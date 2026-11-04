import Cocoa
import CoreVideo
import OpenGL.GL
import XCTest
@testable import IINA

@MainActor
final class IINAFullscreenTests: XCTestCase {
  private var player: PlayerCore!
  private var originalArguments: [String: Any] = [:]
  private var fixtureDirectory: URL!

  override func setUpWithError() throws {
    originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = originalArguments
    for (key, value) in [
      "recordPlaybackHistory": false, "recordRecentFiles": false,
      "resumeLastPosition": false, "pauseWhenOpen": false, "fullScreenWhenOpen": false,
      "useLegacyFullScreen": false, "blackOutMonitor": false,
      "playWhenEnteringFullScreen": false, "pauseWhenLeavingFullScreen": false,
      "enableThumbnailPreview": false, "enableDisplayIdle": true,
      "enableControlBarAutoHide": true
    ] { arguments[key] = value }
    arguments["controlBarAutoHideTimeout"] = 30.0
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    fixtureDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("iina-fullscreen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    let file = fixtureDirectory.appendingPathComponent("motion.y4m")
    var data = Data("YUV4MPEG2 W320 H180 F30:1 Ip A1:1 C420jpeg\n".utf8)
    for frame in 0..<450 {
      data.append(Data("FRAME\n".utf8))
      data.append(Data(repeating: UInt8(40 + frame % 160), count: 320 * 180))
      data.append(Data(repeating: 90, count: 320 * 180 / 4))
      data.append(Data(repeating: 200, count: 320 * 180 / 4))
    }
    try data.write(to: file)
    player = PlayerCore.newPlayerCore
    player.openURL(file, shouldAutoLoad: false)
    try waitUntil("video playing", timeout: 15) { self.player.info.state == .playing }
    player.mpv.setString("loop-file", "inf")
    player.mainWindow.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    pump(0.4)
  }

  override func tearDownWithError() throws {
    if let player {
      if player.mainWindow.fsState.isFullscreen {
        player.mainWindow.toggleWindowFullScreen()
        try? waitUntil("exit fullscreen in teardown") {
          self.player.mainWindow.fsState == .windowed
        }
      }
      player.stop()
      try? waitUntil("player stopped") { player.info.state == .idle }
      player.mainWindow.window?.close()
    }
    player = nil
    UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    if let fixtureDirectory { try FileManager.default.removeItem(at: fixtureDirectory) }
  }

  private func pump(_ seconds: TimeInterval) {
    let until = Date(timeIntervalSinceNow: seconds)
    while Date() < until {
      while let event = NSApp.nextEvent(matching: .any, until: .distantPast,
                                       inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
      }
      RunLoop.current.run(until: min(until, Date(timeIntervalSinceNow: 0.005)))
    }
  }

  private func waitUntil(_ label: String, timeout: TimeInterval = 10,
                         _ condition: () -> Bool) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline { pump(0.01) }
    guard condition() else { throw NSError(domain: "FullscreenRegression", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Timed out: \(label)"]) }
  }

  private func enterFullscreen(legacy: Bool) throws {
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["useLegacyFullScreen"] = legacy
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    player.mainWindow.toggleWindowFullScreen()
    try waitUntil("entered fullscreen") {
      if case .fullscreen(let actualLegacy, _) = self.player.mainWindow.fsState {
        return actualLegacy == legacy
      }
      return false
    }
    pump(0.4)
  }

  private func snapshot() throws -> NSBitmapImageRep {
    var image: NSImage?
    var completed = false
    Task { @MainActor in
      image = await player.mainWindow.videoView.videoLayer.captureSnapshot()
      completed = true
    }
    try waitUntil("rendered snapshot") { completed }
    let captured = try XCTUnwrap(image)
    return try XCTUnwrap(captured.representations.first as? NSBitmapImageRep
      ?? captured.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
  }

  private func luminance(_ image: NSBitmapImageRep) throws -> Double {
    let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?
      .usingColorSpace(.deviceRGB))
    return Double(color.redComponent + color.greenComponent + color.blueComponent)
  }

  private func mouseEvent(index: Int) throws -> NSEvent {
    let window = try XCTUnwrap(player.mainWindow.window)
    let location = NSPoint(x: window.contentLayoutRect.midX + CGFloat(index % 100),
                           y: window.contentLayoutRect.midY)
    return try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: index,
      clickCount: 0, pressure: 0))
  }

