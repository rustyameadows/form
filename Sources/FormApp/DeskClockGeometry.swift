import AppKit
import SceneKit
import simd
import FormCore

@MainActor enum DeskClockGeometry {
  static func updateHands(_ root:SCNNode,object o:ProductObject) {
    root.childNode(withName:"deskClock.Hour hand",recursively:true)?.eulerAngles.z=CGFloat(-(o["hour"]+o["minute"]/60)*Double.pi/6)
    root.childNode(withName:"deskClock.Minute hand",recursively:true)?.eulerAngles.z=CGFloat(-o["minute"]*Double.pi/30)
    for name in ["Hour hand","Minute hand","Hub"] {root.childNode(withName:"deskClock."+name,recursively:true)?.isHidden=o["hands"]<0.5}
  }
  static func make(_ o:ProductObject,project:Project,assets:URL,limit:Int)->SCNNode {
    let root=SCNNode(),w=o["width"],h=o["height"],d=o["depth"],wall=o["wall"],bevel=o["bevel"]
    let center=14+h/2,front=d/2
    func material(_ color:String,metal:Double=0,rough:Double=0.4)->SCNMaterial {
      let m=SCNMaterial();m.lightingModel = .physicallyBased;m.diffuse.contents=NSColor(hex:color);m.metalness.contents=metal;m.roughness.contents=rough;return m
    }
    let caseMat=GeometryFactory.material(o,project:project),brass=material("#B29158",metal:0.8,rough:0.26),dark=material("#282C29",metal:0.5,rough:0.3),warm=material("#70452A",metal:0.1,rough:0.36),ivory=material("#F2EDDF",rough:0.7)
    func part(_ name:String,_ geometry:SCNGeometry,_ mat:SCNMaterial)->SCNNode {
      let n=GeometryFactory.solid(geometry,mat);n.name="deskClock."+name;n.position.y=CGFloat(center/100);root.addChildNode(n);return n
    }
    // One closed section swept around the exact sampled outline. All ring
    // surfaces share topology, including rounded front/back edges and inner wall.
    func ring(_ inset:Double,_ width:Double,_ z0:Double,_ z1:Double,_ r:Double)->SCNGeometry {
      var section:[(Double,Double)]=[]
      for (x,z,start) in [(inset+r,z1-r,Double.pi),(inset+width-r,z1-r,Double.pi/2),(inset+width-r,z0+r,0.0),(inset+r,z0+r,-Double.pi/2)] {
        for j in 0...8 {let a=start-Double(j)*Double.pi/16;section.append((x+r*cos(a),z+r*sin(a)))}
      }
      let loops=section.map {s in DeskClockDesign.outline(o,inset:s.0).map{SCNVector3($0.x/100,$0.y/100,s.1/100)}}
      return swept(loops,closed:true)
    }
    _=part("Case shell",ring(0,wall,-front,front, min(bevel,wall/2-0.05)),caseMat)
    _=part("Bezel",ring(0.7,2.3,front-0.7,front+1.7,0.55),brass)
    _=part("Inner surround",ring(wall+0.3,7.2,front-8,front-1.0,0.8),warm)
    func panel(_ inset:Double,_ thickness:Double,_ z:Double,bore:Double=0,canvas:Point2?=nil)->SCNGeometry {
      let outer=DeskClockDesign.outline(o,inset:inset)
      let inner=outer.indices.map{i -> Point2 in let a=(Double(i)+0.5)*2 * Double.pi/Double(outer.count);return .init(cos(a)*bore/2,sin(a)*bore/2)}
      if bore>0 {
        return swept([outer.map{SCNVector3($0.x/100,$0.y/100,z/100)},outer.map{SCNVector3($0.x/100,$0.y/100,(z+thickness)/100)},inner.map{SCNVector3($0.x/100,$0.y/100,(z+thickness)/100)},inner.map{SCNVector3($0.x/100,$0.y/100,z/100)}],closed:true,flat:true,canvas:canvas)
      }
      return capped(outer,z:z,thickness:thickness)
    }
    _=part("Dial",panel(10.5,2,front-9,bore:o["bore"]),ivory)
    _=part("Back cover",panel(wall+0.25,2,-front+0.5),dark)
    if let art=o.artwork {
      let face=panel(10.5,0.025,front-6.96,bore:o["bore"],canvas:.init(w,h))
      let m=SCNMaterial();m.lightingModel = .physicallyBased;m.diffuse.contents=GeometryFactory.artworkImage(art,width:w,depth:h,assets:assets,textureLimit:limit);m.roughness.contents=0.8
      // Planar UVs use the full physical source rectangle. The shaped face and
      // shaft opening clip the material; no fake painted model silhouette.
      let node=part("Artwork",face,m);node.castsShadow=false
    }
    func hand(_ name:String,_ length:Double,_ width:Double,_ z:Double,_ angle:Double) {
      let pts=[Point2(-width*0.45,-11),Point2(width*0.45,-11),Point2(width*0.62,length*0.30),Point2(0,length),Point2(-width*0.62,length*0.30)]
      let node=part(name,capped(pts,z:0,thickness:0.9),brass);node.position.z=CGFloat(z/100);node.eulerAngles.z=CGFloat(-angle*Double.pi/180);node.isHidden=o["hands"]<0.5
      let inset=[Point2(-width*0.23,-8),Point2(width*0.23,-8),Point2(width*0.34,length*0.31),Point2(0,length-3),Point2(-width*0.34,length*0.31)]
      let inner=GeometryFactory.solid(capped(inset,z:0.91,thickness:0.02),dark);inner.name="display.inlay";node.addChildNode(inner)
    }
    hand("Hour hand",h*0.28,7,front-4.6,(o["hour"]+o["minute"]/60)*30)
    hand("Minute hand",h*0.407,3.1,front-2.9,o["minute"]*6)
    let hub=SCNCylinder(radius:0.026,height:0.024);hub.radialSegmentCount=96
    let pin=part("Hub",hub,brass);pin.eulerAngles.x = .pi/2;pin.position.z=CGFloat((front-0.7)/100);pin.isHidden=o["hands"]<0.5
    let feet=SCNNode();feet.name="deskClock.Feet";root.addChildNode(feet)
    for x in [-w*0.36,w*0.36] {for z in [-d*0.32,d*0.32] {
      let foot=Self.foot()
      let node=GeometryFactory.solid(foot,brass,at:.init(x/100,0.122,z/100));node.eulerAngles.z=CGFloat(x<0 ? -0.15:0.15);node.eulerAngles.x=CGFloat(z<0 ? -0.09:0.09);feet.addChildNode(node)
    }}
    return root
  }
  static func foot()->SCNGeometry {
    let count=96,profile:[(Double,Double)]=[(1.5,-12),(1.8,-11.7),(2.7,11.7),(2.4,12)]
    var vertices:[SCNVector3]=[],indices:[Int32]=[]
    for (radius,y) in profile {for i in 0..<count {let a=Double(i)*2 * Double.pi/Double(count);vertices.append(.init(radius*cos(a)/100,y/100,radius*sin(a)/100))}}
    for j in 0..<profile.count-1 {for i in 0..<count {let a=Int32(j*count+i),b=Int32(j*count+(i+1)%count),c=Int32((j+1)*count+(i+1)%count),d=Int32((j+1)*count+i);indices += [a,b,c,a,c,d]}}
    let low=Int32(vertices.count),high=low+1;vertices += [.init(0,-0.12,0),.init(0,0.12,0)]
    for i in 0..<count {let j=(i+1)%count;indices += [low,Int32(j),Int32(i),high,Int32(3*count+i),Int32(3*count+j)]}
    return mesh(vertices,indices)
  }
  // Normals are accumulated on the smooth rolled sections. Coplanar panel caps
  // remain flat; all printable geometry is triangulated rather than SCNShape.
  static func swept(_ loops:[[SCNVector3]],closed:Bool,flat:Bool=false,canvas:Point2?=nil)->SCNGeometry {
    let n=loops[0].count;let vertices=loops.flatMap{$0};var indices:[Int32]=[]
    for j in 0..<(closed ? loops.count:loops.count-1) {for i in 0..<n {
      let a=Int32(j*n+i),b=Int32(j*n+(i+1)%n),c=Int32(((j+1)%loops.count)*n+(i+1)%n),d=Int32(((j+1)%loops.count)*n+i)
      indices += [a,b,c,a,c,d]
    }}
    return mesh(vertices,indices,flat:flat,canvas:canvas)
  }
  static func capped(_ points:[Point2],z:Double,thickness:Double)->SCNGeometry {
    let n=points.count;var v=points.map{SCNVector3($0.x/100,$0.y/100,z/100)}+points.map{SCNVector3($0.x/100,$0.y/100,(z+thickness)/100)}
    v += [.init(0,0,z/100),.init(0,0,(z+thickness)/100)];var indices:[Int32]=[]
    for i in 0..<n {let j=(i+1)%n;indices += [Int32(i),Int32(j),Int32(n+j),Int32(i),Int32(n+j),Int32(n+i),Int32(2*n),Int32(j),Int32(i),Int32(2*n+1),Int32(n+i),Int32(n+j)]}
    return mesh(v,indices,flat:true)
  }
  static func mesh(_ original:[SCNVector3],_ originalIndices:[Int32],flat:Bool=false,canvas:Point2?=nil)->SCNGeometry {
    var indices=originalIndices
    var volume=0.0
    for i in stride(from:0,to:indices.count,by:3) {let a=original[Int(indices[i])],b=original[Int(indices[i+1])],c=original[Int(indices[i+2])];volume += Double(a.x)*(Double(b.y)*Double(c.z)-Double(b.z)*Double(c.y))+Double(a.y)*(Double(b.z)*Double(c.x)-Double(b.x)*Double(c.z))+Double(a.z)*(Double(b.x)*Double(c.y)-Double(b.y)*Double(c.x))}
    if volume<0 {for i in stride(from:0,to:indices.count,by:3){indices.swapAt(i+1,i+2)}}
    let v=flat ? indices.map{original[Int($0)]}:original
    if flat {indices=v.indices.map{Int32($0)}}
    var normals=Array(repeating:SIMD3<Float>(repeating:0),count:v.count)
    for i in stride(from:0,to:indices.count,by:3) {let a=Int(indices[i]),b=Int(indices[i+1]),c=Int(indices[i+2]);let p=SIMD3<Float>(Float(v[a].x),Float(v[a].y),Float(v[a].z)),q=SIMD3<Float>(Float(v[b].x),Float(v[b].y),Float(v[b].z)),r=SIMD3<Float>(Float(v[c].x),Float(v[c].y),Float(v[c].z));let normal=simd_cross(q-p,r-p);normals[a]+=normal;normals[b]+=normal;normals[c]+=normal}
    let ns=normals.map{n -> SCNVector3 in let l=simd_length(n);return l>0 ? .init(Double(n.x/l),Double(n.y/l),Double(n.z/l)):.init(0,0,1)}
    // UV remapping for the dial is supplied below by its actual bounds.
    let minX=v.map{Double($0.x)}.min() ?? 0,maxX=v.map{Double($0.x)}.max() ?? 1,minY=v.map{Double($0.y)}.min() ?? 0,maxY=v.map{Double($0.y)}.max() ?? 1
    let uv=v.map{p -> CGPoint in if let canvas {return .init(x:Double(p.x)*100/canvas.x+0.5,y:0.5-Double(p.y)*100/canvas.y)};return .init(x:(Double(p.x)-minX)/max(maxX-minX,0.0001),y:(Double(p.y)-minY)/max(maxY-minY,0.0001))}
    return SCNGeometry(sources:[SCNGeometrySource(vertices:v),SCNGeometrySource(normals:ns),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
  }
}
