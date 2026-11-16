class_name DotCloudEd25519
extends RefCounted

## Ed25519 signature verification (RFC 8032) in plain GDScript.
##
## Godot's [Crypto] has no EdDSA, and a GDExtension would not reach every export target, so this is
## the pure-script verifier: field arithmetic modulo 2^255 - 19 on sixteen 16-bit limbs (the layout
## of the compact TweetNaCl implementation), and the extended-coordinate group law of the twisted
## Edwards curve. A group element is an [Array] of four limb arrays [X, Y, Z, T].
##
## [b]Verification only[/b], and only public data: nothing here is secret, so branching on bits and
## early exits are fine and no constant-time care is taken. Signing belongs to the publisher, not a
## game client.
##
## [b]Strict.[/b] A signature whose scalar S is not below the group order, a public key whose
## y-coordinate is not canonical, and a point that is not on the curve are all refused (RFC 8032
## section 5.1.7), so one message has one valid signature.
##
## [b]Cost.[/b] About 10,000 field multiplications, so expect a second or two in a release build
## of the interpreter. Verify a token once and keep the result; do not verify per frame.

const KEY_BYTES := 32
const SIGNATURE_BYTES := 64

const _D := [0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
	0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203]
const _D2 := [0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
	0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406]
const _BASE_X := [0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
	0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169]
const _BASE_Y := [0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
	0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666]
## The square root of -1 modulo 2^255 - 19.
const _SQRT_M1 := [0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
	0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83]
## The group order L = 2^252 + 27742317777372353535851937790883648493, little-endian bytes.
const _L := [0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9,
	0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]


## Verifies [param signature] (64 bytes, R then S) over [param message] against the raw 32-byte
## public key [param key_bytes]. Success carries [code]true[/code]; every failure is a result with
## a code and a reason, never a silent false.
static func verify(message: PackedByteArray, signature: PackedByteArray, key_bytes: PackedByteArray) -> DotResult:
	if key_bytes.size() != KEY_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "An Ed25519 public key is %d bytes." % KEY_BYTES,
			"got %d" % key_bytes.size())
	if signature.size() != SIGNATURE_BYTES:
		return DotResult.fail(DotError.CODE_INTEGRITY, "An Ed25519 signature is %d bytes." % SIGNATURE_BYTES,
			"got %d" % signature.size())
	if not _scalar_below_order(signature.slice(32, 64)):
		return DotResult.fail(DotError.CODE_INTEGRITY, "The signature's scalar is not below the group order.")
	if not _y_is_canonical(key_bytes):
		return DotResult.fail(DotError.CODE_INVALID, "The public key is not a canonical Ed25519 point.")
	var a_neg: Variant = _unpack_negated(key_bytes)
	if a_neg == null:
		return DotResult.fail(DotError.CODE_INVALID, "The public key is not a point on the Ed25519 curve.")

	# h = SHA-512(R || A || M) mod L; the check is [S]B - [h]A == R, compared as encoded bytes.
	var hashed := PackedByteArray()
	hashed.append_array(signature.slice(0, 32))
	hashed.append_array(key_bytes)
	hashed.append_array(message)
	var h := _reduce_mod_l(DotCloudSha512.digest(hashed))
	var left := _scalar_mult(a_neg, h)
	var right := _scalar_mult(_base_point(), signature.slice(32, 64))
	var sum := _add(left, right)
	var packed := _pack(sum)
	if packed != signature.slice(0, 32):
		return DotResult.fail(DotError.CODE_INTEGRITY, "The Ed25519 signature does not match the message.",
			"signed %d bytes" % message.size())
	return DotResult.success(true)


# ---- Scalars ----

static func _scalar_below_order(s: PackedByteArray) -> bool:
	for i in range(31, -1, -1):
		if s[i] != _L[i]:
			return s[i] < _L[i]
	return false


## A 64-byte little-endian number modulo L, as 32 bytes.
static func _reduce_mod_l(r: PackedByteArray) -> PackedByteArray:
	var x := PackedInt64Array()
	x.resize(64)
	for i in 64:
		x[i] = r[i]
	for i in range(63, 31, -1):
		var carry := 0
		for j in range(i - 32, i - 12):
			x[j] += carry - 16 * x[i] * _L[j - (i - 32)]
			carry = (x[j] + 128) >> 8
			x[j] -= carry << 8
		x[i - 12] += carry
		x[i] = 0
	var carry := 0
	for j in 32:
		x[j] += carry - (x[31] >> 4) * _L[j]
		carry = x[j] >> 8
		x[j] &= 255
	for j in 32:
		x[j] -= carry * _L[j]
	var out := PackedByteArray()
	out.resize(32)
	for i in 32:
		x[i + 1] += x[i] >> 8
		out[i] = x[i] & 255
	return out


# ---- Field arithmetic modulo 2^255 - 19 (sixteen 16-bit limbs) ----

static func _gf(init: Array = []) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in init.size():
		o[i] = init[i]
	return o


static func _carry(o: PackedInt64Array) -> void:
	for i in 16:
		o[i] += 65536
		var c := o[i] >> 16
		if i < 15:
			o[i + 1] += c - 1
		else:
			o[0] += 38 * (c - 1)
		o[i] -= c << 16


