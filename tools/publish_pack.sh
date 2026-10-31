#!/bin/bash
# Publish a pack (or a raw store) to the CDN through the site, and pin it in content.lock.json. Same flags as publish_pack.ps1.
#   tools/publish_pack.sh [publish] --source DIR --id NAME [--version V | --bump patch|minor|major] [--lock content.lock.json]
#                         [--into DIR] [--kind pack|store] [--lock-optional] [--name TEXT] [--meta KEY=VALUE]... [--exclude-dir NAME]...
#                         [--host-addons FILE|DIR|LOCK]... [--site URL] [--token-file FILE] [--out DIR] [--godot BIN] [--dry-run]
#   tools/publish_pack.sh relock --id NAME [--version V] [--lock FILE]   (rewrite the lock line of a held version once approved)
#   publish --resume reuses an unfinished claim instead of failing with 409 version_taken
#   tools/publish_pack.sh versions [--id NAME] [--site URL] [--token-file FILE]
# --host-addons leaves out the addons/<name> folders the host already owns (a duplicate class_name breaks the pack). The argument is an
# addons.lock (repo<TAB>ref), a directory of addon folders (dot-server-deploy/addons) or a directory holding addons.lock or addons/, or a
# plain list of names, one per line. Names match with - and _ alike. Without it every addon under the source's addons/ is packed.
# Token: $DOT_CLI_TOKEN (a creator token), else the file in --token-file / $DOT_CLI_TOKEN_FILE / ~/.config/dot/cli-token. Never an argument;
# an env token is copied to a mode-600 temp file that is removed on exit. Site: --site, $DOT_SITE, else https://tmcdev.net (dev.dotgames.org is the dev CDN and answers no API).
# Everything else is dot_cloud_cli.gd's `publish --upload` (docs/cdn-publish.md). A re-run resumes: only missing objects are sent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD=publish; [ "${1:-}" = publish ] || [ "${1:-}" = versions ] || [ "${1:-}" = relock ] && { CMD=$1; shift; }
GODOT="${GODOT:-godot}"; SITE="${DOT_SITE:-}"; TOKEN_FILE="${DOT_CLI_TOKEN_FILE:-$HOME/.config/dot/cli-token}"
SRC=""; HOST=(); OUT=""; LOCK="content.lock.json"; DRY=""; ARGS=()
abs() { case $1 in /*) printf %s "$1" ;; *) printf %s "$PWD/$1" ;; esac; }
while [ $# -gt 0 ]; do
    case $1 in
        --godot) GODOT="${2:?}"; shift 2 ;;
        --site) SITE="${2:?}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
        --out) OUT="$(abs "${2:?}")"; shift 2 ;;
        --lock) LOCK="${2:?}"; shift 2 ;;
        --source) SRC="$(abs "${2:?}")"; ARGS+=(--source "$SRC"); shift 2 ;;
        --host-addons) HOST+=("${2:?}"); shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --token) echo "publish_pack: the token is never an argument; set DOT_CLI_TOKEN or use --token-file" >&2; exit 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
# host_names ARG: the addon folder names ARG lists, one per line, normalised to underscores.
host_names() {
    local f=$1
    [ -d "$f" ] && { if [ -f "$f/addons.lock" ]; then f="$f/addons.lock"; else
        local d=$f; [ -d "$f/addons" ] && d="$f/addons"
        find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | tr - _; return; fi; }
    [ -f "$f" ] || { echo "publish_pack: --host-addons $1 is not a file or directory" >&2; return 1; }
    grep -v '^[[:space:]]*#' "$f" | cut -f1 | tr -d ' \r' | grep -v '^$' | tr - _
}
if [ "$CMD" = publish ] && [ -n "$SRC" ] && [ -d "$SRC/addons" ]; then
    if [ ${#HOST[@]} -eq 0 ]; then
        echo "publish_pack: no --host-addons: packing every addon under $SRC/addons (a host that already owns one will refuse the pack; see docs/cdn-publish.md)" >&2
    else
        NAMES="$(for h in "${HOST[@]}"; do host_names "$h" || exit 2; done | sort -u)"
        LEFT=(); KEPT=()
        for d in "$SRC"/addons/*/; do
            n="$(basename "$d")"
            if printf '%s\n' "$NAMES" | grep -qxF "$n"; then LEFT+=("$n"); ARGS+=(--exclude-dir "$n"); else KEPT+=("$n"); fi
        done
        echo "publish_pack: --host-addons left out ${#LEFT[@]} host-owned addon(s): ${LEFT[*]:-none}" >&2
        echo "publish_pack: packing ${#KEPT[@]} other addon(s): ${KEPT[*]:-none}" >&2
    fi
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "${DOT_CLI_TOKEN:-}" ]; then
    ( umask 077; printf %s "$DOT_CLI_TOKEN" > "$TMP/token" ); TOKEN_FILE="$TMP/token"
fi
[ -s "$TOKEN_FILE" ] || { [ "$DRY" ] && [ "$CMD" = publish ]; } || { echo "publish_pack: no token (set DOT_CLI_TOKEN or write one to $TOKEN_FILE)" >&2; exit 2; }
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
