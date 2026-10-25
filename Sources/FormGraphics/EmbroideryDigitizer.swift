import AppKit
import CoreGraphics
import CryptoKit
import FormCore

/// Deterministic geometry digitizer. It emits actual needle/travel commands;
/// source artwork remains editable and is resolved again for every export.
@MainActor public enum EmbroideryDigitizer {
  public static let flatteningTolerance=0.05 // mm before 0.1 mm needle quantization
  private static let maximumGeometryPoints=100000
  private struct Contour {var points:[CGPoint];var closed:Bool}
  private struct Shape {
    var path:CGPath
    var rule:CGPathFillRule
    var contours:[Contour]
    var clips:[(CGPath,CGPathFillRule)]
    var clipContours:[Contour]
    func contains(_ point:CGPoint)->Bool {
      path.contains(point,using:rule) && clips.allSatisfy {$0.0.contains(point,using:$0.1)}
    }
  }
  private static func distance(_ a:CGPoint,_ b:CGPoint)->Double {hypot(a.x-b.x,a.y-b.y)}
  private static func interpolate(_ a:CGPoint,_ b:CGPoint,_ t:Double)->CGPoint {.init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)}
  private static func segmentDistance(_ p:CGPoint,_ a:CGPoint,_ b:CGPoint)->Double {
    let length=pow(b.x-a.x,2)+pow(b.y-a.y,2)
    let t=length>0 ? min(1,max(0,((p.x-a.x)*(b.x-a.x)+(p.y-a.y)*(b.y-a.y))/length)):0
    return distance(p,interpolate(a,b,t))
  }
  private static func flatten(_ path:CGPath,budget:inout Int)throws -> [Contour] {
    var result:[Contour]=[],points:[CGPoint]=[],closed=false,error:Error?
    func append(_ point:CGPoint)throws {
      guard budget>0,point.x.isFinite,point.y.isFinite else {throw FormError.invalid("Embroidery source exceeds 100000 finite flattened points. Simplify the geometry.")}
      if points.last.map({distance($0,point)<1e-10}) == true {return}
      points.append(point);budget-=1
    }
    func finish() {if !points.isEmpty {result.append(.init(points:points,closed:closed))};points=[];closed=false}
    func cubic(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint,_ d:CGPoint,_ depth:Int)throws {
      if max(segmentDistance(b,a,d),segmentDistance(c,a,d))<=flatteningTolerance {try append(d);return}
      guard depth<20 else {throw FormError.invalid("The curve cannot be flattened within 0.05 mm. Simplify its handles.")}
      let ab=interpolate(a,b,0.5),bc=interpolate(b,c,0.5),cd=interpolate(c,d,0.5)
      let abc=interpolate(ab,bc,0.5),bcd=interpolate(bc,cd,0.5),middle=interpolate(abc,bcd,0.5)
      try cubic(a,ab,abc,middle,depth+1);try cubic(middle,bcd,cd,d,depth+1)
    }
    path.applyWithBlock { pointer in
      guard error==nil else {return}
      let value=pointer.pointee
      do {
        switch value.type {
        case .moveToPoint:finish();try append(value.points[0])
        case .addLineToPoint:try append(value.points[0])
        case .addCurveToPoint:
          guard let last=points.last else {throw FormError.invalid("A curve needs a starting point.")}
          try cubic(last,value.points[0],value.points[1],value.points[2],0)
        case .addQuadCurveToPoint:
          guard let last=points.last else {throw FormError.invalid("A curve needs a starting point.")}
          let control=value.points[0],end=value.points[1]
          try cubic(last,interpolate(last,control,2.0/3),interpolate(end,control,2.0/3),end,0)
        case .closeSubpath:closed=true;finish()
        @unknown default:throw FormError.invalid("Unsupported embroidery source segment.")
        }
      } catch let problem {error=problem}
    }
    if let error {throw error};finish();return result
  }
  private static func resample(_ points:[CGPoint],closed:Bool,spacing:Double,uniform:Bool = false)throws -> [CGPoint] {
    guard points.count>=2 else {return []}
    var input=points
    if closed,distance(input[0],input.last!)>1e-9 {input.append(input[0])}
    if uniform {
      let lengths=(1..<input.count).map {distance(input[$0-1],input[$0])},total=lengths.reduce(0,+)
      let count=max(1,Int(ceil(total/spacing)))
      guard count<=100000 else {throw FormError.invalid("This satin centerline exceeds the bounded sample count. Increase spacing.")}
      var result=[input[0]],segment=0,offset=0.0
      for step in 1...count {
        let target=total*Double(step)/Double(count)
        while segment+1<lengths.count,offset+lengths[segment]<target {offset+=lengths[segment];segment+=1}
        result.append(interpolate(input[segment],input[segment+1],lengths[segment]>0 ? min(1,(target-offset)/lengths[segment]):0))
      }
      return result
    }
    var result=[input[0]]
    for index in 1..<input.count {
      let length=distance(input[index-1],input[index])
      let count=max(1,Int(ceil(length/spacing)))
      guard result.count+count<=100000 else {throw FormError.invalid("This path exceeds the bounded stitch/sample count. Increase spacing.")}
      for step in 1...count {result.append(interpolate(input[index-1],input[index],Double(step)/Double(count)))}
    }
    return result
  }

  public static func defaultDesign(object:ProductObject,project:Project)throws -> EmbroideryDesign {
    guard object.textile?.kind != .garment,object.textile != nil,let art=project.surfaceArtwork(object) else {throw FormError.invalid("Choose a textile decoration with editable source artwork.")}
    let materialized=try BooleanGeometry.materialized(art),masks=Set(materialized.elements.compactMap(\.clipID))
    let roles=ArtworkProduction.effectiveRoles(in:materialized)
    let eligible=materialized.elements.filter {$0.kind != "group" && !masks.contains($0.id) && $0.hidden != true && [.print,.stitch].contains(roles[$0.id] ?? .print)}
    let usesStitch=eligible.contains {roles[$0.id] == .stitch}
    let selected=eligible.filter {!usesStitch || roles[$0.id] == .stitch}
    guard !selected.isEmpty,selected.count<=128,!selected.contains(where:{$0.kind == "image" || $0.component != nil || $0.hasActiveEffects || $0.gradient != nil}) else {throw FormError.invalid("Digitizing needs 1–128 plain vector/text sources. Trace images, flatten effects, and separate gradient colors first.")}
    var threads:[EmbroideryThread]=[],regions:[EmbroideryRegion]=[]
    for element in selected {
      let running=element.kind == "line" || element.fillEnabled == false || element.path?.contours.contains(where:{!$0.closed}) == true
      let color=(running ? element.stroke?.color ?? element.color:element.color).uppercased()
      let index:Int
      if let existing=threads.firstIndex(where:{$0.color==color}) {index=existing}
      else {index=threads.count;threads.append(.init(name:"Thread \(index+1)",color:color))}
      regions.append(.init(elementIDs:[element.id],method:running ? .running:.fill,threadIndex:index))
    }
    var design=EmbroideryDesign(threads:threads,regions:regions)
    design.hoopWidth=max(100,ceil((object.artworkSize.x+10)/10)*10)
    design.hoopHeight=max(100,ceil((object.artworkSize.y+10)/10)*10)
    try design.validate();return design
  }

  public static func generate(object:ProductObject,project:Project,design:EmbroideryDesign? = nil)throws -> EmbroideryProgram {
    guard let design=design ?? object.textile?.embroidery else {throw FormError.invalid("Configure an embroidery source before generating stitches.")}
    try design.validate()
    guard object.textile != nil,object.textile?.kind != .garment else {throw FormError.invalid("Digitize a textile decoration with a physical artwork face.")}
    guard let raw=project.surfaceArtwork(object) else {throw FormError.invalid("This decoration has no editable artwork source.")}
    let art=try BooleanGeometry.materialized(raw).withInheritedLanguage.resolvingLists
    let byID=Dictionary(uniqueKeysWithValues:art.elements.map {($0.id,$0)}),masks=Set(art.elements.compactMap(\.clipID))
    var geometryBudget=maximumGeometryPoints,workBudget=2_000_000,shapeCache:[UUID:Shape]=[:]
    var signature=try JSONEncoder.form.encode(art);signature.append(try JSONEncoder.form.encode(design))
    let size=object.artworkSize
    let center=CGAffineTransform(translationX:-size.x/2,y:-size.y/2)
    let rect=CGRect(x:-size.x/2,y:-size.y/2,width:size.x,height:size.y)
    let corner=min(max(0,object["corner"]),min(size.x,size.y)/2)
    let face=CGPath(roundedRect:rect,cornerWidth:corner,cornerHeight:corner,transform:nil)
    var faceContours=try flatten(face,budget:&geometryBudget)
    var boundary:CGPath?
    if let path=art.boundary {
      var element=ArtworkElement(kind:"path",x:0,y:0,width:path.width,height:path.height);element.path=path
      var transform=center
      boundary=VectorGeometry.path(element).copy(using:&transform)
      if let boundary {faceContours += try flatten(boundary,budget:&geometryBudget)}
    }
    func shape(_ element:ArtworkElement)throws -> Shape {
      if let cached=shapeCache[element.id] {return cached}
      guard element.kind != "image",element.component==nil,element.gradient==nil else {throw FormError.invalid("\(element.title) needs plain vector geometry or outlined text before digitizing.")}
      var cursor:ArtworkElement?=element,clips:[(CGPath,CGPathFillRule)]=[(face,.winding)],clipContours=faceContours
      if let boundary {clips.append((boundary,art.boundary?.evenOdd == true ? .evenOdd:.winding))}
      while let current=cursor {
        guard current.hidden != true,(current.opacity ?? 1)>0,!current.hasActiveEffects else {throw FormError.invalid("A digitizing region references hidden or effect-bearing artwork. Make its source explicit and visible first.")}
        if let clip=current.clipID,let mask=byID[clip] {
          var transform=center
          guard let path=VectorGeometry.worldPath(mask,in:art).copy(using:&transform) else {throw FormError.invalid("Could not resolve the embroidery clip.")}
          clips.append((path,mask.path?.evenOdd == true ? .evenOdd:.winding));clipContours += try flatten(path,budget:&geometryBudget)
        }
        cursor=current.parentID.flatMap {byID[$0]}
      }
      let local=element.kind == "text" ? try TypographyEngine.outlines(element):VectorGeometry.path(element)
      var transform=art.worldTransform(element).cg.concatenating(center)
      guard let path=local.copy(using:&transform) else {throw FormError.invalid("Could not resolve embroidery source geometry.")}
      let contours=try flatten(path,budget:&geometryBudget)
      signature.append(Data(SVGRenderer.data(path).utf8))
      let result=Shape(path:path,rule:element.path?.evenOdd == true ? .evenOdd:.winding,contours:contours,clips:clips,clipContours:clipContours)
      shapeCache[element.id]=result;return result
    }
    var commands:[EmbroideryCommand]=[],position=Point2(),currentThread:Int?,stitches=0,currentRegion:UUID?
    func append(_ action:EmbroideryCommand.Action,_ point:CGPoint,thread:Int)throws {
      let x=Int((point.x*10).rounded(.toNearestOrEven)),y=Int((point.y*10).rounded(.toNearestOrEven))
      guard commands.count<200000 else {throw FormError.invalid("Embroidery command count exceeds 200000. Simplify or split the design.")}
      if action == .stitch {stitches+=1;guard stitches<=design.maximumStitches else {throw FormError.invalid("Generated stitches exceed the configured limit. Increase spacing or split the design.")}}
      commands.append(.init(action,x:x,y:y,threadIndex:thread,regionID:currentRegion));position = .init(Double(x)/10,Double(y)/10)
    }
    func travel(_ point:CGPoint,thread:Int)throws {
      if let currentThread,currentThread != thread {try append(.trim,CGPoint(x:position.x,y:position.y),thread:currentThread);try append(.colorChange,CGPoint(x:position.x,y:position.y),thread:thread)}
      currentThread=thread
      let distance=hypot(point.x-position.x,point.y-position.y)
      if distance>design.trimJumpThreshold,!commands.isEmpty,commands.last?.action != .colorChange {try append(.trim,CGPoint(x:position.x,y:position.y),thread:thread)}
      if distance>0.049 {try append(.jump,point,thread:thread)}
    }
    func sew(_ point:CGPoint,thread:Int,length:Double,first:Bool = false)throws {
      let start=CGPoint(x:position.x,y:position.y),count=max(1,Int(ceil(distance(start,point)/length)))
      for step in 1...count {
        let next=interpolate(start,point,Double(step)/Double(count))
        if first || Int((next.x*10).rounded(.toNearestOrEven)) != Int((position.x*10).rounded(.toNearestOrEven)) || Int((next.y*10).rounded(.toNearestOrEven)) != Int((position.y*10).rounded(.toNearestOrEven)) {
          try append(.stitch,next,thread:thread)
        }
      }
    }
    for region in design.regions {
      let regionStart=stitches
      currentRegion=region.id
      guard Set(region.elementIDs).isSubset(of:Set(byID.keys)) else {throw FormError.invalid("A digitizing source was removed or converted. Reassign that region to existing artwork.")}
      let expanded=art.descendants(of:Set(region.elementIDs))
      let elements=art.elements.filter {expanded.contains($0.id) && $0.kind != "group" && !masks.contains($0.id)}
      guard !elements.isEmpty else {throw FormError.invalid("This digitizing region has no vector leaves.")}
      for element in elements {
        let source=try shape(element)
        switch region.method {
        case .running,.satin:
          for contour in source.contours {
            let samples=try resample(contour.points,closed:contour.closed,spacing:region.method == .running ? region.stitchLength:region.spacing,uniform:region.method == .satin)
            guard samples.count>=2 else {continue}
            var points=samples
            if region.method == .satin {
              points=[]
              for index in samples.indices {
                let a=samples[max(0,index-1)],b=samples[min(samples.count-1,index+1)],length=distance(a,b)
                guard length>1e-8 else {continue}
                let sign=index%2 == 0 ? 1.0:-1.0
                points.append(.init(x:samples[index].x-(b.y-a.y)/length*region.satinWidth/2*sign,
                  y:samples[index].y+(b.x-a.x)/length*region.satinWidth/2*sign))
              }
            }
            guard let first=points.first else {continue}
            func contained(_ point:CGPoint)->Bool {
              source.clips.allSatisfy {$0.0.contains(point,using:$0.1)}
            }
            // Running/satin does not silently intersect or reroute a clipped
            // path. Accept already-contained geometry, checking travel along
            // each sewn segment at the same 0.05 mm physical tolerance.
            var last:CGPoint?
            for point in points {
              let needle=CGPoint(x:(point.x*10).rounded(.toNearestOrEven)/10,y:(point.y*10).rounded(.toNearestOrEven)/10)
              if let last {
                let steps=max(1,Int(ceil(distance(last,needle)/flatteningTolerance)))
                workBudget-=steps
                guard workBudget>=0 else {throw FormError.invalid("Running/satin containment exceeds its bounded geometry-work budget.")}
                guard (0...steps).allSatisfy({contained(interpolate(last,needle,Double($0)/Double(steps)))}) else {
                  throw FormError.invalid("A running/satin path leaves its face or clipping boundary. Inset the source, reduce satin width, or convert the clipped result to explicit paths.")
                }
              } else if !contained(needle) {
                throw FormError.invalid("A running/satin needle point leaves its face or clipping boundary. Inset the source or reduce satin width.")
              }
              last=needle
            }
            try travel(first,thread:region.threadIndex);try sew(first,thread:region.threadIndex,length:region.stitchLength,first:true)
            for point in points.dropFirst() {try sew(point,thread:region.threadIndex,length:region.stitchLength)}
          }
        case .fill:
          guard source.contours.allSatisfy(\.closed) else {throw FormError.invalid("Fill needs closed contours. Use running or satin for an open path.")}
          let angle=region.angle * .pi/180,c=cos(angle),s=sin(angle)
          func rotated(_ p:CGPoint)->CGPoint {.init(x:p.x*c+p.y*s,y:-p.x*s+p.y*c)}
          func original(_ p:CGPoint)->CGPoint {.init(x:p.x*c-p.y*s,y:p.x*s+p.y*c)}
          let contours=(source.contours+source.clipContours).filter(\.closed).map {$0.points.map(rotated)}
          let points=source.contours.flatMap(\.points).map(rotated)
          guard let low=points.map(\.y).min(),let high=points.map(\.y).max() else {continue}
          let rows=max(1,Int(ceil((high-low)/region.spacing)))
          guard rows<=10000 else {throw FormError.invalid("Fill exceeds 10000 rows. Increase row spacing.")}
          for row in 0..<rows {
            let y=low+(Double(row)+0.5)*(high-low)/Double(rows)
            var crossings:[Double]=[]
            for contour in contours where contour.count>=3 {
              workBudget-=contour.count
              guard workBudget>=0 else {throw FormError.invalid("Digitizing exceeds its geometry-work budget. Simplify curves, split regions, or increase row spacing.")}
              for index in contour.indices {
                let a=contour[index],b=contour[(index+1)%contour.count]
                if (a.y<=y && b.y>y) || (b.y<=y && a.y>y) {crossings.append(a.x+(y-a.y)*(b.x-a.x)/(b.y-a.y))}
              }
            }
            crossings.sort()
            var intervals:[(Double,Double)]=[]
            for index in 1..<max(1,crossings.count) {
              let a=crossings[index-1],b=crossings[index]
              // Keep the quantized needle inside both the flattened curve's
              // 0.05 mm error and the 0.1 mm coordinate grid's half-step.
              if b-a>0.24,source.contains(original(.init(x:(a+b)/2,y:y))) {intervals.append((a+0.11,b-0.11))}
            }
            if row%2 != 0 {intervals.reverse()}
            for interval in intervals {
              let a=original(.init(x:row%2 == 0 ? interval.0:interval.1,y:y)),b=original(.init(x:row%2 == 0 ? interval.1:interval.0,y:y))
              try travel(a,thread:region.threadIndex);try sew(a,thread:region.threadIndex,length:region.stitchLength,first:true)
              try sew(b,thread:region.threadIndex,length:region.stitchLength)
            }
          }
        }
      }
      guard stitches>regionStart else {throw FormError.invalid("A digitizing region produced no stitches. Enlarge its geometry, reduce spacing, or choose a path method.")}
    }
    guard let thread=currentThread else {throw FormError.invalid("No stitches could be generated from these regions.")}
    try append(.trim,CGPoint(x:position.x,y:position.y),thread:thread);try append(.end,CGPoint(x:position.x,y:position.y),thread:thread)
    let digest=SHA256.hash(data:signature).map {String(format:"%02x",$0)}.joined()
    let result=EmbroideryProgram(name:object.name,sourceDigest:digest,design:design,commands:commands)
    try result.validate();return result
  }
}
