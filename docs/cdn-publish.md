# Publishing through the site to the CDN

How a developer with a creator token publishes a pack of any size, and how a fresh clone gets that content back by lock file. The site holds the only bucket credentials; the CLI never sees one.

## The flow

1. **Claim** (`POST /api/app/v1/packs`, `action: claim`, unchanged): `{repoName, version, fileCount, byteSize}` returns `{id, contentId}`. The owner segment comes from the token's account, never from the request. A taken version is gone for good (409 `version_taken`).
2. **Manifest** (`POST /api/app/v1/packs/upload`, `action: manifest`): `{id, manifest: <base64 of the unsigned manifest bytes>}`, up to 32 MiB (about 150,000 files). The site checks that `content_id` and `version` equal the claim, every path is relative and safe, every `sha256` is 64 lower-case hex, and the licence block covers every file. It answers `{objects, present, missing, missingBytes}`. Sending the manifest again is how a crashed run resumes: the plan is rebuilt from what the bucket already holds.
3. **Next** (`action: next`, `{id, max ≤ 1000}`): `{puts: [{sha256, size, url, headers}], copied, remaining, expiresInSec: 900}`. Each URL is a presigned PUT for one key under `game/content/<owner>/<repo>/<version>/`, signed with `x-amz-checksum-sha256`, so S3 itself refuses bytes with another hash. Objects already in this version are never listed; objects an earlier READY version of the same pack has (the last three) are copied inside the bucket and never uploaded again. An expired URL (403) means "call next again".
4. **Finalize** (`action: finalize`): 409 `missing` while any object is absent. Otherwise the review gate decides: `{status: "READY", manifestUrl, manifestSha256}`, or `{status: "HELD", approvalId}`. Only on READY does the site sign the payload with its pack key, write `manifest.json`, mark the row READY and write `latest.json`. A held version has no manifest and nothing names it.

`complete` on the claim route stays for publishers with their own bucket write (staff CLI tokens); a creator token is refused it, because `complete` trusts a write the caller never had.

## Manifest and lock-file format

The manifest is the existing dot-cloud manifest (`format`, `content_id`, `version`, `mount_root`, `files[{path, sha256, size, side?}]`, optional `bundle`, `provides`, `metadata`, `dependencies`) plus one required top-level key, `licences`, copied from `licence.json` at the source root. The site signs exactly the bytes it was sent, so what the CLI built is what clients verify.

The lock file is `content.lock.json` at the repository root:

```json
{"format": 1, "origin": "https://dev.dotgames.org/content", "mirrors": [],
 "packs": [{"id": "gamemann/zz-stores", "version": "1.0.0", "manifest_sha256": "<from finalize>",
            "into": ".stores", "kind": "store", "optional": true}]}
```

`manifest_sha256` pins the signed bytes as served, so a manifest from any mirror is as trustworthy as one from the origin. Objects are at `<origin>/<id>/<version>/objects/<aa>/<sha256>`.

## The command: publish_pack

`tools/publish_pack.sh` (Linux, macOS) and `tools/publish_pack.ps1` (Windows) take the same options; the PowerShell ones are `-PascalCase` (`-Source`, `-Id`, `-Bump`, `-LockOptional`, `-TokenFile`, `-DryRun`). They run `dot_cloud_cli.gd publish --upload` in this repository's project, so Godot is needed (`--godot BIN` or `$GODOT`) and `curl` (Windows 10+ ships `curl.exe`). The `.ps1` needs PowerShell 7 (`pwsh`) off Windows; it was run on Linux under `pwsh` 7.6 against a stub site (claim, manifest, next, finalize, presigned PUT) for a first publish, `-Bump`, `-Kind store`, `-LockOptional`, `-Meta a=1,b=2`, an env token and `-DryRun`.

