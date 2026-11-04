import AppKit
import CryptoKit
import FormCore
import FormGeometry
import FormGraphics
import ImageIO
import LabRendering
import simd

/// Render the saved needle program in physical millimeters. Travel is never
/// drawn, and separate stitches cannot acquire spurious connecting segments.
@MainActor enum CyclesEmbroidery {
  static func curves(object:ProductObject,project:Project,faceNode:MeshNode,assets:URL,
    frame:(UUID)->ClothFrame?,attachedSurface:CyclesAttachedSurface?=nil,deferAttachedMapping:Bool=false)throws->[SceneCurvePayload] {
    let program=try EmbroideryDigitizer.generate(object:object,project:project)
    return try curves(program:program,object:object,project:project,faceNode:faceNode,assets:assets,frame:frame,attachedSurface:attachedSurface,deferAttachedMapping:deferAttachedMapping)
  }

  static func curves(program:EmbroideryProgram,object:ProductObject,project:Project,faceNode:MeshNode,assets:URL,
    frame:(UUID)->ClothFrame?,attachedSurface:CyclesAttachedSurface?=nil,deferAttachedMapping:Bool=false)throws->[SceneCurvePayload] {
    try program.validate()
    let attached=try attachedSurface ?? CyclesAttachedSurface(object:object,project:project,frame:frame)
    let mapping=try attached != nil && !deferAttachedMapping ? attached!.makeSurface():nil
    var mappingBudget=mapping?.makeBudget() ?? .init(),totalKeys=0
    let diameter=program.design.process?.threadDiameter ?? 0.22,radius=Float(diameter/2)
    var groups=[Int:CurveGroup](),previous=Point2(),crossings=Crossings(diameter:diameter)
    for (index,command) in program.commands.enumerated() {
      if index.isMultiple(of:512) {try Task.checkCancellation()}
      let point=command.point
      defer {previous=point}
      guard command.action == .stitch,hypot(point.x-previous.x,point.y-previous.y)>1e-8 else {continue}
      // Needle penetration fixes the endpoints. Interior keys rise above the
      // textile and previously laid crossing strands in sewing order.
      let profile=try crossings.add(from:previous,to:point,command:index)
      let thread=command.threadIndex,start=UInt32(groups[command.threadIndex]?.points.count ?? 0)
      groups[thread,default:CurveGroup()].firstKey.append(start)
      var local=[SIMD3<Double>]()
      for key in profile.values.indices {
        let t=Double(key)/Double(profile.values.count-1),sample=Point2(previous.x+(point.x-previous.x)*t,previous.y+(point.y-previous.y)*t)
        let height=diameter*0.25+profile.values[key]
        if attached != nil {local.append(.init(sample.x,object["height"]/2+height,sample.y))}
        else {
          let world=faceNode.convertPosition(.init(sample.x/100,-sample.y/100,(height-0.15-object["height"]/2)/100),to:nil)
          local.append(.init(world.x*100,world.y*100,world.z*100))
        }
      }
      let points=try mapping?.deformCurve(local,budget:&mappingBudget) ?? local
      totalKeys+=points.count
      guard totalKeys<=2_000_000 else {throw FormError.invalid("Embroidery curves exceed the rendering key budget.")}
      groups[thread,default:CurveGroup()].points+=points
      groups[thread,default:CurveGroup()].radii+=Array(repeating:radius,count:points.count)
    }
    return try groups.keys.sorted().map {threadIndex in
      let group=groups[threadIndex]!,thread=program.design.threads[threadIndex]
      let appearance=thread.resolvedAppearance
      try appearance.validate()
      for texture in appearance.textures.values {
        let url=try texture.verifiedURL(in:assets)
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceCreateImageAtIndex(source,0,nil) != nil else {
          throw FormError.invalid("A thread appearance texture cannot be decoded: \(texture.asset).")
        }
      }
      let identity="\(object.id.uuidString):thread:\(threadIndex)",color=GeometryPayloadAdapter.color(NSColor(hex:thread.color))
      var material=SceneMaterialPayload(id:identity,revision:program.sourceDigest,baseColor:color,roughness:Float(thread.roughness ?? 0.5))
      material.physicalAppearance=try GeometryPayloadAdapter.physicalPayload(appearance.meshAppearance(assets:assets,surfaceSizeMM:.init(1,1)),assets:assets)
      var digest=SHA256();digest.update(data:Data(program.sourceDigest.utf8));digest.update(data:try JSONEncoder.form.encode(thread))
      // Deformed frames and ordinary node placement both change the revision.
      for p in group.points {for coordinate in [p.x,p.y,p.z] {withUnsafeBytes(of:coordinate.bitPattern.littleEndian) {digest.update(bufferPointer:$0)}}}
      let revision=digest.finalize().map{String(format:"%02x",$0)}.joined()
      let payload=SceneCurvePayload(id:identity,revision:revision,objectID:object.id,pointsMM:group.points,radiiMM:group.radii,firstKey:group.firstKey,material:material)
      try payload.validate();return payload
    }
  }

