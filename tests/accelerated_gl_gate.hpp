#pragma once

#include <OpenGL/OpenGL.h>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <cstdio>

// The Qt GL video item refuses a non-accelerated CGL pixel format, so the
// display-route tests cannot pass on a host without one (hosted CI VMs).
// Returns 77, ctest's skip code, when the default format is not accelerated.
inline int skipUnlessAcceleratedGl() {
  QOffscreenSurface surface;
  surface.create();
  QOpenGLContext context;
  if (!context.create() || !context.makeCurrent(&surface)) {
    std::puts("SKIP: no OpenGL context can be created on this host");
    return 77;
  }
  GLint virtualScreen = 0;
  GLint accelerated = 0;
  CGLContextObj cgl = CGLGetCurrentContext();
  const bool ok = cgl != nullptr &&
                  CGLGetVirtualScreen(cgl, &virtualScreen) == kCGLNoError &&
                  CGLDescribePixelFormat(CGLGetPixelFormat(cgl), virtualScreen,
                                         kCGLPFAAccelerated, &accelerated) == kCGLNoError;
  context.doneCurrent();
  if (!ok || accelerated == 0) {
    std::puts("SKIP: CGL offers no accelerated renderer on this host");
    return 77;
  }
  return 0;
}
