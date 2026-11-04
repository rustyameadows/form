import AppKit
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class CyclesEmbroideryTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  private func fixture()throws->(Project,ProductObject,MeshNode) {
    _ = NSApplication.shared
    var project=Project(name:"Curve contract")
    var object=try project.makeObject(recipeID:"textilePatch",parameters:["width":40,"depth":40,"height":1,"corner":0])
    let line=ArtworkElement(kind:"line",x:16,y:20,width:8,height:0.1,color:"#BB2244")
    object.artwork = .init(background:"#FFFFFF",elements:[line])
    var design=EmbroideryDesign(threads:[.init(name:"First",color:"#BB2244"),.init(name:"Second",color:"#22BB44")],regions:[.init(elementIDs:[line.id],method:.running)])
    design.process=EmbroideryProcess();design.process!.threadDiameter=0.4
    object.textile?.embroidery=design;project.objects=[object]
    let face=MeshNode();face.eulerAngles.x = -.pi/2;face.position = .init(0,(object["height"]+0.15)/100,0)
    return (project,object,face)
  }
  private func program(_ object:ProductObject,_ commands:[EmbroideryCommand])->EmbroideryProgram {
    .init(name:"Needle contract",sourceDigest:"source",design:object.textile!.embroidery!,commands:commands)
  }
  private func simpleProgram(_ object:ProductObject)->EmbroideryProgram {
    program(object,[.init(.jump,x:-40,y:0,threadIndex:0),.init(.stitch,x:40,y:0,threadIndex:0),.init(.end,x:40,y:0,threadIndex:0)])
  }
  private func strands(_ curve:SceneCurvePayload)->[[SIMD3<Double>]] {
    curve.firstKey.indices.map {i in
      let end=i+1<curve.firstKey.count ? Int(curve.firstKey[i+1]):curve.pointsMM.count
      return Array(curve.pointsMM[Int(curve.firstKey[i])..<end])
    }
  }
  /// Evaluate the same clamped Catmull-Rom curve as Cycles, rather than only
  /// testing heights at control keys (a crossing may lie between those keys).
  private func point(_ keys:[SIMD3<Double>],axis:Int,coordinate:Double)->SIMD3<Double> {
    func at(_ fraction:Double)->SIMD3<Double> {
      let value=fraction*Double(keys.count-1),i=min(keys.count-2,Int(value)),t=value-Double(i)
      let p0=keys[max(0,i-1)],p1=keys[i],p2=keys[i+1],p3=keys[min(keys.count-1,i+2)]
      return p1+(p2-p0)*(0.5*t)+(p0*2-p1*5+p2*4-p3)*(0.5*t*t)+(-p0+p1*3-p2*3+p3)*(0.5*t*t*t)
    }
    let increasing=keys.last![axis]>keys.first![axis];var lo=0.0,hi=1.0
    for _ in 0..<48 {let mid=(lo+hi)/2;if (at(mid)[axis]<coordinate)==increasing {lo=mid}else{hi=mid}}
    return at((lo+hi)/2)
  }
  /// Include cubic extrema between keys when reporting actual curve height.
  private func maximumY(_ keys:[SIMD3<Double>])->Double {
    var result=keys.map(\.y).max()!
    for i in 0..<keys.count-1 {
      let p0=keys[max(0,i-1)].y,p1=keys[i].y,p2=keys[i+1].y,p3=keys[min(keys.count-1,i+2)].y
      let a=(p2-p0)/2,b=(2*p0-5*p1+4*p2-p3)/2,c=(-p0+3*p1-3*p2+p3)/2
      var roots=[Double]()
      if abs(c)<1e-12 {if abs(b)>1e-12 {roots.append(-a/(2*b))}}
      else {let d=4*b*b-12*c*a;if d>=0 {roots.append((-2*b+sqrt(d))/(6*c));roots.append((-2*b-sqrt(d))/(6*c))}}
      for t in roots where t>0 && t<1 {result=max(result,p1+a*t+b*t*t+c*t*t*t)}
    }
    return result
  }
  func testNeedleProgramCreatesIndependentStrandsWithPhysicalRadiusAndThreadAppearance()throws {
    var (project,object,face)=try fixture()
    var response=PhysicalAppearance();response.sheen=0.8;response.anisotropy=0.7
    object.textile!.embroidery!.threads[1].appearance=response;object.textile!.embroidery!.threads[1].roughness=0.2;project.objects=[object]
    let needle=program(object,[.init(.jump,x:-40,y:0,threadIndex:0),.init(.stitch,x:40,y:0,threadIndex:0),
      .init(.trim,x:40,y:0,threadIndex:0),.init(.colorChange,x:40,y:0,threadIndex:1),
      .init(.jump,x:-40,y:30,threadIndex:1),.init(.stitch,x:40,y:30,threadIndex:1),.init(.end,x:40,y:30,threadIndex:1)])
    let curves=try CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil})
    XCTAssertEqual(curves.count,2)
    for curve in curves {XCTAssertEqual(curve.pointsMM.count,5);XCTAssertEqual(curve.firstKey,[0]);XCTAssertEqual(curve.radiiMM,Array(repeating:0.2,count:5));try curve.validate()}
    XCTAssertEqual(curves[0].pointsMM[0].x,-4,accuracy:1e-8);XCTAssertEqual(curves[0].pointsMM[4].x,4,accuracy:1e-8)
    XCTAssertEqual(curves[1].pointsMM[0].z,3,accuracy:1e-8)
    XCTAssertGreaterThan(curves[0].pointsMM[2].y,curves[0].pointsMM[0].y)
    let top=object["height"]/2,radius=Double(curves[0].radiiMM[0])
    XCTAssertLessThan(curves[0].pointsMM[0].y-radius,top,"Needle endpoint must intersect the actual textile top, not float above the preview bias.")
    XCTAssertGreaterThan(curves[0].pointsMM[0].y+radius,top)
    XCTAssertGreaterThan(curves[0].pointsMM[2].y-radius,top,"The stitch interior must remain raised above the cloth.")
    XCTAssertEqual(curves[1].material.physicalAppearance?.sheen,0.8);XCTAssertEqual(curves[1].material.physicalAppearance?.anisotropy,0.7)
    XCTAssertEqual(curves[0].material.roughness,0.5);XCTAssertEqual(curves[1].material.roughness,0.2)
    XCTAssertNotEqual(curves[0].material.baseColor,curves[1].material.baseColor)
    let initial=curves[0].revision;face.position.x=1
    let moved=try CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil})
    XCTAssertEqual(moved[0].pointsMM[0].x,96,accuracy:1e-8);XCTAssertNotEqual(moved[0].revision,initial)
  }
  func testIndependentNeedleEndpointsIntersectActualBackingAtDifferentCalipersAndWorldTransforms()throws {
    for caliper in [0.4,1.0,2.8] {
      var (project,object,_)=try fixture();object.parameters["height"]=caliper;project.objects=[object]
      let original=project,needle=simpleProgram(object),diameter=object.textile!.embroidery!.process!.threadDiameter
      let decoration=TextileGeometry.decoration(object,project:project,assets:assets,textureLimit:64)
      let backing=try XCTUnwrap(decoration.childNode(withName:"Independent textile base",recursively:false))
      let face=try XCTUnwrap(decoration.childNode(withName:EmbroiderySceneSurface.faceName,recursively:false))
      let geometry=try XCTUnwrap(backing.geometry),vertices=geometry.sources(for:.vertex).flatMap(\.vectors).map(\.simd)
      let actualTop=try XCTUnwrap(vertices.map(\.z).max())
      // Use generated backing vertices, not the assumed height of the preview
      // plane, and move/tilt the complete construction in world coordinates.
      XCTAssertEqual(actualTop*100,caliper/2,accuracy:1e-8)
      let parent=MeshNode();parent.position = .init(0.63,0.81,-0.47);parent.eulerAngles = .init(0.32,-0.74,0.21)
      parent.addChildNode(decoration);decoration.position = .init(-0.12,0.09,0.18);decoration.eulerAngles.y=0.51
      let axisStart=backing.convertPosition(.init(),to:nil).simd,axisEnd=backing.convertPosition(.init(0,0,1),to:nil).simd
      let normal=simd_normalize(axisEnd-axisStart)
      let curve=try XCTUnwrap(CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil}).first)
      XCTAssertEqual(curve.firstKey,[0]);XCTAssertEqual(curve.pointsMM.count,5)
      for (index,x) in [(0,-4.0),(4,4.0)] {
        let contact=backing.convertPosition(.init(x/100,0,actualTop),to:nil).simd*100
        let offset=curve.pointsMM[index]-contact,distance=simd_dot(offset,normal),radius=Double(curve.radiiMM[index])
        XCTAssertEqual(distance,diameter/4,accuracy:1e-7)
        XCTAssertLessThan(simd_length(offset-normal*distance),1e-7,"The endpoint must retain its authored in-plane needle coordinates.")
        XCTAssertLessThan(distance-radius,0,"The needle endpoint's tube must intersect the actual backing, even after world transforms.")
        XCTAssertGreaterThan(distance+radius,0)
      }
      let middle=backing.convertPosition(.init(0,0,actualTop),to:nil).simd*100
      XCTAssertGreaterThan(simd_dot(curve.pointsMM[2]-middle,normal)-Double(curve.radiiMM[2]),0,"The interior arch remains above the backing.")
      XCTAssertEqual(geometry.sources(for:.vertex).flatMap(\.vectors).map(\.simd),vertices)
      XCTAssertEqual(project,original)
    }
  }
  func testCrossingsFollowSewingOrderWithoutDrawingTravel()throws {
    let (project,object,face)=try fixture()
    let needle=program(object,[.init(.jump,x:-40,y:0,threadIndex:0),.init(.stitch,x:40,y:0,threadIndex:0),
      .init(.jump,x:0,y:-40,threadIndex:0),.init(.stitch,x:0,y:40,threadIndex:0),.init(.end,x:0,y:40,threadIndex:0)])
    let curves=try CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil})
    XCTAssertEqual(curves.count,1);XCTAssertEqual(curves[0].firstKey.count,2)
    let paths=strands(curves[0]);XCTAssertEqual(paths.count,2)
    XCTAssertGreaterThanOrEqual(point(paths[1],axis:2,coordinate:0).y-point(paths[0],axis:0,coordinate:0).y,0.4)
    XCTAssertEqual(paths[1].first!.z,-4,accuracy:1e-8)
    XCTAssertLessThan(maximumY(paths[1])-object["height"]/2,0.9)
  }
  func testNearNeedleCrossingRaisesOnlyItsLocalNeighborhood()throws {
    var (project,object,face)=try fixture();object.textile!.embroidery!.process!.threadDiameter=0.22;project.objects=[object]
    let needle=program(object,[.init(.jump,x:-10,y:0,threadIndex:0),.init(.stitch,x:10,y:0,threadIndex:0),
      .init(.jump,x:0,y:-28,threadIndex:0),.init(.stitch,x:0,y:2,threadIndex:0),.init(.end,x:0,y:2,threadIndex:0)])
    let before=needle,curve=try XCTUnwrap(CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil}).first)
    let paths=strands(curve),lower=point(paths[0],axis:0,coordinate:0),upper=point(paths[1],axis:2,coordinate:0)
    XCTAssertGreaterThanOrEqual(upper.y-lower.y,0.22,"Actual curve clearance must remain at the off-key crossing.")
    XCTAssertLessThan(maximumY(paths[1])-object["height"]/2,0.8,"An underlay crossover cannot create the previous multi-millimeter upright loop.")
    XCTAssertLessThan(point(paths[1],axis:2,coordinate:-1.5).y-object["height"]/2,0.3,"The remote middle stays on the ordinary laid arch.")
    XCTAssertEqual(paths[1].first!.y,object["height"]/2+0.055,accuracy:1e-8)
    XCTAssertEqual(paths[1].last!.y,object["height"]/2+0.055,accuracy:1e-8)
    XCTAssertEqual(needle,before);XCTAssertLessThanOrEqual(curve.pointsMM.count,514)
  }
  func testConsecutiveTieRetracesKeepRealLayerOrderAndNeedlePenetrations()throws {
    var (project,object,face)=try fixture();object.textile!.embroidery!.process!.threadDiameter=0.22;project.objects=[object]
    let needle=program(object,[.init(.jump,x:-3,y:0,threadIndex:0),.init(.stitch,x:4,y:0,threadIndex:0),
      .init(.stitch,x:-3,y:0,threadIndex:0),.init(.stitch,x:4,y:0,threadIndex:0),.init(.stitch,x:-3,y:0,threadIndex:0),.init(.end,x:-3,y:0,threadIndex:0)])
    let curve=try XCTUnwrap(CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil}).first),paths=strands(curve)
    XCTAssertEqual(paths.count,4)
    for index in 1..<paths.count {
      XCTAssertGreaterThanOrEqual(point(paths[index],axis:0,coordinate:0.05).y-point(paths[index-1],axis:0,coordinate:0.05).y,0.22)
    }
    for path in paths {
      XCTAssertEqual(path.first!.y,object["height"]/2+0.055,accuracy:1e-8)
      XCTAssertEqual(path.last!.y,object["height"]/2+0.055,accuracy:1e-8)
    }
    XCTAssertLessThan(paths.map{maximumY($0)}.max()!-object["height"]/2,1.2)
  }
  func testNearbyParallelRowsDoNotAcquireChronologicalHeight()throws {
    var (project,object,face)=try fixture();object.textile!.embroidery!.process!.threadDiameter=0.22;project.objects=[object]
    var commands=[EmbroideryCommand]()
    for row in 0..<30 {
      commands.append(.init(.jump,x:-40,y:row*2,threadIndex:0))
      commands.append(.init(.stitch,x:40,y:row*2,threadIndex:0))
    }
    commands.append(.init(.end,x:40,y:58,threadIndex:0))
    let needle=program(object,commands),curve=try XCTUnwrap(CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil}).first)
    let paths=strands(curve);XCTAssertEqual(paths.count,30)
    for path in paths {XCTAssertEqual(maximumY(path)-object["height"]/2,0.198,accuracy:1e-8)}
  }
  func testDenseZigzagNeedleTurnsDoNotFormACrossingStaircase()throws {
    var (project,object,face)=try fixture();object.textile!.embroidery!.process!.threadDiameter=0.22;project.objects=[object]
    var commands=[EmbroideryCommand(.jump,x:-20,y:0,threadIndex:0)]
    for leg in 1...30 {commands.append(.init(.stitch,x:leg.isMultiple(of:2) ? -20:20,y:leg*2,threadIndex:0))}
    commands.append(.init(.end,x:-20,y:60,threadIndex:0))
    let needle=program(object,commands),curve=try XCTUnwrap(CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil}).first)
    let paths=strands(curve);XCTAssertEqual(paths.count,30)
    for (index,path) in paths.enumerated() {
      XCTAssertEqual(maximumY(path)-object["height"]/2,0.198,accuracy:1e-8)
      XCTAssertEqual(path.first!.z,Double(index)*0.2,accuracy:1e-8)
      XCTAssertEqual(path.last!.z,Double(index+1)*0.2,accuracy:1e-8)
    }
  }
  func testLongShallowCrossingKeepsClearanceAcrossTheOverlapFootprint()throws {
    var (project,object,face)=try fixture();object.textile!.embroidery!.process!.threadDiameter=0.22;project.objects=[object]
    let needle=program(object,[.init(.jump,x:-40,y:0,threadIndex:0),.init(.stitch,x:40,y:0,threadIndex:0),
      .init(.jump,x:-40,y:-4,threadIndex:0),.init(.stitch,x:40,y:4,threadIndex:0),.init(.end,x:40,y:4,threadIndex:0)])
    let curve=try XCTUnwrap(CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil}).first),paths=strands(curve)
    for step in -20...20 {
      let x=Double(step)/10,a=point(paths[0],axis:0,coordinate:x),b=point(paths[1],axis:0,coordinate:x)
      XCTAssertGreaterThanOrEqual(simd_distance(a,b),0.22-1e-6)
    }
    XCTAssertLessThan(paths.map{maximumY($0)}.max()!-object["height"]/2,0.8)
  }
  func testOptionalSavedNeedleProgramLocalClearanceDiagnostic()throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_EMBROIDERY_PROGRAM"] else {throw XCTSkip("Opt-in saved needle program diagnostic.")}
    var (project,object,face)=try fixture()
    let needle=try JSONDecoder.form.decode(EmbroideryProgram.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    object.textile!.embroidery=needle.design;project.objects=[object]
    let curves=try CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil})
    let paths=curves.flatMap{strands($0)},diameter=needle.design.process?.threadDiameter ?? 0.22
    var previous=Point2(),expected=[(Point2,Point2)]()
    for command in needle.commands {if command.action == .stitch,command.point != previous {expected.append((previous,command.point))};previous=command.point}
    XCTAssertEqual(paths.count,expected.count)
    // The optional corpus is a single-thread source; preserve every actual
    // stitch endpoint and ignore all travel/control commands exactly.
    XCTAssertEqual(curves.count,1)
    for (path,ends) in zip(paths,expected) {
      XCTAssertEqual(path.first!.x,ends.0.x,accuracy:1e-8);XCTAssertEqual(path.first!.z,ends.0.y,accuracy:1e-8)
      XCTAssertEqual(path.last!.x,ends.1.x,accuracy:1e-8);XCTAssertEqual(path.last!.z,ends.1.y,accuracy:1e-8)
    }
    let heights=paths.map{maximumY($0)-object["height"]/2},maximum=heights.max()!
    XCTAssertLessThan(maximum,diameter*6,"A simple top fill and sparse underlay should retain only local physical layers.")
    if let output=ProcessInfo.processInfo.environment["LAB_EMBROIDERY_DIAGNOSTIC_REPORT"] {
      let report:[String:Any]=["sourceDigest":needle.sourceDigest,"diameterMM":diameter,"curves":paths.count,"keys":curves.reduce(0){$0+$1.pointsMM.count},"maximumCenterHeightMM":maximum,"maximumTubeTopMM":maximum+diameter/2,"centersAbove1MM":heights.filter{$0>1}.count,"roughness":curves[0].material.roughness]
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
    }
  }
  func testEveryKeyUsesCurrentClothMaterialCoordinatesAndOutsidePanelFails()throws {
    var (project,object,face)=try fixture()
    var parent=try project.makeObject(recipeID:"clothPanel",parameters:["resolution":4])
    let mesh=try ClothMeshes.rectangle(widthMm:100,heightMm:100,columns:20,rows:4,areaDensityKgPerM2:0.2,originMm:.init())
    parent.cloth!.mesh=mesh;parent.cloth!.colliders=[];parent.position = .init(20,10,-30);parent.rotation=90
    let anchor=try mesh.anchor(at:.init(0.5,0.5),normalOffsetMm:0.3)
    object.clothAttachment = .init(surfaceObjectID:parent.id,anchor:anchor)
    project.objects=[parent,object]
    var current=try ClothSolver(mesh:mesh,settings:parent.cloth!.settings).frame
    for i in current.positionsMm.indices {
      let x=current.positionsMm[i].x;current.positionsMm[i].y=0.02*x*x
      let n=simd_normalize(SIMD3<Double>(-0.04*x,1,0));current.normals[i] = .init(n.x,n.y,n.z)
    }
    let needle=simpleProgram(object),before=project
    let curves=try CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in current})
    let step=(curves[0].pointsMM.count-1)/4
    XCTAssertEqual((curves[0].pointsMM.count-1)%4,0,"Refinement retains every original material-coordinate key.")
    for key in 0..<5 {
      let x = -4+Double(key)*2,shape:[Double]=[0,0.75,1,0.75,0]
      let height=0.1+0.26*shape[key]
      let binding=try mesh.anchor(at:.init(0.5+x/100,0.5),normalOffsetMm:0.3+object["height"]/2+height)
      let expected=project.worldClothPlacement(try binding.placement(mesh:mesh,frame:current),parent:parent,rotationDegrees:0)
      XCTAssertEqual(curves[0].pointsMM[key*step].x,expected.positionMm.x,accuracy:1e-8)
      XCTAssertEqual(curves[0].pointsMM[key*step].y,expected.positionMm.y,accuracy:1e-8)
      XCTAssertEqual(curves[0].pointsMM[key*step].z,expected.positionMm.z,accuracy:1e-8)
    }
    XCTAssertEqual(project,before)
    object.clothAttachment!.anchor=try mesh.anchor(at:.init(0.98,0.5));project.objects[1]=object
    XCTAssertThrowsError(try CyclesEmbroidery.curves(program:needle,object:object,project:project,faceNode:face,assets:assets,frame:{_ in current}))
  }
  func testGeneratorAndCurveStrandsUseExactlyTheSameActualStitches()throws {
    let (project,object,face)=try fixture(),needle=try EmbroideryDigitizer.generate(object:object,project:project)
    var previous=Point2(),count=0
    for command in needle.commands {if command.action == .stitch,command.point != previous {count+=1};previous=command.point}
    let curves=try CyclesEmbroidery.curves(object:object,project:project,faceNode:face,assets:assets,frame:{_ in nil})
    XCTAssertEqual(curves.reduce(0){$0+$1.firstKey.count},count)
    XCTAssertEqual(curves.reduce(0){$0+$1.pointsMM.count},count*5)
  }
  func testAssemblyStitchesResolveOriginalPanelMillimeters()throws {
    var (project,object,face)=try fixture()
    var source=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
    var piece=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100,color:"#FFFFFF")
    piece.sewingPiece = .init(name:"Panel");source.artwork = .init(background:"#FFFFFF",elements:[piece]);project.objects.append(source)
    try PatternAssemblySource.prepare(in:&project,objectID:source.id,elements:[piece.id])
    let panel=PatternPanelID(elementID:piece.id,copy:1)
    var definition=PatternAssemblyDefinition(sourceObjectID:source.id,panels:[.init(panel:panel,pose:.init(originMm:.init(5,20,10),uAxis:.init(1,0,0),vAxis:.init(0,0,1)),material:project.material("linen"),densityGSM:200)],seamIDs:[],maximumEdgeMm:20)
    definition.preparation=nil
    let id=try project.addPatternAssembly(definition),parent=try XCTUnwrap(project.objects.first{$0.id==id})
    let product=try XCTUnwrap(AssemblyProducts.product(for:parent,in:project)),current=try ClothSolver(mesh:product.study.mesh,settings:product.study.settings).frame
    object.patternAssemblyAttachment = .init(surfaceObjectID:id,anchor:.init(panel:panel,materialPointMm:.init(50,50),normalOffsetMm:0.2),rotationDegrees:0)
    project.objects[0]=object
    let curves=try CyclesEmbroidery.curves(program:simpleProgram(object),object:object,project:project,faceNode:face,assets:assets,frame:{_ in current})
    for (key,x) in [(0,46.0),(4,54.0)] {
      let binding=PatternAssemblyAnchor(panel:panel,materialPointMm:.init(x,50),normalOffsetMm:0.2+object["height"]/2+0.1)
      let expected=project.worldClothPlacement(try binding.placement(in:product,frame:current),parent:parent,rotationDegrees:0)
      XCTAssertEqual(curves[0].pointsMM[key].x,expected.positionMm.x,accuracy:1e-8)
      XCTAssertEqual(curves[0].pointsMM[key].y,expected.positionMm.y,accuracy:1e-8)
      XCTAssertEqual(curves[0].pointsMM[key].z,expected.positionMm.z,accuracy:1e-8)
    }
  }
  func testClothAndAssemblyNeedleEndpointsIntersectActualTableBackingAtVariedCalipers()throws {
    for assembly in [false,true] {for caliper in [0.4,1.0,2.8] {
      var (project,object,_)=try fixture()
      object.parameters["height"]=caliper;object.parameters["borderWidth"]=0
      let tilt=0.37,attachmentRotation=23.0
      let parentID:UUID,current:ClothFrame
      if assembly {
        var source=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
        var piece=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100,color:"#FFFFFF")
        piece.sewingPiece = .init(name:"Panel");source.artwork = .init(background:"#FFFFFF",elements:[piece])
        project.objects.append(source)
        try PatternAssemblySource.prepare(in:&project,objectID:source.id,elements:[piece.id])
        let panel=PatternPanelID(elementID:piece.id,copy:1)
        let pose=PatternPanelPose(originMm:.init(5,20,10),uAxis:.init(1,0,0),vAxis:.init(0,-sin(tilt),cos(tilt)))
        var definition=PatternAssemblyDefinition(sourceObjectID:source.id,panels:[.init(panel:panel,pose:pose,material:project.material("linen"),densityGSM:200)],seamIDs:[],maximumEdgeMm:20)
        definition.preparation=nil
        parentID=try project.addPatternAssembly(definition)
        let index=try XCTUnwrap(project.objects.firstIndex{$0.id==parentID})
        project.objects[index].position = .init(20,10,-30);project.objects[index].rotation=61
        let product=try XCTUnwrap(AssemblyProducts.product(for:project.objects[index],in:project))
        current=try ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation).frame
        object.patternAssemblyAttachment = .init(surfaceObjectID:parentID,anchor:.init(panel:panel,materialPointMm:.init(50,50),normalOffsetMm:0.3),rotationDegrees:attachmentRotation)
      } else {
        var parent=try project.makeObject(recipeID:"clothPanel",parameters:["resolution":4])
        var mesh=try ClothMeshes.rectangle(widthMm:100,heightMm:100,columns:4,rows:4,areaDensityKgPerM2:0.2,originMm:.init())
        for i in mesh.restPositionsMm.indices {
          let z=mesh.restPositionsMm[i].z
          mesh.restPositionsMm[i].y = 20-sin(tilt)*z;mesh.restPositionsMm[i].z = 10+cos(tilt)*z
        }
        parent.cloth!.mesh=mesh;parent.cloth!.colliders=[];parent.cloth!.preparation=nil
        parent.position = .init(20,10,-30);parent.rotation=61;parentID=parent.id
        current=try ClothSolver(mesh:mesh,settings:parent.cloth!.settings).frame
        object.clothAttachment = .init(surfaceObjectID:parentID,anchor:try mesh.anchor(at:.init(0.5,0.5),normalOffsetMm:0.3),rotationDegrees:attachmentRotation)
        project.objects.append(parent)
      }
      project.objects[0]=object
      let before=project,root=assets.appendingPathComponent("attached-thread-contact-"+UUID().uuidString)
      let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
      defer {store.cloth.clear();store.scene=nil;try? FileManager.default.removeItem(at:root)}
      store.engine.project=project
      let scene=TableSceneController(store:store);store.scene=scene
      scene.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Paper",assets:assets,textureLimit:64)
      let node=try XCTUnwrap(scene.objectRoot.childNode(withName:"object:\(object.id.uuidString)",recursively:false))
      let backing=try XCTUnwrap(node.childNode(withName:"Independent textile base",recursively:true))
      let face=try XCTUnwrap(node.childNode(withName:EmbroiderySceneSurface.faceName,recursively:true))
      let geometry=try XCTUnwrap(backing.geometry),vertices=geometry.sources(for:.vertex).flatMap(\.vectors).map(\.simd)
      let actualTop=try XCTUnwrap(vertices.map(\.z).max())
      XCTAssertEqual(actualTop*100,caliper/2,accuracy:1e-8)
      let origin=backing.convertPosition(.init(),to:nil).simd,normal=simd_normalize(backing.convertPosition(.init(0,0,1),to:nil).simd-origin)
      XCTAssertGreaterThan(abs(normal.y-1),0.01,"The actual Table placement must exercise a tilted source plane.")
      let curve=try XCTUnwrap(CyclesEmbroidery.curves(program:simpleProgram(object),object:object,project:project,faceNode:face,assets:assets,frame:{$0==parentID ? current:nil}).first)
      let diameter=object.textile!.embroidery!.process!.threadDiameter
      for (index,x) in [(0,-4.0),(4,4.0)] {
        let contact=backing.convertPosition(.init(x/100,0,actualTop),to:nil).simd*100
        let delta=curve.pointsMM[index]-contact,distance=simd_dot(delta,normal),radius=Double(curve.radiiMM[index])
        XCTAssertEqual(distance,diameter/4,accuracy:2e-5,"\(assembly ? "Assembly":"Cloth") attachment at caliper \(caliper) must use its actual backing top.")
        XCTAssertLessThan(simd_length(delta-normal*distance),2e-5,"World placement must preserve the authored needle point.")
        XCTAssertLessThan(distance-radius,0,"The endpoint tube must enter the actual Table backing.")
        XCTAssertGreaterThan(distance+radius,0)
      }
      XCTAssertEqual(geometry.sources(for:.vertex).flatMap(\.vectors).map(\.simd),vertices)
      XCTAssertTrue(project==before && store.project==before,"Preparing physical thread curves must not alter the source project or backing mesh.")
    }}
  }
}
