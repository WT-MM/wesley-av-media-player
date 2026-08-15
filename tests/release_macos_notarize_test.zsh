#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
release_script="$repo_root/scripts/release_macos_notarize.zsh"
fixture_root="$(/usr/bin/mktemp -d \
  "${TMPDIR:-/tmp}/wam-release-notarize-test.XXXXXX")"
trap '/bin/rm -rf -- "$fixture_root"' EXIT

expected_team="ABCDE12345"
expected_authority="Developer ID Application: WAM Test ($expected_team)"
fixed_checksum="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
tool_directory="$fixture_root/tools"
mkdir -p "$tool_directory"

fail() {
  print -u2 -- "release_macos_notarize test failed: $*"
  exit 1
}

typeset mock_tool_source
IFS= read -r -d '' mock_tool_source <<'MOCK_TOOL' || true
#!/bin/zsh
set -euo pipefail

tool_name="${0:t}"
log_path="${WAM_RELEASE_FAKE_LOG:?}"
state_root="${WAM_RELEASE_FAKE_STATE:?}"
failure="${WAM_RELEASE_FAKE_FAILURE:-}"
phase=pre
[[ ! -f "$state_root/ticket" ]] || phase=post

log_event() {
  print -r -- "$1" >> "$log_path"
}

case "$tool_name" in
  find)
    log_event find
    /usr/bin/find "$@"
    ;;
  file)
    target="${@: -1}"
    if [[ "${target:t}" == WAM ]]; then
      log_event file-macho
      print -r -- "Mach-O 64-bit arm64 executable"
    else
      print -r -- "XML 1.0 document text"
    fi
    ;;
  lipo)
    log_event "lipo-$phase"
    [[ "$1" == -archs && $# == 2 ]] || exit 64
    print -r -- arm64
    ;;
  codesign)
    arguments=" $* "
    if [[ "$arguments" == *" --verify "* ]]; then
      if [[ "$arguments" == *" --deep "* ]]; then
        log_event "codesign-deep-$phase"
      else
        log_event "codesign-verify-$phase"
      fi
      [[ "$failure" != codesign_verify ]] || exit 1
      if [[ "$arguments" == *" -R "* && "$failure" == trust ]]; then
        exit 1
      fi
      exit 0
    fi
    if [[ "$arguments" == *" --entitlements "* ]]; then
      log_event "codesign-entitlements-$phase"
      entitlement_index=${@[(i)--entitlements]}
      entitlement_output="${@[$(( entitlement_index + 1 ))]}"
      if [[ "$failure" == debug_entitlement ]]; then
        print -r -- \
          '<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>' \
          > "$entitlement_output"
      else
        print -r -- '<plist><dict/></plist>' > "$entitlement_output"
      fi
      exit 0
    fi
    if [[ "$arguments" == *" --display "* ]]; then
      log_event "codesign-metadata-$phase"
      authority="$WAM_MACOS_EXPECTED_SIGNING_AUTHORITY"
      team="$WAM_MACOS_EXPECTED_TEAM_ID"
      [[ "$failure" != wrong_authority ]] ||
        authority="Developer ID Application: Wrong Signer ($team)"
      [[ "$failure" != wrong_team ]] || team="ZZZZZ99999"
      print -u2 -- "Executable=${@: -1}"
      print -u2 -- "Authority=$authority"
      print -u2 -- "TeamIdentifier=$team"
      if [[ "$failure" != missing_runtime ]]; then
        print -u2 -- \
          "CodeDirectory v=20500 size=500 flags=0x10000(runtime) hashes=10"
      else
        print -u2 -- \
          "CodeDirectory v=20500 size=500 flags=0x0(notruntime) hashes=10"
      fi
      if [[ "$failure" != missing_timestamp ]]; then
        print -u2 -- "Timestamp=Aug 13, 2026 at 12:00:00"
      else
        print -u2 -- "Signed Time=Aug 13, 2026 at 12:00:00"
      fi
      [[ "$failure" != duplicate_timestamp ]] || print -u2 -- "Timestamp="
      exit 0
    fi
    exit 64
    ;;
  ditto)
    destination="${@: -1}"
    if [[ "${destination:t}" == submission.zip ]]; then
      log_event ditto-submission
      print -r -- unstapled > "$destination"
    elif [[ "${destination:t}" == final.zip ]]; then
      log_event ditto-final
      [[ -f "$state_root/ticket" ]] || exit 1
      print -r -- stapled > "$destination"
    else
      exit 64
    fi
    ;;
  xcrun)
    if [[ "$1" == notarytool && "$2" == submit ]]; then
      log_event notary-submit
      arguments=" $* "
      [[ "$arguments" == *" --wait "* &&
         "$arguments" == *" --output-format json "* &&
         "$arguments" == *" --key "* &&
         "$arguments" == *" --key-id "* &&
         "$arguments" == *" --issuer "* ]] || exit 64
      [[ -f "$3" ]] || exit 1
      case "$failure" in
        notary_command) exit 1 ;;
        malformed_notary) print -r -- '{not-json' ;;
        rejected_notary) print -r -- '{"status":"Invalid"}' ;;
        *) print -r -- '{"status":"Accepted"}' ;;
      esac
      exit 0
    fi
    if [[ "$1" == stapler && "$2" == staple ]]; then
      log_event stapler-staple
      [[ "$failure" != staple ]] || exit 1
      : > "$state_root/ticket"
      exit 0
    fi
    if [[ "$1" == stapler && "$2" == validate ]]; then
      log_event stapler-validate
      [[ -f "$state_root/ticket" ]] || exit 1
      [[ "$failure" != staple_validate ]] || exit 1
      exit 0
    fi
    exit 64
    ;;
  plutil)
    target="${@: -1}"
    if [[ "$1" == -lint ]]; then
      exit 0
    fi
    if [[ "${target:t}" == entitlements.* ]]; then
      if [[ "$failure" == debug_entitlement ]]; then
        print -r -- true
        exit 0
      fi
      exit 1
    fi
    if [[ "${target:t}" == Info.plist ]]; then
      log_event plist-floor
      [[ "$failure" != floor_type ]] || exit 1
      print -r -- "${WAM_RELEASE_FAKE_PACKAGED_FLOOR:-13.3}"
      exit 0
    fi
    log_event notary-status
    case "$failure" in
      malformed_notary) exit 1 ;;
      rejected_notary) print -r -- Invalid ;;
      *) print -r -- Accepted ;;
    esac
    ;;
  shasum)
    log_event shasum
    print -r -- \
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ${@: -1}"
    ;;
  spctl)
    log_event spctl
    [[ -f "$state_root/ticket" ]] || exit 1
    [[ "$failure" != spctl ]] || exit 1
    ;;
  *)
    exit 64
    ;;
