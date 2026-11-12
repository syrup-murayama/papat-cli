#!/bin/zsh
setopt extendedglob pipefail
set -eu

ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
trap 'find "$TMP" -depth -delete' EXIT
export HOME="$TMP/home"
export PATH="$ROOT/tests/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export MOCK_API_LOG="$TMP/api.log"
export MOCK_REJECTED_LOG="$TMP/rejected.log"
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

[[ "$(papat_cli --version)" == '0.1.2' ]] || { print -u2 'version command returned an unexpected value'; exit 1; }
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
assert_contains "$MOCK_MANIFEST" '"count":4'
assert_contains "$MOCK_MANIFEST" '"key_color":"#0066CC"'
assert_contains "$MOCK_MANIFEST" 'papat-cli-'
assert_contains "$TMP/first.out" 'サブフォルダの 1 枚は送りません（sub folder/）。送るのは上の階の 4 枚です'
if [[ "$(<"$MOCK_API_LOG")" == *'sub%20folder'* ]]; then print -u2 'a subfolder photo was sent'; exit 1; fi
[[ ! -s "$MOCK_REJECTED_LOG" ]] || { print -u2 'the mock API rejected a path (415)'; exit 1; }
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

# サブフォルダの写真は送らない（API は photos/<名前>.jpg の 1 階層だけを受ける）
mkdir -p "$TMP/only-sub/sub1" "$TMP/only-sub/sub2/deep"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/only-sub/sub1/a.jpg"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/only-sub/sub2/deep/b.JPG"
api_lines_before="$(wc -l < "$MOCK_API_LOG")"
if papat_cli upload "$TMP/only-sub" > "$TMP/only-sub.out" 2>&1; then
  print -u2 'folder with only subfolder JPEGs unexpectedly succeeded'; exit 1
fi
assert_contains "$TMP/only-sub.out" '上の階に JPEG がありません。サブフォルダの 2 枚は送りません（sub1/, sub2/）'
[[ "$(wc -l < "$MOCK_API_LOG")" == "$api_lines_before" ]] || { print -u2 'API was called for a folder with no top-level JPEG'; exit 1; }
ok 'no top-level JPEG and only subfolder JPEGs: stops before creating a gallery'

mkdir -p "$TMP/mixed/a" "$TMP/mixed/b" "$TMP/mixed/c" "$TMP/mixed/d" "$TMP/mixed/e/deep"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/mixed/top1.jpg"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/mixed/top2.JPEG"
for sub in a b c d e/deep; do cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/mixed/$sub/x.jpg"; done
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/mixed/a/y.jpg"
: > "$MOCK_REJECTED_LOG"
papat_cli upload "$TMP/mixed" --json > "$TMP/mixed.json" 2> "$TMP/mixed.err"
assert_contains "$TMP/mixed.json" '"sid":"sid-test"'
if [[ "$(<"$TMP/mixed.json")" == *サブフォルダ* ]]; then print -u2 'the notice leaked into the JSON on stdout'; exit 1; fi
assert_contains "$TMP/mixed.err" 'サブフォルダの 6 枚は送りません（a/, b/, c/ ほか）。送るのは上の階の 2 枚です'
assert_contains "$MOCK_MANIFEST" '"count":2'
[[ ! -s "$MOCK_REJECTED_LOG" ]] || { print -u2 'the mock API rejected a path (415)'; exit 1; }
ok 'subfolder JPEGs are counted and announced (first 3 folders + ほか), only top-level files are sent'

