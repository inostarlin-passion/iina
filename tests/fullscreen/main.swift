import Cocoa
import OpenGL.GL
import OpenGL.GL3

var failures = 0
func check(_ condition: Bool, _ message: String) {
  print("\(condition ? "PASS" : "FAIL") \(message)")
  if !condition { failures += 1 }
}
func field<T>(_ object: Any, _ name: String) -> T {
  var mirror: Mirror? = Mirror(reflecting: object)
  while let current = mirror {
    if let child = current.children.first(where: { $0.label == name }), let value = child.value as? T {
      return value
    }
    mirror = current.superclassMirror
  }
  fatalError("Missing production field: \(name)")
}
func queue(_ layer: ViewLayer) -> DispatchQueue { field(layer, "mpvGLQueue") }
func flush(_ layer: ViewLayer) { queue(layer).sync {} }

// Observes production update scheduling, replacing only the expensive rendering boundary.
final class RecordingLayer: ViewLayer {
  var forces: [Bool] = [] // Accessed only on mpvGLQueue; read after draining it.
  var entered: DispatchSemaphore?
  var release: DispatchSemaphore?
  override func display() {
    let force: Atomic<Bool> = field(self, "_forceDraw")
    forces.append(force.wrappedValue)
    force.wrappedValue = false
    if forces.count == 1 {
      entered?.signal()
      if let release { _ = release.wait(timeout: .now() + 3) }
    }
  }
}

let app = NSApplication.shared
let view = VideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

// D1: Hold the real render lock while calling the production display on the main thread.
do {
  let layer = ViewLayer(view)
  let renderLock: NSLocking = field(layer, "displayLock")
  let held = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    renderLock.lock()
    held.signal()
    Thread.sleep(forTimeInterval: 0.15)
    renderLock.unlock()
    done.signal()
  }
  check(held.wait(timeout: .now() + 3) == .success, "D1 setup: background render lock acquired")
  let start = ProcessInfo.processInfo.systemUptime
  layer.display()
  let elapsed = ProcessInfo.processInfo.systemUptime - start
  check(elapsed < 0.030, "D1 main-thread display latency \(elapsed * 1000)ms < 30ms")
  check(done.wait(timeout: .now() + 3) == .success, "D1 background lock released")
  flush(layer)
}

// D2 / D3: Deterministically enqueue a burst while the real serial render queue is busy.
for forced in [false, true] {
  let layer = RecordingLayer(view)
  let blocked = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  queue(layer).async {
    blocked.signal()
    _ = release.wait(timeout: .now() + 3)
  }
  check(blocked.wait(timeout: .now() + 3) == .success, "D2/D3 setup: queue blocked")
  if forced {
    DispatchQueue.concurrentPerform(iterations: 10000) { index in
      layer.update(force: index == 50)
    }
  } else {
    for _ in 0..<10000 { layer.update() }
  }
  release.signal()
  flush(layer)
  check(layer.forces.count == 1, "\(forced ? "D3" : "D2") 10000 requests -> \(layer.forces.count) display(s)")
  check(layer.forces.first == forced, "\(forced ? "D3" : "D2") force flag preserved")
}

// D4: Requests made after consumption of the first request must schedule a successor.
do {
  let layer = RecordingLayer(view)
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  layer.entered = entered
  layer.release = release
  layer.update()
  check(entered.wait(timeout: .now() + 3) == .success, "D4 first display running")
  for index in 0..<10000 { layer.update(force: index == 50) }
  release.signal()
  flush(layer)
  check(layer.forces == [false, true], "D4 one successor, with force retained (count=\(layer.forces.count))")
}

// D5: Exercise real canDraw and display after shutdown, with no render context.
do {
  let layer = ViewLayer(view)
  let ctx: CGLContextObj = field(layer, "cglContext")
  let pf: CGLPixelFormatObj = field(layer, "cglPixelFormat")
  check(!layer.canDraw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: 0, displayTime: nil),
        "D5 stopped view cannot draw")
  layer.update(force: true)
  flush(layer)
  check(view.isUninited, "D5 forced update after shutdown returns safely")
}
// D6: The mpv boundary resets GL state; the layer must return the caller's exact bindings.
do {
  let layer = ViewLayer(view)
  let ctx: CGLContextObj = field(layer, "cglContext")
  let pf: CGLPixelFormatObj = field(layer, "cglPixelFormat")
  CGLSetCurrentContext(ctx)
  var textures = [GLuint](repeating: 0, count: 2)
  var framebuffers = [GLuint](repeating: 0, count: 2)
  glGenTextures(2, &textures)
  glGenFramebuffers(2, &framebuffers)
  for index in 0..<2 {
    glBindTexture(GLenum(GL_TEXTURE_2D), textures[index])
    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, 16, 16, 0,
                 GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffers[index])
    glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                           GLenum(GL_TEXTURE_2D), textures[index], 0)
    check(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE),
          "D6 fixture framebuffer \(index) complete")
  }
  glBindTexture(GLenum(GL_TEXTURE_2D), 0)
  glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), framebuffers[0])
  glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), framebuffers[1])
  glViewport(0, 0, 16, 16)
  view.isUninited = false
  view.player.mpv.mpvRenderContext = OpaquePointer(bitPattern: 1)
  let before = iina_test_render_calls()
  layer.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: 0, displayTime: nil)
  check(iina_test_render_calls() == before + 1, "D6 mpv boundary substitute invoked")
  var draw: GLint = 0
  var read: GLint = 0
  glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &draw)
  glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &read)
  check(draw == GLint(framebuffers[0]), "D6 draw framebuffer restored: \(draw) == \(framebuffers[0])")
  check(read == GLint(framebuffers[1]), "D6 read framebuffer restored: \(read) == \(framebuffers[1])")
  view.player.mpv.mpvRenderContext = nil
  view.isUninited = true
  glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
  glDeleteFramebuffers(2, &framebuffers)
  glDeleteTextures(2, &textures)
}

print("Dynamic test failures: \(failures)")
exit(failures == 0 ? 0 : 1)
