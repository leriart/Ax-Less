package axvideo

import "math"

// SynthOptions tunes the frame generator.
type SynthOptions struct {
	// MaxMotion clamps per-cell displacement in pixels. Motion vectors from
	// the codec describe the full frame-to-frame displacement; a value that
	// is absurdly large means a bad block and warping by it smears the
	// whole cell across the screen. FSR applies the same kind of clamp.
	MaxMotion int
	// BlendGamma shapes the A/B mix. 1.0 is linear.
	BlendGamma float64
}

func defaultSynthOptions() SynthOptions {
	return SynthOptions{MaxMotion: 48, BlendGamma: 1.0}
}

func clampi(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// sample bilinear RGB from a frame, returning false when the coordinates
// fall outside the frame. Out-of-range reads are how disocclusion shows up:
// a cell whose motion points into territory neither frame can explain.
func sample(f *Frame, x, y float64) (r, g, b uint8, ok bool) {
	if x < 0 || y < 0 || x >= float64(f.Width) || y >= float64(f.Height) {
		return 0, 0, 0, false
	}
	x0 := int(x)
	y0 := int(y)
	x1 := x0 + 1
	y1 := y0 + 1
	fx := x - float64(x0)
	fy := y - float64(y0)
	if x1 >= f.Width {
		x1 = f.Width - 1
	}
	if y1 >= f.Height {
		y1 = f.Height - 1
	}

	i00 := (y0*f.Width + x0) * 3
	i10 := (y0*f.Width + x1) * 3
	i01 := (y1*f.Width + x0) * 3
	i11 := (y1*f.Width + x1) * 3

	w00 := (1 - fx) * (1 - fy)
	w10 := fx * (1 - fy)
	w01 := (1 - fx) * fy
	w11 := fx * fy

	return uint8(float64(f.RGB[i00])*w00 + float64(f.RGB[i10])*w10 +
			float64(f.RGB[i01])*w01 + float64(f.RGB[i11])*w11),
		uint8(float64(f.RGB[i00+1])*w00 + float64(f.RGB[i10+1])*w10 +
			float64(f.RGB[i01+1])*w01 + float64(f.RGB[i11+1])*w11),
		uint8(float64(f.RGB[i00+2])*w00 + float64(f.RGB[i10+2])*w10 +
			float64(f.RGB[i01+2])*w01 + float64(f.RGB[i11+2])*w11),
		true
}

// Synthesize builds the frame at phase t (0 = a, 1 = b) between two decoded
// frames, using b's motion field to warp both towards t.
//
// The method is the one FSR uses: for every cell, walk backwards along the
// motion vector into frame a and forwards along it into frame b, then blend.
// Cells with no usable vector, or whose samples fall outside a frame, fall
// back to a straight cross-fade - degraded, never garbage.
//
// Returns a newly allocated RGB24 buffer.
func Synthesize(a, b *Frame, t float64, opt SynthOptions) []byte {
	if opt.MaxMotion <= 0 {
		opt = defaultSynthOptions()
	}
	if t < 0 {
		t = 0
	}
	if t > 1 {
		t = 1
	}
	if opt.BlendGamma <= 0 {
		opt.BlendGamma = 1.0
	}

	w, h := a.Width, a.Height
	out := make([]byte, w*h*3)
	gridSize := w / a.GridW
	if gridSize <= 0 {
		gridSize = 16
	}

	// With no motion information at all there is nothing to warp: this is a
	// pure cross-fade and doing the full warp per pixel would only cost time.
	useMotion := b.HasMotion && b.GridW == a.GridW && b.GridH == a.GridH

	for py := 0; py < h; py++ {
		gy := py / gridSize
		if gy >= b.GridH {
			gy = b.GridH - 1
		}
		rowBase := py * w * 3

		for px := 0; px < w; px++ {
			var (
				ra, rb           uint8
				ag, ab, bg, bb   uint8
				okA, okB         = true, true
			)

			if useMotion {
				gx := px / gridSize
				if gx >= b.GridW {
					gx = b.GridW - 1
				}
				blk := b.Blocks[gy*b.GridW+gx]

				dx, dy := blk.DX, blk.DY
				if !blk.Valid {
					dx, dy = 0, 0
				}
				// Clamp so one bad vector cannot tear a cell apart.
				if dx > opt.MaxMotion {
					dx = opt.MaxMotion
				} else if dx < -opt.MaxMotion {
					dx = -opt.MaxMotion
				}
				if dy > opt.MaxMotion {
					dy = opt.MaxMotion
				} else if dy < -opt.MaxMotion {
					dy = -opt.MaxMotion
				}

				// At t the pixel sits t of the way along the vector, so the
				// source samples are one t back and (1-t) forward.
				saR, saG, saB, saOK := sample(a, float64(px)-float64(dx)*t, float64(py)-float64(dy)*t)
				sbR, sbG, sbB, sbOK := sample(b, float64(px)+float64(dx)*(1-t), float64(py)+float64(dy)*(1-t))
				ra, rb, okA, okB = saR, sbR, saOK, sbOK
				if okA && okB {
					out[rowBase+px*3+1] = mix(saG, sbG, t, opt.BlendGamma)
					out[rowBase+px*3+2] = mix(saB, sbB, t, opt.BlendGamma)
				}
			} else {
				ra, ag, ab, okA = sample(a, float64(px), float64(py))
				rb, bg, bb, okB = sample(b, float64(px), float64(py))
				if okA && okB {
					out[rowBase+px*3+1] = mix(ag, bg, t, opt.BlendGamma)
					out[rowBase+px*3+2] = mix(ab, bb, t, opt.BlendGamma)
				}
			}

			i := rowBase + px*3
			switch {
			case okA && okB:
				out[i] = mix(ra, rb, t, opt.BlendGamma)
				// green/blue were already mixed where they were sampled
			case okA:
				copy(out[i:i+3], a.RGB[i:i+3])
			case okB:
				copy(out[i:i+3], b.RGB[i:i+3])
			default:
				out[i], out[i+1], out[i+2] = 0, 0, 0
			}
		}
	}
	return out
}

func mix(a, b uint8, t, gamma float64) uint8 {
	if gamma != 1.0 {
		t = math.Pow(t, gamma)
	}
	v := float64(a)*(1-t) + float64(b)*t
	if v < 0 {
		v = 0
	}
	if v > 255 {
		v = 255
	}
	return uint8(v + 0.5)
}

// InterpolatePair returns the intermediate frames needed to go from a to b at
// the given ratio, e.g. 2 means 24->48 fps (one frame in between).
func InterpolatePair(a, b *Frame, ratio int, opt SynthOptions) [][]byte {
	if ratio <= 1 {
		return nil
	}
	out := make([][]byte, 0, ratio-1)
	for i := 1; i < ratio; i++ {
		out = append(out, Synthesize(a, b, float64(i)/float64(ratio), opt))
	}
	return out
}