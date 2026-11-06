#pragma once
#include <functional>
#include <string>
namespace wam {
// Called on the UI thread. Completion runs on that same thread: asynchronously
// from the sheet, or synchronously with false when there is no window to host it.
void showCaptionDownloadPrompt(const std::string& locale, std::function<void(bool)> completion);
}