  func testH1VisibleUIIsIdempotentDuringMouseBurst() throws {
    try enterFullscreen(legacy: false)
    let controller = player.mainWindow!
    controller.isMouseInWindow = true
    controller.showUI()
    try waitUntil("UI shown") { controller.animationState == .shown }
    for index in 0..<1000 { controller.mouseMoved(with: try mouseEvent(index: index)) }
    XCTAssertEqual(controller.animationState, .shown,
      "Moving over already-visible UI must not restart the fade-in animation")
  }

  func testH2HiddenUIAndInterruptedHideCanShowAgain() throws {
    let controller = player.mainWindow!
    controller.hideUI(force: true)
    try waitUntil("UI hidden") { controller.animationState == .hidden }
    controller.isMouseInWindow = true
    controller.mouseMoved(with: try mouseEvent(index: 1))
    controller.mouseMoved(with: try mouseEvent(index: 2))
    try waitUntil("UI shown") { controller.animationState == .shown }
    XCTAssertFalse(try XCTUnwrap(controller.currentControlBar).isHidden)
    controller.hideUI(force: true)
    XCTAssertEqual(controller.animationState, .willHide)
    controller.mouseMoved(with: try mouseEvent(index: 3))
    try waitUntil("interrupted hide reversed") { controller.animationState == .shown }
    XCTAssertFalse(try XCTUnwrap(controller.currentControlBar).isHidden)
  }

  private func verifyPlayback(legacy: Bool) throws {
    let window = try XCTUnwrap(player.mainWindow.window)
    let before = window.frame
    try enterFullscreen(legacy: legacy)
    let first = try luminance(snapshot())
    pump(0.7)
    let second = try luminance(snapshot())
    XCTAssertGreaterThan(first, 0.1)
    XCTAssertGreaterThan(second, 0.1)
    XCTAssertGreaterThan(abs(first - second), 0.03, "Video must advance in fullscreen")
    player.mainWindow.toggleWindowFullScreen()
    try waitUntil("restored window") { self.player.mainWindow.fsState == .windowed }
    pump(0.3)
    XCTAssertEqual(window.frame.width, before.width, accuracy: 2)
    XCTAssertEqual(window.frame.height, before.height, accuracy: 2)
    XCTAssertGreaterThan(try luminance(snapshot()), 0.1)
  }

  func testH3NativeFullscreenRendersAndRestoresWindow() throws { try verifyPlayback(legacy: false) }
  func testH3LegacyFullscreenRendersAndRestoresWindow() throws { try verifyPlayback(legacy: true) }

  func testH4PausedFullscreenCanDrawAfterDisplayLinkStops() throws {
    try enterFullscreen(legacy: false)
    player.pause()
    try waitUntil("paused") { self.player.info.state == .paused }
    pump(6.5)
    let link = try XCTUnwrap(player.mainWindow.videoView.link)
    XCTAssertFalse(CVDisplayLinkIsRunning(link))
    XCTAssertGreaterThan(try luminance(snapshot()), 0.1)
    player.resume()
    try waitUntil("resumed") { self.player.info.state == .playing }
    pump(0.3)
    XCTAssertTrue(CVDisplayLinkIsRunning(link))
    XCTAssertGreaterThan(try luminance(snapshot()), 0.1)
  }

