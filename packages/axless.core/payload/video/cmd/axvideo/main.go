package main

// axvideo — NothingLess frame interpolator.
//
// Decodes a video with libavcodec, takes the motion vectors the decoder
// itself produces, and synthesises the frames needed to reach the display
// refresh rate. This is the offline/verification entry point; the shell
// drives the same package over its socket protocol.

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"time"

	"axvideo"
)

func main() {
	var (
		input  = flag.String("in", "", "input video")
		output = flag.String("out", "", "raw RGB24 output ('-' for stdout)")
		ratio  = flag.Int("ratio", 2, "interpolation ratio (2 = double the frame rate)")
		limit  = flag.Int("frames", 0, "stop after N source frames (0 = all)")
		grid   = flag.Int("grid", 16, "motion grid cell size in pixels")
		quiet  = flag.Bool("quiet", false, "only print the summary")
	)
	flag.Parse()

	if *input == "" {
		fmt.Fprintln(os.Stderr, "axvideo: falta -in")
		os.Exit(2)
	}

	dec, err := axvideo.NewDecoder(*input)
	if err != nil {
		fmt.Fprintln(os.Stderr, "axvideo:", err)
		os.Exit(1)
	}
	defer dec.Close()
	dec.GridSize = *grid

	var out *os.File
	if *output != "" {
		if *output == "-" {
			out = os.Stdout
		} else {
			out, err = os.Create(*output)
			if err != nil {
				fmt.Fprintln(os.Stderr, "axvideo:", err)
				os.Exit(1)
			}
			defer out.Close()
		}
	}

	opt := axvideo.SynthOptions{MaxMotion: 48, BlendGamma: 1.0}

	start := time.Now()
	src, synth := 0, 0
	var motionFrames int

	prev := dec.NextFrame()
	for prev != nil {
		if *limit > 0 && src >= *limit {
			break
		}
		cur := dec.NextFrame()
		if cur == nil {
			break
		}
		src++

		if cur.HasMotion {
			motionFrames++
		}
		if !*quiet {
			fmt.Fprintf(os.Stderr, "frame %d: %d vectores de movimiento\n", src, motionVecCount(cur))
		}

		// Emit the previous source frame verbatim so the output stream has a
		// consistent cadence, then the synthesised in-betweens.
		if out != nil {
			out.Write(prev.RGB)
		}
		for _, f := range axvideo.InterpolatePair(prev, cur, *ratio, opt) {
			if out != nil {
				out.Write(f)
			}
			synth++
		}
		prev = cur
	}

	elapsed := time.Since(start)
	fmt.Printf("fuente: %dx%d | frames fuente: %d | con movimiento: %d\n",
		dec.Width, dec.Height, src, motionFrames)
	fmt.Printf("sintetizados: %d | total salida: %d | ratio real: %.2fx\n",
		synth, src+synth, float64(src+synth)/float64(max(1, src)))
	fmt.Printf("tiempo: %s\n", elapsed.Round(time.Millisecond))
	if src > 0 {
		fmt.Printf("rendimiento: %.1f fps de salida\n",
			float64(src+synth)/elapsed.Seconds())
	}
	_ = binary.LittleEndian
}

func motionVecCount(f *axvideo.Frame) int {
	n := 0
	for _, b := range f.Blocks {
		if b.Valid {
			n++
		}
	}
	return n
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
