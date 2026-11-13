#!/bin/bash
# Publish a pack (or a raw store) to the CDN through the site, and pin it in content.lock.json. Same flags as publish_pack.ps1.
#   tools/publish_pack.sh [publish] --source DIR --id NAME [--version V | --bump patch|minor|major] [--lock content.lock.json]
#                         [--into DIR] [--kind pack|store] [--lock-optional] [--asset ID | --member-of ID] [--name TEXT] [--meta KEY=VALUE]... [--exclude-dir NAME]...
#                         [--host-addons FILE|DIR|LOCK]... [--site URL] [--token-file FILE] [--out DIR] [--godot BIN] [--dry-run] [--no-import]
#   tools/publish_pack.sh relock --id NAME [--version V] [--lock FILE]   (rewrite the lock line of a held version once approved)
#   publish --resume reuses an unfinished claim instead of failing with 409 version_taken
#   tools/publish_pack.sh versions [--id NAME] [--site URL] [--token-file FILE]
#   tools/publish_pack.sh member --id NAME --member-of ASSET [--site URL] [--token-file FILE]   (move a pack's versions into a collection page)
# --member-of ASSET publishes a map (or any) pack as a member of that collection asset: it keeps its own id, is listed in the asset's
# collection.json and gets no Workshop page of its own (a bare publish of a map pack creates one).
# --host-addons leaves out the addons/<name> folders the host already owns (a duplicate class_name breaks the pack). The argument is an
# addons.lock (repo<TAB>ref), a directory of addon folders (dot-server-deploy/addons) or a directory holding addons.lock or addons/, or a
# plain list of names, one per line. Names match with - and _ alike. Without it every addon under the source's addons/ is packed.
# A derived requires.json ships at the pack root, capped at the lock's levels (see the requires.json step below).
# Family addons (dot_*) are the host's and are never packed, whatever the tree looks like: heavy runs the per-game publish.sh on another box
# from a copy with links resolved, where a wrapper that finds linked addons by symlink sees none. --pack-addon NAME packs one on purpose.
# More than 5 addon folders left in the pack is refused (a game ships a handful of its own adapters at most).
# Token: $DOT_CLI_TOKEN (a creator token), else the file in --token-file / $DOT_CLI_TOKEN_FILE / ~/.config/dot/cli-token. Never an argument;
# an env token is copied to a mode-600 temp file that is removed on exit. Site: --site, $DOT_SITE, else https://tmcdev.net (dev.dotgames.org is the dev CDN and answers no API).
# The source's project is imported first (--no-import skips it): a fresh clone has .import markers but no .godot/imported outputs.
# Everything else is dot_cloud_cli.gd's `publish --upload` (docs/cdn-publish.md). A re-run resumes: only missing objects are sent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD=publish
case "${1:-}" in
    publish|versions|relock|member) CMD=$1; shift ;;
    -*|"") ;;
    *) echo "publish_pack: unknown verb '$1' (publish, versions, relock or member; flags start with --)" >&2; exit 2 ;;
