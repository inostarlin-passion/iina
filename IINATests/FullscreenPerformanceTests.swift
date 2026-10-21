import Cocoa
import OpenGL
import ScreenCaptureKit
import XCTest
@testable import IINA

/// Exercise the actual window controller and OpenGL layer, rather than a second implementation
/// of their state machines. These tests require the macOS application host (the iina scheme).
@MainActor
final class FullscreenPerformanceTests: XCTestCase {
  private static var testPlayer: CountingPlayerCore!
  private var player: CountingPlayerCore { Self.testPlayer }
  private var controller: MainWindowController { player.mainWindow }

  override func setUp() async throws {
    if Self.testPlayer == nil {
      // Override preferences for this process only; don't change the user's playback settings.
      var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      for key in ["fullScreenWhenOpen", "useLegacyFullScreen", "pauseWhenOpen", "pauseWhenLeavingFullScreen",
                  "recordPlaybackHistory", "resumeLastPosition", "enableThumbnailPreview", "enableAdvancedSettings",
                  "disableAnimations", "pauseWhenInactive"] {
        arguments[key] = false
      }
      arguments["enableControlBarAutoHide"] = true
      UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
      let player = CountingPlayerCore()
      player.label = "fullscreen-tests"
      player.startMPV()
      _ = player.mainWindow.window
      Self.testPlayer = player
    }
    controller.fsState = .windowed
    controller.videoView.videoLayer.inLiveResize = false
    controller.animationState = .shown
    controller.isMouseInWindow = true
    player.uiRefreshCount = 0
  }

  override func tearDown() async throws {
    controller.hideControlTimer?.invalidate()
    controller.hideControlTimer = nil
    controller.videoView.videoLayer.inLiveResize = false
    controller.fsState = .windowed
  }

  func testEnteringFullscreenKeepsDisplayLinkRunningAndRecoversOnFailure() {
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    XCTAssertTrue(CVDisplayLinkIsRunning(controller.videoView.link!))
    XCTAssertFalse(controller.videoView.isIdle)
    controller.windowDidFailToEnterFullScreen(controller.window!)
    XCTAssertFalse(controller.videoView.videoLayer.inLiveResize)
    XCTAssertFalse(controller.fsState.isFullscreen)
  }

