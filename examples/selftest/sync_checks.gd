extends RefCounted

## The refusal checks of sync_demo.gd's signature step, in a file of their own so the demo stays inside the
## size budget. Takes the demo node `h` and reports through its `_check` and `_fail`.


## Returns false after reporting a setup failure. A signed [param manifest] must still be refused when tampered, when its key is too weak, and when empty.
static func signature_refusals(h: Node, manifest: DotCloudManifest, key_pair: Dictionary) -> bool:
	# A tampered manifest must fail. Without this check a signature routine that
	# always returns true would pass every other test in this file.
	var tampered := manifest.raw_bytes.duplicate()
	tampered[tampered.size() - 2] = 0x20
	var tamper_check := DotCloudSignature.verify(
		tampered, manifest.signature, str(key_pair["public"])
	)
	h._check("tamper refused", not tamper_check.ok)

	# A key too weak to mean anything must be refused before any crypto runs.
	# 1024-bit RSA still verifies happily under mbedTLS, and a valid signature
	# from a broken key is indistinguishable from a good one everywhere
	# downstream of here — which is the whole reason MIN_KEY_BITS exists.
	# Generated through Crypto directly, because DotCloudSignature.generate_keypair
	# refuses to produce one this small — which is the point: the weak key in the
	# real scenario was never made here. It came from an old setup, or from a
	# trusted_keys entry in a layered config file.
	var weak_key := Crypto.new().generate_rsa(1024)
	if weak_key == null:
		h._fail(
			"generating a 1024-bit key",
			DotResult.fail(DotError.CODE_INTERNAL, "generate_rsa(1024) failed")
		)
		return false

	var weak_sig := DotCloudSignature.sign(
		manifest.raw_bytes, weak_key.save_to_string(false)
	)
	if not weak_sig.ok:
		h._fail("signing with the weak key", weak_sig)
		return false

	# This signature is genuinely valid: 128 bytes, and mbedTLS verifies it
	# against its own key without complaint. It must be refused as FORBIDDEN —
	# too weak to consider — and not as INTEGRITY, which would mean the key was
	# considered and only the bytes disagreed.
	var weak_check := DotCloudSignature.verify(
		manifest.raw_bytes,
		str(weak_sig.value),
		weak_key.save_to_string(true)
	)
	h._check(
		"weak key refused",
		not weak_check.ok and weak_check.error.code == DotError.CODE_FORBIDDEN,
		"" if not weak_check.ok else "ACCEPTED"
	)

	# A zero-byte manifest is what a truncated response looks like. This has to
	# come back as a failed DotResult, not as an engine error out of
	# HashingContext.update() with a DotResult that claims success.
	var empty_check := DotCloudSignature.verify(
		PackedByteArray(), manifest.signature, str(key_pair["public"])
	)
	h._check("empty body refused", not empty_check.ok)
	return true
