#include "form_mesher.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <vector>
#include <dispatch/dispatch.h>

namespace {
struct V {
  double x,y,z;
  V operator+(V b)const{return{x+b.x,y+b.y,z+b.z};}
  V operator-(V b)const{return{x-b.x,y-b.y,z-b.z};}
  V operator*(double s)const{return{x*s,y*s,z*s};}
};
double dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
V cross(V a,V b){return{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
double length(V a){return std::sqrt(dot(a,a));}
double distance(const FMOrganicShape &s,V p){
  V q=p-V{s.cx,s.cy,s.cz};
  if(s.kind==1){
    V w{s.wx,s.wy,s.wz};double t=std::clamp(dot(q,w)/s.length,0.,1.);
    return length(q-w*(t*s.length))-(s.rx+(s.ry-s.rx)*t);
  }
  V a{dot(q,{s.ux,s.uy,s.uz})/s.rx,dot(q,{s.vx,s.vy,s.vz})/s.ry,dot(q,{s.wx,s.wy,s.wz})/s.rz};
  double k=length(a),k1=length({a.x/s.rx,a.y/s.ry,a.z/s.rz});
  return k1>1e-12 ? k*(k-1)/k1:-std::min({s.rx,s.ry,s.rz});
}
struct Edge {uint32_t a,b;bool operator==(const Edge &e)const{return a==e.a&&b==e.b;}};
struct EdgeHash {size_t operator()(Edge e)const{return (uint64_t(e.a)<<32)^uint64_t(e.b);}};
}
extern "C" void fm_free_organic_mesh(FMOrganicMesh *r){if(r){std::free(r->xyz);std::free(r->indices);*r={};}}
extern "C" int fm_organic_mesh(const FMOrganicShape *shapes,size_t count,double step,int trim_floor,double floor_y,FMOrganicMesh *r){
  if(!r)return -1;*r={};
  if(!shapes||count<1||count>12000||!std::isfinite(step)||step<.15||step>2||!std::isfinite(floor_y))return -1;
  try{
    V lo{1e9,1e9,1e9},hi{-1e9,-1e9,-1e9};std::vector<std::pair<V,V>> bounds;
    for(size_t i=0;i<count;i++){
      const auto &s=shapes[i];const double *values=&s.cx;
      for(int k=0;k<17;k++)if(!std::isfinite(values[k])||std::abs(values[k])>1000)return -1;
      if(s.rx<=0||s.ry<=0||s.rz<=0||s.blend<0||s.blend>3||s.kind<0||s.kind>1||(s.kind==1&&s.length<=0))return -1;
      V c{s.cx,s.cy,s.cz},e;
      if(s.kind==1){double radius=std::max(s.rx,s.ry)+s.blend+step*2;V end=c+V{s.wx,s.wy,s.wz}*s.length;
        V a{std::min(c.x,end.x)-radius,std::min(c.y,end.y)-radius,std::min(c.z,end.z)-radius};
        V b{std::max(c.x,end.x)+radius,std::max(c.y,end.y)+radius,std::max(c.z,end.z)+radius};bounds.push_back({a,b});
      }else{
        e={std::abs(s.ux)*s.rx+std::abs(s.vx)*s.ry+std::abs(s.wx)*s.rz,std::abs(s.uy)*s.rx+std::abs(s.vy)*s.ry+std::abs(s.wy)*s.rz,std::abs(s.uz)*s.rx+std::abs(s.vz)*s.ry+std::abs(s.wz)*s.rz};
        e=e+V{1,1,1}*(s.blend+step*2);bounds.push_back({c-e,c+e});
      }
      auto b=bounds.back();lo={std::min(lo.x,b.first.x),std::min(lo.y,b.first.y),std::min(lo.z,b.first.z)};hi={std::max(hi.x,b.second.x),std::max(hi.y,b.second.y),std::max(hi.z,b.second.z)};
    }
    if(trim_floor){lo.y=floor_y-step*1.37;if(hi.y<=floor_y)return -2;}
    int nx=int(std::ceil((hi.x-lo.x)/step))+1,ny=int(std::ceil((hi.y-lo.y)/step))+1,nz=int(std::ceil((hi.z-lo.z)/step))+1;
    uint64_t total=uint64_t(nx)*ny*nz;if(nx<2||ny<2||nz<2||total>80000000)return -2;
    const int bin=8,bx=(nx+bin-1)/bin,by=(ny+bin-1)/bin,bz=(nz+bin-1)/bin;
    std::vector<std::vector<int>> bins(bx*by*bz);
    for(size_t i=0;i<count;i++){
      V a=bounds[i].first-lo,b=bounds[i].second-lo;
      int x0=std::max(0,int(std::floor(a.x/step/bin))),x1=std::min(bx-1,int(std::floor(b.x/step/bin)));
      int y0=std::max(0,int(std::floor(a.y/step/bin))),y1=std::min(by-1,int(std::floor(b.y/step/bin)));
      int z0=std::max(0,int(std::floor(a.z/step/bin))),z1=std::min(bz-1,int(std::floor(b.z/step/bin)));
      for(int z=z0;z<=z1;z++)for(int y=y0;y<=y1;y++)for(int x=x0;x<=x1;x++)bins[(z*by+y)*bx+x].push_back(int(i));
    }
    std::vector<float> field(total,1000.f);
    struct Context {const FMOrganicShape *shapes;const std::vector<std::vector<int>> *bins;float *field;V lo;double step;int nx,ny,bx,by,bin,trim_floor;double floor_y;};
    Context context{shapes,&bins,field.data(),lo,step,nx,ny,bx,by,bin,trim_floor,floor_y};
    dispatch_apply_f(nz,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&context,[](void *raw,size_t z){
      auto &c=*static_cast<Context*>(raw);
      for(int y=0;y<c.ny;y++)for(int x=0;x<c.nx;x++){
        auto &list=(*c.bins)[((int(z)/c.bin)*c.by+y/c.bin)*c.bx+x/c.bin];if(list.empty())continue;
        V p=c.lo+V{double(x),double(y),double(z)}*c.step;double d=1000;
        for(int index:list){auto &s=c.shapes[index];double b=distance(s,p),k=s.blend;
          if(k>0){double h=std::max(k-std::abs(d-b),0.)/k;d=std::min(d,b)-h*h*k*.25;}else d=std::min(d,b);
        }
        if(c.trim_floor)d=std::max(d,c.floor_y-p.y);if(std::abs(d)<1e-8)d=1e-8;
        c.field[(z*c.ny+y)*c.nx+x]=float(d);
      }
    });
    std::vector<V> vertices;std::vector<uint32_t> indices;std::unordered_map<Edge,uint32_t,EdgeHash> crossings;
    auto point=[&](uint32_t id){int x=id%nx,y=(id/nx)%ny,z=id/(nx*ny);return lo+V{double(x),double(y),double(z)}*step;};
    auto vertex=[&](uint32_t a,uint32_t b){if(a>b)std::swap(a,b);Edge edge{a,b};auto found=crossings.find(edge);if(found!=crossings.end())return found->second;
      double t=double(field[a])/(double(field[a])-field[b]);uint32_t index=uint32_t(vertices.size());vertices.push_back(point(a)+(point(b)-point(a))*t);crossings.emplace(edge,index);return index;};
    auto triangle=[&](uint32_t a,uint32_t b,uint32_t c,V outward){if(dot(cross(vertices[b]-vertices[a],vertices[c]-vertices[a]),outward)<0)std::swap(b,c);indices.insert(indices.end(),{a,b,c});};
    constexpr int tetra[6][4]={{0,1,3,7},{0,3,2,7},{0,2,6,7},{0,6,4,7},{0,4,5,7},{0,5,1,7}};
    for(int z=0;z<nz-1;z++)for(int y=0;y<ny-1;y++)for(int x=0;x<nx-1;x++){
      uint32_t base=(z*ny+y)*nx+x,ids[8]={base,base+1,base+uint32_t(nx),base+uint32_t(nx)+1,base+uint32_t(nx*ny),base+uint32_t(nx*ny)+1,base+uint32_t(nx*ny+nx),base+uint32_t(nx*ny+nx)+1};
      bool neg=false,pos=false;for(auto id:ids){neg|=field[id]<0;pos|=field[id]>0;}if(!neg||!pos)continue;
      for(auto &t:tetra){uint32_t in[4],out[4];int ni=0,no=0;V ic{0,0,0},oc{0,0,0};
        for(int k:t){uint32_t id=ids[k];if(field[id]<0){in[ni++]=id;ic=ic+point(id);}else{out[no++]=id;oc=oc+point(id);}}
        if(!ni||!no)continue;V direction=oc*(1./no)-ic*(1./ni);
        if(ni==1)triangle(vertex(in[0],out[0]),vertex(in[0],out[1]),vertex(in[0],out[2]),direction);
        else if(no==1)triangle(vertex(out[0],in[0]),vertex(out[0],in[1]),vertex(out[0],in[2]),direction);
        else{uint32_t a=vertex(in[0],out[0]),b=vertex(in[0],out[1]),c=vertex(in[1],out[1]),d=vertex(in[1],out[0]);triangle(a,b,c,direction);triangle(a,c,d,direction);}
      }
      if(indices.size()>6000000)return -2;
    }
    if(indices.empty())return -2;
    r->xyz=static_cast<double*>(std::malloc(vertices.size()*3*sizeof(double)));r->indices=static_cast<uint32_t*>(std::malloc(indices.size()*sizeof(uint32_t)));
    if(!r->xyz||!r->indices){fm_free_organic_mesh(r);return -3;}
    for(size_t i=0;i<vertices.size();i++){r->xyz[i*3]=vertices[i].x;r->xyz[i*3+1]=vertices[i].y;r->xyz[i*3+2]=vertices[i].z;}
    std::memcpy(r->indices,indices.data(),indices.size()*sizeof(uint32_t));r->vertex_count=vertices.size();r->index_count=indices.size();return 0;
  }catch(...){fm_free_organic_mesh(r);return -3;}
}
