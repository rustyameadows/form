import XCTest
@testable import FormCore

final class ClothIdealSeamTests:XCTestCase {
  private func freeSettings()->ClothSettings {var s=ClothSettings();s.gravityMPerSecondSquared = .init();s.velocityDampingPerSecond=0;s.substeps=1;s.iterations=1;return s}
  func testIdealSeamConservesAreaMassAndMomentumWithoutChangingSourceOrReset()throws {
    var mesh=ClothMesh(restPositionsMm:[.init(0,0,0),.init(40,0,0)],massesKg:[1,3],uv:[.init(0,0),.init(1,1)],links:[.init(0,1,kind:.seam,restLengthMm:0)])
    mesh.initialVelocitiesMPerSecond=[.init(1,0,0),.init(-1,0,0)]
    var solver=try ClothSolver(mesh:mesh,settings:freeSettings());let reset=solver.frame
    XCTAssertEqual(reset.positionsMm,mesh.restPositionsMm)
    try solver.start();try solver.advance()
    let frame=solver.frame,expectedX=30-0.5*1000/60
    XCTAssertEqual(frame.positionsMm[0],frame.positionsMm[1]);XCTAssertEqual(frame.positionsMm[0].x,expectedX,accuracy:1e-9)
    XCTAssertEqual(frame.velocitiesMPerSecond[0].x,-0.5,accuracy:1e-10);XCTAssertEqual(frame.velocitiesMPerSecond[1].x,-0.5,accuracy:1e-10)
    XCTAssertEqual(frame.diagnostics.totalMassKg,4);XCTAssertEqual(frame.diagnostics.maximumSeamGapMm,0)
    let join=try XCTUnwrap(frame.diagnostics.initialJoin)
    XCTAssertEqual(join.idealGroupCount,1);XCTAssertFalse(join.idealSeamReactionsEstimated)
    XCTAssertEqual(join.centerOfMassBeforeMm.x,30,accuracy:1e-12);XCTAssertEqual(join.centerOfMassAfterMm.x,30,accuracy:1e-12)
    XCTAssertEqual(join.linearMomentumBeforeKgMPerSecond.x,-2,accuracy:1e-12);XCTAssertEqual(join.linearMomentumAfterKgMPerSecond.x,-2,accuracy:1e-12)
    XCTAssertEqual(solver.mesh,mesh);solver.reset();XCTAssertEqual(solver.frame,reset)
  }
  func testTransitiveRedundantSeamsDoNotChangeTheSinglePhysicalMotion()throws {
    let rest:[Vector3]=[.init(0,20,0),.init(30,20,0),.init(60,20,0)],links:[ClothLink]=[.init(0,1,kind:.seam,restLengthMm:0),.init(1,2,kind:.seam,restLengthMm:0)]
    var mesh=ClothMesh(restPositionsMm:rest,massesKg:[1,2,3],links:links),a=try ClothSolver(mesh:mesh,settings:freeSettings())
    mesh.links += [.init(2,0,kind:.seam,restLengthMm:0)]
    var b=try ClothSolver(mesh:mesh,settings:freeSettings())
    try a.start();try b.start();try a.advance();try b.advance()
    XCTAssertEqual(a.frame.positionsMm,b.frame.positionsMm);XCTAssertTrue(a.frame.positionsMm.allSatisfy{$0==a.frame.positionsMm[0]})
    XCTAssertEqual(a.frame.positionsMm[0].x,40,accuracy:1e-10)
    try a.pin(2,toMm:.init(10,30,0));XCTAssertTrue(a.frame.positionsMm.allSatisfy{$0 == .init(10,30,0)})
    let pinned=a.frame;XCTAssertThrowsError(try a.pin(0,toMm:.init(11,30,0)));XCTAssertEqual(a.frame,pinned)
    try a.unpin(2);try a.advance();XCTAssertTrue(a.frame.positionsMm.allSatisfy{$0==a.frame.positionsMm[0]})
  }
  func testIdealSewnGroupContactsRemainExactAndFinite()throws {
    let mesh=ClothMesh(restPositionsMm:[.init(0,0,0),.init(0,0,0)],massesKg:[0.001,0.002],links:[.init(0,1,kind:.seam,restLengthMm:0)])
    var solver=try ClothSolver(mesh:mesh,settings:freeSettings(),colliders:[.sphere(centerMm:.init(),radiusMm:20)])
    try solver.start();try solver.advance()
    XCTAssertEqual(solver.frame.positionsMm[0],solver.frame.positionsMm[1]);XCTAssertLessThanOrEqual(solver.diagnostics.maximumVertexPenetrationMm,1e-8)
    XCTAssertTrue(solver.diagnostics.maximumConstraintForceN.isFinite);XCTAssertEqual(solver.diagnostics.maximumSeamGapMm,0)
  }
  func testConflictingTransitivePinsAndCollapsedMaterialFacesAreRejected()throws {
    var mesh=ClothMesh(restPositionsMm:[.init(0,20,0),.init(30,20,0),.init(0,50,0)],massesKg:[1,2,3],links:[.init(0,1,kind:.seam,restLengthMm:0),.init(1,2,kind:.seam,restLengthMm:0)],pins:[.init(0,targetMm:.init(0,20,0)),.init(2,targetMm:.init(1,20,0))])
    XCTAssertThrowsError(try ClothSolver(mesh:mesh,settings:freeSettings()))
    mesh.pins=[];mesh.triangles=[.init(0,1,2)];XCTAssertThrowsError(try ClothSolver(mesh:mesh,settings:freeSettings()))
  }
  func testCompliantAndNonzeroGapSeamsRetainTheirDeclaredIndependentDOFs()throws {
    let mesh=ClothMesh(restPositionsMm:[.init(0,20,0),.init(40,20,0)],massesKg:[1,3],links:[.init(0,1,kind:.seam,restLengthMm:0)])
    var settings=freeSettings();settings.seamComplianceMPerN=0.1
    var compliant=try ClothSolver(mesh:mesh,settings:settings);try compliant.start();try compliant.advance()
    XCTAssertGreaterThan(compliant.diagnostics.maximumSeamGapMm,1)
    var spaced=mesh;spaced.links[0].restLengthMm=20
    var idealDistance=try ClothSolver(mesh:spaced,settings:freeSettings());try idealDistance.start();try idealDistance.advance()
    XCTAssertEqual(idealDistance.frame.positionsMm[1].x-idealDistance.frame.positionsMm[0].x,20,accuracy:1e-9)
  }
}
