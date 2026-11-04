import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationEditingPhaseTests:XCTestCase {
  @MainActor private final class Probe:NSObject,@preconcurrency NSTextStorageDelegate,@preconcurrency NSTextViewDelegate {
    let composition:StoryComposition
    var processingCallbacks=0,selectionCallbacks=0,settledCallbacks=0
    init(_ composition:StoryComposition) {
      self.composition=composition;super.init()
      NotificationCenter.default.addObserver(self,selector:#selector(settled(_:)),
        name:PublicationTextStorage.didFinishEditingNotification,object:composition.storage)
    }
    @objc private func settled(_ notification:Notification) {
      XCTAssertFalse(composition.storage.isProcessingEditing)
      settledCallbacks+=1
    }
    func textStorage(_ textStorage:NSTextStorage,didProcessEditing editedMask:NSTextStorageEditActions,range editedRange:NSRange,changeInLength delta:Int) {
      processingCallbacks+=1
      XCTAssertTrue(composition.storage.isProcessingEditing)
      // A native selection callback can run here, before TextKit invalidates its
      // previous glyph map. Every public composition query must refuse layout.
      composition.ensureLayout()
      XCTAssertFalse(composition.layoutAvailable)
      for index in composition.containers.indices {
        XCTAssertEqual(composition.glyphRange(index),NSRange(location:0,length:0))
        XCTAssertEqual(composition.displayRange(index),NSRange(location:0,length:0))
        XCTAssertEqual(composition.sourceRange(index),NSRange(location:0,length:0))
        XCTAssertEqual(composition.offset(index),composition.topOffsets[index])
      }
      XCTAssertEqual(composition.oversetRange,NSRange(location:0,length:composition.storage.length))
    }
    func textViewDidChangeSelection(_ notification:Notification) {
      selectionCallbacks+=1
      composition.ensureLayout()
      if composition.storage.isProcessingEditing {XCTAssertFalse(composition.layoutAvailable)}
    }
    deinit {NotificationCenter.default.removeObserver(self)}
  }
  private func composition()->StoryComposition {
    var element=ArtworkElement(kind:"text",x:0,y:0,width:65,height:24,
      text:(0..<180).map{"Word\($0) e\u{301} 🧵"}.joined(separator:" "),color:"#24353D",fontSize:13)
    var type=Typography();type.fontName="Georgia";element.typography=type
    let frames=(0..<4).map{_ in StoryFrameID(objectID:UUID(),elementID:UUID())}
    let story=TextStory(source:element,frames:frames)
    let geometry=frames.map{StoryFrameGeometry(frame:$0,width:65,height:24,pageY:20)}
    return StoryComposition(.init(story:story,frames:geometry,baselineGrid:nil,language:"en"))
  }
  private func assertContiguous(_ composition:StoryComposition,file:StaticString=#filePath,line:UInt=#line) {
    composition.ensureLayout()
    XCTAssertTrue(composition.layoutAvailable,file:file,line:line)
    var end=0
    for index in composition.containers.indices {
      let range=composition.sourceRange(index)
      XCTAssertEqual(range.location,end,file:file,line:line);end=NSMaxRange(range)
    }
    let tail=composition.oversetRange
    XCTAssertEqual(tail.location,end,file:file,line:line)
    XCTAssertGreaterThan(tail.length,0,file:file,line:line)
    XCTAssertEqual(NSMaxRange(tail),composition.storage.length,file:file,line:line)
  }
  func testNestedStorageEditsNeverLayoutFromProcessingCallbacksAndRecoverWhenOuterEditFinishes() {
    let value=composition(),probe=Probe(value)
    value.storage.delegate=probe
    value.storage.beginEditing()
    value.storage.replaceCharacters(in:NSRange(location:0,length:0),with:"A native insertion 🧵 ")
    value.ensureLayout()
    XCTAssertTrue(value.storage.isProcessingEditing);XCTAssertFalse(value.layoutAvailable)
    XCTAssertEqual(probe.settledCallbacks,0)
    value.storage.beginEditing()
    value.storage.addAttribute(.font,value:NSFont.systemFont(ofSize:36),range:NSRange(location:2,length:5))
    value.storage.endEditing()
    XCTAssertTrue(value.storage.isProcessingEditing)
    XCTAssertEqual(probe.settledCallbacks,0,"An inner endEditing must not announce a safe layout phase.")
    value.storage.endEditing()
    XCTAssertFalse(value.storage.isProcessingEditing)
    XCTAssertGreaterThan(probe.processingCallbacks,0);XCTAssertEqual(probe.settledCallbacks,1)
    assertContiguous(value)
    XCTAssertTrue(value.storage.string.hasPrefix("A native insertion 🧵 "))
    XCTAssertEqual((value.storage.attribute(.font,at:2,effectiveRange:nil) as? NSFont)?.pointSize,36)
  }
  func testLongSourceGalleyAndPhysicalEditsShareStorageWithoutReentrantLayoutAndDeferredReflowCompletes() async {
    _=NSApplication.shared
    let value=composition(),probe=Probe(value),galleyLayout=PublicationLayoutManager()
    value.storage.delegate=probe;value.storage.addLayoutManager(galleyLayout)
    let galleyContainer=NSTextContainer(size:NSSize(width:500,height:10_000_000))
    galleyLayout.addTextContainer(galleyContainer)
    let galley=NSTextView(frame:NSRect(x:0,y:0,width:500,height:500),textContainer:galleyContainer)
    let physical=value.containers.map{NSTextView(frame:NSRect(x:0,y:0,width:190,height:70),textContainer:$0)}
    for view in [galley]+physical {view.delegate=probe;view.isEditable=true}
    let original=value.storage.string
    galley.setSelectedRange(NSRange(location:0,length:0))
    galley.insertText("Galley edit 🧵 ",replacementRange:NSRange(location:0,length:0))
    assertContiguous(value)
    let target=value.sourceRange(1).location
    physical[1].setSelectedRange(NSRange(location:target,length:0))
    physical[1].insertText("Physical edit ",replacementRange:NSRange(location:target,length:0))
    value.storage.addAttribute(.font,value:NSFont.systemFont(ofSize:30),range:NSRange(location:target,length:8))
    // No explicit ensureLayout here: the safe completion notification must
    // schedule recovery, even when no selection callback follows a format edit.
    await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
      DispatchQueue.main.async {continuation.resume()}
    }
    XCTAssertTrue(value.layoutAvailable)
    assertContiguous(value)
    XCTAssertGreaterThan(probe.processingCallbacks,1);XCTAssertGreaterThan(probe.selectionCallbacks,0)
    XCTAssertEqual(value.storage.string.utf16.count,original.utf16.count+"Galley edit 🧵 ".utf16.count+"Physical edit ".utf16.count)
    XCTAssertTrue(galley.textStorage === value.storage)
    XCTAssertTrue(physical.allSatisfy{$0.textStorage === value.storage})
  }
}