  private struct CurveGroup {var points=[SIMD3<Double>]();var radii=[Float]();var firstKey=[UInt32]()}
  /// Uniform material-coordinate keys make the Cycles Catmull-Rom centerline
  /// predictable. Only the clamped first/last span needs a parameter inversion.
  private struct HeightProfile {
    var values:[Double]
    func basis(at position:Double)->[(Int,Double)] {
      let steps=values.count-1,x=min(1,max(0,position))*Double(steps)
      let span=min(steps-1,Int(floor(x)));var t=x-Double(span)
      if span==0 || span==steps-1 {
        let target=span==0 ? t:1-t
        var u=target
        for _ in 0..<8 {u=min(1,max(0,u-(0.5*u+u*u-0.5*u*u*u-target)/(0.5+2*u-1.5*u*u)))}
        t=span==0 ? u:1-u
      }
      let t2=t*t,t3=t2*t
      return [(max(0,span-1),-0.5*t+t2-0.5*t3),(span,1-2.5*t2+1.5*t3),
        (span+1,0.5*t+2*t2-1.5*t3),(min(steps,span+2),-0.5*t2+0.5*t3)]
    }
    func height(at t:Double)->Double {basis(at:t).reduce(0){$0+values[$1.0]*$1.1}}
  }

  private struct Crossings {
    struct Segment {var a:Point2;var b:Point2;var profile:HeightProfile;var command:Int}
    struct Cell:Hashable {var x:Int;var y:Int}
    var diameter:Double;var segments=[Segment]();var cells=[Cell:[Int]]()
    var work=0,entries=0,totalKeys=0
    mutating func add(from a:Point2,to b:Point2,command:Int)throws->HeightProfile {
      let size=max(1,diameter*4)
      let x0=Int(floor((min(a.x,b.x)-diameter)/size)),x1=Int(floor((max(a.x,b.x)+diameter)/size))
      let y0=Int(floor((min(a.y,b.y)-diameter)/size)),y1=Int(floor((max(a.y,b.y)+diameter)/size))
      var candidates=Set<Int>(),addresses=[Cell]()
      for y in y0...y1 {for x in x0...x1 {let cell=Cell(x:x,y:y);addresses.append(cell);for value in cells[cell] ?? [] {candidates.insert(value)}}}
      let peak=max(0.08,diameter*0.65),base=HeightProfile(values:[0,peak*0.75,peak,peak*0.75,0])
      let rx=b.x-a.x,ry=b.y-a.y,length=hypot(rx,ry)
      // <=0.5 diameter between keys resolves a local crossover without lifting
      // the remote middle of the stitch. Uncrossed stitches retain five keys.
      let steps=max(4,Int(ceil(length/(diameter*0.5)/4))*4)
      guard steps<=256 else {throw FormError.invalid("A stitch exceeds the bounded crossing-resolution length.")}
      let clearance=diameter*1.05
      var contacts=[Double:Double]()
      for index in candidates.sorted() {
        work+=1
        guard work<=32_000_000 else {throw FormError.invalid("Thread crossings exceed the rendering work budget. Split the render into smaller sources.")}
        let old=segments[index],sx=old.b.x-old.a.x,sy=old.b.y-old.a.y,oldLength=hypot(sx,sy)
        let qx=old.a.x-a.x,qy=old.a.y-a.y,det=rx*sy-ry*sx,radius=diameter*0.5
        var intersection:(Double,Double)?
        if abs(det)>1e-10*length*oldLength {
          let t=(qx*sy-qy*sx)/det,u=(qx*ry-qy*rx)/det
          // Nearby satin legs and shared needle turns do not establish an
          // above/below crossing. Only their interior intersection does.
          guard min(t,1-t)*length>radius,min(u,1-u)*oldLength>radius else {continue}
          intersection=(t,u)
        } else {
          // Coincident tie retraces are real layers. Parallel neighboring rows
          // are not: allow only floating-point collinearity, not a radius band.
          guard oldLength>diameter,abs(qx*ry-qy*rx)<=length*1e-7 else {continue}
          let u0=radius/oldLength,u1=1-u0
          let t0=((qx+sx*u0)*rx+(qy+sy*u0)*ry)/(length*length)
          let t1=((qx+sx*u1)*rx+(qy+sy*u1)*ry)/(length*length)
          guard min(1-radius/length,max(t0,t1))>max(radius/length,min(t0,t1))+1e-9 else {continue}
        }
        func contact(_ t:Double,_ u:Double) {
          // A shared needle hole is penetration, not an above-fabric stack.
          guard t>0,t<1,u>0,u<1,min(t,1-t)*length>diameter*0.5,min(u,1-u)*oldLength>diameter*0.5 else{return}
          let dx=a.x+rx*t-old.a.x-sx*u,dy=a.y+ry*t-old.a.y-sy*u,distanceSquared=dx*dx+dy*dy
          guard distanceSquared<clearance*clearance else{return}
          let required=old.profile.height(at:u)+sqrt(clearance*clearance-distanceSquared)
          guard required>base.height(at:t)+1e-9 else{return}
          contacts[t]=max(contacts[t] ?? 0,required)
        }
        // Sample both centerlines, plus the exact planar intersection. This
        // includes shallow-angle and collinear retraces, not only point crosses.
        // Consecutive tie stitches may overlap away from their common needle.
        work+=steps*2+old.profile.values.count*2+1
        guard work<=32_000_000 else {throw FormError.invalid("Thread crossings exceed the rendering work budget. Split the render into smaller sources.")}
        for key in 1..<steps*2 {
          let t=Double(key)/Double(steps*2),px=a.x+rx*t,py=a.y+ry*t
          contact(t,((px-old.a.x)*sx+(py-old.a.y)*sy)/(oldLength*oldLength))
        }
        let oldSteps=(old.profile.values.count-1)*2
        for key in 1..<oldSteps {
          let u=Double(key)/Double(oldSteps),px=old.a.x+sx*u,py=old.a.y+sy*u
          contact(((px-a.x)*rx+(py-a.y)*ry)/(length*length),u)
        }
        if let intersection {contact(intersection.0,intersection.1)}
      }
      var profile=base
      if !contacts.isEmpty {
        guard contacts.count<=4096 else {throw FormError.invalid("A stitch exceeds the bounded local crossing budget.")}
        profile=HeightProfile(values:(0...steps).map{base.height(at:Double($0)/Double(steps))})
        var constraints=contacts
        for key in 1..<steps*2 {let t=Double(key)/Double(steps*2);constraints[t]=max(constraints[t] ?? 0,base.height(at:t))}
        let ordered=constraints.sorted{$0.key<$1.key}
        // Start from a local upper envelope, so several nearby samples of one
        // contact do not repeatedly accumulate the same physical separation.
        for (t,minimum) in ordered {
          let span=min(steps-1,Int(t*Double(steps)))
          for key in max(1,span)...min(steps-1,span+1) {profile.values[key]=max(profile.values[key],minimum)}
        }
        // Lift only positive interpolation weights at each local contact.
        // Raising the negative outer keys would deepen adjacent undershoots
        // and amplify successive short retraces into artificial tall loops.
        // Rechecking accounts for Catmull-Rom's negative outer weights and prevents
        // neighboring lifted keys from pulling the centerline into the textile.
        var satisfied=false
        for _ in 0..<12 {
          satisfied=true
          for (t,minimum) in ordered {
            let basis=profile.basis(at:t),missing=minimum-profile.height(at:t)
            if missing<=1e-8 {continue};satisfied=false
            var weights=[Int:Double]()
            for (key,weight) in basis where key>0 && key<steps {weights[key,default:0]+=weight}
            let positive=weights.filter{$0.value>0},norm=positive.values.reduce(0){$0+$1*$1}
            guard norm>0.25 else {throw FormError.invalid("A local thread crossing cannot retain its needle endpoints.")}
            for (key,weight) in positive {profile.values[key]+=(missing+diameter*0.00001)*weight/norm}
          }
          if satisfied {break}
        }
        guard satisfied || ordered.allSatisfy({profile.height(at:$0.key)>=$0.value-1e-7}) else {throw FormError.invalid("The local thread crossing clearance did not converge within its bounded work budget.")}
        guard profile.values.allSatisfy({$0.isFinite && $0<=max(5,diameter*64)}) else {throw FormError.invalid("The thread crossing stack is too tall. Split the design into physical layers.")}
      }
      totalKeys+=profile.values.count
      guard totalKeys<=2_000_000 else {throw FormError.invalid("Embroidery curves exceed the rendering key budget. Split the render into smaller sources.")}
      let index=segments.count;segments.append(.init(a:a,b:b,profile:profile,command:command))
      for address in addresses {entries+=1;guard entries<=2_000_000 else {throw FormError.invalid("Thread crossings exceed the rendering spatial budget.")};cells[address,default:[]].append(index)}
      return profile
    }
  }
}
