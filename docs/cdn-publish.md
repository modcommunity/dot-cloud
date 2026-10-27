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

## Raw stores are packs too

A raw asset store (the 1.6 GB, 75,556-file CC0 `.stores` tree) is published exactly like a pack: same claim, manifest, objects and signature. The only difference is on the consuming side: `kind: "store"` in the lock file means "write each file to `into/<path>` on disk" instead of mounting it, so there is no second storage system, no second signer and no second retention rule. Unchanged files between store versions are copied server-side, so a new store version costs only what changed.

## Licence and approval gate

Only `CC0-1.0`, `MIT`, `Unlicense`, `public-domain`, `CC-BY-3.0` and `CC-BY-4.0` are accepted. Each `licences` entry is `{paths, licence, author, url, title?}`; a file takes the entry with the longest matching path prefix (`""` matches everything); `author` and an http(s) `url` are required. Anything else (NC, SA, ND, personal-use, an unknown id) or a file no entry covers is a 400 `licence` before any byte moves. There is no private tier: non-redistributable art is reference only and never goes on the CDN. CC-BY work is also credited in the source's README and CREDITS.

Review is the site setting `uploads.cliReview`: `first` (default: a creator's first published release waits for a moderator; staff and creators with a READY release go live), `all`, or `none`. A held release opens an approval request of kind `cliPack`; approving it publishes the held draft, rejecting it makes `finalize` answer 409 `rejected`. The draft is kept for 30 days; after that the creator sends the manifest again and the approval still stands. The game's own approval gate (`PackClaimGate`) still runs at finalize.

## Retention

A version published through the CLI is pinned by somebody's lock file, possibly in a repository's history, so the retention sweep never removes one (`source: CLI` is excluded from `SweepPack`). Such a version leaves only when its owner deletes it. Objects are per version, so deleting one version never breaks another.

## Production and dev buckets

The site that answers is the bucket that is written: tmcdev.net writes `tmc-city-games-dev` (origin `dev.dotgames.org`), the production site writes the production bucket. A lock file names its `origin`, so a dev pin never resolves against production by accident. Promoting a dev pin to production is a fresh publish on the production site; the manifest sha then differs (another signing key) and the lock file is updated.

## Mirrors and the cold copy

`mirrors` in the lock file lists extra origins tried in order after `origin`. Because the lock pins `manifest_sha256` and the manifest pins every object's sha256, any static copy of the `content/<id>/<version>/` tree (a second bucket, a tarball on a disk, an internal HTTP server) is a valid mirror with no extra trust. The cold copy is a periodic sync of the bucket's `content/` prefix to a second store; restoring is pointing `mirrors` at it.

## Open question for Christian

Does a new creator's first release wait for a moderator (`uploads.cliReview = first`, the default as built) or go live at once (`none`)? It is one setting either way.
