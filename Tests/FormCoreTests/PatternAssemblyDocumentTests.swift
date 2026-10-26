import Foundation
import XCTest
@testable import FormCore

final class PatternAssemblyDocumentTests:XCTestCase {
  func testSourcePreparationAndNeutralArrangementAreExactlyOneUndo()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var p=Project(name:"Original source"),source=try p.makeObject(recipeID:"artboard");source.artwork=try SewingPatternTemplates.roundedPouch().artwork;p.objects=[source];engine.project=p
    var id:UUID?
    try engine.edit("Arrange original pieces") {project in
      let definition=try PatternAssemblyPlanning.arrangedPieces(in:&project,sourceID:source.id)
      XCTAssertTrue(definition.seamIDs.isEmpty)
      id=try project.addPatternAssembly(definition)
    }
    XCTAssertEqual(engine.undoStack.count,1);XCTAssertEqual(engine.project!.minimumSchemaVersion,36)
    let assembled=engine.project!,object=try XCTUnwrap(assembled.objects.first{$0.id==id})
    XCTAssertNil(object.cloth);XCTAssertEqual(object.patternAssembly?.panels.count,4)
    XCTAssertEqual(assembled.objects[0].artwork!.elements[1].kind,"path")
    try engine.flush();let loaded=try engine.repository.load(p.id)
    XCTAssertEqual(loaded.schemaVersion,36);XCTAssertEqual(loaded.objects,assembled.objects)
    let encoded=try JSONEncoder.form.encode(object),raw=try XCTUnwrap(String(data:encoded,encoding:.utf8))
    XCTAssertFalse(raw.contains("restPositionsMm"));XCTAssertFalse(raw.contains("massesKg"));XCTAssertFalse(raw.contains("completedFrames"))
    engine.undo();XCTAssertEqual(engine.project,p)
    engine.redo();XCTAssertEqual(engine.project,assembled)
    var locked=p;locked.objects[0].locked=true;let before=locked
    XCTAssertThrowsError(try PatternAssemblyPlanning.arrangedPieces(in:&locked,sourceID:source.id));XCTAssertEqual(locked,before)
  }
  func testCacheReusesGeometryForPaintAndIdleReadsAndNeverReturnsAnInvalidSource()throws {
    var (p,d)=try PatternAssemblySamples.roundedPouch();d.maximumEdgeMm=40
    var cache=PatternAssemblyCache();let first=try cache.resolve(d,in:p),builds=cache.builds
    for _ in 0..<10 {_ = try cache.resolve(d,in:p)}
    XCTAssertEqual(cache.builds,builds)
    let last=p.objects[0].artwork!.elements.count-1;p.objects[0].artwork!.elements[last].fontSize+=2
    let appearance=try cache.resolve(d,in:p)
    XCTAssertEqual(cache.builds,builds);XCTAssertEqual(appearance.study.mesh,first.study.mesh);XCTAssertNotEqual(appearance.sourceDigest,first.sourceDigest)
    p.objects[0].artwork!.elements[0].path!.contours[0].nodes[2].outgoing!.y+=3
    XCTAssertThrowsError(try cache.resolve(d,in:p));XCTAssertEqual(cache.builds,builds)
    p.objects[0].artwork!.elements[0].path!.contours[0].nodes[5].incoming!.y+=3
    let revised=try cache.resolve(d,in:p);XCTAssertEqual(cache.builds,builds+1);XCTAssertNotEqual(revised.study.mesh,first.study.mesh)
    for value in [42.0,44,46,48] {d.maximumEdgeMm=value;_ = try cache.resolve(d,in:p)}
    XCTAssertLessThanOrEqual(cache.retainedVertices,PatternAssemblyCache.maximumRetainedVertices)
    cache.clear();XCTAssertEqual(cache.retainedVertices,0)
  }
  func testChangedSourceUndoAndProjectIdentityRejectPendingOldWork()throws {
    var (p,d)=try PatternAssemblySamples.roundedPouch();d.maximumEdgeMm=40
    let a=try PatternAssemblyGenerator.generate(d,in:p),objectID=UUID()
    var session=ClothSession();let identity=ClothSourceIdentity(projectID:p.id,objectID:objectID,revision:a.sourceDigest)
    try session.bind(identity,study:a.study);try session.start();let pending=try session.prepare()
    p.objects[0].artwork!.elements[0].path!.contours[0].nodes[2].outgoing!.y+=3
    p.objects[0].artwork!.elements[0].path!.contours[0].nodes[5].incoming!.y+=3
    let b=try PatternAssemblyGenerator.generate(d,in:p)
    try session.bind(.init(projectID:p.id,objectID:objectID,revision:b.sourceDigest),study:b.study)
    XCTAssertFalse(session.accept(pending.compute()));XCTAssertEqual(session.frame?.diagnostics.completedFrames,0)
    try session.start();let changed=try session.prepare()
    try session.bind(identity,study:a.study);session.sourceHistoryChanged()
    XCTAssertFalse(session.accept(changed.compute()));XCTAssertEqual(session.mesh,a.study.mesh)
    try session.start();let oldProject=try session.prepare()
    try session.bind(.init(projectID:UUID(),objectID:objectID,revision:a.sourceDigest),study:a.study)
    XCTAssertFalse(session.accept(oldProject.compute()));session.clear();XCTAssertNil(session.frame)
  }
  func testEditorEulerPoseIsRigidAndRoundTripsAtGimbalAndBackFacingViews()throws {
    for r in [Vector3(),.init(90,0,0),.init(0,180,0),.init(22,37,-61),.init(38,90,12),.init(-19,-90,28)] {
      var a=PatternPanelPose(originMm:.init(4,5,6));a.setEulerDegrees(r);try a.validate()
      var b=a;b.setEulerDegrees(a.eulerDegrees)
      for p in [Point2(),.init(100,0),.init(0,100),.init(10,15)] {
        let x=a.point(p),y=b.point(p)
        XCTAssertEqual(x.x,y.x,accuracy:1e-7);XCTAssertEqual(x.y,y.y,accuracy:1e-7);XCTAssertEqual(x.z,y.z,accuracy:1e-7)
      }
    }
  }
}
