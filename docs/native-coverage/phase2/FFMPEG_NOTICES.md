# Native FFmpeg dependency notices

FFmpeg 9.0.1, Copyright (c) the FFmpeg developers and the individual copyright
holders identified in its source files. This build is distributed under the
GNU Lesser General Public License, version 2.1 or later. The complete license
is in COPYING.LGPLv2.1; upstream's license inventory is in LICENSE.md. Individual
source headers retain additional permissive-license notices.

Corresponding source is the unmodified, hash-pinned archive at
third_party/ffmpeg-source/ffmpeg-9.0.1.tar.xz in the same WAM source revision.
SHA-256: cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635.
No FFmpeg source patches are applied. Build with scripts/build_ffmpeg_lgpl.sh.
No warranty is provided by the FFmpeg authors; see the license text.

Replacement: rebuild the matching library ABI using that script and a local
prefix. Replace libavcodec-wamnative.63.dylib and libavutil-wamnative.61.dylib
inside WAM.app/Contents/Frameworks with compatible libraries. Keep their bundle
load commands relative to that directory. Sign changed libraries first with
`codesign --force --sign - LIBRARY`, then sign the app with
`codesign --force --deep --sign - WAM.app`. Run WAM --verify-runtime before
playback. The verification accepts compatible replacement builds; it does not
require the distributor's signature or a byte-identical library hash.

The export/caption FFmpeg executable and mpv compatibility runtime have their
own dependency and license configurations. These native-stage notices do not
assert a license for those separate components or select WAM's own license.
