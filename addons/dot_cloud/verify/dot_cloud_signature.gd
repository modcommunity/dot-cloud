class_name DotCloudSignature
extends RefCounted

## Signing and verifying manifests.
##
## [b]Why a manifest must be signed.[/b] Everything downstream of the manifest
## trusts it: the hashes decide what counts as a valid download, and the paths
## decide what gets mounted into the running game's filesystem. A client that
## accepts an unsigned manifest from whichever server it happens to connect to is
## accepting arbitrary content — and since Godot resource packs can contain
## scripts, arbitrary content is arbitrary code.
##
## Per-file hashes do not help here. They prove a file matches what the manifest
## said, and the manifest is the thing under attack.
##
## [b]So: pin a public key, or accept that any server you connect to can run code
## in your client.[/b] There are cases where the second is fine — a LAN game, a
## first-party server, a development build — which is why
## [member DotCloudConfig.require_signed_manifests] exists and why it defaults to
## refusing unsigned content.
##
## [b]RSA, not Ed25519.[/b] Godot's [Crypto] exposes RSA sign/verify through
## mbedTLS and no EdDSA. Ed25519 would be the better choice — shorter keys,
## no parameter choices to get wrong — and is not available without a GDExtension.
## RSA-2048 or better with SHA-256 is what this uses.

const CHANNEL := "cloud.sig"

## Minimum RSA key size accepted, in bits.
##
## 1024-bit RSA is broken enough to be worthless as a signal, and accepting it
## would let a weak key produce signatures that look as authoritative as a strong
## one's.
##
## Enforced on [method verify] as well as [method generate_keypair]. Enforcing it
## only on generation would have been policy theatre: nothing makes a game ship
## the key this addon generated, and
## [member DotCloudConfig.trusted_keys] is layered config, so a PEM can arrive
## from a JSON file or the environment long after anyone read this constant.
const MIN_KEY_BITS := 2048

## Minimum signature length accepted, in bytes.
##
## [b]Why the signature and not the key.[/b] An RSA signature is exactly as long
## as the modulus — 256 bytes for a 2048-bit key, 384 for 3072 — so its length
## states the key's size and cannot be padded to lie about it: a longer signature
## simply fails [method Crypto.verify] against the real key. Godot's [CryptoKey]
## exposes no bit count, so the alternative was walking the DER inside the PEM to
## measure the modulus, which is a lot of ASN.1 to arrive at a number already
## sitting in front of us.
const MIN_SIGNATURE_BYTES := MIN_KEY_BITS / 8


## Verifies a detached signature over [param bytes].
##
## [param signature_b64] is standard base64 of the raw signature.
## [param public_key_pem] is a PEM-encoded RSA public key.
##
## Verify against the manifest's [member DotCloudManifest.raw_bytes] — the bytes
## as received — never a re-serialisation. A verifier that re-serialises breaks
## on any difference in key order or number formatting, and then "signature
## invalid" means "our JSON writer changed" rather than anything about the
## signature.
static func verify(
	bytes: PackedByteArray,
	signature_b64: String,
	public_key_pem: String
) -> DotResult:
	if signature_b64.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INTEGRITY, "The manifest is not signed."
		)

	var key := CryptoKey.new()
	var err := key.load_from_string(public_key_pem, true)
	if err != OK:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Could not read the trusted public key.",
			error_string(err)
		)

	var sig := Marshalls.base64_to_raw(signature_b64)
	if sig.is_empty():
		return DotResult.fail(
			DotError.CODE_INTEGRITY, "The signature is not valid base64."
		)

	# Refuse a weak key before doing any crypto with it. mbedTLS will happily
	# verify a 1024-bit signature, and a valid signature from a broken key reads
	# exactly like a valid signature from a good one everywhere downstream.
	if sig.size() < MIN_SIGNATURE_BYTES:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"The manifest is signed with a key that is too weak to trust.",
			"%d-byte signature implies about %d-bit RSA; the minimum is %d" % [
				sig.size(), sig.size() * 8, MIN_KEY_BITS
			]
		)

	var digest := _digest(bytes)

	var crypto := Crypto.new()
	if not crypto.verify(HashingContext.HASH_SHA256, digest, sig, key):
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"The manifest's signature does not match its contents.",
			"signed %d bytes" % bytes.size()
		)

	return DotResult.success(true)


