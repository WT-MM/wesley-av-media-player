from pathlib import Path
import json,shutil,hashlib,datetime
root=Path('/private/tmp/wam-phase2g');repo=Path('/private/tmp/wam-cov');docs=repo/'docs/native-coverage/phase2g'
rows=json.loads((root/'corpus-registry-final/results.json').read_text());summary=json.loads((root/'corpus-registry-final/summary.json').read_text())
assert len(rows)==97 and summary['native']>=93 and not summary['regressions']
assert all(x['rc']==0 for x in rows)
candidate=summary['candidate_sha256']
assert hashlib.sha256((repo/'build/WAM.app/Contents/MacOS/WAM').read_bytes()).hexdigest()==candidate
for name in ['corpus-registry-final','measurements-registry-final']:
 shutil.copytree(root/name,docs/name,ignore=shutil.ignore_patterns('home'),dirs_exist_ok=True)
shutil.copy2(root/'corpus-registry-final.log',docs/'corpus-registry-final.log')
byname={Path(x['path']).name:x for x in rows}
original=[x for x in rows if x['baseline']!='NATIVE_OK']
assert len(original)==13
corpus=f'''# Final shipped corpus

Candidate `{candidate}`. AVFORMAT ON / AVCODEC OFF. Quiet six-second launches, scratch HOME, muted/background geometry 480×270+2400+1000, all four required identity variables. A success requires native selection, a first-frame event, streamed drawn frames >0, no native failure and exit code zero. Every log and streamed sample is retained.

**{summary['native']}/97 native; zero regressions among the original 84; zero abnormal exits.** The four refused files retain named missing-proof diagnostics. [All identities, results and metrics paths](corpus-registry-final/results.json), [summary](corpus-registry-final/summary.json), [probe](corpus-final.py).

| Original refusal | Final outcome | Streamed drawn frames | Clock 1.0000 |
| --- | --- | ---: | --- |
'''
for x in original:corpus+=f"| {Path(x['path']).name} | {x['status']} | {x['drawn_frames']} | {'yes' if x['clock_1_0000'] else 'not native'} |\n"
corpus+='\nExact remaining diagnostics:\n\n'
for x in rows:
 if x['status']!='NATIVE_OK':corpus+=f"- `{Path(x['path']).name}`: `{' ; '.join(x['failures'])}`\n"
special=[x for x in rows if 'RustDesk' in x['path'] or Path(x['path']).name=='appleads.mp4']
assert len(special)==7 and all(x['status']=='NATIVE_OK' and x['clock_1_0000'] for x in special)
corpus+='\nSix RustDesk recordings and appleads:\n\n| File | Drawn frames | Clock |\n| --- | ---: | --- |\n'
for x in special:corpus+=f"| {Path(x['path']).name} | {x['drawn_frames']} | 1.0000 |\n"
corpus+='\nThe previous candidate had three shutdown aborts after native draws; those launches were not counted as successes. Their unchanged isolated reruns passed, and the subsequently diagnosed registry lifetime defect was fixed and revert-tested. [Shutdown evidence](SHUTDOWN.md), [earlier complete corpus](corpus-final-complete/results.json), [earlier isolated reruns](shutdown-isolated/results.json). The final corpus above uses the fixed candidate and has no abnormal exit.\n'
(docs/'CORPUS.md').write_text(corpus)
measurement=f'''# Final shipped resource measurements

Fourteen-second quiet launches on candidate `{candidate}`; AVFORMAT ON / AVCODEC OFF. CPU is percentage of one core. Energy is the sampler's process-J reading, not whole-machine energy. Peak footprint is divided by 2²⁰. These measurements do not assert an energy improvement. Native-refused ASP runs the bundled fallback and its costs are not native software-decoder costs.

| Specimen | CPU % | Process J | Peak MiB | Native drawn / late / superseded |
| --- | ---: | ---: | ---: | --- |
'''
for mode in ['normal','no-hardware-seam']:
 measured=json.loads((root/'measurements-registry-final'/mode/'results.json').read_text())
 assert len(measured)==(6 if mode=='normal' else 5)
 for x in measured:
  assert x['candidate_sha256']==candidate and x['rc']==0
  u=x['usage'];sample=x['last_sample'] or {};native=x['first_frame'] and not x['failures'] and (sample.get('drawn_frames') or 0)>0
  result=f"{sample['drawn_frames']} / {sample['discarded_late_frames']} / {sample['superseded_frames']}" if native else 'Native refused; fallback'
  label=Path(x['asset']).stem+(' / no-HW seam' if mode!='normal' else '')
  measurement+=f"| {label} | {u['cpu_percent_one_core']:.2f} | {u['energy_joules_process']:.3f} | {u['peak_footprint_bytes']/2**20:.1f} | {result} |\n"