esac
GODOT="${GODOT:-godot}"; SITE="${DOT_SITE:-}"; TOKEN_FILE="${DOT_CLI_TOKEN_FILE:-$HOME/.config/dot/cli-token}"
# Godot is not on PATH under `sudo -u gamedev heavy` (sudo's secure PATH): fall back to the user's ~/.local/bin/godot.
command -v "$GODOT" >/dev/null 2>&1 || ! [ -x "$HOME/.local/bin/godot" ] || GODOT="$HOME/.local/bin/godot"
SRC=""; HOST=(); HOSTLV=(); PACKADD=(); OUT=""; LOCK="content.lock.json"; DRY=""; IMPORT=1; ARGS=()
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
        --pack-addon) PACKADD+=("${2:?}"); shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --no-import) IMPORT=""; shift ;;
        --version) case "${2:-}" in
                [0-9]*.[0-9]*.[0-9]*) [[ "$2" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || { echo "publish_pack: --version '$2' is not semver (X.Y.Z)" >&2; exit 2; } ;;
                *) echo "publish_pack: --version '${2:-}' is not semver (X.Y.Z)" >&2; exit 2 ;;
            esac
            ARGS+=(--version "$2"); shift 2 ;;
        --token) echo "publish_pack: the token is never an argument; set DOT_CLI_TOKEN or use --token-file" >&2; exit 2 ;;
        --host-level) HOSTLV+=("${2:?}"); shift 2 ;;
        --id|--bump|--into|--kind|--asset|--member-of|--name|--meta|--exclude-dir|--depends|--min-engine|--entry|--mount-root|--extra-file) ARGS+=("$1" "${2:?publish_pack: $1 needs a value}"); shift 2 ;;
        -*) ARGS+=("$1"); shift ;;
        *) echo "publish_pack: unexpected argument '$1' (a verb such as 'versions' goes before any flag; the per-game publish.sh wrappers only publish)" >&2; exit 2 ;;
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
# host_level LOCK PROJECT ADDON: the API level the host's lock pins for ADDON, or nothing when the lock does not carry it.
# The addon's repository is where PROJECT/addons/ADDON links to, else LOCK's sibling checkout; its level is LEVEL in
# addons/ADDON/ADDON_api.gd at the locked ref (1 when the file is absent there, the BASELINE). A ref the repository
# lacks fails: fetch its tags, or pass --host-level ADDON=N.
host_level() {
    local lock=$1 proj=$2 a=$3 root="" repo="" ref="" line
    if [ -e "$proj/addons/$a" ]; then
        root="$(readlink -f "$proj/addons/$a")"; root="${root%/addons/$a}"; repo="$(basename "$root")"
    fi
    while IFS=$'\t' read -r r f _; do
        case $r in ''|'#'*) continue ;; esac
        if [ "$(printf %s "$r" | tr - _)" = "$a" ] || { [ -n "$repo" ] && [ "$r" = "$repo" ]; }; then ref=$f; repo=$r; break; fi
    done < "$lock"
    [ -n "$ref" ] || return 0
    for s in "${HOSTLV[@]}"; do [ "${s%%=*}" = "$a" ] && return 0; done
    git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 || root="$(dirname "$lock")/../$repo"
    git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 || {
        echo "publish_pack: cannot find $repo at $ref (the host lock's) to read its level; fetch its tags or pass --host-level $a=N" >&2; return 1; }
    line="$(git -C "$root" show "$ref:addons/$a/${a}_api.gd" 2>/dev/null | sed -n 's/^const LEVEL *:= *\([0-9][0-9]*\).*/\1/p' | head -1)"
    printf '%s\n' "${line:-1}"
}
# Game addon links are relative (addons/dot_x -> ../../dot-x/addons/dot_x), which resolve beside a ~/godot checkout but dangle in a
# worktree under ~/wt. Point a dangling one at the same repository in the family directory: $DOT_FAMILY_DIR, else the directory holding
# the project's main checkout (git common dir), else /home/gamedev/godot. A link that resolves is never touched.
relink_broken_addons() {
    local proj=$1 l t repo fam c
    for l in "$proj"/addons/*; do
        [ -L "$l" ] && [ ! -e "$l" ] || continue
        t="$(readlink "$l")"; repo="$(printf %s "$t" | sed -n 's|.*/\([^/]*\)/addons/[^/]*$|\1|p')"
        [ -n "$repo" ] || { echo "publish_pack: $l -> $t is dangling and names no repository" >&2; continue; }
        fam=""
        c="$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        for d in "${DOT_FAMILY_DIR:-}" "${c:+$(dirname "$(dirname "$c")")}" /home/gamedev/godot; do
            [ -n "$d" ] && [ -e "$d/$repo/addons/$(basename "$l")" ] && { fam="$d"; break; }
        done
        if [ -n "$fam" ]; then ln -sfn "$fam/$repo/addons/$(basename "$l")" "$l"; echo "publish_pack: relinked $l -> $fam/$repo/addons/$(basename "$l")" >&2
        else echo "publish_pack: $l is dangling ($t) and $repo is not in the family directory" >&2; fi
    done
}
if [ "$CMD" = publish ] && [ -n "$SRC" ]; then
    P="$SRC"; while [ "$P" != / ] && [ ! -f "$P/project.godot" ]; do P="$(dirname "$P")"; done
    [ -f "$P/project.godot" ] && relink_broken_addons "$P"
