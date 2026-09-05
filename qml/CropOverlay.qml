pragma ComponentBehavior: Bound

import QtQuick

// The Quick Edit crop rectangle, drawn over the picture.
//
// WHAT THIS IS AND IS NOT. The rectangle is applied at EXPORT, by FFmpeg's
// `crop` filter, and not to live playback -- so this overlay is not a preview
// OF the crop, it IS the preview: the bright region is exactly what the
// exported file will contain, and the dimmed region is exactly what it will
// not. The sheet says so in words; this file is the reason that sentence is
// true. (A live playback crop looks cheap on the layer presentation route --
// AVSampleBufferDisplayLayer has a `contentsRect` that would do it in the
// compositor for free -- but it is not wired here, and gating the feature on
// it would have shipped nothing. See the report's deferrals.)
//
// COORDINATES. The rectangle is stored NORMALIZED (0-1 fractions of the source
// frame) on the controller, and manipulated here in the displayed video's
// pixels. Those two are related by one linear map per axis, so a fraction of
// the displayed width is exactly the same fraction of the coded width -- which
// is what makes this correct for anamorphic sources too, where the horizontal
// and vertical scales differ. No dimension is ever probed and no display scale
// enters the exported geometry.
Item {
    id: overlay

    required property var player
    // The source's DISPLAY size (controller.videoDisplaySize). Its aspect
    // places the rectangle; its absolute numbers appear only in the readout.
    property size sourceSize: Qt.size(0, 0)
    // 0 = free. Otherwise the locked width/height ratio, in displayed pixels,
    // which is the ratio the viewer actually sees.
    property real lockedAspect: 0
    // True while any handle or the interior is being dragged. Drives the
    // rule-of-thirds guides.
    property bool interacting: false

    // The smallest rectangle the export will accept, as a fraction. Matches
    // the clamp in wam::cropFilter and PlayerController::setCrop, so the
    // overlay can never draw a rectangle the encoder would refuse.
    readonly property real minimumFraction: 0.02

    // ---------------------------------------------------------------------
    // The item the picture is drawn in. This overlay lives in the safe-area
    // `stage`, while the video item runs the full window under the
    // transparent titlebar, so the picture's box is MEASURED from that item
    // rather than assumed to be this one: anchoring to the stage put the
    // rectangle a titlebar's inset off the picture.
    property Item videoItem: null
    readonly property rect videoBox: videoItem
        ? overlay.mapFromItem(videoItem, 0, 0, videoItem.width, videoItem.height)
        : Qt.rect(0, 0, width, height)

    // The letterboxed video rectangle inside that box. The video item centres
    // the picture inside itself, so the crop surface repeats that arithmetic
    // or the rectangle would be drawn against the box instead of the image.
    readonly property real sourceAspect: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 0
    readonly property real boxAspect: videoBox.height > 0 ? videoBox.width / videoBox.height : 0
    readonly property real videoWidth: sourceAspect <= 0 ? videoBox.width : (sourceAspect > boxAspect ? videoBox.width : videoBox.height * sourceAspect)
    readonly property real videoHeight: sourceAspect <= 0 ? videoBox.height : (sourceAspect > boxAspect ? videoBox.width / sourceAspect : videoBox.height)
    readonly property real videoX: videoBox.x + (videoBox.width - videoWidth) / 2
    readonly property real videoY: videoBox.y + (videoBox.height - videoHeight) / 2

    // The live rectangle in overlay pixels, derived from the controller. The
    // controller is the single source of truth: a drag writes through to it
    // and reads back, so the overlay can never drift from what will be
    // exported.
    readonly property real rectX: videoX + overlay.player.cropX * videoWidth
    readonly property real rectY: videoY + overlay.player.cropY * videoHeight
    readonly property real rectW: overlay.player.cropWidth * videoWidth
    readonly property real rectH: overlay.player.cropHeight * videoHeight

    // Writes a rectangle given in overlay pixels. Everything -- clamping to
    // the frame and to the minimum size -- is resolved before it reaches the
    // controller, which then applies the identical clamp itself.
    function commitPixels(px, py, pw, ph) {
        if (videoWidth <= 0 || videoHeight <= 0)
            return;
        const minW = overlay.minimumFraction * videoWidth;
        const minH = overlay.minimumFraction * videoHeight;
        const w = Math.max(minW, Math.min(pw, videoWidth));
        const h = Math.max(minH, Math.min(ph, videoHeight));
        const x = Math.max(0, Math.min(px - videoX, videoWidth - w));
        const y = Math.max(0, Math.min(py - videoY, videoHeight - h));
        overlay.player.setCrop(x / videoWidth, y / videoHeight, w / videoWidth, h / videoHeight);
    }

    // Applies the aspect lock to a candidate rectangle, holding the corner
    // named by (anchorRight, anchorBottom) still so a drag grows away from the
    // edge the user is NOT holding. Returns the rectangle in overlay pixels.
    function lockAspect(x, y, w, h, anchorRight, anchorBottom) {
        if (overlay.lockedAspect <= 0)
            return Qt.rect(x, y, w, h);
        // Fit the locked ratio INSIDE the candidate box rather than stretching
        // to it, so a constrained drag can never push the rectangle out of the
        // frame.
        let lw = w;
        let lh = w / overlay.lockedAspect;
        if (lh > h) {
            lh = h;
            lw = h * overlay.lockedAspect;
        }
        const nx = anchorRight ? x + w - lw : x;
        const ny = anchorBottom ? y + h - lh : y;
        return Qt.rect(nx, ny, lw, lh);
    }

    // Re-imposes the lock on whatever is currently stored, so picking a preset
    // takes effect at once instead of waiting for the next drag.
    function applyAspectNow() {
        if (overlay.lockedAspect <= 0 || overlay.videoWidth <= 0)
            return;
        const fitted = overlay.lockAspect(overlay.rectX, overlay.rectY, overlay.rectW, overlay.rectH, false, false);
        overlay.commitPixels(fitted.x, fitted.y, fitted.width, fitted.height);
    }

    onLockedAspectChanged: overlay.applyAspectNow()

    Accessible.role: Accessible.Grouping
    Accessible.name: "Crop rectangle"

    // ---------------------------------------------------------------------
    // The dim: four bands around the selection rather than one masked shape.
    // No shader, no clipping, no per-frame repaint -- each band's geometry is
    // a binding, so the scene graph moves four quads while a drag is live and
    // does nothing at all when it is not.
    Repeater {
        model: 4

        Rectangle {
            required property int index
            color: "#8c000000"
            visible: overlay.rectW > 0 && overlay.rectH > 0
            // 0 above, 1 below, 2 left, 3 right. The side bands span only the
            // selection's own height so the four never overlap (overlapping
            // translucent bands would darken the corners twice).
            x: index === 3 ? overlay.rectX + overlay.rectW : overlay.videoX
            y: index === 0 ? overlay.videoY : (index === 1 ? overlay.rectY + overlay.rectH : overlay.rectY)
            width: index === 2 ? Math.max(0, overlay.rectX - overlay.videoX) : (index === 3 ? Math.max(0, overlay.videoX + overlay.videoWidth - (overlay.rectX + overlay.rectW)) : overlay.videoWidth)
            height: index === 0 ? Math.max(0, overlay.rectY - overlay.videoY) : (index === 1 ? Math.max(0, overlay.videoY + overlay.videoHeight - (overlay.rectY + overlay.rectH)) : overlay.rectH)
        }
    }

    // ---------------------------------------------------------------------
    // The selection: a hairline border, thirds guides while dragging, and a
    // drag-to-move interior.
    Rectangle {
        id: frame
        x: overlay.rectX
        y: overlay.rectY
        width: overlay.rectW
        height: overlay.rectH
        color: "transparent"
        border.width: 1
        border.color: "#f2ffffff"

        // Thirds guides, only while a drag is live: permanent guides turn the
        // picture into graph paper, and the composition help is only wanted
        // while the composition is being chosen.
        Repeater {
            model: 4

            Rectangle {
                required property int index
                readonly property bool vertical: index < 2
                color: "#59ffffff"
                visible: overlay.interacting
                width: vertical ? 1 : frame.width
                height: vertical ? frame.height : 1
                x: vertical ? Math.round(frame.width * (index + 1) / 3) : 0
                y: vertical ? 0 : Math.round(frame.height * (index - 1) / 3)
            }
        }

        // Drag anywhere inside to move the whole rectangle. `drag.target` is
        // deliberately not used: the frame's geometry is a binding on the
        // controller, so letting the drag system move the item directly would
        // fight that binding. The press offset is remembered and the
        // controller is written on each move instead.
        MouseArea {
            id: moveArea
            anchors.fill: parent
            cursorShape: Qt.SizeAllCursor
            property real pressX: 0
            property real pressY: 0
            property bool moving: false
            onPressed: mouse => {
                pressX = mouse.x;
                pressY = mouse.y;
                moving = true;
                overlay.interacting = true;
            }
            onReleased: {
                moving = false;
                overlay.interacting = false;
            }
            onCanceled: {
                moving = false;
                overlay.interacting = false;
            }
            onPositionChanged: mouse => {
                if (!moving)
                    return;
                const global = mapToItem(overlay, mouse.x, mouse.y);
                overlay.commitPixels(global.x - pressX, global.y - pressY, overlay.rectW, overlay.rectH);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Eight handles. `gx`/`gy` in {-1, 0, 1} name which edges a handle moves:
    // -1 the leading edge, +1 the trailing edge, 0 neither. That one encoding
    // covers corners and edges with a single drag implementation instead of
    // eight near-identical ones.
    Repeater {
        model: [
            {
                gx: -1,
                gy: -1
            },
            {
                gx: 1,
                gy: -1
            },
            {
                gx: -1,
                gy: 1
            },
            {
                gx: 1,
                gy: 1
            },
            {
                gx: 0,
                gy: -1
            },
            {
                gx: 0,
                gy: 1
            },
            {
                gx: -1,
                gy: 0
            },
            {
                gx: 1,
                gy: 0
            }
        ]

        Item {
            id: handle
            required property var modelData
            readonly property int gx: modelData.gx
            readonly property int gy: modelData.gy
            // Generous hit target; the drawn grip inside is smaller. A handle
            // the size of its own pixels is a handle nobody can grab.
            readonly property real span: 16

            width: gx === 0 ? Math.max(0, overlay.rectW - span) : span
            height: gy === 0 ? Math.max(0, overlay.rectH - span) : span
            x: gx === 0 ? overlay.rectX + span / 2 : (gx < 0 ? overlay.rectX - span / 2 : overlay.rectX + overlay.rectW - span / 2)
            y: gy === 0 ? overlay.rectY + span / 2 : (gy < 0 ? overlay.rectY - span / 2 : overlay.rectY + overlay.rectH - span / 2)

            Rectangle {
                anchors.centerIn: parent
                width: handle.gx === 0 ? Math.min(30, handle.width) : 10
                height: handle.gy === 0 ? Math.min(30, handle.height) : 10
                radius: 2
                color: "#ffffff"
                border.width: 1
                border.color: "#40000000"
                visible: handle.width > 0 && handle.height > 0
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: handle.gx === 0 ? Qt.SizeVerCursor : (handle.gy === 0 ? Qt.SizeHorCursor : (handle.gx === handle.gy ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor))
                property bool active: false
                onPressed: {
                    active = true;
                    overlay.interacting = true;
                }
                onReleased: {
                    active = false;
                    overlay.interacting = false;
                }
                onCanceled: {
                    active = false;
                    overlay.interacting = false;
                }
                onPositionChanged: mouse => {
                    if (!active)
                        return;
                    const p = mapToItem(overlay, mouse.x, mouse.y);
                    let left = overlay.rectX;
                    let top = overlay.rectY;
                    let right = overlay.rectX + overlay.rectW;
                    let bottom = overlay.rectY + overlay.rectH;
                    if (handle.gx < 0)
                        left = Math.min(p.x, right - overlay.minimumFraction * overlay.videoWidth);
                    else if (handle.gx > 0)
                        right = Math.max(p.x, left + overlay.minimumFraction * overlay.videoWidth);
                    if (handle.gy < 0)
                        top = Math.min(p.y, bottom - overlay.minimumFraction * overlay.videoHeight);
                    else if (handle.gy > 0)
                        bottom = Math.max(p.y, top + overlay.minimumFraction * overlay.videoHeight);
                    // Hold the corner the user is NOT dragging: a west drag
                    // grows leftward from the fixed east edge, and so on.
                    const fitted = overlay.lockAspect(left, top, right - left, bottom - top, handle.gx < 0, handle.gy < 0);
                    overlay.commitPixels(fitted.x, fitted.y, fitted.width, fitted.height);
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // The readout: the exported pixel size, rounded DOWN to even exactly as
    // wam::cropFilter rounds it, so the number here is the number ffprobe will
    // report on the finished file. Sits just above the rectangle, and flips
    // inside it when there is no room above.
    Rectangle {
        id: sizeChip
        readonly property int outWidth: 2 * Math.floor(overlay.player.cropWidth * overlay.sourceSize.width / 2)
        readonly property int outHeight: 2 * Math.floor(overlay.player.cropHeight * overlay.sourceSize.height / 2)
        visible: overlay.sourceSize.width > 0 && overlay.rectW > 0
        x: overlay.rectX
        y: overlay.rectY > 26 ? overlay.rectY - 26 : overlay.rectY + 6
        width: sizeLabel.implicitWidth + 12
        height: 20
        radius: 3
        color: "#b3000000"

        Text {
            id: sizeLabel
            anchors.centerIn: parent
            text: sizeChip.outWidth + " × " + sizeChip.outHeight
            color: "#ffffff"
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }
}
