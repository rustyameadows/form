import CoreGraphics
import FormCore
import FormGraphics
import ImageIO
import XCTest

final class FigmaArtworkImportTests: XCTestCase {
  private let s=25.4/96.0
  private func guid(_ n:Int)->FigmaValue {.object(["sessionID":.uint(1),"localID":.uint(UInt64(n))])}
  private func solid(_ r:Double,_ g:Double=0,_ b:Double=0,_ alpha:Double=1)->FigmaValue {
    .object(["type":.string("SOLID"),"color":.object(["r":.double(r),"g":.double(g),"b":.double(b),"a":.double(alpha)])])
  }
  private func node(_ id:Int,_ type:String="RECTANGLE",parent:Int?=nil,x:Double=0,y:Double=0,w:Double=100,h:Double=60,
    extra:[String:FigmaValue]=[:])->FigmaValue {
    var value:[String:FigmaValue]=["guid":guid(id),"type":.string(type),"name":.string("Layer \(id)"),
      "size":.object(["x":.double(w),"y":.double(h)]),
      "transform":.object(["m00":.double(1),"m01":.double(0),"m02":.double(x),"m10":.double(0),"m11":.double(1),"m12":.double(y)])]
    if let parent {value["parentIndex"] = .object(["guid":guid(parent),"position":.string(String(format:"%05d",id))])}
    value.merge(extra){_,new in new};return .object(value)
  }
  private func read(_ nodes:[FigmaValue],blobs:[Data]=[],base:Int=0) throws -> FigmaArtworkImportResult {
    try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array(nodes),
      "blobBaseIndex":.int(Int64(base)),"blobs":.array(blobs.map{.object(["bytes":.data($0)])})])))
  }
  private func element(_ result:FigmaArtworkImportResult,_ id:Int) throws -> ArtworkElement {
    let native=try XCTUnwrap(result.sourceNodeIDs["1:\(id)"])
    return try XCTUnwrap(result.artwork.elements.first{$0.id==native})
  }
  private func word(_ value:UInt32,_ data:inout Data) {data.append(contentsOf:(0..<4).map{UInt8((value >> ($0*8)) & 255)})}
  private func floats(_ values:[Float],_ data:inout Data) {for value in values {word(value.bitPattern,&data)}}

  func testHierarchyPaintOrderAffineUnitsAndScopedSourceRemainEditable() throws {
    let frame=node(1,"FRAME",x:90,y:40,w:200,h:120,extra:["resizeToFit":.bool(true)])
    let back=node(2,parent:1,x:10,y:12,extra:["fillPaints":.array([solid(1)])])
    let front=node(3,parent:1,extra:["fillPaints":.array([solid(0,0,1)]),
      "transform":.object(["m00":.double(0),"m01":.double(-2),"m02":.double(80),"m10":.double(1.5),"m11":.double(0.25),"m12":.double(22)])])
    let result=try read([front,frame,back]),a=try element(result,2),b=try element(result,3),group=try element(result,1)
    XCTAssertEqual(result.artwork.elements.map(\.id),[group.id,a.id,b.id])
    XCTAssertEqual(a.parentID,group.id);XCTAssertEqual(b.parentID,group.id)
    XCTAssertEqual(result.selectedRootIDs,[group.id]);XCTAssertEqual(a.color,"#FF0000")
    let transform=result.artwork.worldTransform(b)
    XCTAssertEqual(transform.a,0);XCTAssertEqual(transform.b,1.5);XCTAssertEqual(transform.c,-2);XCTAssertEqual(transform.d,0.25)
    XCTAssertEqual(transform.tx,170*s,accuracy:1e-10);XCTAssertEqual(transform.ty,62*s,accuracy:1e-10)
    XCTAssertEqual(a.width,100*s,accuracy:1e-10)
    let metadata=try XCTUnwrap(b.sourceMetadata)
    XCTAssertEqual(metadata.nodeID,"1:3")
    XCTAssertEqual(try JSONDecoder().decode(FigmaValue.self,from:metadata.properties),front)
    XCTAssertFalse(result.issues.contains{$0.severity=="error"})
  }

  func testCommandBlobsHonorBaseIndexQuadraticControlsAndHoles() throws {
    var commands=Data([1]);floats([0,0],&commands)
    commands.append(3);floats([5,10,10,0],&commands)
    commands.append(2);floats([0,0],&commands);commands.append(0)
    commands.append(1);floats([2,1],&commands);commands.append(2);floats([3,1],&commands)
    commands.append(2);floats([2,2],&commands);commands.append(0)
    let vector=node(1,"VECTOR",w:10,h:10,extra:["fillPaints":.array([solid(1)]),
      "fillGeometry":.array([.object(["commandsBlob":.uint(17),"windingRule":.string("ODD")])])])
    let result=try read([vector],blobs:[commands],base:17),e=try element(result,1)
    let path=try XCTUnwrap(e.path)
    XCTAssertEqual(e.kind,"path");XCTAssertTrue(path.evenOdd);XCTAssertEqual(path.contours.count,2)
    XCTAssertTrue(path.contours.allSatisfy(\.closed))
    XCTAssertEqual(try XCTUnwrap(path.contours[0].nodes[0].outgoing).x,10*s/3,accuracy:1e-8)
    XCTAssertEqual(try XCTUnwrap(path.contours[0].nodes[1].incoming).y,20*s/3,accuracy:1e-8)
    XCTAssertThrowsError(try read([vector],blobs:[Data(commands.dropLast(2))],base:17))
  }

  func testVectorNetworkRegionsAndOpenSegmentsKeepEditableHandles() throws {
    var data=Data();[UInt32(4),4,1].forEach{word($0,&data)}
    for p:[Float] in [[0,0],[10,0],[0,10],[20,20]] {word(0,&data);floats(p,&data)}
    for (a,b) in [(0,1),(1,2),(2,0),(2,3)] {
      word(0,&data);word(UInt32(a),&data);floats(a==0 ? [2,3]:[0,0],&data)
      word(UInt32(b),&data);floats([0,0],&data)
    }
    word(1,&data);word(1,&data);word(3,&data);[UInt32(0),1,2].forEach{word($0,&data)}
    let source=node(1,"VECTOR",w:40,h:40,extra:["vectorData":.object(["vectorNetworkBlob":.uint(0),"normalizedSize":.object(["x":.double(20),"y":.double(20)])]),
      "fillPaints":.array([solid(0,1)]),"strokePaints":.array([solid(0)]),"strokeWeight":.double(1)])
    let result=try read([source],blobs:[data])
    let paths=result.artwork.elements.compactMap(\.path)
    XCTAssertEqual(paths.count,2)
    XCTAssertEqual(paths[0].contours[0].nodes[1].anchor.x,20*s,accuracy:1e-8)
    XCTAssertEqual(try XCTUnwrap(paths[0].contours[0].nodes[0].outgoing).y,6*s,accuracy:1e-8)
    XCTAssertTrue(paths[0].contours[0].closed);XCTAssertFalse(paths[1].contours[0].closed)
  }

  func testFrameClippingSiblingMasksAndMultiplePaintsPreserveDrawingOrder() throws {
    let frame=node(1,"FRAME",extra:["fillPaints":.array([solid(1,1,1)]),"frameMaskDisabled":.bool(false)])
    let mask=node(2,"ELLIPSE",parent:1,extra:["mask":.bool(true),"maskType":.string("OUTLINE")])
    let colored=node(3,parent:1,extra:["fillPaints":.array([solid(1),solid(0,0,1,0.4)])])
    let result=try read([frame,mask,colored]),maskElement=try element(result,2),shape=try element(result,3)
    XCTAssertNotEqual(maskElement.hidden,true)
    let masked=try XCTUnwrap(result.artwork.elements.first{$0.id==shape.parentID})
    XCTAssertEqual(masked.clipID,maskElement.id);XCTAssertEqual(masked.clipMode,"alpha")
    XCTAssertEqual(shape.kind,"group")
    let paints=result.artwork.elements.filter{$0.parentID==shape.id}
    XCTAssertEqual(paints.map(\.color),["#FF0000","#0000FF"]);XCTAssertEqual(paints[1].fillOpacity,0.4)
    let content=try XCTUnwrap(result.artwork.elements.first{$0.id==masked.parentID})
    XCTAssertNotNil(content.clipID)
    XCTAssertFalse(result.issues.contains{$0.severity=="error"})
  }

  func testGradientInverseMatrixAndDisplayP3Conversion() throws {
    let document=node(90,"DOCUMENT",extra:["documentColorProfile":.string("DISPLAY_P3")])
    let gradient:FigmaValue = .object(["type":.string("GRADIENT_LINEAR"),
      "stops":.array([.object(["position":.double(0),"color":.object(["r":.double(0.9),"g":.double(0.3),"b":.double(0.2),"a":.double(0.5)])]),
        .object(["position":.double(1),"color":.object(["r":.double(0),"g":.double(0),"b":.double(1)])])]),
      "transform":.object(["m00":.double(0),"m01":.double(1),"m02":.double(0),"m10":.double(-1),"m11":.double(0),"m12":.double(1)])])
    let result=try read([document,node(1,parent:90,extra:["fillPaints":.array([gradient])])]),e=try element(result,1)
    let g=try XCTUnwrap(e.gradient),t=try XCTUnwrap(g.transform)
    let start=t.apply(.init(g.start.x*e.width,g.start.y*e.height)),end=t.apply(.init(g.end.x*e.width,g.end.y*e.height))
    XCTAssertEqual(start.x,e.width/2,accuracy:1e-9);XCTAssertEqual(start.y,0,accuracy:1e-9)
    XCTAssertEqual(end.y,e.height,accuracy:1e-9)
    XCTAssertNotEqual(g.stops[0].color,"#E64D33");XCTAssertEqual(g.stops[0].opacity,0.5)
  }

  func testAlphaStrokeMasksKeepStrokeCoverageAndLegacyOutlineRemainsGeometric() throws {
    let frame=node(1,"FRAME",extra:["resizeToFit":.bool(true)])
    let strokeMask=node(2,parent:1,extra:["mask":.bool(true),"maskType":.string("ALPHA"),
      "strokePaints":.array([solid(0)]),"strokeWeight":.double(4)])
    let content=node(3,parent:1,extra:["fillPaints":.array([solid(1)])])
    let result=try read([frame,strokeMask,content])
    XCTAssertFalse(result.issues.contains{$0.feature=="mask" && $0.severity=="error"})
    let alphaContent=try element(result,3)
    let maskGroup=try XCTUnwrap(result.artwork.elements.first{$0.id==alphaContent.parentID})
    XCTAssertEqual(maskGroup.clipMode,"alpha")
    var outline=strokeMask.objectValue!;outline["maskIsOutline"] = .bool(true)
    let exact=try read([frame,.object(outline),content])
    XCTAssertFalse(exact.issues.contains{$0.feature=="mask" && $0.severity=="error"})
  }

  func testEmbeddedImageKeepsOriginalBytesAndCropTransform() throws {
    let pixels=Data([255,0,0,255,0,0,255,255])
    let provider=try XCTUnwrap(CGDataProvider(data:pixels as CFData))
    let image=try XCTUnwrap(CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let encoded=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(encoded,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let paint:FigmaValue = .object(["type":.string("IMAGE"),"image":.object(["dataBlob":.uint(0)]),"imageScaleMode":.string("FILL")])
    let result=try read([node(1,w:20,h:20,extra:["fillPaints":.array([paint])])],blobs:[encoded as Data])
    XCTAssertEqual(Array(result.assets.values),[encoded as Data])
    let e=try XCTUnwrap(result.artwork.elements.first{$0.kind=="image"})
    XCTAssertNotNil(e.clipID)
    let box=result.artwork.bounds(of:e)
    XCTAssertEqual(box.x,-10*s,accuracy:1e-8);XCTAssertEqual(box.width,40*s,accuracy:1e-8)
    XCTAssertEqual(box.height,20*s,accuracy:1e-8)
  }

  func testSupportDefinitionsBecomeNativeLinkedComponentsWithoutVisibleSupportCanvas() throws {
    let support=node(90,"CANVAS",extra:["internalOnly":.bool(true)])
    let definition=node(10,"SYMBOL",parent:90,x:900,y:600,w:100,h:50,extra:["resizeToFit":.bool(true)])
    let child=node(11,parent:10,x:5,y:7,w:20,h:10,extra:["fillPaints":.array([solid(1)])])
    let instance=node(1,"INSTANCE",x:20,y:30,w:200,h:100,extra:["symbolData":.object(["symbolID":guid(10),"uniformScaleFactor":.double(2)])])
    let result=try read([support,definition,child,instance]),root=try element(result,1)
    XCTAssertEqual(result.selectedRootIDs,[root.id]);XCTAssertEqual(result.artwork.elements.count,1)
    let component=try XCTUnwrap(result.components.first)
    XCTAssertEqual(root.component?.sourceObjectID,component.id);XCTAssertEqual(component.artwork.elements.count,2)
    XCTAssertEqual(component.artwork.elements[0].affine,.init())
    XCTAssertEqual(root.contentSize?.x,100*s)
    XCTAssertFalse(result.issues.contains{$0.severity=="error"})
    let bundle=try ArtworkTransferBundle.external(artwork:result.artwork,selection:result.selectedRootIDs,assets:result.assets,components:result.components,application:"figma")
    try bundle.validate()
  }

  func testInstanceOverrideMaterializesOnlyOccurrenceAndPreservesNativeDefinitionSource() throws {
    let support=node(90,"CANVAS",extra:["internalOnly":.bool(true)])
    let definition=node(10,"SYMBOL",parent:90,extra:["resizeToFit":.bool(true)])
    let child=node(11,parent:10,x:5,extra:["fillPaints":.array([solid(1)])])
    let override:FigmaValue = .object(["guidPath":.object(["guids":.array([guid(11)])]),"fillPaints":.array([solid(0,1)])])
    let instance=node(1,"INSTANCE",extra:["symbolData":.object(["symbolID":guid(10),"symbolOverrides":.array([override])])])
    let result=try read([support,definition,child,instance]),root=try element(result,1)
    XCTAssertNil(root.component)
    XCTAssertEqual(result.artwork.elements.first{$0.parentID==root.id}?.color,"#00FF00")
    XCTAssertNotNil(root.sourceMetadata)
    XCTAssertTrue(result.issues.contains{$0.feature=="component" && $0.severity=="info"})
  }

  func testResolvedInstanceChildrenTakePrecedenceOverDefinitionGeometry() throws {
    let support=node(90,"CANVAS",extra:["internalOnly":.bool(true)])
    let definition=node(10,"SYMBOL",parent:90,w:100,h:60,extra:["resizeToFit":.bool(true)])
    let sourceChild=node(11,parent:10,x:5,extra:["fillPaints":.array([solid(1)])])
    let instance=node(1,"INSTANCE",w:200,h:120,extra:["symbolData":.object(["symbolID":guid(10)])])
    let resolved=node(2,parent:1,x:31,y:22,w:14,h:17,extra:["fillPaints":.array([solid(0,1)])])
    let result=try read([support,definition,sourceChild,instance,resolved]),root=try element(result,1),child=try element(result,2)
    XCTAssertNil(root.component);XCTAssertEqual(child.parentID,root.id);XCTAssertEqual(child.color,"#00FF00")
    XCTAssertEqual(result.artwork.worldTransform(child).tx,31*s,accuracy:1e-8)
    XCTAssertEqual(result.artwork.bounds(of:child).width,14*s,accuracy:1e-8)
    XCTAssertNil(result.sourceNodeIDs["1:1/1:11"])
  }

  func testCopiedSymbolAppliesRootOpacityAndEffectsExactlyOnce() throws {
    let shadow:FigmaValue = .object(["type":.string("DROP_SHADOW"),"radius":.double(4),
      "color":.object(["r":.double(0),"g":.double(0),"b":.double(0),"a":.double(0.4)])])
    let symbol=node(1,"SYMBOL",extra:["opacity":.double(0.5),"effects":.array([shadow]),"resizeToFit":.bool(true)])
    let child=node(2,parent:1,extra:["fillPaints":.array([solid(1)])])
    let result=try read([symbol,child]),root=try element(result,1),definition=try XCTUnwrap(result.components.first)
    XCTAssertEqual(root.opacity,0.5);XCTAssertEqual(root.effectStack?.effects.first?.kind,"drop-shadow")
    XCTAssertEqual(root.effectStack?.effects.first?.opacity,0.4)
    XCTAssertEqual(definition.artwork.elements[0].opacity,1)
    XCTAssertNil(definition.artwork.elements[0].shadow);XCTAssertNil(definition.artwork.elements[0].effectStack)
  }

  func testRichRunFillWithoutBaseFillIsNotMadeInvisible() throws {
    let run:FigmaValue = .object(["styleID":.uint(2),"fillPaints":.array([solid(1)])])
    let text=node(1,"TEXT",extra:["fontSize":.double(16),"fontName":.object(["postscript":.string("Helvetica")]),
      "textData":.object(["characters":.string("red"),"characterStyleIDs":.array([.uint(2),.uint(2),.uint(2)]),"styleOverrideTable":.array([run])])])
    let e=try element(read([text]),1)
    XCTAssertNotEqual(e.fillEnabled,false);XCTAssertEqual(e.text,"red")
    XCTAssertEqual(e.textRuns?.first?.color,"#FF0000")
  }

  func testFatalIssueSurvivesDenseInformationalDiagnostics() throws {
    let frames=(1...510).map{node($0,"FRAME",extra:["stackMode":.string("VERTICAL")])}
    let missing=node(600,extra:["fillPaints":.array([.object(["type":.string("IMAGE"),"image":.object(["hash":.data(Data([1,2,3]))])])])])
    let result=try read(frames+[missing])
    XCTAssertTrue(result.issues.contains{$0.severity=="error" && $0.feature=="image"})
    XCTAssertLessThanOrEqual(result.issues.count,500)
  }

  func testSinglePaintBlendKeepsSeparateCompositingLevel() throws {
    var fill=solid(1).objectValue!;fill["blendMode"] = .string("MULTIPLY")
    let result=try read([node(1,extra:["fillPaints":.array([.object(fill)]),"blendMode":.string("SCREEN")])]),root=try element(result,1)
    XCTAssertEqual(root.kind,"group");XCTAssertEqual(root.blendMode,"screen")
    XCTAssertEqual(result.artwork.elements.first{$0.parentID==root.id}?.blendMode,"multiply")
  }

  func testMalformedGraphUnknownPaintAndExtremeBlobIndicesFailWithoutTrapping() throws {
    XCTAssertThrowsError(try read([node(1,parent:2),node(2,parent:1)]))
    XCTAssertThrowsError(try read([node(1),node(1)]))
    let shape=node(1,"VECTOR",extra:["fillGeometry":.array([.object(["commandsBlob":.int(Int64.max)])])])
    XCTAssertThrowsError(try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([shape]),"blobBaseIndex":.int(Int64.min),"blobs":.array([])]))))
    let unknown=try read([node(1,extra:["fillPaints":.array([.object(["type":.uint(999)])])])])
    XCTAssertTrue(unknown.issues.contains{$0.severity=="error"})
  }
}
