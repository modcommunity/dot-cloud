# Trust: manifests, signatures and keys

## The manifest is the entire trust boundary

Everything downstream trusts it: the hashes decide what counts as a valid download, and the paths decide what gets mounted. Godot packs can contain scripts, so **a client that mounts content from an unsigned manifest runs whatever the server sent.** Per-file hashes do not help: they prove a file matches what the manifest said, and the manifest is the thing under attack.

`DotCloudConfig.require_signed_manifests` defaults to `true` and `validate()` refuses to boot without a trusted key. Turning it off is legitimate for LAN play, first-party servers and development, and logs a warning every time.

## Both path components are checked

`content_id` must equal its own slug. `version` cannot be held to that (`slugify("1.0.0")` is `1_0_0`, so equality would refuse every semver), and for a long time the only check was that it slugified to something non-empty. `slugify("../evil")` is `"evil"`, and `mount_prefix()` interpolates the raw string, so `version: "../.."` validated and mounted at `res://`: exactly the shadowing `mount_root` exists to prevent. A version now gets `safe_relative` plus a separator check, because it is one path **component**, not a path. `DotCloudMounter._check_prefix` simplifies both sides before comparing, so it is independent of the manifest check rather than agreeing with whatever it let through. `mount_demo`'s section 1 is the assertion.

## The envelope

**Signatures live outside the document they sign.** A published manifest is a `DotCloudEnvelope`:

```json
{ "dot_cloud_signed": 1, "algorithm": "RS256", "key_id": "default",
  "signature": "<base64>", "payload": "<base64url of the manifest JSON>" }
```

A signature inside the manifest over a canonical re-serialisation failed to verify every time, because the file on disk was pretty-printed and the signed bytes were not. Canonical JSON is a whole specification (RFC 8785); an opaque base64url payload means the verifier checks the exact bytes it received with no reformatting anywhere, the same reason JWS is shaped this way. `DotCloudManifest.from_json_bytes()` is the single entry point and unwraps the envelope transparently, so no caller can verify against the wrong bytes.

**RSA, not Ed25519.** Godot's `Crypto` exposes RSA sign/verify via mbedTLS and no EdDSA. Ed25519 would be better and needs a GDExtension.

## A key floor, enforced on verify

`MIN_KEY_BITS` is 2048, and it is checked on **verify**, not only in `generate_keypair`: `trusted_keys` is layered config and can arrive from a JSON file or the environment, so a weak key does not have to be made here to be trusted. The check is on the signature length: an RSA signature is exactly as long as the modulus and cannot be padded to claim otherwise (a longer one fails `Crypto.verify`). `CryptoKey` exposes no bit count; the alternative was walking the DER. A weak key is `CODE_FORBIDDEN` (not considered), never `CODE_INTEGRITY` (considered, bytes disagreed).

## A key says what it is trusted for

A bare PEM in `trusted_keys` is trusted for every content id there is. With two publishers that is the hole: the second signs a manifest claiming `content_id: arena`, and any client that has not mounted it takes the pack, code included, under somebody else's game's name. An entry may name its namespace:

```json
"trusted_keys": {
    "first-party": "-----BEGIN PUBLIC KEY-----\n…",
    "community-alice": {
        "key": "-----BEGIN PUBLIC KEY-----\n…",
        "content_ids": ["alice_*"]
    }
}
```

`verify_for` does both halves and the failure says which ("The manifest is not signed by any trusted key" against "'community-alice' is not trusted to publish 'arena'"). **Verification first, entitlement second**: a scope check on an unverified manifest is a check on a claim the attacker wrote.

`DotCloudConfig.validate()` warns about several keys with at least one unscoped, and says nothing about a single unscoped key. It warns rather than refuses: a client that will not start is worse than one that says so, and the content still has to be signed by a key in the set.

## Other boundaries

- The in-band source's delegate must refuse hashes the client has no business requesting, or it is a way to read the server's cache ([sources.md](sources.md#the-in-band-source)).
- A local source still verifies hashes: a development source is being edited, so it is not automatically trustworthy.
- An addon overlay is admitted only signed, only upward and only from configured namespaces ([addon-packs.md](addon-packs.md#what-keeps-it-from-doing-harm)).
