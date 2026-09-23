#pragma once
#include <functional>
#include <string>
namespace wam {
// Called on the UI thread. Completion is asynchronous on that same thread.
void showCaptionDownloadPrompt(const std::string& locale, std::function<void(bool)> completion);
}
