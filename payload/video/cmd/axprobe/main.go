package main

// axprobe — reports real stream parameters for a video, so the shell never
// has to guess the frame rate.

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"axvideo"
)

func main() {
	var asJSON = flag.Bool("json", false, "emit JSON")
	flag.Parse()

	for _, path := range flag.Args() {
		info, err := axvideo.Probe(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			continue
		}
		if *asJSON {
			b, _ := json.Marshal(info)
			fmt.Println(string(b))
			continue
		}
		fmt.Printf("%s\n  %dx%d  fps=%.3f (estimado %.3f)  frames=%d  dur=%.2fs\n",
			info.Path, info.Width, info.Height, info.FPS,
			info.EstimatedFPS, info.FrameCount, info.Duration)
	}
}
