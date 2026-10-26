import Foundation
import XCTest
@testable import FormCore

@discardableResult func finishAssemblyPreparation(_ solver:inout ClothSolver)throws -> [Double] {
  let source=solver.frame.positionsMm;var timings:[Double]=[]
  while let preparation=solver.diagnostics.preparation,preparation.status != .ready {
    guard timings.count<1024 else{throw FormError.invalid("Preparation did not finish within its bounded batch count.")}
    let previous=preparation.evaluations,start=Date();try solver.advance();timings.append(Date().timeIntervalSince(start)*1000)
    XCTAssertEqual(solver.completedFrames,0);XCTAssertEqual(solver.elapsedSeconds,0);XCTAssertEqual(solver.evaluations,0)
    let report=try XCTUnwrap(solver.diagnostics.preparation)
    XCTAssertLessThanOrEqual(report.evaluations-previous,ClothSolver.maximumPreparationWorkPerAdvance)
    if report.status != .ready {XCTAssertEqual(solver.frame.positionsMm,source);XCTAssertNotNil(solver.frame.preparationCandidatePositionsMm)}
  }
  if let report=solver.diagnostics.preparation {
    XCTAssertLessThanOrEqual(report.maximumRelativeError,0.05);XCTAssertLessThanOrEqual(report.p95RelativeError,0.01)
    XCTAssertLessThanOrEqual(report.passes,report.maximumPasses);XCTAssertLessThanOrEqual(report.evaluations,report.maximumEvaluations)
  }
  return timings
}
final class AssemblyFullRunStrainTests:XCTestCase {
  func testEntireDeclaredPouchRunPreservesStructuralLengthsAndPhysicalSource()throws {try run(reverse:false,write:true)}
  func testOppositeConstraintOrderMeetsTheSamePreparationAndFullRunGate()throws {try run(reverse:true,write:false)}
  private func run(reverse:Bool,write:Bool)throws {
    let(project,definition)=try PatternAssemblySamples.roundedPouch(),before=project,product=try PatternAssemblyGenerator.generate(definition,in:project)
    var mesh=product.study.mesh;if reverse {mesh.links.reverse()}
    var solver=try ClothSolver(mesh:mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation)
    func strains(_ positions:[Vector3])->(maximum:Double,p95:Double,error:Double,minimum:Double) {
      var values:[Double]=[],error=0.0
      for link in mesh.links where [.warp,.weft,.shear].contains(link.kind) {
        let a=positions[link.a],b=positions[link.b],rest=link.restLengthMm!,length=sqrt(pow(a.x-b.x,2)+pow(a.y-b.y,2)+pow(a.z-b.z,2))
        values.append(length/rest);error=max(error,abs(length-rest))
      }
      values.sort();return(values.last!,values[Int(Double(values.count-1)*0.95)],error,values.first!)
    }
    let frames=solver.maximumFrames;XCTAssertEqual(frames,240)
    try solver.start();let preparationStarted=Date(),batches=try finishAssemblyPreparation(&solver),preparationMilliseconds=Date().timeIntervalSince(preparationStarted)*1000
    var worst=1.0,minimum=1.0,samples:[[String:Any]]=[]
    for frame in 1...frames {
      try solver.advance()
      let actual=strains(solver.frame.positionsMm);worst=max(worst,actual.maximum);minimum=min(minimum,actual.minimum)
      if frame==1 || frame%30==0 {samples.append(["frame":frame,"maximum_structural_ratio":actual.maximum,"minimum_structural_ratio":actual.minimum,"structural_p95_ratio":actual.p95,"maximum_structural_error_mm":actual.error,"seam_gap_mm":solver.diagnostics.maximumSeamGapMm])}
    }
    let final=strains(solver.frame.positionsMm)
    if write,let path=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {
      let report:[String:Any]=["frames":frames,"vertices":mesh.restPositionsMm.count,"triangles":mesh.triangles.count,"links":mesh.links.count,"worst_structural_ratio_all_physical_frames":worst,"lowest_structural_ratio_all_physical_frames":minimum,"final_maximum_structural_ratio":final.maximum,"final_minimum_structural_ratio":final.minimum,"final_structural_p95_ratio":final.p95,"final_maximum_structural_error_mm":final.error,"total_mass_kg":mesh.massesKg.reduce(0,+),"samples":samples,"initial_join":try jsonObject(solver.diagnostics.initialJoin),"preparation":try jsonObject(solver.diagnostics.preparation),"preparation_ms":preparationMilliseconds,"preparation_batch_ms":batches]
      try JSONSerialization.data(withJSONObject:["study":try jsonObject(product.study),"panels":try jsonObject(product.panels),"materialPointsMm":try jsonObject(product.materialPointsMm)],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path).appendingPathComponent("assembly-quality-product.json"))
      try JSONEncoder.form.encode(solver.frame.positionsMm).write(to:URL(fileURLWithPath:path).appendingPathComponent("assembly-quality-final-positions.json"))
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path).appendingPathComponent("assembly-full-run-strain.json"))
    }
    XCTAssertLessThanOrEqual(final.maximum,1.05);XCTAssertLessThanOrEqual(final.p95,1.01)
    XCTAssertLessThanOrEqual(worst,1.15);XCTAssertGreaterThanOrEqual(final.minimum,0.90)
    XCTAssertLessThan(solver.diagnostics.maximumSeamGapMm,1e-7)
    XCTAssertEqual(solver.mesh.uv,mesh.uv);XCTAssertEqual(solver.mesh.massesKg,mesh.massesKg);XCTAssertEqual(project,before)
  }
}
