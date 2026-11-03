import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationArrangedOutputTests:XCTestCase {
  private func fixture(_ count:Int)throws->(Project,UUID) {
    var project=Project(name:"Ordered physical output"),ids=[UUID]()
    for n in 1...count {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
      page.name="Page \(n)";page.artwork = Artwork(elements:[.init(kind:"text",x:10,y:15,width:80,height:20,text:"PAGE \(n)",fontSize:18)],bleed:3)
      project.objects.append(page);ids.append(page.id)
    }
    let id=try PublicationCommands.createPublication(in:&project,name:"Physical sequence",pages:ids)
    return(project,id)
  }
  func testTwelvePageFoldedOrderHasEachSourceExactlyOnceWithoutMutation()throws {
    let (project,id)=try fixture(12),before=project
    let plan=try PublicationOutput.arrangement(project,documentID:id,layout:.booklet)
    XCTAssertEqual(plan.sides.map{$0.placements.map(\.sourcePage)},[[12,1],[2,11],[10,3],[4,9],[8,5],[6,7]])
    XCTAssertEqual(plan.sides.map(\.sheet),[1,1,2,2,3,3]);XCTAssertEqual(plan.addedBlankPages,0)
    XCTAssertEqual(Set(plan.sides.flatMap{$0.placements.compactMap(\.sourcePage)}),Set(1...12))
    XCTAssertEqual(project,before)
  }
  func testExplicitPaddingAndMixedSizeRejectionDoNotChangeLogicalPages()throws {
    var (project,id)=try fixture(5)
    XCTAssertThrowsError(try PublicationOutput.arrangement(project,documentID:id,layout:.booklet))
    let padded=try PublicationOutput.arrangement(project,documentID:id,layout:.booklet,padToMultipleOfFour:true)
    XCTAssertEqual(padded.addedBlankPages,3);XCTAssertEqual(padded.sides.count,4)
    XCTAssertEqual(padded.sides.flatMap{$0.placements}.filter{$0.sourcePage==nil}.count,3)
    project.objects[0].parameters["width"]=90
    XCTAssertThrowsError(try PublicationOutput.arrangement(project,documentID:id,layout:.booklet,padToMultipleOfFour:true))
    XCTAssertNoThrow(try PublicationOutput.arrangement(project,documentID:id,layout:.spreads))
  }
  func testReaderSpreadsAndImposedPDFKeepActualPhysicalBoxesAndSource()throws {
    let (project,id)=try fixture(12),before=project,assets=FileManager.default.temporaryDirectory
    let spreads=try PublicationOutput.arrangement(project,documentID:id,layout:.spreads)
    XCTAssertEqual(spreads.sides.count,7)
    XCTAssertEqual(spreads.sides.map(\.widthMM),[100,200,200,200,200,200,100])
    for layout in [PublicationPDFLayout.spreads,.booklet] {
      let data=try PublicationOutput.arrangedPDF(project,documentID:id,assets:assets,outlineText:true,layout:layout)
      let pdf=try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data:data as CFData))))
      XCTAssertEqual(pdf.numberOfPages,layout == .booklet ? 6:7)
      let first=try XCTUnwrap(pdf.page(at:1)),trim=first.getBoxRect(.trimBox)
      XCTAssertEqual(trim.width/TypographyEngine.pointsPerMM,layout == .booklet ? 200:100,accuracy:0.001)
      XCTAssertEqual(trim.height/TypographyEngine.pointsPerMM,140,accuracy:0.001)
      XCTAssertEqual(first.getBoxRect(.mediaBox).width,trim.width+6*TypographyEngine.pointsPerMM,accuracy:0.001)
    }
    XCTAssertEqual(project,before)
  }
  func testFirstVersoRequiresExplicitLeadingBlankAndPreflightMatchesExport()throws {
    var (project,id)=try fixture(12)
    project.publications![0].layout = .init(firstPageSide:.verso)
    let before=project
    XCTAssertEqual(PublicationOutput.arrangedPreflight(project,documentID:id,layout:.booklet)["can_export"] as? Bool,false)
    XCTAssertThrowsError(try PublicationOutput.arrangedPDF(project,documentID:id,assets:FileManager.default.temporaryDirectory,layout:.booklet))
    let plan=try PublicationOutput.arrangement(project,documentID:id,layout:.booklet,padToMultipleOfFour:true)
    XCTAssertEqual(plan.addedBlankPages,4);XCTAssertEqual(plan.sides.count,8)
    XCTAssertNil(plan.sides[0].placements[1].sourcePage)
    XCTAssertEqual(plan.sides[1].placements[0].sourcePage,1)
    XCTAssertEqual(Set(plan.sides.flatMap{$0.placements.compactMap(\.sourcePage)}),Set(1...12))
    XCTAssertEqual(PublicationOutput.arrangedPreflight(project,documentID:id,layout:.booklet,padToMultipleOfFour:true)["can_export"] as? Bool,true)
    XCTAssertEqual(project,before)
    let (short,shortID)=try fixture(5)
    XCTAssertEqual(PublicationOutput.arrangedPreflight(short,documentID:shortID,layout:.booklet)["can_export"] as? Bool,false)
    XCTAssertEqual(PublicationOutput.arrangedPreflight(short,documentID:shortID,layout:.booklet,padToMultipleOfFour:true)["can_export"] as? Bool,true)
  }
  func testMixedBleedsUseTheRealCommonAllowanceAndReportTheCrop()throws {
    var(project,id)=try fixture(4)
    for index in project.objects.indices {project.objects[index].artwork!.bleed=6;project.objects[index].artwork!.background="#183F3C"}
    project.objects[1].artwork!.bleed=1
    let before=project,plan=try PublicationOutput.arrangement(project,documentID:id,layout:.spreads)
    XCTAssertEqual(plan.sides[1].bleedMM,1)
    let report=PublicationOutput.arrangedPreflight(project,documentID:id,layout:.spreads)
    XCTAssertEqual(report["can_export"] as? Bool,true)
    XCTAssertTrue((report["issues"] as? [[String:Any]] ?? []).contains{$0["code"] as? String=="shared_bleed"})
    let data=try PublicationOutput.arrangedPDF(project,documentID:id,assets:FileManager.default.temporaryDirectory,layout:.spreads)
    let pdf=try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data:data as CFData))))
    let page=try XCTUnwrap(pdf.page(at:2))
    XCTAssertEqual(page.getBoxRect(.bleedBox).width/TypographyEngine.pointsPerMM,202,accuracy:0.001)
    XCTAssertEqual(page.getBoxRect(.trimBox).width/TypographyEngine.pointsPerMM,200,accuracy:0.001)
    XCTAssertEqual(project,before)
  }
  func testDeclaredInkArrangementPreflightRequiresTheSameExplicitPreviewAsExport()throws {
    var(project,id)=try fixture(4)
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent("publication-ink-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:assets)}
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    let swatch=try SwatchCommands.save(in:&project,name:"Declared orange",color:"#D45A37",printInk:.init(kind:.spot,components:.init(0,0.7,1,0),profile:profile.reference,spotName:"Declared orange"))
    for index in project.objects.indices {project.objects[index].artwork!.outputColorProfile=profile.reference;project.objects[index].artwork!.elements[0].fillSwatchID=swatch}
    let before=project
    for layout in [PublicationPDFLayout.spreads,.booklet] {
      XCTAssertEqual(PublicationOutput.arrangedPreflight(project,documentID:id,assets:assets,layout:layout)["can_export"] as? Bool,false)
      XCTAssertThrowsError(try PublicationOutput.arrangedPDF(project,documentID:id,assets:assets,layout:layout))
      XCTAssertEqual(PublicationOutput.arrangedPreflight(project,documentID:id,assets:assets,layout:layout,inkOutput:.preview)["can_export"] as? Bool,true)
      XCTAssertNoThrow(try PublicationOutput.arrangedPDF(project,documentID:id,assets:assets,inkOutput:.preview,layout:layout))
    }
    XCTAssertEqual(project,before)
  }
  func testAllPDFModesRejectAStoryThatContinuesOutsideThePublication()throws {
    var(project,id)=try fixture(4)
    project.publications![0].pages=Array(project.publications![0].pages.prefix(2))
    let frames:[StoryFrameID]=[0,3].map{.init(objectID:project.objects[$0].id,elementID:project.objects[$0].artwork!.elements[0].id)}
    _ = try PublicationCommands.createStory(in:&project,frames:frames,name:"Complete source")
    let before=project
    for mode in [InkOutputMode.preview,.composite,.plates] {
      XCTAssertThrowsError(try PublicationOutput.pdf(project,documentID:id,assets:FileManager.default.temporaryDirectory,inkOutput:mode)){error in
        XCTAssertTrue(error.localizedDescription.contains("outside this publication"),error.localizedDescription)
      }
    }
    XCTAssertEqual(project,before)
  }
  func testReadonlyMasterAndLockedPageTextOutlineForOutputWithoutEditingSources()throws {
    var(project,id)=try fixture(4)
    project.objects[0].artwork!.elements[0].locked=true
    var master=try project.makeObject(recipeID:"artboard",name:"Shared running furniture",parameters:["width":100,"depth":140])
    master.artwork = .init(elements:[.init(kind:"text",x:7,y:125,width:80,height:8,text:"PAGE {{page.number}}",fontSize:9)])
    project.objects.append(master);project.publications![0].masters=[.init(sourceObjectID:master.id)]
    let before=project,art=try XCTUnwrap(project.surfaceArtwork(project.objects[0]))
    let generated=try XCTUnwrap(art.elements.first{$0.kind=="text" && $0.parentID != nil})
    XCTAssertTrue(art.isLocked(generated))
    XCTAssertThrowsError(try ArtworkOutlines.convert(art,ids:[generated.id],mode:"text"))
    for layout in [PublicationPDFLayout.pages,.spreads,.booklet] {
      let data=try PublicationOutput.arrangedPDF(project,documentID:id,assets:FileManager.default.temporaryDirectory,outlineText:true,layout:layout)
      let pdf=try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data:data as CFData))))
      XCTAssertEqual(pdf.numberOfPages,layout == .pages ? 4:layout == .spreads ? 3:2)
    }
    XCTAssertEqual(project,before)
  }
}