measurement+='\nThe OFF build does not consume the no-hardware seam. Those five rows still exercise the shipped hardware-capable path and must not be presented as software measurements. Hi10P and H.264 422 now reach Apple hardware in the shipped OFF configuration. [Normal raw measurements](measurements-registry-final/normal/results.json), [seam raw measurements](measurements-registry-final/no-hardware-seam/results.json).\n'
measurement+=f"\nSampler SHA-256 `{hashlib.sha256((root/'sampler').read_bytes()).hexdigest()}`. All launch identities, process usage, logs and streamed metrics are retained under `measurements-registry-final/`.\n"
(docs/'MEASUREMENTS.md').write_text(measurement)
print(json.dumps({'candidate':candidate,'native':summary['native'],'original_outcomes':[(Path(x['path']).name,x['status'],x['drawn_frames']) for x in original]}))
# The report is generated only from complete, identity-matched acceptance runs.
facts=(docs/'FILES.md').read_text();facttable=facts[facts.index('| File |'):facts.index('\n\nCoreMedia')]
factlines=facttable.splitlines();outtable='| File | Codec / pixel format / depth | Primaries / transfer / matrix / range | Coded size; PAR | Final native result |\n| --- | --- | --- | --- | --- | --- |\n'
for line in factlines[2:]:
 name=line.split('|')[1].strip();x=byname[name]
 result=f"Native, {x['drawn_frames']} drawn" if x['status']=='NATIVE_OK' else 'Named refusal'
 outtable+=line+f' {result} |\n'
