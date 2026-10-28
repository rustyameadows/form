#include "form_mesher.h"
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <tuple>
#include <vector>
#include "mapbox/earcut.hpp"
extern "C" int fm_triangulate(const double *xy,size_t point_count,const uint32_t *sizes,size_t ring_count,FMIndexBuffer *result) {
  if (!result) return -1;
  result->indices=nullptr;result->count=0;
  if (!xy || !sizes || point_count<3 || point_count>512 || ring_count<1 || ring_count>16) return -1;
  size_t total=0;
  for(size_t r=0;r<ring_count;++r) {if(sizes[r]<3 || sizes[r]>point_count-total) return -1;total+=sizes[r];}
  if(total!=point_count) return -1;
  for(size_t i=0;i<point_count*2;++i) if(!std::isfinite(xy[i]) || std::abs(xy[i])>100000) return -1;
  try {
    std::vector<std::vector<std::array<double,2>>> polygon;polygon.reserve(ring_count);
    size_t offset=0;
    for(size_t r=0;r<ring_count;++r) {std::vector<std::array<double,2>> ring;ring.reserve(sizes[r]);for(size_t j=0;j<sizes[r];++j,++offset) ring.push_back({xy[2*offset],xy[2*offset+1]});polygon.push_back(std::move(ring));}
    auto triangles=mapbox::earcut<uint32_t>(polygon);
    if(triangles.empty() || triangles.size()%3 || triangles.size()>3*2048) return -2;
    for(auto index:triangles) if(index>=point_count) return -2;
    auto bytes=triangles.size()*sizeof(uint32_t);result->indices=static_cast<uint32_t*>(std::malloc(bytes));if(!result->indices) return -3;
    std::memcpy(result->indices,triangles.data(),bytes);result->count=triangles.size();return 0;
  } catch(...) {return -3;}
}
extern "C" void fm_free_indices(FMIndexBuffer *result) {if(result) {std::free(result->indices);result->indices=nullptr;result->count=0;}}
