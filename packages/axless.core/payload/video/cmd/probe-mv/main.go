package main

/*
#cgo pkg-config: libavcodec libavutil libavformat
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
#include <libavutil/motion_vector.h>
#include <stdlib.h>

// Pointer arithmetic in C: cgo cannot index **T fields directly.
static AVStream *ax_stream(AVFormatContext *f, int i) { return f->streams[i]; }
static AVFrameSideData *ax_side(AVFrame *fr, int i) { return fr->side_data[i]; }
static AVMotionVector *ax_mv(AVFrameSideData *sd, int i) {
    return ((AVMotionVector *)sd->data) + i;
}
static int ax_mv_count(AVFrameSideData *sd) {
    return (int)(sd->size / sizeof(AVMotionVector));
}
*/
import "C"

import (
	"fmt"
	"os"
	"unsafe"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("uso: mvprobe <video>")
		return
	}

	codec := C.avcodec_find_decoder(C.AV_CODEC_ID_H264)
	if codec == nil {
		fmt.Println("no hay decoder h264")
		return
	}
	pc := C.avcodec_alloc_context3(codec)
	defer C.avcodec_free_context(&pc)
	// Without this the decoder does not populate the
	// AV_FRAME_DATA_MOTION_VECTORS side data at all.
	pc.flags2 |= C.AV_CODEC_FLAG2_EXPORT_MVS

	name := C.CString(os.Args[1])
	defer C.free(unsafe.Pointer(name))
	var fmtCtx *C.AVFormatContext
	if C.avformat_open_input(&fmtCtx, name, nil, nil) < 0 {
		fmt.Println("no se pudo abrir:", os.Args[1])
		return
	}
	defer C.avformat_close_input(&fmtCtx)
	if C.avformat_find_stream_info(fmtCtx, nil) < 0 {
		fmt.Println("sin stream info")
		return
	}

	vs := C.av_find_best_stream(fmtCtx, C.AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
	if vs < 0 {
		fmt.Println("sin stream de video")
		return
	}
	pst := C.ax_stream(fmtCtx, C.int(vs))
	if C.avcodec_parameters_to_context(pc, pst.codecpar) < 0 {
		fmt.Println("no se pudo copiar codecpar")
		return
	}
	if C.avcodec_open2(pc, codec, nil) < 0 {
		fmt.Println("no se pudo abrir el decoder")
		return
	}
	fmt.Printf("video: %dx%d\n", pc.width, pc.height)

	frame := C.av_frame_alloc()
	defer C.av_frame_free(&frame)
	pkt := C.av_packet_alloc()
	defer C.av_packet_free(&pkt)

	nFrames, nMVFrames, totalMV := 0, 0, 0
	for {
		if C.av_read_frame(fmtCtx, pkt) < 0 {
			break
		}
		if pkt.stream_index != vs {
			C.av_packet_unref(pkt)
			continue
		}
		if C.avcodec_send_packet(pc, pkt) < 0 {
			C.av_packet_unref(pkt)
			continue
		}
		for C.avcodec_receive_frame(pc, frame) == 0 {
			nFrames++
			for i := 0; i < int(frame.nb_side_data); i++ {
				sd := C.ax_side(frame, C.int(i))
				if sd == nil || uint32(sd._type) != uint32(C.AV_FRAME_DATA_MOTION_VECTORS) {
					continue
				}
				n := int(C.ax_mv_count(sd))
				nMVFrames++
				totalMV += n
				if nMVFrames == 2 && n > 0 {
					fmt.Printf("frame %d: %d vectores\n", nFrames, n)
					// buscar los de mayor magnitud: Movement real, no vectores nulos
					shown := 0
					for k := 0; k < n && shown < 5; k++ {
						m := C.ax_mv(sd, C.int(k))
						dx := int(m.dst_x) - int(m.src_x)
						dy := int(m.dst_y) - int(m.src_y)
						if dx == 0 && dy == 0 {
							continue
						}
						fmt.Printf("  MOV src(%d,%d) -> dst(%d,%d) delta(%+d,%+d) %dx%d source=%d\n",
							m.src_x, m.src_y, m.dst_x, m.dst_y, dx, dy, m.w, m.h, m.source)
						shown++
					}
					if shown == 0 {
						fmt.Println("  (todos los vectores son nulos en este frame)")
					}
				}
			}
			C.av_frame_unref(frame)
		}
		C.av_packet_unref(pkt)
	}
	fmt.Printf("frames: %d | frames con MV: %d | vectores totales: %d\n",
		nFrames, nMVFrames, totalMV)
}
