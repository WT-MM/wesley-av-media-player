import QtQuick
import QtTest
import "../qml" as Wam

// ChromeToolTip's `below` placement, exercised against the real component.
// The titlebar band starts at the window's own top edge, so the ordinary
// above-the-button placement puts the tip at a negative y, outside the window.
// Only the reveal-in-Finder caret uses `below`.
Item {
    id: root
    width: 400
    height: 200

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
