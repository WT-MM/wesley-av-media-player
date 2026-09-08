# DTS-HD MA

`/private/tmp/wam-specimens/` was inspected again for this phase and contained no files. [Timestamped inventory](dts-specimen-inventory-final.json). No HD-MA profile is admitted or claimed qualified.

The codec-ON Matroska profile boundary still refuses unqualified packet geometry as `SoftwareAudioPacketTimelineUnqualified`; the shipped OFF path additionally refuses `SoftwareAudioStageNotBuilt`. Libavformat DTS audio ingress remains unadmitted. The regression accepts a 1,024-byte 16-bit big-endian core carrying 512 samples, rejects a 2,048-byte packet with that same core header, and now explicitly rejects extension-only sync `64582025`.

The temporary trailing-byte mutant fails `software_audio_packet`; byte-identical restoration passes. [Revert receipt](extra-revert-proofs/results.json). This confirms a refusal boundary, not MA decoding. The real-specimen, full-extension PCM, channel-role, exact count/PTS/end, seek and EOS requirements in [phase 2f](../phase2f/DTS_HD_MA.md) remain outstanding.
