extends Node

## DotCloudEd25519 and DotCloudSha512 against known answers: SHA-512 across block boundaries,
## RFC 8032 section 7.1 vectors 1 to 3, further signatures made by an independent implementation,
## and every way a signature can be wrong, which must each be refused with a code.
## Run: godot --headless --path . res://examples/ed25519_selftest.tscn

## [public key, message, signature], all hex.
const VECTORS := [
	["d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "", "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"],
	["3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72", "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"],
	["fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82", "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"],
	["acb4e1d19d5722d342c6c15e6a0a0e9d9b2a34daa3a0f107cba9f639372b844f", "60", "4a33f3f51bc8a626a913c2b56383e3f0e35f42c81e14dc54773ec7e126679c5a56dba7ece5ec431c03d22e3e9d3b76296487a5a3f0c8c1f4893f6dca3862560e"],
	["e22285db6e82403ffc21f9e2f3be60d8d0797f0713ab652ed8fe4ef2fcce6ec9", "c10ab654c9594899c6a2ee26e20b05d4587cdbf392ba4e98380816bb0b6cc7", "a5f9efb16f207449a504fafb56add1245fcac6ea8c8dd1851ad59acb591ec5a380ade06f247366e456899cc1db41f880e6a54b700abb0289e9b5ccfafee55c09"],
	["5d5d47b0bdc7a869ed99c298c877c3f90e0597dadd56ae109bd5fe58594f5a03", "e17497c2b76c6e487a1b8fc74f55000c6cfebdd4e584655ecb386d0911592446f386b32d0b7d54f166c19d051992c41290760065ede2a3f702a3de5f8bfe0bd8", "8f5560753f9813647b023d532ee17ac03fe9f5d331ee632cf298af7d87badfb54e297ab6e5f714c53951b81a776d930d9a87f7442210f2ff98a2ad90d72b9f0a"],
	["9aa1b131ba2c03649e075a001eae60360c0182bf7ceee70ff99580b29ac59346", "20d6babc52806c590be1228c75803d898d0057e21245953ec8b952663e8d75146174945a0f97e853f89d974604ce45f41d529257ef61dfd4a53dc3450544b58420d6babc52806c590be1228c75803d898d0057e21245953ec8b952663e8d75146174945a0f97e853f89d974604ce45", "6740235165ffb2880e4b6ae7cb35be8addc46184822fcc1f51d1bc1cc9be2ebc38107918cbdb2f534b6fab9587b80c9937f683c75ffad3640ef9fe934f71e10c"],
	["03dae08492bcb9867ddace808d82162594555352520cad8c1060bb54e34c68cb", "a74465f1b363fb0bb9779e2bc5cb799fed513ecee5a4f654ad2a0acd23a530ed7360838a2a40e823596fd14db36c55a940dfdc184640859aa4d7262a1ab1158ba74465f1b363fb0bb9779e2bc5cb799fed513ecee5a4f654ad2a0acd23a530ed7360838a2a40e823596fd14db36c55a940dfdc184640859aa4d7262a1ab1158b", "3087d9db2a8df0c81853dc7786e19977f504248a2fcdbc2b66f130838ebcfae38aa4cd39083bbd6f39e344a5a3e123f082b0073de70353a13de31e54f70b700c"],
	["beec5b6920e71caf712b84115415b600bfeac5ff92c32519fc2b32fc5293023e", "fa560518094a8e4b711489cf0ef6bab9cbaf958cef704393fa4fcb6b670447a1574a73ddd98c2a1a7cd92820631cb1807ec2b10b2a20a72585db42ade3a9e501fa560518094a8e4b711489cf0ef6bab9cbaf958cef704393fa4fcb6b670447a1574a73ddd98c2a1a7cd92820631cb1807ec2b10b2a20a72585db42ade3a9e501fa560518094a8e4b711489cf0ef6bab9cbaf958cef704393fa4fcb6b670447a1574a73ddd98c2a1a7cd92820631cb1807ec2b10b2a20a72585db42ade3a9e501fa560518094a8e4b711489cf0ef6bab9cbaf958cef704393fa4fcb6b670447a1574a73ddd98c2a1a7cd92820631cb1807ec2b10b2a20a72585db42ade3a9e501fa560518094a8e4b711489cf0ef6bab9cbaf958cef704393fa4fcb6b670447a1574a73ddd98c2a1a7cd92820", "221e8d0611ae1c6dd0dbaeb5dfef43dcacdb77eb5f7f0556a8a49d43717690c458f5266c15a02f363d21d00fc7ecffc3b741d2c562806c02dd675ab9b7120e0d"],
]

## [length, SHA-512 hex] of the bytes (i * 7 + 3) & 255.
const SHA512_VECTORS := [
	[0, "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"],
	[3, "8853167ab14c043919981a6409307ef68b5b726f4b80dcab259daa24b7cabcb8b4bbfd3e2e36ed98465059661f672e6529cdcc673e7eabfa78dd3186745b112a"],
	[111, "68cffa6d0d76f309c9ce0d35280939f8e25990c43b7b086ccdf709be35b07d4ddba599541ff2b1c19d34ea49aeafb9659adb7ac3c0b078bb30a22d57fc6687ef"],
	[112, "d0865c524d1dddf7c23b799c413f5adcd7caefd3f66a9b49750ec81066012c25a8bcf94ddea6dc525691673097ca40e0101e897fc97218cfdb0704084e2bef4b"],
	[128, "99b16f17aa0b969a5b8f08f367719d516e330ccd2660b6f0688ec031dbc783de50a1cd185a2568dba75070a2403d17d4741d163578515dfd2ff756ddfe4d47b1"],
	[200, "cca3c0276046ef9f2897bdfc3ec330f77f4959914b1462bd581b232ddb3e9aa98acf5f5a2b21c7f49d2e43721daa61a2b5cee6af6052dfeb766e66ddb0d1719c"],
	[1000, "00e36fccf193e59697a92b5ab24666ce6326d7fa16bf10832d0991ddc591112e9dfa6a636950ed9c4d67344a760654c2ff7785e1d60094d651038735b5dccabd"],
]

## The first vector's message signed with its scalar replaced by S + L: the same point, a
## different encoding, which a strict verifier refuses.
const MALLEABLE_SIGNATURE := "4a33f3f51bc8a626a913c2b56383e3f0e35f42c81e14dc54773ec7e126679c5a43af9d4900505674d96e26e17b35553e6487a5a3f0c8c1f4893f6dca3862561e"
const MALLEABLE_MESSAGE := "60"
const MALLEABLE_KEY := "acb4e1d19d5722d342c6c15e6a0a0e9d9b2a34daa3a0f107cba9f639372b844f"

## A token as the site sends it: base64url(payload) + "." + base64url(signature over the payload text).
const TOKEN_PAYLOAD := "eyJ2IjogMSwgImF1ZCI6ICJnYW1lLXRlc3QiLCAic3ViIjogInAxIiwgImV4cCI6IDQxMDI0NDQ4MDAsICJpdGVtcyI6IFtdfQ"
const TOKEN_SIGNATURE := "itlXWdaBFXCkwwcbhN73fcZfVmjxjlA51Dkf8v-790ycm0CxiDrvRAr35Xjbv-H4n3sYddf4Fz_gvIqYWLV4Cw"
const TOKEN_KEY := "wido09U13Tfsgv6qf1GKLy_MqxbohmNaJeNXUeYoUh8"

var _failures := 0
var _checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_sha512()
	_vectors()
	_refusals()
	_signature_class()
	_token_through_the_signature_class()
	print("\n%d checks, %d failed" % [_checks, _failures])
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


func _sha512() -> void:
	print("-- SHA-512")
	for v: Array in SHA512_VECTORS:
		var data := PackedByteArray()
		for i in int(v[0]):
			data.append((i * 7 + 3) & 255)
		_check("sha512 of %d bytes" % int(v[0]), DotCloudSha512.digest(data).hex_encode() == v[1])


func _vectors() -> void:
	print("-- known signatures")
	for i in VECTORS.size():
		var v: Array = VECTORS[i]
		var res := DotCloudEd25519.verify(_hex(v[1]), _hex(v[2]), _hex(v[0]))
		_check("vector %d verifies (%d byte message)" % [i, _hex(v[1]).size()], res.ok, str(res))


func _refusals() -> void:
	print("-- refusals")
	var v: Array = VECTORS[4]
	var key := _hex(v[0])
	var msg := _hex(v[1])
	var sig := _hex(v[2])
	_expect_fail("a changed message", DotCloudEd25519.verify(_flip(msg, 3), sig, key), DotError.CODE_INTEGRITY)
	_expect_fail("an extended message", DotCloudEd25519.verify(msg + PackedByteArray([0]), sig, key), DotError.CODE_INTEGRITY)
	_expect_fail("a flipped bit in R", DotCloudEd25519.verify(msg, _flip(sig, 5), key), DotError.CODE_INTEGRITY)
	_expect_fail("a flipped bit in S", DotCloudEd25519.verify(msg, _flip(sig, 40), key), DotError.CODE_INTEGRITY)
	_expect_fail("another key", DotCloudEd25519.verify(msg, sig, _hex(VECTORS[5][0])), DotError.CODE_INTEGRITY)
	_expect_fail("a 63 byte signature", DotCloudEd25519.verify(msg, sig.slice(0, 63), key), DotError.CODE_INTEGRITY)
	_expect_fail("a 65 byte signature", DotCloudEd25519.verify(msg, sig + PackedByteArray([0]), key), DotError.CODE_INTEGRITY)
	_expect_fail("no signature", DotCloudEd25519.verify(msg, PackedByteArray(), key), DotError.CODE_INTEGRITY)
	_expect_fail("a 31 byte key", DotCloudEd25519.verify(msg, sig, key.slice(0, 31)), DotError.CODE_INVALID)
	_expect_fail("no key", DotCloudEd25519.verify(msg, sig, PackedByteArray()), DotError.CODE_INVALID)
	_expect_fail("an all-zero signature", DotCloudEd25519.verify(msg, _zeros(64), key), DotError.CODE_INTEGRITY)
	_expect_fail("S + L (malleable encoding)", DotCloudEd25519.verify(_hex(MALLEABLE_MESSAGE), _hex(MALLEABLE_SIGNATURE), _hex(MALLEABLE_KEY)), DotError.CODE_INTEGRITY)
	# y = 2 is not the y of any curve point; a non-canonical y (2^255 - 18) is refused outright.
	var off_curve := _zeros(32)
	off_curve[0] = 2
	_expect_fail("a key that is not on the curve", DotCloudEd25519.verify(msg, sig, off_curve), DotError.CODE_INVALID)
	var non_canonical := _hex("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
	_expect_fail("a non-canonical key", DotCloudEd25519.verify(msg, sig, non_canonical), DotError.CODE_INVALID)


func _signature_class() -> void:
	print("-- DotCloudSignature.verify_ed25519")
	var v: Array = VECTORS[2]
	_check("the signature class verifies a good one", DotCloudSignature.verify_ed25519(_hex(v[1]), _hex(v[2]), _hex(v[0])).ok)
	_expect_fail("the signature class refuses a bad one", DotCloudSignature.verify_ed25519(_hex(v[1]), _flip(_hex(v[2]), 9), _hex(v[0])), DotError.CODE_INTEGRITY)


func _token_through_the_signature_class() -> void:
	print("-- a site token")
	var signed := TOKEN_PAYLOAD.to_ascii_buffer()
	var sig := DotHash.base64url_decode(TOKEN_SIGNATURE)
	var key := DotHash.base64url_decode(TOKEN_KEY)
	_check("a base64url token body and raw key verify", DotCloudSignature.verify_ed25519(signed, sig, key).ok)
	var forged := (TOKEN_PAYLOAD + "A").to_ascii_buffer()
	_expect_fail("a token whose payload was edited", DotCloudSignature.verify_ed25519(forged, sig, key), DotError.CODE_INTEGRITY)


func _hex(s: String) -> PackedByteArray:
	return s.hex_decode()


func _zeros(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	return b


func _flip(b: PackedByteArray, index: int) -> PackedByteArray:
	var out := b.duplicate()
	if out.is_empty():
		out.append(1)
	else:
		out[index % out.size()] ^= 1
	return out


func _expect_fail(label: String, res: DotResult, code: String) -> void:
	_check(label, not res.ok and res.code() == code, "ok=%s code=%s" % [res.ok, res.code()])


func _check(label: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		_failures += 1
		print("  FAIL  ", label, "  ", detail)
