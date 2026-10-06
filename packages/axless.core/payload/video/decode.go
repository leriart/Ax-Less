package axvideo

/*
#cgo pkg-config: libavcodec libavutil libavformat libswscale
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/motion_vector.h>
#include <libavutil/pixdesc.h>
#include <libavutil/mathematics.h>
#include <libswscale/swscale.h>
#include <stdlib.h>

// Pointer arithmetic lives in C because cgo cannot index **T fields.
static AVStream *ax_stream(AVFormatContext *f, int i) { return f->streams[i]; }
static AVFrameSideData *ax_side(AVFrame *fr, int i) { return fr->side_data[i]; }
static AVMotionVector *ax_mv(AVFrameSideData *sd, int i) {
    return ((AVMotionVector *)sd->data) + i;
}
static int ax_mv_count(AVFrameSideData *sd) {
    return (int)(sd->size / sizeof(AVMotionVector));
}
// avg_frame_rate is a rational; dividing in Go needs the fields by value.
static double ax_rate_num(AVRational r) { return (double)r.num / r.den; }
// duration / nb_frames live on the stream, not the codec parameters.
static double ax_stream_duration(AVStream *s) {
    if (s->duration > 0) return (double)s->duration / AV_TIME_BASE;
    return 0.0;
}
// The stream duration is often unset for mp4; the container duration is
// authoritative and is what ffprobe reports as DURATION.
static double ax_ctx_duration(AVFormatContext *f) {
    return f->duration / AV_TIME_BASE;
}
static long long ax_stream_frames(AVStream *s) { return (long long)s->nb_frames; }
static double ax_stream_fps(AVStream *s) { return av_q2d(s->avg_frame_rate); }

// Raw planar/whatever frame -> tightly packed RGB24, which is what the rest
// of this package works in.
static int ax_to_rgb(AVFrame *src, uint8_t *dst, int w, int h) {
    struct SwsContext *sws = sws_getContext(
        src->width, src->height, (enum AVPixelFormat)src->format,
        w, h, AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) return -1;
    uint8_t *out[4] = { dst, NULL, NULL, NULL };
    int stride[4] = { w * 3, 0, 0, 0 };
    sws_scale(sws, (const uint8_t *const *)src->data, src->linesize, 0, h, out, stride);
    sws_freeContext(sws);
    return 0;
}
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// MotionVector is a decoder-provided motion vector for one block.
type MotionVector struct {
	SrcX, SrcY int
	DstX, DstY int
	W, H       int
	Source     int // -1 = predicted from the past, +1 = from the future
}

// Block is the motion field resolved onto a uniform grid.
//
// The decoder hands motion vectors in its own block layout (8x8, 8x16,
// 16x8 or 16x16). Interpolation wants a dense, regular grid, so vectors are
// scattered onto a fixed-size grid and gaps are filled with zero motion,
// which degrades to a plain cross-fade for that cell instead of producing
// garbage.
type Block struct {
	DX, DY int
	Valid  bool
}

// Frame is a decoded frame plus its motion field.
type Frame struct {
	RGB    []byte
	Width  int
	Height int
	Blocks []Block
	GridW  int
	GridH  int
	// HasMotion is false for I-frames and for frames the decoder did not
	// attach vectors to.
	HasMotion bool
}

// Info describes a video file as libav sees it. This is how the shell gets
// the *real* frame rate instead of assuming one: the capture cadence that
// drives the interpolation has to match the source or the blend drifts
// against the frames the decoder is producing.
type Info struct {
	Path       string  `json:"path"`
	Width      int     `json:"width"`
	Height     int     `json:"height"`
	FPS        float64 `json:"fps"`
	Duration   float64 `json:"duration"`
	FrameCount int64   `json:"frame_count"`
	HasFrameRate bool `json:"has_frame_rate"`
	// Duration/fps disagreeing means the container lied about the rate; the
	// shell uses FrameCount/Duration as the fallback.
	EstimatedFPS float64 `json:"estimated_fps"`
}

// Probe reads a file's stream parameters without decoding a single frame.
func Probe(path string) (*Info, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))

	var fmtCtx *C.AVFormatContext
	if C.avformat_open_input(&fmtCtx, cpath, nil, nil) < 0 {
		return nil, fmt.Errorf("no se pudo abrir %s", path)
	}
	defer C.avformat_close_input(&fmtCtx)
	if C.avformat_find_stream_info(fmtCtx, nil) < 0 {
		return nil, errors.New("sin stream info")
	}

	vs := C.av_find_best_stream(fmtCtx, C.AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
	if vs < 0 {
		return nil, errors.New("sin stream de video")
	}
	pst := C.ax_stream(fmtCtx, vs)
	par := pst.codecpar
	if par == nil {
		return nil, errors.New("sin codecpar")
	}

	dur := float64(C.ax_stream_duration(pst))
	if dur <= 0 {
		dur = float64(C.ax_ctx_duration(fmtCtx))
	}
	info := &Info{
		Path:        path,
		Width:       int(par.width),
		Height:      int(par.height),
		Duration:    dur,
		FrameCount:  int64(C.ax_stream_frames(pst)),
		FPS:         float64(C.ax_stream_fps(pst)),
	}
	info.HasFrameRate = info.FPS > 0.1
	// Only trust frames/duration when the container gave both and they
	// roughly agree with the declared rate; otherwise it is metadata noise.
	if dur > 0.5 && info.FrameCount > 0 {
		est := float64(info.FrameCount) / dur
		if info.FPS <= 0.1 || (est > info.FPS/2 && est < info.FPS*2) {
			info.EstimatedFPS = est
		}
	}
	if info.EstimatedFPS <= 0 {
		info.EstimatedFPS = info.FPS
	}
	return info, nil
}

// Decoder wraps libavcodec via cgo.
type Decoder struct {
	ctx     *C.AVCodecContext
	fmtCtx  *C.AVFormatContext
	frame   *C.AVFrame
	pkt     *C.AVPacket
	stream  C.int
	scratch *C.SwsContext
	Width   int
	Height  int

	// GridSize is the block cell size in pixels used to build Block grids.
	GridSize int
	// eofOnce guards against an infinite drain loop.
	eofOnce bool
}

// NewDecoder opens path and prepares an RGB decoder.
func NewDecoder(path string) (*Decoder, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))

	var fmtCtx *C.AVFormatContext
	if C.avformat_open_input(&fmtCtx, cpath, nil, nil) < 0 {
		return nil, fmt.Errorf("no se pudo abrir %s", path)
	}
	if C.avformat_find_stream_info(fmtCtx, nil) < 0 {
		C.avformat_close_input(&fmtCtx)
		return nil, errors.New("sin stream info")
	}

	vs := C.av_find_best_stream(fmtCtx, C.AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
	if vs < 0 {
		C.avformat_close_input(&fmtCtx)
		return nil, errors.New("sin stream de video")
	}

	pst := C.ax_stream(fmtCtx, vs)
	codec := C.avcodec_find_decoder(pst.codecpar.codec_id)
	if codec == nil {
		C.avformat_close_input(&fmtCtx)
		return nil, errors.New("sin decoder para ese codec")
	}

	ctx := C.avcodec_alloc_context3(codec)
	if ctx == nil {
		C.avformat_close_input(&fmtCtx)
		return nil, errors.New("no se pudo crear el contexto")
	}
	if C.avcodec_parameters_to_context(ctx, pst.codecpar) < 0 {
		C.avcodec_free_context(&ctx)
		C.avformat_close_input(&fmtCtx)
		return nil, errors.New("codecpar no copiable")
	}

	// This is the flag that makes the decoder attach
	// AV_FRAME_DATA_MOTION_VECTORS. Without it every frame comes back with
	// zero vectors and interpolation silently degrades to plain blending.
	ctx.flags2 |= C.AV_CODEC_FLAG2_EXPORT_MVS

	if C.avcodec_open2(ctx, codec, nil) < 0 {
		C.avcodec_free_context(&ctx)
		C.avformat_close_input(&fmtCtx)
		return nil, errors.New("no se pudo abrir el decoder")
	}

	return &Decoder{
		ctx:      ctx,
		fmtCtx:   fmtCtx,
		frame:    C.av_frame_alloc(),
		pkt:      C.av_packet_alloc(),
		stream:   vs,
		Width:    int(ctx.width),
		Height:   int(ctx.height),
		GridSize: 16,
	}, nil
}

// Close releases every allocation.
func (d *Decoder) Close() {
	if d.frame != nil {
		C.av_frame_free(&d.frame)
		d.frame = nil
	}
	if d.pkt != nil {
		C.av_packet_free(&d.pkt)
		d.pkt = nil
	}
	if d.ctx != nil {
		C.avcodec_free_context(&d.ctx)
		d.ctx = nil
	}
	if d.fmtCtx != nil {
		C.avformat_close_input(&d.fmtCtx)
		d.fmtCtx = nil
	}
}

// NextFrame decodes and returns the next frame, or nil at end of stream.
//
// A decoded frame holds pointers into libav's memory, which the next decode
// reuses, so the RGB data and the motion field are copied out before
// returning. Skipping that copy is the classic way to get smeared
// wallpapers.
func (d *Decoder) NextFrame() *Frame {
	for {
		if C.av_read_frame(d.fmtCtx, d.pkt) < 0 {
			if d.eofOnce {
				return nil
			}
			// Flush the decoder, then stop for good.
			d.eofOnce = true
			C.avcodec_send_packet(d.ctx, nil)
		} else if d.pkt.stream_index != d.stream {
			C.av_packet_unref(d.pkt)
			continue
		} else if C.avcodec_send_packet(d.ctx, d.pkt) < 0 {
			C.av_packet_unref(d.pkt)
			continue
		}

		if C.avcodec_receive_frame(d.ctx, d.frame) == 0 {
			f := d.buildFrame()
			C.av_frame_unref(d.frame)
			return f
		}
		if d.eofOnce && C.av_read_frame(d.fmtCtx, d.pkt) < 0 {
			return nil
		}
		C.av_packet_unref(d.pkt)
	}
}

func (d *Decoder) buildFrame() *Frame {
	w, h := d.Width, d.Height
	out := make([]byte, w*h*3)
	if C.ax_to_rgb(d.frame, (*C.uint8_t)(unsafe.Pointer(&out[0])), C.int(w), C.int(h)) < 0 {
		return nil
	}

	gridW := (w + d.GridSize - 1) / d.GridSize
	gridH := (h + d.GridSize - 1) / d.GridSize
	blocks := make([]Block, gridW*gridH)

	hasMotion := false
	for i := 0; i < int(d.frame.nb_side_data); i++ {
		sd := C.ax_side(d.frame, C.int(i))
		if sd == nil || uint32(sd._type) != uint32(C.AV_FRAME_DATA_MOTION_VECTORS) {
			continue
		}
		n := int(C.ax_mv_count(sd))
		if n <= 0 {
			continue
		}
		hasMotion = true
		for k := 0; k < n; k++ {
			mv := C.ax_mv(sd, C.int(k))
			dx := int(mv.dst_x) - int(mv.src_x)
			dy := int(mv.dst_y) - int(mv.src_y)
			if dx == 0 && dy == 0 {
				continue
			}
			// Scatter onto the uniform grid, attributing each vector to the
			// cell its *destination* falls in.
			cx := int(mv.dst_x) / d.GridSize
			cy := int(mv.dst_y) / d.GridSize
			if cx < 0 || cy < 0 || cx >= gridW || cy >= gridH {
				continue
			}
			idx := cy*gridW + cx
			blocks[idx].DX = dx
			blocks[idx].DY = dy
			blocks[idx].Valid = true
		}
	}

	return &Frame{
		RGB:       out,
		Width:     w,
		Height:    h,
		Blocks:    blocks,
		GridW:     gridW,
		GridH:     gridH,
		HasMotion: hasMotion,
	}
}