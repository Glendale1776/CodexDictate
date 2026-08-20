#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app="$repo_dir/build/Release/CodexDictate.app"
target_app="/Applications/CodexDictate.app"

if [ ! -d "$source_app" ]; then
  echo "Release build not found. Run ./scripts/build.sh first." >&2
  exit 1
fi

ditto "$source_app" "$target_app"
echo "Installed $target_app"