api_lines_before="$(wc -l < "$MOCK_API_LOG")"
jobs_before="$(ls -1 "$HOME/.local/state/papat-cli/jobs" | wc -l)"
papat_cli upload "$TMP/mixed" --dry-run > "$TMP/dry.out" 2>&1
assert_contains "$TMP/dry.out" '送る枚数: 2'
assert_contains "$TMP/dry.out" '送らない枚数: 6（サブフォルダ: a/, b/, c/ ほか）'
papat_cli upload "$TMP/mixed" --dry-run --json > "$TMP/dry.json"
assert_contains "$TMP/dry.json" '"dry_run":true,"title":"mixed","days":7,"will_upload":2,"skipped_subfolder":6'
if papat_cli upload "$TMP/only-sub" --dry-run > "$TMP/dry-only-sub.out" 2>&1; then print -u2 'dry-run with no top-level JPEG unexpectedly succeeded'; exit 1; fi
assert_contains "$TMP/dry-only-sub.out" '上の階に JPEG がありません。サブフォルダの 2 枚は送りません'
[[ "$(wc -l < "$MOCK_API_LOG")" == "$api_lines_before" ]] || { print -u2 'dry-run called the API'; exit 1; }
[[ "$(ls -1 "$HOME/.local/state/papat-cli/jobs" | wc -l)" == "$jobs_before" ]] || { print -u2 'dry-run left a job behind'; exit 1; }
ok 'upload --dry-run reports will-send / skipped counts and sends nothing'

# 0.1.1 の形（サブフォルダ入りの files.list）で failed になった job は、退けて新しく作る
function make_legacy_job() {
  local dir="$1" job_status="${2:-failed}" slash="${3:-yes}" job_id job_dir
  job_id="$(print -rn -- "$dir" | shasum -a 256 | cut -d' ' -f1)"
  job_dir="$HOME/.local/state/papat-cli/jobs/$job_id"
  rm -rf "$job_dir" "$HOME/.local/state/papat-cli/jobs/$job_id".superseded-*(N) "$HOME/.local/state/papat-cli/logs/$job_id"*.log(N)
  mkdir -p "$job_dir" "$HOME/.local/state/papat-cli/logs"
  print -r -- "job_id=$job_id
status=$job_status
pid=999999
sid=sid-old
tenant_id=tenant-test
source_dir=$dir
title=旧い題
days=7
key_color=
passcode=OLDCODE1
idempotency_key=old-key
share_url=https://papat.app/t/tenant-test/s/sid-old/
expires_at=" > "$job_dir/state"
  if [[ "$slash" == yes ]]; then print -r -- $'a.jpg\nsub/x.jpg' > "$job_dir/files.list"; else print -r -- $'a.jpg\nz.jpg' > "$job_dir/files.list"; fi
  print -r -- 'old log' > "$HOME/.local/state/papat-cli/logs/$job_id.log"
  touch -t 202611010930 "$job_dir/state"
  REPLY="$job_id"
}
mkdir -p "$TMP/legacy/sub"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/legacy/a.jpg"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/legacy/sub/x.jpg"
LEGACY_DIR="$(cd "$TMP/legacy" && pwd -P)"
JOBS_ROOT="$HOME/.local/state/papat-cli/jobs"

make_legacy_job "$LEGACY_DIR"; legacy_id="$REPLY"
jobs_snapshot="$(ls -1 "$JOBS_ROOT"; ls -1 "$HOME/.local/state/papat-cli/logs")"
api_lines_before="$(wc -l < "$MOCK_API_LOG")"
papat_cli upload "$TMP/legacy" --dry-run > "$TMP/legacy-dry.out" 2>&1
assert_contains "$TMP/legacy-dry.out" '前に失敗した送り（2026-11-01 09:30、ギャラリー 旧い題/sid-old）は使わずに新しく作ります。前のギャラリーは papat の一覧から消せます'
[[ "$(ls -1 "$JOBS_ROOT"; ls -1 "$HOME/.local/state/papat-cli/logs")" == "$jobs_snapshot" ]] || { print -u2 'dry-run changed the job records'; exit 1; }
[[ "$(wc -l < "$MOCK_API_LOG")" == "$api_lines_before" ]] || { print -u2 'dry-run called the API'; exit 1; }

