import XCTest
import FormCore
import FormGraphics

final class FigmaEffectImportTests: XCTestCase {
  private let scale=25.4/96.0
  private func effect(_ kind:String,spread:Double=0,extra:[String:FigmaValue]=[:])->FigmaValue {
    var value:[String:FigmaValue]=["type":.string(kind),"radius":.double(10),"spread":.double(spread),
      "offset":.object(["x":.double(8),"y":.double(-4)]),"color":.object(["r":.double(1),"g":.double(0),"b":.double(0),"a":.double(0.4)])]
    value.merge(extra){_,new in new};return .object(value)
  }
  private func read(_ effects:[FigmaValue],type:String="RECTANGLE",painted:Bool=true,extra:[String:FigmaValue]=[:]) throws -> FigmaArtworkImportResult {
    var node:[String:FigmaValue]=["guid":.object(["sessionID":.uint(1),"localID":.uint(1)]),"type":.string(type),
      "size":.object(["x":.double(100),"y":.double(60)]),"effects":.array(effects),
      "fillPaints":.array([.object(["type":.string("SOLID"),"color":.object(["r":.double(1),"g":.double(1),"b":.double(1)])])])]
    if !painted {node.removeValue(forKey:"fillPaints")}
    node.merge(extra){_,new in new}
    return try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([.object(node)])])))
  }
  func testMultipleShadowOrderRadiusBlendAndKnockoutMapToNativeEffects() throws {
    let result=try read([effect("DROP_SHADOW",spread:2,extra:["blendMode":.string("MULTIPLY"),"showShadowBehindNode":.bool(false)]),
      effect("INNER_SHADOW",spread:-1),effect("DROP_SHADOW")])
    XCTAssertFalse(result.issues.contains{$0.severity=="error"})
    let e=try XCTUnwrap(result.artwork.elements.first),stack=try XCTUnwrap(e.effectStack)
    XCTAssertEqual(stack.coverage,"paint-outline");XCTAssertEqual(stack.effects.map(\.kind),["drop-shadow","inner-shadow","drop-shadow"])
    XCTAssertEqual(stack.effects[0].blur,4.3*scale,accuracy:1e-12)
    XCTAssertEqual(stack.effects[0].spread,2*scale,accuracy:1e-12)
    XCTAssertEqual(stack.effects[0].offset,.init(8*scale,-4*scale));XCTAssertEqual(stack.effects[0].opacity,0.4)
    XCTAssertEqual(stack.effects[0].blendMode,"multiply");XCTAssertTrue(stack.effects[0].knockout)
    XCTAssertNil(e.shadow);XCTAssertNil(e.blur)
  }
  func testSingleVisualOptimizationPreservesExplicitNormalVersusPassThroughIsolation()throws {
    for (mode,isolated) in [("NORMAL",true),("PASS_THROUGH",false)] {
      let result=try read([effect("DROP_SHADOW",extra:["blendMode":.string("MULTIPLY")])],extra:["blendMode":.string(mode)])
      XCTAssertFalse(result.issues.contains{$0.severity=="error"})
      let element=try XCTUnwrap(result.artwork.elements.first)
      XCTAssertEqual(element.kind,"rectangle");XCTAssertEqual(element.isolatedBlending,isolated)
      XCTAssertEqual(element.effectStack?.effects.first?.blendMode,"multiply")
    }
  }
  func testTextAndOpenGroupSpreadIsIgnoredBySourceSemantics() throws {
    let result=try read([effect("DROP_SHADOW",spread:10),effect("INNER_SHADOW",spread:10)],type:"TEXT",
      extra:["textData":.object(["characters":.string("Editable")])])
    XCTAssertEqual(result.artwork.elements.first?.effectStack?.effects.map(\.spread),[0,0])
    let group=try read([effect("DROP_SHADOW",spread:10)],type:"GROUP")
    XCTAssertEqual(group.artwork.elements.first?.effectStack?.effects.first?.spread,0)
  }
  func testUnknownProgressiveAndBackdropEffectsBlockWithoutGuessing() throws {
    for effects in [[effect("BACKGROUND_BLUR")],[effect("FOREGROUND_BLUR",extra:["blurOpType":.string("PROGRESSIVE")])],
      [effect("DROP_SHADOW",extra:["blendMode":.string("UNKNOWN")])]] {
      XCTAssertTrue(try read(effects).issues.contains{$0.severity=="error"})
    }
    let hidden=effect("BACKGROUND_BLUR",extra:["visible":.bool(false)])
    XCTAssertFalse(try read([hidden]).issues.contains{$0.severity=="error"})
    XCTAssertThrowsError(try read(Array(repeating:effect("DROP_SHADOW"),count:17)))
  }
  func testCurvedSpreadRequiresRepresentableOwnOutline() throws {
    XCTAssertFalse(try read([effect("DROP_SHADOW",spread:4)],type:"ELLIPSE").issues.contains{$0.severity=="error"})
    let curvedFrame=try read([effect("DROP_SHADOW",spread:4)],type:"FRAME",extra:["cornerRadius":.double(8),"frameMaskDisabled":.bool(false)])
    XCTAssertTrue(curvedFrame.issues.contains{$0.severity=="error" && $0.feature=="effects"})
    let oddCorners=try read([effect("DROP_SHADOW",spread:4)],extra:["rectangleTopLeftCornerRadius":.double(8)])
    XCTAssertTrue(oddCorners.issues.contains{$0.severity=="error" && $0.feature=="effects"})
  }
  func testContainerSpreadMatchesExplicitClipAndLegacyBackgroundMapping() throws {
    let unclipped=try read([effect("DROP_SHADOW",spread:4)],type:"FRAME")
    XCTAssertEqual(unclipped.artwork.elements.first?.effectStack?.effects.first?.spread,0)
    let clipped=try read([effect("DROP_SHADOW",spread:4)],type:"FRAME",extra:["frameMaskDisabled":.bool(false)])
    XCTAssertEqual(try XCTUnwrap(clipped.artwork.elements.first?.effectStack?.effects.first?.spread),4*scale,accuracy:1e-12)
    let legacy=try read([effect("DROP_SHADOW",spread:4)],type:"FRAME",painted:false,extra:["frameMaskDisabled":.bool(false),
      "backgroundColor":.object(["r":.double(1),"g":.double(1),"b":.double(1)])])
    XCTAssertEqual(try XCTUnwrap(legacy.artwork.elements.first?.effectStack?.effects.first?.spread),4*scale,accuracy:1e-12)
    // Explicit empty fillPaints wins over the fallback, matching the mapper.
    let empty=try read([effect("DROP_SHADOW",spread:4)],type:"FRAME",extra:["frameMaskDisabled":.bool(false),
      "fillPaints":.array([]),"backgroundColor":.object(["r":.double(1),"g":.double(1),"b":.double(1)])])
    XCTAssertEqual(empty.artwork.elements.first?.effectStack?.effects.first?.spread,0)
  }
}
