import Cocoa
import ScreenCaptureKit

@available(macOS 12.3, *)
final class CompositedFrameRecorder: NSObject, SCStreamOutput {
  struct Sample: Codable {
    let time: Double
    let level: Double
    let cursorX: Int?
  }

  private let queue = DispatchQueue(label: "iina.tests.compositor")
  private let lock = NSLock()
  private var collected: [Sample] = []
  private var stream: SCStream?
  var samples: [Sample] {
    lock.lock()
    defer { lock.unlock() }
    return collected
  }

  func start(displayID: CGDirectDisplayID) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let display = content.displays.first { $0.displayID == displayID }!
    let configuration = SCStreamConfiguration()
    configuration.width = 1280
    configuration.height = Int(1280 * display.frame.height / display.frame.width)
    configuration.minimumFrameInterval = .zero
    configuration.queueDepth = 8
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                          configuration: configuration, delegate: nil)
    self.stream = stream
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
  }

  func stop() async throws {
    guard let stream else { return }
    self.stream = nil
    try await stream.stopCapture()
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, let image = CMSampleBufferGetImageBuffer(buffer),
          let metadata = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
          let displayTime = metadata[.displayTime] as? UInt64,
          (metadata[.status] as? Int) == SCFrameStatus.complete.rawValue else { return }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let time = Double(displayTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let pixels = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    let stride = CVPixelBufferGetBytesPerRow(image)
    // Locate the chroma marker instead of assuming the moving video covers the display center.
    var longestRun = 0
    var videoPixel: Int?
    for y in Swift.stride(from: height / 8, to: height * 7 / 8, by: 16) {
      var runStart: Int?
      for x in Swift.stride(from: width / 16, to: width * 15 / 16, by: 4) {
        let offset = y * stride + x * 4
        let marker = Int(pixels[offset + 2]) - Int(pixels[offset + 1]) > 40
          && Int(pixels[offset + 2]) - Int(pixels[offset]) > 40
        if marker {
          if runStart == nil { runStart = x }
          if let start = runStart, x - start > max(longestRun, 80) {
            longestRun = x - start
            videoPixel = y * stride + ((start + x) / 2) * 4
          }
        } else {
          runStart = nil
        }
      }
    }
    let level = videoPixel.map {
      (Double(pixels[$0]) + Double(pixels[$0 + 1]) + Double(pixels[$0 + 2])) / 3
    } ?? -1
    var cursorX: Int?
    let row = Int(Double(height) * 0.65)
    for y in max(0, row - 4)..<min(height, row + 22) {
      for x in width / 8..<width * 7 / 8 {
        let offset = y * stride + x * 4
        if pixels[offset] < 20 && pixels[offset + 1] < 20 && pixels[offset + 2] < 20 {
          cursorX = min(cursorX ?? x, x)
        }
      }
    }
    lock.lock()
    collected.append(Sample(time: time, level: level, cursorX: cursorX))
    lock.unlock()
  }

  static func changeIntervals<T: Equatable>(_ samples: [Sample], value: (Sample) -> T) -> [Double] {
    guard let first = samples.first else { return [] }
    var previous = value(first)
    var lastChange = first.time
    var intervals: [Double] = []
    for sample in samples.dropFirst() {
      let next = value(sample)
      if next != previous {
        intervals.append(sample.time - lastChange)
        previous = next
        lastChange = sample.time
      }
    }
    if let last = samples.last { intervals.append(last.time - lastChange) }
    return intervals
  }
}

struct CursorMotion: Codable {
  let start: Double
  let end: Double
  var postedAt: [Double] = []
}

struct ProbeStart: Codable {
  let displayID: UInt32
}

struct ProbeBounds: Codable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

#if COMPOSITOR_PROBE_MAIN
@main
struct CompositorProbeMain {
  static func main() async {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    do {
      try await run(in: directory)
    } catch {
      try? Data(String(describing: error).utf8)
        .write(to: directory.appendingPathComponent("error.txt"), options: .atomic)
    }
  }

