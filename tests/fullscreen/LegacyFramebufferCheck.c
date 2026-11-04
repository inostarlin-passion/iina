// Check the binding entry points used by the fix in a real legacy compatibility context.
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>

int main(void) {
  CGLPixelFormatAttribute attributes[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy,
    kCGLPFAAccelerated, kCGLPFADoubleBuffer, 0
  };
  CGLPixelFormatObj format = NULL;
  CGLContextObj context = NULL;
  GLint count = 0;
  CGLError result = CGLChoosePixelFormat(attributes, &format, &count);
  if (result || !format || CGLCreateContext(format, NULL, &context)) {
    if (format) CGLDestroyPixelFormat(format);
    puts("SKIP legacy context unavailable");
    return 2;
  }
  CGLSetCurrentContext(context);
  const GLubyte *version = glGetString(GL_VERSION);
  printf("version=%s\n", version ? (const char *)version : "unknown");
  GLuint framebuffers[2] = {0, 0};
  glGenFramebuffers(2, framebuffers);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffers[0]);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffers[1]);
  GLint draw = 0, read = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
  GLenum error = glGetError();
  int passed = framebuffers[0] && framebuffers[1] && framebuffers[0] != framebuffers[1]
    && draw == (GLint)framebuffers[0] && read == (GLint)framebuffers[1] && error == GL_NO_ERROR;
  printf("legacy framebuffer binding APIs: %s (draw=%d read=%d error=%u)\n",
         passed ? "PASS" : "FAIL", draw, read, error);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glDeleteFramebuffers(2, framebuffers);
  CGLSetCurrentContext(NULL);
  CGLDestroyContext(context);
  CGLDestroyPixelFormat(format);
  return passed ? 0 : 1;
}
