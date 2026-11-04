import AppKit
import CryptoKit
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class CyclesAttachedSurfaceTests:XCTestCase {
  /// Optional external evidence retains the full authored needle program and
  /// the exact parent/patch files named by one atomic project manifest. The
  /// complete Table transfer is exercised separately by the project diagnostic.
  func testOptionalSavedAttachedProgramRetainsEveryStrandWithinOriginalWorkBudget()throws {
    let environment=ProcessInfo.processInfo.environment
    guard let path=environment["LAB_CYCLES_TEST_PROJECT"],let object=environment["LAB_CYCLES_TEST_ATTACHED_OBJECT"],
      let programPath=environment["LAB_CYCLES_TEST_ATTACHED_PROGRAM"] else {
      throw XCTSkip("Set LAB_CYCLES_TEST_PROJECT, LAB_CYCLES_TEST_ATTACHED_OBJECT and LAB_CYCLES_TEST_ATTACHED_PROGRAM for the full saved-program diagnostic.")
    }
    let package=URL(fileURLWithPath:path),objectID=try XCTUnwrap(UUID(uuidString:object)),began=Date()
    let manifestData=try Data(contentsOf:package.appendingPathComponent("Manifest.json"))
    let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:manifestData) as? [String:Any])
    var project=try JSONDecoder.form.decode(Project.self,from:JSONSerialization.data(withJSONObject:XCTUnwrap(manifest["project"])))
    let references=try XCTUnwrap(manifest["objects"] as? [[String:Any]])
    func load(_ id:UUID)throws->(ProductObject,String,Data) {
      let reference=try XCTUnwrap(references.first{$0["id"] as? String==id.uuidString})
      let filename=try XCTUnwrap(reference["file"] as? String)
      guard !filename.contains("/"),filename.hasSuffix(".json") else {throw FormError.invalid("Invalid object reference in diagnostic source.")}
      let data=try Data(contentsOf:package.appendingPathComponent("Objects").appendingPathComponent(filename))
      return(try JSONDecoder.form.decode(ProductObject.self,from:data),filename,data)
    }
    let (patch,patchFile,patchData)=try load(objectID),parentID=try XCTUnwrap(patch.clothAttachment?.surfaceObjectID)
    let (parent,parentFile,parentData)=try load(parentID);project.objects=[parent,patch]
    let programData=try Data(contentsOf:URL(fileURLWithPath:programPath)),program=try JSONDecoder.form.decode(EmbroideryProgram.self,from:programData)
    let generated=try EmbroideryDigitizer.generate(object:patch,project:project)
    XCTAssertTrue(generated.commands==program.commands,"The retained program must be the current complete authored program, not an older or reduced diagnostic.")
    XCTAssertTrue(generated.design==program.design)
    let before=project,mapping=try XCTUnwrap(CyclesAttachedSurface(object:patch,project:project,frame:{_ in nil}))
    let curves=try CyclesEmbroidery.curves(program:program,object:patch,project:project,faceNode:MeshNode(),assets:package.appendingPathComponent("Assets"),frame:{_ in nil},attachedSurface:mapping,deferAttachedMapping:true)
    let surface=try mapping.makeSurface();var budget=surface.makeBudget(),completed=0,outputKeys=0,digest=SHA256()
    for curve in curves {for strand in curve.firstKey.indices {
      let start=Int(curve.firstKey[strand]),end=strand+1<curve.firstKey.count ? Int(curve.firstKey[strand+1]):curve.pointsMM.count
      let source=Array(curve.pointsMM[start..<end]),mapped=try surface.deformCurve(source,budget:&budget)
      let subdivisions=(mapped.count-1)/(source.count-1)
      XCTAssertGreaterThanOrEqual(subdivisions,1)
      for key in source.indices {XCTAssertLessThan(simd_distance(mapped[key*subdivisions],try surface.position(source[key])),1e-10)}
      for point in mapped {for coordinate in [point.x,point.y,point.z] {
        var bits=coordinate.bitPattern.littleEndian;withUnsafeBytes(of:&bits){digest.update(bufferPointer:$0)}
      }}
      completed+=1;outputKeys+=mapped.count
    }}
    let sourceStrands=curves.reduce(0){$0+$1.firstKey.count},sourceKeys=curves.reduce(0){$0+$1.pointsMM.count}
    XCTAssertEqual(completed,sourceStrands);XCTAssertGreaterThanOrEqual(outputKeys,sourceKeys)
    XCTAssertEqual(surface.limits.maximumWork,16_000_000);XCTAssertLessThanOrEqual(budget.work,surface.limits.maximumWork)
    XCTAssertTrue(project==before,"Derived preparation must preserve the authored project.")
    func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    let report:[String:Any]=["manifestSHA256":sha(manifestData),"parentFile":parentFile,"parentSHA256":sha(parentData),"patchFile":patchFile,"patchSHA256":sha(patchData),
      "programPath":programPath,"programFileSHA256":sha(programData),"programDigest":program.sourceDigest,"commands":program.commands.count,
      "sourceStrands":sourceStrands,"sourceKeys":sourceKeys,"completedStrands":completed,"outputKeys":outputKeys,"work":budget.work,"maximumWork":surface.limits.maximumWork,
      "geometrySHA256":digest.finalize().map{String(format:"%02x",$0)}.joined(),"elapsedSeconds":Date().timeIntervalSince(began)]
    if let destination=environment["LAB_CYCLES_ATTACHED_PROGRAM_REPORT"] {
      let url=URL(fileURLWithPath:destination);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    print("Saved attached program: \(completed) strands, \(sourceKeys) original / \(outputKeys) rendered keys, \(budget.work) / \(surface.limits.maximumWork) work.")
  }
  private func fixture()throws->(Project,ProductObject,ProductObject,ClothFrame) {
    _=NSApplication.shared
    var project=Project(name:"Attached rendering contract"),parent=try project.makeObject(recipeID:"clothPanel",parameters:["resolution":4])
    var mesh=try ClothMeshes.rectangle(widthMm:80,heightMm:60,columns:32,rows:8,areaDensityKgPerM2:0.2,originMm:.init())
    for i in mesh.restPositionsMm.indices {let x=mesh.restPositionsMm[i].x;mesh.restPositionsMm[i].y=0.025*x*x}
    parent.cloth!.mesh=mesh;parent.cloth!.colliders=[];parent.cloth!.preparation=nil
    parent.position = .init(15,12,-9);parent.rotation=41
    let current=try ClothSolver(mesh:mesh,settings:parent.cloth!.settings).frame
    var object=try project.makeObject(recipeID:"textilePatch",parameters:["width":20,"depth":16,"height":0.5,"corner":0,"borderWidth":0])
    let line=ArtworkElement(kind:"line",x:4,y:8,width:12,height:0.1,color:"#AA4455")
    object.artwork = .init(background:"#FFFFFF",elements:[line])
    var design=EmbroideryDesign(threads:[.init(name:"Thread",color:"#AA4455")],regions:[.init(elementIDs:[line.id],method:.running)])
    design.process=EmbroideryProcess();design.process!.threadDiameter=0.22;design.process!.tieIn=false;design.process!.tieOff=false
    object.textile!.embroidery=design
    object.clothAttachment = .init(surfaceObjectID:parent.id,anchor:try mesh.anchor(at:.init(0.5,0.5),normalOffsetMm:0.45),rotationDegrees:17)
    project.objects=[parent,object];return(project,parent,object,current)
  }
  private func hitDistance(_ origin:SIMD3<Double>,normal:SIMD3<Double>,mesh:SceneMeshPayload)throws->Double {
    let direction = -normal;var closest=Double.infinity
    for part in mesh.parts {let ids=part.triangleIndices
      for i in stride(from:0,to:ids.count,by:3) {
        let a=mesh.positionsMM[Int(ids[i])],b=mesh.positionsMM[Int(ids[i+1])],c=mesh.positionsMM[Int(ids[i+2])],ab=b-a,ac=c-a,p=simd_cross(direction,ac),det=simd_dot(ab,p)
        if abs(det)<1e-12 {continue}
        let delta=origin-a,u=simd_dot(delta,p)/det,q=simd_cross(delta,ab),v=simd_dot(direction,q)/det,t=simd_dot(ac,q)/det
        if u>=(-1e-8),v>=(-1e-8),u+v<=1+1e-8,t>=0 {closest=min(closest,t)}
      }
    }
    return try XCTUnwrap(closest.isFinite ? closest:nil)
  }
  func testTableSnapshotMapsActualBackingAndNeedleContactTogetherWithoutChangingFastGeometry()async throws {
    let (project,parent,object,current)=try fixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent("mapped-table-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    defer {store.cloth.clear();store.scene=nil;try? FileManager.default.removeItem(at:root)}
    store.engine.project=project
    let scene=TableSceneController(store:store);store.scene=scene
    scene.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Paper",assets:root,textureLimit:64)
    let node=try XCTUnwrap(scene.objectRoot.childNode(withName:"object:\(object.id.uuidString)",recursively:false)),backing=try XCTUnwrap(node.childNode(withName:"Independent textile base",recursively:true))
    let geometry=try XCTUnwrap(backing.geometry),original=geometry.sources(for:.vertex).flatMap(\.vectors).map(\.simd),transform=backing.worldTransform.raw
    let fastTop=backing.convertPosition(.init(0,0,original.map(\.z).max()!),to:nil).simd*100
    let fastNormal=simd_normalize(backing.convertPosition(.init(0,0,1),to:nil).simd-backing.convertPosition(.init(),to:nil).simd)
    let snapshot=try await scene.cyclesSnapshot(settings:.init())
    let payload=try XCTUnwrap(snapshot.renderables.first{$0.objectID==object.id && scene.adapter.nodes[$0.componentID] === backing})
    XCTAssertEqual(payload.transform,.init());XCTAssertTrue(payload.mesh.id.hasSuffix(":material-surface"))
    XCTAssertGreaterThan(payload.mesh.positionsMM.map{abs(simd_dot($0-fastTop,fastNormal))}.max()!,1,"The derived backing must follow the curved parent instead of retaining the rigid tangent plane.")
    let mapper=try XCTUnwrap(CyclesAttachedSurface(object:object,project:project,frame:{$0==parent.id ? current:nil})),surface=try mapper.makeSurface()
    let face=try XCTUnwrap(node.childNode(withName:EmbroiderySceneSurface.faceName,recursively:true))
    let local=try CyclesEmbroidery.curves(object:object,project:project,faceNode:face,assets:root,frame:{_ in current},attachedSurface:mapper,deferAttachedMapping:true)
    let result=try XCTUnwrap(snapshot.curves.first{$0.objectID==object.id})
    XCTAssertEqual(result.firstKey.count,local[0].firstKey.count)
    for strand in result.firstKey.indices {
      let first=Int(result.firstKey[strand]),last=strand+1<result.firstKey.count ? Int(result.firstKey[strand+1])-1:result.pointsMM.count-1
      let localFirst=Int(local[0].firstKey[strand]),localLast=strand+1<local[0].firstKey.count ? Int(local[0].firstKey[strand+1])-1:local[0].pointsMM.count-1
      for (index,sourceIndex) in [(first,localFirst),(last,localLast)] {
        let q=local[0].pointsMM[sourceIndex],mapped=try surface.position(q),normal=simd_normalize(try surface.position(q+SIMD3(0,1,0))-mapped)
        XCTAssertLessThan(simd_distance(result.pointsMM[index],mapped),1e-7)
        let distance=try hitDistance(result.pointsMM[index],normal:normal,mesh:payload.mesh)
        XCTAssertEqual(distance,0.055,accuracy:surface.limits.toleranceMM*2)
        XCTAssertLessThan(distance-Double(result.radiiMM[index]),0,"Every actual needle endpoint must enter the mapped backing.")
      }
    }
    XCTAssertEqual(geometry.sources(for:.vertex).flatMap(\.vectors).map(\.simd),original)
    XCTAssertTrue(backing.worldTransform.raw==transform);XCTAssertTrue(store.project==project)
  }
  func testFrozenParentMappingRetainsItsCapturedFrameAndDetachedCancellationPublishesNothing()async throws {
    let (project,parent,object,initial)=try fixture();var current=initial
    let frozen=try XCTUnwrap(CyclesAttachedSurface(object:object,project:project,frame:{_ in current}))
    let before=try frozen.makeSurface().position(.init(3,0.25,2))
    for i in current.positionsMm.indices {current.positionsMm[i].y+=7}
    let changed=try XCTUnwrap(CyclesAttachedSurface(object:object,project:project,frame:{$0==parent.id ? current:nil}))
    let original=try frozen.makeSurface().position(.init(3,0.25,2)),after=try changed.makeSurface().position(.init(3,0.25,2))
    XCTAssertEqual(original,before);XCTAssertEqual(after.y-before.y,7,accuracy:1e-8);XCTAssertNotEqual(frozen.revision,changed.revision)
    let task=Task {try await CyclesAttachedSurface.prepare([.init(mapping:frozen,indices:[],renderables:[],curves:[])])};task.cancel()
    do {_=try await task.value;XCTFail("A cancelled detached mapping must not publish a prepared snapshot.")}catch {XCTAssertTrue(error is CancellationError)}
  }
}
