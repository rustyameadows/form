// Standalone native regression, outside SwiftPM test targets.
// Include the actual adapter to exercise run/publish without a shipped test API.
#include "../../Sources/CFormCADKernel/FormCADKernel.cpp"
#include <sstream>
#include <iostream>
#include <thread>
#include <chrono>
#include <cstdint>

using ProbeState = BRepGProp_Gauss::CancellationProbeState;
static void expect(bool value,const char* message) {
  if(!value) throw std::runtime_error(message);
}
static std::string serialized(const TopoDS_Shape& shape) {
  std::ostringstream out;
  BRepTools::Write(shape,out,false,false,TopTools_FormatVersion_CURRENT);
  return out.str();
}
static ProbeState currentProbe() {
  const auto state=BRepGProp_Gauss::SetCancellationProbe(nullptr,nullptr);
  BRepGProp_Gauss::SetCancellationProbe(state.Probe,state.Data);
  return state;
}
static void outerProbe(void* data) {++*static_cast<unsigned*>(data);}

struct CountedProbe {
  FCADContext* context;
  ProbeState previous{nullptr,nullptr};
  unsigned calls=0,cancelAt=50;
  static void poll(void* data) {
    auto& self=*static_cast<CountedProbe*>(data);
    ++self.calls;
    if(self.calls==self.cancelAt)fcad_context_cancel(self.context);
    // Forward the actual adapter probe; its existing atomic cancellation throws
    // Failure(FCAD_CANCELLED). This is not a pre-cancelled operation.
    if(self.previous.Probe)self.previous.Probe(self.previous.Data);
  }
};
class CountedScope {
  CountedProbe& counter;
 public:
  explicit CountedScope(CountedProbe& value):counter(value) {
    counter.previous=BRepGProp_Gauss::SetCancellationProbe(&CountedProbe::poll,&counter);
    expect(counter.previous.Probe!=nullptr,"Actual adapter probe was not installed.");
  }
  ~CountedScope()noexcept {
    BRepGProp_Gauss::SetCancellationProbe(counter.previous.Probe,counter.previous.Data);
  }
};

static void cancelledQuadrature(const TopoDS_Shape& source,bool surface) {
  const auto before=serialized(source);
  FCADContext context;
  FCADFailure failure{};
  FCADShape* output=nullptr;
  bool surfaceReportPublished=false;
  CountedProbe counter{&context};
  unsigned outerCalls=0;
  const auto outside=BRepGProp_Gauss::SetCancellationProbe(&outerProbe,&outerCalls);
  const auto started=std::chrono::steady_clock::now();
  const auto status=run(&context,&failure,[&] {
    expect(!context.cancelled.load(),"Operation was pre-cancelled.");
    CountedScope counted(counter);
    if(surface) {
      GProp_GProps properties;
      BRepGProp::SurfaceProperties(source,properties,1e-9);
      surfaceReportPublished=true;
    } else {
      // Real production publication: bounds/validity plus adaptive volume and
      // area inside info(), followed by a single immutable handle assignment.
      publish(&context,source,&output,false);
    }
  });
  const auto elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
  const auto restored=currentProbe();
  expect(restored.Probe==&outerProbe && restored.Data==&outerCalls,"Caller probe was not restored after cancellation.");
  BRepGProp_Gauss::SetCancellationProbe(outside.Probe,outside.Data);
  expect(status==FCAD_CANCELLED,"In-GProp cancellation did not return FCAD_CANCELLED.");
  expect(counter.calls==counter.cancelAt,"Cancellation was not triggered inside active quadrature.");
  expect(output==nullptr && !surfaceReportPublished,"A cancelled operation published an output.");
  expect(serialized(source)==before,"Cancelled quadrature mutated source BRep bytes.");
  std::cout << "{\"phase\":\"" << (surface?"surface":"volume/publication")
            << "\",\"status\":" << status << ",\"polls\":" << counter.calls
            << ",\"seconds\":" << elapsed << ",\"source_unchanged\":true,\"output_unpublished\":true}\n";
}

