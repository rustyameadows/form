import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class GarmentBlockGraphicsTests:XCTestCase {
  private func source()throws->(Project,GarmentBlock) {
    var project=Project(name:"Field / original declared skirt")
    let owner=try project.ensureCanvasWorkspace()
    _=try GarmentBlockCommands.apply(in:&project,objectID:owner.id,arguments:["operation":"create"])
    return (project,project.garmentBlocks![0])
  }
  func testActualTechnicalOutputRetainsFullRawSideSeamsAndShowsOnlyDeclaredStitchAndFoldLines() throws {
    let (project,block)=try source(),source=project.canvasWorkspace!.artwork!
    let row=block.sizes.first{$0.id==block.baseSizeID}!,ids=Set(block.bindings.filter{$0.sizeID==row.id}.map(\.elementID))
    let output=try SewingPatternOutput(source:source,selection:ids)
    XCTAssertEqual(output.plan.pieces.count,3);XCTAssertEqual(output.plan.seams.count,2)
    XCTAssertTrue(output.plan.seams.allSatisfy{$0.matches && abs($0.firstLength-718)<1e-8})
    XCTAssertFalse(output.plan.artwork.elements.contains{$0.name == "Stitch outline"})
    XCTAssertEqual(output.plan.artwork.elements.filter{$0.name?.hasPrefix("Stitch edge") == true}.count,4)
    let body=output.plan.pieces.filter{$0.piece.grainAngle == 90}
    XCTAssertEqual(body.count,2)
    for g in body {
      XCTAssertEqual(g.bounds.width,570,accuracy:1e-8);XCTAssertEqual(g.bounds.height,718,accuracy:1e-8)
      let guides=try SewingConstructionGuides.resolve(g)
      XCTAssertEqual(guides.map{$0.guide.offset},[8,38,688,703,68,673])
      XCTAssertEqual(guides.filter{$0.opening != nil}.count,g.piece.name.hasSuffix("back") ? 1:0)
      XCTAssertTrue(guides.filter{$0.opening != nil}.allSatisfy{$0.guide.opening==25})
    }
    let pdf=try output.pdf(assets:FileManager.default.temporaryDirectory)
    let doc=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:pdf as CFData)!))
    XCTAssertEqual(doc.numberOfPages,1)
    XCTAssertEqual(doc.page(at:1)!.getBoxRect(.mediaBox).width/TypographyEngine.pointsPerMM,output.plan.frameSize.x,accuracy:0.001)
    XCTAssertNil(String(decoding:pdf,as:UTF8.self).range(of:"/Subtype\\s*/Image",options:.regularExpression))
    let svg=try output.svg(assets:FileManager.default.temporaryDirectory)
    XCTAssertTrue(svg.contains("form-role-cut"));XCTAssertTrue(svg.contains("form-role-stitch"));XCTAssertTrue(svg.contains("form-role-guide"))
    let tiled=try SewingTileOutput(source:output,options:.init())
    XCTAssertLessThanOrEqual(tiled.plan.pageCount,200)
    if let path=ProcessInfo.processInfo.environment["FORM_GARMENT_BLOCK_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      try pdf.write(to:folder.appendingPathComponent("field-skirt-base.pdf"))
      try Data(svg.utf8).write(to:folder.appendingPathComponent("field-skirt-base.svg"))
      try JSONSerialization.data(withJSONObject:output.metadata,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("field-skirt-metadata.json"))
      try SewingPatternOutput(source:source).pdf(assets:FileManager.default.temporaryDirectory).write(to:folder.appendingPathComponent("field-skirt-three-sizes.pdf"))
    }
  }
  func testChartOnlyConfigurationLeavesTheAuthoritativePhysicalDrawingIdentical() throws {
    var (project,block)=try source()
    let before=try SewingPatternOutput(source:project.canvasWorkspace!.artwork!),objects=project.objects
    block.grade.hip=44
    _=try GarmentBlockCommands.apply(in:&project,objectID:project.canvasWorkspace!.id,arguments:["operation":"configure","block_id":block.id.uuidString,"block":try GarmentBlockCommands.definition(block)])
    let after=try SewingPatternOutput(source:project.canvasWorkspace!.artwork!)
    XCTAssertEqual(project.objects,objects);XCTAssertEqual(before.plan.artwork,after.plan.artwork)
    XCTAssertEqual(before.plan.frameSize,after.plan.frameSize)
    XCTAssertFalse(try GarmentBlockSources.updateNeededSizes(project.garmentBlocks![0],in:project).isEmpty)
  }
}
