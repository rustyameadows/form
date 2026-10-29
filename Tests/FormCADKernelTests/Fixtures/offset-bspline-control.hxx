#pragma once
// Reproducible analytic regression fixture: exact planar OffsetSurface over a cubic BSpline
// basis with internal U/V knots, a rectangular through-hole, and both cap
// orientations. No approximation, knot removal, source files, or app state.
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Builder.hxx>
#include <Geom2d_BezierCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_OffsetSurface.hxx>
#include <NCollection_Array1.hxx>
#include <NCollection_Array2.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Wire.hxx>
#include <TopLoc_Location.hxx>
#include <gp_Pnt.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Vec.hxx>
#include <array>
#include <stdexcept>

struct SpanIntegrationAnalyticControl {
  TopoDS_Shape shape;
  TopoDS_Shape reversedShape;
  double expectedVolumeMM3 = 1080.;
  double expectedAreaMM2 = 852.;
};

inline SpanIntegrationAnalyticControl makeSpanIntegrationAnalyticControl() {
  // Degree3 with knots0,.5,1 and multiplicities4,1,4:5 poles per axis.
  // Greville-position poles reproduce S(u,v)=(20u,12v,0) exactly.
  const std::array<double,5> greville = {0., 1./6., .5, 5./6., 1.};
  NCollection_Array2<gp_Pnt> poles(1,5,1,5);
  for (int u = 1; u <= 5; ++u)
    for (int v = 1; v <= 5; ++v)
      poles.SetValue(u,v,gp_Pnt(20.*greville[u-1],12.*greville[v-1],0.));
  NCollection_Array1<double> knots(1,3);
  knots.SetValue(1,0.); knots.SetValue(2,.5); knots.SetValue(3,1.);
  NCollection_Array1<int> mults(1,3);
  mults.SetValue(1,4); mults.SetValue(2,1); mults.SetValue(3,4);
  occ::handle<Geom_BSplineSurface> basis = new Geom_BSplineSurface(
      poles,knots,knots,mults,mults,3,3,false,false);
  occ::handle<Geom_Surface> surface = new Geom_OffsetSurface(basis,2.);
  auto wire = [&](const std::array<gp_Pnt2d,4>& points) {
    BRepBuilderAPI_MakeWire builder;
    BRep_Builder topology;
    for (std::size_t i = 0; i != points.size(); ++i) {
      const gp_Pnt2d a = points[i], b = points[(i+1)%points.size()];
      NCollection_Array1<gp_Pnt> threeD(1,2);
      threeD.SetValue(1,gp_Pnt(20.*a.X(),12.*a.Y(),2.));
      threeD.SetValue(2,gp_Pnt(20.*b.X(),12.*b.Y(),2.));
      NCollection_Array1<gp_Pnt2d> twoD(1,2);
      twoD.SetValue(1,a); twoD.SetValue(2,b);
      occ::handle<Geom_Curve> curve = new Geom_BezierCurve(threeD);
      occ::handle<Geom2d_Curve> pcurve = new Geom2d_BezierCurve(twoD);
      // Both curves share exact linear parameter0...1, so the pcurve and
      // world-space curve agree without projection or SameParameter repair.
      TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(curve).Edge();
      topology.UpdateEdge(edge,pcurve,surface,TopLoc_Location(),1e-7);
      topology.Range(edge,surface,TopLoc_Location(),0.,1.);
      builder.Add(edge);
      if (!builder.IsDone()) throw std::runtime_error("Analytic wire creation failed");
    }
    return builder.Wire();
  };
  const TopoDS_Wire outer = wire({gp_Pnt2d(0.,0.),gp_Pnt2d(1.,0.),
                                 gp_Pnt2d(1.,1.),gp_Pnt2d(0.,1.)});
  // Clockwise6×4 mm hole:x7...13,y4...8. It crosses both .5 knot lines.
  const TopoDS_Wire hole = wire({gp_Pnt2d(.35,1./3.),gp_Pnt2d(.35,2./3.),
                                gp_Pnt2d(.65,2./3.),gp_Pnt2d(.65,1./3.)});
  BRepBuilderAPI_MakeFace face(surface,outer,true);
  face.Add(hole);
  if (!face.IsDone()) throw std::runtime_error("Analytic holed face creation failed");
  BRepPrimAPI_MakePrism prism(face.Face(),gp_Vec(0.,0.,5.),true,false);
  if (!prism.IsDone()) throw std::runtime_error("Analytic holed prism creation failed");
  SpanIntegrationAnalyticControl result;
  result.shape = prism.Shape();
  result.reversedShape = result.shape.Reversed();
  // Volume=(20*12-6*4)*5=1080;area=2*216+(64+20)*5=852.
  // reversedShape has signed volume-1080 and the same unsigned surface area.
  return result;
}
