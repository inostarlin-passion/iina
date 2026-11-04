// Screen-cursor sampler, run by the test driver using its existing screen/accessibility grants.
// Only the 280x50-point test-video region is captured; no desktop images are stored.
import Cocoa
import ScreenCaptureKit
import CoreImage

private struct Request: Codable {
  let id: String
  let displayID: UInt32
  let pid: Int32
  let windowID: UInt32
  let activationX: Double
  let activationY: Double
  let centerX: Double
  let centerY: Double
  let mode: String?
}
private struct Measurement: Codable {
  let frames: Int
  let detected: Int
  let span: Double
  let changesPerSecond: Double
  let firstDelay: Double
  let tailDelay: Double
  var postedEvents: Int = 0
  var postedPerSecond: Double = 0
  var inputMaxGap: Double = 0
}
private struct Response: Codable {
  var measurement: Measurement?
  var error: String?
}
private func write<T: Encodable>(_ value: T, to path: URL) throws {
  try JSONEncoder().encode(value).write(to: path, options: .atomic)
}
private func measure(_ samples: [(Double, Int?)], start: Double, end: Double) throws -> Measurement {
  let visible = samples.compactMap { sample in sample.1.map { (sample.0, $0) } }
  guard samples.count > 60, visible.count >= Int(Double(samples.count) * 0.9),
        let first = visible.first, let last = visible.last,
        last.0 - first.0 > 1.7,
        first.0 - start < 0.3, end - last.0 < 0.3 else {
    throw NSError(domain: "CursorCapture", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Invalid capture: frames=\(samples.count), detected=\(visible.count), span=\((visible.last?.0 ?? 0) - (visible.first?.0 ?? 0)), firstDelay=\((visible.first?.0 ?? 0) - start), tailDelay=\(end - (visible.last?.0 ?? 0))"])
  }
  let changes = zip(visible, visible.dropFirst()).filter { abs($0.0.1 - $0.1.1) > 1 }.count
  let span = last.0 - first.0
  return Measurement(frames: samples.count, detected: visible.count, span: span,
                     changesPerSecond: Double(changes) / span,
                     firstDelay: first.0 - start, tailDelay: end - last.0)
}
private final class CursorFrames: NSObject, SCStreamOutput, SCStreamDelegate {
  private let lock = NSLock()
  private let debugURL: URL
  init(debugURL: URL) { self.debugURL = debugURL }
  private var recorded: [(Double, Int?)] = []
  private var streamError: Error?
  private var statuses: [Int: Int] = [:]
  var statusCounts: [Int: Int] { lock.lock(); defer { lock.unlock() }; return statuses }
  var samples: [(Double, Int?)] { lock.lock(); defer { lock.unlock() }; return recorded }
  var error: Error? { lock.lock(); defer { lock.unlock() }; return streamError }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock(); defer { lock.unlock() }; streamError = error
  }
  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
          let status = attachments.first?[.status] as? Int else { return }
    lock.lock()
    statuses[status, default: 0] += 1
    lock.unlock()
    guard status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.idle.rawValue,
          let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var columns: [Int] = []
    var whitePixels = 0
    var videoPixels = 0
    for x in 0..<width {
      var count = 0
      for y in 0..<height {
        let offset = y * stride + x * 4
        if Int(bytes[offset + 2]) > Int(bytes[offset + 1]) + 15 && Int(bytes[offset + 2]) > Int(bytes[offset]) + 15 { videoPixels += 1 }
        if bytes[offset] > 220 && bytes[offset + 1] > 220 && bytes[offset + 2] > 220 { whitePixels += 1 }
        if bytes[offset] < 40 && bytes[offset + 1] < 40 && bytes[offset + 2] < 40 { count += 1 }
      }
      if count >= 3 { columns.append(x) }
    }
    let isTestVideo = Double(videoPixels) / Double(width * height) > 0.8
    if isTestVideo && (recorded.count == 30 || recorded.count == 100),
       let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer),
                                            from: CGRect(x: 0, y: 0, width: width, height: height)) {
      try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
        .write(to: debugURL.appendingPathComponent("sample-\(recorded.count).png"))
      print("CURSOR DEBUG darkColumns=\(columns.count) whitePixels=\(whitePixels) dimensions=\(width)x\(height) pointer=\(CGEvent(source: nil)!.location)")
      fflush(stdout)
    }
    let position = isTestVideo && columns.count >= 3 && columns.count < 80 && whitePixels > 8 ? columns.first : nil
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    lock.lock(); defer { lock.unlock() }
    recorded.append((time, position))
  }
}
@main
private struct CursorCapture {
  static func main() async throws {
    let permitted = CGPreflightScreenCaptureAccess() && AXIsProcessTrusted()
    if CommandLine.arguments.contains("--preflight") {
      print("cursor_capture_permissions=\(permitted)")
      exit(permitted ? 0 : 2)
    }
    if CommandLine.arguments.contains("--self-test") {
      let good: [(Double, Int?)] = (0..<240).map { (Double($0) / 120, $0 * 4) }
      let result = try measure(good, start: 0, end: 2)
      precondition(result.changesPerSecond > 119)
      let invalid: [[(Double, Int?)]] = [[], good.map { ($0.0, nil) },
        Array(good.prefix(100)), Array(good.suffix(100))]
      for sample in invalid {
        do {
          _ = try measure(sample, start: 0, end: 2)
          fatalError("Incomplete or missing capture was accepted")
        } catch {}
      }
      let stationary = try measure(good.map { ($0.0, 10) }, start: 0, end: 2)
      precondition(stationary.changesPerSecond == 0)
      print("PASS cursor measurement rejects missing/truncated data and stationary cursor has zero cadence")
      return
    }
    guard permitted else { throw NSError(domain: "CursorCapture", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Existing Screen Recording and Accessibility grants required"]) }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let available = directory.appendingPathComponent("available.json")
    try write(["available": true], to: available)
    defer { try? FileManager.default.removeItem(at: available) }
    var previousRequest = ""
    let deadline = Date(timeIntervalSinceNow: 600)
    while Date() < deadline && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
      let path = directory.appendingPathComponent("request.json")
      if let data = try? Data(contentsOf: path), let request = try? JSONDecoder().decode(Request.self, from: data),
         request.id != previousRequest {
        previousRequest = request.id
        let result: Response
        do { result = Response(measurement: try await capture(request), error: nil) }
        catch { result = Response(measurement: nil, error: error.localizedDescription) }
        try write(result, to: directory.appendingPathComponent("\(request.id).json"))
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
  private static func capture(_ request: Request) async throws -> Measurement {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
      throw NSError(domain: "CursorCapture", code: 3)
    }
    guard let app = NSRunningApplication(processIdentifier: request.pid),
          content.windows.contains(where: { $0.windowID == request.windowID && $0.owningApplication?.processID == request.pid }) else {
      throw NSError(domain: "CursorCapture", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Test window does not belong to the requested test process"])
    }
    let oldPosition = CGEvent(source: nil)!.location
    defer { CGWarpMouseCursorPosition(oldPosition) }
    if !app.isActive {
      app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    if !app.isActive {
      // Click only the validated test window's title bar, never its playback surface.
      let point = CGPoint(x: request.activationX, y: request.activationY)
      CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
              mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
      CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
              mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    guard app.isActive else {
      throw NSError(domain: "CursorCapture", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Test app did not become active; refusing to measure another app"])
    }
    if request.mode == "input" {
      let (start, end, posted) = try await postMotion(request)
      var result = Measurement(frames: 0, detected: 0, span: end - start,
                               changesPerSecond: 0, firstDelay: 0, tailDelay: 0)
      result.postedEvents = posted.count
      result.postedPerSecond = Double(posted.count) / (end - start)
      result.inputMaxGap = zip(posted, posted.dropFirst()).map { $0.1 - $0.0 }.max() ?? 0
      return result
    }
    let bounds = CGDisplayBounds(request.displayID)
    let left = request.centerX - 120
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = CGRect(x: left - bounds.minX, y: request.centerY - bounds.minY - 8,
                                      width: 280, height: 50)
    configuration.width = 560
    configuration.height = 100
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.queueDepth = 5
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    configuration.capturesAudio = false
    let debugURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      .appendingPathComponent(request.id, isDirectory: true)
    try FileManager.default.createDirectory(at: debugURL, withIntermediateDirectories: true)
    let output = CursorFrames(debugURL: debugURL)
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                          configuration: configuration, delegate: output)
    let samples = DispatchQueue(label: "iina.regression.screen-samples", qos: .userInteractive)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: samples)
    try await stream.startCapture()
    let (start, end, posted) = try await postMotion(request)
    try await stream.stopCapture()
    samples.sync {}
    if let error = output.error { throw error }
    print("SCFRAME statuses=\(output.statusCounts) samples=\(output.samples.count)")
    fflush(stdout)
    var result = try measure(output.samples, start: start, end: end)
    result.postedEvents = posted.count
    result.postedPerSecond = Double(posted.count) / (end - start)
    result.inputMaxGap = zip(posted, posted.dropFirst()).map { $0.1 - $0.0 }.max() ?? 0
    print("INPUT posted=\(result.postedEvents) hz=\(result.postedPerSecond) maxGap=\(result.inputMaxGap)")
    fflush(stdout)
    return result
  }
  private static func postMotion(_ request: Request) async throws -> (Double, Double, [Double]) {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "Measure cursor cadence without background timer throttling")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let start = ProcessInfo.processInfo.systemUptime
    let inputQueue = DispatchQueue(label: "iina.regression.cursor-events", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(queue: inputQueue)
    var posted: [Double] = []
    var step = 0 // Only used by this serial timer.
    // Presentation sampling needs multiple input positions per capture period.
    // Keep the sweep speed and range the same as in the input-delivery probe.
    let inputRate = request.mode == "cadence" ? 240 : 120
    timer.schedule(deadline: .now(), repeating: 1.0 / Double(inputRate))
    timer.setEventHandler {
      posted.append(ProcessInfo.processInfo.systemUptime)
      let phase = step % inputRate
      let distance = min(phase, inputRate - phase)
      let x = request.centerX - 120 + Double(distance) * 480 / Double(inputRate)
      CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
              mouseCursorPosition: CGPoint(x: x, y: request.centerY), mouseButton: .left)?.post(tap: .cghidEventTap)
      step += 1
    }
    timer.resume()
    try await Task.sleep(nanoseconds: 2_300_000_000)
    timer.cancel()
    inputQueue.sync {}
    let end = ProcessInfo.processInfo.systemUptime
    return (start, end, posted)
  }

}
