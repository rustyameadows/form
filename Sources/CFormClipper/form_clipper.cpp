#include "form_clipper.h"
#include "clipper2/clipper.h"
#include <cstdlib>
#include <cmath>
#include <stdexcept>
using namespace Clipper2Lib;
static Paths64 unpack(const double *coords,const int32_t *counts,int32_t count) {
  if(!coords||!counts||count<1||count>128)throw std::invalid_argument("paths");
  Paths64 paths;size_t at=0,total=0;
  for(int32_t i=0;i<count;i++) {
    if(counts[i]<3||counts[i]>16384||(total+=counts[i])>16384)throw std::invalid_argument("points");
    Path64 p;
    for(int32_t j=0;j<counts[i];j++) {double x=coords[at++],y=coords[at++];
      if(!std::isfinite(x)||!std::isfinite(y)||std::abs(x)>200000||std::abs(y)>200000)throw std::invalid_argument("coordinate");
      p.emplace_back(std::llround(x*1000),std::llround(y*1000));
    }paths.push_back(p);
  }return paths;
}
static FCPaths pack(const Paths64 &result) {
  size_t total=0;for(auto &p:result)total+=p.size();
  if(result.empty()||result.size()>128||total>16384)return FCPaths{nullptr,nullptr,0,2};
  FCPaths out{(double*)std::malloc(total*2*sizeof(double)),(int32_t*)std::malloc(result.size()*sizeof(int32_t)),(int32_t)result.size(),0};
  if(!out.coordinates||!out.counts){fc_free(out);return FCPaths{nullptr,nullptr,0,3};}
  size_t at=0;int32_t index=0;
  for(auto &path:result){out.counts[index++]=(int32_t)path.size();for(auto &p:path){out.coordinates[at++]=p.x/1000.0;out.coordinates[at++]=p.y/1000.0;}}
  return out;
}
extern "C" FCPaths fc_offset(const double *c,const int32_t *n,int32_t count,double delta,double tolerance) {
  try {if(!std::isfinite(delta)||std::abs(delta)>100||tolerance<=0)return FCPaths{nullptr,nullptr,0,1};
    return pack(InflatePaths(unpack(c,n,count),delta*1000,JoinType::Round,EndType::Polygon,2,tolerance*1000));
  }catch(...){return FCPaths{nullptr,nullptr,0,3};}
}
extern "C" FCPaths fc_boolean(const double *c,const int32_t *n,int32_t count,const double *cc,const int32_t *cn,int32_t clip_count,int32_t op) {
  try {return pack(BooleanOp(op==0?ClipType::Difference:ClipType::Intersection,FillRule::NonZero,unpack(c,n,count),unpack(cc,cn,clip_count)));}
  catch(...){return FCPaths{nullptr,nullptr,0,3};}
}
extern "C" void fc_free(FCPaths p){std::free(p.coordinates);std::free(p.counts);}
extern "C" const char *fc_version(void){return CLIPPER2_VERSION;}
