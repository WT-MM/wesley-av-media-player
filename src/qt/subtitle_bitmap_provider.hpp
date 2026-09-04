#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QQuickImageProvider>
#include <QString>

QT_BEGIN_NAMESPACE
class QQmlEngine;
QT_END_NAMESPACE

// The bitmap subtitle overlay's image path.
//
// A PGS or VobSub cue is a picture, not a string, so it cannot travel to QML on
// a text property. It travels instead as an image:// URL that a QQuickImageProvider
// resolves out of a small process-wide store, which is the mechanism Qt provides
// for handing a QImage produced in C++ to a declarative Image element.
//
// WHY A STORE AND NOT A PROVIDER PER WINDOW. An image provider is owned by the
// QML engine and there is exactly one engine for every window this app opens, so
// a provider cannot hold a window's state. The provider is therefore a thin
// adapter over a keyed store: each PlayerController publishes under its own key
// and the URL names that key, so two windows showing two different films cannot
// see each other's captions.
namespace wam::qt {

class SubtitleBitmapStore {
public:
  [[nodiscard]] static SubtitleBitmapStore &instance();

  // Publishes the image a window currently shows. A null image means "nothing",
  // which is cheaper than erasing and re-inserting on every cue turnover.
  void publish(quint64 key, const QImage &image);
  // Called when a window goes away, so its last caption is not retained.
  void forget(quint64 key);
  [[nodiscard]] QImage lookup(quint64 key) const;

private:
  SubtitleBitmapStore() = default;

  mutable QMutex mutex_;
  QHash<quint64, QImage> images_;
};

class SubtitleBitmapProvider final : public QQuickImageProvider {
public:
  SubtitleBitmapProvider();

  // The URL authority: image://<name>/<key>/<serial>. The serial exists only to
  // defeat QML's image cache -- the same key with new pixels must not be served
  // from the cache -- and is ignored when resolving.
  [[nodiscard]] static QString name();
  // Builds the URL for a key and serial. Kept next to the parser so the two
  // cannot drift.
  [[nodiscard]] static QString urlFor(quint64 key, quint64 serial);

  QImage requestImage(const QString &id, QSize *size,
                      const QSize &requestedSize) override;
};

// Registers the provider on `engine`, which takes ownership. Call once.
void registerSubtitleBitmapProvider(QQmlEngine &engine);

}  // namespace wam::qt