esac
MOCK_TOOL

for tool_name in codesign ditto file find lipo plutil shasum spctl xcrun; do
  print -r -- "$mock_tool_source" > "$tool_directory/$tool_name"
  chmod +x "$tool_directory/$tool_name"
done

case_root=""
case_app=""
case_output_directory=""
case_output=""
case_key=""
case_log=""
case_state=""
case_status=0

create_case() {
  local name="$1"
  case_root="$fixture_root/$name"
  case_app="$case_root/WAM.app"
  case_output_directory="$case_root/output"
  case_output="$case_output_directory/WAM-test.zip"
  case_key="$case_root/notary-key.p8"
  case_log="$case_root/tool.log"
  case_state="$case_root/state"
  mkdir -p "$case_app/Contents/MacOS" \
    "$case_output_directory" "$case_state"
  print -r -- '<plist><dict/></plist>' > \
    "$case_app/Contents/Info.plist"
  print -r -- 'fixture Mach-O' > "$case_app/Contents/MacOS/WAM"
  chmod +x "$case_app/Contents/MacOS/WAM"
  print -r -- '-----BEGIN PRIVATE KEY-----
fixture
-----END PRIVATE KEY-----' > "$case_key"
  chmod 600 "$case_key"
  : > "$case_log"
}

invoke_release() {
  local failure="${1:-}"
  local packaged_floor="${2:-13.3}"
  set +e
  /usr/bin/env \
    WAM_RELEASE_MACOS_POLICY_TESTING=1 \
    WAM_RELEASE_MACOS_TEST_ROOT="$fixture_root" \
    WAM_RELEASE_MACOS_TOOL_DIR="$tool_directory" \
    WAM_RELEASE_FAKE_LOG="$case_log" \
    WAM_RELEASE_FAKE_STATE="$case_state" \
    WAM_RELEASE_FAKE_FAILURE="$failure" \
    WAM_RELEASE_FAKE_PACKAGED_FLOOR="$packaged_floor" \
    WAM_MACOS_RELEASE_FLOOR=13.3 \
    WAM_MACOS_CODESIGN_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567 \
    WAM_MACOS_EXPECTED_SIGNING_AUTHORITY="$expected_authority" \
    WAM_MACOS_EXPECTED_TEAM_ID="$expected_team" \
    WAM_MACOS_NOTARY_KEY="$case_key" \
    WAM_MACOS_NOTARY_KEY_ID=KEYID12345 \
    WAM_MACOS_NOTARY_ISSUER_ID=11111111-2222-3333-4444-555555555555 \
    /bin/zsh "$release_script" "$case_app" "$case_output" \
    > "$case_root/stdout" 2> "$case_root/stderr"
  case_status=$?
  set -e
}

