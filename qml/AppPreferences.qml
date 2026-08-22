import QtQuick

// The application's ONE Preferences window.
//
// Every setting this panel offers is app-level: one persisted value, applied
// live to every open player window (WindowManager mirrors each change onto
// every other controller and into the state store). So there is exactly one
// panel, owned by the application rather than by any window, and it keeps
// working when the window it was opened from is closed underneath it.
//
// It still drives a real PlayerController, because that is the object the
// settings live on -- and since they are mirrored, ANY live controller is an
// equally valid view of them. `liveController` therefore latches the most
// recently focused non-null one instead of following focus into null.
PreferencesWindow {
    id: prefs

    // Seeded by WindowManager::showPreferences through
    // QQmlComponent::createWithInitialProperties, which is the one mechanism
    // that lands a value BEFORE any binding in the component is evaluated.
    // Neither a declarative binding on this property nor a Component.onCompleted
    // assignment is early enough: the controls below evaluate their own
    // bindings first and spend their first frame reading properties off null.
    property var liveController: null

    player: prefs.liveController
    dark: appHost.darkAppearance

    // Called by WindowManager::showPreferences() on both the first and every
    // later invocation: the first creates this object, later ones just raise
    // the panel that already exists.
    function presentPreferences() {
        prefs.show();
        prefs.raise();
        prefs.requestActivate();
    }

    Connections {
        target: appHost
        function onFocusChanged() {
            // Follow focus, INCLUDING into null. Latching the previous
            // controller would be latching an object that is about to be
            // destroyed -- QML nulls a var holding a deleted QObject anyway,
            // so the latch buys nothing and hides the real state. With no
            // window open the panel legitimately has no controller, and
            // PreferencesWindow disables its controls for exactly that.
            prefs.liveController = appHost.focusedController;
        }
    }
}
