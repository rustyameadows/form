// LAB private Cycles service. Upstream renderer types never cross the process boundary.
#import <Foundation/Foundation.h>
#include <OpenImageIO/imageio.h>
#include <OpenImageDenoise/config.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <unistd.h>
#include "device/device.h"
#include "integrator/path_trace.h"
#include "scene/background.h"
#include "scene/camera.h"
#include "scene/film.h"
#include "scene/hair.h"
#include "scene/integrator.h"
#include "scene/light.h"
#include "scene/mesh.h"
#include "scene/object.h"
#include "scene/pass.h"
#include "scene/scene.h"
#include "scene/shader.h"
#include "scene/shader_graph.h"
#include "scene/shader_nodes.h"
#include "session/display_driver.h"
#include "session/output_driver.h"
#include "session/session.h"
#include "util/colorspace.h"
#include "util/half.h"
#include "util/log.h"
#include "util/path.h"

using namespace ccl;
namespace fs = std::filesystem;
static volatile sig_atomic_t interrupted = 0;
static void signal_handler(int) { interrupted = 1; }
static FILE *event_file = nullptr;
static std::mutex event_mutex;
static NSString *job_id = @"";
static NSString *revision = @"";
static NSString *backend = @"";
static NSString *fallback_reason = @"";
static NSString *error_category = @"";
static fs::path job_root;
static fs::path output_root;
static double exposure = 0;
static std::atomic<bool> final_written{false};
static std::atomic<int> current_sample{0};
static std::function<int()> actual_sample_count;
static int requested_samples=0;
static std::string output_error;

static std::string str(NSString *s) { return s ? std::string(s.UTF8String) : std::string(); }
static NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }
static id value(NSDictionary *d, NSString *key) { id v=d[key]; return v == [NSNull null] ? nil : v; }
static double number(NSDictionary *d, NSString *key, double fallback=0) {
  id v=value(d,key); if (!v) return fallback;
  if (![v isKindOfClass:NSNumber.class] || !std::isfinite([v doubleValue]))
    throw std::runtime_error("Invalid numeric field: "+str(key));
  return [v doubleValue];
}
static double bounded(NSDictionary *d, NSString *key, double fallback, double lo, double hi) {
  double v=number(d,key,fallback);
  if (v<lo || v>hi) throw std::runtime_error("Out of range: "+str(key));
  return v;
}
static NSString *string_value(NSDictionary *d, NSString *key, NSString *fallback=@"") {
  id v=value(d,key); if (!v) return fallback;
  if (![v isKindOfClass:NSString.class]) throw std::runtime_error("Invalid string: "+str(key));
  return v;
}
static NSArray *json_list(NSDictionary *d, NSString *key) {
  id v=value(d,key); if (!v) return @[];
  if (![v isKindOfClass:NSArray.class]) throw std::runtime_error("Invalid array: "+str(key));
  return v;
}
static float component(NSArray *a, NSUInteger i, float fallback) {
  if (i>=a.count) return fallback;
  if (![a[i] isKindOfClass:NSNumber.class] || !std::isfinite([a[i] doubleValue]))
    throw std::runtime_error("Invalid vector component");
  return [a[i] floatValue];
}
static float3 color(NSDictionary *d, NSString *key, float3 fallback=make_float3(1,1,1)) {
  NSArray *a=json_list(d,key);
  return make_float3(component(a,0,fallback.x),component(a,1,fallback.y),component(a,2,fallback.z));
}
static void event(NSString *type, NSDictionary *extra=@{}) {
  @autoreleasepool {
    NSMutableDictionary *d=[@{@"type":type,@"jobID":job_id,@"sourceRevision":revision,
      @"device":backend,@"engineVersion":@LAB_CYCLES_COMMIT} mutableCopy];
    [d addEntriesFromDictionary:extra];
    if(fallback_reason.length)d[@"fallbackReason"]=fallback_reason;
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];
    std::lock_guard<std::mutex> lock(event_mutex);
    fwrite(bytes.bytes,1,bytes.length,event_file); fputc('\n',event_file); fflush(event_file);
  }
}
static void engine_log(LogLevel level,const char *,const char *function,const char *message) {
  // Pinned Cycles has no Session denoising progress callback. Its public log
  // callback reports this exact entry before real OIDN work, including previews.
  if(std::string(function)=="denoise" && std::string(message)=="Perform denoising work.") {
    if(actual_sample_count)current_sample=actual_sample_count();
    @autoreleasepool {event(@"progress",@{@"phase":@"denoising",@"status":@"Denoising",
      @"sample":@(current_sample.load()),@"totalSamples":@(requested_samples),@"progress":@(requested_samples>0 ? double(current_sample.load())/requested_samples:0)});}
  } else if(level<=LOG_LEVEL_INFO_IMPORTANT) {
    fprintf(stderr,"%s: %s\n",log_level_to_string(level),message);fflush(stderr);
  }
}
static fs::path resource_path(NSString *name) {
  fs::path p(str(name)); if (p.is_relative()) p=job_root/p;
  p=fs::weakly_canonical(p);
  auto rel=p.lexically_relative(job_root);
  if (rel.empty() || *rel.begin()=="..") throw std::runtime_error("Resource outside render job");
  return p;
}
template<typename T> static std::vector<T> binary(NSDictionary *desc, size_t dimensions, size_t maximum=20000000) {
  if (![desc isKindOfClass:NSDictionary.class]) throw std::runtime_error("Missing binary array descriptor");
  const size_t count=bounded(desc,@"count",0,0,maximum);
  auto path=resource_path(string_value(desc,@"path"));
  if (fs::file_size(path)!=count*dimensions*sizeof(T)) throw std::runtime_error("Binary array size mismatch: "+path.string());
  std::vector<T> out(count*dimensions);
  std::ifstream file(path,std::ios::binary);
  file.read(reinterpret_cast<char*>(out.data()),out.size()*sizeof(T));
  if (!file && !out.empty()) throw std::runtime_error("Failed to read array");
  if constexpr(std::is_floating_point_v<T>) for (T x:out) if (!std::isfinite(x)) throw std::runtime_error("Nonfinite geometry value");
  return out;
}
static Transform matrix(NSDictionary *d, NSString *key=@"transform") {
  NSArray *m=json_list(d,key); if (m.count==0) return transform_identity();
  if (m.count!=16) throw std::runtime_error("Transform must have 16 column-major elements");
  Transform t;
  t.x=make_float4(component(m,0,0),component(m,4,0),component(m,8,0),component(m,12,0)*.001f);
  t.y=make_float4(component(m,1,0),component(m,5,0),component(m,9,0),component(m,13,0)*.001f);
  t.z=make_float4(component(m,2,0),component(m,6,0),component(m,10,0),component(m,14,0)*.001f);
  return t;
}
static void write_image(const fs::path &path, int w, int h, const float *rgba, bool png) {
  fs::path temporary=path.parent_path()/(path.stem().string()+".partial"+path.extension().string());
  auto writer=OIIO::ImageOutput::create(temporary.string());
  if (!writer) throw std::runtime_error("Image output unavailable: "+OIIO::geterror());
  OIIO::ImageSpec spec(w,h,4,png ? OIIO::TypeDesc::UINT8 : OIIO::TypeDesc::FLOAT);
  spec.attribute("oiio:ColorSpace",png ? "sRGB" : "Linear");
  // PNG values below are already straight-alpha. Without this flag OIIO
  // deassociates them a second time, brightening semitransparent pixels.
  if(png)spec.attribute("oiio:UnassociatedAlpha",1);
  spec.attribute("Software","LAB / Cycles " LAB_CYCLES_COMMIT);
  if (!writer->open(temporary.string(),spec)) throw std::runtime_error(writer->geterror());
  bool ok=false;
  if (png) {
    std::vector<unsigned char> encoded(w*h*4);
    for(size_t i=0;i<size_t(w)*h;i++) {
      float a=std::clamp(rgba[i*4+3],0.f,1.f);
      for(int c=0;c<3;c++) {
        float v=std::max(0.f,rgba[i*4+c])*(a>1e-6f ? 1.f/a : 0.f)*std::exp2(exposure);
        v=v<=0.0031308f ? v*12.92f : 1.055f*std::pow(v,1.f/2.4f)-.055f;
        encoded[i*4+c]=static_cast<unsigned char>(std::clamp(v,0.f,1.f)*255.f+.5f);
      }
      encoded[i*4+3]=static_cast<unsigned char>(a*255.f+.5f);
    }
    ok=writer->write_image(OIIO::TypeDesc::UINT8,encoded.data());
  } else ok=writer->write_image(OIIO::TypeDesc::FLOAT,rgba);
  bool closed=writer->close();
  if(!ok || !closed) throw std::runtime_error("Failed writing render image: "+writer->geterror());
  fs::rename(temporary,path);
}

