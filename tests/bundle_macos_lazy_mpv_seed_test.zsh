#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
bundle_entry="$repo_root/scripts/bundle_macos.zsh"
bundle_library="$repo_root/scripts/bundle_macos_lib.zsh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/wam-mpv-package-policy.XXXXXX")"
trap '/bin/rm -rf -- "$fixture_root"' EXIT

real_clang="$(xcrun --find clang)"
real_sdk="$(xcrun --sdk macosx --show-sdk-path)"
fake_bin="$fixture_root/bin"
source_root="$fixture_root/sources"
mkdir -p "$fake_bin" "$source_root"

print -r -- '#!/bin/zsh
set -euo pipefail
if [[ "$1" == --find && $# == 2 ]]; then
  case "$2" in
    install_name_tool) print -r -- "$WAM_FIXTURE_BIN/install_name_tool" ;;
    clang) print -r -- "$WAM_FIXTURE_REAL_CLANG" ;;
    *) exit 1 ;;
  esac
elif [[ "$1" == --sdk && "$2" == macosx &&
        "$3" == --show-sdk-path && $# == 3 ]]; then
  print -r -- "$WAM_FIXTURE_REAL_SDK"
else
  exit 64
fi' > "$fake_bin/xcrun"

print -r -- '#!/bin/zsh
exit 1' > "$fake_bin/brew"

print -r -- '#!/bin/zsh
set -euo pipefail
target="${@: -1}"
if [[ "$1" == -b ]]; then target="$2"; fi
case "${target:t}" in
  WAM|ffmpeg|whisper-cli)
    print -r -- "Mach-O 64-bit arm64 executable"
    ;;
  *.dylib|QtFixture)
    print -r -- "Mach-O 64-bit arm64 dynamically linked shared library"
    ;;
  *) print -r -- "ASCII text" ;;
esac' > "$fake_bin/file"

print -r -- '#!/bin/zsh
set -euo pipefail
[[ "$1" == -archs && $# == 2 ]] || exit 64
while IFS= read -r line; do
  if [[ "$line" == ARCH=* ]]; then
    print -r -- "${line#ARCH=}"
    exit 0
  fi
done < "$2"
print -r -- arm64' > "$fake_bin/lipo"

print -r -- '#!/bin/zsh
set -euo pipefail
architecture=""
if [[ "$1" == -l && $# == 2 ]]; then
  target="$2"
elif [[ "$1" == -arch && "$3" == -l && $# == 4 ]]; then
  architecture="$2"
  target="$4"
else
  exit 64
fi
specific_minos=false
specific_platform=""
if [[ -n "$architecture" ]]; then
  while IFS= read -r line; do
    [[ "$line" != "MINOS_${architecture}="* ]] || specific_minos=true
    [[ "$line" != "PLATFORM_${architecture}="* ]] || \
      specific_platform="${line#*=}"
  done < "$target"
fi
command_index=0
while IFS= read -r line; do
  case "$line" in
    ID=*)
      print -- "Load command $command_index\n          cmd LC_ID_DYLIB\n      cmdsize 72\n         name ${line#ID=} (offset 24)"
      (( command_index += 1 ))
      ;;
    LOAD=*)
      print -- "Load command $command_index\n          cmd LC_LOAD_DYLIB\n      cmdsize 72\n         name ${line#LOAD=} (offset 24)"
      (( command_index += 1 ))
      ;;
    RPATH=*)
      print -- "Load command $command_index\n          cmd LC_RPATH\n      cmdsize 48\n         path ${line#RPATH=} (offset 12)"
      (( command_index += 1 ))
      ;;
    MINOS=*)
      [[ -z "$architecture" || "$specific_minos" != true ]] || continue
      print -- "Load command $command_index\n          cmd LC_BUILD_VERSION\n      cmdsize 32\n     platform MACOS\n        minos ${line#MINOS=}"
      (( command_index += 1 ))
      ;;
    MINOS_*=*)
      [[ -n "$architecture" && "$line" == "MINOS_${architecture}="* ]] || \
        continue
      platform="${specific_platform:-MACOS}"
      print -- "Load command $command_index\n          cmd LC_BUILD_VERSION\n      cmdsize 32\n     platform $platform\n        minos ${line#*=}"
      (( command_index += 1 ))
      ;;
  esac
done < "$target"' > "$fake_bin/otool"

print -r -- '#!/bin/zsh
set -euo pipefail
operation="$1"
shift
case "$operation" in
  -id)
    new_id="$1"; target="$2"; prefix=ID; old=""
    ;;
  -change)
    old="$1"; replacement="$2"; target="$3"; prefix=LOAD
    ;;
  -delete_rpath)
    old="$1"; target="$2"; prefix=RPATH; replacement=""
    ;;
  -add_rpath)
    replacement="$1"; target="$2"; prefix=RPATH; old=""
    ;;
  *) exit 64 ;;
