#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepTools.hxx>
#include <TopoDS_Shape.hxx>
#include <string>
int main(int argc,char**argv){if(argc!=2)return 2;std::string folder=argv[1];
 auto write=[&](const char*name,const TopoDS_Shape& shape){return BRepTools::Write(shape,(folder+"/"+name+".brep").c_str());};
 if(!write("box",BRepPrimAPI_MakeBox(17,23,31).Shape()))return 3;
 if(!write("cylinder",BRepPrimAPI_MakeCylinder(9,27).Shape()))return 3;
 if(!write("cone",BRepPrimAPI_MakeCone(12,4,30).Shape()))return 3;
 if(!write("sphere",BRepPrimAPI_MakeSphere(11).Shape()))return 3;
 if(!write("torus",BRepPrimAPI_MakeTorus(22,5).Shape()))return 3;
 auto box=BRepPrimAPI_MakeBox(17,23,31).Shape();auto hole=BRepPrimAPI_MakeCylinder(4,40).Shape();
 if(!write("cut",BRepAlgoAPI_Cut(box,hole).Shape()))return 3;return 0;}
