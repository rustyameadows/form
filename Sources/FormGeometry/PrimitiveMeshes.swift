import AppKit
import CFormMesher
import Foundation
import simd

private func surface(_ p:[MeshVector3],_ n:[MeshVector3],_ uv:[CGPoint],_ raw:[Int32])->([MeshGeometrySource],[MeshGeometryElement]) {
  var indices:[Int32]=[]
  for i in stride(from:0,to:raw.count,by:3) {let a=Int(raw[i]),b=Int(raw[i+1]),c=Int(raw[i+2]),cross=simd_cross(p[b].simd-p[a].simd,p[c].simd-p[a].simd);if simd_length_squared(cross)<1e-28{continue};if simd_dot(cross,n[a].simd+n[b].simd+n[c].simd)<0{indices += [raw[i],raw[i+2],raw[i+1]]}else{indices += [raw[i],raw[i+1],raw[i+2]]}}
  return ([.init(vertices:p),.init(normals:n),.init(textureCoordinates:uv)],[.init(indices:indices,primitiveType:.triangles)])
}
open class MeshPrimitive:MeshGeometry {
  private var built=false
  public func invalidate(){built=false}
  open func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {([],[])}
  public override func prepare(){if !built{let b=buffers();replace(sources:b.0,elements:b.1);built=true}}
}
public final class MeshBox:MeshPrimitive {
  public var width:Double,height:Double,length:Double,chamferRadius:Double
  public var chamferSegmentCount=8 {didSet{invalidate()}}
  public init(width:Double,height:Double,length:Double,chamferRadius:Double){self.width=width;self.height=height;self.length=length;self.chamferRadius=chamferRadius;super.init()}
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {
    let half=SIMD3(width/2,height/2,length/2),r=max(0,min(chamferRadius,half.x,half.y,half.z)),inner=half-SIMD3(repeating:r)
    func grid(_ h:Double)->[Double]{guard r>0 else{return[-h,h]};let count=max(2,min(32,chamferSegmentCount));return (0...count).map{-h+r*Double($0)/Double(count)}+[0]+(0...count).map{h-r+r*Double($0)/Double(count)}}
    var p:[MeshVector3]=[],n:[MeshVector3]=[],uv:[CGPoint]=[],idx:[Int32]=[]
    for axis in 0..<3 {for sign in [-1.0,1.0] {
      let u=(axis+1)%3,v=(axis+2)%3,us=grid(half[u]),vs=grid(half[v]),start=p.count
      for y in vs {for x in us {var point=SIMD3<Double>.zero;point[axis]=sign*half[axis];point[u]=x;point[v]=y
        let q=simd_clamp(point,-inner,inner);var normal=SIMD3<Double>.zero;normal[axis]=sign
        if r>0{normal=simd_normalize(point-q);point=q+normal*r}
        p.append(.init(point));n.append(.init(normal));uv.append(.init(x:(x+half[u])/max(1e-12,half[u]*2),y:1-(y+half[v])/max(1e-12,half[v]*2)))
      }}
      for j in 0..<vs.count-1 {for i in 0..<us.count-1 {let a=Int32(start+j*us.count+i),b=a+1,c=a+Int32(us.count)+1,d=c-1;idx += [a,b,c,a,c,d]}}
    }}
    return surface(p,n,uv,idx)
  }
}
public final class MeshPlane:MeshPrimitive {
  public let width:Double,height:Double
  public init(width:Double,height:Double){self.width=width;self.height=height;super.init()}
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {surface([.init(-width/2,-height/2,0),.init(width/2,-height/2,0),.init(width/2,height/2,0),.init(-width/2,height/2,0)],Array(repeating:.init(0,0,1),count:4),[.init(x:0,y:1),.init(x:1,y:1),.init(x:1,y:0),.init(x:0,y:0)],[0,1,2,0,2,3])}
}
public final class MeshFloor:MeshPrimitive {
  public var reflectivity=0.0
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {surface([.init(-10000,0,-10000),.init(10000,0,-10000),.init(10000,0,10000),.init(-10000,0,10000)],Array(repeating:.init(0,1,0),count:4),[.init(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)],[0,1,2,0,2,3])}
}
open class MeshCone:MeshPrimitive {
  public var topRadius:Double,bottomRadius:Double,height:Double
  public var radialSegmentCount=96 {didSet{invalidate()}}
  public init(topRadius:Double,bottomRadius:Double,height:Double){self.topRadius=topRadius;self.bottomRadius=bottomRadius;self.height=height;super.init()}
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {
    let count=max(3,min(512,radialSegmentCount)),slope=(bottomRadius-topRadius)/max(height,1e-12)
    var p:[MeshVector3]=[],n:[MeshVector3]=[],uv:[CGPoint]=[],idx:[Int32]=[]
    for y in [0,1] {let radius=y==0 ? bottomRadius:topRadius;for i in 0...count {let t=Double(i)/Double(count),a=t*2 * .pi;p.append(.init(radius*cos(a),(Double(y)-0.5)*height,radius*sin(a)));n.append(.init(simd_normalize(SIMD3(cos(a),slope,sin(a)))));uv.append(.init(x:t,y:Double(1-y)))}}
    for i in 0..<count {let a=Int32(i),b=a+Int32(count+1),c=b+1,d=a+1;idx += [a,b,c,a,c,d]}
    for top in [false,true] {let radius=top ? topRadius:bottomRadius;if radius<=0{continue};let start=p.count,y=(top ? 0.5 : -0.5)*height,normal=MeshVector3(0,top ? 1 : -1,0)
      p.append(.init(0,y,0));n.append(normal);uv.append(.init(x:0.5,y:0.5))
      for i in 0..<count {let a=Double(i)*2 * .pi/Double(count);p.append(.init(radius*cos(a),y,radius*sin(a)));n.append(normal);uv.append(.init(x:0.5+cos(a)/2,y:0.5+sin(a)/2))}
      for i in 0..<count {idx += [Int32(start),Int32(start+1+i),Int32(start+1+(i+1)%count)]}
    }
    return surface(p,n,uv,idx)
  }
}
public final class MeshCylinder:MeshCone {
  public var radius:Double {get{bottomRadius}set{bottomRadius=newValue;topRadius=newValue;invalidate()}}
  public init(radius:Double,height:Double){super.init(topRadius:radius,bottomRadius:radius,height:height)}
}
public final class MeshSphere:MeshPrimitive {
  public let radius:Double
  public var segmentCount=96 {didSet{invalidate()}}
  public init(radius:Double){self.radius=radius;super.init()}
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {
    let count=max(8,min(512,segmentCount)),rows=max(4,count/2)
    var p:[MeshVector3]=[],n:[MeshVector3]=[],uv:[CGPoint]=[],idx:[Int32]=[]
    for j in 0...rows {let v=Double(j)/Double(rows),phi=v * .pi;for i in 0...count {let u=Double(i)/Double(count),a=u*2 * .pi,normal=MeshVector3(sin(phi)*cos(a),cos(phi),sin(phi)*sin(a));p.append(.init(normal.simd*radius));n.append(normal);uv.append(.init(x:u,y:v))}}
    for j in 0..<rows {for i in 0..<count {let a=Int32(j*(count+1)+i),b=a+Int32(count+1),c=b+1,d=a+1;idx += [a,b,c,a,c,d]}}
    return surface(p,n,uv,idx)
  }
}
public final class MeshTorus:MeshPrimitive {
  public let ringRadius:Double,pipeRadius:Double
  public var ringSegmentCount=128 {didSet{invalidate()}}
  public var pipeSegmentCount=32 {didSet{invalidate()}}
  public init(ringRadius:Double,pipeRadius:Double){self.ringRadius=ringRadius;self.pipeRadius=pipeRadius;super.init()}
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {
    let ring=max(8,min(512,ringSegmentCount)),pipe=max(6,min(256,pipeSegmentCount));var p:[MeshVector3]=[],n:[MeshVector3]=[],uv:[CGPoint]=[],idx:[Int32]=[]
    for j in 0...ring {let u=Double(j)/Double(ring),a=u*2 * .pi;for i in 0...pipe {let v=Double(i)/Double(pipe),b=v*2 * .pi,r=ringRadius+pipeRadius*cos(b);p.append(.init(r*cos(a),pipeRadius*sin(b),r*sin(a)));n.append(.init(cos(b)*cos(a),sin(b),cos(b)*sin(a)));uv.append(.init(x:u,y:v))}}
    for j in 0..<ring {for i in 0..<pipe {let a=Int32(j*(pipe+1)+i),b=a+Int32(pipe+1),c=b+1,d=a+1;idx += [a,b,c,a,c,d]}}
    return surface(p,n,uv,idx)
  }
}
public final class MeshShape:MeshPrimitive {
  public let path:NSBezierPath,extrusionDepth:Double
  public var chamferRadius=0.0 {didSet{invalidate()}}
  public private(set) var diagnostic:String?
  public init(path:NSBezierPath,extrusionDepth:Double){self.path=path.copy() as! NSBezierPath;self.extrusionDepth=extrusionDepth;super.init()}
  public override func buffers()->([MeshGeometrySource],[MeshGeometryElement]) {
    var rings:[[CGPoint]]=[],current:[CGPoint]=[]
    func close(_ a:CGPoint,_ b:CGPoint)->Bool{hypot(a.x-b.x,a.y-b.y)<1e-12}
    func append(_ p:CGPoint){if current.last.map({close($0,p)}) != true{current.append(p)}}
    func finish(){if current.count>1,close(current.first!,current.last!){current.removeLast()};if current.count>=3{rings.append(current)};current=[]}
    func middle(_ a:CGPoint,_ b:CGPoint)->CGPoint{.init(x:(a.x+b.x)/2,y:(a.y+b.y)/2)}
    func cubic(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint,_ d:CGPoint,_ depth:Int){
      let dx=d.x-a.x,dy=d.y-a.y,length=hypot(dx,dy)
      func distance(_ p:CGPoint)->Double{length>1e-14 ? abs(dx*(a.y-p.y)-(a.x-p.x)*dy)/length:hypot(p.x-a.x,p.y-a.y)}
      if depth>=18 || max(distance(b),distance(c))<=0.0002{append(d);return}
      let ab=middle(a,b),bc=middle(b,c),cd=middle(c,d),abc=middle(ab,bc),bcd=middle(bc,cd),center=middle(abc,bcd)
      cubic(a,ab,abc,center,depth+1);cubic(center,bcd,cd,d,depth+1)
    }
    for i in 0..<path.elementCount {var points=Array(repeating:CGPoint.zero,count:3);let type=path.element(at:i,associatedPoints:&points);switch type{case .moveTo:finish();current=[points[0]];case .lineTo:append(points[0]);case .curveTo:if let start=current.last{cubic(start,points[0],points[1],points[2],0)};case .closePath:finish();default:break}}
    finish();guard !rings.isEmpty,rings.reduce(0,{$0+$1.count})<=100000 else{diagnostic="The construction profile exceeds its bounded tessellation budget.";return([],[])}
    func area(_ r:[CGPoint])->Double {zip(r,r.dropFirst()+[r[0]]).reduce(0){$0+Double($1.0.x*$1.1.y-$1.1.x*$1.0.y)}/2}
    func contains(_ ring:[CGPoint],_ p:CGPoint)->Bool{var inside=false;for i in ring.indices{let a=ring[i],b=ring[(i+1)%ring.count];if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x{inside.toggle()}};return inside}
    let depths=rings.map{r in rings.filter{other in abs(area(other))>abs(area(r)) && contains(other,r[0])}.count}
    var p:[MeshVector3]=[],n:[MeshVector3]=[],uv:[CGPoint]=[],idx:[Int32]=[]
    let bounds=path.bounds,z0 = -extrusionDepth/2,z1=extrusionDepth/2
    func coordinate(_ q:CGPoint)->CGPoint{.init(x:Double((q.x-bounds.minX)/max(bounds.width,1e-12)),y:1-Double((q.y-bounds.minY)/max(bounds.height,1e-12)))}
    for outer in rings.indices where depths[outer]%2==0 {
      let ids=[outer]+rings.indices.filter{depths[$0]==depths[outer]+1 && contains(rings[outer],rings[$0][0])},group=ids.map{rings[$0]}
      let bevel=max(0,min(chamferRadius,extrusionDepth/2-1e-9))
      func inset(_ ring:[CGPoint],_ distance:Double,_ hole:Bool)->[CGPoint] {
        guard distance>0 else{return ring};let sign=(area(ring)>0 ? 1.0:-1.0)*(hole ? -1:1)
        return ring.indices.map{i in
          let p=ring[i],before=ring[(i+ring.count-1)%ring.count],after=ring[(i+1)%ring.count]
          let a=simd_normalize(SIMD2<Double>(Double(p.x-before.x),Double(p.y-before.y))),b=simd_normalize(SIMD2<Double>(Double(after.x-p.x),Double(after.y-p.y)))
          let na=SIMD2(-a.y,a.x)*sign,nb=SIMD2(-b.y,b.x)*sign,sum=na+nb
          guard simd_length_squared(sum)>1e-20 else{return p};let direction=simd_normalize(sum),denominator=simd_dot(direction,na)
          guard denominator>1e-8 else{return p};let amount=min(distance*8,distance/denominator)
          return .init(x:Double(p.x)+direction.x*amount,y:Double(p.y)+direction.y*amount)
        }
      }
      let capRings=group.enumerated().map{inset($0.element,bevel,$0.offset>0)},points=capRings.flatMap{$0},xy=points.flatMap{[Double($0.x),Double($0.y)]},sizes=group.map{UInt32($0.count)}
      var output=FMIndexBuffer();let status=xy.withUnsafeBufferPointer{x in sizes.withUnsafeBufferPointer{s in fm_triangulate(x.baseAddress,points.count,s.baseAddress,sizes.count,&output)}}
      guard status==0,let raw=output.indices else{fm_free_indices(&output);diagnostic="The construction profile bevel could not be triangulated; reduce its radius.";return([],[])}
      let cap=Array(UnsafeBufferPointer(start:raw,count:output.count));fm_free_indices(&output)
      for top in [false,true] {let start=Int32(p.count);for q in points{p.append(.init(Double(q.x),Double(q.y),top ? z1:z0));n.append(.init(0,0,top ? 1:-1));uv.append(coordinate(q))};for i in stride(from:0,to:cap.count,by:3){let a=points[Int(cap[i])],b=points[Int(cap[i+1])],c=points[Int(cap[i+2])],cross=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x),flip=(cross>0) != top;idx += [start+Int32(cap[i]),start+Int32(cap[i+(flip ? 2:1)]),start+Int32(cap[i+(flip ? 1:2)])]}}
      var sections:[(offset:Double,z:Double,nz:Double,xy:Double)]=[]
      if bevel>0 {
        for j in 0...6 {let t=(1-Double(j)/6) * .pi/2;sections.append((bevel*(1-cos(t)),z0+bevel-bevel*sin(t),-sin(t),cos(t)))}
        sections.append((0,z1-bevel,0,1))
        for j in 1...6 {let t=Double(j)/6 * .pi/2;sections.append((bevel*(1-cos(t)),z1-bevel+bevel*sin(t),sin(t),cos(t)))}
      }else{sections=[(0,z0,0,1),(0,z1,0,1)]}
      for (j,ring) in group.enumerated(){let sign=(area(ring)>0 ? 1.0:-1.0)*(j==0 ? 1:-1),profiles=sections.map{inset(ring,$0.offset,j>0)}
        for k in 0..<sections.count-1 {for i in ring.indices {let next=(i+1)%ring.count,a=ring[i],b=ring[next],delta=SIMD2<Double>(Double(b.x-a.x),Double(b.y-a.y)),length=simd_length(delta);if length<=1e-12{continue};let normal=SIMD2(sign*delta.y/length,-sign*delta.x/length),start=Int32(p.count),lo=sections[k],hi=sections[k+1]
          for (q,section) in [(profiles[k][i],lo),(profiles[k][next],lo),(profiles[k+1][next],hi),(profiles[k+1][i],hi)] {p.append(.init(Double(q.x),Double(q.y),section.z));n.append(.init(normal.x*section.xy,normal.y*section.xy,section.nz));uv.append(coordinate(q))}
          idx += sign>0 ? [start,start+1,start+2,start,start+2,start+3]:[start,start+2,start+1,start,start+3,start+2]
        }}
      }
    }
    return surface(p,n,uv,idx)
  }
}
