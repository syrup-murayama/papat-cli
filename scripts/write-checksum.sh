#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: write-checksum.sh <archive.zip>" >&2
  exit 2
fi

archive=$1
if [ ! -f "$archive" ]; then
  echo "archive not found" >&2
  exit 1
fi

archive_dir=$(CDPATH= cd -- "$(dirname -- "$archive")" && pwd)
archive_name=$(basename -- "$archive")
(
  cd "$archive_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
