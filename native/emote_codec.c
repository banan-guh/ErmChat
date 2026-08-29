#include "emote_codec.h"

#include <stdlib.h>
#include <string.h>

#include "webp/demux.h"

int emote_decode_webp(const uint8_t* bytes, size_t len, EmoteDecodedFrames* out) {
  if (bytes == NULL || len == 0 || out == NULL) {
    return 0;
  }

  WebPData webp_data = {bytes, len};

  WebPAnimDecoderOptions opts;
  if (!WebPAnimDecoderOptionsInit(&opts)) {
    return 0;
  }
  // MODE_rgbA (lowercase 'a') = premultiplied RGBA. libwebp applies the
  // alpha multiply in C as it emits each row, so the frames come back
  // premultiplied directly and we skip the per-pixel Dart premultiply loop
  // that used to run on the main isolate after decode.
  opts.color_mode = MODE_rgbA;
  // Keep decoding single-threaded. libwebp's threaded anim decoder can
  // deadlock when invoked from a spawned Dart isolate (the path used on iOS,
  // where the shim is statically linked and loaded via DynamicLibrary.process).
  // A hung decode would never return, permanently holding a decode-gate permit
  // and freezing every subsequent animated-WebP emote. Single-threaded matches
  // the Android build, which never compiles libwebp with thread support.
  opts.use_threads = 0;

  WebPAnimDecoder* dec = WebPAnimDecoderNew(&webp_data, &opts);
  if (dec == NULL) {
    return 0;
  }

  WebPAnimInfo info;
  if (!WebPAnimDecoderGetInfo(dec, &info)) {
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  const uint32_t w = info.canvas_width;
  const uint32_t h = info.canvas_height;
  const uint32_t count = info.frame_count;
  if (w == 0 || h == 0 || count == 0) {
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  const size_t canvas_bytes = (size_t)w * h * 4;
  const size_t rgba_total = canvas_bytes * count;
  if (canvas_bytes == 0 || rgba_total / canvas_bytes != count) {
    // Overflow guard.
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  uint8_t* rgba = (uint8_t*)malloc(rgba_total);
  int32_t* durations_ms = (int32_t*)malloc(sizeof(int32_t) * count);
  if (rgba == NULL || durations_ms == NULL) {
    free(rgba);
    free(durations_ms);
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  uint32_t idx = 0;
  int prev_ts = 0;
  while (WebPAnimDecoderHasMoreFrames(dec) && idx < count) {
    uint8_t* buf = NULL;
    int ts = 0;
    if (!WebPAnimDecoderGetNext(dec, &buf, &ts)) {
      break;
    }
    memcpy(rgba + (size_t)idx * canvas_bytes, buf, canvas_bytes);
    durations_ms[idx] = ts - prev_ts;
    prev_ts = ts;
    idx++;
  }
  WebPAnimDecoderDelete(dec);

  if (idx != count) {
    free(rgba);
    free(durations_ms);
    return 0;
  }

  out->canvas_w = w;
  out->canvas_h = h;
  out->frame_count = count;
  out->loop_count = info.loop_count;
  out->durations_ms = durations_ms;
  out->rgba = rgba;
  return 1;
}

void emote_free_frames(EmoteDecodedFrames* frames) {
  if (frames == NULL) {
    return;
  }
  free(frames->durations_ms);
  free(frames->rgba);
  frames->durations_ms = NULL;
  frames->rgba = NULL;
  frames->frame_count = 0;
}
