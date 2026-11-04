import Foundation
import FormCore
import FormGeometry
import FormGraphics
import simd

/// Reusable physical layers for wrapped panels and stepped inset pockets. Every
/// layer goes through the ordinary paper/material renderer; no cover shortcut.
@MainActor enum SheetPanelLayerGeometry {
  struct Layer {
    var id:String,size:Point2,polygon:[Point2],cutouts:[PaperPanelCutout],stock:PaperStock
    var front:ResolvedSheetAssemblyFace?,back:ResolvedSheetAssemblyFace?
    var position:SIMD3<Double> = .zero,rotation:SIMD3<Double> = .zero
    var finishes:[PaperFinishAssignment] = []
    var frontMapping:Affine2? = nil
    var reverseArtwork:Bool=false
  }
  static func rectangle(_ size:Point2,origin:Point2 = .init(),radius:Double=0)->[Point2] {
    let r=min(max(0,radius),min(size.x,size.y)/2)
    guard r>1e-8 else{return [.init(origin.x,origin.y),.init(origin.x+size.x,origin.y),.init(origin.x+size.x,origin.y+size.y),.init(origin.x,origin.y+size.y)]}
    var polygon=[Point2]()
    for (x,y,a) in [(size.x-r,r,-Double.pi/2),(size.x-r,size.y-r,0),(r,size.y-r,Double.pi/2),(r,r,Double.pi)] {
      for i in 0...5 {let angle=a+Double(i)*Double.pi/10;polygon.append(.init(origin.x+x+r*cos(angle),origin.y+y+r*sin(angle)))}
    };return polygon
  }
  static func stock(_ source:PaperStock,thickness:Double)->PaperStock {
    var result=source;let thickness=thickness<0.01 && thickness>=0.01-1e-10 ? 0.01:thickness
    result.thicknessMM=thickness
    if let plies=source.plies,!plies.isEmpty {
      let ratio=thickness/source.resolvedThicknessMM
      result.plies=plies.map{var p=$0;p.thicknessMM *= ratio;return p}
    };return result
  }
  static func layers(_ plane:ResolvedSheetAssemblyPlane)throws->[Layer] {
    guard let features=plane.features else{return [.init(id:"face",size:plane.size,polygon:rectangle(plane.size),cutouts:[],stock:plane.stock,front:plane.front,back:plane.back,finishes:plane.finishes)]}
    let thickness=plane.stock.resolvedThicknessMM,wrap=features.wrap,recesses=features.recesses
    let rectangular=features.outline == rectangle(plane.size)
    let polygon=rectangular ? rectangle(plane.size,radius:wrap?.cornerRadiusMM ?? 0):features.outline
    let cutouts=features.cutouts
    func aperture(_ recess:ResolvedSheetPanelRecess)->PaperPanelCutout {
      .init(id:"recess:"+recess.id,polygon:rectangle(recess.size,origin:recess.origin,radius:recess.cornerRadiusMM),kind:.window)
    }
    var result=[Layer]()
    // Slabs share exact contact planes. Their aperture set changes only at the
    // authored pocket floors, exposing a real lower face and vertical rim.
    var plyCuts=[Double](),plyDepth=0.0
    if !recesses.isEmpty {for ply in (plane.stock.plies ?? []).reversed() {plyDepth+=ply.thicknessMM;plyCuts.append(plyDepth)}}
    var depths=[Double]()
    for cut in ([0.0,thickness]+recesses.map(\.depthMM)+plyCuts).sorted() where depths.last.map({cut-$0>1e-10}) ?? true {depths.append(cut)}
    func slice(high:Double,low:Double)->PaperStock {
      guard !recesses.isEmpty,let plies=plane.stock.plies,!plies.isEmpty else{return stock(plane.stock,thickness:low-high)}
      var depth=0.0
      for ply in plies.reversed() {
        let end=depth+ply.thicknessMM
        if (high+low)/2<=end+1e-9 {
          var value=stock(plane.stock,thickness:low-high);value.plies=nil;value.name=ply.name
          value.gsm=ply.gsm ?? plane.stock.gsm
          var profile=ply.profile ?? plane.stock.profile ?? PaperSurfaceProfile()
          if profile.edgeAppearance == nil {profile.edgeAppearance=plane.stock.profile?.edgeAppearance}
          profile.color=ply.profile?.color ?? ply.color;value.profile=profile;return value
        };depth=end
      };return stock(plane.stock,thickness:low-high)
    }
    for index in 0..<(depths.count-1) {
      let high=depths[index],low=depths[index+1],center=thickness/2-(high+low)/2
      let holes=cutouts+recesses.filter{$0.depthMM>high+1e-9}.map(aperture)
      result.append(.init(id:index==0 ? "face":"core:\(index)",size:plane.size,polygon:polygon,cutouts:holes,
        stock:slice(high:high,low:low),front:wrap==nil && index==0 ? plane.front:nil,back:index==depths.count-2 ? plane.back:nil,
        position:.init(0,0,center),finishes:wrap==nil && index==0 ? plane.finishes:[]))
    }
    for recess in recesses {
      guard let insert=recess.insert else{continue}
      let d=insert.stock.resolvedThicknessMM
      result.append(.init(id:"insert:"+recess.id,size:recess.size,
        polygon:rectangle(recess.size,radius:recess.cornerRadiusMM),cutouts:[],stock:insert.stock,
        front:insert.face,back:nil,position:.init(recess.origin.x,-recess.origin.y,thickness/2-recess.depthMM+d/2)))
    }
    guard let wrap else{return result}
    let caliper=wrap.stock.resolvedThicknessMM
    result.append(.init(id:"wrap:face",size:plane.size,polygon:polygon,cutouts:cutouts+recesses.map(aperture),stock:wrap.stock,
      front:plane.front,back:nil,position:.init(0,0,(thickness+caliper)/2),finishes:plane.finishes))
    // Offset each corner by the intersection of its neighboring edge normals.
    // This produces mitered turn-ins instead of four overlapping rectangles.
    let area=polygon.indices.reduce(0.0){sum,i in let a=polygon[i],b=polygon[(i+1)%polygon.count];return sum+a.x*b.y-b.x*a.y}
    let sign=area>=0 ? 1.0:-1.0
    var inward=[SIMD2<Double>](),directions=[SIMD2<Double>]()
    for i in polygon.indices {let a=polygon[i],b=polygon[(i+1)%polygon.count],v=SIMD2(b.x-a.x,b.y-a.y),u=simd_normalize(v);directions.append(u);inward.append(SIMD2(-u.y,u.x)*sign)}
    let amount=min(wrap.turnInMM,min(plane.size.x,plane.size.y)/2-0.01)
    let inset=polygon.indices.map { i -> Point2 in
      if rectangular,(wrap.cornerRadiusMM<=amount) {
        return .init(min(max(polygon[i].x,amount),plane.size.x-amount),min(max(polygon[i].y,amount),plane.size.y-amount))
      }
      let prior=(i+polygon.count-1)%polygon.count,n=inward[i]+inward[prior]
      let denom=simd_dot(n,inward[i]);let delta=abs(denom)>1e-8 ? n*(amount/denom):inward[i]*amount
      return .init(polygon[i].x+delta.x,polygon[i].y+delta.y)
    }
    for i in polygon.indices {
      let next=(i+1)%polygon.count,a=polygon[i],b=polygon[next],length=hypot(b.x-a.x,b.y-a.y)
      // A vertical strip follows every perimeter segment, including rounded
      // corners. Its front points outwards and its grain uses physical mm.
      result.append(.init(id:"wrap:edge:\(i)",size:.init(length,thickness),polygon:rectangle(.init(length,thickness)),cutouts:[],stock:wrap.stock,front:plane.front,back:nil,
        position:.init(a.x-inward[i].x*caliper/2,-a.y+inward[i].y*caliper/2,-thickness/2),rotation:.init(-Double.pi/2,0,-atan2(b.y-a.y,b.x-a.x)),finishes:plane.finishes,
        frontMapping:.init(a:directions[i].x,b:inward[i].x,c:directions[i].y,d:inward[i].y,
          tx:-(a.x*directions[i].x+a.y*directions[i].y),ty:thickness-a.x*inward[i].x-a.y*inward[i].y)))
      if amount>0 {
        var turn=[Point2]()
        for p in [a,b,inset[next],inset[i]] where turn.last.map({hypot($0.x-p.x,$0.y-p.y)>1e-9}) ?? true {turn.append(p)}
        if let first=turn.first,let last=turn.last,hypot(first.x-last.x,first.y-last.y)<1e-9 {turn.removeLast()}
        guard turn.count>=3 else{continue}
        result.append(.init(id:"wrap:turn-in:\(i)",size:plane.size,
          polygon:turn,cutouts:[],stock:wrap.stock,front:plane.front,back:nil,
          position:.init(0,0,-(thickness+caliper)/2),finishes:plane.finishes,
          frontMapping:.init(a:1-2*inward[i].x*inward[i].x,b:-2*inward[i].x*inward[i].y,
            c:-2*inward[i].x*inward[i].y,d:1-2*inward[i].y*inward[i].y,
            tx:inward[i].x*(2*(a.x*inward[i].x+a.y*inward[i].y)-thickness),
            ty:inward[i].y*(2*(a.x*inward[i].x+a.y*inward[i].y)-thickness)),reverseArtwork:true))
      }
    }
    return result
  }
}