color=(docs/'COLOR.md').read_text();colortable=color[color.index('| Family |'):color.index('\n\nVivid-off')].replace('(captures/','(../phase2g/captures/')
mt=measurement[measurement.index('| Specimen |'):measurement.index('\n\nThe OFF')]
report=f'''# Phase 2g — 93/97 native; AVFORMAT ON, AVCODEC OFF

Final shipped candidate `{candidate}`. The 97-file probe reaches **{summary['native']}/97 native**, including all original 84 and nine hardware additions, with **zero regressions and zero abnormal exits**. All six RustDesk recordings and appleads draw native frames at clock **1.0000**. **All 124 tests pass across the final suite and unchanged isolated timeout reruns.** The owner's broader goal of eliminating every fallback is not achieved: four corpus refusals and the software-stage gates remain explicitly deferred.

Apple priority remains VideoToolbox hardware → VideoToolbox software → AudioToolbox → libvpx → libavcodec last. Native fails closed. Captures ran first and every capture, including failed/shifted controls and removed experiments, is retained. Changes remain in the working tree for independent maintainer verification; no commit, staging, stash, reset or checkout was performed. No network or sibling-process/file manipulation was used.

## Thirteen original fallbacks

{outtable}

The six angel files use Apple H.264 High 10 hardware, with ambient payload `002fe9a03d134042` (314 lux; x=15635/50000, y=16450/50000). The exact HLG tuple passes the retained display comparison and all 100 production fixture surfaces retain the payload. The three 4:4:4 files decode **983/983, 903/903 and 263/263** respectively in Apple hardware to explicit `444v`; Apple software creates a session but decodes zero frames with status −8969. Their limited-range 601/709 display tuples are qualified. No unqualified software 4:4:4 admission is added. [Hardware packet/frame receipts](../phase2g/apple-444-probes-unsandboxed.json), [final per-file identities, draws and diagnostics](../phase2g/CORPUS.md).

CoreMedia video edits, source start → target zero (duration): all six angel files start `1024/15360`, with durations 55, 44, 55, 55, 44 and 99 seconds in the table's order; zbot33, 495_2 and amp6 start zero with durations `196600/3000`, `180600/3000` and `52600/3000`. Screencast starts `6000/90000`, duration `491326/1000`; visual_hand starts `352434/90000`, duration `7373/1000`. IMG video starts `321/600`, audio `1476/44100`, both duration 22 seconds. PXL video starts zero and ends `854297/30000`; audio has an empty `192/10000` prefix and source trim `2112/48000`, retained duration `6815160/240000`, target start `192/10000`. [Verbatim CoreMedia segments, full immutable FFprobe facts and metadata](../phase2g/FILES.md).

Remaining refusals:

- **IMG_7267:** `DolbyVisionDisplayOracleProofMissing`. It additionally carries Dolby Vision profile 8/level 4, RPU present, compatibility ID 4 and −90° rotation. An HLG-base-layer comparison does not qualify the complete DV presentation.
- **Both anamorphic files:** `AnamorphicExactRationalDisplaySizeProofMissing`. PAR `5127:4912` gives exact display size `(615240/307) × 1080`, aspect `1709:921`. Frozen integral display fields cannot carry that requested actual size; Proposal 27 is unapplied. No exact aspect/Qt scaling capture is claimed.
- **PXL:** `CoreMediaAudioEditExactTimelineProofMissing`. FFmpeg decodes 1,364,070 frames, first PTS `922/48000`; its timestamp endpoint is `56881/2000`, differing from video by `541/15000` seconds. The CoreMedia retained interval is 1,363,032 samples and ends at target `284157/10000`. Exact PCM/discontinuity/head/tail mapping is unimplemented; no zero-gap or approximate-count proof is claimed.

## Amendment 26 applied

Only `src/media/native_media_source.hpp` changes among the frozen files. The enum appends `Yuv444EightBit`; `MediaVideoFormat` appends `std::uint64_t ambientViewingEnvironmentPayload{{0}};` and `bool fullRangeVideo{{false}};` immediately after `ambientViewingEnvironmentPresent`. [Exact frozen-line before/after](../phase2g/amendment26-applied.md), [SHA-256 inventory](../phase2g/frozen-invariants.json).

Admission is limited to 8-bit H.264 4:4:4 limited-range 709/709/709 or 601/709/601 on the direct display route, and exact ambient payload `002fe9a03d134042` on limited-range 2020/HLG/2020-NCL ten-bit 4:2:0. Nearby payloads, full-range variants, HDR 4:4:4, Dolby Vision and scene-graph 4:4:4 remain closed. Matroska range zero inherits coded range and contradictory full-coded 4:4:4 is refused. The padded 4:4:4 surface derives 30,629,888 bytes, below the retained per-surface ceiling; ten surfaces and 384 MiB remain unchanged.

## Display qualification and codec gates

Unchanged tolerances: RMS ≤6 eight-bit RGB units and absolute matrix/range projections ≤0.15. Table passes qualify the measured fixtures, not every metadata combination in a family. [Method, controls and full retained evidence](../phase2g/COLOR.md).

{colortable}

Vivid-off now enables extended range before applying Automatic dynamic range, fixing the display-layer setting that crushed HDR. Hardware HEVC PQ/HLG provides matching-content display oracles. Known software PQ/HLG fixtures pass; the software HDR predicate remains unchanged and closed because mastering/ambient payload transport is not fully proved.

Full-range ASP loses a container-only range fact when the software adapter derives range from MPEG-4 VOL. Correcting the surface flag alone improves RMS to 2.1466 but still fails range projection at 0.19835. Integer normalization trials also fail; all were removed byte-identically. Full-range VP9 p0 hardware and software captures have identical RGB and the same 0.2027275 projection: the unresolved discrepancy is shared display/reference treatment, not demonstrated software-only expansion. No tolerance was relaxed and no approximate pixel correction ships.

The three fully started sixteen-window software storms have **16 / 17 / 17 preview failures**. A bounded-worker trace identifies `AvcodecWorkerBudgetExceeded`: sixteen playback workers fill the process ceiling and independent preview workers cannot acquire capacity. All three retire **16 → 16 → 0** windows and unload the native images. The first also has one commit-seek drain failure; the other two have none. No zero-failure storm or scheduling fix is claimed. [Raw storm summaries](../phase2g/storm-final-summary.json). The temporary trace was removed byte-identically; resource caps and derived reservations were not increased.

**AVCODEC stays OFF.** Full-range ASP and VP9 p0 fail color qualification; unmeasured software HDR metadata stays closed; three zero-failure storms are absent; the full package fails the macOS 13.3 floor. The codec closure is lazy, no eager native-FFmpeg load command is present, all notices exist, no external/unresolved dependency remains and deep strict signing passes. However 164 bundled images exceed the deployment floor. [Final packaging audit and reproduction limits](../phase2g/PACKAGING.md). Hi10P and H.264 422 can now reach Apple hardware with AVCODEC OFF.

## Final resource table

Fourteen-second quiet launches, CPU as percentage of one core, sampler process joules and peak MiB. Native-refused ASP costs include bundled fallback. The OFF build ignores the no-hardware seam, so those rows are still shipped hardware-capable runs, not software measurements. No energy-improvement claim is made.

{mt}

[Identities, sampler hash, raw usage and streamed metrics](../phase2g/MEASUREMENTS.md).

## Tests, shutdown and remaining work

`cmake --build build --parallel` passes. The final full suite is 122/124 in 399.06 s; packaging and Matroska timed out. Their unchanged isolated reruns pass in 54.58 and 3.36 s, so all 124 tests pass across those runs. The prior pre-registry candidate also has a clean 122/122 full run. No timeout or expectation was relaxed. [Build/test logs and 14 behavior-group revert receipts](../phase2g/TESTS.md).

The prior corpus exposed three aborts after native drawing. PID-matched crash reports showed audio/video global registry mutex destruction racing deferred retirement. Fixed in-place process-lifetime registry storage preserves bounded slots and explicit retirement without a GUI wait or allocation. Both new production-registry exit tests fail with the old registries and pass after byte-identical restoration. The final 97-file corpus has zero abnormal exits. [Crash reports and shutdown proof](../phase2g/SHUTDOWN.md).

DTS specimen inventory remains empty; no DTS-HD MA profile is admitted. Named `SoftwareAudioPacketTimelineUnqualified` (opt-in) and `SoftwareAudioStageNotBuilt` (shipped) boundaries remain. Core-plus-extension and extension-only packets are rejected; the trailing-byte mutant fails and restoration passes. [Timestamped inventory and exact remaining MA requirements](../phase2g/DTS_HD_MA.md).

**Unapplied Proposal 27** replaces the frozen integral `MediaDisplaySize` and `PreparedDescriptor` display fields with exact rationals. Its exact before/after is retained in [PROPOSALS.md](../phase2g/PROPOSALS.md). Further deferred work is PXL rational PCM edit mapping, DV display proof, bounded preview capacity handoff, full-range/HDR metadata qualification, macOS 13.3 dependency packaging and a real DTS-HD MA specimen. No frozen geometry/timeline amendment beyond 26 was applied.

The preceding phase-2f report is preserved [here](../phase2g/PHASE2F_REPORT.md); the amendment ledger through 25 remains in the existing README and phase-2e receipts. The maintainer verifies this uncommitted candidate independently before committing.
'''
(repo/'docs/native-coverage/phase2/REPORT.md').write_text(report)
