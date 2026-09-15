#!/bin/bash
# SPDX-License-Identifier: MIT
# Compile only the harness; the saver is an existing CI or release artifact.
set -euo pipefail
if [[ $# != 2 ]]; then
  printf 'Usage: bash tests/verify-rendering.sh /path/to/ghostty.saver output-directory\n' >&2
  exit 2
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bundle="$(cd -- "$1" && pwd)"
mkdir -p -- "$2"
output="$(cd -- "$2" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-render-build.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
xcrun clang -fobjc-arc -O2 -Wall -Wextra \
  -framework AppKit -framework ScreenSaver -framework CoreText -framework QuartzCore \
  "$script_dir/render_bundle.m" -o "$build_dir/render_bundle"
"$build_dir/render_bundle" "$bundle" "$output"
