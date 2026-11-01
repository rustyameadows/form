import XCTest
@testable import FormCore

final class ArtworkPaintStackEditingTests: XCTestCase {
  private func fixture(_ elements:[ArtworkElement])throws->(Project,UUID) {
    var project=Project(name:"Native paints");let owner=try project.ensureCanvasWorkspace()
    project.objects[0].artwork!.elements=elements;return (project,owner.id)
  }
  private func encoded(_ stack:[ArtworkPaintLayer])throws->Any {
    try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(stack))
  }
  private func fill(_ color:String)->ArtworkPaintLayer {.init(.init(color:color))}
  func testBaseTextStackReplacementPreservesRichSpansStylesStoryAndDuplicate()throws {
    var text=ArtworkElement(kind:"text",x:0,y:0,width:40,height:20,text:"Rich text",fontSize:20)
    text.paintStack=[fill("#FF0000")]
    var span=TextSpan(location:0,length:4,typography:.init(),fontSize:22,color:"#0000FF");span.paintStack=[fill("#0000FF")]
    text.textRuns=[span];text.effectStack = .init(effects:[.init(kind:"drop-shadow",blur:1)])
    var (project,owner)=try fixture([text])
    let replacement=[fill("#00FF00"),ArtworkPaintLayer(.init(color:"#111111",opacity:0.6),stroke:.init(width:0.5))]
    try PaintCommands.apply(in:&project,objectID:owner,ids:[text.id],arguments:["paint_stack":try encoded(replacement)])
    let changed=try XCTUnwrap(project.objects[0].artwork?.elements[0])
    XCTAssertEqual(changed.paintStack,replacement);XCTAssertEqual(changed.textRuns,text.textRuns);XCTAssertEqual(changed.effectStack,text.effectStack)
    let style=ArtworkTextStyle(name:"Headline",fontSize:30)
    let styled=TextStyleCommands.applying(TextStyleCommands.span(changed),style:style)
    XCTAssertEqual(styled.paintStack,replacement);XCTAssertEqual(styled.fontSize,30)
    var story=TextStory(source:changed),source=story.sourceElement;source.fontSize=35;story.setSource(source)
    XCTAssertEqual(story.sourceElement.paintStack,replacement);XCTAssertEqual(story.sourceElement.textRuns,text.textRuns)
    var artwork=project.objects[0].artwork!
    let ids=try ArtworkCommands.apply("duplicate",to:&artwork,ids:[text.id])
    let copy=try XCTUnwrap(artwork.elements.first{ids.contains($0.id)})
    XCTAssertEqual(copy.paintStack,replacement);XCTAssertEqual(copy.textRuns,text.textRuns);XCTAssertEqual(copy.effectStack,text.effectStack)
    XCTAssertGreaterThanOrEqual(project.minimumSchemaVersion,58)
  }
  func testInvalidOrInvisibleLegacyStackEditsAreAtomicAndExplicitResetRestoresLegacy()throws {
    var shape=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:20);shape.paintStack=[fill("#FF0000")]
    var (project,owner)=try fixture([shape]);let before=project
    var invalid=fill("#000000");invalid.paint.opacity=2
    for args:[String:Any] in [["stroke":["width":4]],["gradient":["kind":"radial"]],
      ["paint_stack":try encoded([invalid])],["paint_stack":try encoded(Array(repeating:fill("#000000"),count:17))],
      ["paint_stack":try encoded([fill("#000000")]),"stroke":["width":2]]] {
      XCTAssertThrowsError(try PaintCommands.apply(in:&project,objectID:owner,ids:[shape.id],arguments:args))
      XCTAssertEqual(project,before)
    }
    try PaintCommands.apply(in:&project,objectID:owner,ids:[shape.id],arguments:["paint_stack":[]])
    XCTAssertEqual(project.objects[0].artwork?.elements[0].paintStack,[])
    try PaintCommands.apply(in:&project,objectID:owner,ids:[shape.id],arguments:["paint_stack":NSNull()])
    XCTAssertNil(project.objects[0].artwork?.elements[0].paintStack)
    try PaintCommands.apply(in:&project,objectID:owner,ids:[shape.id],arguments:["stroke":["width":2]])
    XCTAssertEqual(project.objects[0].artwork?.elements[0].stroke?.width,2)
  }
  func testCoverageMaskPaintIsEditableButOutlineOnlyMaskPaintRemainsProtected()throws {
    let mask=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:20)
    var target=mask;target.id=UUID();target.clipID=mask.id;target.clipMode="alpha"
    var (project,owner)=try fixture([mask,target])
    try PaintCommands.apply(in:&project,objectID:owner,ids:[mask.id],arguments:["gradient":["kind":"radial"]])
    XCTAssertEqual(project.objects[0].artwork?.elements[0].gradient?.kind,"radial")
    try PaintCommands.apply(in:&project,objectID:owner,ids:[mask.id],arguments:["paint_stack":try encoded([fill("#FFFFFF")])])
    project.objects[0].artwork!.elements[1].clipMode=nil
    let before=project
    XCTAssertThrowsError(try PaintCommands.apply(in:&project,objectID:owner,ids:[mask.id],arguments:["paint_stack":try encoded([fill("#000000")])]))
    XCTAssertEqual(project,before)
  }
  func testExplicitStackEditDetachesOldFillBindingThenNamedSwatchRecolorsEffectivePaint()throws {
    var shape=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:20)
    let swatch=ArtworkSwatch(name:"Brand",color:"#0000FF");shape.fillSwatchID=swatch.id;shape.paintStack=[fill("#0000FF")]
    var (project,owner)=try fixture([shape]);project.swatches=[swatch]
    try PaintCommands.apply(in:&project,objectID:owner,ids:[shape.id],arguments:["paint_stack":try encoded([fill("#FF0000")])])
    XCTAssertNil(project.objects[0].artwork?.elements[0].fillSwatchID)
    let visible=project.resolvingSwatches(in:project.objects[0].artwork!).elements[0]
    XCTAssertEqual(visible.paintStack?.first?.paint.color,"#FF0000")
    try SwatchCommands.assign(in:&project,objectID:owner,ids:[shape.id],target:"fill",swatchID:swatch.id)
    XCTAssertEqual(project.objects[0].artwork?.elements[0].paintStack?.first?.paint.color,"#0000FF")
  }
}
