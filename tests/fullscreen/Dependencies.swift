// Minimal player dependencies. Rendering and scheduling use the complete production ViewLayer.
import Cocoa
import OpenGL.GL

enum CocoaCbSwRenderer { case auto, yes, no }
enum MPVOption {
  enum GPURendererOptions {
    static let cocoaCbSwRenderer = "software"
    static let cocoaCb10bitContext = "10bit"
  }
}
enum Preference {
  enum Key { case forceDedicatedGPU }
  static func bool(for key: Key) -> Bool { false }
}
enum Logger {
  static func makeSubsystem(_ name: String, _ icons: [String]) -> String { name }
  static func log(_ message: String, subsystem: String = "") {}
  static func fatal(_ message: String) -> Never { fatalError(message) }
}
final class MPVController {
  var mpvRenderContext: OpaquePointer? = nil
  func shouldRenderUpdateFrame() -> Bool { false }
  func lockAndSetOpenGLContext() {}
  func unlockOpenGLContext() {}
  func getEnum(_ key: String) -> CocoaCbSwRenderer { .auto }
  func getFlag(_ key: String) -> Bool { false }
}
final class PlayerCore {
  let playerNumber = 0
  var mpv: MPVController! = MPVController()
}
final class VideoView: NSView {
  let player = PlayerCore()
  @ReadWriteAtomic var isUninited = true
}
