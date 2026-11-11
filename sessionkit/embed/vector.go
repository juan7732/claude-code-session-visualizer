package embed

import (
	"encoding/binary"
	"fmt"
	"math"
)

// Vectors are stored as little-endian IEEE 754 half floats: 1.5 KB for 768
// dimensions, half of float32. They are L2-normalised first, so every value is
// in [-1, 1] and the rounding costs nothing a ranking can see (the spike
// measured Q8_0 against BF16 at cosine 0.9999; fp16 storage is finer than that).

// Normalize scales v to unit length in place and returns it. A zero vector is
// left alone.
func Normalize(v []float32) []float32 {
	var sum float64
	for _, x := range v {
		sum += float64(x) * float64(x)
	}
	if sum == 0 {
		return v
	}
	inv := float32(1 / math.Sqrt(sum))
	for i := range v {
		v[i] *= inv
	}
	return v
}

// Pack encodes v as half floats.
func Pack(v []float32) []byte {
	out := make([]byte, 2*len(v))
	for i, x := range v {
		binary.LittleEndian.PutUint16(out[2*i:], toHalf(x))
	}
	return out
}

// Unpack decodes half floats into dst, which must have len(b)/2 elements.
func Unpack(dst []float32, b []byte) error {
	if len(b) != 2*len(dst) {
		return fmt.Errorf("vector blob is %d bytes, expected %d", len(b), 2*len(dst))
	}
	for i := range dst {
		dst[i] = fromHalf(binary.LittleEndian.Uint16(b[2*i:]))
	}
	return nil
}

// halfTable holds the float32 for every half float, so reading a stored vector
// is a lookup per number.
var halfTable = func() *[1 << 16]float32 {
	var t [1 << 16]float32
	for h := range t {
		t[h] = fromHalf(uint16(h))
	}
	return &t
}()

// DotPacked is the inner product of q with a packed vector, without unpacking
// it first. b must hold 2*len(q) bytes.
func DotPacked(q []float32, b []byte) float32 {
	if len(b) < 2*len(q) {
		return 0
	}
	var s float32
	for i, x := range q {
		s += x * halfTable[uint16(b[2*i])|uint16(b[2*i+1])<<8]
	}
	return s
}

// Dot is the inner product, which is the cosine for unit vectors.
func Dot(a, b []float32) float32 {
	var s float32
	for i := range a {
		s += a[i] * b[i]
	}
	return s
}

// toHalf converts to half precision, rounding to nearest even.
func toHalf(f float32) uint16 {
	b := math.Float32bits(f)
	sign := uint16(b>>16) & 0x8000
	exp := int(b>>23) & 0xff
	man := b & 0x7fffff
	switch {
	case exp == 0xff: // infinity or NaN
		if man != 0 {
			return sign | 0x7e00
		}
		return sign | 0x7c00
	case exp > 142: // too large for a half: infinity
		return sign | 0x7c00
	case exp >= 113: // normal half
		h := uint32(exp-112)<<10 | man>>13
		if rem := man & 0x1fff; rem > 0x1000 || (rem == 0x1000 && h&1 == 1) {
			h++ // may carry into the exponent, which is the right result
		}
		return sign | uint16(h)
	case exp >= 102: // subnormal half
		man |= 0x800000
		shift := uint(126 - exp)
		h := man >> shift
		half := uint32(1) << (shift - 1)
		if rem := man & (half<<1 - 1); rem > half || (rem == half && h&1 == 1) {
			h++
		}
		return sign | uint16(h)
	default: // rounds to zero
		return sign
	}
}

func fromHalf(h uint16) float32 {
	sign := uint32(h&0x8000) << 16
	exp := uint32(h>>10) & 0x1f
	man := uint32(h & 0x3ff)
	switch {
	case exp == 0x1f:
		return math.Float32frombits(sign | 0x7f800000 | man<<13)
	case exp != 0:
		return math.Float32frombits(sign | (exp+112)<<23 | man<<13)
	case man == 0:
		return math.Float32frombits(sign)
	default: // subnormal: shift the mantissa up until its leading bit is set
		e := uint32(113)
		for man&0x400 == 0 {
			man <<= 1
			e--
		}
		return math.Float32frombits(sign | e<<23 | (man&0x3ff)<<13)
	}
}
