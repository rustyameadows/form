import Foundation
import XCTest
@testable import FormCore

final class ClothSolverTests:XCTestCase {
  private func run(_ solver:inout ClothSolver,seconds:Double)throws {
    try solver.start()
    for _ in 0..<Int((seconds/solver.settings.frameStepSeconds).rounded()) {try solver.advance()}
  }
  private func spring(step:Double = 1.0/60,iterations:Int = 4,mass:Double = 1,compliance:Double = 0.01)->ClothSolver {
    let mesh=ClothMesh(restPositionsMm:[.init(),.init(0,-1000,0)],massesKg:[1,mass],links:[.init(0,1,kind:.warp)],pins:[.init(0,targetMm:.init())])
    var settings=ClothSettings();settings.frameStepSeconds=step;settings.substeps=2;settings.iterations=iterations;settings.warpComplianceMPerN=compliance;settings.velocityDampingPerSecond=6;settings.maximumSimulationSeconds=10
    return try! .init(mesh:mesh,settings:settings)
  }
  func testPhysicalTriangleMassAndMaterialUVsArePreserved()throws {
    let mesh=try ClothMeshes.rectangle(widthMm:400,heightMm:300,columns:8,rows:6,areaDensityKgPerM2:0.2)
    XCTAssertEqual(mesh.restPositionsMm.count,63);XCTAssertEqual(mesh.triangles.count,96)
    XCTAssertEqual(mesh.massesKg.reduce(0,+),0.024,accuracy:1e-14)
    XCTAssertTrue(mesh.massesKg.allSatisfy {$0>0});XCTAssertEqual(mesh.uv.first,.init(0,0));XCTAssertEqual(mesh.uv.last,.init(1,1))
    XCTAssertTrue(ClothLinkKind.allCases.filter {$0 != .seam}.allSatisfy {kind in mesh.links.contains {$0.kind==kind}})
    var solver=try ClothSolver(mesh:mesh);try run(&solver,seconds:0.1)
    XCTAssertEqual(solver.mesh.uv,mesh.uv);XCTAssertEqual(solver.mesh.triangles,mesh.triangles)
  }
  func testFreeFallUsesSIGravityAndConvergesAsSubstepShrinks()throws {
    let mesh=ClothMesh(restPositionsMm:[.init(0,2000,0)],massesKg:[0.25])
    var coarse=ClothSettings();coarse.substeps=1;coarse.iterations=1;coarse.velocityDampingPerSecond=0
    var fine=coarse;fine.substeps=8
    var a=try ClothSolver(mesh:mesh,settings:coarse),b=try ClothSolver(mesh:mesh,settings:fine)
    try run(&a,seconds:0.5);try run(&b,seconds:0.5)
    let expected=2000-0.5*9.80665*0.5*0.5*1000
    XCTAssertEqual(a.frame.velocitiesMPerSecond[0].y,-9.80665*0.5,accuracy:1e-12)
    XCTAssertEqual(b.frame.velocitiesMPerSecond[0].y,-9.80665*0.5,accuracy:1e-11)
    let coarseError=abs(a.frame.positionsMm[0].y-expected),fineError=abs(b.frame.positionsMm[0].y-expected)
    XCTAssertGreaterThan(coarseError,20);XCTAssertLessThan(fineError,6);XCTAssertLessThan(fineError,coarseError/7.9)
    // Exact semi-implicit position for N fixed substeps, rather than a loose visual check.
    let h=fine.frameStepSeconds/Double(fine.substeps),count=240.0
    XCTAssertEqual(b.frame.positionsMm[0].y,2000-9.80665*h*h*count*(count+1)/2*1000,accuracy:1e-8)
  }
  func testXPBDLambdaAccumulationKeepsSingleConstraintIterationInvariant()throws {
    var mesh=ClothMesh(restPositionsMm:[.init(),.init(1000,0,0)],massesKg:[1,1],links:[.init(0,1,kind:.warp)],pins:[.init(0,targetMm:.init())])
    mesh.initialVelocitiesMPerSecond=[.init(),.init(30,0,0)]
    var one=ClothSettings();one.gravityMPerSecondSquared = .init();one.substeps=1;one.iterations=1;one.warpComplianceMPerN=0.001;one.velocityDampingPerSecond=0
    var many=one;many.iterations=16
    var a=try ClothSolver(mesh:mesh,settings:one),b=try ClothSolver(mesh:mesh,settings:many)
    try a.start();try b.start();try a.advance();try b.advance()
    let expected=1500-500/(1+0.001/pow(one.frameStepSeconds,2))
    XCTAssertEqual(a.frame.positionsMm[1].x,expected,accuracy:1e-9)
    XCTAssertEqual(b.frame.positionsMm[1].x,expected,accuracy:1e-9)
    XCTAssertEqual(a.frame.positionsMm[0],.init());XCTAssertEqual(b.frame.positionsMm[0],.init())
    for _ in 0..<30 {try a.advance();try b.advance()}
    XCTAssertEqual(a.frame.positionsMm[1].x,b.frame.positionsMm[1].x,accuracy:1e-8)
  }
  func testCompliantSpringSettlesToMassGravityExtensionAcrossTimeSteps()throws {
    var a=spring(step:1.0/60,iterations:1),b=spring(step:1.0/120,iterations:12),heavy=spring(step:1.0/60,iterations:4,mass:2)
    try run(&a,seconds:6);try run(&b,seconds:6);try run(&heavy,seconds:6)
    XCTAssertEqual(-a.frame.positionsMm[1].y,1000+9.80665*0.01*1000,accuracy:0.1)
    XCTAssertEqual(a.frame.positionsMm[1].y,b.frame.positionsMm[1].y,accuracy:0.1)
    XCTAssertEqual(-heavy.frame.positionsMm[1].y,1000+2*9.80665*0.01*1000,accuracy:0.3)
    XCTAssertEqual(a.diagnostics.maximumConstraintForceN,9.80665,accuracy:0.02)
  }
  func testPlaneContactAndCoulombVelocityFrictionScaleWithSubstep()throws {
    var mesh=ClothMesh(restPositionsMm:[.init(0,0.4,0)],massesKg:[1]);mesh.initialVelocitiesMPerSecond=[.init(1,0,0)]
    var settings=ClothSettings();settings.substeps=1;settings.iterations=3;settings.velocityDampingPerSecond=0;settings.friction=0.4
    var refined=settings;refined.substeps=8
    var a=try ClothSolver(mesh:mesh,settings:settings,colliders:[.plane()]),b=try ClothSolver(mesh:mesh,settings:refined,colliders:[.plane()])
    try run(&a,seconds:0.1);try run(&b,seconds:0.1)
    let speed=1-0.4*9.80665*0.1
    XCTAssertEqual(a.frame.velocitiesMPerSecond[0].x,speed,accuracy:1e-9);XCTAssertEqual(b.frame.velocitiesMPerSecond[0].x,speed,accuracy:1e-9)
    XCTAssertEqual(a.frame.positionsMm[0].y,0.4,accuracy:1e-9);XCTAssertEqual(b.frame.positionsMm[0].y,0.4,accuracy:1e-9)
    XCTAssertEqual(a.diagnostics.maximumVertexPenetrationMm,0,accuracy:1e-8)
  }
  func testSweptSphereContactStopsFastVertexOnNearSideAndResolvesCenterOverlap()throws {
    var mesh=ClothMesh(restPositionsMm:[.init(-1000,0,0)],massesKg:[1]);mesh.initialVelocitiesMPerSecond=[.init(100,0,0)]
    var settings=ClothSettings();settings.substeps=1;settings.iterations=6;settings.gravityMPerSecondSquared = .init();settings.velocityDampingPerSecond=0;settings.friction=0
    var fast=try ClothSolver(mesh:mesh,settings:settings,colliders:[.sphere(centerMm:.init(),radiusMm:50)])
    try fast.start();try fast.advance()
    XCTAssertEqual(fast.frame.positionsMm[0].x,-50.4,accuracy:1e-8);XCTAssertEqual(fast.frame.velocitiesMPerSecond[0].x,0,accuracy:1e-9)
    XCTAssertEqual(fast.diagnostics.maximumVertexPenetrationMm,0,accuracy:1e-8)
    var overlap=try ClothSolver(mesh:.init(restPositionsMm:[.init()],massesKg:[1]),settings:settings,colliders:[.sphere(centerMm:.init(),radiusMm:50)])
    try overlap.start();try overlap.advance();XCTAssertEqual(overlap.frame.positionsMm[0],.init(0,50.4,0));XCTAssertEqual(overlap.frame.velocitiesMPerSecond[0],.init())
  }
  func testTriangleInteriorContactUsesMassWeightedBarycentricCorrection()throws {
    // All three vertices start outside the sphere. Its center lies inside the
    // face footprint, so a vertex-only collision test would miss this contact.
    let points:[Vector3]=[.init(-100,0,-100),.init(100,0,-100),.init(0,0,100)]
    let mesh=ClothMesh(restPositionsMm:points,massesKg:[1,2,1],triangles:[.init(0,2,1)])
    var settings=ClothSettings();settings.substeps=1;settings.iterations=12;settings.gravityMPerSecondSquared = .init();settings.velocityDampingPerSecond=0
    let sphere=ClothCollider.sphere(centerMm:.init(0,-20,0),radiusMm:50)
    var solver=try ClothSolver(mesh:mesh,settings:settings,colliders:[sphere]);XCTAssertGreaterThan(solver.diagnostics.maximumSurfacePenetrationMm,30)
    try solver.start();try solver.advance();XCTAssertLessThan(solver.diagnostics.maximumSurfacePenetrationMm,0.001)
    XCTAssertTrue(solver.frame.positionsMm.contains {$0.y>20})
    // Every fully pinned vertex is individually clear, but the fixed face is not.
    var fixed=mesh;fixed.pins=points.enumerated().map {.init($0.offset,targetMm:$0.element)}
    XCTAssertThrowsError(try ClothSolver(mesh:fixed,settings:settings,colliders:[sphere]))
  }
  func testPinsStayExactAndRuntimeReleaseStopResetAreDeterministic()throws {
    var mesh=try ClothMeshes.rectangle(widthMm:240,heightMm:200,columns:6,rows:5,areaDensityKgPerM2:0.2)
    mesh.pins=[.init(0,targetMm:mesh.restPositionsMm[0]),.init(6,targetMm:mesh.restPositionsMm[6])]
    let settings=ClothSettings();var a=try ClothSolver(mesh:mesh,settings:settings),b=try ClothSolver(mesh:mesh,settings:settings)
    try run(&a,seconds:0.5);try run(&b,seconds:0.5);XCTAssertEqual(a.frame,b.frame)
    XCTAssertEqual(a.frame.positionsMm[0],mesh.pins[0].targetMm);XCTAssertEqual(a.frame.positionsMm[6],mesh.pins[1].targetMm)
    a.stop();let stopped=a.frame;try a.advance(frames:2);XCTAssertEqual(a.frame,stopped)
    try a.pin(10,toMm:.init(0,250,0));XCTAssertTrue(a.frame.pinnedVertices.contains(10));XCTAssertEqual(a.frame.positionsMm[10],.init(0,250,0))
    try a.unpin(10);XCTAssertFalse(a.frame.pinnedVertices.contains(10));a.reset()
    XCTAssertEqual(a.frame.positionsMm,mesh.restPositionsMm);XCTAssertEqual(a.frame.pinnedVertices,[0,6]);XCTAssertEqual(a.completedFrames,0);XCTAssertEqual(a.status,.stopped)
    try run(&a,seconds:0.5);XCTAssertEqual(a.frame,b.frame)
  }
  func testSeamsPullActualPanelEdgesTogetherWithoutMovingPinnedHandles()throws {
    let mesh=try ClothMeshes.seamedPanels(widthMm:220,heightMm:200,columns:8,rows:8,areaDensityKgPerM2:0.2)
    var settings=ClothSettings();settings.substeps=8;settings.iterations=8;settings.velocityDampingPerSecond=2
    var solver=try ClothSolver(mesh:mesh,settings:settings)
    let initialGap=solver.diagnostics.maximumSeamGapMm;XCTAssertEqual(initialGap,60,accuracy:1e-10)
    try run(&solver,seconds:1)
    XCTAssertLessThan(solver.diagnostics.maximumSeamGapMm,1.5)
    for pin in mesh.pins {XCTAssertEqual(solver.frame.positionsMm[pin.vertex],pin.targetMm)}
    XCTAssertGreaterThan(solver.frame.positionsMm.zipDistance(to:mesh.restPositionsMm),10)
  }
  func testDrapeComputesRealNonplanarShapeWithoutSphereOrFloorVertexPenetration()throws {
    var mesh=try ClothMeshes.rectangle(widthMm:320,heightMm:300,columns:16,rows:16,areaDensityKgPerM2:0.22,originMm:.init(0,125,0))
    // One explicit central support prevents an unrestrained sheet from sliding
    // completely off the sphere; the remaining 288 vertices are simulated.
    mesh.pins=[.init(8*17+8,targetMm:.init(0,70.4,0))]
    var settings=ClothSettings();settings.substeps=8;settings.iterations=6;settings.velocityDampingPerSecond=1.5
    let colliders:[ClothCollider]=[.sphere(centerMm:.init(),radiusMm:70),.plane(pointMm:.init(0,-90,0))]
    var solver=try ClothSolver(mesh:mesh,settings:settings,colliders:colliders)
    let began=Date();try run(&solver,seconds:1.5);let wallSeconds=Date().timeIntervalSince(began)
    let ys=solver.frame.positionsMm.map(\.y)
    XCTAssertGreaterThan(ys.max()!-ys.min()!,100);XCTAssertLessThan(ys.min()!,0)
    XCTAssertLessThanOrEqual(solver.diagnostics.maximumVertexPenetrationMm,1e-7)
    XCTAssertLessThanOrEqual(solver.diagnostics.maximumSurfacePenetrationMm,0.01)
    XCTAssertLessThan(solver.diagnostics.maximumStretchRatio,1.1)
    XCTAssertTrue(solver.frame.normals.allSatisfy {abs(sqrt($0.x*$0.x+$0.y*$0.y+$0.z*$0.z)-1)<1e-8})
    if let directory=ProcessInfo.processInfo.environment["FORM_CLOTH_PROOF_DIR"] {
      let root=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      struct Proof:Codable {var mesh:ClothMesh;var settings:ClothSettings;var colliders:[ClothCollider];var positionsMm:[Vector3];var diagnostics:ClothDiagnostics;var measuredWallSeconds:Double}
      try JSONEncoder.form.encode(Proof(mesh:mesh,settings:settings,colliders:colliders,positionsMm:solver.frame.positionsMm,diagnostics:solver.diagnostics,measuredWallSeconds:wallSeconds)).write(to:root.appendingPathComponent("sphere-drape.json"))
    }
  }
  func testInvalidSettingsContactsPinnedConflictsAndWorkRequestsRollback()throws {
    var settings=ClothSettings();settings.warpComplianceMPerN = .leastNonzeroMagnitude
    XCTAssertThrowsError(try settings.validate());settings=ClothSettings();settings.gravityMPerSecondSquared.x = .nan;XCTAssertThrowsError(try settings.validate())
    XCTAssertThrowsError(try ClothCollider.plane(normal:.init()).validate());XCTAssertThrowsError(try ClothCollider.sphere(centerMm:.init(),radiusMm:-1).validate())
    var mesh=ClothMesh(restPositionsMm:[.init()],massesKg:[1],pins:[.init(0,targetMm:.init())])
    XCTAssertThrowsError(try ClothSolver(mesh:mesh,colliders:[.sphere(centerMm:.init(),radiusMm:50)]))
    mesh=ClothMesh(restPositionsMm:[.init(),.init(100,0,0)],massesKg:[1,1],links:[.init(0,1,kind:.seam,restLengthMm:0)],pins:[.init(0,targetMm:.init()),.init(1,targetMm:.init(100,0,0))])
    XCTAssertThrowsError(try ClothSolver(mesh:mesh))
    var solver=try ClothSolver(mesh:ClothMeshes.rectangle(widthMm:400,heightMm:300,columns:20,rows:20,areaDensityKgPerM2:0.2))
    try solver.start();let before=solver.frame
    XCTAssertThrowsError(try solver.advance(frames:120));XCTAssertEqual(solver.frame,before)
    XCTAssertThrowsError(try solver.advance(frames:0));XCTAssertEqual(solver.frame,before)
    XCTAssertThrowsError(try solver.pin(9000,toMm:.init()));XCTAssertEqual(solver.frame,before)
  }
  func testNumericalDomainFailureKeepsLastValidStateAndRequiresReset()throws {
    // A valid but incompatible extreme rest length would demand >10,000 m/s
    // in one tiny substep. Publish no partial positions or elapsed frames.
    let mesh=ClothMesh(restPositionsMm:[.init(),.init(1,0,0)],massesKg:[1,1],links:[.init(0,1,kind:.warp,restLengthMm:200000)],pins:[.init(0,targetMm:.init())])
    var settings=ClothSettings();settings.warpComplianceMPerN=0;settings.frameStepSeconds=1.0/240;settings.substeps=16;settings.iterations=1
    var solver=try ClothSolver(mesh:mesh,settings:settings);try solver.start();let before=solver.frame
    XCTAssertThrowsError(try solver.advance())
    XCTAssertEqual(solver.status,.failed);XCTAssertEqual(solver.frame.positionsMm,before.positionsMm)
    XCTAssertEqual(solver.frame.velocitiesMPerSecond,before.velocitiesMPerSecond);XCTAssertEqual(solver.completedFrames,0)
    XCTAssertNotNil(solver.lastError);XCTAssertThrowsError(try solver.start())
    XCTAssertNoThrow(try JSONEncoder.form.encode(solver.diagnostics))
    solver.reset();XCTAssertNil(solver.lastError);XCTAssertEqual(solver.status,.stopped)
  }
  func testDeclaredTimeLimitStopsWithoutOvershootingOrIdleMutation()throws {
    var settings=ClothSettings();settings.maximumSimulationSeconds=0.05;settings.substeps=1;settings.velocityDampingPerSecond=0
    var solver=try ClothSolver(mesh:.init(restPositionsMm:[.init(0,1000,0)],massesKg:[1]),settings:settings)
    try solver.start();try solver.advance(frames:10)
    XCTAssertEqual(solver.completedFrames,3);XCTAssertEqual(solver.elapsedSeconds,0.05,accuracy:1e-12);XCTAssertEqual(solver.status,.timeLimit)
    let stopped=solver.frame;try solver.advance();XCTAssertEqual(solver.frame,stopped);XCTAssertThrowsError(try solver.start())
    solver.reset();try solver.start();try solver.advance();XCTAssertEqual(solver.completedFrames,1)
  }
}
private extension Array where Element==Vector3 {
  func zipDistance(to other:[Vector3])->Double {zip(self,other).map {a,b in sqrt(pow(a.x-b.x,2)+pow(a.y-b.y,2)+pow(a.z-b.z,2))}.max() ?? 0}
}
