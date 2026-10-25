import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationLayoutTests:XCTestCase {
  private func fixture(height:Double=40,grid:Bool=false)->ResolvedTextStory {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:70,height:height,text:(1...15).map{"Step \($0): Inspect the materials and record the dimensions before careful assembly."}.joined(separator:"\n"),color:"#24353D",fontSize:13)
    e.typography=Typography();e.typography!.fontName="Georgia";e.typography!.kerningMode="metrics";e.typography!.alignToBaselineGrid=grid
    let frames=(0..<4).map{_ in StoryFrameID(objectID:UUID(),elementID:UUID())}
    let story=TextStory(source:e,frames:frames)
    return .init(story:story,frames:frames.enumerated().map{.init(frame:$0.element,width:$0.offset%2==0 ? 66:72,height:height,pageY:$0.offset<2 ? 30:42)},baselineGrid:grid ? .init(spacing:18,origin:6):nil,language:"en")
  }
  private func resolvedElement(_ context:ResolvedTextStory,index:Int)->ArtworkElement {
    let geometry=context.frames[index]
    var e=ArtworkElement(kind:"text",x:0,y:0,width:geometry.width,height:geometry.height)
    e.id=geometry.frame.elementID;e.storyFrame = .init(storyID:context.story.id);e.storyFrame!.resolved=context;e.storyFrame!.frame=geometry.frame;return e
  }
  func testOneLayoutConsumesContiguousGlobalSourceRangesAndKeepsRealOverset() throws {
    let context=fixture(),value=StoryComposition(context)
    var end=0
    for index in value.containers.indices {
      let range=value.sourceRange(index);XCTAssertEqual(range.location,end);end=NSMaxRange(range)
      XCTAssertTrue(value.containers[index].layoutManager === value.layout)
    }
    XCTAssertEqual(value.oversetRange.location,end);XCTAssertGreaterThan(value.oversetRange.length,0)
    XCTAssertEqual(NSMaxRange(value.oversetRange),context.story.text.utf16.count)
    XCTAssertEqual(TextCase.source(value.storage).text.string,context.story.text)
    let later=resolvedElement(context,index:1)
    XCTAssertFalse(try TypographyEngine.outlines(later).isEmpty)
    XCTAssertTrue(TypographyEngine.requiresComposedOutlines(later))
  }
  func testGridBaselinesAndEveryCommittedLineFitEvenVeryShortFrames() throws {
    for height in [7.0,9.0,13.0,35.0,70.0] {
      var context=fixture(height:height,grid:true)
      var large=context.story.typography!;large.leading=0
      context.story.textRuns=[.init(location:0,length:40,typography:large,fontSize:24,color:context.story.color)]
      let value=StoryComposition(context),grid=context.baselineGrid!
      for index in value.containers.indices {
        let box=value.containers[index]
        value.layout.enumerateLineFragments(forGlyphRange:value.glyphRange(index)) {rect,_,_,range,_ in
          XCTAssertLessThanOrEqual(rect.maxY,box.size.height+1e-7)
          let baseline=context.frames[index].pageY+value.topOffsets[index]+rect.minY+value.layout.location(forGlyphAt:range.location).y
          let quotient=(baseline-grid.origin)/grid.spacing
          XCTAssertEqual(quotient,quotient.rounded(),accuracy:1e-7)
        }
      }
      XCTAssertEqual(TextCase.source(value.storage).text.string,context.story.text)
    }
  }
  func testResizeAndFrameOrderReflowWithoutDuplicatingSourceAndUseBoundedCache() throws {
    var context=fixture(height:55)
    let initial=PublicationStoryLayout.composition(context),oldRanges=initial.containers.indices.map{initial.sourceRange($0)}
    XCTAssertTrue(initial === PublicationStoryLayout.composition(context))
    context.frames[0].width=35
    let changed=PublicationStoryLayout.composition(context)
    XCTAssertFalse(initial === changed);XCTAssertNotEqual(oldRanges,changed.containers.indices.map{changed.sourceRange($0)})
    XCTAssertEqual(TextCase.source(changed.storage).text.string,context.story.text)
    context.frames.swapAt(1,2)
    let reordered=PublicationStoryLayout.composition(context)
    XCTAssertFalse(changed === reordered);XCTAssertEqual(TextCase.source(reordered.storage).text.string,context.story.text)
    XCTAssertEqual(PublicationStoryLayout.diagnostics["story_layout_cache_limit"] as? Int,64)
  }
  func testLocaleCaseListsAndRichSourceRemainGlobalAcrossFramesAndOutlines() throws {
    var context=fixture(height:45)
    context.story.text="straße I\u{301}\nPrepare materials\nInspect the finish\n"+context.story.text
    context.story.typography!.caseTreatment="uppercase";context.story.typography!.language="lt"
    try ParagraphLists.edit(&context.story.listItems,text:context.story.text,marker:.decimal)
    let value=StoryComposition(context),mapping=TextCase.source(value.storage)
    XCTAssertEqual(mapping.text.string,context.story.text)
    XCTAssertEqual(PublicationLists.items(from:mapping.text),context.story.listItems)
    XCTAssertEqual(value.storage.string,context.story.text.uppercased(with:Locale(identifier:"lt")))
    for i in value.containers.indices {
      let e=resolvedElement(context,index:i)
      let paths=try TypographyEngine.outlinePaintRuns(e)
      if value.glyphRange(i).length>0 {XCTAssertFalse(paths.isEmpty)}
    }
    XCTAssertEqual(context.story.text,"straße I\u{301}\nPrepare materials\nInspect the finish\n"+fixture(height:45).story.text)
  }
  func testGridDerivedLeadingDoesNotBecomeAStoredTypographyOverride() throws {
    let context=fixture(height:55,grid:true),value=StoryComposition(context)
    let source=TextCase.source(value.storage).text
    let spans=TypographyEngine.spans(from:source,fallback:context.story.typography!)
    XCTAssertTrue(spans.allSatisfy{$0.typography.leading==0 && $0.typography.alignToBaselineGrid==true})
    XCTAssertTrue(spans.allSatisfy{$0.typography.inheritedLanguage==nil})
  }
}
