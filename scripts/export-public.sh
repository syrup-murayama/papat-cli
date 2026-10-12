#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/export-public.sh <destination>" >&2
  exit 2
fi

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=$1
case "$destination" in
  /*) ;;
  *) destination="$PWD/$destination" ;;
esac
case "$destination/" in
  "$source_dir/"*|"$source_dir") echo "destination must be outside the source repository" >&2; exit 1 ;;
esac
if [ -e "$destination" ] && [ ! -d "$destination" ]; then
  echo "destination exists and is not a directory" >&2
  exit 1
fi
if [ -d "$destination" ] && [ ! -d "$destination/.git" ] && [ "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "destination must be empty" >&2
  exit 1
fi

mkdir -p "$destination"
if [ -d "$destination/.git" ] && [ -n "$(git -C "$destination" status --porcelain)" ]; then
  echo "destination working tree must be clean before export" >&2
  exit 1
fi
cp "$source_dir/README.md" "$source_dir/SECURITY.md" "$source_dir/LICENSE" "$source_dir/.gitignore" "$destination/"
cp "$source_dir/CHANGELOG.md" "$destination/"
if [ -d "$source_dir/.github" ]; then cp -R "$source_dir/.github" "$destination/"; fi
cp "$source_dir/papat" "$source_dir/install.sh" "$destination/"
mkdir -p "$destination/skill/papat-upload" "$destination/tests/mock-bin" "$destination/tests/fixtures" "$destination/scripts"
cp "$source_dir/skill/papat-upload/SKILL.md" "$destination/skill/papat-upload/"
cp "$source_dir/tests/run.zsh" "$destination/tests/"
cp "$source_dir/tests/mock-bin/curl" "$source_dir/tests/mock-bin/security" "$source_dir/tests/mock-bin/sips" "$destination/tests/mock-bin/"
cp "$source_dir/tests/fixtures/synthetic-metadata.jpg" "$destination/tests/fixtures/"
cp "$source_dir/scripts/write-checksum.sh" "$source_dir/scripts/export-public.sh" "$destination/scripts/"
chmod +x "$destination/scripts/"*.sh

check_tree() {
  tree=$1
  problems=0
  username=$(id -un)

  home_pattern='/Use''rs/[^/[:space:]]+'
  if rg -l --hidden --glob '!**/.git/**' "$home_pattern" "$tree" >/dev/null 2>&1; then
    echo "public export rejected: local home path found" >&2; problems=1
  fi
  if [ -n "$username" ] && rg -l --hidden --glob '!**/.git/**' -F "$username" "$tree" >/dev/null 2>&1; then
    echo "public export rejected: local account name found" >&2; problems=1
  fi

  emails=$(rg -o -i --no-filename --hidden --glob '!**/.git/**' '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "$tree" 2>/dev/null | sort -u || true)
  for email in $emails; do
    [ "$email" = 'hello@papat.app' ] || { echo "public export rejected: unapproved email address found" >&2; problems=1; }
  done

  credential_pattern='sk''_live_[A-Za-z0-9_-]{8,}|-----BEGIN (RSA |EC |OPENSSH )?PR''IVATE KEY-----|AKIA[0-9A-Z]{16}|[A-Fa-f0-9]{64}'
  if rg -l --hidden --glob '!**/.git/**' "$credential_pattern" "$tree" >/dev/null 2>&1; then
    echo "public export rejected: credential-like value found" >&2; problems=1
  fi
  marker_public=$(printf '公開%s' '禁止')
  marker_company=$(printf '社外%s' '秘')
  marker_note=$(printf '内部%s' 'メモ')
  marker_english=$(printf 'internal%s only' '')
  marker_confidential=$(printf 'conf%sidential' '')
  internal_pattern="$marker_public|$marker_company|$marker_note|$marker_english|$marker_confidential"
  if find "$tree" -type f ! -path '*/.git/*' ! -path '*/scripts/export-public.sh' -exec rg -l -i "$internal_pattern" {} + 2>/dev/null | grep . >/dev/null; then
    echo "public export rejected: internal note marker found" >&2; problems=1
  fi
  return "$problems"
}

if ! check_tree "$destination"; then
  echo "public export rejected; review and remove the destination manually" >&2
  exit 1
fi

if [ ! -d "$destination/.git" ]; then
  git -C "$destination" init -b main >/dev/null
fi
git -C "$destination" add README.md SECURITY.md LICENSE CHANGELOG.md .gitignore .github papat install.sh skill tests scripts
if git -C "$destination" rev-parse --verify -q HEAD >/dev/null 2>&1 && git -C "$destination" diff --cached --quiet; then
  echo "no public release changes to commit; repository kept unchanged: $destination"
  exit 0
fi
GIT_AUTHOR_NAME='Murayama Photo Office' \
GIT_AUTHOR_EMAIL='hello@papat.app' \
GIT_COMMITTER_NAME='Murayama Photo Office' \
GIT_COMMITTER_EMAIL='hello@papat.app' \
  git -C "$destination" commit -m "Release 0.1.1" >/dev/null
if ! check_tree "$destination"; then
  echo "public export rejected after commit; review and remove the destination manually" >&2
  exit 1
fi
echo "Updated public repository without rewriting history: $destination"
