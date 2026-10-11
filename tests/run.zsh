#!/bin/zsh
setopt extendedglob pipefail
set -eu

ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PATH="$ROOT/tests/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export MOCK_API_LOG="$TMP/api.log"
export MOCK_CREATE_BODY="$TMP/create.json"
export MOCK_MANIFEST="$TMP/manifest.json"
export MOCK_RETRY_COUNT="$TMP/retry.count"
export MOCK_FAIL_COUNT="$TMP/fail.count"
export MOCK_SIPS_LOG="$TMP/sips.log"
export MOCK_UPLOADED_SMALL="$TMP/uploaded-small.jpg"
export MOCK_UPLOADED_LARGE="$TMP/uploaded-large.jpg"
export MOCK_ACTIVE_FILE="$TMP/active"
export MOCK_ACTIVE_LOCK="$TMP/active.lock"
export MOCK_MAX_ACTIVE="$TMP/max-active"
export TMPDIR="$TMP"
mkdir -p "$HOME" "$TMP/photos/sub folder" "$TMP/zsh"
export ZDOTDIR="$TMP/zsh"
print -r -- "sk""_live_mock_test" > "$HOME/.mock-keychain"
chmod 600 "$HOME/.mock-keychain"
for name in large small retry fail-once; do cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/photos/$name.jpg"; done
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/photos/sub folder/日本 photo.jpg"

function ok() { print -r -- "ok - $1"; }
function papat_cli() { /bin/zsh -f "$ROOT/papat" "$@"; }
function assert_contains() {
  local file="$1" needle="$2"
  [[ "$(<"$file")" == *"$needle"* ]] || { print -u2 -r -- "missing '$needle' in $file"; exit 1; }
}

papat_cli status --json > "$TMP/status.json"
assert_contains "$TMP/status.json" '"current":"v1"'
ok 'status sends Keychain API key through the mock only'

[[ "$(papat_cli --version)" == '0.1.0' ]] || { print -u2 'version command returned an unexpected value'; exit 1; }
ok 'version command reports the installed CLI version'

if papat_cli upload "$TMP/photos" --days 3 > "$TMP/invalid.out" 2>&1; then
  print -u2 'invalid days unexpectedly succeeded'; exit 1
fi
if papat_cli upload "$TMP/photos" --key-color red > "$TMP/invalid.out" 2>&1; then
  print -u2 'invalid key color unexpectedly succeeded'; exit 1
fi
ok 'upload rejects invalid option values'

if papat_cli upload "$TMP/photos" --title '案件 "A"' --days 7 \
    --key-color '#0066CC' --passcode 'SAFE-42' > "$TMP/first.out" 2>&1; then
  print -u2 'first upload should fail once to exercise resume'; exit 1
fi
assert_contains "$TMP/first.out" 'https://papat.app/t/tenant-test/s/sid-test/'
assert_contains "$TMP/first.out" 'SAFE-42'
assert_contains "$MOCK_CREATE_BODY" '"passcode_hash"'
assert_contains "$MOCK_CREATE_BODY" '"key_color":"#0066CC"'
assert_contains "$TMP/first.out" 'rate limited'
[[ -f "$MOCK_MAX_ACTIVE" ]] || { print -u2 'parallel upload counter missing'; exit 1; }
(( $(<"$MOCK_MAX_ACTIVE") >= 2 && $(<"$MOCK_MAX_ACTIVE") <= 4 )) || { print -u2 'uploads did not stay within the 4-worker pool'; exit 1; }
ok 'gallery details print before upload and 429 is retried'

papat_cli jobs --json > "$TMP/jobs.json"
assert_contains "$TMP/jobs.json" '"status":"failed"'

papat_cli upload "$TMP/photos" --json > "$TMP/resume.json" 2> "$TMP/resume.err"
assert_contains "$TMP/resume.json" '"sid":"sid-test"'
assert_contains "$TMP/resume.err" 'manifest を更新'
assert_contains "$MOCK_MANIFEST" '"count":5'
assert_contains "$MOCK_MANIFEST" '"key_color":"#0066CC"'
assert_contains "$MOCK_MANIFEST" 'papat-cli-'
assert_contains "$MOCK_API_LOG" '/photos/sub%20folder/%E6%97%A5%E6%9C%AC%20photo.jpg'
assert_contains "$MOCK_SIPS_LOG" 'large.jpg'
if [[ "$(<"$MOCK_SIPS_LOG")" == *small.jpg* ]]; then print -u2 'small sRGB JPEG was unnecessarily converted'; exit 1; fi
ok 'resume skips completed files; sips conversion and manifest metadata are correct'