fi
if [ "$CMD" = publish ] && [ -n "$SRC" ] && [ -d "$SRC/addons" ]; then
    if [ ${#HOST[@]} -eq 0 ]; then
        echo "publish_pack: no --host-addons: packing every addon under $SRC/addons (a host that already owns one will refuse the pack; see docs/cdn-publish.md)" >&2
    else
        NAMES="$(for h in "${HOST[@]}"; do host_names "$h" || exit 2; done | sort -u)"
        LEFT=(); KEPT=()
        for d in "$SRC"/addons/*/; do
            n="$(basename "$d")"
            # A repo's name is not always its addon folder (zee-dot-weapons ships addons/zee_weapons): a linked
            # addon is also matched by the repository it links into.
            repo="$(readlink -f "${d%/}" | sed -n 's|.*/\([^/]*\)/addons/[^/]*$|\1|p' | tr - _)"
            if printf '%s\n' "$NAMES" | grep -qxF "$n" || { [ -n "$repo" ] && printf '%s\n' "$NAMES" | grep -qxF "$repo"; }; then LEFT+=("$n"); ARGS+=(--exclude-dir "addons/$n"); else KEPT+=("$n"); fi
        done
        # Anchored at addons/: a bare name drops every folder so named, and cfg/addon/zee_weapons/ads.yml or
        # cfg/game/<id>/dot_map/... are the game's own settings for that addon, not the addon.
        echo "publish_pack: --host-addons left out ${#LEFT[@]} host-owned addon(s): ${LEFT[*]:-none}" >&2
        echo "publish_pack: packing ${#KEPT[@]} other addon(s): ${KEPT[*]:-none}" >&2
    fi
fi
if [ "$CMD" = publish ] && [ -n "$SRC" ] && [ -d "$SRC/addons" ]; then
    EXC=" "; for ((i=0; i<${#ARGS[@]}; i++)); do [ "${ARGS[i]}" = --exclude-dir ] && EXC+="${ARGS[i+1]#addons/} "; done
    NPACK=0
    for d in "$SRC"/addons/*/; do
        [ -d "$d" ] || continue
        n="$(basename "$d")"
        case "$EXC" in *" $n "*) continue ;; esac
        if [[ $n == dot_* ]] && ! printf '%s\n' "${PACKADD[@]:-}" | grep -qxF "$n"; then
            ARGS+=(--exclude-dir "addons/$n"); EXC+="$n "; echo "publish_pack: addons/$n is a family addon, left out (--pack-addon $n to pack it)" >&2; continue
        fi
        NPACK=$((NPACK+1))
    done
    if [ "$NPACK" -gt 5 ]; then
        echo "publish_pack: $NPACK addon folders would be packed from $SRC/addons; a pack carries a handful of its own at most. Linked addons reach servers through addons.lock. Refusing (a copy with resolved links, as heavy's staging box makes, looks like this)." >&2
        exit 2
    fi
fi
# A VRAM-compressed import that holds only the desktop variant (s3tc_bptc, no etc2_astc) is dead weight on web and mobile
# clients, which cannot use it; it is also the biggest thing a pack can carry (18 textures were 25 of 38 MB). Warn, never fail.
if [ "$CMD" = publish ] && [ -n "$SRC" ]; then
    FIND_X=(-name .godot -prune); for ((i=0; i<${#ARGS[@]}; i++)); do [ "${ARGS[i]}" = --exclude-dir ] && FIND_X+=(-o -path "$SRC/${ARGS[i+1]}" -prune); done
    DESK="$(find "$SRC" \( "${FIND_X[@]}" \) -o -name '*.import' -type f -print0 2>/dev/null | xargs -0 -r grep -l '^imported_formats=.*s3tc_bptc' 2>/dev/null | xargs -r grep -L '^imported_formats=.*etc2_astc' 2>/dev/null || true)"
    if [ -n "$DESK" ]; then
        echo "publish_pack: warning: $(printf '%s\n' "$DESK" | wc -l) .import file(s) carry only the desktop-only s3tc_bptc VRAM variant (no etc2_astc); web and mobile clients cannot use it. Import them lossy (compress/mode=1) or with vram_texture=false. First: $(printf '%s\n' "$DESK" | head -1)" >&2
    fi
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "${DOT_CLI_TOKEN:-}" ]; then
    ( umask 077; printf %s "$DOT_CLI_TOKEN" > "$TMP/token" ); TOKEN_FILE="$TMP/token"
fi
[ -s "$TOKEN_FILE" ] || { [ "$DRY" ] && [ "$CMD" = publish ]; } || { echo "publish_pack: no token (set DOT_CLI_TOKEN or write one to $TOKEN_FILE)" >&2; exit 2; }
[ -n "$SITE" ] && ARGS+=(--site "$SITE")
if [ "$CMD" = publish ] && [ -n "$SRC" ] && [ "$IMPORT" ]; then
    P="$SRC"; while [ "$P" != / ] && [ ! -f "$P/project.godot" ]; do P="$(dirname "$P")"; done
    if [ -f "$P/project.godot" ]; then
        echo "publish_pack: importing $P" >&2
        timeout 1800 "$GODOT" --headless --path "$P" --import >"$TMP/import.log" 2>&1 || { tail -20 "$TMP/import.log" >&2; echo "publish_pack: import of $P failed" >&2; exit 1; }
    fi
fi
# requires.json: what the pack needs of the host's addons. The solo shell fetches a game's addon packs from it and
# dot-cloud refuses a pack above the host's levels before mounting, so a game without one misses its addons (Prop Hunt
# 0.1.16 had no zee_weapons and failed to parse). Derived like dot-ci's package.sh (dot-core's dot_requires.gd, which
# applies requires.floor.json), then capped at the levels the host's addons.lock pins: the checkout's own addons are
# usually newer than the shell players run. A committed requires.json is the game's word and is only checked: a level
# above the host's is refused. --host-level NAME=N names a host level by hand (one the lock cannot resolve).
if [ "$CMD" = publish ] && [ -n "$SRC" ]; then
    P="$SRC"; while [ "$P" != / ] && [ ! -f "$P/project.godot" ]; do P="$(dirname "$P")"; done
    if [ -f "$P/project.godot" ] && [ -f "$P/addons/dot_core/tools/dot_requires.gd" ]; then
        REQ="$SRC/requires.json"
        if [ ! -f "$REQ" ]; then
            REQ="$TMP/requires.json"
            "$GODOT" --headless --path "$P" --script res://addons/dot_core/tools/dot_requires.gd -- --out "$REQ" >"$TMP/req.log" 2>&1 \
                && [ -s "$REQ" ] || { tail -20 "$TMP/req.log" >&2; echo "publish_pack: could not derive requires.json for $P" >&2; exit 1; }
            ARGS+=(--extra-file "requires.json=$REQ")
        fi
        CAPS=("${HOSTLV[@]}")
        for h in "${HOST[@]}"; do
            [ -d "$h" ] && h="$h/addons.lock"
            [ -f "$h" ] && grep -q $'\t' "$h" || continue
            for a in $(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("addons", {})))' "$REQ"); do
                lv="$(host_level "$h" "$P" "$a")" || exit 2
                [ -n "$lv" ] && CAPS+=("$a=$lv")
            done
        done
        python3 -I - "$REQ" "$([ "$REQ" = "$TMP/requires.json" ] && echo cap || echo check)" "${CAPS[@]}" <<'PY' || exit 2
import json, sys
path, mode, caps = sys.argv[1], sys.argv[2], dict(c.split("=", 1) for c in sys.argv[3:])
doc = json.load(open(path)); addons = doc.get("addons", {}); bad = []
for name in sorted(addons):
    if name in caps and int(addons[name]) > int(caps[name]):
        if mode == "check":
            bad.append(name)
            print("publish_pack: requires.json asks %s level %s; the host carries %s" % (name, addons[name], caps[name]), file=sys.stderr)
        else:
            print("publish_pack: requires.json: %s %s capped at the host's %s" % (name, addons[name], caps[name]), file=sys.stderr)
            addons[name] = int(caps[name])
if bad:
    print("publish_pack: the committed requires.json is above the host's levels; the host would refuse the pack. Refusing.", file=sys.stderr)
    sys.exit(1)
if mode == "cap":
    open(path, "w").write(json.dumps(doc, indent=2) + "\n")
print("publish_pack: requires.json (%s): %s" % ("derived" if mode == "cap" else "committed",
      ", ".join("%s %s" % (k, addons[k]) for k in sorted(addons))), file=sys.stderr)
PY
    elif [ -f "$P/project.godot" ]; then
        echo "publish_pack: note: $P has no addons/dot_core/tools/dot_requires.gd; the pack ships without requires.json" >&2
    fi
fi
[ -f "$HERE/.godot/global_script_class_cache.cfg" ] || "$GODOT" --headless --path "$HERE" --import >/dev/null 2>&1 || true
RUN=("$GODOT" --headless --path "$HERE" --script addons/dot_cloud/publish/dot_cloud_cli.gd --)
if [ "$CMD" = versions ]; then
    exec "${RUN[@]}" versions --token-file "$(abs "$TOKEN_FILE")" "${ARGS[@]}"
fi
if [ "$CMD" = member ]; then
    exec "${RUN[@]}" member --token-file "$(abs "$TOKEN_FILE")" "${ARGS[@]}"
fi
if [ "$CMD" = relock ]; then
    exec "${RUN[@]}" relock --token-file "$(abs "$TOKEN_FILE")" --lock "$(abs "$LOCK")" "${ARGS[@]}"
fi
[ -n "$OUT" ] || OUT="$TMP/out"
[ "$DRY" ] && exec "${RUN[@]}" publish --out "$OUT" "${ARGS[@]}"
"${RUN[@]}" publish --upload --token-file "$(abs "$TOKEN_FILE")" --lock "$(abs "$LOCK")" --out "$OUT" "${ARGS[@]}"