class LabDisplay final:public DisplayDriver {
  Progress *progress;
  std::vector<half4> pixels;
  int width=0,height=0;
  std::chrono::steady_clock::time_point last{};
 public:
  explicit LabDisplay(Progress *p):progress(p) {}
  bool update_begin(const Params &,int w,int h) override {
    if (interrupted) return false;
    width=w;height=h;pixels.resize(size_t(w)*h);return true;
  }
  half4 *map_texture_buffer() override { return pixels.data(); }
  void unmap_texture_buffer() override {}
  void update_end() override {
    auto now=std::chrono::steady_clock::now();
    if(now-last<std::chrono::milliseconds(250)) return;
    last=now;
    @autoreleasepool { try {
      std::vector<float> rgba(size_t(width)*height*4);
      for(int y=0;y<height;y++) for(int x=0;x<width;x++) {
        float4 p=half4_to_float4(pixels[size_t(height-1-y)*width+x]);
        size_t i=(size_t(y)*width+x)*4;
        rgba[i]=p.x;rgba[i+1]=p.y;rgba[i+2]=p.z;rgba[i+3]=p.w;
      }
      auto path=output_root/"preview.png";
      write_image(path,width,height,rgba.data(),true);
      const int samples=actual_sample_count ? actual_sample_count():progress->get_current_sample();
      current_sample=samples;
      event(@"frame",@{@"framePath":ns(path.string()),@"width":@(width),@"height":@(height),
        @"sample":@(samples),@"totalSamples":@(requested_samples)});
    } catch(const std::exception &e) { event(@"warning",@{@"message":ns(e.what())}); } }
  }
  void next_tile_begin() override {}
  void zero() override { std::fill(pixels.begin(),pixels.end(),half4{}); }
  void draw(const Params &) override {}
};
// Expose upstream's actual device and stage timing report without changing Cycles.
class LabSession final:public Session {
 public:
  using Session::Session;
  std::string engine_report() const {return path_trace_->full_report();}
  void enable_progressive_updates() {render_scheduler_.set_limit_samples_per_update(32);}
  int rendered_samples() const {return render_scheduler_.get_total_rendered_samples();}
};
static void add_stage_time(NSMutableDictionary *result,const std::string &report,
                           const std::string &label,NSString *key) {
  std::istringstream lines(report);std::string line;
  while(std::getline(lines,line)) {
    auto first=line.find_first_not_of(' ');
    if(first==std::string::npos || line.compare(first,label.size(),label)!=0)continue;
    std::istringstream numbers(line.substr(first+label.size()));double seconds;
    if(numbers>>seconds && std::isfinite(seconds) && seconds>=0)result[key]=@(seconds);
  }
}
class LabOutput final:public OutputDriver {
 public:
  void write_render_tile(const Tile &tile) override {
    if (!(tile.size==tile.full_size)) { output_error="Unexpected partial final tile";return; }
    @autoreleasepool { try {
      int w=tile.size.x,h=tile.size.y;
      std::vector<float> pixels(size_t(w)*h*4),top(pixels.size());
      if(!tile.get_pass_pixels("combined",4,pixels.data())) throw std::runtime_error("Combined render pass unavailable");
      for(int y=0;y<h;y++) std::copy_n(pixels.data()+size_t(h-1-y)*w*4,w*4,top.data()+size_t(y)*w*4);
      write_image(output_root/"final.exr",w,h,top.data(),false);
      write_image(output_root/"final.png",w,h,top.data(),true);
      final_written=true;
    } catch(const std::exception &e) {output_error=e.what();} }
  }
};

