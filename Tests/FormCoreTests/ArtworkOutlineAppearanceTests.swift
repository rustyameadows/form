import FormCore
import FormGraphics
import XCTest

@MainActor final class ArtworkOutlineAppearanceTests:XCTestCase {
  private var effects:ArtworkEffectStack {.init(effects:[.init(kind:"drop-shadow",offset:.init(2,3),blur:0.5,opacity:0.4)])}
  func testRichTextOutlineKeepsCoverageAndEffectsOnOneWrapper()throws {
    var mask=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100,color:"#FFFFFF");mask.opacity=0.5
    var text=ArtworkElement(kind:"text",x:10,y:12,width:80,height:35,text:"ABCD",fontSize:24)
    text.paintStack=[.init(.init(color:"#BB0000"))]
    text.textRuns=[.init(location:2,length:2,typography:.init(),fontSize:24,color:"#0000BB")]
    text.textRuns![0].paintStack=[.init(.init(color:"#0000BB"))]
    text.clipID=mask.id;text.clipMode="alpha";text.effectStack=effects;text.opacity=0.7;text.isolatedBlending=true
    let result=try ArtworkOutlines.convert(.init(elements:[mask,text]),ids:[text.id],mode:"text")
    let root=try XCTUnwrap(result.created.first)
    XCTAssertEqual(root.kind,"group");XCTAssertEqual(root.clipID,mask.id);XCTAssertEqual(root.clipMode,"alpha")
    XCTAssertEqual(root.effectStack,effects);XCTAssertEqual(root.opacity,0.7);XCTAssertEqual(root.isolatedBlending,true)
    let descendants=result.created.filter{$0.parentID==root.id}
    XCTAssertGreaterThan(descendants.count,1)
    XCTAssertTrue(descendants.allSatisfy{$0.effectStack==nil && $0.clipID==nil && $0.clipMode==nil})
    try validateArtwork(result.artwork)
  }
  func testExpandedStrokeClearsInnerCopiesOfCoverageAndEffects()throws {
    let mask=ArtworkElement(kind:"rectangle",x:0,y:0,width:60,height:60,color:"#FFFFFF")
    var shape=ArtworkElement(kind:"rectangle",x:5,y:6,width:40,height:30,color:"#CC2200")
    shape.stroke = .init(color:"#0033CC",width:3)
    shape.clipID=mask.id;shape.clipMode="luminance";shape.effectStack=effects
    let result=try ArtworkOutlines.convert(.init(elements:[mask,shape]),ids:[shape.id],mode:"stroke")
    let root=try XCTUnwrap(result.created.first)
    XCTAssertEqual(root.clipMode,"luminance");XCTAssertEqual(root.effectStack,effects)
    let children=result.created.filter{$0.parentID==root.id}
    XCTAssertEqual(children.count,2)
    XCTAssertTrue(children.allSatisfy{$0.effectStack==nil && $0.clipMode==nil && $0.clipID==nil})
  }
  func testOutliningEditableTextMaskRepointsCoverageToEntireNewGlyphGroup()throws {
    var text=ArtworkElement(kind:"text",x:0,y:0,width:100,height:40,text:"AB",fontSize:24)
    text.textRuns=[.init(location:0,length:1,typography:.init(),fontSize:24,color:"#FFFFFF"),
      .init(location:1,length:1,typography:.init(),fontSize:24,color:"#777777")]
    var content=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:40,color:"#CC2200")
    content.clipID=text.id;content.clipMode="alpha"
    let result=try ArtworkOutlines.convert(.init(elements:[text,content]),ids:[text.id],mode:"text")
    let root=try XCTUnwrap(result.created.first),updated=try XCTUnwrap(result.artwork.elements.first{$0.id==content.id})
    XCTAssertEqual(root.kind,"group");XCTAssertEqual(updated.clipID,root.id);XCTAssertEqual(updated.clipMode,"alpha")
    XCTAssertGreaterThan(result.created.filter{$0.parentID==root.id}.count,1)
    XCTAssertEqual(result.artwork.elements.first{$0.id==text.id}?.hidden,true)
    try validateArtwork(result.artwork)
  }
}
