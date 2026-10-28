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
/* Bounded implicit solids, millimeters. Orthonormal columns u/v/w; radii > 0.
   kind 0 is an ellipsoid, kind 1 a round tapered segment (c -> c + w*length).
   Optional planar trimming and explicit enclosed-void filling are generic
   construction operations; disabled operations preserve the source boundary. */
typedef struct FMOrganicShape {
  double cx,cy,cz, ux,uy,uz, vx,vy,vz, wx,wy,wz;
  double rx,ry,rz,length,blend,end_aspect;
  int kind;
} FMOrganicShape;
typedef struct FMOrganicMesh { double *xyz; uint32_t *indices; size_t vertex_count,index_count; } FMOrganicMesh;
int fm_organic_mesh(const FMOrganicShape *shapes,size_t count,double spacing,int trim_floor,double floor_y,int fill_voids,FMOrganicMesh *result);
void fm_free_organic_mesh(FMOrganicMesh *result);
#ifdef __cplusplus
}
#endif
#endif
