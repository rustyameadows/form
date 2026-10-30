import Foundation
import FormCore

/// Conservative artwork bounds checks, not press certification or glyph-level trapping.
@MainActor enum PaperProductionReview {
  static func inspect(object:ProductObject,project:Project,minimumSafetyMM:Double=2)throws->[String:Any] {
    let d=try PaperConstruction.definition(for:object),net=try d.net()
    var issues:[[String:Any]]=[]
    for side in PaperFinishAssignment.Side.allCases {
      guard let art=project.paperArtwork(for:object,inside:side == .inside) else{continue}
      let resolved=project.resolvingSwatches(in:try project.resolvingComponents(in:art)).renderDefinition
      for e in resolved.elements where e.kind != "group" && e.hidden != true {
        let b=resolved.bounds(of:e)
        guard [b.x,b.y,b.width,b.height].allSatisfy(\.isFinite) else{continue}
        if e.kind == "text" {
          let nearCut=net.cutEdges.filter{distance(b,$0.start,$0.end)<minimumSafetyMM}
          let nearFold=net.folds.filter{distance(b,$0.start,$0.end)<minimumSafetyMM}
          if !nearCut.isEmpty {issues.append(["code":"typeNearCut","severity":"warning","side":side.rawValue,"element_id":e.id.uuidString,"minimum_safety_mm":minimumSafetyMM,"edge_ids":nearCut.map(\.id),"message":"Text frame is within the declared cut safety margin; review actual glyphs and vendor tolerances."])}
          if !nearFold.isEmpty {issues.append(["code":"typeNearCrease","severity":"warning","side":side.rawValue,"element_id":e.id.uuidString,"minimum_safety_mm":minimumSafetyMM,"fold_ids":nearFold.map(\.id),"message":"Text frame is close to a fold; review the assembled reading surface and crease tolerance."])}
        }
        let glue=net.panels.filter {panel in
          guard panel.role == .glue else{return false}
          let p=panel.bounds
          return b.x<p.x+p.width && b.x+b.width>p.x && b.y<p.y+p.height && b.y+b.height>p.y
        }
        if !glue.isEmpty {issues.append(["code":"inkInGlueArea","severity":"warning","side":side.rawValue,"element_id":e.id.uuidString,"panel_ids":glue.map(\.id),"message":"Artwork bounds overlap a declared glue area; confirm ink/coating exclusion with the supplier."])}
        if issues.count>=2000 {issues.append(["code":"boundedSafetyReview","severity":"warning","message":"Additional safety findings were omitted after2000 issues."]);break}
      }
    }
    return ["issues":issues,"coverage":"Visible non-group artwork frame bounds in canonical millimeters, against declared cuts, crease axes and glue-panel bounds. This is conservative placement review, not glyph outlines, trapping, ink adhesion or vendor approval.","manufacturing_verified":false]
  }
  private static func distance(_ r:Rect2,_ a:Point2,_ b:Point2)->Double {
    let corners=[Point2(r.x,r.y),.init(r.x+r.width,r.y),.init(r.x+r.width,r.y+r.height),.init(r.x,r.y+r.height)]
    func inside(_ p:Point2)->Bool{p.x>=r.x && p.x<=r.x+r.width && p.y>=r.y && p.y<=r.y+r.height}
    if inside(a)||inside(b){return 0}
    func cross(_ p:Point2,_ q:Point2,_ z:Point2)->Double{(q.x-p.x)*(z.y-p.y)-(q.y-p.y)*(z.x-p.x)}
    for (p,q) in zip(corners,Array(corners.dropFirst())+[corners[0]]) {
      let c1=cross(a,b,p),c2=cross(a,b,q),c3=cross(p,q,a),c4=cross(p,q,b)
      if c1*c2<=0 && c3*c4<=0 && max(a.x,b.x)>=min(p.x,q.x) && max(p.x,q.x)>=min(a.x,b.x) && max(a.y,b.y)>=min(p.y,q.y) && max(p.y,q.y)>=min(a.y,b.y){return 0}
    }
    func pointSegment(_ p:Point2,_ x:Point2,_ y:Point2)->Double {
      let dx=y.x-x.x,dy=y.y-x.y,den=dx*dx+dy*dy
      let t=den>0 ? min(1,max(0,((p.x-x.x)*dx+(p.y-x.y)*dy)/den)):0
      return hypot(p.x-x.x-t*dx,p.y-x.y-t*dy)
    }
    let pointRect:[Double]=[a,b].map{p in hypot(max(0,max(r.x-p.x,p.x-r.x-r.width)),max(0,max(r.y-p.y,p.y-r.y-r.height)))}
    return min(pointRect.min() ?? 0,corners.map{pointSegment($0,a,b)}.min() ?? 0)
  }
}
