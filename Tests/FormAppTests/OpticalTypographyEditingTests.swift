import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

private struct NativeTrackingField:View {
  @ObservedObject var session:ArtworkSession
  var enabled=true
  var body:some View {
    ScalarArtworkField("Tracking",value:session.inspectedTypography.tracking,unit:"pt",increment:enabled ? session.numericIncrement(step:0.1):nil) {value in session.typography{$0.tracking=value}}
      .padding(20).frame(width:250,height:100)
  }
}
@MainActor final class OpticalTypographyEditingTests:XCTestCase {
  private func fixture(inline:Bool=false,enabled:Bool=true)throws->(StudioStore,ProductObject,NSWindow,VectorCanvasView,NSView,NSTextView) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false);store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var p=Project(name:"Optical native interactions"),o=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":110])
    var e=ArtworkElement(kind:"text",x:10,y:10,width:150,height:70,text:"Optical office",color:"#203A4A",fontSize:36)
    var type=Typography();type.fontName=".AppleSystemUIFont";type.opticalSizing = .init(.automatic);type.tracking=0.123456789;type.variations=[OpticalSizing.axisID:72];type.caseTreatment="uppercase";type.kerningMode="metrics";e.typography=type
    var a=Artwork(elements:[e]);a.backgroundOpacity=0;o.artwork=a;p.objects=[o];p.schemaVersion=p.minimumSchemaVersion;store.engine.project=p;try store.engine.flush();store.mode = .artwork
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:980,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let content=NSView(frame:.init(x:0,y:0,width:980,height:700)),canvas=VectorCanvasView(frame:.init(x:0,y:0,width:700,height:700)),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=o.id;session.choose([e.id]);content.addSubview(canvas);window.contentView=content;canvas.synchronize()
    if inline {canvas.beginText(e);let text=try XCTUnwrap(window.firstResponder as? CanvasTextView);text.undoManager?.groupsByEvent=false;text.setSelectedRange(.init(location:0,length:7))}
    let host=NSHostingView(rootView:NativeTrackingField(session:session,enabled:enabled));host.frame = .init(x:710,y:300,width:250,height:100);content.addSubview(host)
    window.setFrameOrigin(.init(x:-10000,y:-10000));window.orderBack(nil);content.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.07));host.layoutSubtreeIfNeeded()
    let field=try XCTUnwrap(fields(host).first{$0.isEditable});window.makeFirstResponder(field)
    let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    addTeardownBlock {MainActor.assumeIsolated {window.makeFirstResponder(nil);canvas.finishText();window.close()}}
    return(store,o,window,canvas,host,editor)
  }
  private func canvasEditors(_ view:NSView)->[CanvasTextView] {([view as? CanvasTextView].compactMap{$0})+view.subviews.flatMap{canvasEditors($0)}}
  private func fields(_ view:NSView)->[NSTextField] {([view as? NSTextField].compactMap{$0})+view.subviews.flatMap{fields($0)}}
  private func event(_ editor:NSTextView,_ window:NSWindow,code:UInt16,up:Bool=false,shift:Bool=false,command:Bool=false,repeatKey:Bool=false)throws {
    var mods=NSEvent.ModifierFlags();if shift{mods.insert(.shift)};if command{mods.insert(.command)}
    let char=code==126 ? "\u{f700}":code==125 ? "\u{f701}":"z"
    let value=try XCTUnwrap(NSEvent.keyEvent(with:up ? .keyUp:.keyDown,location:.zero,modifierFlags:mods,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:char,charactersIgnoringModifiers:char,isARepeat:repeatKey,keyCode:code))
    if up {editor.keyUp(with:value)}else{editor.keyDown(with:value)}
    RunLoop.main.run(until:Date().addingTimeInterval(0.025))
  }
  private func tracking(_ store:StudioStore)->Double {store.project!.objects[0].artwork!.elements[0].typography!.tracking}
  func testActualFocusedUpDownRepeatShiftAndUndoPreserveExactUnderlyingPrecision()throws {
    let(store,_,window,_,host,editor)=try fixture();XCTAssertTrue(editor is NumericArtworkFieldEditor)
    let baseline=store.project!,initial=tracking(store)
    try event(editor,window,code:126);try event(editor,window,code:126,repeatKey:true);try event(editor,window,code:126,repeatKey:true);try event(editor,window,code:126,up:true)
    XCTAssertEqual(tracking(store),initial+0.3,accuracy:1e-12);XCTAssertEqual(store.engine.undoStack.count,1)
    let firstHold=store.project!
    try event(editor,window,code:125,shift:true);try event(editor,window,code:125,up:true,shift:true)
    XCTAssertEqual(tracking(store),initial+0.3-1,accuracy:1e-12);XCTAssertEqual(store.engine.undoStack.count,2)
    try event(editor,window,code:6,command:true);XCTAssertEqual(store.project,firstHold)
    try event(editor,window,code:6,command:true);XCTAssertEqual(store.project,baseline)
    XCTAssertEqual(Double(try XCTUnwrap(fields(host).first).stringValue)!,initial,accuracy:1e-12)
    try event(editor,window,code:6,shift:true,command:true);XCTAssertEqual(store.project,firstHold)
    XCTAssertEqual(store.project!.camera,baseline.camera);XCTAssertEqual(store.project!.objects[0].position,baseline.objects[0].position)
  }
  func testNumericInvalidDraftMarkedInputAndUnconfiguredFieldsDoNotChangeDocument()throws {
    let(store,_,window,_,host,editor)=try fixture(),baseline=store.project!
    for value in ["nan","", "10001"] {
      editor.selectAll(nil);editor.insertText(value,replacementRange:.init(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.02))
      try event(editor,window,code:126);try event(editor,window,code:126,up:true)
      XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(editor.string,value)
    }
    editor.selectAll(nil);editor.setMarkedText("9",selectedRange:.init(location:1,length:0),replacementRange:.init(location:NSNotFound,length:0));XCTAssertTrue(editor.hasMarkedText())
    try event(editor,window,code:126);try event(editor,window,code:126,up:true);XCTAssertEqual(store.project,baseline);editor.unmarkText()
    XCTAssertTrue(fields(host).first is NumericArtworkTextField)
    let(other,_,otherWindow,_,_,ordinary)=try fixture(enabled:false),unchanged=other.project!
    XCTAssertFalse(ordinary is NumericArtworkFieldEditor);try event(ordinary,otherWindow,code:126);try event(ordinary,otherWindow,code:125)
    XCTAssertEqual(other.project,unchanged);XCTAssertTrue(other.engine.undoStack.isEmpty)
  }
  func testLateKeyRepeatKeyUpAndUndoCannotEditOrEndNewProjectInteraction()throws {
    let(store,_,window,_,_,editor)=try fixture();try event(editor,window,code:126)
    let newer=Project(name:"Different source");try store.repository.save(newer);try store.engine.open(newer.id);let baseline=store.project!
    try event(editor,window,code:126,repeatKey:true);try event(editor,window,code:126,up:true);try event(editor,window,code:6,command:true)
    XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testActualNativeCharacterIncrementGroupsUndoWithoutChangingWordsOrOpticalMetadata()throws {
    let(store,object,window,canvas,_,editor)=try fixture(inline:true),baseline=store.project!,e=baseline.objects[0].artwork!.elements[0]
    try event(editor,window,code:126);try event(editor,window,code:126,repeatKey:true);try event(editor,window,code:126,up:true)
    let changed=store.project!.objects[0].artwork!.elements[0],runs=try XCTUnwrap(changed.textRuns)
    XCTAssertEqual(changed.text,e.text);XCTAssertEqual(changed.typography,e.typography)
    XCTAssertEqual(runs.first?.length,7);XCTAssertEqual(runs.first!.typography.tracking,e.typography!.tracking+0.2,accuracy:1e-12)
    XCTAssertTrue(runs.allSatisfy{$0.typography.opticalSizing==e.typography!.opticalSizing && $0.typography.variations==e.typography!.variations && $0.typography.caseTreatment==e.typography!.caseTreatment})
    try event(editor,window,code:6,command:true);canvas.finishText();XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.project!.objects[0].id,object.id)
  }
  func testNativeOpticalSelectionAndPackagedEquivalentAreUndoableAndRejectBeforeDraftCommit()throws {
    let(store,object,window,canvas,_,_)=try fixture(inline:true),baseline=store.project!
    try store.artworkSession.opticalSizing(.init(.explicit,points:72))
    let changed=store.project!.objects[0].artwork!.elements[0]
    XCTAssertEqual(changed.text,baseline.objects[0].artwork!.elements[0].text)
    XCTAssertEqual(changed.textRuns?.first?.typography.opticalSizing,.init(.explicit,points:72))
    XCTAssertEqual(changed.textRuns?.first?.typography.variations,[OpticalSizing.axisID:72])
    store.undo();canvas.finishText();XCTAssertEqual(store.project,baseline)
    canvas.beginText(baseline.objects[0].artwork!.elements[0]);let native=try XCTUnwrap(window.firstResponder as? CanvasTextView);native.setSelectedRange(.init(location:0,length:7))
    let selected=native.selectedRange(),before=store.project!,count=store.engine.undoStack.count
    XCTAssertThrowsError(try store.engine.call("form_edit_artwork",arguments:["object_id":object.id.uuidString,"element_ids":[changed.id.uuidString],"command":"optical","optical_sizing":["mode":"explicit","points":100.0]]))
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,count);XCTAssertTrue(window.firstResponder === native);XCTAssertEqual(native.selectedRange(),selected)
    canvas.finishText()
    _ = try store.engine.call("form_edit_artwork",arguments:["object_id":object.id.uuidString,"element_ids":[changed.id.uuidString],"command":"optical","optical_sizing":["mode":"none"]])
    XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].typography!.opticalSizing,.init(.none));store.undo();XCTAssertEqual(store.project,before)
  }
  func testNativeTextResizeReevaluatesAutomaticOpticalSizeAndKeepsOtherSourceProperties()throws {
    let(store,_,window,canvas,_,_)=try fixture(inline:true),before=store.project!,e=before.objects[0].artwork!.elements[0]
    store.artworkSession.typeSize(48)
    let changed=store.project!.objects[0].artwork!.elements[0],first=try XCTUnwrap(changed.textRuns?.first)
    XCTAssertEqual(first.fontSize,48);XCTAssertEqual(first.typography.fontName,e.typography!.fontName)
    XCTAssertEqual(first.typography.opticalSizing,.init(.automatic));XCTAssertEqual(first.typography.variations,e.typography!.variations)
    let font=TypographyEngine.sourceAttributed(changed).attribute(.font,at:0,effectiveRange:nil) as! NSFont
    let axes=CTFontCopyVariation(font as CTFont) as! [NSNumber:NSNumber];XCTAssertEqual(axes[NSNumber(value:OpticalSizing.axisID)]?.doubleValue,48)
    XCTAssertEqual(changed.text,e.text);XCTAssertEqual(changed.glyphOverrides,e.glyphOverrides);XCTAssertEqual(changed.listItems,e.listItems)
    store.undo();canvas.finishText();XCTAssertEqual(store.project,before)
    window.makeFirstResponder(nil)
  }

  func testPhysicalOpticalExportsReportTheirOutlineFallbackAndPreserveOriginalSource()throws {
    let(store,object,_,_,_,_)=try fixture();var p=store.project!,elements:[ArtworkElement]=[]
    p.objects[0].parameters["width"]=230;p.objects[0].parameters["depth"]=165
    var header=ArtworkElement(kind:"text",x:12,y:10,width:205,height:18,text:"OPTICAL / size intent",color:"#203A4A",fontSize:26);header.typography = .init();header.typography!.fontName="Georgia";elements.append(header)
    let policies:[OpticalSizing]=[.init(.automatic),.init(.explicit,points:72),.init(.none)]
    for (i,policy) in policies.enumerated() {
      let x=12.0+Double(i)*72
      var label=ArtworkElement(kind:"text",x:x,y:40,width:65,height:10,text:["AUTOMATIC / 32 PT","EXPLICIT / 72 OPSZ","OFF / NO AUTO"][i],color:"#767F83",fontSize:8);label.typography = .init();label.typography!.fontName="Menlo-Regular";elements.append(label)
      var sample=ArtworkElement(kind:"text",x:x,y:55,width:65,height:65,text:"Optical\nAa 0123\nRag & Q",color:i==1 ? "#C7573B":"#203A4A",fontSize:32)
      var type=Typography();type.fontName=".AppleSystemUIFont";type.kerningMode="metrics";type.opticalSizing=policy;type.variations=[OpticalSizing.axisID:19];sample.typography=type;elements.append(sample)
    }
    var note=ArtworkElement(kind:"text",x:12,y:135,width:205,height:15,text:"NOMINAL DOCUMENT POINTS / ZOOM-INDEPENDENT / ORIGINAL SOURCE RETAINED",color:"#767F83",fontSize:8);note.typography = .init();note.typography!.fontName="Menlo-Regular";elements.append(note)
    p.objects[0].artwork = .init(background:"#F6F3EB",elements:elements,bleed:0);store.engine.project=p;try store.engine.flush();let baseline=store.project!
    let output=store.repository.root.appendingPathComponent("Proof");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    for format in ["svg","pdf","png"] {
      let result=try store.exportArtwork(object:store.project!.objects[0],arguments:["object_id":object.id.uuidString,"format":format,"path":output.appendingPathComponent("optical."+format).path,"outline_text":false,"dpi":150]) as! [String:Any]
      if format=="svg" {XCTAssertEqual(result["optical_text_outlined"] as? Int,3);XCTAssertNotNil(result["optical_sizing_fallback"])}
    }
    XCTAssertEqual(store.project,baseline)
    try JSONEncoder.form.encode(baseline).write(to:output.appendingPathComponent("Source.json"))
    var measurements:[[String:Any]]=[]
    for e in elements where e.typography?.opticalSizing != nil {
      let type=e.typography!,point=TypographyEngine.font(type,size:e.fontSize),mm=TypographyEngine.attributes(type,size:e.fontSize,color:e.color,millimeters:true)[.font] as! NSFont
      var character:UniChar=65,pointGlyph:CGGlyph=0,mmGlyph:CGGlyph=0;CTFontGetGlyphsForCharacters(point as CTFont,&character,&pointGlyph,1);CTFontGetGlyphsForCharacters(mm as CTFont,&character,&mmGlyph,1)
      let a=CTFontGetAdvancesForGlyphs(point as CTFont,.horizontal,&pointGlyph,nil,1),b=CTFontGetAdvancesForGlyphs(mm as CTFont,.horizontal,&mmGlyph,nil,1)*TypographyEngine.pointsPerMM
      XCTAssertEqual(a,b,accuracy:1e-10)
      measurements.append(["mode":type.opticalSizing!.mode.rawValue,"nominal_points":e.fontSize,"source_legacy_opsz":type.variations[OpticalSizing.axisID]!,"effective_opsz":OpticalTypography.effectiveCoordinate(type,nominalPoints:e.fontSize)!,"A_advance_points":a,"mm_normalized_A_advance_points":b])
    }
    try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("Metrics.json"))
    if let path=ProcessInfo.processInfo.environment["FORM_OPTICAL_PROOF_DIR"] {
      let target=URL(fileURLWithPath:path);try? FileManager.default.removeItem(at:target);try FileManager.default.copyItem(at:output,to:target)
      store.artworkSession.choose([elements.first{$0.typography?.opticalSizing?.mode == .explicit}!.id])
      let panel=NSWindow(contentRect:.init(x:-10000,y:-10000,width:340,height:340),styleMask:[.titled],backing:.buffered,defer:false);panel.isReleasedWhenClosed=false
      let inspector=NSHostingView(rootView:FontFeaturesInspector(session:store.artworkSession).padding(20).frame(width:340,height:340,alignment:.topLeading).background(Palette.paper));panel.contentView=inspector;panel.orderBack(nil)
      inspector.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.06));inspector.layoutSubtreeIfNeeded()
      let bitmap=try XCTUnwrap(inspector.bitmapImageRepForCachingDisplay(in:inspector.bounds));inspector.cacheDisplay(in:inspector.bounds,to:bitmap)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:target.appendingPathComponent("native-controls.png"));panel.close()
      XCTAssertEqual(store.project,baseline)
    }
  }

  func testSelectionChangeAndLateKeyUpCannotCloseAReplacementInteraction()throws {
    let(store,_,window,_,_,editor)=try fixture();var p=store.project!,other=p.objects[0].artwork!.elements[0];other.id=UUID();other.text="Other source";other.typography!.tracking=5;p.objects[0].artwork!.elements.append(other);store.engine.project=p
    try event(editor,window,code:126);store.artworkSession.choose([other.id]);let before=store.project!
    try event(editor,window,code:126,repeatKey:true);XCTAssertEqual(store.project,before)
    store.engine.beginInteraction("replacement-proof")
    try store.engine.edit("Other interaction",coalescing:"replacement-proof"){$0.subtitle="First replacement edit"}
    let count=store.engine.undoStack.count
    try event(editor,window,code:126,up:true)
    RunLoop.main.run(until:Date().addingTimeInterval(0.7))
    try store.engine.edit("Other interaction",coalescing:"replacement-proof"){$0.subtitle="Second replacement edit"}
    XCTAssertEqual(store.engine.undoStack.count,count,"Late key-up must not end another interaction's coalescing generation")
    XCTAssertEqual(store.project!.objects[0].artwork!.elements[1].typography!.tracking,5)
    let current=store.project!;try event(editor,window,code:6,command:true);XCTAssertEqual(store.project,current)
    store.engine.endInteraction()
  }

  func testRejectedOpticalBatchPreflightKeepsCurrentNativeDraftAndUndoExact()throws {
    let(store,object,window,canvas,_,_)=try fixture(inline:true)
    let editor=try XCTUnwrap(canvasEditors(canvas).first);window.makeFirstResponder(editor)
    editor.undoManager?.groupsByEvent=false;editor.setSelectedRange(.init(location:2,length:3))
    let before=store.project!,selected=editor.selectedRange(),count=store.engine.undoStack.count
    let arguments:[String:Any]=["operations":[
      ["name":"form_update_object","arguments":["object_id":object.id.uuidString,"name":"Must roll back"]],
      ["name":"form_edit_artwork","arguments":["command":"optical","object_id":object.id.uuidString,"element_ids":[before.objects[0].artwork!.elements[0].id.uuidString],"optical_sizing":["mode":"explicit","points":100.0]]]
    ]]
    XCTAssertThrowsError(try store.preflightOpticalHandoff("form_batch",arguments))
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,count);XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(editor.selectedRange(),selected)
    XCTAssertTrue(store.artworkSession.editingText)
    let valid:[String:Any]=["operations":[["name":"form_edit_artwork","arguments":["command":"optical","object_id":object.id.uuidString,"element_ids":[before.objects[0].artwork!.elements[0].id.uuidString],"optical_sizing":["mode":"none"]]]]]
    try store.preflightOpticalHandoff("form_batch",valid);XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === editor)
  }

}