## Verifies against any of several trusted keys.
##
## Several keys is the normal case, not an exception: rotating a signing key
## requires a window where both the old and new key are accepted, otherwise every
## client has to update in lockstep with the publisher.
##
## [param keys] maps a key id to its PEM. When the manifest names a
## [member DotCloudManifest.signature_key_id] that key is tried first, but the
## others are still tried — a manifest is not trusted to tell the truth about
## which key signed it, only to hint.
static func verify_any(
	bytes: PackedByteArray,
	signature_b64: String,
	keys: Dictionary,
	preferred_key_id: String = ""
) -> DotResult:
	if keys.is_empty():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"No trusted signing keys are configured.",
			"set DotCloudConfig.trusted_keys, or turn off "
			+ "require_signed_manifests for unsigned content"
		)

	var order: Array = []
	if preferred_key_id != "" and keys.has(preferred_key_id):
		order.append(preferred_key_id)
	for k in keys:
		if k != preferred_key_id:
			order.append(k)

	var last: DotResult = null
	for key_id in order:
		last = verify(bytes, signature_b64, str(keys[key_id]))
		if last.ok:
			DotLog.debug(
				CHANNEL, "manifest signature verified", {"key": str(key_id)}
			)
			return DotResult.success(str(key_id))

	return DotResult.fail(
		DotError.CODE_INTEGRITY,
		"The manifest is not signed by any trusted key.",
		"tried %d key(s)" % order.size()
	)


## Signs [param bytes] with a private key. For the publisher, not the client.
##
## The private key must never ship inside a game build. Sign during publishing —
## in CI, or on the machine that runs [DotCloudPublisher] — and distribute only
## the public half.
static func sign(
	bytes: PackedByteArray,
	private_key_pem: String
) -> DotResult:
	var key := CryptoKey.new()
	var err := key.load_from_string(private_key_pem, false)
	if err != OK:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Could not read the signing key.",
			error_string(err)
		)

	var crypto := Crypto.new()
	var digest := _digest(bytes)

	var sig := crypto.sign(HashingContext.HASH_SHA256, digest, key)
	if sig.is_empty():
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"Signing failed.",
			"the key may be a public key, or too small"
		)

	return DotResult.success(Marshalls.raw_to_base64(sig))


## Generates an RSA keypair, as [code]{private, public}[/code] PEM strings.
##
## A convenience for getting started. In production, generate keys with a tool
## that can keep the private half in an HSM or a secrets manager — a key that has
## been in a Godot process's memory and written to a file with default
## permissions is not a key you want signing everything your players run.
static func generate_keypair(bits: int = 3072) -> DotResult:
	if bits < MIN_KEY_BITS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Refusing to generate a key smaller than %d bits." % MIN_KEY_BITS
		)

	var crypto := Crypto.new()
	var key := crypto.generate_rsa(bits)
	if key == null:
		return DotResult.fail(
			DotError.CODE_INTERNAL, "Key generation failed."
		)

	return DotResult.success({
		"private": key.save_to_string(false),
		"public": key.save_to_string(true),
	})


## SHA-256 of the payload.
##
## [method Crypto.sign] and [method Crypto.verify] take a digest, not a message —
## passing the message itself produces a signature over the wrong thing that
## still verifies against itself, so this indirection is where that mistake gets
## made once instead of at every call site.
static func _digest(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)

	# HashingContext.update() errors on an empty buffer, and a zero-byte manifest
	# is exactly what a truncated response or a misconfigured host produces. The
	# empty string has a well-defined SHA-256, so skipping the update yields the
	# right digest and the caller gets "signature does not match" rather than an
	# engine error with a DotResult that claims success. Same trap
	# DotHash.sha256_bytes fixed in dot-core; it cannot be reused here because it
	# returns hex and Crypto.verify wants the raw digest.
	if not bytes.is_empty():
		ctx.update(bytes)

	return ctx.finish()
