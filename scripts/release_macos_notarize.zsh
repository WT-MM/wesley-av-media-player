#!/bin/zsh
set -euo pipefail
setopt extendedglob
export LC_ALL=C

die() {
  print -u2 -- "$*"
  exit 1
}

usage() {
  print -u2 -- "usage: release_macos_notarize.zsh APP OUTPUT.zip"
  exit 64
}

(( $# == 2 )) || usage

policy_testing="${WAM_RELEASE_MACOS_POLICY_TESTING:-0}"
test_root_input="${WAM_RELEASE_MACOS_TEST_ROOT:-}"
test_tool_directory_input="${WAM_RELEASE_MACOS_TOOL_DIR:-}"
if [[ "$policy_testing" != 0 && "$policy_testing" != 1 ]]; then
  die "WAM_RELEASE_MACOS_POLICY_TESTING must be 0 or 1"
fi

test_root=""
test_tool_directory=""
if [[ "$policy_testing" == 1 ]]; then
  [[ -n "$test_root_input" && -n "$test_tool_directory_input" ]] ||
    die "macOS release policy testing requires a test root and tool directory"
  [[ -d "$test_root_input" && ! -L "$test_root_input" ]] ||
    die "macOS release policy test root must be a real directory"
  [[ -d "$test_tool_directory_input" &&
     ! -L "$test_tool_directory_input" ]] ||
    die "macOS release policy tool directory must be a real directory"
  test_root="${test_root_input:A}"
  test_tool_directory="${test_tool_directory_input:A}"
  [[ "$test_tool_directory" == "$test_root"/* ]] ||
    die "macOS release policy tools must remain inside the test root"
elif [[ -n "$test_root_input" || -n "$test_tool_directory_input" ]]; then
  die "macOS release test injection is disabled"
fi

resolve_tool() {
  local name="$1"
  local production_path="$2"
  local candidate
  if [[ "$policy_testing" == 1 ]]; then
    candidate="$test_tool_directory/$name"
    [[ -f "$candidate" && -x "$candidate" && ! -L "$candidate" ]] ||
      die "missing guarded macOS release test tool: $name"
    candidate="${candidate:A}"
    [[ "$candidate" == "$test_root"/* ]] ||
      die "macOS release test tool escaped the guarded root: $name"
    print -r -- "$candidate"
    return
  fi
  [[ -x "$production_path" && ! -L "$production_path" ]] ||
    die "required macOS release tool is unavailable: $production_path"
  print -r -- "$production_path"
}

CODESIGN="$(resolve_tool codesign /usr/bin/codesign)"
DITTO="$(resolve_tool ditto /usr/bin/ditto)"
FILE_TOOL="$(resolve_tool file /usr/bin/file)"
FIND_TOOL="$(resolve_tool find /usr/bin/find)"
LIPO="$(resolve_tool lipo /usr/bin/lipo)"
PLUTIL="$(resolve_tool plutil /usr/bin/plutil)"
SHASUM="$(resolve_tool shasum /usr/bin/shasum)"
SPCTL="$(resolve_tool spctl /usr/sbin/spctl)"
XCRUN="$(resolve_tool xcrun /usr/bin/xcrun)"

release_floor="${WAM_MACOS_RELEASE_FLOOR:-}"
codesign_identity="${WAM_MACOS_CODESIGN_IDENTITY:-}"
expected_authority="${WAM_MACOS_EXPECTED_SIGNING_AUTHORITY:-}"
expected_team="${WAM_MACOS_EXPECTED_TEAM_ID:-}"
notary_key_input="${WAM_MACOS_NOTARY_KEY:-}"
notary_key_id="${WAM_MACOS_NOTARY_KEY_ID:-}"
notary_issuer_id="${WAM_MACOS_NOTARY_ISSUER_ID:-}"

[[ -n "$release_floor" ]] || die "WAM_MACOS_RELEASE_FLOOR is required"
[[ -n "$codesign_identity" ]] ||
  die "WAM_MACOS_CODESIGN_IDENTITY is required"
[[ -n "$expected_authority" ]] ||
  die "WAM_MACOS_EXPECTED_SIGNING_AUTHORITY is required"
[[ -n "$expected_team" ]] ||
  die "WAM_MACOS_EXPECTED_TEAM_ID is required"
[[ -n "$notary_key_input" ]] || die "WAM_MACOS_NOTARY_KEY is required"
[[ -n "$notary_key_id" ]] || die "WAM_MACOS_NOTARY_KEY_ID is required"
[[ -n "$notary_issuer_id" ]] ||
  die "WAM_MACOS_NOTARY_ISSUER_ID is required"

for single_line_value in "$release_floor" "$codesign_identity" \
    "$expected_authority" \
    "$expected_team" "$notary_key_id" "$notary_issuer_id"; do
  [[ "$single_line_value" != *$'\n'* &&
     "$single_line_value" != *$'\r'* ]] ||
    die "macOS release policy values must be single-line"
done

(( ${#codesign_identity} == 40 )) ||
  die "WAM_MACOS_CODESIGN_IDENTITY must be a certificate SHA-1"
[[ "$codesign_identity" != *[^0-9A-Fa-f]* ]] ||
  die "WAM_MACOS_CODESIGN_IDENTITY must be a certificate SHA-1"
[[ "$notary_key_id" == [A-Z0-9]## ]] ||
  die "notary API key ID contains invalid characters"
(( ${#notary_key_id} == 10 )) ||
  die "notary API key ID must contain 10 characters"
[[ "$notary_issuer_id" == \
  [0-9A-Fa-f]##-[0-9A-Fa-f]##-[0-9A-Fa-f]##-[0-9A-Fa-f]##-[0-9A-Fa-f]## ]] ||
  die "notary API issuer ID must be a UUID"
typeset -a issuer_parts
issuer_parts=("${(@s:-:)notary_issuer_id}")
[[ "${#issuer_parts[1]}" == 8 && "${#issuer_parts[2]}" == 4 &&
   "${#issuer_parts[3]}" == 4 && "${#issuer_parts[4]}" == 4 &&
   "${#issuer_parts[5]}" == 12 ]] ||
  die "notary API issuer ID must be a UUID"

typeset -a release_floor_parts
release_floor_parts=("${(@s:.:)release_floor}")
(( ${#release_floor_parts[@]} == 2 ||
   ${#release_floor_parts[@]} == 3 )) ||
  die "WAM_MACOS_RELEASE_FLOOR must be a dotted numeric version"
for release_floor_part in "${release_floor_parts[@]}"; do
  [[ -n "$release_floor_part" &&
     "$release_floor_part" != *[^0-9]* &&
     ( "$release_floor_part" == 0 || "$release_floor_part" != 0* ) &&
     ${#release_floor_part} -le 3 ]] ||
    die "WAM_MACOS_RELEASE_FLOOR must be a dotted numeric version"
done

[[ "$expected_authority" == "Developer ID Application: "* ]] ||
  die "expected signing authority is not a Developer ID Application identity"
(( ${#expected_team} == 10 )) ||
  die "expected Developer ID team must contain 10 characters"
[[ "$expected_team" != *[^A-Z0-9]* ]] ||
  die "expected Developer ID team contains invalid characters"
[[ "$expected_authority" == *" ($expected_team)" ]] ||
  die "expected signing authority does not belong to the expected team"

[[ -f "$notary_key_input" && ! -L "$notary_key_input" ]] ||
  die "notary API key must be a regular, non-symlink file"
notary_key="${notary_key_input:A}"
notary_key_mode="$(/usr/bin/stat -f '%Lp' "$notary_key")"
[[ "$notary_key_mode" == 400 || "$notary_key_mode" == 600 ]] ||
  die "notary API key permissions must be owner-readable only"
if ! /usr/bin/grep -q '^-----BEGIN PRIVATE KEY-----$' "$notary_key" ||
    ! /usr/bin/grep -q '^-----END PRIVATE KEY-----$' "$notary_key"; then
  die "notary API key is not a PEM private key"
fi

app_input="$1"
output_input="$2"
[[ -d "$app_input" && ! -L "$app_input" ]] ||
  die "release input must be a real application directory"
app_path="${app_input:A}"
[[ "${app_path:t}" == *.app ]] || die "release input must end in .app"
info_plist="$app_path/Contents/Info.plist"
[[ -d "$app_path/Contents" && -f "$info_plist" &&
   ! -L "$info_plist" && "$info_plist" == "${info_plist:A}" ]] ||
  die "release input is not a complete application bundle"

output_parent_input="${output_input:h}"
output_name="${output_input:t}"
[[ "$output_name" == *.zip && "$output_name" != *$'\n'* &&
   "$output_name" != *$'\r'* ]] ||
  die "release output must be a single-line .zip path"
[[ -d "$output_parent_input" && ! -L "$output_parent_input" ]] ||
  die "release output directory must already exist and not be a symlink"
output_parent="${output_parent_input:A}"
output_zip="$output_parent/$output_name"
output_checksum="$output_zip.sha256"
[[ ! -e "$output_zip" && ! -L "$output_zip" ]] ||
  die "release output already exists: $output_zip"
[[ ! -e "$output_checksum" && ! -L "$output_checksum" ]] ||
  die "release checksum already exists: $output_checksum"
[[ "$output_zip" != "$app_path" &&
   "$output_zip" != "$app_path"/* ]] ||
  die "release output cannot be placed inside the application"

if [[ "$policy_testing" == 1 ]]; then
  [[ "$app_path" == "$test_root"/* ]] ||
    die "test application escaped the guarded macOS release root"
  [[ "$output_parent" == "$test_root" ||
     "$output_parent" == "$test_root"/* ]] ||
    die "test output escaped the guarded macOS release root"
  [[ "$notary_key" == "$test_root"/* ]] ||
    die "test notary key escaped the guarded macOS release root"
fi

if ! packaged_floor="$("$PLUTIL" -extract LSMinimumSystemVersion raw \
    -expect string -o - "$info_plist")"; then
  die "could not read the packaged minimum macOS version"
fi
[[ "$packaged_floor" == "$release_floor" ]] ||
  die "packaged minimum macOS is $packaged_floor; expected $release_floor"

temporary_root=""
published_zip=false
published_checksum=false
transaction_complete=false
cleanup_release_transaction() {
  local exit_code="${1:-$?}"
  if [[ "$transaction_complete" != true ]]; then
    [[ "$published_zip" != true ]] || /bin/rm -f -- "$output_zip"
    [[ "$published_checksum" != true ]] ||
      /bin/rm -f -- "$output_checksum"
  fi
  if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
    /bin/rm -rf -- "$temporary_root"
  fi
  return "$exit_code"
}
trap 'cleanup_release_transaction $?' EXIT

if ! temporary_root="$(/usr/bin/mktemp -d \
    "$output_parent/.wam-release.XXXXXX")"; then
  die "could not create the macOS release transaction directory"
fi
[[ -d "$temporary_root" && ! -L "$temporary_root" &&
   "$temporary_root" == "$output_parent"/.wam-release.* ]] ||
  die "macOS release transaction directory failed validation"

typeset -a bundle_machos
inventory_path="$temporary_root/bundle-files"
if ! "$FIND_TOOL" "$app_path/Contents" -type f -print0 > "$inventory_path"; then
  die "could not inventory the application bundle"
fi
while IFS= read -r -d '' candidate; do
  if ! description="$("$FILE_TOOL" -b "$candidate")"; then
    die "could not inspect packaged file: $candidate"
  fi
  [[ "$description" == *Mach-O* ]] || continue
  canonical_candidate="${candidate:A}"
  [[ -f "$canonical_candidate" && ! -L "$canonical_candidate" &&
     "$canonical_candidate" == "$app_path/Contents"/* ]] ||
    die "Mach-O inventory target escaped or changed identity: $candidate"
  bundle_machos+=("$canonical_candidate")
done < "$inventory_path"
(( ${#bundle_machos[@]} > 0 )) ||
  die "release application contains no Mach-O payload"
bundle_machos=("${(@oa)bundle_machos}")

release_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$expected_team\""

verify_signature_metadata() {
  local target="$1"
  local architecture_source target_arches target_arch
  local metadata entitlements_file line timestamp_value
  local authority authority_count team team_count
  local runtime_count timestamp_count timestamp_total

  if ! "$CODESIGN" --verify --strict --all-architectures --verbose=2 \
      -R "$release_requirement" "$target"; then
    die "Developer ID trust verification failed: $target"
  fi

  architecture_source="$target"
  [[ "$target" != "$app_path" ]] ||
    architecture_source="$app_path/Contents/MacOS/WAM"
  if ! target_arches="$("$LIPO" -archs "$architecture_source")" ||
      [[ -z "$target_arches" ]]; then
    die "could not inspect signed target architectures: $target"
  fi

  for target_arch in ${=target_arches}; do
    if ! metadata="$("$CODESIGN" --display --verbose=4 \
        --arch "$target_arch" "$target" 2>&1)"; then
      die "could not inspect code-signature metadata: $target ($target_arch)"
    fi
    authority=""
    authority_count=0
    team=""
    team_count=0
    runtime_count=0
    timestamp_count=0
    timestamp_total=0
    for line in "${(@f)metadata}"; do
      if [[ "$line" == Authority=* ]]; then
        (( authority_count += 1 ))
        [[ -n "$authority" ]] || authority="${line#Authority=}"
      fi
      if [[ "$line" == TeamIdentifier=* ]]; then
        (( team_count += 1 ))
        team="${line#TeamIdentifier=}"
      fi
      if [[ "$line" == CodeDirectory* ]] &&
          /usr/bin/grep -Eq \
            '^CodeDirectory .*flags=.*\(([^)]*[,[:space:]])?runtime([,[:space:]][^)]*)?\)' \
            <<< "$line"; then
        (( runtime_count += 1 ))
      fi
      if [[ "$line" == Timestamp=* ]]; then
        (( timestamp_total += 1 ))
        timestamp_value="${line#Timestamp=}"
        if [[ -n "$timestamp_value" && "$timestamp_value" != none ]]; then
          (( timestamp_count += 1 ))
        fi
      fi
    done
    (( authority_count >= 1 )) && [[ "$authority" == "$expected_authority" ]] ||
      die "unexpected Developer ID signing authority: $target ($target_arch)"
    (( team_count == 1 )) && [[ "$team" == "$expected_team" ]] ||
      die "unexpected Developer ID team: $target ($target_arch)"
    (( runtime_count == 1 )) ||
      die "hardened runtime is missing from code signature: $target ($target_arch)"
    (( timestamp_total == 1 && timestamp_count == 1 )) ||
      die "secure timestamp is missing from code signature: $target ($target_arch)"

    if ! entitlements_file="$(/usr/bin/mktemp \
        "$temporary_root/entitlements.XXXXXX")"; then
      die "could not create a release entitlement audit file"
    fi
    if ! "$CODESIGN" --display --arch "$target_arch" --xml \
        --entitlements "$entitlements_file" "$target" >/dev/null 2>&1; then
      /bin/rm -f -- "$entitlements_file"
      die "could not inspect code-signature entitlements: $target ($target_arch)"
    fi
    if [[ -s "$entitlements_file" ]]; then
      if ! "$PLUTIL" -lint "$entitlements_file" >/dev/null; then
        /bin/rm -f -- "$entitlements_file"
        die "code-signature entitlements are malformed: $target ($target_arch)"
      fi
      if "$PLUTIL" -extract 'com\.apple\.security\.get-task-allow' raw \
          -o - "$entitlements_file" >/dev/null 2>&1; then
        /bin/rm -f -- "$entitlements_file"
        die "development get-task-allow entitlement is present: $target ($target_arch)"
      fi
    fi
    /bin/rm -f -- "$entitlements_file"
  done
}

verify_complete_application() {
  local target
  for target in "${bundle_machos[@]}"; do
    verify_signature_metadata "$target"
  done
  verify_signature_metadata "$app_path"
  if ! "$CODESIGN" --verify --deep --strict --verbose=2 "$app_path"; then
    die "deep application code-signature verification failed"
  fi
}

verify_complete_application

submission_zip="$temporary_root/submission.zip"
notary_result="$temporary_root/notary-result.json"
if ! "$DITTO" -c -k --sequesterRsrc --keepParent \
    "$app_path" "$submission_zip"; then
  die "could not create the notarization submission archive"
fi
[[ -f "$submission_zip" && -s "$submission_zip" &&
   ! -L "$submission_zip" ]] ||
  die "notarization submission archive was not produced"

if ! "$XCRUN" notarytool submit "$submission_zip" \
    --key "$notary_key" \
    --key-id "$notary_key_id" \
    --issuer "$notary_issuer_id" \
    --wait --output-format json > "$notary_result"; then
  die "Apple notarization submission failed"
fi
if ! notary_status="$("$PLUTIL" -extract status raw -o - \
    "$notary_result")"; then
  die "could not parse Apple notarization result"
fi
[[ "$notary_status" == Accepted ]] ||
  die "Apple notarization did not accept the application: $notary_status"

if ! "$XCRUN" stapler staple -v "$app_path"; then
  die "could not staple the notarization ticket"
fi
if ! "$XCRUN" stapler validate -v "$app_path"; then
  die "stapled notarization ticket failed validation"
fi

verify_complete_application
if ! "$SPCTL" --assess --type execute --verbose=4 "$app_path"; then
  die "Gatekeeper rejected the notarized application"
fi

final_zip="$temporary_root/final.zip"
checksum_file="$temporary_root/final.zip.sha256"
if ! "$DITTO" -c -k --sequesterRsrc --keepParent \
    "$app_path" "$final_zip"; then
  die "could not create the post-staple release archive"
fi
[[ -f "$final_zip" && -s "$final_zip" && ! -L "$final_zip" ]] ||
  die "post-staple release archive was not produced"

if ! checksum_output="$("$SHASUM" -a 256 "$final_zip")"; then
  die "could not compute the release archive checksum"
fi
checksum="${checksum_output%%[[:space:]]*}"
(( ${#checksum} == 64 )) || die "release checksum has an invalid length"
[[ "$checksum" != *[^0-9A-Fa-f]* ]] ||
  die "release checksum contains invalid characters"
print -r -- "${checksum:l}  $output_name" > "$checksum_file"

/bin/mv "$final_zip" "$output_zip"
published_zip=true
/bin/mv "$checksum_file" "$output_checksum"
published_checksum=true
transaction_complete=true
/bin/rm -rf -- "$temporary_root"
temporary_root=""

print -r -- "Created notarized macOS release: $output_zip"
print -r -- "SHA-256: ${checksum:l}"
