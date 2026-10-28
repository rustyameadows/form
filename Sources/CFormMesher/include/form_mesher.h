#ifndef FORM_MESHER_H
#define FORM_MESHER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FMIndexBuffer { uint32_t *indices; size_t count; } FMIndexBuffer;
/* One outer ring then holes, physical2D coordinates. Bounded seed only;
   callers independently validate area/boundary/manifold/hole invariants. */
int fm_triangulate(const double *xy,size_t point_count,const uint32_t *ring_sizes,size_t ring_count,FMIndexBuffer *result);
void fm_free_indices(FMIndexBuffer *result);
#ifdef __cplusplus
}
#endif
#endif