  func testExitingFullscreenKeepsDisplayLinkRunningAndRecoversOnFailure() {
    controller.fsState = .fullscreen(legacy: false, priorWindowedFrame: controller.window!.frame)
    controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification))
    XCTAssertTrue(CVDisplayLinkIsRunning(controller.videoView.link!))
    XCTAssertFalse(controller.videoView.isIdle)
    controller.windowDidFailToExitFullScreen(controller.window!)
    XCTAssertFalse(controller.videoView.videoLayer.inLiveResize)
    XCTAssertTrue(controller.fsState.isFullscreen)
  }

  func testCompletedFullscreenTransitionsRestoreNormalRendering() {
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))
    XCTAssertFalse(controller.videoView.videoLayer.inLiveResize)
    XCTAssertTrue(controller.fsState.isFullscreen)
    controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification))
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
    XCTAssertFalse(controller.videoView.videoLayer.inLiveResize)
    XCTAssertFalse(controller.fsState.isFullscreen)
  }

  func testFullscreenAnimationKeepsDrawableSizeAndRestoresItOnFailure() {
    let view = controller.videoView
    let originalSize = view.frame.size
    let drawableSize = view.videoLayer.bounds.size
    defer { view.setFrameSize(originalSize) }
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    view.setFrameSize(NSSize(width: originalSize.width * 1.5, height: originalSize.height * 1.5))
    XCTAssertEqual(view.videoLayer.bounds.size, drawableSize,
                   "Window animation must scale the existing drawable instead of reallocating IOSurfaces")
    controller.windowDidFailToEnterFullScreen(controller.window!)
    XCTAssertEqual(view.videoLayer.bounds.size, view.bounds.size)
    XCTAssertEqual(view.videoLayer.affineTransform(), .identity)
  }

  func testFullscreenMouseBurstDoesNotRestartVisibleUIAnimations() {
    controller.fsState = .fullscreen(legacy: false, priorWindowedFrame: controller.window!.frame)
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 100, y: 200),
                                  modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    // A two-second burst on a 120 Hz display must not create 240 fade animations / UI refreshes.
    for _ in 0..<240 { controller.mouseMoved(with: event) }
    XCTAssertEqual(controller.animationState, .shown)
    XCTAssertEqual(player.uiRefreshCount, 0)
  }

  func testShowingUIWhileFadeInIsRunningDoesNotRestartIt() {
    controller.animationState = .willShow
    for _ in 0..<240 { controller.showUI() }
    XCTAssertEqual(player.uiRefreshCount, 0)
  }

  func testMouseActivityReusesHideTimerAndExtendsDeadline() {
    controller.updateTimer()
    let timer = controller.hideControlTimer!
    timer.fireDate = Date(timeIntervalSinceNow: 0.1)
    let previousDeadline = timer.fireDate
    for _ in 0..<240 { controller.updateTimer() }
    XCTAssertTrue(controller.hideControlTimer === timer,
                  "Mouse movement must reschedule the timer instead of allocating one per event")
    XCTAssertGreaterThan(timer.fireDate, previousDeadline)
    XCTAssertTrue(timer.isValid)
  }

  func testMouseActivityCanReverseFadeOut() {
    controller.animationState = .willHide
    controller.showUI()
    XCTAssertEqual(player.uiRefreshCount, 1)
    XCTAssertTrue(controller.animationState == .willShow || controller.animationState == .shown)
  }

  func testLiveResizeEndingDoesNotEndFullscreenRenderingProtection() {
    controller.videoView.videoLayer.inLiveResize = true
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    XCTAssertTrue(controller.videoView.videoLayer.inLiveResize)
    controller.windowDidFailToEnterFullScreen(controller.window!)
    XCTAssertFalse(controller.videoView.videoLayer.inLiveResize)
  }

  func testMainThreadDisplayDoesNotWaitForBusyVideoRenderer() {
    let layer = controller.videoView.videoLayer
    layer.inLiveResize = true
    let format = layer.copyCGLPixelFormat(forDisplayMask: 0)
    let context = layer.copyCGLContext(forPixelFormat: format)
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
      CGLLockContext(context)
      locked.signal()
      // A bounded wait ensures a regression reports a failure instead of hanging the suite.
      _ = release.wait(timeout: .now() + 0.25)
      CGLUnlockContext(context)
      finished.signal()
    }
    XCTAssertEqual(locked.wait(timeout: .now() + 2), .success)
    let start = ProcessInfo.processInfo.systemUptime
    layer.display()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    release.signal()
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    XCTAssertLessThan(elapsed, 1.0 / 60, "A resize/display request must not block mouse handling on the GL context")
  }

  func testRenderRequestsDoNotAccumulateBehindBusyRenderer() async {
    let started = expectation(description: "Renderer is busy")
    let next = expectation(description: "Latest pending redraw")
    let excess = expectation(description: "Obsolete redraws must be coalesced")
    excess.isInverted = true
    let layer = BlockingRenderLayer(controller.videoView)
    layer.onDisplay = { count in
      if count == 1 { started.fulfill() }
      if count == 2 { next.fulfill() }
      if count == 3 { excess.fulfill() }
    }
    DispatchQueue.global(qos: .userInteractive).async {
      _ = layer.started.wait(timeout: .now() + 2)
      for _ in 0..<240 { layer.update(force: true) }
      layer.release.signal()
    }
    layer.update()
    await fulfillment(of: [started], timeout: 2)
    await fulfillment(of: [next, excess], timeout: 0.2)
    XCTAssertEqual(layer.displayCount, 2, "Full-screen/UI redraw bursts must not queue hundreds of GPU submissions")
  }

  func testPlaybackDuringNativeFullscreenAndMouseMovement() async throws {
    // Keep the real AppKit transition independent of the synthetic failure callbacks above.
    let player = PlayerCore()
    player.label = "fullscreen-playback"
    player.startMPV()
    let controller = player.mainWindow!
    let window = controller.window!
    addTeardownBlock { @MainActor in
      if window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
        try await self.waitUntil {
          if case .windowed = controller.fsState { return true }
          return false
        }
      }
      if player.info.state != .idle && player.info.state != .shutDown {
        player.stop()
        try await self.waitUntil { player.info.state == .idle }
      }
      if player.info.state != .shutDown {
        player.shutdown()
        try await self.waitUntil { player.info.state == .shutDown }
      }
      window.orderOut(nil)
    }
    // A generated 60 fps clip makes the test independent of downloads, codecs, and private media.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".y4m")
    var clip = Data("YUV4MPEG2 W320 H180 F60:1 Ip A1:1 C420jpeg\n".utf8)
    for frame in 0..<600 {
      clip.append(Data("FRAME\n".utf8))
      clip.append(Data(repeating: UInt8(32 + (frame * 3) % 192), count: 320 * 180))
      clip.append(Data(repeating: 128, count: 320 * 180 / 2))
    }
    try clip.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let audioURL = url.deletingPathExtension().appendingPathExtension("wav")
    try writeSilentAudio(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }
    player.mpv.setString("loop-file", "no")
    player.openURL(url, shouldAutoLoad: false)
    try await waitUntil { player.info.state == .playing }
    player.loadExternalAudioFile(audioURL)
    try await waitUntil { player.info.currentTrack(.audio) != nil }
    try await Task.sleep(nanoseconds: 500_000_000)

    XCTAssertNotNil(player.info.currentTrack(.video))
    XCTAssertNotNil(player.mpv.getNode(MPVProperty.frameDropCount), "Dropped-frame telemetry must be available")
    let before = player.mpv.getInt(MPVProperty.frameDropCount)
    window.toggleFullScreen(nil)
    try await waitUntil {
      if case .fullscreen = controller.fsState { return true }
      return false
    }
    let transitionDrops = player.mpv.getInt(MPVProperty.frameDropCount) - before
    XCTAssertLessThanOrEqual(transitionDrops, 2, "Fullscreen entry dropped more than two frames of a 60 fps clip")

    var eventDurations: [TimeInterval] = []
    var avSyncErrors: [Double] = []
    let beforeMouse = player.mpv.getInt(MPVProperty.frameDropCount)
    for index in 0..<240 {
      let event = NSEvent.mouseEvent(with: .mouseMoved,
                                    location: NSPoint(x: 100 + index % 200, y: 200),
                                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: index, clickCount: 0, pressure: 0)!
      let start = ProcessInfo.processInfo.systemUptime
      controller.mouseMoved(with: event)
      eventDurations.append(ProcessInfo.processInfo.systemUptime - start)
      if index % 30 == 0 {
        XCTAssertNotNil(player.mpv.getNode(MPVProperty.avsync))
        avSyncErrors.append(abs(player.mpv.getDouble(MPVProperty.avsync)))
      }
      try await Task.sleep(nanoseconds: 8_333_333)
    }
    let mouseDrops = player.mpv.getInt(MPVProperty.frameDropCount) - beforeMouse
    XCTAssertGreaterThanOrEqual(mouseDrops, 0, "The frame counter must not reset during measurement")
    XCTAssertLessThanOrEqual(mouseDrops, 2, "Mouse movement caused video frame drops in fullscreen")
    let p99 = eventDurations.sorted()[237]
    XCTAssertLessThan(p99, 1.0 / 120, "Mouse event handling exceeded a 120 Hz frame budget")
    XCTAssertLessThan(avSyncErrors.max() ?? .infinity, 0.05, "Embedded rendering must preserve audio/video synchronization")
    print("Fullscreen playback: entry drops=\(transitionDrops), mouse drops=\(mouseDrops), mouse p99=\(p99 * 1000) ms, A/V sync error max=\((avSyncErrors.max() ?? 0) * 1000) ms")

    window.toggleFullScreen(nil)
    try await waitUntil {
      if case .windowed = controller.fsState { return true }
      return false
    }
    player.stop()
    try await waitUntil { player.info.state == .idle }
    player.shutdown()
    try await waitUntil { player.info.state == .shutDown }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while !condition() {
      if ProcessInfo.processInfo.systemUptime >= deadline {
        XCTFail("Timed out waiting for playback / fullscreen state")
        throw NSError(domain: "FullscreenPerformanceTests", code: 1)
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func writeSilentAudio(to url: URL) throws {
    let bytes: UInt32 = 48_000 * 2 * 10
    var wav = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
    }
    append(bytes + 36)
    wav.append(Data("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(48_000))
    append(UInt32(96_000))
    append(UInt16(2))
    append(UInt16(16))
    wav.append(Data("data".utf8))
    append(bytes)
    wav.append(Data(repeating: 0, count: Int(bytes)))
    try wav.write(to: url)
  }

  @available(macOS 12.3, *)
  func testCompositedFullscreenVideoAndSystemCursor() async throws {
    let player = PlayerCore()
    player.label = "compositor-test"
    player.startMPV()
    let controller = player.mainWindow!
    let window = controller.window!
    let recorder = try CompositorProbeClient()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".y4m")
    addTeardownBlock { @MainActor in
      try? await recorder.stop()
      if window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
        try await self.waitUntil {
          if case .windowed = controller.fsState { return true }
          return false
        }
      }
      player.stop()
      try await self.waitUntil { player.info.state == .idle }
      player.shutdown()
      try await self.waitUntil { player.info.state == .shutDown }
      window.orderOut(nil)
      try? FileManager.default.removeItem(at: url)
    }
    var clip = Data("YUV4MPEG2 W640 H360 F60:1 Ip A1:1 C420jpeg\n".utf8)
    for frame in 0..<600 {
      clip.append(Data("FRAME\n".utf8))
      clip.append(Data(repeating: UInt8(64 + (frame % 24) * 6), count: 640 * 360))
      clip.append(Data(repeating: 100, count: 640 * 360 / 4))
      clip.append(Data(repeating: 170, count: 640 * 360 / 4))
    }
    try clip.write(to: url)
    player.mpv.setString("loop-file", "inf")
    player.openURL(url, shouldAutoLoad: false)
    try await waitUntil { player.info.state == .playing }
    window.center()
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(nanoseconds: 700_000_000)
    let displayID = window.screen!.displayId!
    try await recorder.start(displayID: displayID)
    try await Task.sleep(nanoseconds: 300_000_000)
    let entryStart = ProcessInfo.processInfo.systemUptime
    window.toggleFullScreen(nil)
    try await waitUntil {
      if case .fullscreen = controller.fsState { return true }
      return false
    }
    let entryEnd = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(nanoseconds: 300_000_000)
    let referenceWindow = NSPanel(contentRect: window.screen!.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
    referenceWindow.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 1)
    referenceWindow.level = .floating
    referenceWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    referenceWindow.orderFrontRegardless()
    let referenceMotion = try await recorder.moveCursor(bounds: CGDisplayBounds(displayID))
    referenceWindow.orderOut(nil)
    controller.hideUIAndCursor()
    try await Task.sleep(nanoseconds: 300_000_000)
    let layer = controller.videoView.videoLayer
    let context = layer.copyCGLContext(forPixelFormat: layer.copyCGLPixelFormat(forDisplayMask: 0))
    let contextLatency = Task.detached(priority: .high) {
      var waits: [Double] = []
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while ProcessInfo.processInfo.systemUptime < deadline {
        let start = ProcessInfo.processInfo.systemUptime
        CGLLockContext(context)
        waits.append(ProcessInfo.processInfo.systemUptime - start)
        CGLUnlockContext(context)
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      return waits.sorted()
    }
    let redrawBurst = Task { @MainActor in
      try await Task.sleep(nanoseconds: 200_000_000)
      for _ in 0..<240 { layer.update(force: true) }
    }
    let motion = try await recorder.moveCursor(bounds: CGDisplayBounds(displayID))
    try await redrawBurst.value
    let contextWaits = try await contextLatency.value
    let cursorStart = motion.start
    let cursorEnd = motion.end
    try await recorder.stop()
    let samples = try recorder.samples
    let attachment = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
    attachment.name = "composited-frames.json"
    attachment.lifetime = .keepAlways
    add(attachment)
    let phases = ["entryStart": entryStart, "entryEnd": entryEnd,
                  "referenceStart": referenceMotion.start, "referenceEnd": referenceMotion.end,
                  "cursorStart": cursorStart, "cursorEnd": cursorEnd]
    let phaseAttachment = XCTAttachment(data: try JSONEncoder().encode(phases), uniformTypeIdentifier: "public.json")
    phaseAttachment.name = "capture-phases.json"
    phaseAttachment.lifetime = .keepAlways
    add(phaseAttachment)
    let motionAttachment = XCTAttachment(data: try JSONEncoder().encode(motion), uniformTypeIdentifier: "public.json")
    motionAttachment.name = "injected-cursor-events.json"
    motionAttachment.lifetime = .keepAlways
    add(motionAttachment)
    let transition = samples.filter { $0.time >= entryStart && $0.time <= entryEnd }
    let cursor = samples.filter { $0.time >= cursorStart && $0.time <= cursorEnd }
    let reference = samples.filter { $0.time >= referenceMotion.start && $0.time <= referenceMotion.end }
    let videoHolds = CompositedFrameRecorder.changeIntervals(transition, value: { Int($0.level / 3) })
    let cursorHolds = CompositedFrameRecorder.changeIntervals(cursor.filter { $0.cursorX != nil }, value: { $0.cursorX! })
    let referenceHolds = CompositedFrameRecorder.changeIntervals(reference.filter { $0.cursorX != nil }, value: { $0.cursorX! })
    let framePeriod = 1.0 / Double(window.screen!.maximumFramesPerSecond)
    let referenceP99 = referenceHolds.sorted().dropLast(referenceHolds.count / 100).last ?? .infinity
    let cursorP99 = cursorHolds.sorted().dropLast(cursorHolds.count / 100).last ?? .infinity
    let contextP95 = contextWaits.dropLast(contextWaits.count / 20).last ?? .infinity
    let cursorAppearance = (cursor.first { $0.cursorX != nil }?.time ?? .infinity) - cursorStart
    let referenceAppearance = (reference.first { $0.cursorX != nil }?.time ?? .infinity) - referenceMotion.start
    print("COMPOSITOR video max=\((videoHolds.max() ?? 0) * 1000) ms; reference cursor p99=\(referenceP99 * 1000) ms; fullscreen cursor p99=\(cursorP99 * 1000) ms; cursor max=\((cursorHolds.max() ?? 0) * 1000) ms; cursor reappearance=\(cursorAppearance * 1000) ms; GL wait p95=\(contextP95 * 1000) ms")
    XCTAssertGreaterThan(transition.count, 10, "The capture must observe the fullscreen animation")
    XCTAssertGreaterThan(videoHolds.count, 10, "Video must continue changing throughout fullscreen entry")
    XCTAssertLessThan(videoHolds.max() ?? .infinity, 3.0 / 60, "Composited video froze during fullscreen entry")
    XCTAssertGreaterThan(cursorHolds.count, 120, "The actual system cursor must be visible and moving in captured output")
    XCTAssertGreaterThan(Double(referenceHolds.count) / (referenceMotion.end - referenceMotion.start),
                         0.8 / framePeriod, "The reference capture must resolve high-refresh cursor motion")
    XCTAssertLessThan(referenceP99, 2.5 * framePeriod, "The capture reference must be free of long stalls")
    XCTAssertLessThan(cursorP99, referenceP99 + 0.5 * framePeriod, "Fullscreen playback reduced the composited cursor cadence")
    XCTAssertLessThan(cursorHolds.max() ?? .infinity, (referenceHolds.max() ?? 0) + 0.5 * framePeriod,
                      "Fullscreen playback introduced cursor stalls beyond the calibrated capture cadence")
    XCTAssertLessThan(cursorHolds.max() ?? .infinity, 1.0 / 30, "The composited system cursor stalled")
    XCTAssertLessThan(cursorAppearance, max(referenceAppearance, framePeriod) + framePeriod,
                      "The hidden system cursor must reappear promptly when movement resumes")
    XCTAssertLessThan(contextP95, framePeriod, "The video renderer must not reserve OpenGL while waiting for a playback deadline")
  }
}

private class CountingPlayerCore: PlayerCore {
  var uiRefreshCount = 0

  override func refreshSyncUITimer() {
    uiRefreshCount += 1
  }
}

private class BlockingRenderLayer: ViewLayer {
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  var onDisplay: ((Int) -> Void)?
  private let countLock = NSLock()
  private var count = 0
  var displayCount: Int {
    countLock.lock()
    defer { countLock.unlock() }
    return count
  }

  override func display() {
    countLock.lock()
    count += 1
    let current = count
    countLock.unlock()
    onDisplay?(current)
    if current == 1 {
      started.signal()
      _ = release.wait(timeout: .now() + 2)
    }
  }
}