papat_cli upload "$TMP/legacy" --json > "$TMP/legacy.json" 2> "$TMP/legacy.err"
assert_contains "$TMP/legacy.err" '前に失敗した送り（2026-11-01 09:30、ギャラリー 旧い題/sid-old）は使わずに新しく作ります。前のギャラリーは papat の一覧から消せます'
assert_contains "$TMP/legacy.json" '"sid":"sid-test"'
assert_contains "$MOCK_MANIFEST" '"count":1'
superseded=("$JOBS_ROOT/$legacy_id".superseded-*(N))
(( ${#superseded} == 1 )) || { print -u2 'the old job was not kept under a superseded name'; exit 1; }
assert_contains "${superseded[1]}/state" 'sid=sid-old'
assert_contains "${superseded[1]}/files.list" 'sub/x.jpg'
superseded_logs=("$HOME/.local/state/papat-cli/logs/$legacy_id".superseded-*.log(N))
(( ${#superseded_logs} == 1 )) || { print -u2 'the old log was not kept'; exit 1; }
assert_contains "${superseded_logs[1]}" 'old log'
papat_cli jobs > "$TMP/jobs-superseded.out"
assert_contains "$TMP/jobs-superseded.out" "$legacy_id.superseded-"
assert_contains "$TMP/jobs-superseded.out" 'superseded  sid-old  旧い題'
assert_contains "$TMP/jobs-superseded.out" '退けた送り: 新しく作り直したため再開しません'
if [[ "$(grep -A3 'superseded  sid-old' "$TMP/jobs-superseded.out")" == *'再開: papat upload'* ]]; then print -u2 'a superseded job shows a resume hint'; exit 1; fi
papat_cli jobs --json > "$TMP/jobs-superseded.json"
assert_contains "$TMP/jobs-superseded.json" '"status":"superseded"'
ok '0.1.1-style failed job with subfolder files.list: announced, set aside under a new name (state and log kept), dry-run changes nothing'

# 条件に当たらない job は今のまま「JPEG一覧が変わりました」で止まる
make_legacy_job "$LEGACY_DIR" failed no
if papat_cli upload "$TMP/legacy" > "$TMP/legacy-nomatch.out" 2>&1; then print -u2 'failed job without a slash line should still stop'; exit 1; fi
assert_contains "$TMP/legacy-nomatch.out" 'JPEG一覧が変わりました'
make_legacy_job "$LEGACY_DIR" running yes
if papat_cli upload "$TMP/legacy" > "$TMP/legacy-running.out" 2>&1; then print -u2 'non-failed job with a slash line should still stop'; exit 1; fi
assert_contains "$TMP/legacy-running.out" 'JPEG一覧が変わりました'
leftover=("$JOBS_ROOT"/*.superseded-*(N))
(( ${#leftover} == 0 )) || { print -u2 'a job outside the condition was set aside'; exit 1; }
rm -rf "$JOBS_ROOT/$REPLY"
ok 'failed job without a slash line, or non-failed job with one, keeps the old behavior'

# 上の階のリンクされた JPEG は送らず、数えて知らせる
mkdir -p "$TMP/linked" "$TMP/linked-only" "$TMP/link-src"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/link-src/real.jpg"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/linked/own.jpg"
ln -s "$TMP/link-src/real.jpg" "$TMP/linked/alias1.jpg"
ln -s "$TMP/link-src/real.jpg" "$TMP/linked/alias2.JPEG"
ln -s "$TMP/link-src/real.jpg" "$TMP/linked-only/alias.jpg"
papat_cli upload "$TMP/linked" --dry-run > "$TMP/linked-dry.out" 2>&1
assert_contains "$TMP/linked-dry.out" '送る枚数: 1'
assert_contains "$TMP/linked-dry.out" '送らないリンク: 2'
: > "$MOCK_REJECTED_LOG"
papat_cli upload "$TMP/linked" > "$TMP/linked.out" 2>&1
assert_contains "$TMP/linked.out" 'リンクの 2 枚は送りません。送るのは上の階の 1 枚です'
assert_contains "$MOCK_MANIFEST" '"count":1'
api_lines_before="$(wc -l < "$MOCK_API_LOG")"
if papat_cli upload "$TMP/linked-only" > "$TMP/linked-only.out" 2>&1; then print -u2 'folder with only linked JPEGs unexpectedly succeeded'; exit 1; fi
assert_contains "$TMP/linked-only.out" '上の階に JPEG がありません。リンクの 1 枚は送りません'
[[ "$(wc -l < "$MOCK_API_LOG")" == "$api_lines_before" ]] || { print -u2 'API was called for a folder with only linked JPEGs'; exit 1; }
ok 'linked top-level JPEGs are counted and announced, not sent; only-link folder stops before creating a gallery'

mkdir -p "$TMP/flat"
cp "$ROOT/tests/fixtures/synthetic-metadata.jpg" "$TMP/flat/one.jpg"
papat_cli upload "$TMP/flat" > "$TMP/flat.out" 2>&1
if [[ "$(<"$TMP/flat.out")" == *サブフォルダ* ]]; then print -u2 'notice shown for a folder without subfolders'; exit 1; fi
assert_contains "$MOCK_MANIFEST" '"count":1'
ok 'folder without subfolders prints no notice'

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

export MOCK_REQUEST_LOG="$TMP/requests.log"
papat_cli selections sid-test --json > "$TMP/sel-default.json"
papat_cli selections sid-test --schema v1 --json > "$TMP/sel-v1.json"
papat_cli selections sid-test --json --schema v2 > "$TMP/sel-v2.json"
papat_cli selections sid-test --schema=papat.selections/v2 --json > "$TMP/sel-v2-full.json"
assert_contains "$TMP/sel-default.json" 'papat.selections/v1'
assert_contains "$TMP/sel-v1.json" 'papat.selections/v1'
assert_contains "$TMP/sel-v2.json" 'papat.selections/v2'
assert_contains "$TMP/sel-v2-full.json" 'papat.selections/v2'
[[ "$(command sed -n '1p' "$MOCK_REQUEST_LOG")" == 'GET /api/v1/galleries/sid-test/selections header = "X-Papat-Client: papat-cli/0.1.2"' ]] \
  || { print -u2 'default selections URL or client header changed'; exit 1; }
[[ "$(command sed -n '2p' "$MOCK_REQUEST_LOG")" == 'GET /api/v1/galleries/sid-test/selections header = "X-Papat-Client: papat-cli/0.1.2"' ]] \
  || { print -u2 '--schema v1 must keep the plain v1 URL'; exit 1; }
[[ "$(command sed -n '3p;4p' "$MOCK_REQUEST_LOG" | command sort -u)" == 'GET /api/v1/galleries/sid-test/selections?schema=papat.selections/v2 header = "X-Papat-Client: papat-cli/0.1.2"' ]] \
  || { print -u2 '--schema v2 URL or client header is wrong'; exit 1; }
if papat_cli selections sid-test --schema v3 > "$TMP/bad-schema.out" 2>&1; then
  print -u2 'unknown schema unexpectedly succeeded'; exit 1
fi
unset MOCK_REQUEST_LOG
ok 'selections: default and v1 keep the plain URL, --schema v2 adds ?schema=papat.selections/v2, X-Papat-Client is sent'

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
[[ -f "$PUBLIC_EXPORT/CHANGELOG.md" ]] || { print -u2 'public export omitted CHANGELOG.md'; exit 1; }
ok 'public export contains the allowlisted files in a fresh one-commit repository'

UPDATE_SOURCE="$TMP/update-source"
cp -R "$ROOT" "$UPDATE_SOURCE"
print -r -- 'Release export update test.' >> "$UPDATE_SOURCE/README.md"
"$UPDATE_SOURCE/scripts/export-public.sh" "$PUBLIC_EXPORT" > "$TMP/export-update.out"
[[ "$(git -C "$PUBLIC_EXPORT" rev-list --count HEAD)" == '2' ]] || { print -u2 'public export update did not add exactly one commit'; exit 1; }
[[ "$(git -C "$PUBLIC_EXPORT" show -s --format='%an <%ae>; %cn <%ce>' HEAD)" == 'Murayama Photo Office <hello@papat.app>; Murayama Photo Office <hello@papat.app>' ]] || { print -u2 'public export update identity is incorrect'; exit 1; }
ok 'public export updates an existing repository by adding a commit'

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
