# Product design

This document is the version-controlled source of truth for WAM's interface.
It records the product intent and the design constraints that should govern new
surfaces, controls, and interaction changes.

## Product purpose

WAM opens, plays, transforms, captions, and exports audiovisual media in one
exceptionally fast cross-platform desktop application.

## Primary user

A media-heavy power user on macOS, Windows, or Linux who frequently watches and
lightly edits varied formats and expects immediate keyboard-driven control.

## Principles

These principles are listed in conflict-resolution order: when two principles
compete, the earlier one wins.

1. **The media is the interface.** Playback content dominates; chrome stays
   compact, translucent, and temporary.
2. **Responsiveness is visible quality.** Controls react immediately, animation
   stays brief, and decorative work never competes with playback performance.
3. **Complexity appears on demand.** Editing and advanced tools are easy to
   summon, easy to dismiss, and never permanently shrink the viewing surface.
4. **Native does not mean old-fashioned.** Keep platform conventions that aid
   familiarity while removing boxed toolbars, heavy borders, and ornamental
   UI.

## Success criterion

From the empty player, a user can open or drop media in one action. During
playback, the content becomes visually primary again after five seconds without
pointer movement, or immediately when the pointer leaves the player window.

## Explicit exclusions

- Do not place persistent onboarding copy over the empty player.
- Do not keep editing panels open when they are not needed.
- Do not use decorative accent color to create hierarchy.
- Do not imitate legacy desktop toolbars or bordered control strips.

## Learned constraints

- **2026-08-10 — Default to a considered light appearance, with dark mode
  available as an explicit option.** A dark-first player feels unnecessarily
  heavy outside the media itself.
- **2026-08-10 — Playback controls must be slim, translucent, borderless, and
  quick to fade when attention returns to the media.** Large or persistent
  chrome makes the viewing surface feel smaller.
- **2026-08-10 — Avoid blue as WAM's default accent and keep neutral surfaces
  dominant.** Blue felt generic and visually disconnected from the restrained
  player.
- **2026-08-10 — The empty player uses one faint icon without instructional
  text, and that icon must not be a play triangle.** The state is waiting for
  media input, not offering playback; an audiovisual or import mark communicates
  the correct action.
- **2026-08-11 — Playback chrome disappears immediately when the pointer leaves
  the window and after five seconds without pointer movement even while the
  pointer remains inside.** Pointer location alone is not attention, so idle
  chrome must never keep covering the media.
- **2026-08-11 — The floating playback palette can be dragged out of the way,
  and the timeline supports direct click-and-drag scrubbing.** This preserves
  the QuickTime-style ability to protect important parts of the frame while
  retaining precise seeking.

## Playback palette verification

The scrubber's frame-pacing and exact-release contract has deterministic Qt
Quick Test coverage in `tests/tst_scrubber.qml`. The project does not yet have
a full playback-palette Qt Quick Test target, so palette integration changes
must also include these deterministic manual checks:

1. Move the pointer over the player, leave it still over the video and then over
   the palette, and confirm the palette begins hiding at five seconds in both
   cases while playing and paused.
2. Move the pointer out of the player and confirm the palette reaches zero
   opacity immediately; move it back and confirm the palette reappears.
3. Hold and drag the timeline for longer than five seconds. Confirm the palette
   stays visible, its time label and handle track the pointer continuously, and
   native preview follows rapidly at frame cadence without duplicate stationary
   requests, then playback lands at the exact release position. Repeat by
   clicking three distant points on the track and with Left/Right, Home/End, and
   Page Up/Page Down while the timeline has keyboard focus.
4. Drag from empty palette chrome and confirm the complete palette follows the
   pointer. Start the same gesture on the timeline, volume slider, and every
   button and confirm the palette itself does not move.
5. Drag the palette against every window edge, then shrink and expand the
   window. Confirm all of the palette stays inside the safe viewing area.
6. Open Quick Edit and leave the pointer still inside the window for five
   seconds. Confirm the playback palette still hides while the editor remains
   open, then move the pointer and confirm the palette reappears without moving
   or closing the editor.
