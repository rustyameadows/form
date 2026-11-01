import FormCore
import FormGraphics
import XCTest

final class FigmaMaskImportTests:XCTestCase {
  private func node(_ id:String,mask:String?=nil,visible:Bool=true,opacity:Double=1)->FigmaValue {
    var fields:[String:FigmaValue]=["guid":.string(id),"type":.string("RECTANGLE"),"parentIndex":.object(["guid":.string("frame"),"position":.string(id)]),
      "size":.object(["x":.double(100),"y":.double(80)]),"visible":.bool(visible),"opacity":.double(opacity),
      "fillPaints":.array([.object(["type":.string("SOLID"),"color":.object(["r":.double(1),"g":.double(1),"b":.double(1)])])])]
    if let mask {fields["mask"] = .bool(true);fields["maskType"] = .string(mask)}
    return .object(fields)
  }
  private func read(_ nodes:[FigmaValue])throws->FigmaArtworkImportResult {
    let frame:FigmaValue = .object(["guid":.string("frame"),"type":.string("FRAME"),"size":.object(["x":.double(100),"y":.double(80)]),"resizeToFit":.bool(true)])
    return try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([frame]+nodes)])))
  }
  private func e(_ result:FigmaArtworkImportResult,_ key:String)throws->ArtworkElement {
    let id=try XCTUnwrap(result.sourceNodeIDs[key]);return try XCTUnwrap(result.artwork.elements.first{$0.id==id})
  }
  func testAlphaMaskAppliesOnceToCompleteOverlappingSiblingRun()throws {
    let result=try read([node("a",mask:"ALPHA",opacity:0.5),node("b"),node("c")]),mask=try e(result,"a"),b=try e(result,"b"),c=try e(result,"c")
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    XCTAssertEqual(b.parentID,c.parentID);XCTAssertNil(b.clipID);XCTAssertNil(c.clipID)
    let group=try XCTUnwrap(result.artwork.elements.first{$0.id==b.parentID})
    XCTAssertEqual(group.clipID,mask.id);XCTAssertEqual(group.clipMode,"alpha")
    XCTAssertEqual(mask.opacity,0.5);XCTAssertNotEqual(mask.hidden,true)
  }
  func testConsecutiveMixedMasksCreateIndependentCoverageCarriers()throws {
    let result=try read([node("a",mask:"ALPHA",opacity:0.5),node("b",mask:"LUMINANCE",opacity:0.25),node("c")])
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    let a=try e(result,"a"),b=try e(result,"b"),content=try e(result,"c")
    XCTAssertEqual(a.parentID,b.parentID)
    let coverage=try XCTUnwrap(result.artwork.elements.first{$0.id==a.parentID})
    let carriers=result.artwork.elements.filter{$0.parentID==coverage.id && $0.clipID != nil}
    XCTAssertEqual(Set(carriers.compactMap(\.clipID)),[a.id,b.id])
    XCTAssertEqual(Set(carriers.compactMap(\.clipMode)),["alpha","luminance-alpha"])
    let group=try XCTUnwrap(result.artwork.elements.first{$0.id==content.parentID})
    XCTAssertEqual(group.clipID,coverage.id);XCTAssertEqual(group.clipMode,"alpha")
  }
  func testHiddenMaskDoesNotStartOrSplitVisibleMaskRun()throws {
    let unmasked=try read([node("a",mask:"ALPHA",visible:false),node("b")])
    XCTAssertEqual(try e(unmasked,"b").parentID,try e(unmasked,"frame").id)
    let consecutive=try read([node("a",mask:"ALPHA"),node("b",mask:"ALPHA",visible:false),node("c",mask:"ALPHA"),node("d")])
    XCTAssertEqual(try e(consecutive,"a").parentID,try e(consecutive,"c").parentID)
  }
  func testVectorMaskRetainsStrokeOnlyRegionAndMakesNonzeroInkOpaque()throws {
    var source=node("a",mask:"OUTLINE",opacity:0.6).objectValue!
    source["fillPaints"] = .array([])
    source["strokePaints"] = .array([.object(["type":.string("SOLID"),"opacity":.double(0.2),"color":.object(["r":.double(1),"g":.double(0),"b":.double(0)])])])
    source["strokeWeight"] = .double(5)
    let result=try read([.object(source),node("b")]),mask=try e(result,"a"),content=try e(result,"b")
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    XCTAssertEqual(mask.fillEnabled,false);XCTAssertEqual(mask.stroke?.opacity,1)
    XCTAssertEqual(mask.stroke?.color,"#FFFFFF");XCTAssertEqual(mask.opacity,0.6)
    let group=try XCTUnwrap(result.artwork.elements.first{$0.id==content.parentID})
    XCTAssertEqual(group.clipMode,"alpha")
    let original=try JSONDecoder().decode(FigmaValue.self,from:XCTUnwrap(mask.sourceMetadata).properties)
    XCTAssertEqual(original["strokePaints"]?.arrayValue?.first?["opacity"],.double(0.2))
    var fill=node("a",mask:"OUTLINE").objectValue!
    fill["fillPaints"] = .array([.object(["type":.string("SOLID"),"opacity":.double(0.1),"color":.object(["r":.double(0),"g":.double(1),"b":.double(0),"a":.double(0.1)])])])
    let filled=try e(read([.object(fill),node("b")]),"a")
    XCTAssertEqual(filled.fillOpacity,1);XCTAssertEqual(filled.color,"#FFFFFF")
  }

  func testUnknownDeclaredDocumentProfileIsAnErrorInsteadOfSRGBFallback()throws {
    for profile:FigmaValue in [.string("UNKNOWN_PROFILE"),.uint(999)] {
      let document:FigmaValue = .object(["guid":.string("document"),"type":.string("DOCUMENT"),"documentColorProfile":profile])
      let result=try read([document,node("a")])
      XCTAssertTrue(result.issues.contains{$0.feature=="color-profile" && $0.severity=="error"})
    }
  }
}
