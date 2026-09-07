# Native FFmpeg corresponding source — release held

The exact local source archive is `third_party/ffmpeg-source/ffmpeg-9.0.1.tar.xz`.
SHA-256: `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`.
No source patches are applied. Build it offline with
`scripts/build_ffmpeg_lgpl.sh ARCHIVE PREFIX`; the recipe fixes arm64 and macOS
13.3 and retains configure arguments, license text and compiler/SDK receipts.

A binary release must distribute that archive, recipe and receipts alongside
its download. No release-specific corresponding-source URL has been assigned
in this repository. The About/licenses presentation and download-page link
remain release blockers; a repository-relative path is not a published URL.

The native stage loads the replaceable `libavcodec-wamnative.63.dylib` and
`libavutil-wamnative.61.dylib` from Contents/Frameworks. Rebuild both from the
matching source/configuration as one ABI closure; retain their @rpath install
names and LGPL-only configuration. Replace both files in a copy of the app,
sign the replaced leaves and then the enclosing app with the user's signing
identity (ad-hoc signing is suitable for local development), and run
`--verify-runtime`. The loader checks ABI majors, license, configuration and
required functions/decoders. A missing or invalid closure returns a named
refusal. It never searches Homebrew for a native-stage replacement.

This work does not decide WAM's own license or contributor rights. The
maintainer must settle those release prerequisites separately.
