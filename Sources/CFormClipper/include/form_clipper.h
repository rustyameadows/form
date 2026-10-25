#ifndef FORM_CLIPPER_H
#define FORM_CLIPPER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { double *coordinates; int32_t *counts; int32_t count; int32_t status; } FCPaths;
FCPaths fc_offset(const double *coordinates, const int32_t *counts, int32_t count, double delta, double arc_tolerance);
FCPaths fc_boolean(const double *coordinates, const int32_t *counts, int32_t count, const double *clip_coordinates, const int32_t *clip_counts, int32_t clip_count, int32_t operation);
void fc_free(FCPaths paths);
const char *fc_version(void);
#ifdef __cplusplus
}
#endif
#endif
