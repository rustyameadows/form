// Same source for old, patched-null, and actual adapter production-probe controls.
#ifdef ADAPTER_SOURCE
#include ADAPTER_SOURCE
#else
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <TopoDS_Shape.hxx>
#endif
#include <gp_Mat.hxx>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <cstring>
#include <cstdint>
#include <fstream>
static void bits(double value) {
  uint64_t raw;std::memcpy(&raw,&value,sizeof(raw));
  std::cout<<std::hex<<std::setw(16)<<std::setfill('0')<<raw<<' ';
}
static void properties(const GProp_GProps& p) {
  bits(p.Mass());auto c=p.CentreOfMass();bits(c.X());bits(c.Y());bits(c.Z());
  auto m=p.MatrixOfInertia();for(int i=1;i<=3;++i)for(int j=1;j<=3;++j)bits(m.Value(i,j));std::cout<<'\n';
}
#ifdef ADAPTER_SOURCE
struct ProductionProbeCounter {
  uint64_t calls=0;
  BRepGProp_Gauss::CancellationProbeState previous{nullptr,nullptr};
  static void poll(void* data) {
    auto& self=*static_cast<ProductionProbeCounter*>(data);++self.calls;
    self.previous.Probe(self.previous.Data); // Actual production atomic check.
  }
  explicit ProductionProbeCounter(FCADContext* expected) {
    previous=BRepGProp_Gauss::SetCancellationProbe(&poll,this);
    if(!previous.Probe || previous.Data!=expected)throw std::runtime_error("Production adapter probe missing.");
  }
  ~ProductionProbeCounter()noexcept {
    BRepGProp_Gauss::SetCancellationProbe(previous.Probe,previous.Data);
  }
};
#endif
int main(int argc,char**argv) {
  if(argc!=2&&argc!=3)return 2;
  TopoDS_Shape shape;BRep_Builder builder;
  if(!BRepTools::Read(shape,argv[1],builder))return 3;
  std::ostringstream before;BRepTools::Write(shape,before,false,false,TopTools_FormatVersion_CURRENT);
  auto calculate=[&] {
    GProp_GProps volume,area;
    BRepGProp::VolumeProperties(shape,volume,1e-9);
    BRepGProp::SurfaceProperties(shape,area,1e-9);
    properties(volume);properties(area);
  };
#ifdef ADAPTER_SOURCE
  FCADContext context;FCADFailure failure{};uint64_t calls=0;
  const auto status=run(&context,&failure,[&] {
    ProductionProbeCounter counter(&context);calculate();calls=counter.calls;
  });
  if(status!=FCAD_OK || calls==0){std::cerr<<failure.message<<'\n';return 6;}
  std::cerr<<"production_probe_installed=true; active_gprop_polls="<<calls<<"; status="<<status<<'\n';
#else
  calculate();
#endif
  std::ostringstream after;BRepTools::Write(shape,after,false,false,TopTools_FormatVersion_CURRENT);
  if(before.str()!=after.str())return 4;
  if(argc==3){std::ofstream dump(argv[2],std::ios::binary);dump<<after.str();if(!dump)return 5;}
  return 0;
}
