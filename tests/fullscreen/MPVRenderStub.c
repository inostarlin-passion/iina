// Boundary substitute for mechanism tests only. Models the documented mpv default-state cleanup.
#include <mpv/render_gl.h>
#include <OpenGL/gl3.h>
static int calls;
int iina_test_render_calls(void) { return calls; }
int mpv_render_context_render(mpv_render_context *context, mpv_render_param *params) {
  (void)context;
  (void)params;
  calls++;
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  return 0;
}
