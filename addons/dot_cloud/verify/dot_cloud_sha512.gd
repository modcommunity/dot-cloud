class_name DotCloudSha512
extends RefCounted

## SHA-512 in plain GDScript.
##
## Godot's [HashingContext] stops at SHA-256, and Ed25519 ([DotCloudEd25519]) hashes with SHA-512,
## so this is the missing piece. It works on 64-bit words held in GDScript's signed 64-bit
## integers: addition and left shifts wrap exactly as the arithmetic needs, and every right shift
## is masked so it is logical, not arithmetic. Used for a few hundred bytes at a time (a
## signature check), not for files.

const BLOCK_BYTES := 128

## The first 64 bits of the fractional parts of the cube roots of the first 80 primes, as signed
## 64-bit integers (GDScript has no unsigned literals).
const K: PackedInt64Array = [
	4794697086780616226, 8158064640168781261, -5349999486874862801, -1606136188198331460,
	4131703408338449720, 6480981068601479193, -7908458776815382629, -6116909921290321640,
	-2880145864133508542, 1334009975649890238, 2608012711638119052, 6128411473006802146,
	8268148722764581231, -9160688886553864527, -7215885187991268811, -4495734319001033068,
	-1973867731355612462, -1171420211273849373, 1135362057144423861, 2597628984639134821,
	3308224258029322869, 5365058923640841347, 6679025012923562964, 8573033837759648693,
	-7476448914759557205, -6327057829258317296, -5763719355590565569, -4658551843659510044,
	-4116276920077217854, -3051310485924567259, 489312712824947311, 1452737877330783856,
	2861767655752347644, 3322285676063803686, 5560940570517711597, 5996557281743188959,
	7280758554555802590, 8532644243296465576, -9096487096722542874, -7894198246740708037,
	-6719396339535248540, -6333637450476146687, -4446306890439682159, -4076793802049405392,
	-3345356375505022440, -2983346525034927856, -860691631967231958, 1182934255886127544,
	1847814050463011016, 2177327727835720531, 2830643537854262169, 3796741975233480872,
	4115178125766777443, 5681478168544905931, 6601373596472566643, 7507060721942968483,
	8399075790359081724, 8693463985226723168, -8878714635349349518, -8302665154208450068,
	-8016688836872298968, -6606660893046293015, -4685533653050689259, -4147400797238176981,
	-3880063495543823972, -3348786107499101689, -1523767162380948706, -757361751448694408,
	500013540394364858, 748580250866718886, 1242879168328830382, 1977374033974150939,
	2944078676154940804, 3659926193048069267, 4368137639120453308, 4836135668995329356,
	5532061633213252278, 6448918945643986474, 6902733635092675308, 7801388544844847127,
]

## The first 64 bits of the fractional parts of the square roots of the first 8 primes.
const H0: PackedInt64Array = [7640891576956012808, -4942790177534073029, 4354685564936845355, -6534734903238641935, 5840696475078001361, -7276294671716946913, 2270897969802886507, 6620516959819538809]


## SHA-512 of [param data] as 64 raw bytes.
static func digest(data: PackedByteArray) -> PackedByteArray:
	var padded := data.duplicate()
	padded.append(0x80)
	while padded.size() % BLOCK_BYTES != BLOCK_BYTES - 16:
		padded.append(0)
	# A 128-bit big-endian bit length; the high 64 bits are zero for anything that fits in memory.
	for _i in 8:
		padded.append(0)
	var bits := data.size() * 8
	for i in 8:
		padded.append((bits >> (56 - 8 * i)) & 0xff)

	var h := H0.duplicate()
	var w := PackedInt64Array()
	w.resize(80)
	for block in range(0, padded.size(), BLOCK_BYTES):
		for t in 16:
			var v := 0
			for b in 8:
				v = (v << 8) | padded[block + t * 8 + b]
			w[t] = v
		for t in range(16, 80):
			var w15 := w[t - 15]
			var w2 := w[t - 2]
			var s0 := _rotr(w15, 1) ^ _rotr(w15, 8) ^ _shr(w15, 7)
			var s1 := _rotr(w2, 19) ^ _rotr(w2, 61) ^ _shr(w2, 6)
			w[t] = w[t - 16] + s0 + w[t - 7] + s1
		var a := h[0]
		var b := h[1]
		var c := h[2]
		var d := h[3]
		var e := h[4]
		var f := h[5]
		var g := h[6]
		var hh := h[7]
		for t in 80:
			var big1 := _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41)
			var ch := (e & f) ^ (~e & g)
			var t1 := hh + big1 + ch + K[t] + w[t]
			var big0 := _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39)
			var maj := (a & b) ^ (a & c) ^ (b & c)
			var t2 := big0 + maj
			hh = g
			g = f
			f = e
			e = d + t1
			d = c
			c = b
			b = a
			a = t1 + t2
		h[0] += a
		h[1] += b
		h[2] += c
		h[3] += d
		h[4] += e
		h[5] += f
		h[6] += g
		h[7] += hh

	var out := PackedByteArray()
	for word in h:
		for i in 8:
			out.append((word >> (56 - 8 * i)) & 0xff)
	return out


## Logical right shift of a 64-bit word ([code]n[/code] from 1 to 63).
static func _shr(x: int, n: int) -> int:
	return (x >> n) & ((1 << (64 - n)) - 1)


static func _rotr(x: int, n: int) -> int:
	return _shr(x, n) | (x << (64 - n))
