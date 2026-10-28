#ifndef FORM_CAD_KERNEL_H
#define FORM_CAD_KERNEL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* All public lengths/points use millimeters, right-handed XYZ with +Y up.
   Inputs are immutable. A success allocates one owned shape; release exactly
   once. Failure leaves inputs/output unchanged and returns a bounded message.
   Handles may be shared read-only; serialize geometry operations in one worker.
   Face/edge indices are 1-based and scoped to this exact B-rep revision. */
typedef struct FCADShape FCADShape;
typedef struct FCADContext FCADContext;
typedef struct FCADSTEPDocument FCADSTEPDocument;
typedef struct FCADPoint { double x,y,z; } FCADPoint;
typedef enum FCADStatus { FCAD_OK=0, FCAD_INVALID_INPUT=1, FCAD_OPERATION_FAILED=2,
 FCAD_INVALID_TOPOLOGY=3, FCAD_LIMIT_EXCEEDED=4, FCAD_IO_FAILED=5, FCAD_CANCELLED=6 } FCADStatus;
typedef struct FCADFailure { int32_t code; char message[1024]; } FCADFailure;
typedef struct FCADShapeInfo {
 FCADPoint minimum, maximum; double volume, area, maximum_tolerance;
 uint32_t solids, shells, faces, edges, vertices; int32_t valid, closed, shape_type;
} FCADShapeInfo;
typedef struct FCADFaceInfo { uint32_t index; int32_t surface_type; double area; FCADPoint center,minimum,maximum; } FCADFaceInfo;
typedef struct FCADEdgeInfo { uint32_t index; int32_t curve_type; double length; FCADPoint start,end,center; } FCADEdgeInfo;
typedef struct FCADCurveSegment { int32_t kind; FCADPoint start, control1, control2, end; } FCADCurveSegment;
/* kind 0 line, 1 quadratic Bezier, 2 cubic Bezier, 3 circular arc through control1. */
typedef struct FCADMesh {
 double *positions; double *normals; double *uvs; uint32_t *indices; uint32_t *face_indices;
 size_t vertex_count, index_count, triangle_count;
} FCADMesh;
/* STEP source occurrence paths and face ordinals are bound to the exact source
   digest + kernel version. Colors use linear-sRGB, alpha in [0,1]. */
typedef struct FCADSTEPNodeInfo {
 char path[512],definition_key[256],name[1024];
 int32_t parent_index,is_assembly,has_color;
 double local_transform[16],world_transform[16],color_rgba[4];
 uint32_t face_color_count;
} FCADSTEPNodeInfo;
typedef struct FCADFaceColor {uint32_t face_index;double rgba[4];} FCADFaceColor;
FCADStatus fcad_read_step_document(FCADContext*,const char*path,FCADSTEPDocument**,FCADFailure*);
void fcad_step_document_release(FCADSTEPDocument*);
size_t fcad_step_node_count(const FCADSTEPDocument*);
FCADStatus fcad_step_node_info(FCADContext*,const FCADSTEPDocument*,size_t index,FCADSTEPNodeInfo*,FCADFailure*);
FCADStatus fcad_step_part(FCADContext*,const FCADSTEPDocument*,const char*part_path,FCADShape**,FCADFailure*);
FCADStatus fcad_step_face_colors(FCADContext*,const FCADSTEPDocument*,size_t node_index,FCADFaceColor*,size_t capacity,FCADFailure*);
const char *fcad_version(void);
FCADContext *fcad_context_create(void);
void fcad_context_cancel(FCADContext *context);
void fcad_context_release(FCADContext *context);
void fcad_shape_release(FCADShape *shape);
void fcad_mesh_release(FCADMesh *mesh);
FCADStatus fcad_box(FCADContext*,double width,double height,double depth,FCADShape**,FCADFailure*);
FCADStatus fcad_cylinder(FCADContext*,double radius,double height,FCADShape**,FCADFailure*);
FCADStatus fcad_cone(FCADContext*,double bottom_radius,double top_radius,double height,FCADShape**,FCADFailure*);
FCADStatus fcad_sphere(FCADContext*,double radius,FCADShape**,FCADFailure*);
FCADStatus fcad_torus(FCADContext*,double major_radius,double minor_radius,FCADShape**,FCADFailure*);
/* First ring is outer, subsequent rings are holes; all points planar, rings unclosed.
   normal determines winding (outer CCW; holes CW). No implicit unit conversion. */
