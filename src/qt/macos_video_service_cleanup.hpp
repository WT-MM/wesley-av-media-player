#pragma once

namespace wam::qt {
// macOS 26 drawable/XPC lifetime workaround. Call only after QApplication,
// every renderer, and all background native graph destruction have finished.
void finishMacosVideoServices() noexcept;
}
