# Offline WAM ASR bake-off

From the repository root, on macOS 26 with the staged assets:

```sh
sh tools/asr-bench/build.sh
python3 tools/asr-bench/test_bench.py
python3 tools/asr-bench/bench.py prepare
/private/tmp/wam-asr-scratch/apple-transcribe --probe
python3 tools/asr-bench/bench.py run --engines AB
python3 tools/asr-bench/bench.py summarize
```

Use `ABC` only if the Apple probe reports `installed`; use `ABCD` to include the optional CPU run. C never calls an installation API. Hardware and `ps` access must be allowed by the execution environment; the sandbox gives misleading asset availability. No network is used. All corpus, PCM, models, compilers' output/cache and engine outputs are in `/private/tmp/wam-asr-scratch`. Do not delete OS CoreML caches to simulate a cold start.

Preparation deterministically samples 300 distinct utterances with Python Random seed 20260922 from sorted IDs. It then shuffles speaker IDs with the same generator and selects 20 speakers with at least five minutes of consecutive utterances (numeric chapter/utterance order), stopping just after five minutes and always before ten. There is no inserted silence or resampling beyond ffmpeg's 16 kHz mono signed-16 PCM extraction. Some short samples can also occur in long files; do not pool the two WER strata. Manifest records references, exact PCM boundaries, audio duration and WAV SHA256. They are file boundaries, not forced-aligned speech onsets.

A uses the shipped executable and model, `-t 16 -osrt -l auto`, GPU enabled. B uses the same f16 model plus the staged CoreML encoder, with otherwise identical flags. D uses A with `-ng`. B's upstream CoreML configuration permits CPU/GPU/ANE; successful loading does not establish ANE residency. No quantization is performed. The Apple model precision is not exposed by its public API.

Every process invocation waits until `uptime`'s **one-minute** load is below 4 and `ps` shows no compiler/linker/build process. `quiet.jsonl` records waits. The five- and fifteen-minute averages are preserved as context. Build checks repeat during and after transcription; runs overlapping a build are invalid. Load during the run includes the engine itself and therefore is not grounds alone for rejecting the run. This gate cannot prove absence of every kind of external contention. `Ctrl-C` kills the active benchmark process group. The per-file watchdog is 30 minutes.

Each engine first receives one long file, stored under repetition `first`, excluded from steady-state aggregation. This is a **first observed invocation**, not proof of an empty system cache. B's `coreml_load` measures the interval between upstream loading/loaded messages, including any specialization; the API does not isolate compiler time. Subsequent runs rotate engine order per file and repeat three times. Valid records are resumable; rerunning retries invalid records and retains the previous JSON. Run `summarize` only after completion; it includes only files with all three valid repetitions and reports coverage explicitly.

`runs/ENGINE/FILE/REPEAT/` contains exact command, `/usr/bin/time -l`, complete merged output, timestamped JSONL line events, final SRT and `result.json`. Wall time includes process launch/load/output. RTF divides wall by WAV duration. First caption is first flushed Whisper segment line or Apple result event, including volatile Apple results; the final SRT contains only final Apple results. This latency excludes WAM's earlier audio extraction. Whisper flushes every callback segment (upstream CLI source), so pipes do not wait for process exit. `model_load` is upstream's ggml load timer, not total startup. RSS is bytes on macOS. CPU user+sys is a proxy, not energy, and Apple service work can occur outside the child process.

WER is corpus-weighted errors/reference words, using a local Levenshtein implementation after uppercasing and removing punctuation (no number or contraction expansion). Summary WER uses repetition zero; inspect per-run values for nondeterminism. Timing cells are medians across files of each file's three-run median, not total throughput. `boundary_offsets` is distance from each segment start to the nearest known utterance boundary; it is segmentation-sensitive, not an accuracy verdict. `boundary_alignment` additionally matches at least three consecutive words with SequenceMatcher, compares starts only when a segment starts at the corresponding utterance's first word, and reports coverage and signed errors. Neither metric is word-level forced alignment. SRT timestamps have millisecond resolution; emission clocks are monotonic.

Power probe: `sudo -n powermetrics -n 1 -i 100 --samplers cpu_power,gpu_power,ane_power`. A password failure means no power/energy ranking is possible. No password prompt is permitted. On a host where metering works, collect a time-aligned power trace plus idle baseline before claiming joules; this harness currently records CPU time only.
