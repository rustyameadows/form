import XCTest
@testable import FormCore

final class ArtworkEffectTransferTests:XCTestCase {
  func testPaletteClosureIncludesDisabledEffectsAndRemapsAcrossDocuments()throws {
    var project=Project(name:"Effect palette"),destination=Project(name:"Destination")
    let owner=try project.ensureCanvasWorkspace(),target=try destination.ensureCanvasWorkspace()
    let active=ArtworkSwatch(name:"Shadow",color:"#224466"),disabled=ArtworkSwatch(name:"Retained shadow",color:"#886644")
    project.swatches=[active,disabled,.init(name:"Unused",color:"#FF0000")]
    var layer=ArtworkElement(kind:"text",x:0,y:0,width:80,height:30,text:"Still editable")
    layer.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",blur:1,swatchID:active.id),
      .init(kind:"inner-shadow",enabled:false,spread:2,swatchID:disabled.id)])
    try project.setArtwork(.init(elements:[layer]),for:owner.id)
    let bundle=try ArtworkTransferGraph.capture(project:project,objectID:owner.id,ids:[layer.id],readAsset:{_,_ in XCTFail("No bitmap needed for editable effects");return Data()})
    XCTAssertEqual(Set(bundle.metadata.swatches.map(\.id)),[active.id,disabled.id])
    let plan=try ArtworkTransferGraph.plan(.decode(bundle.encoded()),into:destination,objectID:target.id)
    let pasted=try XCTUnwrap(plan.project.canvasWorkspace?.artwork?.elements.first),effects=try XCTUnwrap(pasted.effectStack?.effects)
    XCTAssertNotEqual(effects[0].swatchID,active.id);XCTAssertNotEqual(effects[1].swatchID,disabled.id)
    XCTAssertEqual(effects.map(\.kind),["drop-shadow","inner-shadow"]);XCTAssertFalse(effects[1].enabled)
    XCTAssertEqual(pasted.text,layer.text);XCTAssertNil(pasted.path)
    try plan.project.validateSwatches()
    let resolved=plan.project.resolvingSwatches(in:plan.project.canvasWorkspace!.artwork!).elements[0]
    XCTAssertEqual(resolved.effectStack?.effects.map(\.color),[active.color,disabled.color])
    XCTAssertTrue(resolved.effectStack!.effects.allSatisfy{$0.swatchID==nil})
    let copied=try ArtworkTransferGraph.capture(project:plan.project,objectID:target.id,ids:plan.selection,readAsset:{_,_ in Data()})
    XCTAssertEqual(copied.metadata.swatches.count,2)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(plan.project))
    XCTAssertEqual(reopened.objects,plan.project.objects)
  }
  func testChangingAndDeletingEffectSwatchPreservesEveryOtherEffectSetting()throws {
    var project=Project(name:"Linked effects");let owner=try project.ensureCanvasWorkspace()
    let swatch=try SwatchCommands.save(in:&project,name:"Ink",color:"#112233")
    var layer=ArtworkElement(kind:"rectangle",x:0,y:0,width:30,height:20)
    layer.effectStack = .init(effects:[.init(kind:"drop-shadow",offset:.init(-3,4),blur:2,spread:1,
      opacity:0.3,blendMode:"multiply",knockout:true,swatchID:swatch)])
    try project.setArtwork(.init(elements:[layer]),for:owner.id)
    try SwatchCommands.save(in:&project,id:swatch,name:"Ink",color:"#AABBCC")
    let before=project.resolvingSwatches(in:project.canvasWorkspace!.artwork!)
    try SwatchCommands.delete(in:&project,id:swatch)
    XCTAssertEqual(project.canvasWorkspace!.artwork!,before)
    XCTAssertNil(project.canvasWorkspace!.artwork!.elements[0].effectStack!.effects[0].swatchID)
  }
  func testShorthandAppearanceEditDefaultsAndRejectsMalformedReplacementAtomically()throws {
    var project=Project(name:"Stack commands");let owner=try project.ensureCanvasWorkspace()
    let layer=ArtworkElement(kind:"rectangle",x:0,y:0,width:30,height:20)
    try project.setArtwork(.init(elements:[layer]),for:owner.id)
    try AppearanceCommands.apply(in:&project,objectID:owner.id,ids:[layer.id],values:["effect_stack":["effects":[["kind":"drop-shadow","blur":2]]]])
    let stack=try XCTUnwrap(project.canvasWorkspace?.artwork?.elements[0].effectStack)
    XCTAssertEqual(stack.coverage,"paint-alpha");XCTAssertEqual(stack.effects[0],.init(kind:"drop-shadow",blur:2))
    let before=project
    for value:[String:Any] in [["effects":[["kind":"drop-shadow","opacity":2]]],
      ["effects":[["kind":"drop-shadow","enabled":1]]],["effects":[["kind":"blur","unexpected":true]]]] {
      XCTAssertThrowsError(try AppearanceCommands.apply(in:&project,objectID:owner.id,ids:[layer.id],values:["effect_stack":value]))
      XCTAssertEqual(project,before)
    }
  }
}
