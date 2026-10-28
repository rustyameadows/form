import AppKit
import FormCore
import FormGraphics
import SceneKit
import simd

/// Lightweight, authored fabric forms. These are presentation blanks, not cloth simulation or sewing patterns.
@MainActor enum TextileGeometry {
  private static func point(_ x:Double,_ y:Double,_ z:Double)->SCNVector3 {.init(x/100,y/100,z/100)}
  private static func material(_ color:String,_ roughness:Double=0.85)->SCNMaterial {
    let m=SCNMaterial();m.lightingModel = .physicallyBased;m.diffuse.contents=NSColor(hex:color);m.roughness.contents=roughness;return m
  }
  private static func mesh(_ vertices:[SCNVector3],_ triangles:[Int32],_ material:SCNMaterial)->SCNNode {
    var normals=[SIMD3<Float>](repeating:.zero,count:vertices.count)
    let vectors=vertices.map{SIMD3<Float>(Float($0.x),Float($0.y),Float($0.z))}
    for i in stride(from:0,to:triangles.count,by:3) {
      let a=Int(triangles[i]),b=Int(triangles[i+1]),c=Int(triangles[i+2]),n=simd_cross(vectors[b]-vectors[a],vectors[c]-vectors[a])
      normals[a]+=n;normals[b]+=n;normals[c]+=n
    }
    let normalSource=SCNGeometrySource(normals:normals.map { n in
      let unit=simd_length_squared(n)>0 ? simd_normalize(n):SIMD3<Float>(0,1,0);return .init(CGFloat(unit.x),CGFloat(unit.y),CGFloat(unit.z))
    })
    let tex=vertices.map{CGPoint(x:Double($0.x)*3,y:Double($0.z)*3)}
    let geo=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),normalSource,SCNGeometrySource(textureCoordinates:tex)],elements:[SCNGeometryElement(indices:triangles,primitiveType:.triangles)])
    geo.materials=[material];let node=SCNNode(geometry:geo);node.categoryBitMask=2;return node
  }
  private static func line(_ points:[Vector3],radius:Double,material:SCNMaterial)->SCNNode {
    var vertices:[SCNVector3]=[],faces:[Int32]=[]
    guard points.count>1 else{return SCNNode()}
    let sides=5
    for i in 1..<points.count {
      let p=points[i-1],q=points[i],a=SIMD3<Double>(p.x,p.y,p.z),b=SIMD3<Double>(q.x,q.y,q.z)
      guard simd_length(b-a)>0.00001 else{continue}
      let axis=simd_normalize(b-a),reference=abs(axis.y)<0.9 ? SIMD3<Double>(0,1,0):SIMD3<Double>(1,0,0)
      let right=simd_normalize(simd_cross(axis,reference)),up=simd_cross(axis,right),base=vertices.count
      for center in [a,b] {for side in 0..<sides {
        let angle=Double(side)/Double(sides)*2 * .pi,r=center+radius*(right*cos(angle)+up*sin(angle))
        vertices.append(point(r.x,r.y,r.z))
      }}
      for side in 0..<sides {let next=(side+1)%sides,aa=base+side,bb=base+next,cc=aa+sides,dd=bb+sides
        faces += [Int32(aa),Int32(bb),Int32(cc),Int32(bb),Int32(dd),Int32(cc)]
      }
    }
    return mesh(vertices,faces,material)
  }
  private static func halfWidth(_ o:ProductObject,_ z:Double)->Double {
    let v=z/o["depth"]+0.5
    let anchors:[(Double,Double)]=[(0,0.28),(0.12,0.4),(0.23,0.5),(0.65,0.49),(1,0.44)]
    for i in 1..<anchors.count where v<=anchors[i].0 {
      let t=(v-anchors[i-1].0)/(anchors[i].0-anchors[i-1].0)
      return o["width"]*(anchors[i-1].1+(anchors[i].1-anchors[i-1].1)*t)
    }
    return o["width"]*0.44
  }
  static func bomber(_ o:ProductObject,project:Project, assets:URL? = nil, textureLimit:Int = 2048)->SCNNode {
    let root=SCNNode(),cloth=GeometryFactory.material(o,project:project)
    if let assets, let design = try? project.resolvedFabricPattern(materialID: o.materialID) {
      cloth.diffuse.contents = FabricPatternRenderer.texture(design, assets: assets, limit: textureLimit, fontRevision: GeometryFactory.fontRevision)
      let t = design.pattern.bomberTextureTransform(sourceSize: design.sourceSize)
      var matrix = SCNMatrix4Identity
      matrix.m11 = CGFloat(t.a); matrix.m12 = CGFloat(t.b); matrix.m21 = CGFloat(t.c); matrix.m22 = CGFloat(t.d)
      matrix.m41 = CGFloat(t.tx); matrix.m42 = CGFloat(t.ty)
      cloth.diffuse.contentsTransform = matrix
    }
    cloth.isDoubleSided=true;cloth.diffuse.wrapS = .repeat;cloth.diffuse.wrapT = .repeat
    let trim=material(project.material(o.textile?.trimMaterialID ?? "flight-rib").color,0.97)
    let lining=material(project.material(o.textile?.liningMaterialID ?? "flight-orange").color,0.62)
    let seams=material("#0D1B25",0.95),metal=material("#A8AAA6",0.33);metal.metalness.contents=0.85
    let w=o["width"],d=o["depth"],loft=o["loft"],rib=o["ribHeight"],neck=o["neckWidth"]
    let cols=32,rows=40,layer=(cols+1)*(rows+1)
    var vertices:[SCNVector3]=[],indices:[Int32]=[]
    for back in [false,true] {
      for row in 0...rows {
        let z = -d/2+Double(row)/Double(rows)*(d-rib),half=halfWidth(o,z)
        for col in 0...cols {
          let u = -1+2*Double(col)/Double(cols),x=u*half
          let wrinkle=sin(z/23+x/47)*1.3*pow(abs(u),3)
          let y=back ? 3+3*(1-u*u) : TextileDesign.bodyTop(o,x:x,z:z)+wrinkle
          vertices.append(point(x,y,z))
        }
      }
    }
    for side in 0...1 {for row in 0..<rows {for col in 0..<cols {
      let a=side*layer+row*(cols+1)+col,b=a+1,c=a+cols+1,e=c+1
      // Leave an actual shallow neck opening; the orange lining remains visible inside it.
      let z = -d/2+(Double(row)+0.5)/Double(rows)*(d-rib)
      let x = (-1+2*(Double(col)+0.5)/Double(cols))*halfWidth(o,z)
      if z < -d*0.37 && abs(x)<neck*0.47 {continue}
      let triangle:[Int32]=[Int32(a),Int32(c),Int32(b),Int32(b),Int32(c),Int32(e)]
      indices += side==0 ? triangle:Array(triangle.reversed())
    }}}
    func bridge(_ a:Int,_ b:Int) {indices += [Int32(a),Int32(b),Int32(a+layer),Int32(b),Int32(b+layer),Int32(a+layer)]}
    for row in 0..<rows {bridge(row*(cols+1),(row+1)*(cols+1));bridge(row*(cols+1)+cols,(row+1)*(cols+1)+cols)}
    for col in 0..<cols {bridge(col,col+1);bridge(rows*(cols+1)+col,rows*(cols+1)+col+1)}
    let torso=mesh(vertices,indices,cloth);torso.name="Shaped nylon body";root.addChildNode(torso)
    let neckLining=GeometryFactory.box(neck*0.95,3,d*0.16,lining,y:8,z:-d*0.42,corner:8)
    neckLining.name="Rescue-orange neck lining";root.addChildNode(neckLining)
    // Rib collar follows a U shape around the opening, leaving the zipper throat open.
    var collar:[Vector3]=[]
    for i in 0...32 {let a=Double(i)/32 * .pi*1.7+0.15 * .pi;collar.append(.init(cos(a)*neck*0.53,22+loft*0.26,sin(a)*d*0.075-d*0.43))}
    root.addChildNode(line(collar,radius:11,material:trim))
    let waist=GeometryFactory.box(w*0.88,27,rib,trim,y:17,z:d/2-rib/2,corner:12);waist.name="Rib-knit waistband";root.addChildNode(waist)
    for i in 0...68 {
      let x = -w*0.43+Double(i)/68*w*0.86
      root.addChildNode(line([.init(x,31,d/2-rib+6),.init(x,31,d/2-5)],radius:0.48,material:seams))
    }
    for sign in [-1.0,1.0] {
      let length=o["sleeveLength"],angle=o["sleeveAngle"] * .pi/180,sections=26,sides=18
      let start=Vector3(sign*w*0.41,16+loft*0.15,-d*0.28)
      let direction=Vector3(sign*cos(angle),0,sin(angle)),perpendicular=Vector3(-sign*sin(angle),0,cos(angle))
      var points:[SCNVector3]=[],faces:[Int32]=[]
      for row in 0...sections {
        let t=Double(row)/Double(sections),radius=(w*0.155*(1-t)+o["cuffWidth"]*0.5*t)
        let yRadius=(loft*0.48*(1-t)+17*t)*(1+0.07*sin(t*45))
        for col in 0...sides {
          let a=Double(col)/Double(sides)*2 * .pi,bulge=1+0.025*sin(t*59+a*3)
          points.append(point(start.x+direction.x*t*length+perpendicular.x*cos(a)*radius*bulge,
            start.y*(1-t)+20*t+sin(a)*yRadius,start.z+direction.z*t*length+perpendicular.z*cos(a)*radius*bulge))
        }
      }
      for row in 0..<sections {for col in 0..<sides {let a=row*(sides+1)+col,b=a+1,c=a+sides+1,e=c+1;let tri:[Int32]=[Int32(a),Int32(b),Int32(c),Int32(b),Int32(e),Int32(c)];faces += sign>0 ? Array(tri.reversed()):tri}}
      let sleeve=mesh(points,faces,cloth);sleeve.name=sign>0 ? "Left shaped sleeve":"Right shaped sleeve";root.addChildNode(sleeve)
      let cuff=GeometryFactory.box(o["cuffWidth"],34,58,trim,y:start.y,z:0,corner:13)
      cuff.position=point(start.x+direction.x*(length-12),20,start.z+direction.z*(length-12))
      cuff.eulerAngles.y=CGFloat(sign*(.pi/2-angle));cuff.name="Rib-knit cuff";root.addChildNode(cuff)
      var seam:[Vector3]=[]
      for i in 0...20 {let t=Double(i)/20;seam.append(.init(start.x+direction.x*t*length,TextileDesign.sleeveTop(o,t:t)+0.5,start.z+direction.z*t*length))}
      root.addChildNode(line(seam,radius:0.65,material:seams))
      // Angled welt pockets and a subtle second seam.
      let px=sign*w*0.28,pz=d*0.17
      let pocket=[Vector3(px-sign*48,TextileDesign.bodyTop(o,x:px-sign*48,z:pz-50)+1,pz-50),Vector3(px+sign*32,TextileDesign.bodyTop(o,x:px+sign*32,z:pz+37)+1,pz+37)]
      root.addChildNode(line(pocket,radius:4,material:trim))
      root.addChildNode(line(pocket.map{.init($0.x+sign*7,$0.y+0.5,$0.z)},radius:0.6,material:seams))
    }
    var zip:[Vector3]=[]
    for i in 0...38 {let z = -d*0.36+Double(i)/38*d*0.83;zip.append(.init(0,TextileDesign.bodyTop(o,x:0,z:z)+1,z))}
    root.addChildNode(line(zip,radius:3.2,material:trim))
    let teeth=SCNNode()
    for i in 0..<74 {let z = -d*0.355+Double(i)/74*d*0.82,y=TextileDesign.bodyTop(o,x:0,z:z)+3
      teeth.addChildNode(GeometryFactory.box(5.8,1.5,2.2,metal,y:y,z:z,corner:0.5))
    }
    root.addChildNode(teeth.flattenedClone())
    let pull=GeometryFactory.box(8,3,20,metal,y:TextileDesign.bodyTop(o,x:0,z:-d*0.33)+5,z:-d*0.33,corner:2);pull.name="Zipper pull";root.addChildNode(pull)
    return root
  }
  static func decoration(_ o:ProductObject,project:Project,assets:URL,textureLimit:Int)->SCNNode {
    let root=SCNNode(),w=o["width"],h=o["depth"],thickness=o["height"],r=min(o["corner"],min(w,h)/2)
    let path=NSBezierPath(roundedRect:NSRect(x:-w/200,y:-h/200,width:w/100,height:h/100),xRadius:r/100,yRadius:r/100)
    path.flatness=0.0003
    let shape=SCNShape(path:path,extrusionDepth:thickness/100);shape.chamferRadius=min(0.4,thickness/3)/100
    let cloth=GeometryFactory.material(o,project:project),base=GeometryFactory.solid(shape,cloth)
    base.eulerAngles.x = -.pi/2;base.name="Independent textile base";root.addChildNode(base)
    root.name=EmbroiderySceneSurface.containerName
    EmbroiderySceneSurface.update(root,object:o,project:project,assets:assets,textureLimit:textureLimit)
    let border=o["borderWidth"]
    if border>0 {
      let inset=max(border/2,0.5),x=w/2-inset,z=h/2-inset,corner=max(0,r-inset)
      var points:[Vector3]=[]
      for (cx,cz,start) in [(x-corner,z-corner,0.0),(-x+corner,z-corner,90.0),(-x+corner,-z+corner,180.0),(x-corner,-z+corner,270.0)] {
        for j in 0...12 {let a=(start+Double(j)/12*90) * .pi/180;points.append(.init(cx+corner*cos(a),thickness+0.45,cz+corner*sin(a)))}
      }
      if let first=points.first {points.append(first)}
      let thread=material(o.textile?.threadColors?.first ?? "#D7CAB0",0.97)
      root.addChildNode(line(points,radius:o.recipeID=="textileLabel" ? 0.28:border*0.40,material:thread))
    }
    return root
  }
}
