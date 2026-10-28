import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationOutputTests:XCTestCase {
  private func proofDirectory()->URL? {ProcessInfo.processInfo.environment["FORM_PUBLICATION_PROOF_DIR"].map{URL(fileURLWithPath:$0)}}
  private func retain(_ data:Data,name:String) throws {
    if let folder=proofDirectory() {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try data.write(to:folder.appendingPathComponent(name),options:.atomic)}
  }
  func testIllustratedThreePageBookletHasRealOrderedPhysicalBoxesAndOneFlowingStory() throws {
    let p=try Samples.fieldGuide(),before=p,document=try XCTUnwrap(p.publications?.first)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let report=PublicationOutput.preflight(p,documentID:document.id,assets:root)
    XCTAssertEqual(report["can_export"] as? Bool,true)
    let story=try XCTUnwrap(p.textStories?.first),context=try XCTUnwrap(p.resolvedTextStory(story.id)),composition=PublicationStoryLayout.composition(context)
    XCTAssertEqual(story.frames.count,4);XCTAssertEqual(composition.oversetRange.length,0)
    XCTAssertGreaterThan(composition.sourceRange(3).length,0,"The final physical column must contain actual flowing source.")
    var covered=Set<Int>()
    for i in composition.containers.indices {let range=composition.sourceRange(i);covered.formUnion(range.location..<NSMaxRange(range))}
    XCTAssertEqual(covered.count,story.text.utf16.count)
    for outlined in [false,true] {
      let data=try PublicationOutput.pdf(p,documentID:document.id,assets:root,dpi:144,outlineText:outlined)
      try retain(data,name:outlined ? "orbital-booklet-outlined.pdf":"orbital-booklet.pdf")
      let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data as CFData)!));XCTAssertEqual(pdf.numberOfPages,3)
      for i in 0..<3 {
        let object=p.objects.first{$0.id==document.pages[i].objectID}!,page=try XCTUnwrap(pdf.page(at:i+1))
        let media=page.getBoxRect(.mediaBox),trim=page.getBoxRect(.trimBox),bleed=page.getBoxRect(.bleedBox)
        XCTAssertEqual(trim.width/TypographyEngine.pointsPerMM,object.artworkSize.x,accuracy:0.001)
        XCTAssertEqual(trim.height/TypographyEngine.pointsPerMM,object.artworkSize.y,accuracy:0.001)
        XCTAssertEqual(trim.minX/TypographyEngine.pointsPerMM,3,accuracy:0.001);XCTAssertEqual(trim.minY/TypographyEngine.pointsPerMM,3,accuracy:0.001)
        XCTAssertEqual(media.width,trim.width+6*TypographyEngine.pointsPerMM,accuracy:0.001)
        XCTAssertEqual(media.height,trim.height+6*TypographyEngine.pointsPerMM,accuracy:0.001);XCTAssertEqual(bleed,media)
      }
    }
    for (i,page) in document.pages.enumerated() {
      let object=p.objects.first{$0.id==page.objectID}!,art=try XCTUnwrap(p.surfaceArtwork(object))
      let image=ArtworkRenderer.image(art,width:object.artworkSize.x,height:object.artworkSize.y,assets:root,pixelsPerMM:3)
      let bitmap=try XCTUnwrap(image.representations.first as? NSBitmapImageRep),data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
      try retain(data,name:"orbital-booklet-native-\(i+1).png")
    }
    XCTAssertEqual(p,before)
    let rawFrames:[ArtworkElement]=p.objects.flatMap{$0.artwork?.elements ?? []}.filter{$0.storyFrame != nil}
    for frame in rawFrames {XCTAssertEqual(frame.text,"");XCTAssertNil(frame.textRuns);XCTAssertNil(frame.listItems)}
  }
  func testPageReorderReflowsTheGlobalStoryAndPreservesWords() throws {
    var p=try Samples.fieldGuide(),document=p.publications![0]
    let text=p.textStories![0].text,oldFrames=p.textStories![0].frames
    document.pages.swapAt(1,2);try PublicationCommands.setPublication(in:&p,document:document)
    XCTAssertEqual(p.textStories![0].text,text);XCTAssertNotEqual(p.textStories![0].frames,oldFrames)
    XCTAssertEqual(p.textStories![0].frames.first?.objectID,document.pages[1].objectID)
    let context=try XCTUnwrap(p.resolvedTextStory(p.textStories![0].id)),layout=PublicationStoryLayout.composition(context)
    XCTAssertEqual(layout.oversetRange.length,0)
  }
  func testDefaultExportRefusesOversetAndReviewedPartialOutputKeepsSource() throws {
    var p=try Samples.fieldGuide();let document=p.publications![0],story=p.textStories![0]
    for frame in story.frames {
      let i=p.objects.firstIndex{$0.id==frame.objectID}!,j=p.objects[i].artwork!.elements.firstIndex{$0.id==frame.elementID}!
      p.objects[i].artwork!.elements[j].height=5
    }
    let before=p,assets=FileManager.default.temporaryDirectory
    XCTAssertEqual(PublicationOutput.preflight(p,documentID:document.id)["can_export"] as? Bool,false)
    XCTAssertThrowsError(try PublicationOutput.pdf(p,documentID:document.id,assets:assets))
    let reviewed=try PublicationOutput.pdf(p,documentID:document.id,assets:assets,allowOverset:true)
    XCTAssertGreaterThan(reviewed.count,1000);XCTAssertEqual(p,before)
  }
  func testConflictingProfileAssignmentsFailPreflightBeforeOutput() throws {
    var p=try Samples.fieldGuide();let document=p.publications![0]
    let digest=String(repeating:"a",count:64)
    p.objects[0].artwork!.outputColorProfile = .init(name:"First page only",asset:"icc-"+digest+".icc",sha256:digest,model:"CMYK")
    let report=PublicationOutput.preflight(p,documentID:document.id)
    XCTAssertEqual(report["can_export"] as? Bool,false)
    XCTAssertThrowsError(try PublicationOutput.pdf(p,documentID:document.id,assets:FileManager.default.temporaryDirectory,allowOverset:true))
  }
  func testMatchingPortableCMYKProfileConvertsActualBookletAndRetainsAllMixedPageBoxes() throws {
    var p=try Samples.fieldGuide();let id=p.publications![0].id
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"))
    try profile.store(in:root)
    for i in p.objects.indices {p.objects[i].artwork!.outputColorProfile=profile.reference}
    let before=p,source=try PublicationOutput.pdf(p,documentID:id,assets:root)
    try retain(source,name:"orbital-booklet-cmyk.pdf")
    let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:source as CFData)!));XCTAssertEqual(pdf.numberOfPages,3)
    for i in 1...3 {
      let page=try XCTUnwrap(pdf.page(at:i)),trim=page.getBoxRect(.trimBox)
      XCTAssertEqual(trim.width/TypographyEngine.pointsPerMM,i==3 ? 210:160,accuracy:0.001)
      XCTAssertEqual(trim.height/TypographyEngine.pointsPerMM,i==3 ? 160:210,accuracy:0.001)
      var stream:CGPDFStreamRef?;XCTAssertTrue(CGPDFDictionaryGetStream(page.dictionary!,"Contents",&stream))
      var format=CGPDFDataFormat.raw
      let bytes=try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream),&format)) as Data
      let content=try XCTUnwrap(String(data:bytes,encoding:.isoLatin1))
      XCTAssertNotNil(content.range(of:#"(?:[0-9.]+\s+){4}sc\b"#,options:.regularExpression))
    }
    XCTAssertEqual(p,before)
    let result=PublicationOutput.preflight(p,documentID:id,assets:root)
    XCTAssertEqual(result["can_export"] as? Bool,true)
  }

}