static fs::path texture_path(NSDictionary *description) {
  auto source=resource_path(string_value(description,@"path"));
  if(![string_value(description,@"format") isEqualToString:@"rgba32f"])return source;
  int width=bounded(description,@"width",0,1,8192),height=bounded(description,@"height",0,1,8192);
  if(size_t(width)*height>16777216 || fs::file_size(source)!=size_t(width)*height*16)
    throw std::runtime_error("Invalid floating point texture dimensions");
  fs::path converted=source.string()+".exr";
  if(!fs::exists(converted)) {
    std::vector<float> pixels(size_t(width)*height*4);
    std::ifstream file(source,std::ios::binary);file.read(reinterpret_cast<char*>(pixels.data()),pixels.size()*4);
    if(!file)throw std::runtime_error("Failed reading HDR texture");
    for(float x:pixels)if(!std::isfinite(x))throw std::runtime_error("Nonfinite HDR texture value");
    // Wire textures are straight RGBA. EXR does not retain OIIO's transient
    // alpha hint, so their nodes explicitly declare unassociated alpha below.
    // Final render EXRs use the separate premultiplied Combined pass unchanged.
    write_image(converted,width,height,pixels.data(),false);
  }
  return converted;
}
static ShaderOutput *math_output(ShaderGraph *graph,ShaderOutput *a,NodeMathType op,float b) {
  auto node=graph->create_node<MathNode>();node->set_math_type(op);node->set_value2(b);
  graph->connect(a,node->input("Value1"));return node->output("Value");
}
static ShaderOutput *binary_math(ShaderGraph *graph,ShaderOutput *a,NodeMathType op,ShaderOutput *b) {
  auto node=graph->create_node<MathNode>();node->set_math_type(op);
  graph->connect(a,node->input("Value1"));graph->connect(b,node->input("Value2"));return node->output("Value");
}
static ShaderOutput *vector_math(ShaderGraph *graph,ShaderOutput *a,NodeVectorMathType op,
                                 ShaderOutput *b=nullptr,float3 constant=zero_float3()) {
  auto node=graph->create_node<VectorMathNode>();node->set_math_type(op);node->set_vector2(constant);
  graph->connect(a,node->input("Vector1"));if(b)graph->connect(b,node->input("Vector2"));
  return node->output(op==NODE_VECTOR_MATH_DOT_PRODUCT?"Value":"Vector");
}
static ShaderOutput *vector_scale(ShaderGraph *graph,ShaderOutput *a,ShaderOutput *scale) {
  auto node=graph->create_node<VectorMathNode>();node->set_math_type(NODE_VECTOR_MATH_SCALE);
  graph->connect(a,node->input("Vector1"));graph->connect(scale,node->input("Scale"));return node->output("Vector");
}
static ShaderOutput *curve_uv(ShaderGraph *graph,ShaderOutput *uv) {
  // Cycles' built-in Hair UV is constant per strand. Named per-key UV attributes
  // provide longitudinal millimeters; a transported frame supplies the missing
  // circumferential coordinate without using view-dependent hair normals.
  auto geometry=graph->create_node<GeometryNode>();
  auto local_normal=graph->create_node<VectorTransformNode>();
  local_normal->set_transform_type(NODE_VECTOR_TRANSFORM_TYPE_NORMAL);
  local_normal->set_convert_from(NODE_VECTOR_TRANSFORM_CONVERT_SPACE_WORLD);
  local_normal->set_convert_to(NODE_VECTOR_TRANSFORM_CONVERT_SPACE_OBJECT);
  graph->connect(geometry->output("Normal"),local_normal->input("Vector"));
  auto frame_n=graph->create_node<AttributeNode>();frame_n->set_attribute(ustring("LABCurveFrameN"));
  auto frame_b=graph->create_node<AttributeNode>();frame_b->set_attribute(ustring("LABCurveFrameB"));
  auto circumference=graph->create_node<AttributeNode>();circumference->set_attribute(ustring("LABCurveCircumferenceMM"));
  auto x=vector_math(graph,local_normal->output("Vector"),NODE_VECTOR_MATH_DOT_PRODUCT,frame_n->output("Vector"));
  auto y=vector_math(graph,local_normal->output("Vector"),NODE_VECTOR_MATH_DOT_PRODUCT,frame_b->output("Vector"));
  auto turns=math_output(graph,math_output(graph,binary_math(graph,y,NODE_MATH_ARCTAN2,x),NODE_MATH_MULTIPLY,1/(2*M_PI)),NODE_MATH_FRACTION,0);
  auto distance=binary_math(graph,turns,NODE_MATH_MULTIPLY,circumference->output("Fac"));
  auto strand=graph->create_node<HairInfoNode>();distance=binary_math(graph,distance,NODE_MATH_MULTIPLY,strand->output("Is Strand"));
  auto separate=graph->create_node<SeparateXYZNode>();graph->connect(uv,separate->input("Vector"));
  auto combine=graph->create_node<CombineXYZNode>();graph->connect(separate->output("X"),combine->input("X"));
  graph->connect(binary_math(graph,separate->output("Y"),NODE_MATH_ADD,distance),combine->input("Y"));
  return combine->output("Vector");
}
static ustring texture_colorspace(NSDictionary *description) {
  NSString *cs=string_value(description,@"colorSpace",@"linear");
  // These identities bypass external OCIO configuration entirely. A display
  // name such as "sRGB" is not a built-in and otherwise falls back to linear.
  if([cs caseInsensitiveCompare:@"sRGB"]==NSOrderedSame)return u_colorspace_srgb;
  if([cs isEqualToString:@"linear"])return u_colorspace_scene_linear;
  if([cs isEqualToString:@"data"])return u_colorspace_data;
  throw std::runtime_error("Unknown texture color space; use srgb, linear or data");
}
static ImageTextureNode *texture(ShaderGraph *graph, NSDictionary *description,bool curve_shader=false) {
  auto node=graph->create_node<ImageTextureNode>();
  node->set_filename(ustring(texture_path(description).string()));
  node->set_colorspace(texture_colorspace(description));
  if([string_value(description,@"format") isEqualToString:@"rgba32f"])node->set_alpha_type(IMAGE_ALPHA_UNASSOCIATED);
  int uv_index=bounded(description,@"uvIndex",0,0,1);
  auto uv=graph->create_node<UVMapNode>();uv->set_attribute(ustring(uv_index==0?"UVMap":"UVMap1"));
  NSArray *scale=json_list(description,@"scale"),*offset=json_list(description,@"offset");
  auto mapping=graph->create_node<MappingNode>();
  mapping->set_scale(make_float3(component(scale,0,1),component(scale,1,1),1));
  mapping->set_location(make_float3(component(offset,0,0),component(offset,1,0),0));
  mapping->set_rotation(make_float3(0,0,number(description,@"rotationDegrees")*M_PI/180));
  graph->connect(curve_shader?curve_uv(graph,uv->output("UV")):uv->output("UV"),mapping->input("Vector"));
  auto separate=graph->create_node<SeparateXYZNode>();graph->connect(mapping->output("Vector"),separate->input("Vector"));
  ShaderOutput *u=separate->output("X"),*v=separate->output("Y");
  NSString *wrap_s=string_value(description,@"wrapS",@"repeat"),*wrap_t=string_value(description,@"wrapT",@"repeat");
  auto wrap=[&](ShaderOutput *p,NSString *mode) {
    if([mode isEqualToString:@"repeat"])return math_output(graph,p,NODE_MATH_FRACTION,0);
    if([mode isEqualToString:@"mirror"])return math_output(graph,p,NODE_MATH_PINGPONG,1);
    return math_output(graph,math_output(graph,p,NODE_MATH_MAXIMUM,0),NODE_MATH_MINIMUM,1);
  };
  if([wrap_s isEqualToString:wrap_t])node->set_extension([wrap_s isEqualToString:@"clamp"]?EXTENSION_EXTEND:[wrap_s isEqualToString:@"mirror"]?EXTENSION_MIRROR:EXTENSION_REPEAT);
  else {u=wrap(u,wrap_s);v=wrap(v,wrap_t);node->set_extension(EXTENSION_EXTEND);}
  // LAB's portable UV origin is top-left. Flip after its affine UV mapping.
  v=math_output(graph,math_output(graph,v,NODE_MATH_MULTIPLY,-1),NODE_MATH_ADD,1);
  auto combine=graph->create_node<CombineXYZNode>();
  graph->connect(u,combine->input("X"));graph->connect(v,combine->input("Y"));
  graph->connect(combine->output("Vector"),node->input("Vector"));
  return node;
}
static ShaderOutput *texture_output(ShaderGraph *graph,ImageTextureNode *texture,NSDictionary *desc) {
  NSString *channel=string_value(desc,@"channel",@"rgba");
  if([channel isEqualToString:@"alpha"])return texture->output("Alpha");
  if([channel isEqualToString:@"rgba"])return texture->output("Color");
  auto separate=graph->create_node<SeparateColorNode>();graph->connect(texture->output("Color"),separate->input("Color"));
  return separate->output([channel isEqualToString:@"red"]?"Red":[channel isEqualToString:@"green"]?"Green":"Blue");
}
static ShaderOutput *multiply_color(ShaderGraph *graph,ShaderOutput *a,float3 factor,ShaderOutput *b=nullptr) {
  auto multiply=graph->create_node<VectorMathNode>();multiply->set_math_type(NODE_VECTOR_MATH_MULTIPLY);
  multiply->set_vector2(factor);graph->connect(a,multiply->input("Vector1"));
  if(b)graph->connect(b,multiply->input("Vector2"));return multiply->output("Vector");
}
static ShaderOutput *mapped_normal(ShaderGraph *graph,ShaderOutput *color,NSDictionary *desc,float strength,bool curve_shader) {
  if(!curve_shader) {
    // NormalMap supplies the selected mesh UV tangent frame. Rotate/reflect
    // the sampled tangent vector into that frame as well as transforming the
    // lookup coordinates; otherwise constant tilted maps expose a stale basis.
    NSArray *scale=json_list(desc,@"scale"),*offset=json_list(desc,@"offset");
    float sx=component(scale,0,1),sy=component(scale,1,1),angle=number(desc,@"rotationDegrees")*M_PI/180;
    if(std::abs(sx)<1e-12f || std::abs(sy)<1e-12f)throw std::runtime_error("Normal maps require nonzero texture scales");
    const float sign=sx*sy<0?-1.f:1.f;
    float tx=std::cos(angle)*sy*sign,ty=std::sin(angle)*sx*sign,length=std::hypot(tx,ty);tx/=length;ty/=length;
    auto separate=graph->create_node<SeparateXYZNode>();graph->connect(color,separate->input("Vector"));
    auto x=math_output(graph,math_output(graph,separate->output("X"),NODE_MATH_MULTIPLY,2),NODE_MATH_SUBTRACT,1);
    auto y=math_output(graph,math_output(graph,separate->output("Y"),NODE_MATH_MULTIPLY,2),NODE_MATH_SUBTRACT,1);
    bool mirror_u=[string_value(desc,@"wrapS",@"repeat") isEqualToString:@"mirror"];
    bool mirror_v=[string_value(desc,@"wrapT",@"repeat") isEqualToString:@"mirror"];
    if(mirror_u || mirror_v) {
      auto uv=graph->create_node<UVMapNode>();uv->set_attribute(ustring(number(desc,@"uvIndex",0)==0?"UVMap":"UVMap1"));
      auto mapping=graph->create_node<MappingNode>();mapping->set_scale(make_float3(sx,sy,1));
      mapping->set_location(make_float3(component(offset,0,0),component(offset,1,0),0));mapping->set_rotation(make_float3(0,0,angle));
      graph->connect(uv->output("UV"),mapping->input("Vector"));
      auto mapped=graph->create_node<SeparateXYZNode>();graph->connect(mapping->output("Vector"),mapped->input("Vector"));
      auto parity=[&](ShaderOutput *p) {
        p=math_output(graph,math_output(graph,math_output(graph,p,NODE_MATH_FLOOR,0),NODE_MATH_MULTIPLY,.5f),NODE_MATH_FRACTION,0);
        return math_output(graph,math_output(graph,p,NODE_MATH_MULTIPLY,-4),NODE_MATH_ADD,1);
      };
      if(mirror_u)x=binary_math(graph,x,NODE_MATH_MULTIPLY,parity(mapped->output("X")));
      if(mirror_v)y=binary_math(graph,y,NODE_MATH_MULTIPLY,parity(mapped->output("Y")));
    }
    auto mapped_x=binary_math(graph,math_output(graph,x,NODE_MATH_MULTIPLY,tx),NODE_MATH_SUBTRACT,math_output(graph,y,NODE_MATH_MULTIPLY,ty*sign));
    auto mapped_y=binary_math(graph,math_output(graph,x,NODE_MATH_MULTIPLY,ty),NODE_MATH_ADD,math_output(graph,y,NODE_MATH_MULTIPLY,tx*sign));
    auto encoded=graph->create_node<CombineXYZNode>();
    graph->connect(math_output(graph,math_output(graph,mapped_x,NODE_MATH_MULTIPLY,.5f),NODE_MATH_ADD,.5f),encoded->input("X"));
    graph->connect(math_output(graph,math_output(graph,mapped_y,NODE_MATH_MULTIPLY,.5f),NODE_MATH_ADD,.5f),encoded->input("Y"));
    graph->connect(separate->output("Z"),encoded->input("Z"));
    auto normal=graph->create_node<NormalMapNode>();
    normal->set_attribute(ustring(number(desc,@"uvIndex",0)==0?"UVMap":"UVMap1"));normal->set_strength(strength);
    graph->connect(encoded->output("Vector"),normal->input("Color"));return normal->output("Normal");
  }
  // Upstream tangent NormalMap deliberately ignores curves. Build their tangent
  // basis from the actual curve derivative, preserving the regular mesh branch.
  auto geometry=graph->create_node<GeometryNode>();auto n=geometry->output("Normal");
  auto tangent=geometry->output("Tangent");
  tangent=vector_math(graph,tangent,NODE_VECTOR_MATH_SUBTRACT,vector_scale(graph,n,vector_math(graph,n,NODE_VECTOR_MATH_DOT_PRODUCT,tangent)));
  tangent=vector_math(graph,tangent,NODE_VECTOR_MATH_NORMALIZE);
  auto bitangent=vector_math(graph,n,NODE_VECTOR_MATH_CROSS_PRODUCT,tangent);
  // A normal map's basis follows its actual coordinate set and affine mapping.
  // UVs use top-left V; the final image lookup flips V, so a positive texture
  // rotation rotates the physical tangent toward the original bitangent.
  int uv_index=bounded(desc,@"uvIndex",0,0,1);
  auto derivative=graph->create_node<AttributeNode>();derivative->set_missing(make_float3(1,0,0));
  derivative->set_attribute(ustring(uv_index==0?"LABCurveUV0Derivative":"LABCurveUV1Derivative"));
  auto slope=graph->create_node<SeparateXYZNode>();graph->connect(derivative->output("Vector"),slope->input("Vector"));
  NSArray *scale=json_list(desc,@"scale");
  float sx=component(scale,0,1),sy=component(scale,1,1),angle=number(desc,@"rotationDegrees")*M_PI/180;
  if(std::abs(sx)<1e-12f || std::abs(sy)<1e-12f)throw std::runtime_error("Curve normal maps require nonzero texture scales");
  auto det_sign=math_output(graph,math_output(graph,slope->output("X"),NODE_MATH_MULTIPLY,sx*sy),NODE_MATH_SIGN,0);
  auto b_coefficient=binary_math(graph,math_output(graph,slope->output("X"),NODE_MATH_MULTIPLY,std::sin(angle)*sx),NODE_MATH_ADD,
                                math_output(graph,slope->output("Y"),NODE_MATH_MULTIPLY,std::cos(angle)*sy));
  auto t_coefficient=graph->create_node<ValueNode>();t_coefficient->set_value(std::cos(angle)*sy);
  auto mapped_tangent=vector_math(graph,vector_scale(graph,tangent,t_coefficient->output("Value")),NODE_VECTOR_MATH_ADD,
                                 vector_scale(graph,bitangent,b_coefficient));
  tangent=vector_math(graph,vector_scale(graph,mapped_tangent,det_sign),NODE_VECTOR_MATH_NORMALIZE);
  bitangent=vector_scale(graph,vector_math(graph,n,NODE_VECTOR_MATH_CROSS_PRODUCT,tangent),det_sign);
  bool mirror_u=[string_value(desc,@"wrapS",@"repeat") isEqualToString:@"mirror"];
  bool mirror_v=[string_value(desc,@"wrapT",@"repeat") isEqualToString:@"mirror"];
  if(mirror_u || mirror_v) {
    auto uv=graph->create_node<UVMapNode>();uv->set_attribute(ustring(uv_index==0?"UVMap":"UVMap1"));
    auto mapping=graph->create_node<MappingNode>();mapping->set_scale(make_float3(sx,sy,1));
    NSArray *offset=json_list(desc,@"offset");mapping->set_location(make_float3(component(offset,0,0),component(offset,1,0),0));
    mapping->set_rotation(make_float3(0,0,angle));graph->connect(curve_uv(graph,uv->output("UV")),mapping->input("Vector"));
    auto mapped_uv=graph->create_node<SeparateXYZNode>();graph->connect(mapping->output("Vector"),mapped_uv->input("Vector"));
    auto mirror_sign=[&](ShaderOutput *coordinate) {
      auto parity=math_output(graph,math_output(graph,math_output(graph,coordinate,NODE_MATH_FLOOR,0),NODE_MATH_MULTIPLY,.5f),NODE_MATH_FRACTION,0);
      return math_output(graph,math_output(graph,parity,NODE_MATH_MULTIPLY,-4),NODE_MATH_ADD,1);
    };
    if(mirror_u)tangent=vector_scale(graph,tangent,mirror_sign(mapped_uv->output("X")));
    if(mirror_v)bitangent=vector_scale(graph,bitangent,mirror_sign(mapped_uv->output("Y")));
  }
  auto decoded=vector_math(graph,color,NODE_VECTOR_MATH_MULTIPLY,nullptr,make_float3(2,2,2));
  decoded=vector_math(graph,decoded,NODE_VECTOR_MATH_ADD,nullptr,make_float3(-1,-1,-1));
  float z_strength=std::clamp(strength,0.f,1.f);
  decoded=vector_math(graph,decoded,NODE_VECTOR_MATH_MULTIPLY,nullptr,make_float3(strength,strength,z_strength));
  decoded=vector_math(graph,decoded,NODE_VECTOR_MATH_ADD,nullptr,make_float3(0,0,1-z_strength));
  auto components=graph->create_node<SeparateXYZNode>();graph->connect(decoded,components->input("Vector"));
  auto result=vector_math(graph,vector_scale(graph,tangent,components->output("X")),NODE_VECTOR_MATH_ADD,vector_scale(graph,bitangent,components->output("Y")));
  result=vector_math(graph,result,NODE_VECTOR_MATH_ADD,vector_scale(graph,n,components->output("Z")));
  result=vector_math(graph,result,NODE_VECTOR_MATH_NORMALIZE);
  return result;
}
struct AnisotropyUVMapping {ustring name;int uv_index;double sx,sy,angle;};
static std::vector<AnisotropyUVMapping> anisotropy_uv_mappings;
static size_t anisotropy_attribute_bytes=0;
static ustring anisotropy_uv_name(NSDictionary *mapping) {
  int uv_index=bounded(mapping,@"uvIndex",0,0,1);
  NSArray *scale=json_list(mapping,@"scale");
  double sx=component(scale,0,1),sy=component(scale,1,1),angle=std::remainder(number(mapping,@"rotationDegrees",0),180.0);
  if(std::abs(sx)<1e-12 || std::abs(sy)<1e-12)
    throw std::runtime_error("Anisotropy direction requires nonzero texture scales");
  if(std::abs(angle)<1e-10)return ustring(uv_index==0?"UVMap":"UVMap1");
  double maximum=std::max(std::abs(sx),std::abs(sy));sx/=maximum;sy/=maximum;
  // A common scale, translation and repeat parity cannot change the unoriented
  // microfacet axis. Deduplicate those variants before allocating UV attributes.
  for(const auto &entry:anisotropy_uv_mappings)
    if(entry.uv_index==uv_index && entry.sx==sx && entry.sy==sy && entry.angle==angle)return entry.name;
  ustring name(("LABAnisotropyUV"+std::to_string(anisotropy_uv_mappings.size())).c_str());
  anisotropy_uv_mappings.push_back({name,uv_index,sx,sy,angle});return name;
}
static ShaderOutput *mesh_anisotropy_tangent(ShaderGraph *graph,NSDictionary *mapping) {
  // Geometry.Tangent uses generated radial coordinates, or a triangle edge if
  // those are absent. Explicitly request the authored chart's MikkTSpace tangent.
  // A rotated texture needs its full mapped UV chart: rotating an orthonormal
  // tangent frame alone loses the physical metric of rectangular/skewed charts.
  ustring uv_name=anisotropy_uv_name(mapping);
  auto tangent_node=graph->create_node<TangentNode>();
  tangent_node->set_direction_type(NODE_TANGENT_UVMAP);
  tangent_node->set_attribute(uv_name);
  auto tangent=tangent_node->output("Tangent");
  auto geometry=graph->create_node<GeometryNode>();auto normal=geometry->output("Normal");
  auto projected_axis=[&](float3 axis) {
    auto transform=graph->create_node<VectorTransformNode>();
    transform->set_transform_type(NODE_VECTOR_TRANSFORM_TYPE_VECTOR);
    transform->set_convert_from(NODE_VECTOR_TRANSFORM_CONVERT_SPACE_OBJECT);
    transform->set_convert_to(NODE_VECTOR_TRANSFORM_CONVERT_SPACE_WORLD);
    transform->set_vector(axis);
    auto value=transform->output("Vector");
    return vector_math(graph,value,NODE_VECTOR_MATH_SUBTRACT,
      vector_scale(graph,normal,vector_math(graph,value,NODE_VECTOR_MATH_DOT_PRODUCT,normal)));
  };
  auto nonzero=[&](ShaderOutput *value) {
    // Packed vertex normals have finite precision, including at exact poles.
    return math_output(graph,vector_math(graph,value,NODE_VECTOR_MATH_DOT_PRODUCT,value),NODE_MATH_GREATER_THAN,1e-8f);
  };
  auto choose=[&](ShaderOutput *a,ShaderOutput *b,ShaderOutput *use_a) {
    auto use_b=math_output(graph,math_output(graph,use_a,NODE_MATH_MULTIPLY,-1),NODE_MATH_ADD,1);
    return vector_math(graph,vector_scale(graph,a,use_a),NODE_VECTOR_MATH_ADD,vector_scale(graph,b,use_b));
  };
  // Old untextured assets may have no UVs. Use projected object X (then Y at
  // its pole), rather than silently returning to a triangle-dependent basis.
  auto axis_x=projected_axis(make_float3(1,0,0));
  auto fallback=choose(axis_x,projected_axis(make_float3(0,1,0)),nonzero(axis_x));
  return vector_math(graph,choose(tangent,fallback,nonzero(tangent)),NODE_VECTOR_MATH_NORMALIZE);
}
static ShaderOutput *material_closure(ShaderGraph *graph,NSDictionary *d,ShaderOutput *&displacement_output,bool curve_shader) {
  auto p=graph->create_node<PrincipledBsdfNode>();
  p->set_base_color(color(d,@"baseColor"));
  NSString *alpha_mode=string_value(d,@"alphaMode",@"opaque");
  // Resolve opacity around the final closure so transmission and unlit shading
  // share the same cutout behavior.
  p->set_alpha(1);
  p->set_metallic(bounded(d,@"metallic",0,0,1));
  p->set_roughness(bounded(d,@"roughness",.5,0,1));
  p->set_ior(bounded(d,@"ior",1.5,1,4));
  p->set_transmission_weight(bounded(d,@"transmission",0,0,1));
  p->set_subsurface_weight(bounded(d,@"subsurface",0,0,1));
  p->set_subsurface_radius(color(d,@"subsurfaceRadiusMM",make_float3(1,1,1)));
  p->set_subsurface_scale(.001f);
  p->set_sheen_weight(bounded(d,@"sheen",0,0,1));
  p->set_sheen_roughness(bounded(d,@"sheenRoughness",.5,0,1));
  p->set_sheen_tint(color(d,@"sheenTint"));
  p->set_anisotropic(bounded(d,@"anisotropy",0,-1,1));
  p->set_anisotropic_rotation(number(d,@"anisotropyRotation",0));
  p->set_coat_weight(bounded(d,@"coat",0,0,1));
  p->set_coat_roughness(bounded(d,@"coatRoughness",.03,0,1));
  p->set_emission_color(color(d,@"emissionColor",zero_float3()));
  p->set_emission_strength(number(d,@"emissionStrength",0));
  ShaderOutput *surface=p->output("BSDF");
  double diffuse=bounded(d,@"diffuseTransmission",0,0,1);
  NSDictionary *textures=value(d,@"textures") ?: @{};
  if(!curve_shader && (number(d,@"anisotropy",0)>0 || textures[@"anisotropy"]))
    graph->connect(mesh_anisotropy_tangent(graph,textures[@"anisotropy"] ?: @{}),p->input("Tangent"));
  float normal_strength=bounded(d,@"normalStrength",1,0,10);
  MixClosureNode *diffuse_mix=nullptr;
  TranslucentBsdfNode *translucent=nullptr;
  ShaderOutput *normal_map=nullptr,*normal_detail=nullptr;BumpNode *bump_map=nullptr;
  ImageTextureNode *artwork=nullptr;
  auto base_node=graph->create_node<ColorNode>();base_node->set_value(color(d,@"baseColor"));
  ShaderOutput *resolved_color=base_node->output("Color");
  auto alpha_node=graph->create_node<ValueNode>();alpha_node->set_value(component(json_list(d,@"baseColor"),3,1));
  ShaderOutput *resolved_alpha=alpha_node->output("Value");
  if(diffuse>0 || textures[@"diffuseTransmission"]) {
    translucent=graph->create_node<TranslucentBsdfNode>();
    translucent->set_color(color(d,@"baseColor"));
    diffuse_mix=graph->create_node<MixClosureNode>();diffuse_mix->set_fac(diffuse);
    graph->connect(surface,diffuse_mix->input("Closure1"));
    graph->connect(translucent->output("BSDF"),diffuse_mix->input("Closure2"));
    surface=diffuse_mix->output("Closure");
  }
  NSDictionary *sockets=@{@"baseColor":@"Base Color",@"roughness":@"Roughness",@"metallic":@"Metallic",
    @"emission":@"Emission Color",@"alpha":@"Alpha",@"anisotropy":@"Anisotropic",
    @"sheen":@"Sheen Weight",@"sheenTint":@"Sheen Tint",@"coat":@"Coat Weight",
    @"transmission":@"Transmission Weight",@"subsurface":@"Subsurface Weight"};
  for(NSString *channel in textures) {
    NSDictionary *desc=textures[channel];
    auto tex=texture(graph,desc,curve_shader);
    NSString *socket=sockets[channel];
    auto tex_value=texture_output(graph,tex,desc);
    if([channel isEqualToString:@"artwork"]) {artwork=tex;continue;}
    if(socket) {
      if([channel isEqualToString:@"alpha"])
        resolved_alpha=math_output(graph,tex_value,NODE_MATH_MULTIPLY,component(json_list(d,@"baseColor"),3,1));
      else if([channel isEqualToString:@"baseColor"]) {
        resolved_color=multiply_color(graph,tex_value,color(d,@"baseColor"));
        if(!textures[@"alpha"])resolved_alpha=math_output(graph,tex->output("Alpha"),NODE_MATH_MULTIPLY,component(json_list(d,@"baseColor"),3,1));
      } else {
        if([channel isEqualToString:@"emission"])tex_value=multiply_color(graph,tex_value,color(d,@"emissionColor"));
        else if([channel isEqualToString:@"sheenTint"])tex_value=multiply_color(graph,tex_value,color(d,@"sheenTint"));
        else tex_value=math_output(graph,tex_value,NODE_MATH_MULTIPLY,number(d,channel,1));
        graph->connect(tex_value,p->input(str(socket).c_str()));
      }
    }
    else if([channel isEqualToString:@"diffuseTransmission"] && diffuse_mix)
      graph->connect(math_output(graph,tex_value,NODE_MATH_MULTIPLY,diffuse),diffuse_mix->input("Fac"));
    else if([channel isEqualToString:@"normal"] || [channel isEqualToString:@"normalDetail"]) {
      bool detail=[channel isEqualToString:@"normalDetail"];
      float strength=detail?normal_strength:number(d,@"normalScale",1)*(textures[@"normalDetail"]?1:normal_strength);
      auto normal=mapped_normal(graph,tex_value,desc,strength,curve_shader);
      if(detail)normal_detail=normal;else normal_map=normal;
    } else if([channel isEqualToString:@"bump"]) {
      auto bump=graph->create_node<BumpNode>();bump_map=bump;
      bump->set_strength(number(d,@"bumpStrength",1));bump->set_distance(.0001f);
      graph->connect(tex_value,bump->input("Height"));
    } else if([channel isEqualToString:@"displacement"]) {
      if(number(d,@"displacementScaleMM",0)==0)continue;
      auto displacement=graph->create_node<DisplacementNode>();
      displacement->set_space(NODE_NORMAL_MAP_WORLD);
      displacement->set_scale(number(d,@"displacementScaleMM",0)*.001f);
      displacement->set_midlevel(number(d,@"displacementMidlevel",.5));
      graph->connect(tex_value,displacement->input("Height"));
      displacement_output=displacement->output("Displacement");
    } else throw std::runtime_error("Unsupported texture channel: "+str(channel));
  }
  ShaderOutput *resolved_normal=normal_map?normal_map:normal_detail;
  if(normal_map && normal_detail) {
    auto add=graph->create_node<VectorMathNode>();add->set_math_type(NODE_VECTOR_MATH_ADD);
    graph->connect(normal_map,add->input("Vector1"));graph->connect(normal_detail,add->input("Vector2"));
    auto geometry=graph->create_node<GeometryNode>();auto subtract=graph->create_node<VectorMathNode>();subtract->set_math_type(NODE_VECTOR_MATH_SUBTRACT);
    graph->connect(add->output("Vector"),subtract->input("Vector1"));graph->connect(geometry->output("Normal"),subtract->input("Vector2"));
    auto normalize=graph->create_node<VectorMathNode>();normalize->set_math_type(NODE_VECTOR_MATH_NORMALIZE);
    graph->connect(subtract->output("Vector"),normalize->input("Vector1"));resolved_normal=normalize->output("Vector");
  }
  if(resolved_normal && bump_map)graph->connect(resolved_normal,bump_map->input("Normal"));
  if(bump_map)resolved_normal=bump_map->output("Normal");
  if(resolved_normal)graph->connect(resolved_normal,p->input("Normal"));
  if(number(d,@"useVertexColor",0)!=0) {
    auto attr=graph->create_node<AttributeNode>();attr->set_attribute(ustring("LABColor"));
    resolved_color=multiply_color(graph,resolved_color,one_float3(),attr->output("Color"));
    auto multiply=graph->create_node<MathNode>();multiply->set_math_type(NODE_MATH_MULTIPLY);
    graph->connect(resolved_alpha,multiply->input("Value1"));graph->connect(attr->output("Alpha"),multiply->input("Value2"));
    resolved_alpha=multiply->output("Value");
  }
  if(artwork) {
    auto over=graph->create_node<MixColorNode>();
    graph->connect(resolved_color,over->input("A"));graph->connect(artwork->output("Color"),over->input("B"));
    graph->connect(artwork->output("Alpha"),over->input("Factor"));resolved_color=over->output("Result");
    auto alpha_over=graph->create_node<MixFloatNode>();alpha_over->set_b(1);
    graph->connect(resolved_alpha,alpha_over->input("A"));graph->connect(artwork->output("Alpha"),alpha_over->input("Factor"));
    resolved_alpha=alpha_over->output("Result");
  }
  graph->connect(resolved_color,p->input("Base Color"));
  if(translucent)graph->connect(resolved_color,translucent->input("Color"));
  if(number(d,@"unlit",0)!=0) {
    auto emission=graph->create_node<EmissionNode>(); emission->set_color(color(d,@"baseColor"));
    emission->set_strength(1); surface=emission->output("Emission");
    graph->connect(resolved_color,emission->input("Color"));
  }
  if(![alpha_mode isEqualToString:@"opaque"]) {
    if([alpha_mode isEqualToString:@"mask"])resolved_alpha=math_output(graph,resolved_alpha,NODE_MATH_GREATER_THAN,number(d,@"alphaCutoff",.5));
    auto transparent=graph->create_node<TransparentBsdfNode>();transparent->set_color(one_float3());
    auto mix=graph->create_node<MixClosureNode>();graph->connect(resolved_alpha,mix->input("Fac"));
    graph->connect(transparent->output("BSDF"),mix->input("Closure1"));graph->connect(surface,mix->input("Closure2"));
    surface=mix->output("Closure");
  }
  return surface;
}
static Shader *material(Scene *scene,NSDictionary *d,bool curve_shader=false) {
  auto shader=scene->create_node<Shader>();shader->name=ustring(str(string_value(d,@"id",@"material")));
  auto graph=make_unique<ShaderGraph>();ShaderOutput *displacement=nullptr;
  auto surface=material_closure(graph.get(),d,displacement,curve_shader);
  NSArray *layers=json_list(d,@"physicalLayers");
  if(layers.count>16)throw std::runtime_error("A material supports at most 16 physical layers");
  for(NSDictionary *layer in layers) {
    NSDictionary *appearance=layer[@"appearance"],*mask=layer[@"mask"];
    if((appearance && ![appearance isKindOfClass:NSDictionary.class]) || ![mask isKindOfClass:NSDictionary.class])
      throw std::runtime_error("Physical layer needs a mask texture and optional appearance");
    if(!appearance)appearance=@{};
    NSMutableDictionary *merged=[d mutableCopy];[merged removeObjectForKey:@"physicalLayers"];
    [merged addEntriesFromDictionary:appearance];
    NSMutableDictionary *textures=[(d[@"textures"] ?: @{}) mutableCopy];
    NSMutableDictionary *own_textures=[(appearance[@"textures"] ?: @{}) mutableCopy];
    for(NSString *channel in @[@"roughness",@"metallic"]) {
      // A finish factor replaces substrate maps. A map explicitly authored on
      // this finish still modulates its factor, with its independent mapping.
      id scalar=layer[channel] ?: appearance[channel];
      if(scalar) {
        double value=number(@{channel:scalar},channel,-1);
        if(value<0 || value>1)throw std::runtime_error("Finish roughness and metallic factors must be between zero and one");
        merged[channel]=scalar;
        if(!own_textures[channel])[textures removeObjectForKey:channel];
      }
    }
    if(own_textures[@"normal"] || own_textures[@"bump"] || own_textures[@"displacement"]) {
      // Base normal contains retained macro finish relief. Replacing substrate
      // microdetail must neither erase that relief nor apply two detail maps.
      [textures removeObjectForKey:@"normalDetail"];
      [textures removeObjectForKey:@"bump"];
      [textures removeObjectForKey:@"displacement"];
      if(textures[@"normal"] && own_textures[@"normal"]) {
        own_textures[@"normalDetail"]=own_textures[@"normal"];
        [own_textures removeObjectForKey:@"normal"];
      }
    }
    [textures addEntriesFromDictionary:own_textures];merged[@"textures"]=textures;
    ShaderOutput *layer_displacement=nullptr;
    auto layer_surface=material_closure(graph.get(),merged,layer_displacement,curve_shader);
    auto mask_node=texture(graph.get(),mask,curve_shader);auto factor=texture_output(graph.get(),mask_node,mask);
    auto mix=graph->create_node<MixClosureNode>();
    graph->connect(factor,mix->input("Fac"));graph->connect(surface,mix->input("Closure1"));
    graph->connect(layer_surface,mix->input("Closure2"));surface=mix->output("Closure");
    if((displacement || layer_displacement) &&
       (appearance[@"textures"][@"displacement"] || appearance[@"displacementScaleMM"])) {
      auto mix_displacement=graph->create_node<MixVectorNode>();
      if(displacement)graph->connect(displacement,mix_displacement->input("A"));
      if(layer_displacement)graph->connect(layer_displacement,mix_displacement->input("B"));
      graph->connect(factor,mix_displacement->input("Factor"));
      displacement=mix_displacement->output("Result");
    }
  }
  graph->connect(surface,graph->output()->input("Surface"));
  if(displacement){graph->connect(displacement,graph->output()->input("Displacement"));shader->set_displacement_method(DISPLACE_TRUE);}
  shader->set_graph(std::move(graph));shader->tag_update(scene);return shader;
}
static void attach(Scene *scene,Geometry *geometry,NSDictionary *d,const std::vector<Shader*> &materials) {
  array<Node*> shaders;for(auto shader:materials)shaders.push_back_slow(shader);
  geometry->set_used_shaders(shaders);
  auto object=scene->create_node<Object>();
  object->name=ustring(str(string_value(d,@"id",@"object")));
  object->set_geometry(geometry);object->set_tfm(matrix(d));
}
struct MeshBuffers {
  std::vector<double> positions;
  std::vector<float> normals,uvs,uvs1,colors;
  std::vector<uint32_t> indices,materials;
};
static double displacement_dicing_rate=2;
static size_t displacement_triangle_limit=2000000,displaced_triangles=0;
static int displacement_max_subdivisions=10,render_height=0;
static NSDictionary *render_camera=nil;

