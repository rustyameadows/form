#include <STEPCAFControl_Writer.hxx>
#include <STEPConstruct_ExternRefs.hxx>
#include <StepBasic_ProductDefinition.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <TDataStd_Name.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRep_Builder.hxx>
#include <TopoDS_Compound.hxx>
#include <TopExp_Explorer.hxx>
#include <gp_Trsf.hxx>
#include <Interface_InterfaceModel.hxx>
#include <XSControl_WorkSession.hxx>
#include <Quantity_Color.hxx>
#include <Quantity_TypeOfColor.hxx>
#include <cassert>
#include <iostream>
int main(int argc,char**argv){
 assert(argc==3);occ::handle<TDocStd_Document> doc=new TDocStd_Document("LAB fixture");auto shapes=XCAFDoc_DocumentTool::ShapeTool(doc->Main());auto colors=XCAFDoc_DocumentTool::ColorTool(doc->Main());
 auto box=BRepPrimAPI_MakeBox(10,20,30).Shape(),cylinder=BRepPrimAPI_MakeCylinder(4,12).Shape();auto boxLabel=shapes->AddShape(box,false),cylinderLabel=shapes->AddShape(cylinder,false);TDataStd_Name::Set(boxLabel,"Copper bracket");TDataStd_Name::Set(cylinderLabel,"Steel spacer");colors->SetColor(boxLabel,Quantity_Color(0.7,0.15,0.05,Quantity_TOC_RGB),XCAFDoc_ColorSurf);colors->SetColor(cylinderLabel,Quantity_Color(0.25,0.3,0.35,Quantity_TOC_RGB),XCAFDoc_ColorSurf);
 TopExp_Explorer face(box,TopAbs_FACE);colors->SetColor(face.Current(),Quantity_Color(0.05,0.15,0.9,Quantity_TOC_RGB),XCAFDoc_ColorSurf);
 BRep_Builder b;TopoDS_Compound empty;b.MakeCompound(empty);auto sub=shapes->AddShape(empty,true);TDataStd_Name::Set(sub,"Nested hardware");gp_Trsf move;move.SetTranslation(gp_Vec(40,5,6));auto first=shapes->AddComponent(sub,boxLabel,TopLoc_Location(move));TDataStd_Name::Set(first,"Bracket left");move.SetTranslation(gp_Vec(65,5,6));auto second=shapes->AddComponent(sub,boxLabel,TopLoc_Location(move));TDataStd_Name::Set(second,"Bracket right");move.SetTranslation(gp_Vec(0,0,50));auto third=shapes->AddComponent(sub,cylinderLabel,TopLoc_Location(move));TDataStd_Name::Set(third,"Spacer occurrence");
 TopoDS_Compound rootEmpty;b.MakeCompound(rootEmpty);auto root=shapes->AddShape(rootEmpty,true);TDataStd_Name::Set(root,"Clock movement assembly");move.SetTranslation(gp_Vec(100,200,300));auto nested=shapes->AddComponent(root,sub,TopLoc_Location(move));TDataStd_Name::Set(nested,"Hardware group");shapes->UpdateAssemblies();
 STEPCAFControl_Writer writer;writer.SetNameMode(true);writer.SetColorMode(true);assert(writer.Transfer(doc,STEPControl_AsIs));assert(writer.Write(argv[1])==IFSelect_RetDone);
 auto model=writer.ChangeWriter().WS()->Model();occ::handle<StepBasic_ProductDefinition> pd;for(int i=1;i<=model->NbEntities();++i){pd=occ::down_cast<StepBasic_ProductDefinition>(model->Value(i));if(!pd.IsNull())break;}assert(!pd.IsNull());STEPConstruct_ExternRefs refs(writer.ChangeWriter().WS());refs.AddExternRef("../never-read-this.step",pd,"STEP AP214");assert(refs.WriteExternRefs(0)>0);assert(writer.Write(argv[2])==IFSelect_RetDone);std::cout<<"generated fixtures\n";
}
