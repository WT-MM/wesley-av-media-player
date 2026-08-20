import QtQuick
import QtTest
import "../qml" as Wam

Item {
    id: root
    width: 400
    height: 100

    Component {
        id: scrubberComponent

        Wam.Scrubber {
            width: 320
            height: 44
            from: 0
            to: 100
        }
    }

    TestCase {
        id: testCase
        name: "ScrubberFramePacing"
        when: windowShown
        property var scrubber: null
        property var previews: []
        property var commits: []

        function pointerAt(fraction) {
            return scrubber.leftPadding + scrubber.availableWidth * fraction;
        }

        function init() {
            previews = [];
            commits = [];
            scrubber = createTemporaryObject(scrubberComponent, root);
            verify(scrubber !== null, "Scrubber must instantiate");
            verify(scrubber.availableWidth > 0,
                   "Scrubber must expose a usable timeline width");
            scrubber.previewSeekRequested.connect(function(seconds) {
                testCase.previews.push(seconds);
            });
            scrubber.seekRequested.connect(function(seconds) {
                testCase.commits.push(seconds);
            });
        }

        function cleanup() {
            if (scrubber !== null)
                scrubber.previewPacerActive = false;
            scrubber = null;
        }

        function test_firstImmediateThenLatestAtFrameCadence() {
            scrubber.beginPreviewPacing();
            scrubber.previewAt(pointerAt(0.25));
            compare(previews.length, 1,
                    "the first target is submitted immediately");
            fuzzyCompare(previews[0], 25, 0.001);
            fuzzyCompare(scrubber.previewPosition, 25, 0.001,
                         "the visual handle follows the first pointer");

            scrubber.previewAt(pointerAt(0.50));
            scrubber.previewAt(pointerAt(0.75));
            compare(previews.length, 1,
                    "intermediate pointer targets stay coalesced");
            fuzzyCompare(scrubber.previewPosition, 75, 0.001,
                         "the handle follows the newest pointer immediately");
            fuzzyCompare(scrubber.pendingSeek, 75, 0.001,
                         "only the newest target remains pending");

            scrubber.advancePreviewPacer(0.008);
            compare(previews.length, 1,
                    "half a cadence does not submit heavy preview work");
            scrubber.advancePreviewPacer(0.008);
            compare(previews.length, 2,
                    "a full 16 ms cadence submits the newest target once");
            fuzzyCompare(previews[1], 75, 0.001);
            compare(scrubber.pendingSeek, -1);

            scrubber.previewAt(pointerAt(0.75));
            compare(scrubber.pendingSeek, -1,
                    "a stationary pointer never queues a duplicate target");
            scrubber.advancePreviewPacer(0.016);
            compare(previews.length, 2,
                    "a stationary pointer never emits a duplicate target");
        }

        function test_pointerTargetsAreContinuousNotStepQuantized() {
            // Slider.valueAt() rounds through stepSize. Routing pointer motion
            // through it snapped every drag onto five-second stops: the handle
            // did not sit under the pointer and a whole drag produced only a
            // handful of distinct preview targets. Pointer positions between
            // two keyboard steps must resolve to their own distinct values.
            verify(scrubber.stepSize > 0,
                   "the keyboard step is still configured");
            scrubber.beginPreviewPacing();

            const fractions = [0.071, 0.072, 0.073, 0.074];
            const seen = [];
            for (let i = 0; i < fractions.length; ++i) {
                const value = scrubber.valueForPointer(pointerAt(fractions[i]));
                fuzzyCompare(value, fractions[i] * 100, 0.001,
                             "the pointer target interpolates the timeline");
                verify(seen.indexOf(value) === -1,
                       "neighbouring pointer positions stay distinct");
                seen.push(value);
            }

            // A quarter-timeline drag sampled at pointer cadence must produce a
            // distinct target per sample, not one per keyboard step.
            scrubber.previewAt(pointerAt(0.10));
            compare(previews.length, 1);
            let emitted = 1;
            for (let s = 1; s <= 20; ++s) {
                scrubber.previewAt(pointerAt(0.10 + s * 0.25 / 20));
                scrubber.advancePreviewPacer(0.016);
            }
            verify(previews.length >= 20,
                   "a paced quarter-timeline drag emits a target per frame, "
                   + "got " + previews.length);
        }

        function test_fractionalFramesAdaptWithoutBursting() {
            scrubber.beginPreviewPacing();
            scrubber.previewAt(pointerAt(0.10));
            compare(previews.length, 1);

            // Three 144 Hz frames cross one 16 ms cadence. Retaining the
            // fractional remainder lets the following update converge in two
            // frames instead of permanently sampling every third frame.
            scrubber.previewAt(pointerAt(0.20));
            scrubber.advancePreviewPacer(1 / 144);
            scrubber.advancePreviewPacer(1 / 144);
            compare(previews.length, 1);
            scrubber.advancePreviewPacer(1 / 144);
            compare(previews.length, 2);
            fuzzyCompare(previews[1], 20, 0.001);

            scrubber.previewAt(pointerAt(0.30));
            scrubber.advancePreviewPacer(1 / 144);
            compare(previews.length, 2);
            scrubber.advancePreviewPacer(1 / 144);
            compare(previews.length, 3,
                    "the retained remainder adapts toward 60 Hz");
            fuzzyCompare(previews[2], 30, 0.001);

            scrubber.previewAt(pointerAt(0.40));
            scrubber.advancePreviewPacer(0.100);
            compare(previews.length, 4,
                    "a dropped frame still emits at most one latest target");
            fuzzyCompare(previews[3], 40, 0.001);
        }

        function test_returnToSubmittedTargetCancelsPendingDuplicate() {
            scrubber.beginPreviewPacing();
            scrubber.previewAt(pointerAt(0.20));
            scrubber.previewAt(pointerAt(0.80));
            fuzzyCompare(scrubber.pendingSeek, 80, 0.001);
            scrubber.previewAt(pointerAt(0.20));
            compare(scrubber.pendingSeek, -1,
                    "returning to the submitted target cancels queued work");
            scrubber.advancePreviewPacer(0.100);
            compare(previews.length, 1,
                    "the submitted target is not emitted twice");
        }

        function test_releaseAndCancelAlwaysCommitExactVisibleTarget() {
            scrubber.beginPreviewPacing();
            scrubber.previewAt(pointerAt(0.10));
            scrubber.previewAt(pointerAt(0.60));
            compare(previews.length, 1);
            fuzzyCompare(scrubber.pendingSeek, 60, 0.001);

            scrubber.finishScrub(pointerAt(0.90), true);
            compare(previews.length, 1,
                    "release drops the pending approximate preview");
            compare(commits.length, 1,
                    "release emits exactly one authoritative commit");
            fuzzyCompare(commits[0], 90, 0.001);
            fuzzyCompare(scrubber.previewPosition, 90, 0.001,
                         "the committed handle remains under the pointer");
            compare(scrubber.pendingSeek, -1);
            compare(scrubber.previewPacerActive, false);

            previews = [];
            commits = [];
            scrubber.beginPreviewPacing();
            scrubber.previewAt(pointerAt(0.30));
            scrubber.previewAt(pointerAt(0.70));
            scrubber.finishScrub(0, false);
            compare(previews.length, 1,
                    "cancellation drops the pending approximate preview");
            compare(commits.length, 1,
                    "cancellation emits one authoritative commit");
            fuzzyCompare(commits[0], 70, 0.001,
                         "cancellation commits the last visible handle");
        }
    }
}