template<typename T> static void interpolate(std::vector<T> &data,uint32_t a,uint32_t b,size_t components) {
  if(data.empty())return;
  for(size_t c=0;c<components;c++)data.push_back((data[size_t(a)*components+c]+data[size_t(b)*components+c])/T(2));
}
static void subdivide_displacement(MeshBuffers &data,NSDictionary *record) {
  const size_t source_triangles=data.indices.size()/3;
  Transform camera_from_local=transform_inverse(matrix(render_camera))*matrix(record);
  std::vector<float3> camera_points(data.positions.size()/3);
  float nearest=FLT_MAX;
  for(size_t i=0;i<camera_points.size();i++) {
    auto p=make_float3(data.positions[i*3]*.001,data.positions[i*3+1]*.001,data.positions[i*3+2]*.001);
    camera_points[i]=transform_point(&camera_from_local,p);
    nearest=std::min(nearest,camera_points[i].z);
  }
  double scale;
  if([string_value(render_camera,@"type",@"perspective") isEqualToString:@"orthographic"])
    scale=render_height/(number(render_camera,@"orthoScale",100)*.001);
  else {
    nearest=std::max(nearest,float(number(render_camera,@"near",.1)*.001));
    scale=render_height/(2*std::tan(number(render_camera,@"fovRadians",M_PI/4)/2)*nearest);
  }
  double longest=0;
  for(size_t i=0;i<data.indices.size();i+=3)for(int e=0;e<3;e++)
    longest=std::max(longest,double(len(camera_points[data.indices[i+e]]-camera_points[data.indices[i+(e+1)%3]]))*scale);
  int levels=longest>displacement_dicing_rate?int(std::ceil(std::log2(longest/displacement_dicing_rate))):0;
  if(levels>displacement_max_subdivisions)
    throw std::runtime_error("Displacement needs more subdivision levels; increase displacement dicing pixels or the subdivision limit.");
  size_t triangles=source_triangles;
  for(int i=0;i<levels;i++) {
    if(triangles>displacement_triangle_limit/4)
      throw std::runtime_error("Displacement exceeds the triangle budget; increase displacement dicing pixels.");
    triangles*=4;
  }
  if(triangles>displacement_triangle_limit || displaced_triangles>displacement_triangle_limit-triangles)
    throw std::runtime_error("Scene displacement exceeds the triangle budget; increase displacement dicing pixels.");
  displaced_triangles+=triangles;
  if(levels)event(@"progress",@{@"progress":@0,@"sample":@0,@"phase":@"preparing",
    @"status":@"Tessellating textured displacement",@"sourceTriangles":@(source_triangles),@"renderTriangles":@(triangles)});
  for(int level=0;level<levels;level++) {
    if(interrupted)throw std::runtime_error("Cancelled displacement preparation");
    std::unordered_map<uint64_t,uint32_t> edge_vertices;edge_vertices.reserve(data.indices.size());
    auto midpoint=[&](uint32_t a,uint32_t b) {
      uint64_t key=(uint64_t(std::min(a,b))<<32)|std::max(a,b);
      auto found=edge_vertices.find(key);if(found!=edge_vertices.end())return found->second;
      uint32_t v=data.positions.size()/3;
      interpolate(data.positions,a,b,3);interpolate(data.normals,a,b,3);
      interpolate(data.uvs,a,b,2);interpolate(data.uvs1,a,b,2);interpolate(data.colors,a,b,4);
      edge_vertices.emplace(key,v);return v;
    };
    std::vector<uint32_t> indices,materials;indices.reserve(data.indices.size()*4);materials.reserve(data.materials.size()*4);
    for(size_t i=0;i<data.indices.size();i+=3) {
      uint32_t a=data.indices[i],b=data.indices[i+1],c=data.indices[i+2];
      uint32_t ab=midpoint(a,b),bc=midpoint(b,c),ca=midpoint(c,a);
      uint32_t child[]={a,ab,ca,ab,b,bc,ca,bc,c,ab,bc,ca};indices.insert(indices.end(),child,child+12);
      materials.insert(materials.end(),4,data.materials[i/3]);
    }
    data.indices=std::move(indices);data.materials=std::move(materials);
  }
}
static void mesh(Scene *scene,NSDictionary *d,const std::vector<Shader*> &materials) {
  MeshBuffers data;data.positions=binary<double>(d[@"positions"],3);data.indices=binary<uint32_t>(d[@"triangles"],1);
  size_t n=data.positions.size()/3,triangles=data.indices.size()/3;
  if(data.indices.size()%3 || !n)throw std::runtime_error("Invalid triangle mesh");
  for(auto i:data.indices)if(i>=n)throw std::runtime_error("Triangle index out of bounds");
  if(d[@"normals"])data.normals=binary<float>(d[@"normals"],3);
  if(d[@"uvs"])data.uvs=binary<float>(d[@"uvs"],2);
  if(d[@"uvs1"])data.uvs1=binary<float>(d[@"uvs1"],2);
  if(d[@"colors"])data.colors=binary<float>(d[@"colors"],4);
  if((!data.normals.empty() && data.normals.size()!=n*3) ||
     (!data.uvs.empty() && data.uvs.size()!=n*2) || (!data.uvs1.empty() && data.uvs1.size()!=n*2) ||
     (!data.colors.empty() && data.colors.size()!=n*4))throw std::runtime_error("Vertex attribute count mismatch");
  if(d[@"materialIndices"])data.materials=binary<uint32_t>(d[@"materialIndices"],1);
  else data.materials.resize(triangles,0);
  if(data.materials.size()!=triangles)throw std::runtime_error("Material index count mismatch");
  bool displaced=false;std::vector<Shader*> used_materials;std::vector<bool> seen_material(materials.size(),false);
  for(auto index:data.materials) {
    if(index>=materials.size())throw std::runtime_error("Material index out of bounds");
    if(!seen_material[index]){seen_material[index]=true;used_materials.push_back(materials[index]);}
    displaced|=materials[index]->get_displacement_method()!=DISPLACE_BUMP;
  }
  if(displaced)subdivide_displacement(data,d);
  n=data.positions.size()/3;triangles=data.indices.size()/3;
  auto m=scene->create_node<Mesh>();m->resize_mesh(n,triangles);
  auto positions=m->get_position_for_write();
  for(size_t i=0;i<n;i++)positions[i]=make_float3(data.positions[i*3]*.001,data.positions[i*3+1]*.001,data.positions[i*3+2]*.001);
  array<int> face_indices,shaders;array<bool> smooth;
  for(auto i:data.indices)face_indices.push_back_slow(i);
  for(auto i:data.materials){shaders.push_back_slow(i);smooth.push_back_slow(!data.normals.empty());}
  m->set_triangles(face_indices);m->set_shader(shaders);m->set_smooth(smooth);
  if(!data.normals.empty()) {
    auto attr=m->attributes.add(ATTR_STD_VERTEX_NORMAL);auto out=attr->data_for_write<packed_normal>();
    for(size_t i=0;i<n;i++)out[i]=packed_normal(safe_normalize(make_float3(data.normals[i*3],data.normals[i*3+1],data.normals[i*3+2])));
  }
  if(!data.uvs.empty()) {
    auto attr=m->attributes.add(ATTR_STD_UV,ustring("UVMap"));auto out=attr->data_for_write<float2>();
    for(size_t i=0;i<data.indices.size();i++)out[i]=make_float2(data.uvs[data.indices[i]*2],data.uvs[data.indices[i]*2+1]);
  }
  if(!data.uvs1.empty()) {
    auto attr=m->attributes.add(ustring("UVMap1"),TypeFloat2,ATTR_ELEMENT_CORNER);auto out=attr->data_for_write<float2>();
    for(size_t i=0;i<data.indices.size();i++)out[i]=make_float2(data.uvs1[data.indices[i]*2],data.uvs1[data.indices[i]*2+1]);
  }
  for(const auto &mapping:anisotropy_uv_mappings) {
    bool used=false;
    for(auto shader:used_materials)if(shader->attributes.find(mapping.name)){used=true;break;}
    const auto &uvs=mapping.uv_index==0?data.uvs:data.uvs1;
    if(!used || uvs.empty())continue;
    // Account for FLOAT2 corners plus Cycles' FLOAT3 tangent and FLOAT sign.
    constexpr size_t limit=128*1024*1024,bytes_per_corner=6*sizeof(float);
    if(data.indices.size()>(limit-anisotropy_attribute_bytes)/bytes_per_corner)
      throw std::runtime_error("Anisotropic direction attributes exceed 128 MiB; reduce mesh resolution or share texture mappings.");
    anisotropy_attribute_bytes+=data.indices.size()*bytes_per_corner;
    auto attr=m->attributes.add(mapping.name,TypeFloat2,ATTR_ELEMENT_CORNER);auto out=attr->data_for_write<float2>();
    double angle=mapping.angle*M_PI/180,c=std::cos(angle),s=std::sin(angle);
    for(size_t i=0;i<data.indices.size();i++) {
      if((i&16383)==0 && interrupted)throw std::runtime_error("Render cancelled");
      // Translation and positive common scale do not affect tangent direction.
      // Removing them keeps derived coordinates numerically well conditioned.
      double u=(double(uvs[data.indices[i]*2])-uvs[0])*mapping.sx;
      double v=(double(uvs[data.indices[i]*2+1])-uvs[1])*mapping.sy;
      out[i]=make_float2(c*u-s*v,s*u+c*v);
      if(!std::isfinite(out[i].x) || !std::isfinite(out[i].y))throw std::runtime_error("Anisotropy UV mapping is nonfinite");
    }
  }
  if(!data.colors.empty()) {
    auto attr=m->attributes.add(ustring("LABColor"),TypeRGBA,ATTR_ELEMENT_VERTEX);auto out=attr->data_for_write<float4>();
    for(size_t i=0;i<n;i++)out[i]=make_float4(data.colors[i*4],data.colors[i*4+1],data.colors[i*4+2],data.colors[i*4+3]);
  }
  attach(scene,m,d,materials);
}
static void curves(Scene *scene,NSDictionary *d,const std::vector<Shader*> &materials) {
  auto p=binary<double>(d[@"points"],3);auto r=binary<float>(d[@"radii"],1);
  auto first=binary<uint32_t>(d[@"firstKey"],1);
  if(p.size()/3!=r.size() || first.empty() || first[0]!=0)throw std::runtime_error("Invalid curve arrays");
  int mat=bounded(d,@"materialIndex",0,0,materials.size()-1);
  if(materials[mat]->get_displacement_method()!=DISPLACE_BUMP)
    throw std::runtime_error("Textured true displacement is unsupported on Cycles curves; use a mesh surface or a bump/normal texture.");
  std::vector<float> uvs,uvs1;
  if(d[@"uvs"])uvs=binary<float>(d[@"uvs"],2);
  if(d[@"uvs1"])uvs1=binary<float>(d[@"uvs1"],2);
  if((!uvs.empty() && uvs.size()!=r.size()*2) || (!uvs1.empty() && uvs1.size()!=r.size()*2))
    throw std::runtime_error("Curve UV arrays must contain one millimeter coordinate per key");
  bool generated_uvs=uvs.empty();if(generated_uvs)uvs.resize(r.size()*2);
  auto hair=scene->create_node<Hair>();hair->resize_curves(first.size(),r.size());
  hair->curve_shape=CURVE_THICK;
  auto positions=hair->get_position_for_write();auto radii=hair->get_radius_for_write();
  for(size_t i=0;i<r.size();i++) {
    if(r[i]<=0)throw std::runtime_error("Curve radius must be positive");
    positions[i]=make_float3(p[i*3]*.001,p[i*3+1]*.001,p[i*3+2]*.001);radii[i]=r[i]*.001;
  }
  auto frame_n=hair->attributes.add(ustring("LABCurveFrameN"),TypeVector,ATTR_ELEMENT_CURVE_KEY)->data_for_write<packed_float3>();
  auto frame_b=hair->attributes.add(ustring("LABCurveFrameB"),TypeVector,ATTR_ELEMENT_CURVE_KEY)->data_for_write<packed_float3>();
  auto circumference=hair->attributes.add(ustring("LABCurveCircumferenceMM"),TypeFloat,ATTR_ELEMENT_CURVE_KEY)->data_for_write<float>();
  auto tfm=matrix(d);auto c0=transform_get_column(&tfm,0),c1=transform_get_column(&tfm,1),c2=transform_get_column(&tfm,2);
  float radius_scale=std::cbrt(std::abs(dot(cross(c0,c1),c2)));
  array<int> starts,shaders;
  for(size_t i=0;i<first.size();i++) {
    size_t end=i+1<first.size()?first[i+1]:r.size();
    if(end>r.size() || end<first[i]+2)throw std::runtime_error("Each curve needs two ordered keys");
    starts.push_back_slow(first[i]);shaders.push_back_slow(mat);
    float3 previous_t=zero_float3(),previous_n=zero_float3();double length_mm=0;
    for(size_t key=first[i];key<end;key++) {
      size_t a=key==first[i]?key:key-1,b=key+1==end?key:key+1;
      float3 tangent=safe_normalize(float3(positions[b])-float3(positions[a]));
      if(len_squared(tangent)<.5f)tangent=key==first[i]?make_float3(1,0,0):previous_t;
      float3 n;
      if(key==first[i]) {
        float3 axis=std::abs(tangent.x)<=std::abs(tangent.y) && std::abs(tangent.x)<=std::abs(tangent.z)?make_float3(1,0,0):std::abs(tangent.y)<=std::abs(tangent.z)?make_float3(0,1,0):make_float3(0,0,1);
        n=safe_normalize(cross(tangent,axis));
      } else {
        float denominator=1+dot(previous_t,tangent);
        n=denominator>1e-6f?previous_n-(previous_t+tangent)*(dot(previous_n,tangent)/denominator):previous_n;
        n=safe_normalize(n-tangent*dot(n,tangent));
        length_mm+=len(transform_direction(&tfm,float3(positions[key])-float3(positions[key-1])))*1000;
      }
      frame_n[key]=n;frame_b[key]=safe_normalize(cross(tangent,n));circumference[key]=2*M_PI*r[key]*radius_scale;
      previous_t=tangent;previous_n=n;
      if(generated_uvs){uvs[key*2]=length_mm;uvs[key*2+1]=0;}
    }
  }
  auto set_uv=[&](const char *name,const std::vector<float> &data) {
    if(data.empty())return;
    auto attribute=hair->attributes.add(ustring(name),TypeFloat2,ATTR_ELEMENT_CURVE_KEY)->data_for_write<float2>();
    for(size_t i=0;i<r.size();i++)attribute[i]=make_float2(data[i*2],data[i*2+1]);
    const char *derivative_name=std::string(name)=="UVMap"?"LABCurveUV0Derivative":"LABCurveUV1Derivative";
    auto derivative=hair->attributes.add(ustring(derivative_name),TypeFloat2,ATTR_ELEMENT_CURVE_KEY)->data_for_write<float2>();
    for(size_t strand=0;strand<first.size();strand++) {
      size_t start=first[strand],end=strand+1<first.size()?first[strand+1]:r.size();
      for(size_t key=start;key<end;key++) {
        size_t a=key==start?key:key-1,b=key+1==end?key:key+1;
        double length_mm=len(transform_direction(&tfm,float3(positions[b])-float3(positions[a])))*1000;
        float du=length_mm>1e-10?(data[b*2]-data[a*2])/length_mm:1;
        float dv=length_mm>1e-10?(data[b*2+1]-data[a*2+1])/length_mm:0;
        // A constant coordinate set still permits constant 1x1 normal maps.
        derivative[key]=make_float2(std::abs(du)>1e-8f?du:1,dv);
      }
    }
  };
  set_uv("UVMap",uvs);set_uv("UVMap1",uvs1);
  hair->set_curve_first_key(starts);hair->set_curve_shader(shaders);attach(scene,hair,d,materials);
}
static void scene_load(Scene *scene,NSDictionary *d,int width,int height) {
  render_camera=d[@"camera"];if(!render_camera)throw std::runtime_error("Camera is required");
  render_height=height;displacement_dicing_rate=bounded(d,@"displacementDicingRate",2,.25,64);
  displacement_triangle_limit=bounded(d,@"displacementMaxTriangles",2000000,1,2000000);
  displacement_max_subdivisions=bounded(d,@"displacementMaxSubdivisions",10,0,10);
  // Upstream's default light shader has zero emission; explicit physical power
  // multiplies this unit-emission shader in the light geometry.
  auto light_graph=make_unique<ShaderGraph>();auto light_emission=light_graph->create_node<EmissionNode>();
  light_emission->set_color(one_float3());light_emission->set_strength(1);
  light_graph->connect(light_emission->output("Emission"),light_graph->output()->input("Surface"));
  scene->default_light->set_graph(std::move(light_graph));
  scene->default_light->tag_update(scene);
  NSArray *material_records=json_list(d,@"materials");
  std::vector<Shader*> shaders;for(NSDictionary *m in material_records)shaders.push_back(material(scene,m));
  if(shaders.empty())shaders.push_back(material(scene,@{}));
  for(NSDictionary *m in json_list(d,@"meshes"))mesh(scene,m,shaders);
  auto curve_shaders=shaders;std::vector<bool> curve_material_ready(shaders.size(),false);
  for(NSDictionary *c in json_list(d,@"curves")) {
    size_t index=bounded(c,@"materialIndex",0,0,shaders.size()-1);
    if(!curve_material_ready[index]) {
      curve_shaders[index]=material(scene,index<material_records.count?material_records[index]:@{},true);
      curve_material_ready[index]=true;
    }
    curves(scene,c,curve_shaders);
  }
  NSDictionary *c=d[@"camera"];if(!c)throw std::runtime_error("Camera is required");
  auto camera=scene->camera;
  camera->set_full_width(width);camera->set_full_height(height);camera->set_matrix(matrix(c));
  bool ortho=[string_value(c,@"type",@"perspective") isEqualToString:@"orthographic"];
  camera->set_camera_type(ortho ? CAMERA_ORTHOGRAPHIC : CAMERA_PERSPECTIVE);
  camera->set_fov(bounded(c,@"fovRadians",M_PI/4,.001,3.13));
  camera->set_nearclip(bounded(c,@"near",.1,.001,1e9)*.001);
  camera->set_farclip(bounded(c,@"far",1e7,1,1e12)*.001);
  double aspect=double(width)/height;
  float half_y=ortho ? bounded(c,@"orthoScale",100,.001,1e9)*.0005 : 1.f;
  camera->set_viewplane_left(-half_y*aspect);camera->set_viewplane_right(half_y*aspect);
  camera->set_viewplane_bottom(-half_y);camera->set_viewplane_top(half_y);
  if(number(c,@"apertureFStop",0)>0) {
    camera->set_aperturesize(.036/(2*std::tan(camera->get_fov()/2))/number(c,@"apertureFStop")/2);
    camera->set_focaldistance(number(c,@"focusDistanceMM",1000)*.001);
  }
  for(NSDictionary *l in json_list(d,@"lights")) {
    NSString *type=string_value(l,@"type",@"area");Light *light;
    if([type isEqualToString:@"point"]) {
      auto point=scene->create_node<PointLight>();point->set_radius(component(json_list(l,@"size"),0,1)*.0005);light=point;
    } else if([type isEqualToString:@"sun"]) {
      auto sun=scene->create_node<SunLight>();sun->set_angle(.00918);light=sun;
    } else if([type isEqualToString:@"area"]) {
      auto area=scene->create_node<AreaLight>();NSArray *size=json_list(l,@"size");
      area->set_sizeu(component(size,0,100)*.001);area->set_sizev(component(size,1,100)*.001);light=area;
      area->set_ellipse([string_value(l,@"shape",@"rectangle") isEqualToString:@"disk"]);
    } else throw std::runtime_error("Unsupported light type");
    light->set_strength(color(l,@"color")*float(number(l,@"power",10)));light->set_normalize(true);
    auto obj=scene->create_node<Object>();obj->set_geometry(light);obj->set_tfm(matrix(l));
    obj->set_visibility(PATH_RAY_VISIBILITY_ALL & ~PATH_RAY_VISIBILITY_CAMERA);
  }
  NSDictionary *bg=d[@"background"] ?: @{};
  auto graph=make_unique<ShaderGraph>();auto background=graph->create_node<BackgroundNode>();
  background->set_color(color(bg,@"color",make_float3(.05,.05,.05)));
  background->set_strength(number(bg,@"strength",1));
  if(bg[@"texture"]) {
    NSDictionary *desc=bg[@"texture"];
    auto environment=graph->create_node<EnvironmentTextureNode>();
    environment->set_filename(ustring(texture_path(desc).string()));
    environment->set_colorspace(texture_colorspace(desc));
    if([string_value(desc,@"format") isEqualToString:@"rgba32f"])environment->set_alpha_type(IMAGE_ALPHA_UNASSOCIATED);
    // Cycles lat-long environment uses +Z up; rotate LAB's +Y-up coordinates.
    environment->tex_mapping.rotation=make_float3(M_PI/2,0,number(bg,@"rotationDegrees")*M_PI/180);
    graph->connect(environment->output("Color"),background->input("Color"));
  }
  graph->connect(background->output("Background"),graph->output()->input("Surface"));
  scene->default_background->set_graph(std::move(graph));
  scene->default_background->tag_update(scene);
  scene->background->set_transparent(number(d,@"transparent",0)!=0);
  auto light=scene->create_node<BackgroundLight>();light->set_strength(one_float3());
  auto obj=scene->create_node<Object>();obj->set_geometry(light);
}
static DeviceInfo select_device(NSString *requested) {
  if(![@[@"auto",@"cpu",@"metal"] containsObject:requested])throw std::runtime_error("Unknown render device selection");
  auto devices=Device::available_devices(DEVICE_MASK_CPU|DEVICE_MASK_METAL);
  if(![requested isEqualToString:@"cpu"])for(auto &d:devices)if(d.type==DEVICE_METAL) {backend=@"metal";return d;}
  if([requested isEqualToString:@"metal"])throw std::runtime_error("No usable Cycles Metal device");
  for(auto &d:devices)if(d.type==DEVICE_CPU) {backend=@"cpu";if(![requested isEqualToString:@"cpu"])fallback_reason=@"Metal is unavailable; rendering with the bundled CPU device.";return d;}
  throw std::runtime_error("No usable Cycles render device");
}
int main(int argc,char **argv) {
  @autoreleasepool {
    // Keep the protocol independent of upstream diagnostic printf calls.
    event_file=fdopen(dup(STDOUT_FILENO),"w");dup2(STDERR_FILENO,STDOUT_FILENO);
    log_init(engine_log);log_level_set(LOG_LEVEL_DEBUG);
    signal(SIGTERM,signal_handler);signal(SIGINT,signal_handler);
    try {
      auto preparation_started=std::chrono::steady_clock::now();
      fs::path executable=fs::canonical(argv[0]);
      fs::path resource=executable.parent_path();
      if(fs::exists(executable.parent_path().parent_path()/"Resources/Cycles"))
        resource=executable.parent_path().parent_path()/"Resources/Cycles";
      NSString *cache=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"LAB/Cycles/" LAB_CYCLES_COMMIT];
      if(const char *override_path=getenv("LAB_CYCLES_CACHE_DIR"))cache=ns(override_path);
      fs::create_directories(str(cache));path_init(resource.string(),str(cache));
      if(argc==2 && std::string(argv[1])=="--capabilities") {
        NSMutableArray *devices=[NSMutableArray array];
        for(auto &d:Device::available_devices(DEVICE_MASK_CPU|DEVICE_MASK_METAL))
          [devices addObject:@{@"id":ns(d.id),@"name":ns(d.description),@"type":d.type==DEVICE_METAL?@"metal":@"cpu"}];
        event(@"capabilities",@{@"protocolVersion":@1,@"devices":devices,@"denoising":@YES,@"curves":@YES});return 0;
      }
      if(argc!=3 || std::string(argv[1])!="--render")throw std::runtime_error("Usage: lab-cycles-render --capabilities | --render manifest.json");
      fs::path manifest=fs::canonical(argv[2]);job_root=manifest.parent_path();
      NSData *data=[NSData dataWithContentsOfFile:ns(manifest.string())];
      NSError *error=nil;NSDictionary *d=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
      if(error || ![d isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid render manifest JSON");
      if(number(d,@"version")!=1)throw std::runtime_error("Unsupported render protocol version");
      job_id=string_value(d,@"jobID");revision=string_value(d,@"sourceRevision");
      output_root=resource_path(string_value(d,@"outputDirectory",@"output"));fs::create_directories(output_root);
      exposure=bounded(d,@"exposureEV",0,-20,20);
      int width=bounded(d,@"width",1024,1,8192),height=bounded(d,@"height",1024,1,8192);
      if(size_t(width)*height>33554432)throw std::runtime_error("Render exceeds 32 megapixel budget");
      SessionParams params;params.device=select_device(string_value(d,@"device",@"auto"));
      // `headless` disables DisplayDriver in upstream Cycles. Our driver is an
      // offscreen file sink, but still needs display scheduling. Background
      // mode ends the session at its sample limit and denoises the final image.
      params.denoise_device=params.device;params.headless=false;params.background=true;
      params.samples=bounded(d,@"samples",128,1,65536);params.use_auto_tile=false;
      requested_samples=params.samples;
      params.temp_dir=output_root.string();params.use_resolution_divider=true;
      SceneParams scene_params;LabSession session(params,scene_params);session.enable_progressive_updates();
      actual_sample_count=[&session]{return session.rendered_samples();};
      auto scene=session.scene.get();scene_load(scene,d,width,height);
      scene->integrator->set_seed(bounded(d,@"seed",0,0,2147483647));
      scene->integrator->set_max_bounce(bounded(d,@"maxBounces",12,1,128));
      scene->integrator->set_use_adaptive_sampling(number(d,@"adaptiveThreshold",.01)>0);
      scene->integrator->set_adaptive_threshold(bounded(d,@"adaptiveThreshold",.01,0,1));
      scene->integrator->set_adaptive_min_samples(16);
      bool denoise=number(d,@"denoise",1)!=0;
      scene->integrator->set_use_denoise(denoise);scene->integrator->set_denoiser_type(DENOISER_OPENIMAGEDENOISE);
      auto pass=scene->create_node<Pass>();pass->set_name(ustring("combined"));pass->set_type(PASS_COMBINED);
      pass->set_mode(denoise?PassMode::DENOISED:PassMode::NOISY);
      session.set_display_driver(make_unique<LabDisplay>(&session.progress));session.set_output_driver(make_unique<LabOutput>());
      std::chrono::steady_clock::time_point last{};
      session.progress.set_update_callback([&]{
        @autoreleasepool {
          current_sample=session.progress.get_current_sample();
          auto now=std::chrono::steady_clock::now();if(now-last<std::chrono::milliseconds(200))return;last=now;
          std::string status,substatus;session.progress.get_status(status,substatus);
          double progress=session.progress.get_progress();
          event(@"progress",@{@"progress":@(progress),@"sample":@(session.progress.get_current_sample()),
            @"totalSamples":@(params.samples),@"status":ns(status+(substatus.empty()?"":" / "+substatus))});
        }
      });
      BufferParams buffers;buffers.width=width;buffers.height=height;buffers.full_width=width;buffers.full_height=height;
      session.reset(params,buffers);auto started=std::chrono::steady_clock::now();
      std::atomic<bool> done{false};
      std::thread cancellation([&]{while(!done){if(interrupted){session.cancel(true);return;}std::this_thread::sleep_for(std::chrono::milliseconds(50));}});
      session.start();session.wait();done=true;cancellation.join();
      if(interrupted){event(@"cancelled");return 130;}
      if(session.progress.get_error()) {
        const auto message=session.progress.get_error_message();
        // Only these pinned upstream failures, before a sample is rendered, permit
        // the client to retry an Auto job once on CPU. Scene and memory errors do not.
        if([backend isEqualToString:@"metal"] && session.progress.get_current_sample()==0 &&
           (message.rfind("Failed to compile library:",0)==0 ||
            message.rfind("Could not activate pipeline for ",0)==0))error_category=@"metalInitialization";
        throw std::runtime_error(message);
      }
      if(!final_written)throw std::runtime_error(output_error.empty()?"Renderer completed without final pixels":output_error);
      auto report=session.engine_report();
      std::ofstream(output_root/"engine-report.txt")<<report;
      double total_seconds=0,render_seconds=0;session.progress.get_time(total_seconds,render_seconds);
      NSMutableDictionary *result=[@{@"finalPNG":ns((output_root/"final.png").string()),@"finalEXR":ns((output_root/"final.exr").string()),
        @"width":@(width),@"height":@(height),@"sample":@(session.progress.get_current_sample()),
        @"samplesRequested":@(params.samples),@"samplesCompleted":@(session.progress.get_current_sample()),
        @"denoiser":denoise?@"OpenImageDenoise " OIDN_VERSION_STRING:@"none",
        @"displayTransform":@"LAB-sRGB-v1",@"engineReportPath":ns((output_root/"engine-report.txt").string()),
        @"preparationSeconds":@(std::chrono::duration<double>(started-preparation_started).count()+std::max(0.,total_seconds-render_seconds)),
        @"seconds":@(std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count())} mutableCopy];
      add_stage_time(result,report,"Path Tracing",@"renderSeconds");
      if(denoise)add_stage_time(result,report,"Denoiser",@"denoiseSeconds");
      event(@"completed",result);
      return 0;
    }catch(const std::exception &e){if(interrupted){event(@"cancelled");return 130;}event(@"error",@{@"message":ns(e.what()),@"category":error_category});return 1;}
  }
}
