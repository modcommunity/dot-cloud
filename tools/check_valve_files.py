#!/usr/bin/env python3
"""Refuse Valve-origin files in a pack or a repository (policy: stock Valve/TF2/CS:S/HL2 assets are local-only).

  check_valve_files.py DIR [--id PACK] [--exclude-dir REL]...       scan a pack source tree (publish_pack.sh runs this before anything is sent)
  check_valve_files.py --git [REPO]          scan the files git tracks or has staged (pre-commit / CI)
  check_valve_files.py --lock FILE [--only ID]...          scan every pack a content.lock.json pins, by its published manifest (read-only, no token)
  check_valve_files.py --build-index OUT ARCHIVE_DIR...   write a stock index from the *_dir.vpk trees under ARCHIVE_DIR
  check_valve_files.py --install-hook [REPO]              install a pre-commit hook that runs --git --staged

Rules, each hit printed as `<path>: <reason>`; exit 1 when any hit, 2 on a usage or setup error, never a silent drop:
  - a *.vpk, *.vpk.sound.cache, or *_dir.vpk archive
  - Source engine formats: .vtf .vmt .mdl .vvd .vtx .phy .ani are never ours (convert to png/glb)
  - a textures/orig or materials/ folder holding such files, and a pack id ending in _orig
  - a file whose CRC32 and size match an entry of the stock index (any name, any extension): the index is built from the
    owner's own install (--build-index) and lives outside git: $DOT_VALVE_INDEX, else ~/.cache/dot/valve_stock.idx.
    Without an index the name/extension rules still run and a note says the content match was skipped.
No limit on hits listed. $DOT_VALVE_ALLOW names a file of path globs (one per line) that are exempt, for fixtures.
"""
import fnmatch, os, subprocess, sys, zlib

EXT = {".vpk", ".vtf", ".vmt", ".mdl", ".vvd", ".vtx", ".phy", ".ani"}
SKIP_DIRS = {".git", ".godot"}


def index_path():
    return os.environ.get("DOT_VALVE_INDEX") or os.path.expanduser("~/.cache/dot/valve_stock.idx")


def load_index(path):
    idx = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            crc, size, name = line.rstrip("\n").split("\t", 2)
            idx.setdefault((int(crc, 16), int(size)), name)
    return idx


def build_index(out, roots):
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [os.environ.get("DOT_FAMILY_DIR", ""), os.path.join(here, "..", "..", ".."), "/home/gamedev/godot"]
    mod = next((os.path.join(c, "dot-map-convert", "dotbsp", "vpk.py") for c in cands
                if c and os.path.isfile(os.path.join(c, "dot-map-convert", "dotbsp", "vpk.py"))), None)
    if mod is None:
        print("check_valve_files: dot-map-convert/dotbsp/vpk.py not found; set DOT_FAMILY_DIR", file=sys.stderr); return 2
    # Loaded by path under a stub package: dotbsp's __init__ and vtf pull numpy, which the archive-tree reader does not need.
    import importlib.util, types
    pkg = types.ModuleType("dotbsp"); pkg.__path__ = [os.path.dirname(mod)]
    sys.modules["dotbsp"] = pkg; sys.modules["dotbsp.vtf"] = types.ModuleType("dotbsp.vtf")
    spec = importlib.util.spec_from_file_location("dotbsp.vpk", mod); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    Vpk = m.Vpk
    n = 0
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w") as o:
        o.write("# crc32\tsize\tstock path (built from local Valve archives; never commit or publish)\n")
        for root in roots:
            for dp, _, fs in os.walk(root):
                for fn in sorted(fs):
                    if fn.endswith("_dir.vpk"):
                        v = Vpk(os.path.join(dp, fn))
                        for p, (arc, off, ln, pre, crc) in sorted(v.entries.items()):
                            o.write("%08x\t%d\t%s\n" % (crc, ln + len(pre), p)); n += 1
    print("check_valve_files: %d stock entries -> %s" % (n, out)); return 0


def reason_for(rel):
    low = rel.lower(); base = os.path.basename(low)
    if base.endswith(".vpk") or ".vpk." in base:
        return "Valve package archive (.vpk)"
    ext = os.path.splitext(base)[1]
    if ext in EXT:
        return "Valve/Source %s file (convert to png/glb; stock content is local-only)" % ext
    if base.endswith(".dx90.vtx") or base.endswith(".dx80.vtx") or base.endswith(".sw.vtx"):
        return "Valve model mesh (.vtx)"
    parts = low.split("/")
    if "orig" in parts and "textures" in parts and parts.index("textures") < parts.index("orig"):
        return "textures/orig folder (stock texture drop)"
    return None


def scan(files, pack_id=None, idx=None, allow=()):
    """files: iterable of (relpath, abspath). Returns [(rel, reason)]."""
    hits = []
    if pack_id and pack_id.lower().endswith("_orig"):
        hits.append(("(pack id %s)" % pack_id, "an _orig pack is the stock-texture build; never published"))
    for rel, ab in files:
        if any(fnmatch.fnmatch(rel, g) for g in allow):
            continue
        r = reason_for(rel)
        if r is None and idx:
            try:
                key = (zlib.crc32(open(ab, "rb").read()) & 0xFFFFFFFF, os.path.getsize(ab))
            except OSError:
                continue
            if key in idx and key[1] > 0:
                r = "content matches stock Valve file %s (crc32 %08x, %d bytes)" % (idx[key], key[0], key[1])
        if r:
            hits.append((rel, r))
    return hits


