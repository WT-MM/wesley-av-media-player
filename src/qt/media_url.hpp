#pragma once

#include <QString>
#include <QUrl>

namespace wam::qt {

// The URL a command-line or Finder argument names. Path-shaped arguments and
// bare filenames with a media extension stay local -- even when missing, so a
// typo is reported as a missing file rather than becoming a network request
// -- while explicit URLs and unmistakable web hosts become remote URLs.
[[nodiscard]] QUrl mediaUrlFromArgument(const QString &argument);

} // namespace wam::qt
