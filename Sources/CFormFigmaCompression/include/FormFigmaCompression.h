#ifndef FORM_FIGMA_COMPRESSION_H
#define FORM_FIGMA_COMPRESSION_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FormFigmaInflater FormFigmaInflater;
/* codec: 0 = raw DEFLATE, 1 = Zstandard. The caller bounds total output. */
FormFigmaInflater *form_figma_inflater_create(int codec, size_t max_window_bytes);
/* 1 = frame complete, 0 = more input/output needed, -1 = malformed data. */
int form_figma_inflater_step(FormFigmaInflater *state,
  const uint8_t *input, size_t input_size, size_t *input_used,
  uint8_t *output, size_t output_size, size_t *output_used);
void form_figma_inflater_destroy(FormFigmaInflater *state);
#ifdef __cplusplus
}
#endif
#endif
