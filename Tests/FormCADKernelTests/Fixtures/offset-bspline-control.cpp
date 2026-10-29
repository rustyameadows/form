// Rebuild the two BRep fixtures with the pinned OCCT headers/libraries and run
// this executable with this directory as its sole argument.
#include "offset-bspline-control.hxx"
#include <BRepTools.hxx>
#include <filesystem>

int main(int argc,char**argv) {
  if(argc!=2)return 1;
  const auto control=makeSpanIntegrationAnalyticControl();
  const std::filesystem::path destination=argv[1];
  BRepTools::Write(control.shape,(destination/"offset-bspline-holed.brep").c_str());
  BRepTools::Write(control.reversedShape,(destination/"offset-bspline-holed-reversed.brep").c_str());
}
