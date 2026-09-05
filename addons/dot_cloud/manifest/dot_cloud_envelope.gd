class_name DotCloudEnvelope
extends RefCounted

## The signed wrapper a published manifest ships inside.
##
## [b]Why an envelope rather than a signature field inside the manifest.[/b] A
## signature covers bytes. If the signature lives inside the document it signs,
## the verifier has to reconstruct "the document without its signature" — which
## means re-serialising the parsed JSON and hoping the result is byte-identical to
## what the signer produced. It is not, in general: key order, indentation, float
## formatting and escaping all differ between writers, and each of them turns a
## perfectly valid signature into a rejection.
##
## [b]This was not a hypothetical.[/b] The first version of dot-cloud signed a
## canonical re-serialisation and wrote a pretty-printed file. Every signature it
## produced failed to verify, and the end-to-end test caught it. Canonical JSON is
## a whole specification (JCS, RFC 8785) and implementing it here to work around a
## self-inflicted problem would be the wrong fix.
##
## So the payload is opaque: base64url of the exact manifest bytes, with the
## signature alongside it rather than inside it. The verifier decodes and checks
## those bytes with no reformatting anywhere in the path — the same reason JWS is
## shaped this way.
##
## [codeblock]
## {
##   "dot_cloud_signed": 1,
##   "algorithm": "RS256",
##   "key_id": "default",
##   "signature": "<base64>",
##   "payload": "<base64url of manifest JSON>"
## }
## [/codeblock]
##
## An unsigned publish writes the bare manifest JSON instead, with no envelope.
## [method unwrap] accepts either, so a client reads both and only the
## [member DotCloudConfig.require_signed_manifests] policy decides whether the
## unsigned form is acceptable.

const CHANNEL := "cloud.env"

## Marker key. Its presence is what distinguishes an envelope from a manifest.
const MARKER := "dot_cloud_signed"

const ENVELOPE_VERSION := 1

## The only algorithm Godot's [Crypto] can verify. See [DotCloudSignature].
const ALGORITHM := "RS256"


## Builds an envelope around manifest bytes.
static func wrap(
	payload: PackedByteArray,
	signature_b64: String,
	key_id: String
) -> String:
	return JSON.stringify({
		MARKER: ENVELOPE_VERSION,
		"algorithm": ALGORITHM,
		"key_id": key_id,
		"signature": signature_b64,
		"payload": DotHash.base64url_encode(payload),
	}, "\t")


## Extracts payload bytes and signature from either form.
##
## Returns [code]{payload: PackedByteArray, signature: String, key_id: String,
## signed: bool}[/code]. For a bare manifest the payload is the input unchanged
## and [code]signed[/code] is false.
static func unwrap(bytes: PackedByteArray) -> DotResult:
	var text := bytes.get_string_from_utf8()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The manifest is not a JSON object.",
			text.substr(0, 120)
		)

	var d := parsed as Dictionary

	if not d.has(MARKER):
		# A bare, unsigned manifest. Passed through so the caller's policy — not
		# this parser — decides whether that is acceptable.
		return DotResult.success({
			"payload": bytes,
			"signature": "",
			"key_id": "",
			"signed": false,
		})

	var version := int(d.get(MARKER, 0))
	if version > ENVELOPE_VERSION:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This signed manifest needs a newer version of dot-cloud.",
			"envelope version %d, supported up to %d"
				% [version, ENVELOPE_VERSION]
		)

	var algorithm := str(d.get("algorithm", ALGORITHM))
	if algorithm != ALGORITHM:
		# Refused rather than attempted. An unknown algorithm name must never
		# fall through to "verify it as RS256 anyway" — that is the algorithm
		# confusion bug that has bitten every JWT library at least once.
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"Unsupported signature algorithm '%s'." % algorithm,
			"Godot's Crypto can only verify %s" % ALGORITHM
		)

	var payload_b64 := str(d.get("payload", ""))
	if payload_b64 == "":
		return DotResult.fail(
			DotError.CODE_PARSE, "The signed manifest has no payload."
		)

	var payload := DotHash.base64url_decode(payload_b64)
	if payload.is_empty():
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The signed manifest's payload is not valid base64url."
		)

	var signature := str(d.get("signature", ""))
	if signature == "":
		return DotResult.fail(
			DotError.CODE_INTEGRITY,
			"The manifest claims to be signed but carries no signature."
		)

	return DotResult.success({
		"payload": payload,
		"signature": signature,
		"key_id": str(d.get("key_id", "")),
		"signed": true,
	})


## Whether these bytes look like a signed envelope.
static func is_envelope(bytes: PackedByteArray) -> bool:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed is Dictionary and (parsed as Dictionary).has(MARKER)