esac
temporary="${target}.rewrite.$$"
was_executable=false
[[ -x "$target" ]] && was_executable=true
found=false
: > "$temporary"
while IFS= read -r line; do
  if [[ "$operation" == -id && "$line" == ID=* ]]; then
    print -r -- "ID=$new_id" >> "$temporary"; found=true
  elif [[ "$operation" == -change && "$line" == "LOAD=$old" ]]; then
    print -r -- "LOAD=$replacement" >> "$temporary"; found=true
  elif [[ "$operation" == -delete_rpath && "$line" == "RPATH=$old" ]]; then
    found=true
  else
    print -r -- "$line" >> "$temporary"
  fi
done < "$target"
if [[ "$operation" == -id && "$found" != true ]]; then
  print -r -- "ID=$new_id" >> "$temporary"
elif [[ "$operation" == -add_rpath ]]; then
  print -r -- "RPATH=$replacement" >> "$temporary"
fi
/bin/mv "$temporary" "$target"
[[ "$was_executable" != true ]] || chmod +x "$target"' > \
  "$fake_bin/install_name_tool"

print -r -- '#!/bin/zsh
set -euo pipefail
log="$WAM_FIXTURE_CODESIGN_LOG"
state="$WAM_FIXTURE_SIGNATURE_STATE"
mkdir -p "$state"
target="${@: -1}"
key="$(print -rn -- "$target" | shasum -a 256)"
key="${key%% *}"
if (( ${@[(I)--sign]} != 0 )); then
  identity_index=${@[(i)--sign]}
  identity="${@[$(( identity_index + 1 ))]}"
  runtime=false
  timestamp=false
  deep=false
  (( ${@[(I)runtime]} == 0 )) || runtime=true
  (( ${@[(I)--timestamp]} == 0 )) || timestamp=true
  (( ${@[(I)--deep]} == 0 )) || deep=true
  if [[ "$identity" != - ]]; then
    [[ "$identity" == 0123456789ABCDEF0123456789ABCDEF01234567 && "$runtime" == true &&
       "$timestamp" == true && "$deep" == false ]] || exit 65
    if [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" == sign &&
          "${target:t}" == libfixture.1.dylib ]]; then
      exit 1
    fi
  fi
  print -r -- "sign|$identity|$runtime|$timestamp|$deep|$target" >> "$log"
  print -r -- "$identity" > "$state/$key"
  exit 0
