#!/usr/bin/env bash
# Tokenize a project's scripts with the engine's own exporter, for DotCloudPublisher.script_tokens_dir.
#   heavy -- tokenize_scripts.sh <imported project dir> <out dir> [mode: 2 compressed (default), 1 binary]
# The tokens only load on the engine version that wrote them: run with the version clients run.
set -euo pipefail
proj=$(realpath "$1"); out=$(realpath -m "$2"); mode=${3:-2}
here=$(dirname "$(realpath "$0")")
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
godot --headless --path "$proj" --export-pack tokens "$work/t.pck" >/dev/null
printf '[application]\nconfig/name="tokens"\n' > "$work/project.godot"
godot --headless --path "$work" --script "$here/dot_cloud_token_extract.gd" -- "$work/t.pck" "$out"
