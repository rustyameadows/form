#include "FormCADKernel.h"
#include <Standard_Version.hxx>
#include <Standard_Failure.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Compound.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepBndLib.hxx>
#include <BRepGProp.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <Geom_BezierCurve.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <NCollection_Array1.hxx>
#include <gp_Circ.hxx>
#include <memory>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepTools.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <NCollection_IndexedMap.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <NCollection_List.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <Interface_Static.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <STEPConstruct_ExternRefs.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <TDataStd_Name.hxx>
#include <TDF_Tool.hxx>
#include <TCollection_ExtendedString.hxx>
#include <Quantity_ColorRGBA.hxx>
#include <functional>
#include <set>
#include <string>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <IMeshTools_Parameters.hxx>
#include <gp_Ax2.hxx>
#include <gp_GTrsf.hxx>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <vector>

using TopTools_IndexedMapOfShape = NCollection_IndexedMap<TopoDS_Shape,TopTools_ShapeMapHasher>;
using TopTools_ListOfShape = NCollection_List<TopoDS_Shape>;

struct FCADContext { std::atomic<bool> cancelled{false}; };
// A published handle is immutable: every modeling/meshing operation below uses
// a deep copy. Keep the exact report produced by its mandatory publication
// validation; repeated inspection must not reintegrate unchanged geometry.
struct FCADShape {
 const TopoDS_Shape value;
 const FCADShapeInfo report;
 FCADShape(const TopoDS_Shape& v,const FCADShapeInfo& checked):value(v),report(checked){}
};
struct FCADSTEPNode {FCADSTEPNodeInfo info{};TopoDS_Shape shape;std::vector<FCADFaceColor> faceColors;};
struct FCADSTEPDocument {occ::handle<TDocStd_Document> document;std::vector<FCADSTEPNode> nodes;};
namespace {
constexpr double maxCoordinate=10000000.0;
constexpr size_t maxTriangles=2000000, maxVertices=6000000, maxFileBytes=256*1024*1024;
std::recursive_mutex gate;
struct Failure:std::runtime_error { FCADStatus status; Failure(FCADStatus s,const char* m):std::runtime_error(m),status(s){} };
void require(bool value,const char* message) {if(!value) throw Failure(FCAD_INVALID_INPUT,message);}
void cancelled(FCADContext* c) {if(c && c->cancelled.load(std::memory_order_relaxed)) throw Failure(FCAD_CANCELLED,"CAD operation cancelled; no result was published.");}
void finite(double x) {require(std::isfinite(x)&&std::abs(x)<=maxCoordinate,"Use finite millimeter coordinates within ±10,000,000 mm.");}
void positive(double x) {finite(x);require(x>=1e-6,"A physical dimension must be at least 0.000001 mm.");}
gp_Pnt point(FCADPoint p) {finite(p.x);finite(p.y);finite(p.z);return {p.x,p.y,p.z};}
gp_Vec vector(FCADPoint p) {auto a=point(p);return {a.X(),a.Y(),a.Z()};}
gp_Dir direction(FCADPoint p) {auto v=vector(p);require(v.SquareMagnitude()>1e-18,"Use a non-zero axis direction.");return gp_Dir(v);}
FCADPoint value(const gp_Pnt& p){return {p.X(),p.Y(),p.Z()};}
const TopoDS_Shape& shape(const FCADShape* s){require(s && !s->value.IsNull(),"A source shape is unavailable.");return s->value;}
const FCADShapeInfo& verifiedInfo(const FCADShape* s){shape(s);return s->report;}
TopoDS_Shape copy(const FCADShape* s){return BRepBuilderAPI_Copy(shape(s),true,false).Shape();}
class Progress:public Message_ProgressIndicator {
 FCADContext* c;
 public:explicit Progress(FCADContext* x):c(x){} bool UserBreak()override{return c && c->cancelled.load(std::memory_order_relaxed);} void Show(const Message_ProgressScope&,const bool)override{}
};
occ::handle<Progress> progress(FCADContext* c){return new Progress(c);}
void bounds(const TopoDS_Shape& s,FCADPoint& lo,FCADPoint& hi){Bnd_Box box;box.SetGap(0);BRepBndLib::AddOptimal(s,box,false,false);if(box.IsVoid()||box.IsOpen())throw Failure(FCAD_INVALID_TOPOLOGY,"The shape has empty or unbounded geometry.");double x,y,z,X,Y,Z;box.Get(x,y,z,X,Y,Z);lo={x,y,z};hi={X,Y,Z};}
FCADShapeInfo info(const TopoDS_Shape& s,const FCADShapeInfo* rigidMassProperties=nullptr){
 FCADShapeInfo o{};bounds(s,o.minimum,o.maximum);o.shape_type=static_cast<int32_t>(s.ShapeType());
 auto count=[&](TopAbs_ShapeEnum t){TopTools_IndexedMapOfShape m;TopExp::MapShapes(s,t,m);return static_cast<uint32_t>(m.Extent());};
 o.solids=count(TopAbs_SOLID);o.shells=count(TopAbs_SHELL);o.faces=count(TopAbs_FACE);o.edges=count(TopAbs_EDGE);o.vertices=count(TopAbs_VERTEX);
 if(o.faces>100000||o.edges>200000||o.vertices>200000)throw Failure(FCAD_LIMIT_EXCEEDED,"CAD topology exceeds 100,000 faces or 200,000 edges/vertices.");
 o.valid=BRepCheck_Analyzer(s,true).IsValid();o.closed=o.solids>0&&o.shells>0;
 for(TopExp_Explorer e(s,TopAbs_SHELL);e.More();e.Next())if(!BRep_Tool::IsClosed(e.Current()))o.closed=0;
 TopTools_IndexedMapOfShape solidFaces;for(TopExp_Explorer e(s,TopAbs_SOLID);e.More();e.Next())TopExp::MapShapes(e.Current(),TopAbs_FACE,solidFaces);if(static_cast<uint32_t>(solidFaces.Extent())!=o.faces)o.closed=0;
 // Proper rigid motions preserve volume and area exactly. All geometry validity,
 // bounds, closedness, topology and actual tolerances above/below are still
 // checked on the newly constructed output. Other transforms integrate afresh.
 if(rigidMassProperties){o.volume=rigidMassProperties->volume;o.area=rigidMassProperties->area;}
 else{GProp_GProps mass,area;BRepGProp::VolumeProperties(s,mass,1e-9);BRepGProp::SurfaceProperties(s,area,1e-9);o.volume=mass.Mass();o.area=area.Mass();}
 for(TopExp_Explorer e(s,TopAbs_VERTEX);e.More();e.Next())o.maximum_tolerance=std::max(o.maximum_tolerance,BRep_Tool::Tolerance(TopoDS::Vertex(e.Current())));
 for(TopExp_Explorer e(s,TopAbs_EDGE);e.More();e.Next())o.maximum_tolerance=std::max(o.maximum_tolerance,BRep_Tool::Tolerance(TopoDS::Edge(e.Current())));
 for(TopExp_Explorer e(s,TopAbs_FACE);e.More();e.Next())o.maximum_tolerance=std::max(o.maximum_tolerance,BRep_Tool::Tolerance(TopoDS::Face(e.Current())));
 return o;
}
void publish(FCADContext* c,const TopoDS_Shape& s,FCADShape** out,bool solid=true,const FCADShapeInfo* inspected=nullptr,const FCADShapeInfo* rigidMassProperties=nullptr){
 require(out,"An output shape slot is required.");cancelled(c);if(s.IsNull())throw Failure(FCAD_OPERATION_FAILED,"The kernel did not construct a shape.");auto report=inspected ? *inspected:info(s,rigidMassProperties);
 if(!report.valid)throw Failure(FCAD_INVALID_TOPOLOGY,"The exact result failed BRepCheck validity. The previous revision is unchanged.");
 if(solid && (!report.closed||report.solids==0||report.volume<=1e-12))throw Failure(FCAD_INVALID_TOPOLOGY,"The exact result is empty, open, non-solid or inward oriented. The previous revision is unchanged.");
 cancelled(c);*out=new FCADShape(s,report);
}
template<class F>FCADStatus run(FCADContext* c,FCADFailure* err,F body){
 if(err){err->code=0;err->message[0]=0;}std::lock_guard<std::recursive_mutex> lock(gate);
 try{cancelled(c);body();return FCAD_OK;}
 catch(const Failure& e){if(err){err->code=e.status;std::snprintf(err->message,sizeof(err->message),"%s",e.what());}return e.status;}
 catch(const Standard_Failure& e){if(err){err->code=FCAD_OPERATION_FAILED;std::snprintf(err->message,sizeof(err->message),"Exact CAD construction failed: %s. The previous revision is unchanged.",e.what());}return FCAD_OPERATION_FAILED;}
 catch(const std::exception& e){if(err){err->code=FCAD_OPERATION_FAILED;std::snprintf(err->message,sizeof(err->message),"CAD operation failed: %s",e.what());}return FCAD_OPERATION_FAILED;}
 catch(...){if(err){err->code=FCAD_OPERATION_FAILED;std::snprintf(err->message,sizeof(err->message),"Unknown CAD kernel failure; no result was published.");}return FCAD_OPERATION_FAILED;}
}
TopTools_IndexedMapOfShape map(const TopoDS_Shape& s,TopAbs_ShapeEnum type){TopTools_IndexedMapOfShape result;TopExp::MapShapes(s,type,result);return result;}
std::vector<uint32_t> selected(const uint32_t* ids,size_t n,int total,bool all){
 require(n<=static_cast<size_t>(total)&&n<=200000,"Selection exceeds available topology.");require(ids||n==0,"Missing topology indices.");std::vector<uint32_t> result;
 if(n==0 && all){for(int i=1;i<=total;++i)result.push_back(i);}else{for(size_t i=0;i<n;++i){require(ids[i]>0&&ids[i]<=static_cast<uint32_t>(total),"A topology index is unavailable in this exact revision. Reinspect before editing.");require(std::find(result.begin(),result.end(),ids[i])==result.end(),"Topology selection contains duplicates.");result.push_back(ids[i]);}}
 require(!result.empty(),"Select at least one supported face or edge.");return result;
}
void path(const char* p,bool importing){require(p&&p[0]&&std::strlen(p)<=4096,"Use a bounded local file path.");std::filesystem::path f(p);if(importing){require(std::filesystem::is_regular_file(f),"Choose a regular CAD source file.");auto size=std::filesystem::file_size(f);if(size==0||size>maxFileBytes)throw Failure(FCAD_LIMIT_EXCEEDED,"CAD source must be between 1 byte and 256 MiB.");}else require(!std::filesystem::exists(f),"The destination already exists; choose a new exclusive output path.");}
TopoDS_Wire wire(const FCADPoint* points,size_t n){require(points&&n>=3&&n<=10000,"A closed profile ring needs 3–10,000 points.");BRepBuilderAPI_MakePolygon p;for(size_t i=0;i<n;++i){auto v=point(points[i]);if(i>0)require(v.Distance(point(points[i-1]))>1e-7,"Profile contains a zero-length edge.");p.Add(v);}p.Close();if(!p.IsDone())throw Failure(FCAD_INVALID_TOPOLOGY,"The profile wire could not be closed.");return p.Wire();}
}
extern "C" {
const char* fcad_version(){return OCC_VERSION_COMPLETE;}
FCADContext* fcad_context_create(){return new FCADContext();}
void fcad_context_cancel(FCADContext* c){if(c)c->cancelled.store(true,std::memory_order_relaxed);}
void fcad_context_release(FCADContext* c){delete c;}
void fcad_shape_release(FCADShape* s){std::lock_guard<std::recursive_mutex> lock(gate);delete s;}
void fcad_mesh_release(FCADMesh* m){if(!m)return;std::free(m->positions);std::free(m->normals);std::free(m->uvs);std::free(m->indices);std::free(m->face_indices);*m={};}
FCADStatus fcad_box(FCADContext*c,double w,double h,double d,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(w);positive(h);positive(d);publish(c,BRepPrimAPI_MakeBox(w,h,d).Shape(),out);});}
FCADStatus fcad_cylinder(FCADContext*c,double r,double h,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(r);positive(h);publish(c,BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0,0,0),gp_Dir(0,1,0)),r,h).Shape(),out);});}
FCADStatus fcad_cone(FCADContext*c,double a,double b,double h,FCADShape**out,FCADFailure*e){return run(c,e,[&]{finite(a);finite(b);positive(h);require(a>=0&&b>=0&&std::max(a,b)>=1e-6&&std::abs(a-b)>1e-7,"Cone radii must be non-negative, distinct and not both zero; use cylinder for equal radii.");publish(c,BRepPrimAPI_MakeCone(gp_Ax2(gp_Pnt(0,0,0),gp_Dir(0,1,0)),a,b,h).Shape(),out);});}
FCADStatus fcad_sphere(FCADContext*c,double r,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(r);publish(c,BRepPrimAPI_MakeSphere(r).Shape(),out);});}
FCADStatus fcad_torus(FCADContext*c,double a,double b,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(a);positive(b);require(a>b,"The torus major radius must exceed its minor radius.");publish(c,BRepPrimAPI_MakeTorus(gp_Ax2(gp_Pnt(0,0,0),gp_Dir(0,1,0)),a,b).Shape(),out);});}
FCADStatus fcad_profile(FCADContext*c,const FCADPoint*points,size_t total,const uint32_t*sizes,size_t rings,FCADPoint normal,FCADShape**out,FCADFailure*e){return run(c,e,[&]{
 require(points&&sizes&&rings>0&&rings<=64&&total>=3&&total<=10000,"Profile needs 1–64 rings with at most 10,000 points.");auto n=direction(normal);auto origin=point(points[0]);size_t offset=0;std::vector<TopoDS_Wire>wires;
 for(size_t ring=0;ring<rings;++ring){auto count=sizes[ring];require(count>=3&&count<=total-offset,"Invalid profile ring counts.");std::vector<FCADPoint> v(points+offset,points+offset+count);gp_Vec area;
  for(size_t i=0;i<count;++i){auto a=point(v[i]),b=point(v[(i+1)%count]);require(std::abs(gp_Vec(origin,a).Dot(gp_Vec(n)))<=1e-6,"Profile points must lie in one plane within 0.000001 mm.");area+=gp_Vec(a.X(),a.Y(),a.Z()).Crossed(gp_Vec(b.X(),b.Y(),b.Z()));}
  auto signedArea=area.Dot(gp_Vec(n));require(std::abs(signedArea)>1e-10,"Profile ring has no usable planar area.");if((signedArea>0)!=(ring==0))std::reverse(v.begin(),v.end());wires.push_back(wire(v.data(),v.size()));offset+=count;
 }require(offset==total,"Profile point count differs from ring sizes.");BRepBuilderAPI_MakeFace face(wires[0],true);for(size_t i=1;i<wires.size();++i)face.Add(wires[i]);if(!face.IsDone())throw Failure(FCAD_INVALID_TOPOLOGY,"The profile face is invalid or self-intersecting.");publish(c,face.Face(),out,false);
 });}
