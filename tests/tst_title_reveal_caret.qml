import QtQuick
import QtTest
import "../qml" as Wam

// Structure tests for the title band's reveal-in-Finder caret.
//
// Like tst_scrubber.qml, this is NOT wired into ctest -- the repo has no
// qmltestrunner target -- so it is run by hand:
//
//   /opt/homebrew/opt/qtdeclarative/bin/qmltestrunner \
//     -input /Users/wesleymaa/Documents/WAM/tests/tst_title_reveal_caret.qml
//
// Two things are covered, and the split is deliberate.
//
//  * ChromeToolTip's new `below` placement is exercised against the real
//    component. It matters: the titlebar band starts at the window's own top
//    edge, so the ordinary above-the-button placement puts the tip at a
//    negative y -- outside the window, invisible. Nothing else in the app
//    uses `below`, so nothing else would catch a regression in it.
//
//  * The caret's visibility gate is exercised as a *mirror* of the
//    `root.titleRevealable` expression in qml/Main.qml, not as the binding
//    itself: the binding lives on an ApplicationWindow that needs the
//    `controller`, `windowChrome` and `revealInFinderSupported` context
//    properties, and instantiating one here would open a real window. The
//    mirror pins the case table (no media, local file, http, https, a path
//    with spaces); the real binding is evidenced separately by running the
//    app against each of those sources. Keep the two in step.
Item {
    id: root
    width: 400
    height: 200

    // The exact expression from qml/Main.qml's `titleRevealable`, with the
    // context property and the controller lifted into arguments.
    function titleRevealable(supported, hasMedia, source) {
        return supported && hasMedia && String(source).startsWith("file:");
    }

    // Both hosts sit well inside `root` on purpose. A ToolTip is a Popup, and
    // a Popup clamps itself back inside its window: hosted at (0, 0) the
    // *above* placement lands off-window and comes back clamped, so the test
    // would be measuring the clamp instead of reposition(). Hosting at the
    // middle of a 400x200 root leaves both placements in bounds.
    readonly property real hostX: 180
    readonly property real hostY: 90

    Component {
        id: tipComponent

        Item {
            x: root.hostX
            y: root.hostY
            width: 22
            height: 22

            property alias tip: innerTip

            Wam.ChromeToolTip {
                id: innerTip
                text: "Show in Finder"
                below: true
            }
        }
    }

    Component {
        id: aboveTipComponent

        Item {
            x: root.hostX
            y: root.hostY
            width: 22
            height: 22

            property alias tip: innerTip

            Wam.ChromeToolTip {
                id: innerTip
                text: "Show in Finder"
            }
        }
    }

    TestCase {
        name: "TitleRevealCaret"
        when: windowShown

        function test_gate_data() {
            return [
                {
                    tag: "no media",
                    supported: true, hasMedia: false, source: "",
                    expected: false
                },
                {
                    tag: "local file",
                    supported: true, hasMedia: true,
                    source: "file:///Users/x/Movies/clip.mp4",
                    expected: true
                },
                {
                    tag: "local file with spaces",
                    supported: true, hasMedia: true,
                    source: "file:///Users/x/My%20Movies/a%20clip.mkv",
                    expected: true
                },
                {
                    tag: "http stream",
                    supported: true, hasMedia: true,
                    source: "http://example.com/stream/clip.mp4",
                    expected: false
                },
                {
                    tag: "https stream",
                    supported: true, hasMedia: true,
                    source: "https://example.com/stream/clip.mp4",
                    expected: false
                },
                {
                    // A stream whose host happens to start with the letters
                    // of the scheme we accept. startsWith("file:") -- with
                    // the colon -- is what keeps this out.
                    tag: "https host named file",
                    supported: true, hasMedia: true,
                    source: "https://filestore.example.com/clip.mp4",
                    expected: false
                },
                {
                    // hasMedia false but a stale-looking source: the gate
                    // must fall on hasMedia alone.
                    tag: "no media, stale source",
                    supported: true, hasMedia: false,
                    source: "file:///Users/x/Movies/clip.mp4",
                    expected: false
                },
                {
                    // Non-macOS build: the reveal has no implementation, so
                    // the affordance must not be offered at all.
                    tag: "unsupported platform",
                    supported: false, hasMedia: true,
                    source: "file:///Users/x/Movies/clip.mp4",
                    expected: false
                }
            ];
        }

        function test_gate(data) {
            compare(root.titleRevealable(data.supported, data.hasMedia,
                                         data.source),
                    data.expected, data.tag);
        }

        function test_toolTipBelowHangsUnderItsButton() {
            const host = createTemporaryObject(tipComponent, root);
            verify(host !== null, "the tooltip host must instantiate");
            const tip = host.tip;
            tip.visible = true;
            tryCompare(tip, "visible", true);
            verify(tip.height > 0, "the tip must have laid out");

            // Below the button, by the component's own gap, and horizontally
            // centred on it.
            compare(tip.y, host.height + tip.gap,
                    "the tip hangs under the button");
            verify(tip.y > 0,
                   "a tip in the titlebar band must stay inside the window");
            fuzzyCompare(tip.x, (host.width - tip.width) / 2, 0.5,
                         "the tip stays centred on the button");
        }

        function test_toolTipDefaultStillSitsAbove() {
            // The placement the rest of the chrome relies on is unchanged.
            const host = createTemporaryObject(aboveTipComponent, root);
            verify(host !== null, "the tooltip host must instantiate");
            const tip = host.tip;
            compare(tip.below, false, "above is still the default");
            tip.visible = true;
            tryCompare(tip, "visible", true);
            verify(tip.height > 0, "the tip must have laid out");
            compare(tip.y, -tip.height - tip.gap,
                    "the default placement is unchanged");
        }
    }
}