def walk(root, excl=()):
    for dp, dn, fs in os.walk(root, followlinks=False):
        rd = os.path.relpath(dp, root).replace(os.sep, "/")
        dn[:] = [d for d in dn if d not in SKIP_DIRS and (d if rd == "." else rd + "/" + d) not in excl]
        for fn in fs:
            ab = os.path.join(dp, fn)
            yield os.path.relpath(ab, root).replace(os.sep, "/"), ab


def git_files(repo, staged):
    cmd = ["git", "-C", repo, "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"] if staged else ["git", "-C", repo, "ls-files", "-z"]
    out = subprocess.run(cmd, check=True, capture_output=True).stdout.decode("utf-8", "surrogateescape")
    for rel in filter(None, out.split("\0")):
        ab = os.path.join(repo, rel)
        if os.path.isfile(ab) and not os.path.islink(ab):
            yield rel, ab


def manifest_files(origin, pid, version):
    import base64, json, urllib.request
    req = urllib.request.Request("%s/%s/%s/manifest.json" % (origin.rstrip("/"), pid, version), headers={"User-Agent": "dot-cloud-valve-guard/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        p = json.loads(r.read())["payload"]
    return [f["path"] for f in json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("files", [])]


def scan_lock(lock, only):
    """Path rules over each pinned pack's published manifest. A pack that cannot be read is an error (exit 2), never a pass."""
    import json
    doc = json.load(open(lock)); hits = []; errs = 0
    for e in doc.get("packs", []):
        pid = e.get("id", ""); ver = e.get("version", "")
        if only and pid not in only:
            continue
        try:
            paths = manifest_files(doc.get("origin", "https://dev.dotgames.org/content"), pid, ver)
        except Exception as ex:
            print("%s: manifest of %s %s unreadable: %s" % (lock, pid, ver, ex), file=sys.stderr); errs += 1; continue
        for rel, why in scan([(p, "") for p in paths], pid):
            hits.append(("%s@%s:%s" % (pid, ver, rel), why))
    return hits, errs


def install_hook(repo):
    gd = subprocess.run(["git", "-C", repo, "rev-parse", "--git-path", "hooks"], check=True, capture_output=True, text=True).stdout.strip()
    hooks = gd if os.path.isabs(gd) else os.path.join(repo, gd)
    os.makedirs(hooks, exist_ok=True)
    hook = os.path.join(hooks, "pre-commit"); me = os.path.abspath(__file__)
    line = 'python3 -I "%s" --git --staged "$(git rev-parse --show-toplevel)" || exit 1\n' % me
    cur = open(hook).read() if os.path.exists(hook) else "#!/bin/sh\n"
    if me not in cur:
        open(hook, "w").write(cur + "# Valve-file guard (stock Valve assets never enter a repo)\n" + line)
    os.chmod(hook, 0o755); print("check_valve_files: hook in %s" % hook); return 0


def main(argv):
    a = argv[1:]
    if a[:1] == ["--build-index"]:
        if len(a) < 3: print(__doc__, file=sys.stderr); return 2
        return build_index(a[1], a[2:])
    if a[:1] == ["--install-hook"]:
        return install_hook(a[1] if len(a) > 1 else ".")
    if a[:1] == ["--lock"]:
        if len(a) < 2: print(__doc__, file=sys.stderr); return 2
        only = [a[i + 1] for i in range(2, len(a) - 1) if a[i] == "--only"]
        hits, errs = scan_lock(a[1], only)
        for rel, why in hits: print("%s: %s" % (rel, why))
        print("check_valve_files: %s: %d hit(s), %d unreadable" % (a[1], len(hits), errs), file=sys.stderr)
        return 2 if errs else (1 if hits else 0)
    pack_id = None; excl = []; staged = False; git = False; pos = []
    i = 0
    while i < len(a):
        if a[i] == "--id" and i + 1 < len(a): pack_id = a[i + 1]; i += 2; continue
        if a[i] == "--exclude-dir" and i + 1 < len(a): excl.append(a[i + 1].strip("/")); i += 2; continue
        if a[i] == "--git": git = True
        elif a[i] == "--staged": staged = True
        elif a[i].startswith("--"): print("check_valve_files: unknown flag %s" % a[i], file=sys.stderr); return 2
        else: pos.append(a[i])
        i += 1
    root = pos[0] if pos else "."
    if not os.path.isdir(root):
        print("check_valve_files: %s is not a directory" % root, file=sys.stderr); return 2
    ip = index_path(); idx = None
    if os.path.isfile(ip):
        idx = load_index(ip)
    else:
        print("check_valve_files: note: no stock index at %s (--build-index); content-hash match skipped, name/extension rules ran" % ip, file=sys.stderr)
    allow = []
    if os.environ.get("DOT_VALVE_ALLOW"):
        allow = [l.strip() for l in open(os.environ["DOT_VALVE_ALLOW"]) if l.strip() and not l.startswith("#")]
    try:
        files = git_files(root, staged) if git else walk(root, excl)
        hits = scan(files, pack_id, idx, allow)
    except subprocess.CalledProcessError as e:
        print("check_valve_files: git failed in %s: %s" % (root, e), file=sys.stderr); return 2
    for rel, why in hits:
        print("%s: %s" % (rel, why))
    if hits:
        print("check_valve_files: REFUSED, %d Valve-origin file(s) in %s. Stock Valve assets are local-only: never in a repo or a published pack." % (len(hits), root), file=sys.stderr)
        return 1
    print("check_valve_files: clean (%s)" % root, file=sys.stderr); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
