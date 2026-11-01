import FormCore
import FormGraphics
import XCTest

final class FigmaTextPaintImportTests:XCTestCase {
  private func solid(_ opacity:Double)->FigmaValue {
    .object(["type":.string("SOLID"),"opacity":.double(opacity),"color":.object(["r":.double(1),"g":.double(0),"b":.double(0),"a":.double(0.5)])])
  }
  private var gradient:FigmaValue {
    .object(["type":.string("GRADIENT_LINEAR"),"opacity":.double(0.75),
      "stops":.array([.object(["position":.double(0),"color":.object(["r":.double(0),"g":.double(0),"b":.double(1)])]),
        .object(["position":.double(1),"color":.object(["r":.double(0),"g":.double(1),"b":.double(0)])])])])
  }
  private func read(_ extra:[String:FigmaValue])throws->FigmaArtworkImportResult {
    var node:[String:FigmaValue]=["guid":.string("text"),"type":.string("TEXT"),
      "size":.object(["x":.double(120),"y":.double(60)]),"fontSize":.double(20),
      "fontName":.object(["postscript":.string("Helvetica")]),"textData":.object(["characters":.string("AB")])]
    node.merge(extra){_,new in new}
    return try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([.object(node)])])))
  }
  func testLiveTextKeepsOrderedGradientFillAndStrokeWithoutDoubleOpacity()throws {
    let result=try read(["fillPaints":.array([solid(0.5),gradient]),"strokePaints":.array([gradient]),
      "strokeWeight":.double(2),"strokeAlign":.string("OUTSIDE"),"opacity":.double(0.8)])
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    let text=try XCTUnwrap(result.artwork.elements.first{$0.kind=="text"}),stack=try XCTUnwrap(text.paintStack)
    XCTAssertEqual(text.text,"AB");XCTAssertEqual(text.opacity,0.8);XCTAssertNil(text.fillOpacity)
    XCTAssertEqual(stack.count,3);XCTAssertEqual(stack.map{$0.paint.kind},["solid","gradient","gradient"])
    XCTAssertEqual(stack[0].paint.opacity,0.25);XCTAssertEqual(stack[1].paint.opacity,0.75)
    XCTAssertNil(stack[0].stroke);XCTAssertEqual(stack[2].stroke?.width,2*25.4/96)
    XCTAssertEqual(stack[2].stroke?.alignment,"outside")
    let copy=try JSONDecoder().decode(Artwork.self,from:JSONEncoder().encode(result.artwork))
    XCTAssertEqual(copy.elements.first{$0.kind=="text"}?.paintStack,stack)
  }
  func testRichRangeGradientOverridesOnlyItsCharacters()throws {
    let style:FigmaValue = .object(["styleID":.uint(3),"fillPaints":.array([gradient])])
    let textData:FigmaValue = .object(["characters":.string("AB"),"characterStyleIDs":.array([.uint(0),.uint(3)]),"styleOverrideTable":.array([style])])
    let result=try read(["fillPaints":.array([solid(1)]),"textData":textData])
    let text=try XCTUnwrap(result.artwork.elements.first{$0.kind=="text"})
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    let run=try XCTUnwrap(text.textRuns?.first{$0.paintStack != nil})
    XCTAssertEqual(run.paintStack?.first?.paint.kind,"gradient")
    XCTAssertEqual(text.paintStack?.first?.paint.kind,"solid")
    XCTAssertEqual(run.length,1)
  }
  func testFigmaEffectRadiusMapsToGaussianSigmaAndUnknownEnumsFailExplicitly()throws {
    let effect:FigmaValue = .object(["type":.string("FOREGROUND_BLUR"),"radius":.double(10)])
    let result=try read(["fillPaints":.array([solid(1)]),"effects":.array([effect])])
    let text=try XCTUnwrap(result.artwork.elements.first{$0.kind=="text"})
    XCTAssertEqual(try XCTUnwrap(text.effectStack?.effects.first).blur,10*0.43*25.4/96,accuracy:1e-10)
    let unsupported=try read(["effects":.array([.object(["type":.uint(999),"blendMode":.uint(10)])])])
    XCTAssertTrue(unsupported.issues.contains{$0.feature=="effects" && $0.severity=="error"})
  }
}