fi
if (( ${@[(I)--verify]} != 0 || ${@[(I)-v]} != 0 )); then
  [[ -f "$state/$key" ]] || exit 1
  if (( ${@[(I)-R]} != 0 )) && [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" == trust ]]; then
    exit 1
  fi
  print -r -- "verify|$target" >> "$log"
  exit 0
fi
if (( ${@[(I)-d]} != 0 )); then
  [[ -f "$state/$key" ]] || exit 1
  if (( ${@[(I)--entitlements]} != 0 )); then
    output_index=${@[(i)--entitlements]}
    output="${@[$(( output_index + 1 ))]}"
    if [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" == get-task-allow ]]; then
      print -r -- "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<plist version=\"1.0\"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>" > "$output"
    else
      : > "$output"
    fi
    exit 0
  fi
  authority="Developer ID Application: WAM Fixture (ABCDE12345)"
  team="ABCDE12345"
  flags="0x10000(runtime)"
  timestamp="Timestamp=Aug 13, 2026 at 12:00:00"
  [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" != authority ]] || \
    authority="Apple Development: Wrong (ABCDE12345)"
  [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" != team ]] || team="ZZZZZ99999"
  [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" != runtime ]] || flags="0x0(none)"
  [[ "${WAM_FIXTURE_SIGNATURE_DEFECT:-}" != timestamp ]] || timestamp=""
  print -u2 -- "Executable=$target"
  print -u2 -- "Authority=$authority"
  print -u2 -- "Authority=Developer ID Certification Authority"
  print -u2 -- "TeamIdentifier=$team"
  print -u2 -- "CodeDirectory v=20500 size=100 flags=$flags hashes=1 location=embedded"
  [[ -z "$timestamp" ]] || print -u2 -- "$timestamp"
  exit 0
fi
exit 64' > "$fake_bin/codesign"

chmod +x "$fake_bin"/*

write_image() {
  local target="$1"
  shift
  mkdir -p "${target:h}"
  : > "$target"
  for metadata_line in "$@"; do
    print -r -- "$metadata_line" >> "$target"
  done
}

write_image "$source_root/ffmpeg" \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
write_image "$source_root/whisper-cli" \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
write_image "$source_root/libmpv.2.dylib" \
  'ID=/fixture/libmpv.2.dylib' \
  'LOAD=@loader_path/libfixture.1.dylib' \
  'LOAD=@rpath/QtFixture.framework/Versions/A/QtFixture' \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
write_image "$source_root/libfixture.1.dylib" \
  'ID=/fixture/libfixture.1.dylib' \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
chmod +x "$source_root/ffmpeg" "$source_root/whisper-cli"

export PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WAM_FIXTURE_BIN="$fake_bin"
export WAM_FIXTURE_REAL_CLANG="$real_clang"
export WAM_FIXTURE_REAL_SDK="$real_sdk"
export WAM_FIXTURE_CODESIGN_LOG="$fixture_root/codesign.log"
export WAM_FIXTURE_SIGNATURE_STATE="$fixture_root/signatures"
export WAM_FFMPEG_EXECUTABLE="$source_root/ffmpeg"
export WAM_MPV_FALLBACK_LIBRARY="$source_root/libmpv.2.dylib"

create_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS" \
    "$app/Contents/Frameworks/QtCore.framework" \
    "$app/Contents/Frameworks/QtQuick.framework" \
    "$app/Contents/Frameworks/QtFixture.framework/Versions/A" \
    "$app/Contents/PlugIns/platforms" \
    "$app/Contents/Resources/qml/QtQuick" \
    "$app/Contents/Resources/models"
  write_image "$app/Contents/MacOS/WAM" \
    'LOAD=/usr/lib/libSystem.B.dylib' \
    'RPATH=@executable_path/../Frameworks' 'MINOS=13.0'
  write_image \
    "$app/Contents/Frameworks/QtFixture.framework/Versions/A/QtFixture" \
    'ID=@rpath/QtFixture.framework/Versions/A/QtFixture' \
    'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
  write_image "$app/Contents/PlugIns/platforms/libqcocoa.dylib" \
    'ID=@rpath/libqcocoa.dylib' \
    'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
  chmod +x "$app/Contents/MacOS/WAM"
  print -r -- old-media.dylib > \
    "$app/Contents/Resources/wam-media-libraries.manifest"
  write_image "$app/Contents/Frameworks/old-media.dylib" \
    'ID=@rpath/old-media.dylib' \
    'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
  print -r -- model > \
    "$app/Contents/Resources/models/ggml-base.en.bin"
  print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>LSMinimumSystemVersion</key><string>13.0</string></dict></plist>' > \
    "$app/Contents/Info.plist"
}

tree_digest() {
  local app="$1"
  local node relative kind mode payload
  {
    while IFS= read -r -d '' node; do
      relative="${node#$app/}"
      mode="$(stat -f '%Lp' "$node")"
      if [[ -L "$node" ]]; then
        kind=link
        payload="$(readlink "$node")"
      elif [[ -d "$node" ]]; then
        kind=directory
        payload=""
      elif [[ -f "$node" ]]; then
        kind=file
        payload="$(shasum -a 256 "$node" | awk '{print $1}')"
      else
        kind=other
        payload=""
      fi
      print -rn -- "${#relative}:$relative"$'\0' \
        "$kind"$'\0'"$mode"$'\0'"${#payload}:$payload"$'\0'
    done < <(/usr/bin/find -s "$app" -print0)
  } | shasum -a 256 | awk '{print $1}'
}

expect_no_stage() {
  local case_root="$1"
  local label="$2"
  if find "$case_root" -maxdepth 1 -name '.wam-bundle-stage.*' | \
      grep -q .; then
    print -u2 "$label retained a recognized stage"
    return 1
  fi
}

snapshot_app() {
  local app="$1"
  SNAPSHOT_APP_ID="$(stat -f '%d:%i' "$app")"
  SNAPSHOT_MANIFEST_ID="$(stat -f '%d:%i' \
    "$app/Contents/Resources/wam-media-libraries.manifest")"
  SNAPSHOT_MANIFEST_HASH="$(shasum -a 256 \
    "$app/Contents/Resources/wam-media-libraries.manifest" | awk '{print $1}')"
  SNAPSHOT_TREE_HASH="$(tree_digest "$app")"
}

expect_unchanged() {
  local app="$1"
  [[ "$(stat -f '%d:%i' "$app")" == "$SNAPSHOT_APP_ID" ]]
  [[ "$(stat -f '%d:%i' \
    "$app/Contents/Resources/wam-media-libraries.manifest")" == \
    "$SNAPSHOT_MANIFEST_ID" ]]
  [[ "$(shasum -a 256 \
    "$app/Contents/Resources/wam-media-libraries.manifest" | awk '{print $1}')" == \
    "$SNAPSHOT_MANIFEST_HASH" ]]
  [[ "$(tree_digest "$app")" == "$SNAPSHOT_TREE_HASH" ]]
}

run_fault_case() {
  local fault="$1"
  local case_root="$fixture_root/case-$fault"
  local app="$case_root/WAM.app"
  mkdir -p "$case_root"
  create_app "$app"
  snapshot_app "$app"
  if (
      source "$bundle_library"
      wam_bundle_macos "$app" "$source_root/whisper-cli" \
        "$app/Contents/Resources/models/ggml-base.en.bin" \
        "$fault" "$fixture_root"
    ); then
    print -u2 "fault case unexpectedly succeeded: $fault"
    return 1
  fi
  expect_unchanged "$app"
  if find "$case_root" -maxdepth 1 -name '.wam-bundle-stage.*' | \
      grep -q .; then
    print -u2 "recognized failed stage was not cleaned: $fault"
    return 1
  fi
}

cd "$repo_root"
run_fault_case after-copy
run_fault_case after-install-name
run_fault_case after-rpath-introspection
run_fault_case before-swap
run_fault_case helper-rollback

for traversal_root in System usr-lib Data-volume; do
  case_root="$fixture_root/traversal-$traversal_root"
  app="$case_root/WAM.app"
  mkdir -p "$case_root"
  create_app "$app"
  case "$traversal_root" in
    System)
      print -r -- 'LOAD=/System/../tmp/libescape.dylib' >> \
        "$app/Contents/MacOS/WAM"
      ;;
    usr-lib)
      print -r -- 'LOAD=/usr/lib/../../tmp/libescape.dylib' >> \
        "$app/Contents/MacOS/WAM"
      ;;
    Data-volume)
      print -r -- \
        'LOAD=/System/Volumes/Data/private/tmp/libInjected.dylib' >> \
        "$app/Contents/MacOS/WAM"
      ;;
  esac
  snapshot_app "$app"
  if (
      source "$bundle_library"
      wam_bundle_macos "$app" "$source_root/whisper-cli" \
        "$app/Contents/Resources/models/ggml-base.en.bin"
    ) >/dev/null 2>&1; then
    print -u2 "absolute dependency traversal was accepted: $traversal_root"
    exit 1
  fi
  expect_unchanged "$app"
  expect_no_stage "$case_root" "absolute dependency rejection"
done

wrong_arch_root="$fixture_root/wrong-root-architecture"
wrong_arch_app="$wrong_arch_root/WAM.app"
wrong_arch_whisper="$wrong_arch_root/whisper-cli"
mkdir -p "$wrong_arch_root"
create_app "$wrong_arch_app"
write_image "$wrong_arch_whisper" \
  'ARCH=x86_64' 'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
chmod +x "$wrong_arch_whisper"
snapshot_app "$wrong_arch_app"
if (
    source "$bundle_library"
    wam_bundle_macos "$wrong_arch_app" "$wrong_arch_whisper" \
      "$wrong_arch_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "wrong-architecture whisper root was accepted"
  exit 1
fi
expect_unchanged "$wrong_arch_app"
expect_no_stage "$wrong_arch_root" "wrong-architecture root rejection"

wrong_type_root="$fixture_root/wrong-root-type"
wrong_type_app="$wrong_type_root/WAM.app"
wrong_type_whisper="$wrong_type_root/libwhisper.dylib"
mkdir -p "$wrong_type_root"
create_app "$wrong_type_app"
write_image "$wrong_type_whisper" \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
chmod +x "$wrong_type_whisper"
snapshot_app "$wrong_type_app"
if (
    source "$bundle_library"
    wam_bundle_macos "$wrong_type_app" "$wrong_type_whisper" \
      "$wrong_type_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "dylib masquerading as whisper executable was accepted"
  exit 1
fi
expect_unchanged "$wrong_type_app"
expect_no_stage "$wrong_type_root" "wrong-type root rejection"

wrong_plugin_root="$fixture_root/wrong-plugin-architecture"
wrong_plugin_app="$wrong_plugin_root/WAM.app"
mkdir -p "$wrong_plugin_root"
create_app "$wrong_plugin_app"
print -r -- 'ARCH=x86_64' >> \
  "$wrong_plugin_app/Contents/PlugIns/platforms/libqcocoa.dylib"
snapshot_app "$wrong_plugin_app"
if (
    source "$bundle_library"
    wam_bundle_macos "$wrong_plugin_app" "$source_root/whisper-cli" \
      "$wrong_plugin_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "wrong-architecture packaged plugin was accepted"
  exit 1
fi
expect_unchanged "$wrong_plugin_app"
expect_no_stage "$wrong_plugin_root" "wrong-architecture plugin rejection"

escape_root="$fixture_root/symlink-escape"
escape_app="$escape_root/WAM.app"
mkdir -p "$escape_root"
create_app "$escape_app"
ln -s "$source_root/libfixture.1.dylib" \
  "$escape_app/Contents/Resources/escape-link"
snapshot_app "$escape_app"
if (
    source "$bundle_library"
    wam_bundle_macos "$escape_app" "$source_root/whisper-cli" \
      "$escape_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "source app symlink escape was accepted"
  exit 1
fi
expect_unchanged "$escape_app"

# The fallback is descriptor-loaded in WAM's execution context. Its own
# LC_RPATH entries precede the inherited executable stack, but packaging fails
# closed if two ordered entries name different canonical images: preserving
# that shadowing would make source provenance depend on a mutable search root.
ambiguity_root="$fixture_root/inherited-rpath-ambiguity"
ambiguity_app="$ambiguity_root/WAM.app"
ambiguity_source="$ambiguity_root/source"
ambiguity_inherited="$ambiguity_root/inherited"
mkdir -p "$ambiguity_root" "$ambiguity_source/own" "$ambiguity_inherited"
create_app "$ambiguity_app"
write_image "$ambiguity_source/libmpv.2.dylib" \
  'ID=/fixture/libmpv.2.dylib' \
  'RPATH=@loader_path/own' \
  'LOAD=@rpath/libambiguous.1.dylib' \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
write_image "$ambiguity_source/own/libambiguous.1.dylib" \
  'ID=/first/libambiguous.1.dylib' \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
write_image "$ambiguity_inherited/libambiguous.1.dylib" \
  'ID=/second/libambiguous.1.dylib' \
  'LOAD=/usr/lib/libSystem.B.dylib' 'MINOS=13.0'
print -r -- "RPATH=$ambiguity_inherited" >> \
  "$ambiguity_app/Contents/MacOS/WAM"
snapshot_app "$ambiguity_app"
if (
    export WAM_MPV_FALLBACK_LIBRARY="$ambiguity_source/libmpv.2.dylib"
    source "$bundle_library"
    wam_bundle_macos "$ambiguity_app" "$source_root/whisper-cli" \
      "$ambiguity_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "different inherited @rpath sources were accepted"
  exit 1
fi
expect_unchanged "$ambiguity_app"
if find "$ambiguity_root" -maxdepth 1 -name '.wam-bundle-stage.*' | \
    grep -q .; then
  print -u2 "ambiguous inherited-RPATH failure retained a recognized stage"
  exit 1
fi

success_root="$fixture_root/success"
success_app="$success_root/WAM.app"
mkdir -p "$success_root"
create_app "$success_app"
old_success_id="$(stat -f '%d:%i' "$success_app")"
"$bundle_entry" "$success_app" "$source_root/whisper-cli" \
  "$success_app/Contents/Resources/models/ggml-base.en.bin"
[[ "$(stat -f '%d:%i' "$success_app")" != "$old_success_id" ]]
[[ -x "$success_app/Contents/MacOS/WAM" ]]
[[ -x "$success_app/Contents/Resources/tools/ffmpeg" ]]
[[ -x "$success_app/Contents/Resources/tools/whisper-cli" ]]
grep -q '^WAMMpvFallback.dylib$' \
  "$success_app/Contents/Resources/wam-media-libraries.manifest"
grep -q '^LOAD=@executable_path/../Frameworks/libfixture.1.dylib$' \
  "$success_app/Contents/Frameworks/WAMMpvFallback.dylib"
grep -q '^LOAD=@executable_path/../Frameworks/QtFixture.framework/Versions/A/QtFixture$' \
  "$success_app/Contents/Frameworks/WAMMpvFallback.dylib"
if find "$success_root" -maxdepth 1 -name '.wam-bundle-stage.*' | grep -q .; then
  print -u2 "successful transaction retained the old app stage"
  exit 1
fi

set_plist_floor() {
  local app="$1"
  local floor="$2"
  /usr/libexec/PlistBuddy -c \
    "Set :LSMinimumSystemVersion $floor" "$app/Contents/Info.plist"
}

run_release_floor_failure() {
  local label="$1"
  local defect="$2"
  local case_root="$fixture_root/release-floor-$label"
  local app="$case_root/WAM.app"
  local plugin="$app/Contents/PlugIns/platforms/libqcocoa.dylib"
  mkdir -p "$case_root"
  create_app "$app"
  if [[ "$defect" != plist && "$defect" != plist-type ]]; then
    set_plist_floor "$app" 13.3
  fi
  case "$defect" in
    over)
      /usr/bin/sed -i '' '/^MINOS=/d' "$plugin"
      print -r -- 'ARCH=arm64 x86_64' >> "$plugin"
      print -r -- 'MINOS_arm64=13.0' >> "$plugin"
      print -r -- 'MINOS_x86_64=14.0' >> "$plugin"
      ;;
    missing)
      /usr/bin/sed -i '' '/^MINOS=/d' "$plugin"
      ;;
    duplicate)
      /usr/bin/sed -i '' '/^MINOS=/d' "$plugin"
      print -r -- 'MINOS_arm64=13.0' >> "$plugin"
      print -r -- 'MINOS_arm64=13.1' >> "$plugin"
      ;;
    malformed)
      /usr/bin/sed -i '' '/^MINOS=/d' "$plugin"
      print -r -- 'MINOS_arm64=13.x' >> "$plugin"
      ;;
    platform)
      /usr/bin/sed -i '' '/^MINOS=/d' "$plugin"
      print -r -- 'MINOS_arm64=13.0' >> "$plugin"
      print -r -- 'PLATFORM_arm64=IOS' >> "$plugin"
      ;;
    plist) ;;
    plist-type)
      /usr/bin/plutil -replace LSMinimumSystemVersion -float 13.3 \
        "$app/Contents/Info.plist"
      ;;
    *) return 64 ;;
  esac
  snapshot_app "$app"
  if (
      export WAM_MACOS_RELEASE_FLOOR=13.3
      source "$bundle_library"
      wam_bundle_macos "$app" "$source_root/whisper-cli" \
        "$app/Contents/Resources/models/ggml-base.en.bin"
    ) >/dev/null 2>&1; then
    print -u2 "release floor defect was accepted: $label"
    return 1
  fi
  expect_unchanged "$app"
  expect_no_stage "$case_root" "release floor $label rejection"
}

run_release_floor_failure over-slice over
run_release_floor_failure missing-build-version missing
run_release_floor_failure duplicate-build-version duplicate
run_release_floor_failure malformed-build-version malformed
run_release_floor_failure wrong-platform platform
run_release_floor_failure mismatched-plist plist
run_release_floor_failure non-string-plist plist-type

partial_policy_root="$fixture_root/release-partial-policy"
partial_policy_app="$partial_policy_root/WAM.app"
mkdir -p "$partial_policy_root"
create_app "$partial_policy_app"
set_plist_floor "$partial_policy_app" 13.3
snapshot_app "$partial_policy_app"
if (
    export WAM_MACOS_RELEASE_FLOOR=13.3
    export WAM_MACOS_CODESIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
    source "$bundle_library"
    wam_bundle_macos "$partial_policy_app" "$source_root/whisper-cli" \
      "$partial_policy_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "partial Developer ID policy was accepted"
  exit 1
fi
expect_unchanged "$partial_policy_app"
expect_no_stage "$partial_policy_root" "partial signing policy rejection"

invalid_identity_root="$fixture_root/release-invalid-identity"
invalid_identity_app="$invalid_identity_root/WAM.app"
mkdir -p "$invalid_identity_root"
create_app "$invalid_identity_app"
set_plist_floor "$invalid_identity_app" 13.3
snapshot_app "$invalid_identity_app"
if (
    export WAM_MACOS_RELEASE_FLOOR=13.3
    export WAM_MACOS_CODESIGN_IDENTITY=ambiguous-name
    export WAM_MACOS_EXPECTED_SIGNING_AUTHORITY=\
'Developer ID Application: WAM Fixture (ABCDE12345)'
    export WAM_MACOS_EXPECTED_TEAM_ID=ABCDE12345
    source "$bundle_library"
    wam_bundle_macos "$invalid_identity_app" "$source_root/whisper-cli" \
      "$invalid_identity_app/Contents/Resources/models/ggml-base.en.bin"
  ) >/dev/null 2>&1; then
  print -u2 "invalid Developer ID identity was accepted"
  exit 1
fi
expect_unchanged "$invalid_identity_app"
expect_no_stage "$invalid_identity_root" "invalid signing identity rejection"

release_root="$fixture_root/release-success"
release_app="$release_root/WAM.app"
mkdir -p "$release_root"
create_app "$release_app"
set_plist_floor "$release_app" 13.3
release_plugin="$release_app/Contents/PlugIns/platforms/libqcocoa.dylib"
/usr/bin/sed -i '' '/^MINOS=/d' "$release_plugin"
print -r -- 'ARCH=arm64 x86_64' >> "$release_plugin"
print -r -- 'MINOS_arm64=13.0' >> "$release_plugin"
print -r -- 'MINOS_x86_64=13.3' >> "$release_plugin"
: > "$WAM_FIXTURE_CODESIGN_LOG"
if ! (
    export WAM_MACOS_RELEASE_FLOOR=13.3
    export WAM_MACOS_CODESIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
    export WAM_MACOS_EXPECTED_SIGNING_AUTHORITY=\
'Developer ID Application: WAM Fixture (ABCDE12345)'
    export WAM_MACOS_EXPECTED_TEAM_ID=ABCDE12345
    source "$bundle_library"
    wam_bundle_macos "$release_app" "$source_root/whisper-cli" \
      "$release_app/Contents/Resources/models/ggml-base.en.bin"
  ); then
  print -u2 "valid Developer ID release policy was rejected"
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
  "$release_app/Contents/Info.plist")" == 13.3 ]]
if grep '^sign|' "$WAM_FIXTURE_CODESIGN_LOG" | \
    grep -v '^sign|0123456789ABCDEF0123456789ABCDEF01234567|true|true|false|' >/dev/null; then
  print -u2 "release signing used unexpected identity, options, or --deep"
  exit 1
fi
last_release_sign="$(grep '^sign|' "$WAM_FIXTURE_CODESIGN_LOG" | tail -n 1)"
last_release_target="${last_release_sign##*|}"
if [[ "${last_release_target:t}" != WAM.app ||
      "$last_release_target" == */Contents/* ]]; then
  print -u2 "release app was not the final signing target"
  exit 1
fi

for signature_defect in sign authority team runtime timestamp get-task-allow trust; do
  defect_root="$fixture_root/release-signature-$signature_defect"
  defect_app="$defect_root/WAM.app"
  mkdir -p "$defect_root"
  create_app "$defect_app"
  set_plist_floor "$defect_app" 13.3
  snapshot_app "$defect_app"
  if (
      export WAM_MACOS_RELEASE_FLOOR=13.3
      export WAM_MACOS_CODESIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
      export WAM_MACOS_EXPECTED_SIGNING_AUTHORITY=\
'Developer ID Application: WAM Fixture (ABCDE12345)'
      export WAM_MACOS_EXPECTED_TEAM_ID=ABCDE12345
      export WAM_FIXTURE_SIGNATURE_DEFECT="$signature_defect"
      source "$bundle_library"
      wam_bundle_macos "$defect_app" "$source_root/whisper-cli" \
        "$defect_app/Contents/Resources/models/ggml-base.en.bin"
    ) >/dev/null 2>&1; then
    print -u2 "release signature defect was accepted: $signature_defect"
    exit 1
  fi
  expect_unchanged "$defect_app"
  expect_no_stage "$defect_root" "release signature $signature_defect rejection"
done

forged_root="$fixture_root/forged"
forged_app="$forged_root/WAM.app"
mkdir -p "$forged_root"
create_app "$forged_app"
snapshot_app "$forged_app"
if env WAM_BUNDLE_MACOS_STAGING_ACTIVE=forged \
    WAM_BUNDLE_MACOS_STAGING_TOKEN="$fixture_root/forged-token" \
    "$bundle_entry" "$forged_app" "$source_root/whisper-cli" \
    "$forged_app/Contents/Resources/models/ggml-base.en.bin" \
    >/dev/null 2>&1; then
  print -u2 "shipping entry accepted a forged inner mode"
  exit 1
fi
expect_unchanged "$forged_app"

print "bundle_macos lazy-mpv full transaction test passed"