/usr/bin/perl - "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$MOCK_UPLOADED_SMALL" <<'PERL'
use strict;
use warnings;
my ($source, $clean) = @ARGV;
sub bytes { open my $fh, '<:raw', $_[0] or die "cannot read test JPEG\n"; local $/; return <$fh>; }
my $before = bytes($source);
my $after = bytes($clean);
die "synthetic test JPEG is missing EXIF/XMP or IPTC data\n" unless $before =~ /\xFF\xE1/ && $before =~ /\xFF\xED/;
die "synthetic test JPEG is missing identifying values or ICC\n" unless $before =~ /Synthetic Test Author/ && $before =~ /SYNTHETIC-SERIAL-001/ && $before =~ /ICC_PROFILE\x00/;
die "EXIF/XMP, IPTC, or comment segment remains\n" if $after =~ /\xFF\xE1|\xFF\xED|\xFF\xFE/;
die "synthetic metadata value remains\n" if $after =~ /Synthetic (?:Test Author|Camera|Model|XMP Author|XMP note|IPTC Author|IPTC caption)|SYNTHETIC-SERIAL-001|35\.6812|139\.7671/;
die "ICC profile was not preserved\n" unless index($after, "ICC_PROFILE\x00") >= 0;
my $before_scan = index($before, "\xFF\xDA");
my $after_scan = index($after, "\xFF\xDA");
die "JPEG scan data changed during metadata removal\n" if $before_scan < 0 || $after_scan < 0 || substr($before, $before_scan) ne substr($after, $after_scan);
PERL
[[ "$(sips -g profile "$MOCK_UPLOADED_SMALL" | command sed -n 's/.*profile: //p')" == *sRGB* ]] || { print -u2 'sanitized JPEG lost its sRGB profile'; exit 1; }
[[ -s "$MOCK_UPLOADED_LARGE" ]] || { print -u2 'converted JPEG was not captured by the mock'; exit 1; }
/usr/bin/perl - "$MOCK_UPLOADED_LARGE" <<'PERL'
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "cannot read converted JPEG\n";
local $/; my $bytes = <$fh>;
die "EXIF/XMP, IPTC, or comment segment remains after resize\n" if $bytes =~ /\xFF\xE1|\xFF\xED|\xFF\xFE/;
die "ICC profile was not preserved after resize\n" unless index($bytes, "ICC_PROFILE\x00") >= 0;
PERL
ok 'metadata segments and identifying values are removed, ICC remains, and direct-path JPEG pixels are unchanged'

SRGB_PROFILE='/System/Library/ColorSync/Profiles/sRGB Profile.icc'
REAL_RESIZED="$TMP/real-sips-resized.jpg"
REAL_CLEAN="$TMP/real-sips-clean.jpg"
/usr/bin/sips --matchTo "$SRGB_PROFILE" -s format jpeg -Z 2048 "$ROOT/tests/fixtures/synthetic-metadata.jpg" --out "$REAL_RESIZED" >/dev/null
papat_cli __sanitize_jpeg "$REAL_RESIZED" "$REAL_CLEAN"
/usr/bin/perl - "$REAL_RESIZED" "$REAL_CLEAN" <<'PERL'
use strict;
use warnings;
my ($source, $clean) = @ARGV;
sub bytes { open my $fh, '<:raw', $_[0] or die "cannot read test JPEG\n"; local $/; return <$fh>; }
my $before = bytes($source);
my $after = bytes($clean);
die "sips test should exercise missing ICC restoration\n" if index($before, "ICC_PROFILE\x00") >= 0;
die "sRGB ICC profile was not restored\n" unless index($after, "ICC_PROFILE\x00") >= 0;
die "metadata remains after real sips resize\n" if $after =~ /\xFF\xE1|\xFF\xED|\xFF\xFE|Synthetic Test Author|SYNTHETIC-SERIAL-001/;
my $before_scan = index($before, "\xFF\xDA");
my $after_scan = index($after, "\xFF\xDA");
die "metadata cleanup changed resized JPEG pixels\n" if $before_scan < 0 || $after_scan < 0 || substr($before, $before_scan) ne substr($after, $after_scan);
PERL
[[ "$(/usr/bin/sips -g profile "$REAL_CLEAN" | command sed -n 's/.*profile: //p')" == *sRGB* ]] || { print -u2 'resized JPEG lacks the sRGB profile'; exit 1; }
ok 'real sips resize is cleaned, receives an ICC profile, and image scan bytes are unchanged'

