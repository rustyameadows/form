import Foundation
import XCTest
@testable import FormCore

final class AssemblyPerformanceTests:XCTestCase {
  func testFullCurvedPouchReportsBoundedSolverAndIdleCacheCost()throws {
    let (project,definition)=try PatternAssemblySamples.roundedPouch()
    var cache=PatternAssemblyCache();let begin=Date(),product=try cache.resolve(definition,in:project),meshMilliseconds=Date().timeIntervalSince(begin)*1000
    var solver=try ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation)
    try solver.start();let preparationBatches=try finishAssemblyPreparation(&solver)
    var steps:[Double]=[]
    for _ in 0..<30 {
      let t=Date();try solver.advance();let frame=solver.frame
      steps.append(Date().timeIntervalSince(t)*1000)
      XCTAssertLessThanOrEqual(frame.diagnostics.evaluations/max(1,frame.diagnostics.completedFrames),ClothSolver.maximumWorkPerAdvance)
      XCTAssertTrue(frame.positionsMm.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
    }
    let frameCount=solver.completedFrames,evaluations=solver.evaluations,builds=cache.builds,t=Date()
    for _ in 0..<100 {_ = try cache.resolve(definition,in:project)}
    let idleReadMilliseconds=Date().timeIntervalSince(t)*10
    XCTAssertEqual(cache.builds,builds);XCTAssertEqual(solver.completedFrames,frameCount);XCTAssertEqual(solver.evaluations,evaluations)
    let sorted=steps.sorted()
    #if DEBUG
    let configuration="debug"
    #else
    let configuration="release"
    #endif
    let report:[String:Any]=["configuration":configuration,"vertices":product.study.mesh.restPositionsMm.count,"triangles":product.study.mesh.triangles.count,"constraints":product.study.mesh.links.count,"meshing_operations":product.operations,"preparation_batch_ms":preparationBatches,"preparation":try jsonObject(solver.diagnostics.preparation),"meshing_milliseconds":meshMilliseconds,"step_and_frame_median_ms":sorted[sorted.count/2],"step_and_frame_p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],"step_and_frame_max_ms":sorted.last!,"cached_resolution_mean_ms":idleReadMilliseconds,"idle_solver_evaluations":0,"idle_mesh_builds":0,"per_frame_evaluations":evaluations/frameCount]
    if let root=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:root).appendingPathComponent("assembly-performance-\(configuration).json"))}
  }
}
