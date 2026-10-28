import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

/// Shared native text and recoverable outline conversion must agree physically.
@MainActor final class CharacterPositionOutputTests:XCTestCase {
  private let factor=TypographyEngine.pointsPerMM
  private func sample(_ words:String,_ face:String=".AppleSystemUIFont",position:CharacterPosition?=nil)->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:500/factor,height:54/factor,text:words,color:"#18242D",fontSize:36),type=Typography()
    type.fontName=face;type.baseline=3;type.kerningMode="metrics";type.characterPosition=position;e.typography=type;return e
  }
  func testPhysicalComparisonRetainsCompleteBoundsWordsGlyphsAndPublicationWarnings()throws {
    var pages:[[ArtworkElement]]=[],names:[[String]]=[]
    var first:[ArtworkElement]=[]
    first.append(sample("12ab",position:.superscript));first.append(sample("12ab",position:.subscript));first.append(sample("12abQ",position:.superscript));first.append(sample("12abQ","Georgia",position:.subscript))
    var mixed=sample("H12abQ original"),type=mixed.typography!;type.characterPosition = .superscript
    mixed.textRuns=[.init(location:1,length:5,typography:type,fontSize:36,color:mixed.color)];first.append(mixed)
    var optical=sample("12abQ",position:.superscript);optical.typography!.opticalSizing = .init(.automatic);optical.typography!.variations[OpticalSizing.axisID]=72;first.append(optical)
    first.append(sample("مرحبا क्ष e\u{301}",position:.subscript))
    var exact=sample("Q original","Georgia",position:.superscript);let face=try XCTUnwrap(NSFont(name:"Georgia",size:36)),glyphID=Int(CTFontGetGlyphWithName(face as CTFont,"ampersand" as CFString));exact.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:try GlyphCatalog.glyph(fontName:"Georgia",id:glyphID))];first.append(exact)
    pages.append(first);names.append(["System / font forms / superscript","System / font forms / subscript","System / whole-span geometry","Georgia / geometry / subscript","Selected characters / original body","Automatic optical / rendered 23.4pt","Complex scripts / source retained","Exact ampersand glyph / source Q"])
    var second:[ArtworkElement]=[]
    for name in [".AppleSystemUIFont","Baskerville","Didot","Georgia"] {var e=sample("Orbital office / small caps",name);e.typography!.features=[37:1];second.append(e)}
    var caseMapped=sample("straße / i orbit","Baskerville");caseMapped.typography!.features=[37:1];caseMapped.typography!.caseTreatment="uppercase";second.append(caseMapped)
    var listed=sample("First original",position:nil);var raised=listed.typography!;raised.characterPosition = .superscript;listed.textRuns=[.init(location:0,length:5,typography:raised,fontSize:36,color:listed.color)];listed.listItems=[.init(location:0,marker:.decimal,restart:1)];second.append(listed)
    pages.append(second);names.append(["System / genuine small caps","Baskerville / genuine small caps","Didot / genuine small caps","Georgia / no synthetic caps","Case expansion / original straße","Generated list / nominal marker"])
    let assets=FileManager.default.temporaryDirectory;var project=Project(name:"Character forms / physical comparison"),metrics:[[String:Any]]=[]
    for index in pages.indices {
      var object=try project.makeObject(recipeID:"artboard",name:"Comparison \(index+1)",parameters:["width":1200/factor,"depth":780/factor]),elements:[ArtworkElement]=[]
      var heading=sample("FORM / CHARACTER FORMS", "Menlo-Regular");heading.x=50/factor;heading.y=20/factor;heading.fontSize=12;heading.typography!.baseline=0;elements.append(heading)
      var note=heading;note.id=UUID();note.text="LIVE SHARED LAYOUT                                               CONVERTED OUTLINES";note.fontSize=9;note.y=44/factor;note.width=1100/factor;elements.append(note)
      for i in pages[index].indices {
        var left=pages[index][i];left.x=50/factor;left.y=(92+Double(i)*78)/factor
        var label=heading;label.id=UUID();label.text=names[index][i];label.y=left.y-16/factor;label.fontSize=9;elements.append(label)
        elements.append(left);var right=left;right.id=UUID();right.x=650/factor
        let outlined:Artwork
        do {outlined=try ArtworkOutlines.convert(Artwork(elements:[right]),ids:[right.id],mode:"text").artwork}
        catch {XCTFail(names[index][i]+": "+error.localizedDescription);throw error}
        elements += outlined.elements
        let composed=(try TypographyEngine.outlinePaintRuns(left)).map(\.path).reduce(CGRect.null){$0.union($1.boundingBoxOfPath)}
        let world=composed.offsetBy(dx:left.x,dy:left.y)
        XCTAssertFalse(world.isNull);XCTAssertTrue(CGRect(x:0,y:0,width:1200/factor,height:780/factor).contains(world));XCTAssertLessThan(world.maxX*factor+600,1200)
        metrics.append(["page":index+1,"name":names[index][i],"source":left.text,"nominal_points":left.fontSize,"manual_baseline_points":left.typography!.baseline,"left_origin_points":[50,92+Double(i)*78],"right_origin_points":[650,92+Double(i)*78],"ink_bounds_points":[world.minX*factor,world.minY*factor,world.width*factor,world.height*factor],"crop_points":[45,86+Double(i)*78,510,62]])
      }
      object.artwork = .init(background:"#FFFFFF",elements:elements,bleed:0);project.objects.append(object)
    }
    let document=PublicationDocument(name:project.name,pages:project.objects.map{PublicationPage(objectID:$0.id)},margins:.init(top:0,right:0,bottom:0,left:0));project.publications=[document];project.schemaVersion=project.minimumSchemaVersion;let before=project
    let pdf=try PublicationOutput.pdf(project,documentID:document.id,assets:assets,dpi:144)
    let documentPDF=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:pdf as CFData)!));XCTAssertEqual(documentPDF.numberOfPages,2)
    for i in 1...2 {let box=documentPDF.page(at:i)!.getBoxRect(.trimBox);XCTAssertEqual(box.width,1200,accuracy:0.001);XCTAssertEqual(box.height,780,accuracy:0.001)}
    let report=PublicationOutput.preflight(project,documentID:document.id,assets:assets),issues=report["issues"] as? [[String:Any]] ?? []
    XCTAssertEqual(report["can_export"] as? Bool,true);XCTAssertTrue(issues.contains{$0["code"] as? String=="character_forms"});XCTAssertEqual(project,before)
    if let path=ProcessInfo.processInfo.environment["FORM_CHARACTER_POSITION_PROOF_DIR"] {
      let root=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      try pdf.write(to:root.appendingPathComponent("Form-character-forms.pdf"),options:.atomic)
      try JSONEncoder.form.encode(project).write(to:root.appendingPathComponent("Source.json"),options:.atomic)
      try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("Metrics.json"),options:.atomic)
      for object in project.objects {try SVGRenderer.document(object.artwork!,width:object.artworkSize.x,height:object.artworkSize.y,assets:assets,outlineText:false).write(to:root.appendingPathComponent(object.name+".svg"),atomically:true,encoding:.utf8)}
    }
  }
}
