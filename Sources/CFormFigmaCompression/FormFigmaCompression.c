#include "FormFigmaCompression.h"
#include "vendor/zstd.h"
#include <zlib.h>
#include <limits.h>
#include <stdlib.h>

struct FormFigmaInflater { int codec; z_stream deflate; ZSTD_DStream *zstd; };

FormFigmaInflater *form_figma_inflater_create(int codec, size_t max_window_bytes) {
  if (codec != 0 && codec != 1) return NULL;
  FormFigmaInflater *state = (FormFigmaInflater *)calloc(1, sizeof(*state));
  if (!state) return NULL;
  state->codec = codec;
  if (codec == 0) {
    if (inflateInit2(&state->deflate, -MAX_WBITS) != Z_OK) { free(state); return NULL; }
  } else {
    state->zstd = ZSTD_createDStream();
    unsigned int log = 10;
    /* Use the largest power of two within the byte budget, never above 64 MiB. */
    while (log < 26 && ((size_t)1 << (log + 1)) <= max_window_bytes) ++log;
    if (!state->zstd || ZSTD_isError(ZSTD_DCtx_setParameter(state->zstd, ZSTD_d_windowLogMax, (int)log))) {
      if (state->zstd) ZSTD_freeDStream(state->zstd);
      free(state); return NULL;
    }
  }
  return state;
}

int form_figma_inflater_step(FormFigmaInflater *state,
  const uint8_t *input, size_t input_size, size_t *input_used,
  uint8_t *output, size_t output_size, size_t *output_used) {
  *input_used = 0; *output_used = 0;
  if (!state || input_size > UINT_MAX || output_size > UINT_MAX) return -1;
  if (state->codec == 0) {
    state->deflate.next_in = (Bytef *)input; state->deflate.avail_in = (uInt)input_size;
    state->deflate.next_out = output; state->deflate.avail_out = (uInt)output_size;
    int result = inflate(&state->deflate, Z_NO_FLUSH);
    *input_used = input_size - state->deflate.avail_in;
    *output_used = output_size - state->deflate.avail_out;
    return result == Z_STREAM_END ? 1 : (result == Z_OK || result == Z_BUF_ERROR ? 0 : -1);
  }
  ZSTD_inBuffer in = { input, input_size, 0 };
  ZSTD_outBuffer out = { output, output_size, 0 };
  size_t result = ZSTD_decompressStream(state->zstd, &out, &in);
  *input_used = in.pos; *output_used = out.pos;
  return ZSTD_isError(result) ? -1 : (result == 0 ? 1 : 0);
}

void form_figma_inflater_destroy(FormFigmaInflater *state) {
  if (!state) return;
  if (state->codec == 0) inflateEnd(&state->deflate);
  else ZSTD_freeDStream(state->zstd);
  free(state);
}