static void restoredAndThreadLocal() {
  FCADContext outer,inner;
  unsigned calls=0;
  const auto original=BRepGProp_Gauss::SetCancellationProbe(&outerProbe,&calls);
  {
    GPropCancellationScope first(&outer);
    expect(currentProbe().Data==&outer,"Outer task scope missing.");
    {GPropCancellationScope second(&inner);expect(currentProbe().Data==&inner,"Nested task scope missing.");}
    expect(currentProbe().Data==&outer,"Nested scope did not restore outer task.");
    bool threadEmpty=false,threadRestored=false,threadCancelled=false;
    std::thread other([&] {
      threadEmpty=currentProbe().Probe==nullptr;
      {GPropCancellationScope third(&inner);expect(currentProbe().Data==&inner,"Independent thread scope missing.");
       fcad_context_cancel(&inner);const auto active=currentProbe();try{active.Probe(active.Data);}catch(const Failure& error){threadCancelled=error.status==FCAD_CANCELLED;}}
      threadRestored=currentProbe().Probe==nullptr;
    });
    other.join();
    expect(threadEmpty&&threadRestored&&threadCancelled,"Cancellation probe leaked between threads or failed its own context.");
    expect(!outer.cancelled.load(),"Other thread cancelled the current context.");
    {const auto active=currentProbe();active.Probe(active.Data);}
    {GPropCancellationScope empty(nullptr);expect(currentProbe().Probe==nullptr,"Null context inherited an unrelated probe.");}
    expect(currentProbe().Data==&outer,"Null scope did not restore the caller context.");
    expect(currentProbe().Data==&outer,"Other thread changed current task scope.");
  }
  expect(currentProbe().Probe==&outerProbe&&currentProbe().Data==&calls,"Successful unwind did not restore caller probe.");
  BRepGProp_Gauss::SetCancellationProbe(original.Probe,original.Data);
}

int main(int argc,char** argv) {
  try {
    expect(argc==2,"Pass an exact BRep fixture with more than 50 quadrature polls.");
    BRep_Builder builder;TopoDS_Shape source;
    expect(BRepTools::Read(source,argv[1],builder),"Fixture read failed.");
    expect(!source.IsNull(),"Fixture is empty.");
    restoredAndThreadLocal();
    FCADContext priorContext;FCADFailure priorFailure{};FCADShape* accepted=nullptr;
    expect(run(&priorContext,&priorFailure,[&]{publish(&priorContext,source,&accepted,false);})==FCAD_OK,"Prior accepted publication failed.");
    const auto priorBytes=serialized(accepted->value);const auto priorInfo=accepted->report;
    cancelledQuadrature(accepted->value,false);
    cancelledQuadrature(accepted->value,true);
    expect(serialized(accepted->value)==priorBytes,"Prior accepted source changed.");
    expect(std::memcmp(&priorInfo,&accepted->report,sizeof(priorInfo))==0,"Prior accepted info changed.");
    fcad_shape_release(accepted);
    // A fresh uncancelled task must still publish the same exact shape after
    // both cancellations; a poisoned TLS/context must not affect later work.
    FCADContext fresh;FCADFailure failure{};FCADShape* output=nullptr;
    FCADStatus freshStatus=FCAD_OPERATION_FAILED;
    std::thread independent([&]{freshStatus=run(&fresh,&failure,[&]{publish(&fresh,source,&output,false);});});
    independent.join();
    expect(freshStatus==FCAD_OK,"Independent-thread task failed after cancellation or gate remained locked.");
    expect(output!=nullptr,"Fresh task did not publish its valid output.");
    expect(serialized(output->value)==serialized(source),"Fresh publication changed exact source.");
    fcad_shape_release(output);
    std::cout << "{\"scope_restore\":true,\"thread_isolation\":true,\"next_task_success\":true,\"different_thread_global_gate_released\":true,\"prior_accepted_info_unchanged\":true,\"null_context_restore\":true}\n";
    return 0;
  }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
