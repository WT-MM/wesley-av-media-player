#include "media_url.hpp"

#include "media/media_container_routing.hpp"

#include <QByteArrayView>
#include <QDir>
#include <QFileInfo>

#include <algorithm>
#include <string_view>

namespace wam::qt {

QUrl mediaUrlFromArgument(const QString &argument) {
  QString local_argument = argument;
  if (local_argument == QStringLiteral("~")) {
    local_argument = QDir::homePath();
  } else if (local_argument.startsWith(QStringLiteral("~/")) ||
             local_argument.startsWith(QStringLiteral("~\\"))) {
    local_argument = QDir::homePath() + local_argument.sliced(1);
  }

  // QUrl::fromUserInput treats an unqualified relative path as an HTTP host.
  // Resolve local/path-shaped arguments first, including typos, so WAM can
  // report a local-file error without making an unexpected network request.
  const QFileInfo local_candidate(local_argument);
  if (local_candidate.exists() || QDir::isAbsolutePath(local_argument))
    return QUrl::fromLocalFile(local_candidate.absoluteFilePath());

  const QUrl explicit_url(argument);
  if (!explicit_url.scheme().isEmpty())
    return QUrl::fromUserInput(argument);

  // A bare argument with a suffix the open dialog offers stays a local path,
  // so a missing file is reported as missing rather than falling through to
  // the web-host heuristic below and opening as a URL.
  const QByteArray suffix = local_candidate.suffix().toLatin1().toLower();
  const bool known_media_extension = std::ranges::any_of(
      wam::media::kMediaFileExtensions,
      [&suffix](const wam::media::MediaFileExtensionRow &row) {
        const std::string_view value = row.extension.substr(1);
        return suffix == QByteArrayView(value.data(),
                                        static_cast<qsizetype>(value.size()));
      });
  const qsizetype forward_slash = local_argument.indexOf(QLatin1Char('/'));
  const qsizetype back_slash = local_argument.indexOf(QLatin1Char('\\'));
  qsizetype first_separator = -1;
  if (forward_slash >= 0 && back_slash >= 0)
    first_separator = std::min(forward_slash, back_slash);
  else
    first_separator = std::max(forward_slash, back_slash);

  const QString authority = first_separator >= 0
                                ? local_argument.first(first_separator)
                                : local_argument;
  const bool unmistakable_web_host =
      authority.startsWith(QStringLiteral("www."), Qt::CaseInsensitive) ||
      authority.compare(QStringLiteral("localhost"), Qt::CaseInsensitive) ==
          0 ||
      (first_separator >= 0 && authority.contains(QLatin1Char('.')));
  if (unmistakable_web_host)
    return QUrl::fromUserInput(QStringLiteral("http://") + local_argument);

  // A bare missing media filename must remain local. QUrl::fromUserInput can
  // otherwise mistake its extension (for example, ".mp4") for a web TLD.
  if (first_separator >= 0 || known_media_extension) {
    return QUrl::fromLocalFile(local_candidate.absoluteFilePath());
  }

  const QUrl inferred_url = QUrl::fromUserInput(argument);
  if (inferred_url.isValid())
    return inferred_url;
  return {};
}

} // namespace wam::qt