papat_cli jobs --json > "$TMP/completed.json"
assert_contains "$TMP/completed.json" '"status":"completed"'

papat_cli list --json > "$TMP/list.json"
assert_contains "$TMP/list.json" '"galleries":[]'
papat_cli selections sid-test --json > "$TMP/selections.json"
assert_contains "$TMP/selections.json" 'papat.selections/v1'
papat_cli extend sid-test > "$TMP/extend.json"
assert_contains "$TMP/extend.json" '"extension_count":1'
papat_cli close sid-test > "$TMP/close.json"
assert_contains "$TMP/close.json" '"status":"closed"'
ok 'list, selections, extend, and close use the v1 API contract'

CHECKSUM_DIR="$TMP/checksum with spaces"
mkdir -p "$CHECKSUM_DIR"
print -rn -- 'mock archive' > "$CHECKSUM_DIR/papat-cli-test.zip"
"$ROOT/scripts/write-checksum.sh" "$CHECKSUM_DIR/papat-cli-test.zip"
(cd "$CHECKSUM_DIR" && shasum -a 256 -c papat-cli-test.zip.sha256 >/dev/null)
[[ "$(<"$CHECKSUM_DIR/papat-cli-test.zip.sha256")" == *'  papat-cli-test.zip' ]] || { print -u2 'checksum contains a path'; exit 1; }
ok 'checksum sidecar uses a basename and passes shasum -c'

PUBLIC_EXPORT="$TMP/public-export"
"$ROOT/scripts/export-public.sh" "$PUBLIC_EXPORT" > "$TMP/export.out"
[[ "$(git -C "$PUBLIC_EXPORT" rev-list --count HEAD)" == '1' ]] || { print -u2 'public export does not have exactly one commit'; exit 1; }
[[ -z "$(git -C "$PUBLIC_EXPORT" remote)" ]] || { print -u2 'public export unexpectedly has a remote'; exit 1; }
[[ ! -e "$PUBLIC_EXPORT/dist" && ! -e "$PUBLIC_EXPORT/docs" ]] || { print -u2 'public export included non-source artifacts'; exit 1; }
[[ -f "$PUBLIC_EXPORT/.github/ISSUE_TEMPLATE/bug-report.yml" && -f "$PUBLIC_EXPORT/.github/ISSUE_TEMPLATE/config.yml" ]] || { print -u2 'public export omitted GitHub issue templates'; exit 1; }
[[ "$(git -C "$PUBLIC_EXPORT" show -s --format='%an <%ae>%n%cn <%ce>' HEAD)" == $'Murayama Photo Office <hello@papat.app>\nMurayama Photo Office <hello@papat.app>' ]] || { print -u2 'public export commit identity is incorrect'; exit 1; }
ok 'public export contains the allowlisted files in a fresh one-commit repository'

UNSAFE_SOURCE="$TMP/unsafe-source"
cp -R "$ROOT" "$UNSAFE_SOURCE"
function expect_export_rejection() {
  local label="$1" destination="$2"
  if "$UNSAFE_SOURCE/scripts/export-public.sh" "$destination" >/dev/null 2>&1; then
    print -u2 "public export accepted $label"; exit 1
  fi
  [[ ! -e "$destination/.git/HEAD" ]] || { print -u2 'rejected public export unexpectedly committed'; exit 1; }
  ok "public export rejects $label"
}
printf '/Use%s/%s\n' 'rs' 'test-account' >> "$UNSAFE_SOURCE/README.md"
expect_export_rejection 'a local absolute path' "$TMP/rejected-path"
cp "$ROOT/README.md" "$UNSAFE_SOURCE/README.md"
printf 'dev%s\n' '@example.com' >> "$UNSAFE_SOURCE/README.md"
expect_export_rejection 'an unapproved email address' "$TMP/rejected-email"
cp "$ROOT/README.md" "$UNSAFE_SOURCE/README.md"
printf '%s%s\n' 'sk' '_live_testCredentialValue' >> "$UNSAFE_SOURCE/README.md"
expect_export_rejection 'a credential-like value' "$TMP/rejected-key"
cp "$ROOT/README.md" "$UNSAFE_SOURCE/README.md"
printf '%s%s\n' '社外' '秘' >> "$UNSAFE_SOURCE/README.md"
expect_export_rejection 'an internal note marker' "$TMP/rejected-note"

print -r -- 'All papat-cli tests passed.'
