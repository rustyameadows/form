#include "form_mesher.h"
#include <algorithm>
#include <atomic>
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
    q=q-w*(t*s.length);double aspect=s.rz+(s.end_aspect-s.rz)*t;
    double x=dot(q,{s.ux,s.uy,s.uz}),y=dot(q,{s.vx,s.vy,s.vz})/aspect,z=dot(q,w);
    return (std::sqrt(x*x+y*y+z*z)-(s.rx+(s.ry-s.rx)*t))*std::min(1.,aspect);
  }
  V a{dot(q,{s.ux,s.uy,s.uz})/s.rx,dot(q,{s.vx,s.vy,s.vz})/s.ry,dot(q,{s.wx,s.wy,s.wz})/s.rz};
  double k=length(a),k1=length({a.x/s.rx,a.y/s.ry,a.z/s.rz});
  return k1>1e-12 ? k*(k-1)/k1:-std::min({s.rx,s.ry,s.rz});
}
struct Edge {uint32_t a,b;bool operator==(const Edge &e)const{return a==e.a&&b==e.b;}};
struct EdgeHash {size_t operator()(Edge e)const{return (uint64_t(e.a)<<32)^uint64_t(e.b);}};
}
extern "C" void fm_free_organic_mesh(FMOrganicMesh *r){if(r){std::free(r->xyz);std::free(r->indices);*r={};}}
extern "C" int fm_organic_mesh(const FMOrganicShape *shapes,size_t count,double step,int trim_floor,double floor_y,int fill_voids,FMOrganicMesh *r){
  return fm_organic_mesh_cancellable(shapes,count,step,trim_floor,floor_y,fill_voids,nullptr,nullptr,r);
}
extern "C" int fm_organic_mesh_cancellable(const FMOrganicShape *shapes,size_t count,double step,int trim_floor,double floor_y,int fill_voids,FMOrganicCancellationProbe probe,void *probe_context,FMOrganicMesh *r){
  auto cancelled=[&](){return probe&&probe(probe_context);};
  if(!r)return -1;*r={};
  if(!shapes||count<1||count>12000||!std::isfinite(step)||step<.15||step>2||!std::isfinite(floor_y))return -1;
  if(cancelled())return -4;
  try{
    V lo{1e9,1e9,1e9},hi{-1e9,-1e9,-1e9};std::vector<std::pair<V,V>> bounds;
    for(size_t i=0;i<count;i++){
      if((i&127)==0&&cancelled())return -4;
      const auto &s=shapes[i];const double *values=&s.cx;
      for(int k=0;k<18;k++)if(!std::isfinite(values[k])||std::abs(values[k])>1000)return -1;
      if(s.rx<=0||s.ry<=0||s.rz<=0||s.blend<0||s.blend>3||s.kind<0||s.kind>1||(s.kind==1&&(s.length<=0||s.rz<.25||s.rz>1||s.end_aspect<.25||s.end_aspect>1)))return -1;
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
      if((i&127)==0&&cancelled())return -4;
      V a=bounds[i].first-lo,b=bounds[i].second-lo;
      int x0=std::max(0,int(std::floor(a.x/step/bin))),x1=std::min(bx-1,int(std::floor(b.x/step/bin)));
      int y0=std::max(0,int(std::floor(a.y/step/bin))),y1=std::min(by-1,int(std::floor(b.y/step/bin)));
      int z0=std::max(0,int(std::floor(a.z/step/bin))),z1=std::min(bz-1,int(std::floor(b.z/step/bin)));
      for(int z=z0;z<=z1;z++)for(int y=y0;y<=y1;y++)for(int x=x0;x<=x1;x++)bins[(z*by+y)*bx+x].push_back(int(i));
    }
    std::vector<float> field(total,1000.f);
    struct Context {const FMOrganicShape *shapes;const std::vector<std::vector<int>> *bins;float *field;V lo;double step;int nx,ny,bx,by,bin,trim_floor;double floor_y;FMOrganicCancellationProbe probe;void *probe_context;std::atomic<bool> *stopped;};
    std::atomic<bool> stopped{false};
    Context context{shapes,&bins,field.data(),lo,step,nx,ny,bx,by,bin,trim_floor,floor_y,probe,probe_context,&stopped};
    dispatch_apply_f(nz,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&context,[](void *raw,size_t z){
      auto &c=*static_cast<Context*>(raw);
      for(int y=0;y<c.ny;y++)for(int x=0;x<c.nx;x++){
        if((x&255)==0&&(c.stopped->load(std::memory_order_relaxed)||(c.probe&&c.probe(c.probe_context)))){c.stopped->store(true,std::memory_order_relaxed);return;}
        auto &list=(*c.bins)[((int(z)/c.bin)*c.by+y/c.bin)*c.bx+x/c.bin];if(list.empty())continue;
        V p=c.lo+V{double(x),double(y),double(z)}*c.step;double d=1000;
        for(int index:list){auto &s=c.shapes[index];double b=distance(s,p),k=s.blend;
          if(k>0){double h=std::max(k-std::abs(d-b),0.)/k;d=std::min(d,b)-h*h*k*.25;}else d=std::min(d,b);
        }
        if(c.trim_floor)d=std::max(d,c.floor_y-p.y);
        // Keep the sign and topology while avoiding crossings that are closer
        // to a grid corner than float fabrication storage can distinguish.
        if(std::abs(d)<c.step*.001)d=std::copysign(c.step*.001,d==0 ? 1.:d);
        c.field[(z*c.ny+y)*c.nx+x]=float(d);
      }
    });
    if(stopped.load(std::memory_order_relaxed)||cancelled())return -4;
    if(fill_voids){
      // Optional project-owned solidification: retain all exterior air and fill
      // enclosed cavities before meshing. Open cups and through-holes stay open.
      std::vector<uint8_t> exterior(total,0);std::vector<uint32_t> queue;
      auto enqueue=[&](uint32_t id){if(!exterior[id]&&field[id]>0){exterior[id]=1;queue.push_back(id);}};
      for(int z=0;z<nz;z++)for(int y=0;y<ny;y++){enqueue((z*ny+y)*nx);enqueue((z*ny+y)*nx+nx-1);}
      for(int z=0;z<nz;z++)for(int x=0;x<nx;x++){enqueue(z*ny*nx+x);enqueue((z*ny+ny-1)*nx+x);}
      for(int y=0;y<ny;y++)for(int x=0;x<nx;x++){enqueue(y*nx+x);enqueue(((nz-1)*ny+y)*nx+x);}
      for(size_t cursor=0;cursor<queue.size();cursor++){if((cursor&4095)==0&&cancelled())return -4;uint32_t id=queue[cursor];int x=id%nx,y=(id/nx)%ny,z=id/(nx*ny);
        if(x>0)enqueue(id-1);if(x<nx-1)enqueue(id+1);if(y>0)enqueue(id-nx);if(y<ny-1)enqueue(id+nx);if(z>0)enqueue(id-nx*ny);if(z<nz-1)enqueue(id+nx*ny);
      }
      for(size_t i=0;i<total;i++){if((i&4095)==0&&cancelled())return -4;if(field[i]>0&&!exterior[i])field[i]=float(-step*.25);}
    }
    std::vector<V> vertices;std::vector<uint32_t> indices;std::unordered_map<Edge,uint32_t,EdgeHash> crossings;
    auto point=[&](uint32_t id){int x=id%nx,y=(id/nx)%ny,z=id/(nx*ny);return lo+V{double(x),double(y),double(z)}*step;};
    auto vertex=[&](uint32_t a,uint32_t b){if(a>b)std::swap(a,b);
      double t=double(field[a])/(double(field[a])-field[b]);Edge edge{a,b};
      auto found=crossings.find(edge);if(found!=crossings.end())return found->second;
      uint32_t index=uint32_t(vertices.size());vertices.push_back(point(a)+(point(b)-point(a))*t);crossings.emplace(edge,index);return index;};
    auto triangle=[&](uint32_t a,uint32_t b,uint32_t c,V outward){if(a==b||b==c||c==a)return;if(dot(cross(vertices[b]-vertices[a],vertices[c]-vertices[a]),outward)<0)std::swap(b,c);indices.insert(indices.end(),{a,b,c});};
    constexpr int tetra[6][4]={{0,1,3,7},{0,3,2,7},{0,2,6,7},{0,6,4,7},{0,4,5,7},{0,5,1,7}};
    for(int z=0;z<nz-1;z++)for(int y=0;y<ny-1;y++)for(int x=0;x<nx-1;x++){
      if((x&511)==0&&cancelled())return -4;
      uint32_t base=(z*ny+y)*nx+x,ids[8]={base,base+1,base+uint32_t(nx),base+uint32_t(nx)+1,base+uint32_t(nx*ny),base+uint32_t(nx*ny)+1,base+uint32_t(nx*ny+nx),base+uint32_t(nx*ny+nx)+1};
      bool neg=false,pos=false;for(auto id:ids){neg|=field[id]<0;pos|=field[id]>0;}if(!neg||!pos)continue;
      for(auto &t:tetra){uint32_t in[4],out[4];int ni=0,no=0;V ic{0,0,0},oc{0,0,0};
        for(int k:t){uint32_t id=ids[k];if(field[id]<0){in[ni++]=id;ic=ic+point(id);}else{out[no++]=id;oc=oc+point(id);}}
        if(!ni||!no)continue;V direction=oc*(1./no)-ic*(1./ni);
        if(ni==1)triangle(vertex(in[0],out[0]),vertex(in[0],out[1]),vertex(in[0],out[2]),direction);
        else if(no==1)triangle(vertex(out[0],in[0]),vertex(out[0],in[1]),vertex(out[0],in[2]),direction);
        else{uint32_t a=vertex(in[0],out[0]),b=vertex(in[0],out[1]),c=vertex(in[1],out[1]),d=vertex(in[1],out[0]);triangle(a,b,c,direction);triangle(a,c,d,direction);}
      }
      if(indices.size()>12000000)return -2;
    }
    if(indices.empty())return -2;
    // Tetrahedral sampling can create arbitrarily short edges near a grid
    // corner. Collapse only topologically legal surface edges. This preserves
    // closed fans while removing slivers that disappear in float STL storage.
    std::vector<uint32_t> parent(vertices.size());
    std::vector<std::vector<uint32_t>> neighbors(vertices.size());
    std::vector<std::vector<size_t>> faces(vertices.size());
    for(size_t i=0;i<parent.size();i++)parent[i]=uint32_t(i);
    for(size_t i=0;i<indices.size();i+=3)for(int j=0;j<3;j++){
      uint32_t a=indices[i+j],b=indices[i+(j+1)%3];neighbors[a].push_back(b);neighbors[b].push_back(a);faces[a].push_back(i);
    }
    auto root=[&](uint32_t n){while(parent[n]!=n){parent[n]=parent[parent[n]];n=parent[n];}return n;};
    auto ring=[&](uint32_t n){std::vector<uint32_t> result;for(auto v:neighbors[n]){v=root(v);if(v!=n)result.push_back(v);}std::sort(result.begin(),result.end());result.erase(std::unique(result.begin(),result.end()),result.end());return result;};
    const double threshold=step*.34;
    for(size_t i=0;i<indices.size();i+=3)for(int j=0;j<3;j++){
      if((i%12288)==0&&cancelled())return -4;
      uint32_t a=root(indices[i+j]),b=root(indices[i+(j+1)%3]);if(a==b||length(vertices[a]-vertices[b])>=threshold)continue;
      auto ar=ring(a),br=ring(b);std::vector<uint32_t> common;for(auto n:ar)if(std::binary_search(br.begin(),br.end(),n))common.push_back(n);
      if(common.size()!=2)continue;
      auto opposite=ring(common[0]);if(std::binary_search(opposite.begin(),opposite.end(),common[1]))continue;
      V midpoint=(vertices[a]+vertices[b])*.5;
      // Preserve a planar trim exactly, including its boundary contour.
      if(trim_floor&&(std::abs(vertices[a].y-floor_y)<1e-7||std::abs(vertices[b].y-floor_y)<1e-7))midpoint.y=floor_y;
      bool flips=false;
      auto preserves=[&](size_t offset){uint32_t ids[3]={root(indices[offset]),root(indices[offset+1]),root(indices[offset+2])};
        if(ids[0]==ids[1]||ids[1]==ids[2]||ids[2]==ids[0])return true;
        int shared=0;for(auto id:ids)shared+=(id==a||id==b);if(shared==2)return true;
        V old[3]={vertices[ids[0]],vertices[ids[1]],vertices[ids[2]]},next[3];
        for(int k=0;k<3;k++)next[k]=(ids[k]==a||ids[k]==b)?midpoint:old[k];
        V n=cross(old[1]-old[0],old[2]-old[0]),m=cross(next[1]-next[0],next[2]-next[0]);return dot(n,m)>0&&dot(m,m)>1e-24;
      };
      for(auto face:faces[a])if(!preserves(face)){flips=true;break;}
      if(!flips)for(auto face:faces[b])if(!preserves(face)){flips=true;break;}
      if(flips)continue;
      parent[b]=a;vertices[a]=midpoint;neighbors[a].insert(neighbors[a].end(),neighbors[b].begin(),neighbors[b].end());
      faces[a].insert(faces[a].end(),faces[b].begin(),faces[b].end());
    }
    std::vector<uint32_t> compact(vertices.size(),UINT32_MAX),cleaned;
    std::vector<V> positions;cleaned.reserve(indices.size());
    for(size_t i=0;i<indices.size();i+=3){if((i%12288)==0&&cancelled())return -4;uint32_t a=root(indices[i]),b=root(indices[i+1]),c=root(indices[i+2]);if(a==b||b==c||c==a)continue;
      for(auto n:{a,b,c}){if(compact[n]==UINT32_MAX){compact[n]=uint32_t(positions.size());positions.push_back(vertices[n]);}cleaned.push_back(compact[n]);}
    }
    vertices=std::move(positions);indices=std::move(cleaned);
    if(cancelled())return -4;
    if(indices.size()>6000000)return -2;
    r->xyz=static_cast<double*>(std::malloc(vertices.size()*3*sizeof(double)));r->indices=static_cast<uint32_t*>(std::malloc(indices.size()*sizeof(uint32_t)));
    if(!r->xyz||!r->indices){fm_free_organic_mesh(r);return -3;}
    for(size_t i=0;i<vertices.size();i++){r->xyz[i*3]=vertices[i].x;r->xyz[i*3+1]=vertices[i].y;r->xyz[i*3+2]=vertices[i].z;}
    std::memcpy(r->indices,indices.data(),indices.size()*sizeof(uint32_t));r->vertex_count=vertices.size();r->index_count=indices.size();return 0;
  }catch(...){fm_free_organic_mesh(r);return -3;}
}
