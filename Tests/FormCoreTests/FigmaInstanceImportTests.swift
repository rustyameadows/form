import FormCore
import FormGraphics
import XCTest

final class FigmaInstanceImportTests:XCTestCase {
  private let mm=25.4/96.0
  private func id(_ n:Int)->FigmaValue {.object(["sessionID":.uint(8),"localID":.uint(UInt64(n))])}
  private func color(_ r:Double,_ g:Double=0,_ b:Double=0)->FigmaValue {
    .object(["type":.string("SOLID"),"color":.object(["r":.double(r),"g":.double(g),"b":.double(b)])])
  }
  private func node(_ n:Int,_ type:String="RECTANGLE",parent:Int?=nil,size:Point2 = .init(100,100),x:Double=0,y:Double=0,
    fields:[String:FigmaValue]=[:])->FigmaValue {
    var v:[String:FigmaValue]=["guid":id(n),"type":.string(type),"name":.string("Layer \(n)"),
      "size":.object(["x":.double(size.x),"y":.double(size.y)]),
      "transform":.object(["m00":.double(1),"m11":.double(1),"m02":.double(x),"m12":.double(y)])]
    if let parent {v["parentIndex"] = .object(["guid":id(parent),"position":.string(String(format:"%05d",n))])}
    v.merge(fields){_,new in new};return .object(v)
  }
  private func instance(_ n:Int,_ source:Int,parent:Int?=nil,size:Point2 = .init(100,100),claims:[FigmaValue]=[],fields:[String:FigmaValue]=[:])->FigmaValue {
    var fields=fields
    fields["symbolData"] = .object(["symbolID":id(source),"symbolOverrides":.array(claims)])
    return node(n,"INSTANCE",parent:parent,size:size,fields:fields)
  }
  private func claim(_ path:[Int],_ fields:[String:FigmaValue])->FigmaValue {
    var fields=fields;fields["guidPath"] = .object(["guids":.array(path.map(id))]);return .object(fields)
  }
  private func read(_ values:[FigmaValue]) throws -> FigmaArtworkImportResult {
    try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([node(900,"CANVAS",fields:["internalOnly":.bool(true)])]+values)])))
  }
  private func native(_ result:FigmaArtworkImportResult,_ key:String) throws -> ArtworkElement {
    let id=try XCTUnwrap(result.sourceNodeIDs[key],key)
    return try XCTUnwrap(result.artwork.elements.first{$0.id==id},key)
  }
  private func noErrors(_ result:FigmaArtworkImportResult,file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[],file:file,line:line)
  }

  func testNestedRepeatedComponentOverrideChangesOnlyAddressedOccurrence() throws {
    let nodes=[node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),
      node(11,"FRAME",parent:10,fields:["resizeToFit":.bool(true)]),
      instance(12,20,parent:11),instance(13,20,parent:11),
      node(20,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),
      node(21,parent:20,fields:["fillPaints":.array([color(1)]),"overrideKey":id(99)]),
      instance(1,10,claims:[claim([10,12,99],["fillPaints":.array([color(0,1)])])])]
    let result=try read(nodes)
    noErrors(result)
    XCTAssertEqual(try native(result,"8:1/8:11/8:12/8:21").color,"#00FF00")
    XCTAssertEqual(try native(result,"8:1/8:11/8:13/8:21").color,"#FF0000")
    XCTAssertNil(try native(result,"8:1").component)
    let bundle=try ArtworkTransferBundle.external(artwork:result.artwork,selection:result.selectedRootIDs,
      assets:result.assets,components:result.components,application:"figma")
    try bundle.validate()
  }

  func testNestedSwapPrecedesDescendantClaimAndPreservesSibling() throws {
    let nodes=[node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),instance(11,20,parent:10),instance(12,20,parent:10),
      node(20,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),node(21,parent:20,fields:["fillPaints":.array([color(1)])]),
      node(30,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),node(31,parent:30,fields:["fillPaints":.array([color(0,0,1)])]),
      instance(1,10,claims:[claim([11,31],["fillPaints":.array([color(0,1)])]),claim([11],["symbolData":.object(["symbolID":id(30)])])])]
    let result=try read(nodes)
    noErrors(result)
    XCTAssertEqual(try native(result,"8:1/8:11/8:31").color,"#00FF00")
    XCTAssertEqual(try native(result,"8:1/8:12/8:21").color,"#FF0000")
    XCTAssertNil(result.sourceNodeIDs["8:1/8:11/8:21"])
  }

  func testFreeformResizeUsesEachConstraintAndDerivedBoundsWin() throws {
    let derived=claim([12],["size":.object(["x":.double(33),"y":.double(44)]),
      "transform":.object(["m00":.double(1),"m11":.double(1),"m02":.double(75),"m12":.double(81)])])
    let nodes=[node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),
      node(11,parent:10,size:.init(20,10),x:10,y:10,fields:["fillPaints":.array([color(1)]),"horizontalConstraint":.string("MAX"),"verticalConstraint":.string("CENTER")]),
      node(12,parent:10,size:.init(20,10),x:10,y:10,fields:["fillPaints":.array([color(1)]),"horizontalConstraint":.string("STRETCH"),"verticalConstraint":.string("SCALE")]),
      instance(1,10,size:.init(200,150),fields:["derivedSymbolData":.array([derived])])]
    let result=try read(nodes),a=try native(result,"8:1/8:11"),b=try native(result,"8:1/8:12")
    noErrors(result)
    XCTAssertEqual(result.artwork.worldTransform(a).tx,110*mm,accuracy:1e-8)
    XCTAssertEqual(result.artwork.worldTransform(a).ty,35*mm,accuracy:1e-8)
    XCTAssertEqual(a.width,20*mm,accuracy:1e-8)
    XCTAssertEqual(result.artwork.worldTransform(b).tx,75*mm,accuracy:1e-8)
    XCTAssertEqual(b.width,33*mm,accuracy:1e-8);XCTAssertEqual(b.height,44*mm,accuracy:1e-8)
  }

  func testOuterClearedPaintAndVisibilityOverridesBeatInnerClaims() throws {
    let inner=instance(11,20,parent:10,claims:[claim([21],["fillPaints":.array([color(0,1)]),"visible":.bool(true)])])
    let nodes=[node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),inner,
      node(20,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),node(21,parent:20,fields:["fillPaints":.array([color(1)])]),
      instance(1,10,claims:[claim([11,21],["fillPaints":.array([]),"visible":.bool(false)])])]
    let result=try read(nodes),e=try native(result,"8:1/8:11/8:21")
    noErrors(result);XCTAssertEqual(e.fillEnabled,false);XCTAssertEqual(e.hidden,true)
  }

  func testLiteralComponentPropertiesResolveTextAndVisibility() throws {
    let definitions:FigmaValue = .array([.object(["id":id(91),"initialValue":.object(["boolValue":.bool(true)])]),
      .object(["id":id(92),"initialValue":.object(["textValue":.object(["characters":.string("Before")])])])])
    let text=node(11,"TEXT",parent:10,fields:["fontSize":.double(16),"fontName":.object(["postscript":.string("Helvetica")]),
      "fillPaints":.array([color(0)]),"textData":.object(["characters":.string("Before")]),
      "componentPropRefs":.array([.object(["defID":id(92),"componentPropNodeField":.string("TEXT_DATA")])])])
    let hidden=node(12,parent:10,fields:["fillPaints":.array([color(1)]),
      "componentPropRefs":.array([.object(["defID":id(91),"componentPropNodeField":.string("VISIBLE")])])])
    let assignments:FigmaValue = .array([.object(["defID":id(91),"value":.object(["boolValue":.bool(false)])]),
      .object(["defID":id(92),"value":.object(["textValue":.object(["characters":.string("After")])])])])
    let result=try read([node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true),"componentPropDefs":definitions]),text,hidden,
      instance(1,10,fields:["componentPropAssignments":assignments])])
    noErrors(result)
    XCTAssertEqual(try native(result,"8:1/8:11").text,"After")
    XCTAssertEqual(try native(result,"8:1/8:12").hidden,true)
  }

  func testOuterNestedPropertyAssignmentsRebindOnlyTargetedInstance() throws {
    let definitions:FigmaValue = .array([.object(["id":id(91),"initialValue":.object(["boolValue":.bool(true)])])])
    let binding:FigmaValue = .array([.object(["defID":id(91),"componentPropNodeField":.string("VISIBLE")])])
    let assignments:FigmaValue = .array([.object(["defID":id(91),"value":.object(["boolValue":.bool(false)])])])
    let result=try read([node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),
      instance(11,20,parent:10),instance(12,20,parent:10),
      node(20,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true),"componentPropDefs":definitions]),
      node(21,parent:20,fields:["fillPaints":.array([color(1)]),"componentPropRefs":binding]),
      instance(1,10,claims:[claim([11],["componentPropAssignments":assignments])])])
    noErrors(result)
    XCTAssertEqual(try native(result,"8:1/8:11/8:21").hidden,true)
    XCTAssertNotEqual(try native(result,"8:1/8:12/8:21").hidden,true)
    let root=try read([node(20,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true),"componentPropDefs":definitions]),
      node(21,parent:20,fields:["fillPaints":.array([color(1)]),"componentPropRefs":binding]),
      instance(1,20,claims:[claim([20],["componentPropAssignments":assignments])])])
    noErrors(root);XCTAssertEqual(try native(root,"8:1/8:21").hidden,true)
  }

  func testExcessiveClaimWorkIsRejectedBeforeRepeatedResolution() throws {
    let repeated=Array(repeating:claim([11],["opacity":.double(0.5)]),count:10_001)
    XCTAssertThrowsError(try read([node(10,"SYMBOL",parent:900),node(11,parent:10),instance(1,10,claims:repeated)])) { error in
      XCTAssertTrue(String(describing:error).contains("10,000 instance claims"))
    }
  }

  func testAmbiguousOrImplicitInstanceBoundaryPathsAreRejected() throws {
    let sources=[node(10,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),instance(11,20,parent:10),instance(12,20,parent:10),
      node(20,"SYMBOL",parent:900,fields:["resizeToFit":.bool(true)]),node(21,parent:20,fields:["fillPaints":.array([color(1)])])]
    let result=try read(sources+[instance(1,10,claims:[claim([21],["visible":.bool(false)])])])
    XCTAssertTrue(result.issues.contains{$0.feature=="instance-override" && $0.severity=="error"})
    XCTAssertThrowsError(try read([node(10,"SYMBOL",parent:900),instance(11,10,parent:10),instance(1,10,claims:[claim([],["opacity":.double(0.5)])])]))
  }
}
