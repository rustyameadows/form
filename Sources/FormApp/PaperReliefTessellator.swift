import Foundation
import FormCore
import simd

/// A render-only, conforming height-field mesh. Splitting a shared edge splits
/// both incident triangles; flat regions never pay the resolution of a finish
/// boundary elsewhere on the sheet. The raster hierarchy also finds marks that
/// fall between every vertex of the original cap.
enum PaperReliefTessellator {
  struct Vertex {
    var point: SIMD2<Double>
    var uv: SIMD2<Double>
    var baseZ: Double
    var height: Double
  }
  struct Result {
    let vertices: [Vertex]
    let indices: [UInt32]
    let heightToleranceMM: Double
  }
  private struct Edge: Hashable {
    let a: Int, b: Int
    init(_ a: Int, _ b: Int) { self.a=min(a,b);self.b=max(a,b) }
  }
  private struct Triangle {
    let a: Int, b: Int, c: Int, depth: Int
    var alive=true
    var edges: [Edge] { [Edge(a,b),Edge(b,c),Edge(c,a)] }
  }
  private struct Candidate { let triangle: Int, priority: Double }
  private struct Heap {
    var items=[Candidate]()
    mutating func insert(_ item: Candidate) {
      items.append(item);var i=items.count-1
      while i>0 {
        let parent=(i-1)/2
        guard items[i].priority>items[parent].priority else {break}
        items.swapAt(i,parent);i=parent
      }
    }
    mutating func pop() -> Candidate? {
      guard !items.isEmpty else{return nil}
      if items.count==1{return items.removeLast()}
      let result=items[0];items[0]=items.removeLast();var i=0
      while i*2+1<items.count {
        let left=i*2+1,right=left+1
        let child=right<items.count && items[right].priority>items[left].priority ? right:left
        guard items[child].priority>items[i].priority else{break}
        items.swapAt(i,child);i=child
      }
      return result
    }
  }

  /// Min/max blocks occupy less than 1/20 of the source field's storage. Small
  /// queries read the source texels directly; large empty areas use one block.
  struct Field {
    struct Range {
      var low: Float = .infinity, high: Float = -.infinity
      mutating func include(_ value: Float) {low=min(low,value);high=max(high,value)}
      mutating func include(_ other: Range) {low=min(low,other.low);high=max(high,other.high)}
    }
    private struct Level {let width:Int,height:Int,blocks:[Range]}
    let width:Int,height:Int,origin:SIMD2<Double>,size:SIMD2<Double>,values:[Float]
    private let levels:[Level]
    var pixelSize:Double {min(size.x/Double(width),size.y/Double(height))}
    var amplitude:Double {let r=levels.last!.blocks[0];return Double(max(abs(r.low),abs(r.high)))}
    init(width:Int,height:Int,origin:SIMD2<Double>,size:SIMD2<Double>,values:[Float]) {
      self.width=width;self.height=height;self.origin=origin;self.size=size;self.values=values
      var w=(width+7)/8,h=(height+7)/8,blocks=[Range](repeating:.init(),count:w*h)
      for y in 0..<height {for x in 0..<width {blocks[(y/8)*w+x/8].include(values[y*width+x])}}
      var result=[Level(width:w,height:h,blocks:blocks)]
      while w>1 || h>1 {
        let nw=(w+1)/2,nh=(h+1)/2
        var next=[Range](repeating:.init(),count:nw*nh)
        for y in 0..<h {for x in 0..<w {next[(y/2)*nw+x/2].include(blocks[y*w+x])}}
        w=nw;h=nh;blocks=next;result.append(.init(width:w,height:h,blocks:blocks))
      }
      levels=result
    }
    func range(low:SIMD2<Double>,high:SIMD2<Double>) -> Range {
      // Include the neighboring texels used by bilinear interpolation.
      let a=(low-origin)/size*SIMD2(Double(width),Double(height))-SIMD2(repeating:0.5)
      let b=(high-origin)/size*SIMD2(Double(width),Double(height))-SIMD2(repeating:0.5)
      let x0=max(0,min(width-1,Int(floor(a.x)))),y0=max(0,min(height-1,Int(floor(a.y))))
      let x1=max(0,min(width-1,Int(ceil(b.x)))),y1=max(0,min(height-1,Int(ceil(b.y))))
      var result=Range()
      func visit(_ level:Int,_ x:Int,_ y:Int) {
        let item=levels[level]
        guard x<item.width,y<item.height else{return}
        let span=8<<level,l=x*span,t=y*span,r=min(width-1,l+span-1),bottom=min(height-1,t+span-1)
        guard r>=x0,l<=x1,bottom>=y0,t<=y1 else{return}
        if l>=x0,r<=x1,t>=y0,bottom<=y1 {result.include(item.blocks[y*item.width+x]);return}
        if level==0 {
          for yy in max(t,y0)...min(bottom,y1) {for xx in max(l,x0)...min(r,x1) {result.include(values[yy*width+xx])}}
        } else {
          for dy in 0...1 {for dx in 0...1 {visit(level-1,x*2+dx,y*2+dy)}}
        }
      }
      visit(levels.count-1,0,0)
      return result
    }
  }