  private func measureMouse(_ label: String) throws {
    let controller = player.mainWindow!
    controller.isMouseInWindow = true
    let events = try (0..<240).map { try mouseEvent(index: $0) }
    var latencies: [Double] = []
    var costs: [Double] = []
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "iina.regression.mouse"))
    let counter = Atomic(wrappedValue: 0)
    timer.schedule(deadline: .now(), repeating: 1.0 / 120)
    timer.setEventHandler {
      let index = counter.withLock { value -> Int in defer { value += 1 }; return value }
      guard index < events.count else { return }
      let submitted = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.async {
        let start = ProcessInfo.processInfo.systemUptime
        controller.mouseMoved(with: events[index])
        costs.append(ProcessInfo.processInfo.systemUptime - start)
        latencies.append(start - submitted)
      }
    }
    timer.resume()
    defer { timer.cancel() }
    try waitUntil("mouse sample \(label)", timeout: 6) { latencies.count == events.count }
    let sorted = latencies.sorted()
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    let maximum = sorted.last!
    let displayPeriod: Double
    if let link = player.mainWindow.videoView.link {
      let time = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
      displayPeriod = time.timeScale > 0 && time.timeValue > 0
        ? Double(time.timeValue) / Double(time.timeScale) : 1.0 / 60
    } else { displayPeriod = 1.0 / 60 }
    print("MOUSE \(label) samples=\(latencies.count) p95_ms=\(p95 * 1000) max_ms=\(maximum * 1000) handler_max_ms=\((costs.max() ?? 0) * 1000) nominal_hz=\(1 / displayPeriod)")
    XCTAssertLessThan(p95, 2 * displayPeriod, label)
    XCTAssertLessThan(maximum, 0.1, label)
  }

  private var cursorProbeDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("build/fullscreen-cursor-probe")
  }

  private func cursorProbeMeasurement(_ label: String, mode: String = "capture",
                                      window suppliedWindow: NSWindow? = nil) throws -> [String: Any] {
    let window = try XCTUnwrap(suppliedWindow ?? player.mainWindow.window)
    let screen = try XCTUnwrap(window.screen)
    let displayID = try XCTUnwrap(screen.displayId)
    let center = window.convertPoint(toScreen: NSPoint(x: window.contentLayoutRect.midX,
                                                       y: window.contentLayoutRect.midY))
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    let id = UUID().uuidString
    let request: [String: Any] = ["id": id, "displayID": displayID, "mode": mode,
      "pid": ProcessInfo.processInfo.processIdentifier, "windowID": window.windowNumber,
      "activationX": window.frame.midX,
      "activationY": NSScreen.screens.first!.frame.maxY - window.frame.maxY + 10,
      "centerX": center.x, "centerY": NSScreen.screens.first!.frame.maxY - center.y]
    let responseURL = cursorProbeDirectory.appendingPathComponent("\(id).json")
    NSCursor.arrow.set()
    try JSONSerialization.data(withJSONObject: request).write(
      to: cursorProbeDirectory.appendingPathComponent("request.json"), options: .atomic)
    try waitUntil("screen-cursor sample \(label)", timeout: 15) {
      FileManager.default.fileExists(atPath: responseURL.path)
    }
    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any])
    if let error = response["error"] as? String {
      XCTFail("\(label): \(error)")
      throw NSError(domain: "CursorCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
    }
    let measurement = try XCTUnwrap(response["measurement"] as? [String: Any])
    print("CURSOR \(label) \(measurement)")
    return measurement
  }

  func testH6SystemCursorPresentationCadence() throws {
    guard FileManager.default.fileExists(atPath: cursorProbeDirectory.appendingPathComponent("available.json").path)
    else { throw XCTSkip("Run python3 tests/fullscreen/run_tests.py --integration to start the screen-cursor sampler") }
    let time = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(
      try XCTUnwrap(player.mainWindow.videoView.link))
    let nominal = Double(time.timeScale) / Double(time.timeValue)
    XCTAssertGreaterThanOrEqual(nominal, 45)
    var inconclusive: [String] = []
    for fps in [24, 30, 60] {
      let original = fixtureDirectory.appendingPathComponent("motion.y4m")
      var data = try Data(contentsOf: original)
      let headerEnd = try XCTUnwrap(data.firstIndex(of: 10))
      data.replaceSubrange(0...headerEnd,
        with: Data("YUV4MPEG2 W320 H180 F\(fps):1 Ip A1:1 C420jpeg\n".utf8))
      let video = fixtureDirectory.appendingPathComponent("motion-\(fps).y4m")
      try data.write(to: video)
      player.openURL(video, shouldAutoLoad: false)
      try waitUntil("\(fps)fps video playing") { self.player.info.state == .playing }
      player.mpv.setString("loop-file", "inf")
      XCTAssertEqual(player.mpv.getDouble("container-fps"), Double(fps), accuracy: 0.01)
      pump(0.3)
      func assess(_ label: String) throws -> Double? {
        let sample = try cursorProbeMeasurement(label)
        let span = try XCTUnwrap(sample["span"] as? Double)
        let frames = try XCTUnwrap(sample["frames"] as? Int)
        let inputRate = try XCTUnwrap(sample["postedPerSecond"] as? Double)
        let captureRate = Double(frames - 1) / span
        guard captureRate >= nominal * 0.8, inputRate >= 108 else {
          inconclusive.append("\(label): capture=\(captureRate)Hz input=\(inputRate)Hz")
          return nil
        }
        let rate = try XCTUnwrap(sample["changesPerSecond"] as? Double)
        XCTAssertGreaterThanOrEqual(rate, nominal * 0.8)
        return rate
      }
      let windowed = try assess("\(fps)fps/windowed")
      try enterFullscreen(legacy: false)
      let native = try assess("\(fps)fps/native-fullscreen")
      if let native, let windowed { XCTAssertGreaterThanOrEqual(native, windowed * 0.8) }
      player.mainWindow.toggleWindowFullScreen()
      try waitUntil("exit native fullscreen") { self.player.mainWindow.fsState == .windowed }
      try enterFullscreen(legacy: true)
      let legacy = try assess("\(fps)fps/legacy-fullscreen")
      if let legacy, let windowed { XCTAssertGreaterThanOrEqual(legacy, windowed * 0.8) }
      player.mainWindow.toggleWindowFullScreen()
      try waitUntil("exit legacy fullscreen") { self.player.mainWindow.fsState == .windowed }
    }
    if !inconclusive.isEmpty {
      throw XCTSkip("Screen capture is undersampled; hardware cursor FPS remains unverified: " + inconclusive.joined(separator: "; "))
    }
  }

  func testH7SystemMouseEventsWithoutRecording() throws {
    guard FileManager.default.fileExists(atPath: cursorProbeDirectory.appendingPathComponent("available.json").path)
    else { throw XCTSkip("Start the independent cursor probe with --integration") }
    for stage in ["windowed", "native-fullscreen", "legacy-fullscreen"] {
      if stage == "native-fullscreen" { try enterFullscreen(legacy: false) }
      if stage == "legacy-fullscreen" {
        player.mainWindow.toggleWindowFullScreen()
        try waitUntil("exit native fullscreen") { self.player.mainWindow.fsState == .windowed }
        try enterFullscreen(legacy: true)
      }
      var latencies: [Double] = []
      let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
        latencies.append(ProcessInfo.processInfo.systemUptime - event.timestamp)
        return event
      })
      let sample: [String: Any]
      do { sample = try cursorProbeMeasurement("unrecorded/\(stage)", mode: "input") }
      catch { NSEvent.removeMonitor(monitor); throw error }
      NSEvent.removeMonitor(monitor)
      let posted = try XCTUnwrap(sample["postedEvents"] as? Int)
      let inputRate = try XCTUnwrap(sample["postedPerSecond"] as? Double)
      XCTAssertGreaterThan(inputRate, 108)
      XCTAssertGreaterThanOrEqual(latencies.count, Int(Double(posted) * 0.8), "\(stage): real events must reach the app")
      guard !latencies.isEmpty else { continue }
      let sorted = latencies.sorted()
      let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
      print("SYSTEM_MOUSE \(stage) delivered=\(latencies.count) posted=\(posted) p95_ms=\(p95 * 1000) max_ms=\(sorted.last! * 1000)")
      let period = 1 / Double(try XCTUnwrap(player.mainWindow.window?.screen).maximumFramesPerSecond)
      XCTAssertLessThan(p95, period * 2)
      XCTAssertLessThan(sorted.last!, 0.1)
    }
  }

  func testH8PlainAppKitWindowCaptureControl() throws { try captureControl(mode: 0) }
  func testH9MainThreadOpenGLControl() throws { try captureControl(mode: 1) }
  func testH10BackgroundOpenGLControl() throws { try captureControl(mode: 2) }
  func testH11ProductionContextOpenGLControl() throws { try captureControl(mode: 3) }

  private func captureControl(mode: Int) throws {
    guard FileManager.default.fileExists(atPath: cursorProbeDirectory.appendingPathComponent("available.json").path)
    else { throw XCTSkip("Start the independent cursor probe with --integration") }
    player.pause()
    try waitUntil("paused control player") { self.player.info.state == .paused }
    player.mainWindow.window?.orderOut(nil)
    pump(6.5)
    let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 800, height: 450),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]
    window.title = "Cursor capture control \(mode)"
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
    let glLayer: CursorControlGLLayer?
    if mode > 0 {
      let reference = mode == 3 ? ViewLayer(player.mainWindow.videoView) : nil
      glLayer = CursorControlGLLayer(reference: reference, background: mode > 1)
      glLayer!.frame = view.bounds
      glLayer!.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      if let reference {
        glLayer!.contentsFormat = reference.contentsFormat
        glLayer!.colorspace = player.mainWindow.videoView.videoLayer.colorspace
      }
      view.layer = glLayer
    } else { glLayer = nil }
    view.wantsLayer = true
    window.contentView = view
    var tick = 0
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
      if let glLayer { glLayer.update(phase: tick) }
      else {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.backgroundColor = NSColor(deviceRed: 0.9,
          green: 0.2 + CGFloat(tick % 100) / 250, blue: 0.1, alpha: 1).cgColor
        CATransaction.commit()
      }
      tick += 1
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate(); window.orderOut(nil); window.close() }
    window.makeKeyAndOrderFront(nil)
    pump(0.4)
    for stage in 0..<3 {
      if stage > 0 {
        var entered = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                               object: window, queue: .main) { _ in entered = true }
        window.toggleFullScreen(nil)
        defer { NotificationCenter.default.removeObserver(observer) }
        try waitUntil("plain control fullscreen") { entered }
        pump(0.4)
      }
      let sample = try cursorProbeMeasurement("control-\(mode)/\(stage)", window: window)
      print("CAPTURE_CONTROL mode=\(mode) stage=\(stage) color_ticks=\(tick) sample=\(sample)")
      if stage > 0 {
        var exited = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                               object: window, queue: .main) { _ in exited = true }
        window.toggleFullScreen(nil)
        defer { NotificationCenter.default.removeObserver(observer) }
        try waitUntil("plain control exit fullscreen") { exited }
      }
    }
  }

  func testH5MouseResponseDuringRealPlayback() throws {
    try measureMouse("windowed")
    try enterFullscreen(legacy: false)
    try measureMouse("native-fullscreen")
    player.mainWindow.toggleWindowFullScreen()
    try waitUntil("exit native fullscreen") { self.player.mainWindow.fsState == .windowed }
    try enterFullscreen(legacy: true)
    try measureMouse("legacy-fullscreen")
  }
}