  static func run(in directory: URL) async throws {
    guard CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else {
      try Data("The probe requires Screen Recording and event posting permissions".utf8)
        .write(to: directory.appendingPathComponent("error.txt"), options: .atomic)
      return
    }
    let recorder = CompositedFrameRecorder()
    let originalCursor = CGEvent(source: nil)!.location
    defer {
      CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalCursor,
              mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    let startData = try await read("start.json", in: directory)
    let request = try JSONDecoder().decode(ProbeStart.self, from: startData)
    try await recorder.start(displayID: request.displayID)
    let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
    while true {
      let recent = Array(recorder.samples.suffix(30))
      let changes = CompositedFrameRecorder.changeIntervals(recent.filter { $0.level >= 0 }, value: { Int($0.level / 3) })
      if recent.count >= 20 && changes.count >= 10 { break }
      guard ProcessInfo.processInfo.systemUptime < readyDeadline else {
        try Data("The probe cannot see a changing video marker before fullscreen entry".utf8)
          .write(to: directory.appendingPathComponent("error.txt"), options: .atomic)
        try await recorder.stop()
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try Data().write(to: directory.appendingPathComponent("ready"), options: .atomic)
    var index = 0
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
      let requestURL = directory.appendingPathComponent("motion-\(index)-request.json")
      guard let data = try? Data(contentsOf: requestURL) else {
        try await Task.sleep(nanoseconds: 10_000_000)
        continue
      }
      let bounds = try JSONDecoder().decode(ProbeBounds.self, from: data)
      let motion = await moveCursor(bounds)
      try JSONEncoder().encode(motion).write(to: directory.appendingPathComponent("motion-\(index)-result.json"), options: .atomic)
      index += 1
    }
    try await recorder.stop()
    try JSONEncoder().encode(recorder.samples).write(to: directory.appendingPathComponent("samples.json"), options: .atomic)
  }

  static func read(_ name: String, in directory: URL) async throws -> Data {
    let url = directory.appendingPathComponent(name)
    let deadline = ProcessInfo.processInfo.systemUptime + 600
    while !FileManager.default.fileExists(atPath: url.path) {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw NSError(domain: "Compositor probe timed out: \(name)", code: 1)
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return try Data(contentsOf: url)
  }

  static func moveCursor(_ bounds: ProbeBounds) async -> CursorMotion {
    await withCheckedContinuation { continuation in
      let queue = DispatchQueue(label: "iina.tests.cursor-input", qos: .userInteractive)
      let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
      let start = ProcessInfo.processInfo.systemUptime
      var postedAt: [Double] = []
      timer.setEventHandler {
        let now = ProcessInfo.processInfo.systemUptime
        if now - start >= 3 {
          timer.cancel()
          timer.setEventHandler {}
          continuation.resume(returning: CursorMotion(start: start, end: now, postedAt: postedAt))
          return
        }
        let fraction = (now - start).truncatingRemainder(dividingBy: 2) / 2
        let point = CGPoint(x: bounds.x + bounds.width * (0.2 + 0.6 * fraction),
                            y: bounds.y + bounds.height * 0.65)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        postedAt.append(now)
      }
      timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
      timer.resume()
    }
  }
}
#else
@available(macOS 12.3, *)
final class CompositorProbeClient {
  private let directory: URL
  private var stopped = false
  private var motionIndex = 0

  init() throws {
    guard let path = ProcessInfo.processInfo.environment["IINA_COMPOSITOR_PROBE_DIR"] else {
      throw NSError(domain: "Run other/test_fullscreen.sh to start the authorized compositor probe", code: 1)
    }
    directory = URL(fileURLWithPath: path)
  }

  var samples: [CompositedFrameRecorder.Sample] {
    get throws {
      try JSONDecoder().decode([CompositedFrameRecorder.Sample].self,
                               from: Data(contentsOf: directory.appendingPathComponent("samples.json")))
    }
  }

  func start(displayID: CGDirectDisplayID) async throws {
    try JSONEncoder().encode(ProbeStart(displayID: displayID))
      .write(to: directory.appendingPathComponent("start.json"), options: .atomic)
    _ = try await read("ready")
  }

  func moveCursor(bounds: CGRect) async throws -> CursorMotion {
    let index = motionIndex
    motionIndex += 1
    try JSONEncoder().encode(ProbeBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))
      .write(to: directory.appendingPathComponent("motion-\(index)-request.json"), options: .atomic)
    return try JSONDecoder().decode(CursorMotion.self, from: await read("motion-\(index)-result.json"))
  }

  func stop() async throws {
    guard !stopped else { return }
    stopped = true
    try Data().write(to: directory.appendingPathComponent("stop"), options: .atomic)
    _ = try await read("samples.json")
  }

  private func read(_ name: String) async throws -> Data {
    let url = directory.appendingPathComponent(name)
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while !FileManager.default.fileExists(atPath: url.path) {
      if let error = try? String(contentsOf: directory.appendingPathComponent("error.txt"), encoding: .utf8) {
        throw NSError(domain: error, code: 1)
      }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw NSError(domain: "Compositor probe timed out: \(name)", code: 1)
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return try Data(contentsOf: url)
  }
}
#endif