FCADStatus fcad_circle_profile(FCADContext*c,FCADPoint origin,FCADPoint normal,FCADPoint x,double radius,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(radius);auto n=direction(normal),u=direction(x);require(std::abs(n.Dot(u))<1e-10,"Circle plane axes must be orthogonal.");auto edge=BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(point(origin),n,u),radius)).Edge();auto wire=BRepBuilderAPI_MakeWire(edge).Wire();BRepBuilderAPI_MakeFace face(wire,true);require(face.IsDone(),"Circle profile could not be constructed.");publish(c,face.Face(),out,false);});}
FCADStatus fcad_curve_profile(FCADContext*c,const FCADCurveSegment*segments,size_t count,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(segments&&count>0&&count<=10000,"A curve profile needs 1–10,000 connected segments.");BRepBuilderAPI_MakeWire wire;for(size_t i=0;i<count;++i){const auto&s=segments[i];require(s.kind>=0&&s.kind<=3,"Unknown profile segment type.");require(point(s.end).Distance(point(segments[(i+1)%count].start))<=1e-7,"Curve profile segments must meet and form a closed loop.");TopoDS_Edge edge;if(s.kind==0)edge=BRepBuilderAPI_MakeEdge(point(s.start),point(s.end)).Edge();else if(s.kind==3){GC_MakeArcOfCircle arc(point(s.start),point(s.control1),point(s.end));require(arc.IsDone(),"Circular arc points are collinear or invalid.");edge=BRepBuilderAPI_MakeEdge(arc.Value()).Edge();}else{NCollection_Array1<gp_Pnt> poles(1,s.kind==1?3:4);poles.SetValue(1,point(s.start));poles.SetValue(2,point(s.control1));if(s.kind==2)poles.SetValue(3,point(s.control2));poles.SetValue(poles.Upper(),point(s.end));occ::handle<Geom_BezierCurve> curve=new Geom_BezierCurve(poles);edge=BRepBuilderAPI_MakeEdge(curve).Edge();}wire.Add(edge);if(!wire.IsDone())throw Failure(FCAD_INVALID_TOPOLOGY,"Curve profile wire is disconnected or invalid.");}BRepBuilderAPI_MakeFace face(wire.Wire(),true);if(!face.IsDone())throw Failure(FCAD_INVALID_TOPOLOGY,"Curve profile must form a planar closed face.");publish(c,face.Face(),out,false);});}
FCADStatus fcad_extrude(FCADContext*c,const FCADShape*p,FCADPoint v,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(shape(p).ShapeType()==TopAbs_FACE,"Extrude requires a bounded planar profile face.");auto d=vector(v);require(d.SquareMagnitude()>1e-12,"Extrusion needs a non-zero physical vector.");auto g=progress(c);BRepPrimAPI_MakePrism builder(copy(p),d,true,true);builder.Build(g->Start());if(!builder.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Profile extrusion did not produce a solid.");publish(c,builder.Shape(),out);});}
FCADStatus fcad_revolve(FCADContext*c,const FCADShape*p,FCADPoint origin,FCADPoint axis,double angle,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(shape(p).ShapeType()==TopAbs_FACE,"Revolve requires a closed planar profile face.");require(std::isfinite(angle)&&angle>1e-8&&angle<=2*M_PI+1e-9,"Revolve angle must be greater than zero and at most 2π radians.");auto g=progress(c);BRepPrimAPI_MakeRevol builder(copy(p),gp_Ax1(point(origin),direction(axis)),std::min(angle,2*M_PI),true);builder.Build(g->Start());if(!builder.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Revolve failed; the profile may cross the axis or self-intersect.");publish(c,builder.Shape(),out);});}
FCADStatus fcad_boolean(FCADContext*c,int32_t op,const FCADShape*a,const FCADShape*b,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(op>=0&&op<=2,"Unknown exact boolean operation.");require(verifiedInfo(a).closed&&verifiedInfo(b).closed,"Solid boolean inputs must be closed, valid solids.");auto left=copy(a),right=copy(b);auto g=progress(c);TopTools_ListOfShape args,tools;args.Append(left);tools.Append(right);std::unique_ptr<BRepAlgoAPI_BooleanOperation> builder;
 if(op==0)builder=std::make_unique<BRepAlgoAPI_Fuse>();else if(op==1)builder=std::make_unique<BRepAlgoAPI_Cut>();else builder=std::make_unique<BRepAlgoAPI_Common>();builder->SetArguments(args);builder->SetTools(tools);builder->SetNonDestructive(true);builder->SetRunParallel(false);builder->Build(g->Start());if(!builder->IsDone()||builder->HasErrors())throw Failure(FCAD_OPERATION_FAILED,"Exact boolean failed; inspect coincident edges, self-intersection and source validity.");publish(c,builder->Shape(),out);});}
FCADStatus fcad_fillet(FCADContext*c,const FCADShape*s,const uint32_t*ids,size_t n,double r,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(r);auto source=copy(s);auto edges=map(source,TopAbs_EDGE);auto indices=selected(ids,n,edges.Extent(),true);BRepFilletAPI_MakeFillet b(source);for(auto i:indices)b.Add(r,TopoDS::Edge(edges.FindKey(static_cast<int>(i))));auto g=progress(c);b.Build(g->Start());if(!b.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Fillet could not be built. Reduce radius or choose a supported edge set in the current revision.");publish(c,b.Shape(),out);});}
FCADStatus fcad_chamfer(FCADContext*c,const FCADShape*s,const uint32_t*ids,size_t n,double r,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(r);auto source=copy(s);auto edges=map(source,TopAbs_EDGE);auto indices=selected(ids,n,edges.Extent(),true);BRepFilletAPI_MakeChamfer b(source);for(auto i:indices)b.Add(r,TopoDS::Edge(edges.FindKey(static_cast<int>(i))));auto g=progress(c);b.Build(g->Start());if(!b.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Chamfer could not be built. Reduce distance or choose supported edges.");publish(c,b.Shape(),out);});}
FCADStatus fcad_shell(FCADContext*c,const FCADShape*s,const uint32_t*ids,size_t n,double thickness,FCADShape**out,FCADFailure*e){return run(c,e,[&]{positive(thickness);auto source=copy(s);auto faces=map(source,TopAbs_FACE);auto indices=selected(ids,n,faces.Extent(),false);TopTools_ListOfShape remove;for(auto i:indices)remove.Append(faces.FindKey(static_cast<int>(i)));BRepOffsetAPI_MakeThickSolid b;auto g=progress(c);b.MakeThickSolidByJoin(source,remove,-thickness,1e-7,BRepOffset_Skin,false,false,GeomAbs_Arc,false,g->Start());if(!b.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Shell failed at this thickness/face selection; no approximate hollow was substituted.");publish(c,b.Shape(),out);});}
FCADStatus fcad_offset_profile(FCADContext*c,const FCADShape*s,double distance,FCADShape**out,FCADFailure*e){return run(c,e,[&]{finite(distance);require(std::abs(distance)>=1e-7,"Profile offset must exceed kernel tolerance.");auto source=copy(s);require(source.ShapeType()==TopAbs_FACE&&map(source,TopAbs_WIRE).Extent()==1,"Profile offset supports one closed planar loop; offset holes independently and subtract explicitly.");BRepAdaptor_Surface surface(TopoDS::Face(source));require(surface.GetType()==GeomAbs_Plane,"Offset profile requires a planar face.");BRepOffsetAPI_MakeOffset b(TopoDS::Face(source),GeomAbs_Arc,false);b.Perform(distance);if(!b.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Profile offset failed; inspect distance, collapse and self-intersection.");auto wires=map(b.Shape(),TopAbs_WIRE);require(wires.Extent()==1,"Profile offset split or collapsed the loop; choose another distance.");BRepBuilderAPI_MakeFace face(TopoDS::Wire(wires.FindKey(1)),true);require(face.IsDone(),"Offset wire could not form a valid planar face.");publish(c,face.Face(),out,false);});}
FCADStatus fcad_sweep(FCADContext*c,const FCADShape*p,const FCADPoint*pathPoints,size_t count,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(shape(p).ShapeType()==TopAbs_FACE,"Sweep requires a closed planar profile face.");require(pathPoints&&count>=2&&count<=10000,"Sweep path needs 2–10,000 points.");BRepBuilderAPI_MakePolygon poly;for(size_t i=0;i<count;++i)poly.Add(point(pathPoints[i]));require(poly.IsDone(),"Sweep path could not be built.");BRepOffsetAPI_MakePipe b(poly.Wire(),copy(p));auto g=progress(c);b.Build(g->Start());if(!b.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Sweep failed; inspect path continuity, profile placement and self-intersection.");publish(c,b.Shape(),out);});}
FCADStatus fcad_loft(FCADContext*c,const FCADShape*const*profiles,size_t n,int32_t ruled,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(profiles&&n>=2&&n<=64,"Loft needs 2–64 section profiles.");BRepOffsetAPI_ThruSections b(true,ruled!=0,1e-7);for(size_t i=0;i<n;++i){auto s=copy(profiles[i]);require(s.ShapeType()==TopAbs_FACE,"Loft sections must be planar profile faces.");require(map(s,TopAbs_WIRE).Extent()==1,"Loft supports single-loop sections; subtract hole lofts explicitly.");b.AddWire(BRepTools::OuterWire(TopoDS::Face(s)));}auto g=progress(c);b.Build(g->Start());if(!b.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Loft failed; inspect section ordering, crossings and compatible profiles.");publish(c,b.Shape(),out);});}
FCADStatus fcad_transform(FCADContext*c,const FCADShape*s,const double*m,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(m,"An affine 4×4 transform is required.");for(int i=0;i<16;++i)finite(m[i]);require(std::abs(m[12])+std::abs(m[13])+std::abs(m[14])+std::abs(m[15]-1)<1e-12,"Only affine row-major transforms are supported.");gp_GTrsf t;for(int r=1;r<=3;++r)for(int col=1;col<=4;++col)t.SetValue(r,col,m[(r-1)*4+col-1]);require(std::abs(t.VectorialPart().Determinant())>1e-12,"Transform must be invertible.");double a=m[0]*m[0]+m[4]*m[4]+m[8]*m[8],b=m[1]*m[1]+m[5]*m[5]+m[9]*m[9],d=m[2]*m[2]+m[6]*m[6]+m[10]*m[10];double ab=m[0]*m[1]+m[4]*m[5]+m[8]*m[9],ad=m[0]*m[2]+m[4]*m[6]+m[8]*m[10],bd=m[1]*m[2]+m[5]*m[6]+m[9]*m[10];TopoDS_Shape transformed;const FCADShapeInfo* rigidMassProperties=nullptr;if(std::abs(a-b)+std::abs(a-d)+std::abs(ab)+std::abs(ad)+std::abs(bd)<1e-10*std::max(1.0,a)){gp_Trsf rigid;rigid.SetValues(m[0],m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9],m[10],m[11]);if(rigid.ScaleFactor()==1.0&&!rigid.IsNegative()&&verifiedInfo(s).closed)rigidMassProperties=&verifiedInfo(s);transformed=BRepBuilderAPI_Transform(shape(s),rigid,true).Shape();}else{transformed=BRepBuilderAPI_GTransform(shape(s),t,true).Shape();}publish(c,transformed,out,verifiedInfo(s).solids>0,nullptr,rigidMassProperties);});}
FCADStatus fcad_compound(FCADContext*c,const FCADShape*const*shapes,size_t n,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(shapes&&n>0&&n<=1024,"An assembly compound needs 1–1024 shapes.");TopoDS_Compound result;BRep_Builder b;b.MakeCompound(result);for(size_t i=0;i<n;++i)b.Add(result,copy(shapes[i]));publish(c,result,out);});}
FCADStatus fcad_info(FCADContext*c,const FCADShape*s,FCADShapeInfo*out,FCADFailure*e){return run(c,e,[&]{require(out,"An output report is required.");*out=verifiedInfo(s);});}
FCADStatus fcad_face_info(FCADContext*c,const FCADShape*s,uint32_t index,FCADFaceInfo*out,FCADFailure*e){return run(c,e,[&]{require(out,"An output face report is required.");auto faces=map(shape(s),TopAbs_FACE);require(index>0&&index<=static_cast<uint32_t>(faces.Extent()),"Face is unavailable in this exact revision.");auto f=TopoDS::Face(faces.FindKey(static_cast<int>(index)));GProp_GProps props;BRepGProp::SurfaceProperties(f,props,1e-9);FCADFaceInfo r{};r.index=index;r.surface_type=static_cast<int32_t>(BRepAdaptor_Surface(f).GetType());r.area=props.Mass();r.center=value(props.CentreOfMass());bounds(f,r.minimum,r.maximum);*out=r;});}
FCADStatus fcad_edge_info(FCADContext*c,const FCADShape*s,uint32_t index,FCADEdgeInfo*out,FCADFailure*e){return run(c,e,[&]{require(out,"An output edge report is required.");auto edges=map(shape(s),TopAbs_EDGE);require(index>0&&index<=static_cast<uint32_t>(edges.Extent()),"Edge is unavailable in this exact revision.");auto edge=TopoDS::Edge(edges.FindKey(static_cast<int>(index)));BRepAdaptor_Curve curve(edge);GProp_GProps props;BRepGProp::LinearProperties(edge,props);*out={index,static_cast<int32_t>(curve.GetType()),props.Mass(),value(curve.Value(curve.FirstParameter())),value(curve.Value(curve.LastParameter())),value(props.CentreOfMass())};});}
FCADStatus fcad_clearance(FCADContext*c,const FCADShape*a,const FCADShape*b,double*distance,double*volume,FCADFailure*e){return run(c,e,[&]{require(distance&&volume,"Clearance output slots are required.");auto left=copy(a),right=copy(b);auto g=progress(c);BRepExtrema_DistShapeShape d(left,right);d.Perform(g->Start());if(!d.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Exact closest-distance query failed.");*distance=d.Value();BRepAlgoAPI_Common common(left,right);common.SetNonDestructive(true);common.Build();if(!common.IsDone()||common.HasErrors())throw Failure(FCAD_OPERATION_FAILED,"Interference-volume query failed.");GProp_GProps mass;BRepGProp::VolumeProperties(common.Shape(),mass,1e-9);*volume=std::max(0.0,mass.Mass());});}
FCADStatus fcad_tessellate(FCADContext*c,const FCADShape*s,double linear,double angular,FCADMesh*out,FCADFailure*e){return run(c,e,[&]{require(out,"An output mesh is required.");require(std::isfinite(linear)&&linear>=0.000001&&linear<=1000,"Display chord deflection must be between 0.000001 and 1000 mm.");require(std::isfinite(angular)&&angular>=0.001&&angular<=M_PI,"Display angular deflection must be between 0.001 and π radians.");auto source=copy(s);BRepTools::Clean(source);IMeshTools_Parameters params;params.Deflection=linear;params.Angle=angular;params.InParallel=false;params.Relative=false;auto g=progress(c);BRepMesh_IncrementalMesh mesher(source,params,g->Start());if(!mesher.IsDone())throw Failure(FCAD_OPERATION_FAILED,"Display tessellation failed; exact source remains valid and unchanged.");
 std::vector<double> positions,normals,uvs;std::vector<uint32_t> indices,faceIDs;auto faces=map(source,TopAbs_FACE);
 for(int fi=1;fi<=faces.Extent();++fi){cancelled(c);auto face=TopoDS::Face(faces.FindKey(fi));TopLoc_Location loc;auto t=BRep_Tool::Triangulation(face,loc);if(t.IsNull())throw Failure(FCAD_OPERATION_FAILED,"A face could not be tessellated.");if(positions.size()/3+static_cast<size_t>(t->NbNodes())>maxVertices||faceIDs.size()+static_cast<size_t>(t->NbTriangles())>maxTriangles)throw Failure(FCAD_LIMIT_EXCEEDED,"Display mesh exceeds two million triangles or six million face-local vertices. Use coarser display deflection.");BRepLib_ToolTriangulatedShape::ComputeNormals(face,t);double u0,u1,v0,v1;BRepTools::UVBounds(face,u0,u1,v0,v1);auto base=static_cast<uint32_t>(positions.size()/3);bool reverse=face.Orientation()==TopAbs_REVERSED;
  for(int vi=1;vi<=t->NbNodes();++vi){auto p=t->Node(vi).Transformed(loc.Transformation());auto n=t->Normal(vi).Transformed(loc.Transformation());if(reverse)n.Reverse();positions.insert(positions.end(),{p.X(),p.Y(),p.Z()});normals.insert(normals.end(),{n.X(),n.Y(),n.Z()});double u=0,v=0;if(t->HasUVNodes()){auto uv=t->UVNode(vi);u=u1-u0>1e-15?(uv.X()-u0)/(u1-u0):0;v=v1-v0>1e-15?(uv.Y()-v0)/(v1-v0):0;}uvs.insert(uvs.end(),{u,v});}
  for(int ti=1;ti<=t->NbTriangles();++ti){int a,b,d;t->Triangle(ti).Get(a,b,d);if(reverse)std::swap(b,d);indices.insert(indices.end(),{base+static_cast<uint32_t>(a-1),base+static_cast<uint32_t>(b-1),base+static_cast<uint32_t>(d-1)});faceIDs.push_back(fi);}
 }
 FCADMesh result{};auto alloc=[](const auto& data){using Element=typename std::decay_t<decltype(data)>::value_type;auto p=static_cast<Element*>(std::malloc(data.size()*sizeof(Element)));if(!p&&!data.empty())throw std::bad_alloc();if(!data.empty())std::memcpy(p,data.data(),data.size()*sizeof(Element));return p;};try{result.positions=alloc(positions);result.normals=alloc(normals);result.uvs=alloc(uvs);result.indices=alloc(indices);result.face_indices=alloc(faceIDs);}catch(...){fcad_mesh_release(&result);throw;}result.vertex_count=positions.size()/3;result.index_count=indices.size();result.triangle_count=faceIDs.size();try{cancelled(c);}catch(...){fcad_mesh_release(&result);throw;}*out=result;
 });}
FCADStatus fcad_write_brep(FCADContext*c,const FCADShape*s,const char*p,FCADFailure*e){return run(c,e,[&]{path(p,false);auto g=progress(c);if(!BRepTools::Write(shape(s),p,false,false,TopTools_FormatVersion_CURRENT,g->Start()))throw Failure(FCAD_IO_FAILED,"Could not write the exact B-rep source.");});}
FCADStatus fcad_read_brep(FCADContext*c,const char*p,FCADShape**out,FCADFailure*e){return run(c,e,[&]{path(p,true);BRep_Builder b;TopoDS_Shape s;auto g=progress(c);if(!BRepTools::Read(s,p,b,g->Start()))throw Failure(FCAD_IO_FAILED,"The B-rep source could not be parsed.");auto report=info(s);publish(c,s,out,report.solids>0,&report);});}
FCADStatus fcad_write_step(FCADContext*c,const FCADShape*s,const char*p,FCADFailure*e){return run(c,e,[&]{path(p,false);Interface_Static::SetCVal("write.step.unit","MM");STEPControl_Writer w;auto g=progress(c);if(w.Transfer(copy(s),STEPControl_AsIs,true,g->Start())!=IFSelect_RetDone)throw Failure(FCAD_IO_FAILED,"STEP transfer failed; no approximate mesh export was substituted.");cancelled(c);if(w.Write(p)!=IFSelect_RetDone)throw Failure(FCAD_IO_FAILED,"STEP file could not be written.");});}
void fcad_step_document_release(FCADSTEPDocument*d){std::lock_guard<std::recursive_mutex> lock(gate);delete d;}
size_t fcad_step_node_count(const FCADSTEPDocument*d){std::lock_guard<std::recursive_mutex> lock(gate);return d?d->nodes.size():0;}
FCADStatus fcad_step_node_info(FCADContext*c,const FCADSTEPDocument*d,size_t index,FCADSTEPNodeInfo*out,FCADFailure*e){return run(c,e,[&]{require(d&&out&&index<d->nodes.size(),"STEP occurrence is unavailable.");*out=d->nodes[index].info;});}
FCADStatus fcad_step_part(FCADContext*c,const FCADSTEPDocument*d,const char*partPath,FCADShape**out,FCADFailure*e){return run(c,e,[&]{require(d&&partPath&&std::strlen(partPath)<=511,"Choose a bounded STEP source part path.");for(const auto& node:d->nodes){if(std::strcmp(node.info.path,partPath)==0){require(!node.info.is_assembly&&!node.shape.IsNull(),"Select a leaf STEP component rather than an assembly container.");publish(c,BRepBuilderAPI_Copy(node.shape,true,false).Shape(),out);return;}}throw Failure(FCAD_INVALID_INPUT,"STEP part path does not belong to this pinned source revision.");});}
FCADStatus fcad_step_face_colors(FCADContext*c,const FCADSTEPDocument*d,size_t index,FCADFaceColor*out,size_t capacity,FCADFailure*e){return run(c,e,[&]{require(d&&index<d->nodes.size(),"STEP occurrence is unavailable.");const auto& colors=d->nodes[index].faceColors;require(capacity==colors.size()&&(out||capacity==0),"STEP face-color output capacity disagrees with its occurrence metadata.");if(capacity)std::copy(colors.begin(),colors.end(),out);});}
FCADStatus fcad_read_step_document(FCADContext*c,const char*p,FCADSTEPDocument**out,FCADFailure*e){return run(c,e,[&]{
 path(p,true);require(out,"A STEP document output is required.");Interface_Static::SetCVal("xstep.cascade.unit","MM");STEPCAFControl_Reader reader;reader.SetNameMode(true);reader.SetColorMode(true);
 if(reader.ReadFile(p)!=IFSelect_RetDone)throw Failure(FCAD_IO_FAILED,"STEP assembly source could not be parsed.");
 STEPConstruct_ExternRefs refs(reader.Reader().WS());refs.LoadExternRefs();require(refs.NbExternRefs()==0,"STEP external file references are not imported automatically. Consolidate the assembly to a self-contained STEP file.");
 reader.ChangeReader().SetSystemLengthUnit(1.0);auto document=std::make_unique<FCADSTEPDocument>();document->document=new TDocStd_Document("LAB-STEP");auto g=progress(c);
 if(!reader.Transfer(document->document,g->Start()))throw Failure(FCAD_IO_FAILED,"STEP assembly did not transfer exact geometry.");
 auto shapes=XCAFDoc_DocumentTool::ShapeTool(document->document->Main());auto colors=XCAFDoc_DocumentTool::ColorTool(document->document->Main());NCollection_Sequence<TDF_Label> roots;shapes->GetFreeShapes(roots);require(!roots.IsEmpty(),"STEP assembly contains no free component roots.");
 auto text=[](const TDF_Label& label)->std::string{occ::handle<TDataStd_Name> value;if(!label.FindAttribute(TDataStd_Name::GetID(),value))return {};const auto& name=value->Get();int count=name.LengthOfCString();require(count<=1023,"STEP component names exceed 1023 UTF-8 bytes.");std::vector<char> buffer(count+1,0);char* start=buffer.data();name.ToUTF8CString(start);return std::string(buffer.data());};
 auto matrix=[](const TopLoc_Location& location,double*out){const auto& trsf=location.Transformation();for(int r=0;r<4;++r)for(int col=0;col<4;++col)out[r*4+col]=r==3?(col==3?1:0):trsf.Value(r+1,col+1);};
 auto rgba=[](const Quantity_ColorRGBA& color,double*out){const auto& rgb=color.GetRGB();out[0]=rgb.Red();out[1]=rgb.Green();out[2]=rgb.Blue();out[3]=color.Alpha();};
 auto labelColor=[&](const TDF_Label& label,Quantity_ColorRGBA& color){return colors->GetColor(label,XCAFDoc_ColorSurf,color)||colors->GetColor(label,XCAFDoc_ColorGen,color);};
 size_t leaves=0,totalFaceColors=0,totalFaces=0,totalEdges=0,totalVertices=0;std::set<std::string> ancestors;
 std::function<void(const TDF_Label&,const TopLoc_Location&,int,const std::string&,size_t,bool,const Quantity_ColorRGBA&)> visit;
 visit=[&](const TDF_Label& occurrence,const TopLoc_Location& parent,int parentIndex,const std::string& partPath,size_t depth,bool inherited,const Quantity_ColorRGBA& inheritedColor){
  cancelled(c);require(depth<=64&&document->nodes.size()<4096&&partPath.size()<=511,"STEP assembly exceeds bounded hierarchy size or depth.");
  TDF_Label definition=occurrence;const bool reference=shapes->GetReferredShape(occurrence,definition);TCollection_AsciiString key;TDF_Tool::Entry(definition,key);require(key.Length()<=255,"STEP definition identity exceeds its bound.");
  const std::string definitionKey=key.ToCString();require(!ancestors.count(definitionKey),"STEP assembly contains a component-reference cycle.");ancestors.insert(definitionKey);
  auto local=reference?shapes->GetLocation(occurrence)*shapes->GetLocation(definition):shapes->GetLocation(definition);auto world=parent*local;
  const auto source=shapes->GetShape(definition);require(!source.IsNull(),"STEP component has no shape.");
  FCADSTEPNode node;std::strcpy(node.info.path,partPath.c_str());std::strcpy(node.info.definition_key,definitionKey.c_str());auto name=text(occurrence);if(name.empty()||name=="=>["+definitionKey+"]")name=text(definition);if(name.empty())name="Unnamed component";std::strcpy(node.info.name,name.c_str());node.info.parent_index=parentIndex;node.info.is_assembly=shapes->IsAssembly(definition)?1:0;matrix(local,node.info.local_transform);matrix(world,node.info.world_transform);
  Quantity_ColorRGBA color;bool hasColor=colors->GetInstanceColor(shapes->GetShape(occurrence),XCAFDoc_ColorSurf,color)||colors->GetInstanceColor(shapes->GetShape(occurrence),XCAFDoc_ColorGen,color)||labelColor(occurrence,color)||labelColor(definition,color);if(!hasColor&&inherited){color=inheritedColor;hasColor=true;}node.info.has_color=hasColor?1:0;if(hasColor)rgba(color,node.info.color_rgba);
  if(!node.info.is_assembly){require(++leaves<=256,"STEP assembly exceeds 256 leaf components.");node.shape=source.Located(TopLoc_Location()).Moved(world);auto health=info(node.shape);totalFaces+=health.faces;totalEdges+=health.edges;totalVertices+=health.vertices;require(totalFaces<=100000&&totalEdges<=200000&&totalVertices<=200000,"STEP assembly exceeds total exact topology budget.");require(health.valid&&health.closed&&health.solids>0,"STEP contains an open or non-solid component. Import such geometry as an explicitly visual reference.");
   auto faces=map(source,TopAbs_FACE);for(int i=1;i<=faces.Extent();++i){Quantity_ColorRGBA faceColor;const auto& face=faces.FindKey(i);if(colors->GetColor(face,XCAFDoc_ColorSurf,faceColor)||colors->GetColor(face,XCAFDoc_ColorGen,faceColor)){FCADFaceColor entry{};entry.face_index=i;rgba(faceColor,entry.rgba);node.faceColors.push_back(entry);}}
   totalFaceColors+=node.faceColors.size();require(totalFaceColors<=100000,"STEP face-color map exceeds 100,000 entries.");node.info.face_color_count=static_cast<uint32_t>(node.faceColors.size());
  }
  const auto index=static_cast<int>(document->nodes.size());document->nodes.push_back(std::move(node));
  if(document->nodes[index].info.is_assembly){NCollection_Sequence<TDF_Label> children;shapes->GetComponents(definition,children,false);require(!children.IsEmpty(),"STEP assembly has no component occurrences.");for(int i=1;i<=children.Length();++i)visit(children.Value(i),world,index,partPath+"/"+std::to_string(i-1),depth+1,hasColor,color);}
  ancestors.erase(definitionKey);
 };
 for(int i=1;i<=roots.Length();++i)visit(roots.Value(i),TopLoc_Location(),-1,std::to_string(i-1),0,false,Quantity_ColorRGBA());
 require(leaves>0,"STEP assembly contains no closed solid leaves.");cancelled(c);*out=document.release();
});}

FCADStatus fcad_read_step(FCADContext*c,const char*p,FCADShape**out,FCADFailure*e){return run(c,e,[&]{path(p,true);Interface_Static::SetCVal("xstep.cascade.unit","MM");STEPControl_Reader r;if(r.ReadFile(p)!=IFSelect_RetDone)throw Failure(FCAD_IO_FAILED,"STEP source could not be parsed.");r.SetSystemLengthUnit(1.0);auto g=progress(c);if(r.TransferRoots(g->Start())<=0)throw Failure(FCAD_IO_FAILED,"STEP contains no transferable exact roots.");publish(c,r.OneShape(),out);});}
}
