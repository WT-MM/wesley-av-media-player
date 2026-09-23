#include "caption_download_prompt.hpp"
#import <AppKit/AppKit.h>
namespace wam {
void showCaptionDownloadPrompt(const std::string& locale, std::function<void(bool)> completion) {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Download a language for on-device captions?";
  NSString *identifier = [NSString stringWithUTF8String:locale.c_str()];
  NSString *language = [[NSLocale currentLocale] localizedStringForLocaleIdentifier:identifier] ?: identifier;
  alert.informativeText = [NSString stringWithFormat:@"Apple Speech needs a one-time on-device download for %@. Apple manages the download; its size is unknown. You can cancel while it downloads. Choose Use Whisper to caption with the bundled engine now.", language];
  [alert addButtonWithTitle:@"Download language"];
  [alert addButtonWithTitle:@"Use Whisper"];
  NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
  if (!window) { completion(false); return; }
  [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
    completion(response == NSAlertFirstButtonReturn);
  }];
}
}
