#!/bin/bash
# Publish a pack (or a raw store) to the CDN through the site, and pin it in content.lock.json. Same flags as publish_pack.ps1.
#   tools/publish_pack.sh [publish] --source DIR --id NAME [--version V | --bump patch|minor|major] [--lock content.lock.json]
#                         [--into DIR] [--kind pack|store] [--lock-optional] [--name TEXT] [--meta KEY=VALUE]... [--exclude-dir NAME]...
#                         [--site URL] [--token-file FILE] [--out DIR] [--godot BIN] [--dry-run]
#   tools/publish_pack.sh relock --id NAME [--version V] [--lock FILE]   (rewrite the lock line of a held version once approved)
#   publish --resume reuses an unfinished claim instead of failing with 409 version_taken
#   tools/publish_pack.sh versions [--id NAME] [--site URL] [--token-file FILE]
# Token: $DOT_CLI_TOKEN (a creator token), else the file in --token-file / $DOT_CLI_TOKEN_FILE / ~/.config/dot/cli-token. Never an argument;
# an env token is copied to a mode-600 temp file that is removed on exit. Site: --site, $DOT_SITE, else https://dev.dotgames.org.
# Everything else is dot_cloud_cli.gd's `publish --upload` (docs/cdn-publish.md). A re-run resumes: only missing objects are sent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD=publish; [ "${1:-}" = publish ] || [ "${1:-}" = versions ] || [ "${1:-}" = relock ] && { CMD=$1; shift; }
GODOT="${GODOT:-godot}"; SITE="${DOT_SITE:-}"; TOKEN_FILE="${DOT_CLI_TOKEN_FILE:-$HOME/.config/dot/cli-token}"
OUT=""; LOCK="content.lock.json"; DRY=""; ARGS=()
abs() { case $1 in /*) printf %s "$1" ;; *) printf %s "$PWD/$1" ;; esac; }
while [ $# -gt 0 ]; do
    case $1 in
        --godot) GODOT="${2:?}"; shift 2 ;;
        --site) SITE="${2:?}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
        --out) OUT="$(abs "${2:?}")"; shift 2 ;;
        --lock) LOCK="${2:?}"; shift 2 ;;
        --source) ARGS+=(--source "$(abs "${2:?}")"); shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --token) echo "publish_pack: the token is never an argument; set DOT_CLI_TOKEN or use --token-file" >&2; exit 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "${DOT_CLI_TOKEN:-}" ]; then
    ( umask 077; printf %s "$DOT_CLI_TOKEN" > "$TMP/token" ); TOKEN_FILE="$TMP/token"
fi
[ -s "$TOKEN_FILE" ] || { echo "publish_pack: no token (set DOT_CLI_TOKEN or write one to $TOKEN_FILE)" >&2; exit 2; }
[ -n "$SITE" ] && ARGS+=(--site "$SITE")
[ -f "$HERE/.godot/global_script_class_cache.cfg" ] || "$GODOT" --headless --path "$HERE" --import >/dev/null 2>&1 || true
RUN=("$GODOT" --headless --path "$HERE" --script addons/dot_cloud/publish/dot_cloud_cli.gd --)
if [ "$CMD" = versions ]; then
    exec "${RUN[@]}" versions --token-file "$(abs "$TOKEN_FILE")" "${ARGS[@]}"
fi
if [ "$CMD" = relock ]; then
    exec "${RUN[@]}" relock --token-file "$(abs "$TOKEN_FILE")" --lock "$(abs "$LOCK")" "${ARGS[@]}"
fi
[ -n "$OUT" ] || OUT="$TMP/out"
[ "$DRY" ] && exec "${RUN[@]}" publish --out "$OUT" "${ARGS[@]}"
"${RUN[@]}" publish --upload --token-file "$(abs "$TOKEN_FILE")" --lock "$(abs "$LOCK")" --out "$OUT" "${ARGS[@]}"
