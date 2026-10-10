# dot-cloud docs

The reasoning behind content delivery, one subject per file. [CLAUDE.md](../CLAUDE.md) has the short rules; these say why.

| File | What it covers |
| --- | --- |
| [mounting.md](mounting.md) | Why a path is never reused, what unloading can and cannot do, the addon-API check, UIDs at mount, the prefix check |
| [trust.md](trust.md) | The manifest as the trust boundary, path components, the envelope, the key floor, scoped keys |
| [client.md](client.md) | The registry name and who finds it, `acquire` and `ensure`, local manifests |
| [store.md](store.md) | Content addressing, the index against the directory, partials, platform notes |
| [sources.md](sources.md) | The three sources, why a source is skipped, the in-band bounds, resume, the downloader |
| [publishing.md](publishing.md) | The CLI, imported assets, path rewriting, binary imports, `DotCloudRegistry` |
| [addon-packs.md](addon-packs.md) | Newer addons over a build: the engine facts, the safeguards, the browser, the test |
| [testing.md](testing.md) | The seven demos and the fan-out trap |
| [history.md](history.md) | The bugs, and how each looked |