// Rendering controls isolate CAOpenGLLayer, its caller queue, and IINA's actual context format.
private final class CursorControlGLLayer: CAOpenGLLayer {
  private let reference: ViewLayer?
  private let background: Bool
  private let queue = DispatchQueue(label: "iina.tests.gl-control", qos: .userInteractive)
  @Atomic private var phase = 0
  init(reference: ViewLayer?, background: Bool) {
    self.reference = reference
    self.background = background
    super.init()
    isAsynchronous = false
  }
  override init(layer: Any) {
    let old = layer as! CursorControlGLLayer
    reference = old.reference
    background = old.background
    super.init(layer: layer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used by the rendering control") }
  override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
    guard let reference else { return super.copyCGLPixelFormat(forDisplayMask: mask) }
    let format = reference.copyCGLPixelFormat(forDisplayMask: mask)
    CGLRetainPixelFormat(format)
    return format
  }
  override func copyCGLContext(forPixelFormat format: CGLPixelFormatObj) -> CGLContextObj {
    guard let reference else { return super.copyCGLContext(forPixelFormat: format) }
    let context = reference.copyCGLContext(forPixelFormat: format)
    CGLRetainContext(context)
    return context
  }
  func update(phase: Int) {
    let work = { [self] in
      self.phase = phase
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      display()
      CATransaction.commit()
      CATransaction.flush()
    }
    if background { queue.async(execute: work) } else { work() }
  }
  override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                        forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool { true }
  override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                     forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
    glClearColor(0.9, 0.2 + Float(phase % 100) / 250, 0.1, 1)
    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    glFlush()
  }
}
