import AppKit
import FormCore
import FormGeometry

@MainActor enum StarterTextileGeometry {
  static func make(_ o: ProductObject, project: Project, assets: URL, limit: Int) -> MeshNode {
    let root = MeshNode(), w = o["width"], d = o["depth"], y = o["loft"]
    let mat = MerchandiseGeometry.cloth(o, project, assets, limit)
    let trim = MerchandiseGeometry.material(o.textile?.trimMaterialID ?? o.materialID, project)
    func path(_ points: [Point2]) -> NSBezierPath {
      let p = NSBezierPath()
      p.move(to: .init(x: points[0].x / 100, y: -points[0].y / 100))
      for v in points.dropFirst() { p.line(to: .init(x: v.x / 100, y: -v.y / 100)) }
      p.close(); return p
    }
    func panel(_ p: NSBezierPath, _ height: Double, _ base: Double, _ name: String, _ m: MeshMaterial? = nil) {
      root.addChildNode(MerchandiseGeometry.shape(p, height: height, y: base, material: m ?? mat, name: name))
    }
    func rect(_ width: Double, _ height: Double, _ z: Double = 0) -> NSBezierPath {
      path([.init(-width/2, z-height/2), .init(width/2, z-height/2), .init(width/2, z+height/2), .init(-width/2, z+height/2)])
    }
    switch o.recipeID {
    case "pulloverHoodie":
      let s = o["sleeveLength"], sw = o["sleeveWidth"], hw = o["hoodWidth"], hd = o["hoodHeight"]
      panel(path([.init(-w*0.31, -d/2), .init(w*0.31, -d/2), .init(w/2+s, -d*0.33),
        .init(w/2+s, -d*0.33+sw), .init(w/2, -d*0.1), .init(w*0.49, d/2),
        .init(-w*0.49, d/2), .init(-w/2, -d*0.1), .init(-w/2-s, -d*0.33+sw),
        .init(-w/2-s, -d*0.33)]), y-1, 1, "Approximate fleece body and long sleeves")
      let hood = NSBezierPath(roundedRect: NSRect(x: -hw/200, y: d/200-0.25,
        width: hw/100, height: hd/100), xRadius: hw/240, yRadius: hw/240)
      panel(hood, y*0.6, 1, "Open laid-out hood")
      let lining = trim.copy() as! MeshMaterial
      lining.diffuse.contents = NSColor(hex:project.material(o.materialID).color).blended(withFraction:0.2,of:.black)
      panel(NSBezierPath(ovalIn:NSRect(x:-hw*0.3/100,y:(d/2+hd*0.12)/100,width:hw*0.6/100,height:hd*0.68/100)),
        0.5,y*0.6+1,"Hood lining visible through opening",lining)
      panel(rect(w*0.98, o["ribHeight"], d/2-o["ribHeight"]/2), 2, y, "Ribbed waistband", trim)
      let pw=o["pocketWidth"], ph=o["pocketHeight"], z=d*0.23
      panel(path([.init(-pw*0.32,z-ph/2), .init(pw*0.32,z-ph/2), .init(pw/2,z),
        .init(pw/2,z+ph/2), .init(-pw/2,z+ph/2), .init(-pw/2,z)]), 2, y, "Pouch pocket / artwork interruption")
      for sign in [-1.0, 1.0] {
        root.addChildNode(MerchandiseGeometry.tube([.init(sign*hw*0.18,y+1,-d*0.48), .init(sign*hw*0.12,y+1,-d*0.25)],
          radius: 1.8, material: trim, name: "Hood drawcord"))
      }
    case "cuffedBeanie":
      let crown = NSBezierPath()
      crown.move(to: .init(x: -w/200, y: -d/200))
      crown.line(to: .init(x: w/200, y: -d/200))
      crown.line(to: .init(x: w/200, y: 0))
      crown.curve(to: .init(x: 0, y: d/200), controlPoint1: .init(x: w/200, y: d/250), controlPoint2: .init(x: w/400, y: d/200))
      crown.curve(to: .init(x: -w/200, y: 0), controlPoint1: .init(x: -w/400, y: d/200), controlPoint2: .init(x: -w/200, y: d/250))
      crown.close()
      panel(crown, y-1, 1, "Flat knitted crown")
      panel(rect(w, o["cuffHeight"], d/2-o["cuffHeight"]/2), 3, y, "Turned cuff", trim)
      for i in -18...18 {
        let x=Double(i)*w/40
        root.addChildNode(MerchandiseGeometry.tube([.init(x,y+3.2,d/2-o["cuffHeight"]+3), .init(x,y+3.2,d/2-3)],
          radius: 0.4, material: trim, name: "Cuff rib"))
      }
    case "hemmedTextile":
      panel(rect(w,d), max(0.2,y-1), 1, "Hemmed flat cloth")
      let h=o["hem"]
      root.addChildNode(MerchandiseGeometry.tube([.init(-w/2+h,y+0.1,-d/2+h), .init(w/2-h,y+0.1,-d/2+h),
        .init(w/2-h,y+0.1,d/2-h), .init(-w/2+h,y+0.1,d/2-h), .init(-w/2+h,y+0.1,-d/2+h)],
        radius: 0.25, material: trim, name: "Folded hem stitch line"))
    default: break
    }
    return root
  }
}