| Option | Meaning |
| --- | --- |
| `--source DIR`, `--id NAME` | the pack directory and its repository name (required); `licence.json` at the source root becomes the manifest's `licences` |
| `--version V` or `--bump patch\|minor\|major` | the version to claim, or the next one after the lock entry's |
| `--lock FILE` | the lock file to pin in (default `content.lock.json` in the current directory) |
| `--into DIR`, `--kind pack\|store`, `--lock-optional` | the lock entry; a republish keeps the entry's values unless given |
| `--name TEXT`, `--meta KEY=VALUE` (repeatable) | manifest display name and metadata (`preview`, `credit`, ...) |
| `--exclude-dir NAME` (repeatable) | leave out any folder of this name |
| `--site URL`, `--token-file FILE`, `--out DIR`, `--dry-run` | site (`$DOT_SITE`, default `https://dev.dotgames.org`), token file, where the objects are built, build without sending |

**The token is never an argument** (`--token` is refused). It comes from `$DOT_CLI_TOKEN`, which is copied to a mode-600 temp file removed on exit, or from the file in `--token-file`, `$DOT_CLI_TOKEN_FILE` or `~/.config/dot/cli-token`. The script sends only missing objects, so running it again after a failure resumes. A `HELD` first release writes no lock line; run it again after the moderator approves (the objects are already there, but a taken version cannot be claimed again, so `--bump`).

A worked example: pin a CC0 asset store into a game.

```bash
cd ~/godot/game-arena
echo '[{"paths": [""], "licence": "CC0-1.0", "author": "Kenney", "url": "https://kenney.nl"}]' > ~/stores/kenney/licence.json
export DOT_CLI_TOKEN=tmcc_...   # a creator token; or put it in ~/.config/dot/cli-token
~/godot/dot-cloud/tools/publish_pack.sh --source ~/stores/kenney --id zz-stores --version 1.0.0 \
    --kind store --into .stores/kenney --lock-optional --name "Kenney stores"
git add content.lock.json   # origin, id, version, manifest_sha256, into, kind, optional
```

`tools/test_publish_pack.sh` runs the command against `tools/test/mock_site.py`, a local stand-in for the site calls and the presigned PUT (no network, no bucket): first publish, `--bump` sending only the changed object, `versions`, a wrong token, `--token` refused. It also covers `--resume` (a 409 `version_taken` from an unfinished claim: without the flag the error says what the version is, with it the claim is reused; this needs the site's `versions` answer to carry the claim `id` and a non-READY status for open claims), and `relock` (rewrites the lock entry of a version that was HELD and is now READY, from the site's `versions` record). It has not been run against the dev bucket.

### Republishing one entry

Change the files or metadata of one pack (a new preview, a credit, a licence line, a name) and run the same command with `--bump patch` and the pack's `--id`. Only that entry's line in the lock file changes (`version`, `manifest_sha256`). A version is never reused, so a republish is a new version; every object an earlier READY version (the last three) has is copied inside the bucket, so only changed files travel. The old version stays on the CDN for any lock file that pins it.

```bash
~/godot/dot-cloud/tools/publish_pack.sh --source ~/stores/kenney --id zz-stores --bump patch \
    --meta preview=preview.png --meta credit=Kenney
```

### The read side

`publish_pack.sh versions [--id NAME]` lists your versions on the site (id, version, status, file count, size, manifest sha; `POST /api/app/v1/packs`, `action: versions`, owner only). Anyone with a lock file gets the content back with dot-bootstrap's `tools/fetch_lock.sh` / `fetch_lock.ps1`, which is what every game's bootstrap runs: it reads `content.lock.json`, fetches `<origin>/<id>/<version>/manifest.json` and `objects/<aa>/<sha256>` (origin first, then `mirrors`), checks the manifest against `manifest_sha256` and every object against the manifest, and takes `--only ID` for a single entry. `--packs DIR` also mirrors each `kind: "pack"` entry into a server's `content/packs/`, and dot-server-deploy's `fetch-content` reads the same lock. In game, `DotCloudClient.ensure_locked(lock_path, opts)` reads the same file through `DotCloudLock` (`client/dot_cloud_lock.gd`) with the same CDN precedence (`from`, `DOT_PACKS_FROM`, `cdn`, `DOT_CDN_URL`, `dot-bootstrap/.env`, lock origin and mirrors, `https://dotgames.org`) and the same `cfg/content` rules (`remove:`, `disabled`, `pack:` entries), mounts each wanted `kind: "pack"` entry from the first base whose manifest matches `manifest_sha256`, and leaves `kind: "store"` entries to fetch_lock. The precedence and list rules now exist three times (the Python in fetch_lock.sh, fetch_lock.ps1, `DotCloudLock`) because a game cannot shell out; `examples/lock_demo.tscn` pins the GDScript copy to the same cases.