  static func make(vertices supplied:[Vertex],indices:[UInt32],field:Field,
    triangleBudget:Int,sample:(SIMD2<Double>)->Double)throws->Result {
    guard !supplied.isEmpty,indices.count%3==0,indices.count/3<=triangleBudget else {
      throw FormError.invalid("The paper cap exceeds its bounded relief mesh allocation.")
    }
    // When source allocation meets its 1.15x projected demand, a quarter texel
    // estimates 0.22 output pixels. A capped source pool can raise that estimate.
    // This sampled physical target is not a formal camera-space error bound.
    let tolerance=max(1e-8,min(0.02,min(field.pixelSize*0.25,field.amplitude*0.1)))
    var vertices=supplied,triangles=[Triangle](),adjacency=[Edge:Set<Int>](),heap=Heap(),active=0
    triangles.reserveCapacity(triangleBudget*2);vertices.reserveCapacity(triangleBudget)
    let probes:[SIMD3<Double>]=[.init(0.5,0.5,0),.init(0,0.5,0.5),.init(0.5,0,0.5),
      .init(repeating:1.0/3),.init(0.5,0.25,0.25),.init(0.25,0.5,0.25),.init(0.25,0.25,0.5)]
    func texelError(_ a:Vertex,_ b:Vertex,_ c:Vertex)->Double {
      let u=b.point-a.point,v=c.point-a.point,det=u.x*v.y-u.y*v.x
      guard abs(det)>1e-20 else{return 0}
      func error(_ point:SIMD2<Double>)->Double {
        let p=point-a.point,x=(p.x*v.y-p.y*v.x)/det,y=(u.x*p.y-u.y*p.x)/det
        return sample(point)-(a.height*(1-x-y)+b.height*x+c.height*y)
      }
      let pitch=field.size/SIMD2(Double(field.width),Double(field.height))
      let low=(simd_min(a.point,simd_min(b.point,c.point))-field.origin)/pitch-SIMD2(repeating:0.5)
      let high=(simd_max(a.point,simd_max(b.point,c.point))-field.origin)/pitch-SIMD2(repeating:0.5)
      let x0=max(0,Int(ceil(low.x))),x1=min(field.width-1,Int(floor(high.x)))
      let y0=max(0,Int(ceil(low.y))),y1=min(field.height-1,Int(floor(high.y)))
      var maximum=0.0
      // On a source cell the field minus a triangle plane is bilinear. Its
      // interior stationary point is a saddle, so extrema lie on its boundary.
      if x0<=x1,y0<=y1 {for y in y0...y1 {for x in x0...x1 {
        let point=field.origin+(SIMD2(Double(x),Double(y))+SIMD2(repeating:0.5))*pitch,p=point-a.point
        let s=(p.x*v.y-p.y*v.x)/det,t=(u.x*p.y-u.y*p.x)/det
        if s>=0,t>=0,s+t<=1 {maximum=max(maximum,abs(error(point)))}
      }}}
      for (start,end) in [(a.point,b.point),(b.point,c.point),(c.point,a.point)] {
        var breaks=[0.0,1.0];let delta=end-start
        for axis in 0...1 where abs(delta[axis])>1e-15 {
          let first=axis==0 ? x0:y0,last=axis==0 ? x1:y1
          if first<=last {for i in first...last {
            let line=field.origin[axis]+(Double(i)+0.5)*pitch[axis],t=(line-start[axis])/delta[axis]
            if t>0,t<1 {breaks.append(t)}
          }}
        }
        breaks.sort()
        for i in 0..<(breaks.count-1) {
          let l=breaks[i],r=breaks[i+1],e0=error(start+delta*l),e1=error(start+delta*r)
          let em=error(start+delta*((l+r)/2)),qa=2*(e0+e1-2*em),qb=e1-e0-qa
          maximum=max(maximum,max(abs(e0),max(abs(e1),abs(em))))
          if abs(qa)>1e-16 {
            let extremum = -qb/(2*qa)
            if extremum>0,extremum<1 {maximum=max(maximum,abs(error(start+delta*(l+(r-l)*extremum))))}
          }
        }
      }
      return maximum
    }
    func priority(_ triangle:Triangle)->Double {
      let a=vertices[triangle.a],b=vertices[triangle.b],c=vertices[triangle.c]
      let length=max(simd_length(a.point-b.point),max(simd_length(b.point-c.point),simd_length(c.point-a.point)))
      let bounds=field.range(low:simd_min(a.point,simd_min(b.point,c.point)),high:simd_max(a.point,simd_max(b.point,c.point)))
      var error=0.0
      // Edge and interior probes bound the interpolation error once the
      // conservative field range has brought a transition to texel scale.
      for weight in probes {
        let point=a.point*weight.x+b.point*weight.y+c.point*weight.z
        let interpolated=a.height*weight.x+b.height*weight.y+c.height*weight.z
        error=max(error,abs(sample(point)-interpolated))
      }
      let unresolved=Double(bounds.high-bounds.low)>tolerance && length>field.pixelSize*2
      if length<=field.pixelSize*2 {error=max(error,texelError(a,b,c))}
      if !unresolved && error<=tolerance{return 0}
      return max(unresolved ? length/(field.pixelSize*2):0,error/tolerance)
    }
    func add(_ a:Int,_ b:Int,_ c:Int,_ depth:Int) {
      let id=triangles.count,triangle=Triangle(a:a,b:b,c:c,depth:depth)
      triangles.append(triangle);active+=1
      for edge in triangle.edges {adjacency[edge,default:[]].insert(id)}
      let value=priority(triangle)
      if value>0 {heap.insert(.init(triangle:id,priority:value))}
    }
    for i in stride(from:0,to:indices.count,by:3) {
      let ids=[Int(indices[i]),Int(indices[i+1]),Int(indices[i+2])]
      guard ids.allSatisfy({vertices.indices.contains($0)}) else {throw FormError.invalid("Paper relief found an invalid cap index.")}
      add(ids[0],ids[1],ids[2],0)
    }
    guard adjacency.values.allSatisfy({$0.count<=2}) else {
      throw FormError.invalid("Paper relief requires a manifold cap without overlapping source triangles.")
    }
    func lengthSquared(_ edge:Edge)->Double {
      simd_length_squared(vertices[edge.a].point-vertices[edge.b].point)
    }
    func longestEdge(_ triangle:Triangle)->Edge {
      triangle.edges.max{lengthSquared($0)<lengthSquared($1)}!
    }
    var workCount=0
    while let candidate=heap.pop() {
      let triangle=triangles[candidate.triangle]
      guard triangle.alive else{continue}
      var pending=[longestEdge(triangle)]
      while let edge=pending.last {
        workCount+=1
        if workCount%256==0 {try Task.checkCancellation()}
        let incident=(adjacency[edge] ?? []).sorted()
        if incident.isEmpty {pending.removeLast();continue}
        // Longest-edge propagation prevents the arbitrarily thin triangles
        // produced by forcing a short-edge split on an unrefined neighbor.
        // The iterative stack follows strictly longer edges, then unwinds.
        let length=lengthSquared(edge)
        if let next=incident.lazy.map({longestEdge(triangles[$0])})
          .first(where:{lengthSquared($0)>length*(1+1e-12)}) {
          pending.append(next);continue
        }
        guard active+incident.count<=triangleBudget else {
          throw FormError.invalid("Paper finish relief exceeds its \(triangleBudget)-triangle render budget at \(String(format:"%.6g",tolerance)) mm height tolerance. Reduce finish complexity or capture magnification.")
        }
        guard incident.allSatisfy({triangles[$0].depth<40}) else {
          throw FormError.invalid("Paper finish relief exceeds its bounded subdivision depth at \(String(format:"%.6g",tolerance)) mm height tolerance.")
        }
        let first=vertices[edge.a],second=vertices[edge.b],point=(first.point+second.point)/2
        let midpoint=vertices.count
        vertices.append(.init(point:point,uv:(first.uv+second.uv)/2,baseZ:(first.baseZ+second.baseZ)/2,height:sample(point)))
        for id in incident {
          let old=triangles[id];triangles[id].alive=false;active-=1
          for oldEdge in old.edges {adjacency[oldEdge]?.remove(id);if adjacency[oldEdge]?.isEmpty==true{adjacency.removeValue(forKey:oldEdge)}}
          // Retain the original winding on both sides of the shared edge.
          let ids=[old.a,old.b,old.c]
          for i in 0..<3 where Edge(ids[i],ids[(i+1)%3])==edge {
            add(ids[i],midpoint,ids[(i+2)%3],old.depth+1)
            add(midpoint,ids[(i+1)%3],ids[(i+2)%3],old.depth+1)
          }
        }
        pending.removeLast()
      }
    }
    var output=[UInt32]();output.reserveCapacity(active*3)
    for triangle in triangles where triangle.alive {output += [UInt32(triangle.a),UInt32(triangle.b),UInt32(triangle.c)]}
    return .init(vertices:vertices,indices:output,heightToleranceMM:tolerance)
  }
}
