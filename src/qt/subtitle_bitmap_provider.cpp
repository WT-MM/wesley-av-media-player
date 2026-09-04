#include "qt/subtitle_bitmap_provider.hpp"

#include <QQmlEngine>
#include <QStringView>

namespace wam::qt {
namespace {

constexpr const char *kProviderName = "wamSubtitleBitmap";

}  // namespace

SubtitleBitmapStore &SubtitleBitmapStore::instance() {
  static SubtitleBitmapStore store;
  return store;
}

void SubtitleBitmapStore::publish(quint64 key, const QImage &image) {
  QMutexLocker locker(&mutex_);
  images_.insert(key, image);
}

void SubtitleBitmapStore::forget(quint64 key) {
  QMutexLocker locker(&mutex_);
  images_.remove(key);
}

QImage SubtitleBitmapStore::lookup(quint64 key) const {
  QMutexLocker locker(&mutex_);
  const auto it = images_.constFind(key);
  return it == images_.constEnd() ? QImage() : *it;
}

SubtitleBitmapProvider::SubtitleBitmapProvider()
    : QQuickImageProvider(QQuickImageProvider::Image) {}

QString SubtitleBitmapProvider::name() {
  return QString::fromLatin1(kProviderName);
}

QString SubtitleBitmapProvider::urlFor(quint64 key, quint64 serial) {
  return QStringLiteral("image://%1/%2/%3")
      .arg(QString::fromLatin1(kProviderName))
      .arg(key)
      .arg(serial);
}

QImage SubtitleBitmapProvider::requestImage(const QString &id, QSize *size,
                                            const QSize &requestedSize) {
  // id is "<key>/<serial>"; only the key selects the image.
  const qsizetype slash = id.indexOf(QLatin1Char('/'));
  const QStringView keyText =
      slash < 0 ? QStringView(id) : QStringView(id).left(slash);
  bool ok = false;
  const quint64 key = keyText.toULongLong(&ok);
  QImage image = ok ? SubtitleBitmapStore::instance().lookup(key) : QImage();
  if (image.isNull()) {
    // A 1x1 transparent pixel rather than a null image: a null return makes QML
    // log an error for what is simply "no caption right now".
    image = QImage(1, 1, QImage::Format_ARGB32);
    image.fill(Qt::transparent);
  }
  if (size != nullptr) {
    *size = image.size();
  }
  // The overlay scales the image itself, against the video rectangle. Honouring
  // a requestedSize here would resample twice and soften the glyph edges, so it
  // is deliberately ignored.
  Q_UNUSED(requestedSize);
  return image;
}

void registerSubtitleBitmapProvider(QQmlEngine &engine) {
  engine.addImageProvider(QString::fromLatin1(kProviderName),
                          new SubtitleBitmapProvider());
}

}  // namespace wam::qt