## Raw stores are packs too

A raw asset store (the 1.6 GB, 75,556-file CC0 `.stores` tree) is published exactly like a pack: same claim, manifest, objects and signature. The only difference is on the consuming side: `kind: "store"` in the lock file means "write each file to `into/<path>` on disk" instead of mounting it, so there is no second storage system, no second signer and no second retention rule. Unchanged files between store versions are copied server-side, so a new store version costs only what changed.

## Licence and approval gate

Only `CC0-1.0`, `MIT`, `Unlicense`, `public-domain`, `CC-BY-3.0` and `CC-BY-4.0` are accepted. Each `licences` entry is `{paths, licence, author, url, title?}`; a file takes the entry with the longest matching path prefix (`""` matches everything); `author` and an http(s) `url` are required. Anything else (NC, SA, ND, personal-use, an unknown id) or a file no entry covers is a 400 `licence` before any byte moves. There is no private tier: non-redistributable art is reference only and never goes on the CDN. CC-BY work is also credited in the source's README and CREDITS.

Review has two gates, and a release goes live only when every gate that applies has approved it. **Admins are never held.** The **moderator gate** is the site setting `uploads.cliReview`: `first` (default: the first release of a creator who is not on the app's team waits for a moderator; staff, the app's own team and creators with a READY release go live), `all`, or `none`. The **owner gate** is the app's approval policy (kind `cliPack`): when it is on, releases by anyone but the app's own team wait for the app owner, and it is off for the owner's own releases. The approval policies can add a moderator gate per site or per app on top. A held release opens an approval request of kind `cliPack` that names who is awaited; approving it (a moderator who also manages the app counts for both sides) publishes the held draft, rejecting it makes `finalize` answer 409 `rejected`. The draft is kept for 30 days; after that the creator sends the manifest again and the approval still stands. The game's own approval gate (`PackClaimGate`) still runs at finalize.

**Polish.** The pack manager's Polish button edits one entry of the newest version (name, preview image, credit, licence) and republishes only that entry as the next patch version through the same flow: the other files are copied inside the bucket, unchanged objects are skipped, and the result goes through the gates above (`UNCHANGED` when nothing differs).

## Retention

A version published through the CLI is pinned by somebody's lock file, possibly in a repository's history, so the retention sweep never removes one (`source: CLI` is excluded from `SweepPack`). Such a version leaves only when its owner deletes it. Objects are per version, so deleting one version never breaks another.

## Production and dev buckets

The site that answers is the bucket that is written: tmcdev.net writes `tmc-city-games-dev` (origin `dev.dotgames.org`), the production site writes the production bucket. A lock file names its `origin`, so a dev pin never resolves against production by accident. Promoting a dev pin to production is a fresh publish on the production site; the manifest sha then differs (another signing key) and the lock file is updated.

## Mirrors and the cold copy

`mirrors` in the lock file lists extra origins tried in order after `origin`. Because the lock pins `manifest_sha256` and the manifest pins every object's sha256, any static copy of the `content/<id>/<version>/` tree (a second bucket, a tarball on a disk, an internal HTTP server) is a valid mirror with no extra trust. The cold copy is a periodic sync of the bucket's `content/` prefix to a second store; restoring is pointing `mirrors` at it.

## Open question for Christian

Does a new creator's first release wait for a moderator (`uploads.cliReview = first`, the default as built) or go live at once (`none`)? It is one setting either way.
