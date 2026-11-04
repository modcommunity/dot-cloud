#!/usr/bin/env bash
# Tokenize a project's scripts with the engine's own exporter, for DotCloudPublisher.script_tokens_dir.
#   heavy -- tokenize_scripts.sh <imported project dir> <out dir> [mode: 2 compressed (default), 1 binary]
# The tokens only load on the engine version that wrote them: run with the version clients run.
set -euo pipefail
proj=$(realpath "$1"); out=$(realpath -m "$2"); mode=${3:-2}
here=$(dirname "$(realpath "$0")")
# $GODOT, then PATH, then the GPU boxes' install: heavy offloads suites to hosts with no godot on PATH.
GODOT=${GODOT:-}
if [ -z "$GODOT" ]; then
  if command -v godot >/dev/null 2>&1; then GODOT=godot
  elif [ -x "$HOME/gpu/bin/godot" ]; then GODOT="$HOME/gpu/bin/godot"
  else echo "godot not found: set GODOT=/path/to/godot (the version clients run)" >&2; exit 2; fi
fi
[ -e "$proj/export_presets.cfg" ] && { echo "refusing: $proj already has export_presets.cfg" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -f "$proj/export_presets.cfg"; rm -rf "$work"' EXIT
cat > "$proj/export_presets.cfg" <<CFG
[preset.0]
name="tokens"
platform="Linux"
runnable=false
export_filter="scripts"
include_filter=""
exclude_filter=""
export_path=""
script_export_mode=$mode
[preset.0.options]
binary_format/embed_pck=false
CFG
"$GODOT" --headless --path "$proj" --export-pack tokens "$work/t.pck" >/dev/null
printf '[application]\nconfig/name="tokens"\n' > "$work/project.godot"
"$GODOT" --headless --path "$work" --script "$here/dot_cloud_token_extract.gd" -- "$work/t.pck" "$out"
"$GODOT" --version | head -1 | tr -d "\r" > "$out/engine.txt"
