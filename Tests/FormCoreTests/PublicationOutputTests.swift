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

  private func boundsFixture(_ elements:[ArtworkElement])throws->(Project,UUID) {
    var project=Project(name:"Clipped physical page")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
    page.artwork=Artwork(elements:elements,bleed:3);project.objects=[page]
    let id=try PublicationCommands.createPublication(in:&project,name:"Clip preflight",pages:[page.id])
    return(project,id)
  }
  private func overflowIDs(_ project:Project,_ id:UUID)->Set<String> {
    let issues=PublicationOutput.preflight(project,documentID:id)["issues"] as? [[String:Any]] ?? []
    return Set(issues.filter{($0["message"] as? String)?.contains("extends beyond")==true}.compactMap{$0["element_id"] as? String})
  }
  func testBleedPreflightRespectsOwnClipAndRetainsUnmaskedAndEscapingClipWarnings()throws {
    var mask=ArtworkElement(kind:"rectangle",x:10,y:10,width:40,height:40);mask.hidden=true
    var clipped=ArtworkElement(kind:"rectangle",x:-100,y:-100,width:300,height:300);clipped.clipID=mask.id
    let unmasked=ArtworkElement(kind:"rectangle",x:-15,y:20,width:30,height:30)
    var escapingMask=ArtworkElement(kind:"rectangle",x:90,y:20,width:30,height:30);escapingMask.hidden=true
    var escaping=ArtworkElement(kind:"rectangle",x:80,y:10,width:100,height:100);escaping.clipID=escapingMask.id
    let(project,id)=try boundsFixture([mask,clipped,unmasked,escapingMask,escaping]),before=project
    XCTAssertEqual(overflowIDs(project,id),[unmasked.id.uuidString,escaping.id.uuidString])
    XCTAssertEqual(project,before)
  }
  func testBleedPreflightRespectsEveryTransformedAncestorClipForOutlineAndCoverage()throws {
    for mode in ["outline","alpha","luminance"] {
      var outerMask=ArtworkElement(kind:"rectangle",x:15,y:15,width:60,height:60);outerMask.hidden=true
      var outer=ArtworkElement(kind:"group",x:20,y:20,width:50,height:50);outer.contentSize = .init(50,50);outer.rotation=20;outer.affine = .scale(1.2,0.9);outer.clipID=outerMask.id;outer.clipMode=mode
      var innerMask=ArtworkElement(kind:"rectangle",x:-80,y:-80,width:300,height:300);innerMask.hidden=true;innerMask.parentID=outer.id
      var inner=ArtworkElement(kind:"group",x:-50,y:-50,width:200,height:200);inner.contentSize = .init(200,200);inner.rotation = -15;inner.parentID=outer.id;inner.clipID=innerMask.id;inner.clipMode=mode
      var paint=ArtworkElement(kind:"rectangle",x:-300,y:-300,width:700,height:700);paint.parentID=inner.id
      var(project,id)=try boundsFixture([outerMask,outer,innerMask,inner,paint]);let before=project
      XCTAssertTrue(overflowIDs(project,id).isEmpty,"All parent-coordinate masks must constrain the transformed child: \(mode)")
      XCTAssertEqual(project,before)
      project.objects[0].artwork!.elements[1].clipID=nil
      XCTAssertTrue(overflowIDs(project,id).contains(paint.id.uuidString),"The inner clip still escapes; removing the outer clip must expose that warning")
    }
  }
  func testBleedPreflightPreservesAncestorEffectOverflowUntilAnOuterClipContainsIt()throws {
    var group=ArtworkElement(kind:"group",x:0,y:0,width:100,height:140);group.contentSize = .init(100,140)
    var shadow=ArtworkShadow();shadow.enabled=true;shadow.offset = .init(20,0);shadow.blur=0;shadow.opacity=0.8;group.shadow=shadow
    var mask=ArtworkElement(kind:"rectangle",x:80,y:20,width:10,height:20);mask.parentID=group.id;mask.hidden=true
    var paint=ArtworkElement(kind:"rectangle",x:70,y:10,width:40,height:40);paint.parentID=group.id;paint.clipID=mask.id
    var(project,id)=try boundsFixture([group,mask,paint])
    XCTAssertEqual(overflowIDs(project,id),[paint.id.uuidString],"The group's effect is applied after the child clip and really crosses the bleed")
    var outerMask=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:140);outerMask.hidden=true
    project.objects[0].artwork!.elements.append(outerMask);project.objects[0].artwork!.elements[0].clipID=outerMask.id
    let before=project
    XCTAssertTrue(overflowIDs(project,id).isEmpty,"The outer clip also contains the ancestor's effect")
    XCTAssertEqual(project,before)
  }
  func testBleedPreflightChecksActualStrokeExtentBeyondGeometricFrame()throws {
    var paint=ArtworkElement(kind:"rectangle",x:96,y:20,width:5,height:20)
    paint.stroke = .init(color:"#000000",width:4);paint.stroke?.alignment="outside"
    let(project,id)=try boundsFixture([paint])
    XCTAssertEqual(overflowIDs(project,id),[paint.id.uuidString])
  }

}
