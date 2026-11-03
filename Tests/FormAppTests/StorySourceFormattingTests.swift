import AppKit
import CoreText
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class StorySourceFormattingTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,window:NSWindow,canvas:VectorCanvasView
    let storyID:UUID
    var editor:PublicationEditingController {canvas.storyEditor!}
    var text:CanvasTextView {canvas.activeStoryView!}
    init(words:String="Georgia Helvetica 👩🏽‍💻 straße",mixed:Bool=true,face:String="Georgia",uppercase:Bool=false,variations:[Int:Double]=[:])throws {
      _=NSApplication.shared
      root=FileManager.default.temporaryDirectory.appendingPathComponent("story-format-"+UUID().uuidString)
      let repository=try ProjectRepository(root:root)
      var project=Project(name:"Native story format"),frames:[StoryFrameID]=[]
      let ink=ArtworkSwatch(name:"Retained story ink",color:"#234B61");project.swatches=[ink]
      for index in 0..<2 {
        var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":160,"depth":210])
        var source=ArtworkElement(kind:"text",x:14,y:20,width:130,height:170,text:index==0 ? words:"",fontSize:14)
        var type=Typography();type.fontName=face;type.tracking=0.2;type.caseTreatment=uppercase ? "uppercase":"original"
        type.variations=variations;source.typography=type;source.fillSwatchID=ink.id
        if index==0,mixed {
          var second=type;second.fontName="Helvetica"
          source.textRuns=[.init(location:0,length:8,typography:type,fontSize:14,color:source.color),
            .init(location:8,length:9,typography:second,fontSize:18,color:source.color),
            .init(location:17,length:words.utf16.count-17,typography:type,fontSize:14,color:source.color)]
          for index in source.textRuns!.indices {source.textRuns![index].swatchID=ink.id}
        }
        page.artwork = .init(elements:[source],bleed:0);project.objects.append(page)
        frames.append(.init(objectID:page.id,elementID:source.id))
      }
      let publication=try PublicationCommands.createPublication(in:&project,name:"Formatting source",pages:project.objects.map(\.id))
      storyID=try PublicationCommands.createStory(in:&project,frames:frames,publicationID:publication)
      try repository.save(project)
      store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id)
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1000,height:800),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      canvas=VectorCanvasView(frame:window.contentView!.bounds)
      canvas.session=store.artworkSession;store.artworkSession.canvas=canvas;window.contentView=canvas
      store.artworkSession.activate(frames[0].objectID);store.artworkSession.choose([frames[0].elementID]);canvas.synchronize()
      canvas.beginText(try XCTUnwrap(store.project?.storyFrame(frames[0])?.element))
      editor.nativeUndo.groupsByEvent=false
    }
    func close(){canvas.finishText();window.contentView=nil;window.close();try? FileManager.default.removeItem(at:root)}
    func source()throws->TextStory {try XCTUnwrap(store.project?.textStories?.first{$0.id==storyID})}
    func spans()throws->[TextSpan] {TypographyEngine.spans(from:TypographyEngine.sourceAttributed(try source().sourceElement),fallback:.init())}
  }
  private func span(at position:Int,in spans:[TextSpan])throws->TextSpan {
    try XCTUnwrap(spans.first{$0.location<=position && position<$0.location+$0.length})
  }
  private func assertNativeSource(_ actual:Project?,equals expected:Project,file:StaticString=#filePath,line:UInt=#line) {
    // Native Undo republishes source within the still-open editing interaction.
    // Its one history event/time disappear only when that interaction finishes.
    var value=actual;value?.history=expected.history;value?.updatedAt=expected.updatedAt
    value?.schemaVersion=expected.schemaVersion
    XCTAssertEqual(value,expected,file:file,line:line)
  }
  func testMixedFamiliesUseRealBoldItalicFacesKeepRichMetadataAndUndoExactly()throws {
    let f=try Fixture();defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project),source=try f.source()
    let selected=(f.text.string as NSString).range(of:"Georgia Helvetica")
    f.text.setSelectedRange(selected)
    let typing=f.text.typingAttributes as NSDictionary
    XCTAssertEqual(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text),.init(available:true,isOn:false,isMixed:false))
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    XCTAssertTrue(StorySourceFormatting.apply(.italic,editor:f.editor,text:f.text))
    XCTAssertTrue(StorySourceFormatting.apply(.underline,editor:f.editor,text:f.text))
    XCTAssertEqual(f.text.selectedRange(),selected)
    XCTAssertTrue(typing.isEqual(to:f.text.typingAttributes))
    let spans=try f.spans(),georgia=try span(at:0,in:spans),helvetica=try span(at:8,in:spans),tail=try span(at:18,in:spans)
    XCTAssertEqual(georgia.typography.fontName,"Georgia-BoldItalic")
    XCTAssertEqual(helvetica.typography.fontName,"Helvetica-BoldOblique")
    XCTAssertEqual(georgia.fontSize,14);XCTAssertEqual(helvetica.fontSize,18)
    XCTAssertTrue(georgia.typography.underline);XCTAssertTrue(helvetica.typography.underline)
    XCTAssertFalse(tail.typography.underline);XCTAssertEqual(tail.typography.fontName,"Georgia")
    XCTAssertTrue(spans.allSatisfy{$0.swatchID==source.fillSwatchID && $0.typography.tracking==0.2})
    XCTAssertEqual(try f.source().text,source.text);XCTAssertEqual(f.store.project?.objects,baseline.objects)
    for _ in 0..<3 {f.editor.nativeUndo.undo()}
    assertNativeSource(f.store.project,equals:baseline)
    for _ in 0..<3 {f.editor.nativeUndo.redo()}
    let formatted=try XCTUnwrap(f.store.project)
    f.canvas.finishText();try f.store.engine.flush()
    let reopened=try f.store.repository.load(formatted.id)
    XCTAssertEqual(reopened.textStories,formatted.textStories);XCTAssertEqual(reopened.objects,baseline.objects)
    f.store.engine.undo();XCTAssertEqual(f.store.project,baseline)
  }
  func testMixedSelectionTurnsOnThenOffWithoutFlatteningFaces()throws {
    let f=try Fixture();defer{f.close()}
    let first=(f.text.string as NSString).range(of:"Georgia")
    f.text.setSelectedRange(first)
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    f.text.setSelectedRange((f.text.string as NSString).range(of:"Georgia Helvetica"))
    XCTAssertEqual(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text),.init(available:true,isOn:false,isMixed:true))
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    XCTAssertTrue(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text).isOn)
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    let spans=try f.spans()
    XCTAssertEqual(try span(at:0,in:spans).typography.fontName,"Georgia")
    XCTAssertEqual(try span(at:8,in:spans).typography.fontName,"Helvetica")
  }
  func testCaretIntentHasNativeUndoAndOnlyFormatsNewWords()throws {
    let f=try Fixture(words:"Careful source",mixed:false);defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project)
    f.text.setSelectedRange(.init(location:f.text.string.utf16.count,length:0))
    let typing=f.text.typingAttributes as NSDictionary,selection=f.text.selectedRange()
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    XCTAssertEqual(f.store.project,baseline);XCTAssertEqual(f.text.selectedRange(),selection)
    XCTAssertTrue(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text).isOn)
    f.editor.nativeUndo.undo();XCTAssertTrue(typing.isEqual(to:f.text.typingAttributes))
    f.editor.nativeUndo.redo();XCTAssertTrue(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text).isOn)
    f.text.insertText(" NEW",replacementRange:.init(location:NSNotFound,length:0))
    XCTAssertEqual(try f.source().text,"Careful source NEW")
    XCTAssertEqual(try span(at:0,in:f.spans()).typography.fontName,"Georgia")
    XCTAssertEqual(try span(at:15,in:f.spans()).typography.fontName,"Georgia-Bold")
    f.editor.nativeUndo.undo();XCTAssertEqual(try f.source().text,"Careful source")
  }
  func testCaseExpansionAndEmojiKeepOriginalWordsAndGlobalSourceSelection()throws {
    let f=try Fixture(words:"straße 👩🏽‍💻 tail",mixed:false,uppercase:true);defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project),source=try f.source().text
    XCTAssertTrue(f.text.string.hasPrefix("STRASSE"))
    let selected=(f.text.string as NSString).range(of:"SS")
    f.text.setSelectedRange(selected)
    let range=TextCase.source(f.text.attributedString()).sourceRange(selected)
    XCTAssertEqual((source as NSString).substring(with:range),"ß")
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    XCTAssertEqual(try f.source().text,source)
    XCTAssertEqual(TextCase.source(f.text.attributedString()).sourceRange(f.text.selectedRange()),range)
    f.text.setSelectedRange((f.text.string as NSString).range(of:"👩🏽‍💻"))
    let emoji=TextCase.source(f.text.attributedString()).sourceRange(f.text.selectedRange())
    XCTAssertTrue(StorySourceFormatting.apply(.italic,editor:f.editor,text:f.text))
    XCTAssertEqual(try f.source().text,source)
    XCTAssertEqual(try span(at:emoji.location,in:f.spans()).typography.fontName,"Georgia-Italic","Glyph coverage fallback must not replace the authored family with Apple Color Emoji.")
    f.editor.nativeUndo.undo();f.editor.nativeUndo.undo();assertNativeSource(f.store.project,equals:baseline)
    f.canvas.finishText();XCTAssertEqual(f.store.project,baseline)
  }
  func testUnavailableTraitMarkedInputAndStaleImportedProjectRejectWithoutMutation()throws {
    let f=try Fixture(words:"Unchanged source",mixed:false,face:"Zapfino");defer{f.close()}
    XCTAssertNotNil(NSFont(name:"Zapfino",size:14))
    f.text.setSelectedRange(.init(location:0,length:f.text.string.utf16.count))
    let baseline=try XCTUnwrap(f.store.project),native=NSAttributedString(attributedString:f.text.attributedString())
    XCTAssertFalse(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text).available)
    XCTAssertFalse(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    XCTAssertTrue(GlyphEngine.nativeEqual(f.text.attributedString(),native));XCTAssertEqual(f.store.project,baseline)
    f.editor.nativeUndo.beginUndoGrouping()
    f.text.setMarkedText("に",selectedRange:.init(location:1,length:0),replacementRange:.init(location:0,length:0))
    let marked=NSAttributedString(attributedString:f.text.attributedString())
    XCTAssertFalse(StorySourceFormatting.state(.underline,editor:f.editor,text:f.text).available)
    XCTAssertFalse(StorySourceFormatting.apply(.underline,editor:f.editor,text:f.text))
    XCTAssertTrue(f.text.hasMarkedText());XCTAssertTrue(GlyphEngine.nativeEqual(f.text.attributedString(),marked))
    f.text.unmarkText();f.text.didChangeText();f.editor.nativeUndo.endUndoGrouping()
    let editor=f.editor,text=f.text
    var imported=try XCTUnwrap(f.store.project);imported.id=UUID();f.store.engine.project=imported
    XCTAssertFalse(StorySourceFormatting.state(.underline,editor:editor,text:text).available)
    XCTAssertFalse(StorySourceFormatting.apply(.underline,editor:editor,text:text))
    XCTAssertEqual(f.store.project,imported)
    f.store.engine.project=baseline
  }
  func testVariableWeightUsesEffectiveTraitsAndNeverLeavesAContradictoryWeightOverride()throws {
    let weight=0x77676874
    let names=[NSFont.systemFont(ofSize:14).fontName,".SFNS-Regular","SFPro-Regular","Skia"]
    let candidate=names.compactMap{name->(String,[[String:Any]])? in
      guard let font=NSFont(name:name,size:14),let axes=CTFontCopyVariationAxes(font as CTFont) as? [[String:Any]],
        axes.contains(where:{($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue==weight}) else{return nil}
      return(name,axes)
    }.first
    guard let (face,axes)=candidate else{throw XCTSkip("No installed SF/Skia variable weight font is available.")}
    let weightAxis=try XCTUnwrap(axes.first{($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue==weight})
    let maximum=try XCTUnwrap(weightAxis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber).doubleValue
    var variations=[weight:maximum]
    for axis in axes {
      if let id=axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,id.intValue != weight,
        let value=axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber {variations[id.intValue]=value.doubleValue}
    }
    let f=try Fixture(words:"Variable source",mixed:false,face:face,variations:variations);defer{f.close()}
    f.text.setSelectedRange(.init(location:0,length:f.text.string.utf16.count))
    let baseline=try XCTUnwrap(f.store.project),before=try span(at:0,in:f.spans())
    let actualBefore=TypographyEngine.font(before.typography,size:before.fontSize)
    let wasBold=NSFontManager.shared.traits(of:actualBefore).contains(.boldFontMask)
    let state=StorySourceFormatting.state(.bold,editor:f.editor,text:f.text)
    XCTAssertEqual(state.isOn,wasBold,"Selected state must follow the effective variable coordinates, not the default named face.")
    XCTAssertTrue(state.available,"The installed variable weight face should support an honest trait conversion.")
    XCTAssertTrue(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    let after=try span(at:0,in:f.spans()),actualAfter=TypographyEngine.font(after.typography,size:after.fontSize)
    XCTAssertEqual(actualAfter.familyName,actualBefore.familyName)
    XCTAssertEqual(NSFontManager.shared.traits(of:actualAfter).contains(.boldFontMask),!wasBold)
    XCTAssertEqual(after.typography.variations.filter{$0.key != weight},before.typography.variations.filter{$0.key != weight})
    XCTAssertEqual(after.typography.features,before.typography.features)
    XCTAssertEqual(after.typography.opticalSizing,before.typography.opticalSizing)
    XCTAssertEqual(try f.source().text,"Variable source")
    f.editor.nativeUndo.undo();assertNativeSource(f.store.project,equals:baseline)
    f.canvas.finishText();XCTAssertEqual(f.store.project,baseline)
  }
  func testCanonicallyEquivalentReplacementWithDifferentUTF16RejectsStaleNativeFormatting()throws {
    let f=try Fixture(words:"Caf\u{00E9} source",mixed:false);defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project),native=NSAttributedString(attributedString:f.text.attributedString())
    let undo=f.store.engine.undoStack.count
    var replaced=baseline
    replaced.textStories![0].text="Cafe\u{0301} source"
    XCTAssertEqual(replaced.textStories![0].text,baseline.textStories![0].text,"Swift equality intentionally treats NFC and NFD as equivalent.")
    XCTAssertNotEqual(Array(replaced.textStories![0].text.utf16),Array(baseline.textStories![0].text.utf16))
    f.store.engine.project=replaced
    f.text.setSelectedRange(.init(location:3,length:1))
    let typing=f.text.typingAttributes as NSDictionary,selection=f.text.selectedRange()
    XCTAssertFalse(StorySourceFormatting.state(.bold,editor:f.editor,text:f.text).available)
    XCTAssertFalse(StorySourceFormatting.apply(.bold,editor:f.editor,text:f.text))
    XCTAssertEqual(Array(try f.source().text.utf16),Array(replaced.textStories![0].text.utf16))
    XCTAssertEqual(Array(f.text.string.utf16),Array(native.string.utf16))
    XCTAssertTrue(GlyphEngine.nativeEqual(f.text.attributedString(),native))
    XCTAssertTrue(typing.isEqual(to:f.text.typingAttributes));XCTAssertEqual(f.text.selectedRange(),selection)
    XCTAssertEqual(f.store.engine.undoStack.count,undo);XCTAssertEqual(f.store.project?.history,replaced.history)
    f.store.engine.project=baseline
  }
}
