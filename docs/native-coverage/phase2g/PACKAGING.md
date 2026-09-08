# Final local package audit

The current app and native FFmpeg binaries were assembled with the retained local Qt 6.11.1 and fallback closure. The final app is copied to `build/WAM.app`, the only WAM GUI launch path used. Final candidate identity is in [final-candidate.json](final-candidate-registry.json).

- No direct external dependency and no unresolved dependency remains.
- Native codec/demux closure is lazy; the main executable has no eager native-FFmpeg load command.
- All required FFmpeg notices are present. The three native dylibs and main executable declare macOS 13.3.
- The complete bundle **fails** the macOS 13.3 floor: 164 bundled images exceed it, including Qt at 14.0 and QtLabs/libvpx dependencies at 26.0. `clean_machine_ready=false`; this is not a successful release packaging gate.
- The assembled app passes deep, strict code-signature verification after signing the current native dylibs and thumbnail extension.

[Complete closure/floor audit](package-audit-registry-final.json). The audit exits nonzero for the floor failure, even though relocation and lazy-loading checks pass. No floor declaration was falsified.

The fresh clone initially lacked deployed Qt and bundled mpv. Local `cmake --install` produced dangling QML plugin links; the transactional bundler refused these and then refused an unregistered fallback destination. Those logs are retained. The final assembly uses the previously retained, same-version self-contained Qt/fallback provider closure, with the **current** executable, Info.plist, thumbnail extension and native FFmpeg modules. It restores `@executable_path/../Frameworks`, which Qt deployment had removed and which the lazy native `@rpath` dependencies require. No network, installed WAM or sibling clone was used for this repair.

Reproducing a release still requires a dependency closure meeting the release floor and a clean deployment procedure. The current local package is sufficient for the retained native/fallback runtime measurements on this machine; it does not waive the packaging gate for enabling AVCODEC.