static func _fadd(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = a[i] + b[i]
	return o


static func _fsub(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = a[i] - b[i]
	return o


static func _fmul(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var t := PackedInt64Array()
	t.resize(31)
	for i in 16:
		var ai := a[i]
		for j in 16:
			t[i + j] += ai * b[j]
	for i in 15:
		t[i] += 38 * t[i + 16]
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = t[i]
	_carry(o)
	_carry(o)
	return o


static func _fsquare(a: PackedInt64Array) -> PackedInt64Array:
	return _fmul(a, a)


## a^(p-2), the multiplicative inverse.
static func _finvert(i: PackedInt64Array) -> PackedInt64Array:
	var c := i.duplicate()
	for a in range(253, -1, -1):
		c = _fsquare(c)
		if a != 2 and a != 4:
			c = _fmul(c, i)
	return c


## a^((p-5)/8) = a^(2^252 - 3).
static func _fpow2523(i: PackedInt64Array) -> PackedInt64Array:
	var c := i.duplicate()
	for a in range(250, -1, -1):
		c = _fsquare(c)
		if a != 1:
			c = _fmul(c, i)
	return c


## The canonical 32-byte little-endian form of a field element.
static func _fpack(n: PackedInt64Array) -> PackedByteArray:
	var t := n.duplicate()
	_carry(t)
	_carry(t)
	_carry(t)
	var m := PackedInt64Array()
	m.resize(16)
	for _round in 2:
		m[0] = t[0] - 0xffed
		for i in range(1, 15):
			m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
			m[i - 1] &= 0xffff
		m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
		var borrow := (m[15] >> 16) & 1
		m[14] &= 0xffff
		if borrow == 0:
			t = m.duplicate()
	var out := PackedByteArray()
	out.resize(32)
	for i in 16:
		out[2 * i] = t[i] & 0xff
		out[2 * i + 1] = t[i] >> 8
	return out


static func _funpack(b: PackedByteArray) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = b[2 * i] + (b[2 * i + 1] << 8)
	o[15] &= 0x7fff
	return o


static func _parity(a: PackedInt64Array) -> int:
	return _fpack(a)[0] & 1


static func _fequal(a: PackedInt64Array, b: PackedInt64Array) -> bool:
	return _fpack(a) == _fpack(b)


# ---- Curve points: [X, Y, Z, T] ----

static func _identity() -> Array:
	return [_gf(), _gf([1]), _gf([1]), _gf()]


static func _base_point() -> Array:
	var x := _gf(_BASE_X)
	var y := _gf(_BASE_Y)
	return [x, y, _gf([1]), _fmul(x, y)]


## Adds two points (the unified formula, so it doubles as doubling).
static func _add(p: Array, q: Array) -> Array:
	var a := _fmul(_fsub(p[1], p[0]), _fsub(q[1], q[0]))
	var b := _fmul(_fadd(p[0], p[1]), _fadd(q[0], q[1]))
	var c := _fmul(_fmul(p[3], q[3]), _gf(_D2))
	var d := _fmul(p[2], q[2])
	d = _fadd(d, d)
	var e := _fsub(b, a)
	var f := _fsub(d, c)
	var g := _fadd(d, c)
	var h := _fadd(b, a)
	return [_fmul(e, f), _fmul(h, g), _fmul(g, f), _fmul(e, h)]


## [param s] (32 little-endian bytes) times [param q], by double and add from the top bit.
static func _scalar_mult(q: Array, s: PackedByteArray) -> Array:
	var p := _identity()
	for i in range(255, -1, -1):
		p = _add(p, p)
		if (s[i >> 3] >> (i & 7)) & 1 == 1:
			p = _add(p, q)
	return p


static func _pack(p: Array) -> PackedByteArray:
	var zi := _finvert(p[2])
	var tx := _fmul(p[0], zi)
	var ty := _fmul(p[1], zi)
	var out := _fpack(ty)
	out[31] ^= _parity(tx) << 7
	return out


## The key's y-coordinate (its low 255 bits) is below 2^255 - 19.
static func _y_is_canonical(key: PackedByteArray) -> bool:
	if (key[31] & 0x7f) != 0x7f:
		return true
	for i in range(30, 0, -1):
		if key[i] != 0xff:
			return true
	return key[0] < 0xed


## Decodes a public key to the negated point -A, or null when it is not on the curve.
static func _unpack_negated(p: PackedByteArray) -> Variant:
	var one := _gf([1])
	var y := _funpack(p)
	var num := _fsquare(y)
	var den := _fmul(num, _gf(_D))
	num = _fsub(num, one)
	den = _fadd(one, den)
	var den2 := _fsquare(den)
	var den4 := _fsquare(den2)
	var den6 := _fmul(den4, den2)
	var t := _fmul(den6, num)
	t = _fmul(t, den)
	t = _fpow2523(t)
	t = _fmul(t, num)
	t = _fmul(t, den)
	t = _fmul(t, den)
	var x := _fmul(t, den)
	var chk := _fmul(_fsquare(x), den)
	if not _fequal(chk, num):
		x = _fmul(x, _gf(_SQRT_M1))
	chk = _fmul(_fsquare(x), den)
	if not _fequal(chk, num):
		return null
	if _parity(x) == (p[31] >> 7):
		x = _fsub(_gf(), x)
	return [x, y, one, _fmul(x, y)]