assert_no_transaction_residue() {
  local -a residue
  residue=("$case_output_directory"/.wam-release.*(N))
  if (( ${#residue[@]} != 0 )); then
    fail "transaction residue remained for ${case_root:t}"
  fi
}

assert_no_published_artifact() {
  [[ ! -e "$case_output" && ! -L "$case_output" ]] ||
    fail "unexpected release zip for ${case_root:t}"
  [[ ! -e "$case_output.sha256" && ! -L "$case_output.sha256" ]] ||
    fail "unexpected release checksum for ${case_root:t}"
  assert_no_transaction_residue
}

create_case success
invoke_release
(( case_status == 0 )) || {
  /bin/cat "$case_root/stderr" >&2
  fail "successful mocked release returned $case_status"
}
[[ "$(<"$case_output")" == stapled ]] ||
  fail "published archive was not created after stapling"
[[ "$(<"$case_output.sha256")" == "$fixed_checksum  WAM-test.zip" ]] ||
  fail "published checksum sidecar is not deterministic"
typeset expected_trace
IFS= read -r -d '' expected_trace <<'EXPECTED_TRACE' || true
plist-floor
find
file-macho
codesign-verify-pre
lipo-pre
codesign-metadata-pre
codesign-entitlements-pre
codesign-verify-pre
lipo-pre
codesign-metadata-pre
codesign-entitlements-pre
codesign-deep-pre
ditto-submission
notary-submit
notary-status
stapler-staple
stapler-validate
codesign-verify-post
lipo-post
codesign-metadata-post
codesign-entitlements-post
codesign-verify-post
lipo-post
codesign-metadata-post
codesign-entitlements-post
codesign-deep-post
spctl
ditto-final
shasum
EXPECTED_TRACE
print -rn -- "$expected_trace" > "$case_root/expected.log"
if ! /usr/bin/diff -u "$case_root/expected.log" "$case_log"; then
  fail "successful release command order changed"
fi
assert_no_transaction_residue

for failure_mode in codesign_verify trust wrong_authority wrong_team \
    missing_runtime missing_timestamp duplicate_timestamp debug_entitlement; do
  create_case "$failure_mode"
  invoke_release "$failure_mode"
  (( case_status != 0 )) ||
    fail "$failure_mode unexpectedly passed signature policy"
  if /usr/bin/grep -q '^notary-submit$' "$case_log"; then
    fail "$failure_mode reached Apple submission"
  fi
  assert_no_published_artifact
done

create_case floor_mismatch
invoke_release "" 14.0
(( case_status != 0 )) || fail "packaged floor mismatch unexpectedly passed"
[[ ! -s "$case_log" || "$(<"$case_log")" == plist-floor ]] ||
  fail "packaged floor mismatch advanced past plist inspection"
assert_no_published_artifact

create_case floor_type
invoke_release floor_type
(( case_status != 0 )) || fail "non-string packaged floor unexpectedly passed"
[[ ! -s "$case_log" || "$(<"$case_log")" == plist-floor ]] ||
  fail "non-string packaged floor advanced past plist inspection"
assert_no_published_artifact

for failure_mode in notary_command rejected_notary malformed_notary; do
  create_case "$failure_mode"
  invoke_release "$failure_mode"
  (( case_status != 0 )) ||
    fail "$failure_mode unexpectedly passed notarization policy"
  /usr/bin/grep -q '^notary-submit$' "$case_log" ||
    fail "$failure_mode did not exercise mocked Apple submission"
  if /usr/bin/grep -q '^stapler-staple$' "$case_log"; then
    fail "$failure_mode reached ticket stapling"
  fi
  assert_no_published_artifact
done

create_case staple
invoke_release staple
(( case_status != 0 )) || fail "ticket-stapling failure passed"
/usr/bin/grep -q '^stapler-staple$' "$case_log" ||
  fail "ticket-stapling failure case did not reach stapler"
if /usr/bin/grep -q '^stapler-validate$' "$case_log"; then
  fail "ticket validation ran after failed stapling"
fi
assert_no_published_artifact

create_case staple_validate
invoke_release staple_validate
(( case_status != 0 )) || fail "stapler validation failure passed"
/usr/bin/grep -q '^stapler-staple$' "$case_log" ||
  fail "stapler validation case did not staple"
/usr/bin/grep -q '^stapler-validate$' "$case_log" ||
  fail "stapler validation case did not validate"
if /usr/bin/grep -q '^spctl$' "$case_log"; then
  fail "Gatekeeper ran after failed stapler validation"
fi
assert_no_published_artifact

create_case spctl
invoke_release spctl
(( case_status != 0 )) || fail "Gatekeeper failure passed"
/usr/bin/grep -q '^spctl$' "$case_log" ||
  fail "Gatekeeper failure case did not assess the app"
if /usr/bin/grep -q '^ditto-final$' "$case_log"; then
  fail "final archive was created after Gatekeeper rejection"
fi
assert_no_published_artifact

create_case existing_output
print -r -- preserve-me > "$case_output"
invoke_release
(( case_status != 0 )) || fail "pre-existing output was overwritten"
[[ "$(<"$case_output")" == preserve-me ]] ||
  fail "pre-existing output content changed"
[[ ! -e "$case_output.sha256" ]] ||
  fail "checksum was created beside a pre-existing output"
assert_no_transaction_residue

create_case existing_checksum
print -r -- preserve-checksum > "$case_output.sha256"
invoke_release
(( case_status != 0 )) || fail "pre-existing checksum was overwritten"
[[ ! -e "$case_output" ]] ||
  fail "release zip was created beside a pre-existing checksum"
[[ "$(<"$case_output.sha256")" == preserve-checksum ]] ||
  fail "pre-existing checksum content changed"
assert_no_transaction_residue

create_case injection_guard
set +e
/usr/bin/env \
  WAM_RELEASE_MACOS_TEST_ROOT="$fixture_root" \
  WAM_RELEASE_MACOS_TOOL_DIR="$tool_directory" \
  /bin/zsh "$release_script" "$case_app" "$case_output" \
  > "$case_root/stdout" 2> "$case_root/stderr"
case_status=$?
set -e
(( case_status != 0 )) || fail "unguarded test-tool injection passed"
[[ ! -s "$case_log" ]] ||
  fail "unguarded test-tool injection executed a mock command"
assert_no_published_artifact

print -r -- "release_macos_notarize mocked transaction test passed"
