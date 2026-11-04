import Foundation

extension PaperPanel {
  /// Physical feature coordinates are panel-local, while hinge matrices consume
  /// canonical flat-net coordinates. Keep that translation outside deformation.
  func physicalBoundarySamples(stock:PaperStock,variables:[String:Double],worldMatrix:[Double])throws->[Vector3] {
    guard worldMatrix.count==16 else{throw FormError.invalid("A physical panel boundary requires its complete flat-to-world matrix.")}
    let bounds=self.bounds,size=Point2(bounds.width,bounds.height)
    let physical=try features?.resolved(size:size,stock:stock,variables:variables){_,_ in nil}
    let caliper=physical?.0.resolvedThicknessMM ?? stock.resolvedThicknessMM
    let skin=physical?.1.wrap?.stock.resolvedThicknessMM ?? 0,half=caliper/2+skin
    if let flex=physical?.1.flex {
      return flex.boundarySamples(size:size,halfCaliperMM:half,outsetMM:skin,worldMatrix:worldMatrix)
        .map{.init($0.x+bounds.x,$0.y-bounds.y,$0.z)}
    }
    if skin>0 {
      return [bounds.x-skin,bounds.x+bounds.width+skin].flatMap{x in
        [-bounds.y-bounds.height-skin,-bounds.y+skin].flatMap{y in [-half,half].map{Vector3(x,y,$0)}}
      }
    }
    return polygon.flatMap{p in [-half,half].map{Vector3(p.x,-p.y,$0)}}
  }
}