FCADStatus fcad_profile(FCADContext*,const FCADPoint *points,size_t point_count,const uint32_t *ring_sizes,size_t ring_count,FCADPoint normal,FCADShape**,FCADFailure*);
FCADStatus fcad_circle_profile(FCADContext*,FCADPoint origin,FCADPoint normal,FCADPoint x_direction,double radius,FCADShape**,FCADFailure*);
FCADStatus fcad_curve_profile(FCADContext*,const FCADCurveSegment *segments,size_t count,FCADShape**,FCADFailure*);
FCADStatus fcad_extrude(FCADContext*,const FCADShape *profile,FCADPoint vector,FCADShape**,FCADFailure*);
FCADStatus fcad_revolve(FCADContext*,const FCADShape *profile,FCADPoint axis_origin,FCADPoint axis_direction,double radians,FCADShape**,FCADFailure*);
/* operation: 0 union, 1 subtract, 2 intersection. Empty/non-solid results reject. */
FCADStatus fcad_boolean(FCADContext*,int32_t operation,const FCADShape*,const FCADShape*,FCADShape**,FCADFailure*);
/* Empty edge list explicitly means all current edges. IDs are revision-scoped. */
FCADStatus fcad_fillet(FCADContext*,const FCADShape*,const uint32_t *edges,size_t count,double radius,FCADShape**,FCADFailure*);
FCADStatus fcad_chamfer(FCADContext*,const FCADShape*,const uint32_t *edges,size_t count,double distance,FCADShape**,FCADFailure*);
/* Faces removed are explicit. Positive thickness hollows inward. */
FCADStatus fcad_shell(FCADContext*,const FCADShape*,const uint32_t *remove_faces,size_t count,double thickness,FCADShape**,FCADFailure*);
/* Offset a single-loop planar face. Positive expands; negative contracts. */
FCADStatus fcad_offset_profile(FCADContext*,const FCADShape*,double distance,FCADShape**,FCADFailure*);
FCADStatus fcad_sweep(FCADContext*,const FCADShape *profile,const FCADPoint *path,size_t path_count,FCADShape**,FCADFailure*);
/* Closed single-wire section profiles only; holes require separate cut features. */
FCADStatus fcad_loft(FCADContext*,const FCADShape *const *profiles,size_t count,int32_t ruled,FCADShape**,FCADFailure*);
/* Row-major affine 4x4; last row must be [0,0,0,1]. */
FCADStatus fcad_transform(FCADContext*,const FCADShape*,const double *matrix16,FCADShape**,FCADFailure*);
FCADStatus fcad_compound(FCADContext*,const FCADShape *const *shapes,size_t count,FCADShape**,FCADFailure*);
FCADStatus fcad_info(FCADContext*,const FCADShape*,FCADShapeInfo*,FCADFailure*);
FCADStatus fcad_face_info(FCADContext*,const FCADShape*,uint32_t index,FCADFaceInfo*,FCADFailure*);
FCADStatus fcad_edge_info(FCADContext*,const FCADShape*,uint32_t index,FCADEdgeInfo*,FCADFailure*);
FCADStatus fcad_clearance(FCADContext*,const FCADShape*,const FCADShape*,double *distance,double *interference_volume,FCADFailure*);
/* Display deflection is mm, angle radians; independent of kernel tolerance.
   Mesh is bounded to 2M triangles / 6M vertices. Normals preserve face boundaries.
   UVs are normalized within each analytic face's parameter bounds. */
FCADStatus fcad_tessellate(FCADContext*,const FCADShape*,double linear_deflection,double angular_deflection,FCADMesh*,FCADFailure*);
FCADStatus fcad_write_brep(FCADContext*,const FCADShape*,const char *path,FCADFailure*);
FCADStatus fcad_read_brep(FCADContext*,const char *path,FCADShape**,FCADFailure*);
FCADStatus fcad_write_step(FCADContext*,const FCADShape*,const char *path,FCADFailure*);
FCADStatus fcad_read_step(FCADContext*,const char *path,FCADShape**,FCADFailure*);
#ifdef __cplusplus
}
#endif
#endif
