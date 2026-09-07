# Bounded native / cached fallback coexistence

This phase retains the mutually exclusive closure policy; it does not load two FFmpeg closures together. The main executable has no eager native FFmpeg or mpv load command. Native libraries use distinct `libavcodec-wamnative.63`, `libavutil-wamnative.61` and `libavformat-wamnative.63` install names. The mpv seed uses its separate Homebrew FFmpeg closure.

While any native FFmpeg lease is alive, fallback loading refuses `DecoderUnavailable: PlaybackFfmpegClosureConflict`. Closing one native session does not unload libraries held by another. After the final native lease retires, the native symbols and images unload, and fallback can load. A successful fallback is cached for the process lifetime: closing its window does not release the closure. Subsequent native FFmpeg demux or decode attempts refuse the same name until WAM restarts. Pure AVFoundation/VideoToolbox/AudioToolbox sessions that do not need this demux or decoder closure remain usable. The cost is loss of later libavformat recovery and software-codec sessions in that process; no session is forcibly stopped to clear it.

The runtime test checks the actual native `avcodec_version` symbol's owning image, holds two native leases while the fallback loader refuses, verifies both surviving symbol access and final unload, then loads a fake fallback through the real validated/cached loader and proves the later named native refusal. The fake exports the mpv API but carries no second FFmpeg implementation. This is a loader/cache proof, not a successful media decode by the real mpv closure.

The build-app coordinator proof opens a second unsupported ASF window while a native RustDesk window plays. The second window reports the closure refusal; the first keeps `playing=1`, rate=1 and increasing drawn counts. Closing only the second window leaves the first alive. Only the child PID was controlled.

The local real mpv seed still references missing FFmpeg-62 Homebrew dependencies; its successful cached playback is not newly claimed. The retained packaged closure is separately audited. See coexistence-runtime.txt, coexistence-otool.json and coexistence-playback.json.
