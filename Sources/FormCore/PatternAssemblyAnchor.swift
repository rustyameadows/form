import Foundation

/// Physical material point, independent of a particular tessellation's triangle
/// IDs. Source edits/rebuilds resolve it again; leaving the piece is an error.
public struct PatternAssemblyAnchor:Codable,Equatable,Sendable {
  public var panel:PatternPanelID
  public var materialPointMm:Point2
  public var normalOffsetMm:Double
  public init(panel:PatternPanelID,materialPointMm:Point2,normalOffsetMm:Double = 0) {self.panel=panel;self.materialPointMm=materialPointMm;self.normalOffsetMm=normalOffsetMm}
  public func resolve(in product:PatternAssemblyProduct)throws -> ClothSurfaceAnchor {
    guard let panel=product.panels.first(where:{$0.id==self.panel}),materialPointMm.x.isFinite,materialPointMm.y.isFinite,normalOffsetMm.isFinite,abs(normalOffsetMm)<=1000 else {throw FormError.invalid("Choose a finite material point on an existing assembly panel.")}
    let points=product.materialPointsMm
    for (index,t) in product.study.mesh.triangles.enumerated() where product.study.mesh.panelIDs?[t.a]==panel.panelIndex {
      let a=points[t.a],b=points[t.b],c=points[t.c],u=b.x-a.x,v=b.y-a.y,x=c.x-a.x,y=c.y-a.y,det=u*y-x*v
      guard abs(det)>1e-12 else {continue}
      let dx=materialPointMm.x-a.x,dy=materialPointMm.y-a.y,q=(dx*y-dy*x)/det,r=(u*dy-v*dx)/det,p=1-q-r
      if min(p,q,r)>=(-1e-9) {let sum=max(0,p)+max(0,q)+max(0,r);return .init(triangle:index,weights:.init(max(0,p)/sum,max(0,q)/sum,max(0,r)/sum),normalOffsetMm:normalOffsetMm)}
    }
    throw FormError.invalid("The material anchor lies outside this panel or inside a source hole after rebuilding. Reassign it explicitly.")
  }
  public func placement(in product:PatternAssemblyProduct,frame:ClothFrame)throws -> ClothSurfacePlacement {try resolve(in:product).placement(mesh:product.study.mesh,frame:frame)}
}
