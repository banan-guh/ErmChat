#ifndef EMOTE_CODEC_H
#define EMOTE_CODEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decoded animated image frames in a single contiguous allocation.
///
/// `rgba` holds frame_count * canvas_w * canvas_h * 4 bytes of straight-alpha
/// RGBA (one full canvas per frame, all frames concatenated). `durations_ms`
/// holds one entry per frame. Free with [emote_free_frames].
typedef struct {
  uint32_t canvas_w;
  uint32_t canvas_h;
  uint32_t frame_count;
  uint32_t loop_count;
  int32_t* durations_ms;   // frame_count entries
  uint8_t* rgba;           // frame_count * canvas_w * canvas_h * 4
} EmoteDecodedFrames;

/// Decodes an animated WebP (via libwebp's WebPAnimDecoder, which handles
/// blend/dispose/keyframe compositing) into [EmoteDecodedFrames].
///
/// Returns 1 on success (out is fully populated, caller owns it), 0 on
/// failure (out is left untouched). Static WebP decodes to a single frame.
int emote_decode_webp(const uint8_t* bytes, size_t len, EmoteDecodedFrames* out);

/// Frees a structure returned by [emote_decode_webp].
void emote_free_frames(EmoteDecodedFrames* frames);

#ifdef __cplusplus
}
#endif

#endif // EMOTE_CODEC_H
