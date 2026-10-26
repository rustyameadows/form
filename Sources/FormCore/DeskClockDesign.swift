import Foundation

/// Bounded reference-led desk-clock construction. Dimensions are millimeters.
public enum DeskClockDesign {
  public static let recipe = Recipe("deskClock", "Sculpted desk clock", "clock", "A bowed, tapered hollow case with separate bezel, dial, back and hands. Movement fit and fastening require measured hardware.", [
    .init("width","Case width",180,140...230), .init("height","Case height",166,130...215),
    .init("depth","Case depth",54,40...80), .init("wall","Case wall",3,2.4...5,step:0.1),
    .init("taper","Top taper",14,5...20,unit:"%",step:0.5),
    .init("roundness","Outline roundness",3.8,3.2...4.6,unit:"",step:0.1),
    .init("bevel","Edge roll",1.4,0.6...2,step:0.1),
    .init("bore","Dial shaft bore",8.2,5...12,step:0.1),
    .init("hour","Hour",10,1...12,unit:"h",step:1), .init("minute","Minute",12,0...59,unit:"min",step:1),
    .init("hands","Show hands",1,0...1,unit:"",step:1),
  ])
  public static let components = ["Case shell","Bezel","Inner surround","Dial","Back cover","Hour hand","Minute hand","Foot (print 4)"]
  public static let samples = 512
  public static func outline(_ object:ProductObject,inset:Double = 0)->[Point2] {
    let w=object["width"],h=object["height"],n=object["roundness"],t=object["taper"]/100
    var points=(0..<samples).map { i -> Point2 in
      // Mid-sample avoids repeated vertices on the axes. The shape is convex;
      // the inward polygon offset gives an actual normal wall, not XY scaling.
      let a=(Double(i)+0.5)*2 * Double.pi/Double(samples),c=cos(a),s=sin(a)
      let y=(s<0 ? -1.0:1.0)*pow(abs(s),2/n)
      let x=(c<0 ? -1.0:1.0)*pow(abs(c),2/n)*(1-t*(y+1)/2)
      return .init(x*w/2,y*h/2)
    }
    let minX=points.map(\.x).min()!,maxX=points.map(\.x).max()!,minY=points.map(\.y).min()!,maxY=points.map(\.y).max()!
    points=points.map{.init(($0.x-(minX+maxX)/2)*w/(maxX-minX),($0.y-(minY+maxY)/2)*h/(maxY-minY))}
    guard inset != 0 else{return points}
    return points.indices.map { i in
      let p=points[i],a=points[(i+samples-1)%samples],b=points[(i+1)%samples]
      let ax=p.x-a.x,ay=p.y-a.y,bx=b.x-p.x,by=b.y-p.y
      let al=hypot(ax,ay),bl=hypot(bx,by)
      let nx = -ay/al-by/bl,ny=ax/al+bx/bl,length=hypot(nx,ny)
      let ux=nx/length,uy=ny/length,denom=ux*(-ay/al)+uy*(ax/al)
      return .init(p.x+ux*inset/denom,p.y+uy*inset/denom)
    }
  }
  public static func boundary(_ object:ProductObject)->VectorPath {
    let w=object["width"],h=object["height"]
    var contours:[VectorContour]=[]
    for (index,points) in [outline(object,inset:10.5),(0..<samples).map{i in let a=Double(i)*2 * Double.pi/Double(samples);return Point2(cos(a)*object["bore"]/2,sin(a)*object["bore"]/2)}].enumerated() {
      let nodes=points.enumerated().map {i,p -> BezierNode in
        var node=BezierNode(.init(p.x+w/2,h/2-p.y));node.id=UUID(uuidString:String(format:"00000000-D35C-0000-%04d-%012d",index,i))!;return node
      }
      contours.append(.init(nodes,closed:true))
    }
    return .init(width:w,height:h,contours:contours,evenOdd:true)
  }
}
