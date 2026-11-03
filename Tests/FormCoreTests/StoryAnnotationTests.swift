import AppKit
import FormGraphics
import XCTest
@testable import FormCore

final class StoryAnnotationTests:XCTestCase {
  private func fixture(_ text:String="Alpha 🙂 beta\nTail words")throws->(Project,UUID) {
    var project=Project(name:"Editorial source metadata")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":80])
    var element=ArtworkElement(kind:"text",x:5,y:5,width:90,height:65,text:text,fontSize:14)
    element.typography = .init();element.typography!.fontName="Helvetica"
    page.artwork = .init(elements:[element],bleed:0);project.objects=[page]
    let id=try PublicationCommands.createStory(in:&project,frames:[.init(objectID:page.id,elementID:element.id)])
    return(project,id)
  }
  private func engine(_ project:Project)throws->OperationEngine {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("story-annotations-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try ProjectRepository(root:directory));engine.project=project;return engine
  }
  private func value(_ story:TextStory,_ word:String,kind:StoryAnnotation.Kind = .note,body:String="Editorial note")->StoryAnnotation {
    let range=(story.text as NSString).range(of:word)
    return .init(location:range.location,length:range.length,kind:kind,body:body)
  }
  private func range(_ annotation:StoryAnnotation)->NSRange {.init(location:annotation.location,length:annotation.length)}

  func testMCPUpsertRemoveUndoPersistenceAndLegacyStoryDecodeKeepOneSource()throws {
    let (project,id)=try fixture(),engine=try engine(project),frames=project.objects
    XCTAssertEqual(project.minimumSchemaVersion,26)
    let note=value(project.textStories![0],"beta",kind:.reference,body:"Archive / box 7 / folio 2")
    var raw=try jsonObject(note) as! [String:Any];raw.removeValue(forKey:"id")
    let result=try XCTUnwrap(try engine.call("form_story",arguments:["command":"annotation_upsert","story_id":id.uuidString,"annotation":raw]) as? [String:Any])
    let saved=try JSONDecoder.form.decode(StoryAnnotation.self,from:JSONSerialization.data(withJSONObject:try XCTUnwrap(result["annotation"])))
    XCTAssertEqual(saved.location,note.location);XCTAssertEqual(saved.kind,.reference)
    XCTAssertEqual(engine.project!.objects,frames);XCTAssertEqual(engine.project!.textStories![0].text,project.textStories![0].text)
    XCTAssertEqual(engine.project!.minimumSchemaVersion,64);XCTAssertEqual(engine.undoStack.count,1)
    var changed=saved;changed.body="Updated archive reference"
    _=try engine.call("form_story",arguments:["command":"annotation_upsert","story_id":id.uuidString,"annotation":try jsonObject(changed)])
    XCTAssertEqual(engine.project!.textStories![0].annotations,[changed]);XCTAssertEqual(engine.undoStack.count,2)
    try engine.flush();let reopened=try engine.repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion,64);XCTAssertEqual(reopened.textStories,engine.project!.textStories)
    XCTAssertEqual(reopened.objects,frames)
    _=try engine.call("form_story",arguments:["command":"annotation_remove","story_id":id.uuidString,"annotation_id":saved.id.uuidString])
    XCTAssertNil(engine.project!.textStories![0].annotations)
    engine.undo();XCTAssertEqual(engine.project!.textStories![0].annotations,[changed])
    engine.undo();XCTAssertEqual(engine.project!.textStories![0].annotations,[saved])
    engine.undo();XCTAssertEqual(engine.project,project)
    engine.redo();XCTAssertEqual(engine.project!.textStories![0].annotations,[saved])
    let legacy=try JSONDecoder.form.decode(TextStory.self,from:JSONEncoder.form.encode(project.textStories![0]))
    XCTAssertNil(legacy.annotations);XCTAssertEqual(legacy,project.textStories![0])
  }

  func testRangeValidationBoundsBodiesKindsAndLockedSourceAreAtomic()throws {
    let (project,id)=try fixture(),engine=try engine(project),story=project.textStories![0]
    let emoji=(story.text as NSString).range(of:"🙂")
    let invalid:[StoryAnnotation]=[
      .init(location:emoji.location+1,length:0,body:"Split surrogate"),
      .init(location:emoji.location,length:1,body:"Split surrogate"),
      .init(location:Int.max,length:1,body:"Outside"),
      .init(location:0,length:Int.max,body:"Overflow"),
      .init(location:0,length:0,body:" \n "),
      .init(location:0,length:0,body:String(repeating:"🙂",count:1025))]
    for annotation in invalid {
      XCTAssertThrowsError(try engine.call("form_story",arguments:["command":"annotation_upsert","story_id":id.uuidString,"annotation":try jsonObject(annotation)]))
      XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty)
    }
    let valid=value(story,"beta")
    XCTAssertThrowsError(try StoryAnnotations.validate([valid,valid],in:story.text))
    XCTAssertThrowsError(try StoryAnnotations.validate((0..<257).map{_ in .init(location:0,length:0,body:"Note")},in:story.text))
    XCTAssertThrowsError(try StoryAnnotations.validate((0..<17).map{_ in .init(location:0,length:0,body:String(repeating:"x",count:4096))},in:story.text))
    var raw=try jsonObject(valid) as! [String:Any];raw["kind"]="footnote"
    XCTAssertThrowsError(try engine.call("form_story",arguments:["command":"annotation_upsert","story_id":id.uuidString,"annotation":raw]))
    raw=try jsonObject(valid) as! [String:Any];raw["unexpected"]=true
    XCTAssertThrowsError(try engine.call("form_story",arguments:["command":"annotation_upsert","story_id":id.uuidString,"annotation":raw]))
    engine.project!.objects[0].locked=true;let locked=engine.project
    XCTAssertThrowsError(try engine.call("form_story",arguments:["command":"annotation_upsert","story_id":id.uuidString,"annotation":try jsonObject(valid)]))
    XCTAssertEqual(engine.project,locked);XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testExactSplicesKeepOriginalRepeatedWordAndTrackBoundaryAffinities()throws {
    var (project,id)=try fixture("same same")
    let annotation=StoryAnnotation(location:5,length:4,body:"The second original word")
    try PublicationCommands.upsertAnnotation(in:&project,storyID:id,annotation:annotation)
    // A whole-string diff cannot distinguish identical words. Exact replacement
    // commands preserve the declared insertion intent instead of guessing.
    try PublicationCommands.replaceStoryText(in:&project,storyID:id,range:.init(location:0,length:0),text:"same ")
    XCTAssertEqual(project.textStories![0].annotations?.first?.location,10)
    XCTAssertEqual(project.textStories![0].annotations?.first?.id,annotation.id)
    let text="abcdef",source=StoryAnnotation(location:2,length:3,body:"cde")
    XCTAssertEqual(StoryAnnotations.replacing([source],in:text,range:.init(location:2,length:3),with:"cde"),[source])
    func shifted(_ edit:NSRange,_ inserted:String)throws->StoryAnnotation {
      try XCTUnwrap(StoryAnnotations.replacing([source],in:text,range:edit,with:inserted)?.first)
    }
    XCTAssertEqual(try range(shifted(.init(location:2,length:0),"X")),.init(location:3,length:3))
    XCTAssertEqual(try range(shifted(.init(location:3,length:0),"🙂")),.init(location:2,length:5))
    XCTAssertEqual(try range(shifted(.init(location:5,length:0),"X")),.init(location:2,length:3))
    let point=StoryAnnotation(location:2,length:0,body:"Insertion point")
    XCTAssertEqual(StoryAnnotations.replacing([point],in:text,range:.init(location:2,length:0),with:"🙂")?.first?.location,4)
    let removed=try shifted(.init(location:1,length:5),"Z")
    XCTAssertEqual(range(removed),.init(location:1,length:0));XCTAssertEqual(removed.id,source.id)
    XCTAssertEqual(removed.body,source.body)
    XCTAssertEqual(try range(shifted(.init(location:3,length:1),"")),.init(location:2,length:2))
  }

  func testGeneralSourceChangesFormattingAndDocumentUndoRetainMetadataAndRichOwnership()throws {
    var (project,id)=try fixture()
    let original=project.textStories![0],annotation=value(original,"Tail")
    try PublicationCommands.upsertAnnotation(in:&project,storyID:id,annotation:annotation)
    let engine=try engine(project)
    var source=engine.project!.textStories![0].sourceElement
    source.typography!.underline=true;source.color="#123456"
    try engine.edit("Rich formatting") {try PublicationCommands.setSource(in:&$0,storyID:id,source:source)}
    XCTAssertEqual(engine.project!.textStories![0].annotations,[annotation])
    let formatted=engine.project!
    source=formatted.textStories![0].sourceElement
    source.text="NEW / "+source.text
    try engine.edit("Native full-source publication") {try PublicationCommands.setSource(in:&$0,storyID:id,source:source)}
    var shifted=annotation;shifted.location+=6
    XCTAssertEqual(engine.project!.textStories![0].annotations,[shifted])
    XCTAssertEqual(engine.project!.objects,project.objects)
    let changed=engine.project!
    engine.undo();XCTAssertEqual(engine.project,formatted)
    engine.redo();XCTAssertEqual(engine.project,changed)
    // Changed emoji can share half a surrogate. Inferred edit boundaries must
    // still be safe on both old and new original source strings.
    let emojiNote=StoryAnnotation(location:1,length:2,body:"Emoji")
    let relocated=StoryAnnotations.relocating([emojiNote],from:"A🙂Z",to:"A🙃Z")
    XCTAssertEqual(relocated?.first?.length,0)
    XCTAssertNoThrow(try StoryAnnotations.validate(relocated,in:"A🙃Z"))
    let before=engine.project
    XCTAssertThrowsError(try engine.edit("Mismatched precise edit") {try PublicationCommands.setSource(in:&$0,storyID:id,source:source,textEdit:.init(range:.init(location:0,length:1),text:"wrong"))})
    XCTAssertEqual(engine.project,before)
  }

  func testCanonicalEquivalentNFCAndNFDStillRelocateOriginalUTF16AnchorsExactly()throws {
    let nfc="\u{00E9} Tail",nfd="e\u{0301} Tail"
    XCTAssertEqual(nfc,nfd,"Swift semantic string equality is deliberately broader than source UTF-16 identity")
    XCTAssertFalse(nfc.utf16.elementsEqual(nfd.utf16))
    var (project,id)=try fixture(nfc)
    let note=StoryAnnotation(location:2,length:4,body:"Original Tail")
    try PublicationCommands.upsertAnnotation(in:&project,storyID:id,annotation:note)
    var shifted=note;shifted.location=3
    XCTAssertEqual(StoryAnnotations.replacing([note],in:nfc,range:.init(location:0,length:1),with:"e\u{0301}"),[shifted])
    XCTAssertEqual(StoryAnnotations.relocating([note],from:nfc,to:nfd),[shifted])
    var source=project.textStories![0].sourceElement;source.text=nfd
    let before=project
    // The declared edit yields NFC, while the complete replacement is NFD.
    // Canonical equivalence must not admit a different actual source splice.
    XCTAssertThrowsError(try PublicationCommands.setSource(in:&project,storyID:id,source:source,
      textEdit:.init(range:.init(location:0,length:1),text:"\u{00E9}")))
    XCTAssertEqual(project,before)
    var direct=project.textStories![0]
    direct.setSource(source,textEdit:.init(range:.init(location:0,length:1),text:"\u{00E9}"))
    XCTAssertEqual(direct.annotations,[shifted],"A nonthrowing setter discards an inexact hint and infers the actual source edit")
    try PublicationCommands.setSource(in:&project,storyID:id,source:source)
    XCTAssertEqual(project.textStories![0].annotations,[shifted])
    XCTAssertTrue(project.textStories![0].text.utf16.elementsEqual(nfd.utf16))
    let engine=try engine(before)
    _=try engine.call("form_story",arguments:["command":"replace_text","story_id":id.uuidString,"location":0,"length":1,"text":"e\u{0301}"])
    XCTAssertEqual(engine.project!.textStories![0].annotations,[shifted])
    XCTAssertTrue(engine.project!.textStories![0].text.utf16.elementsEqual(nfd.utf16))
    engine.undo();XCTAssertTrue(engine.project!.textStories![0].text.utf16.elementsEqual(nfc.utf16))
    XCTAssertEqual(engine.project!.textStories![0].annotations,[note])
  }

  func testNormalizationAfterUnchangedAnnotationStillCommitsAndUndoesExactSourceCodeUnits()throws {
    let nfc="Head \u{00E9}",nfd="Head e\u{0301}"
    var (project,id)=try fixture(nfc)
    let note=StoryAnnotation(location:0,length:4,body:"Before the normalized text")
    try PublicationCommands.upsertAnnotation(in:&project,storyID:id,annotation:note)
    XCTAssertNil(project.textStories![0].textRuns)
    let engine=try engine(project)
    _=try engine.call("form_story",arguments:["command":"edit","story_id":id.uuidString,"text":nfd])
    XCTAssertTrue(engine.project!.textStories![0].text.utf16.elementsEqual(nfd.utf16))
    XCTAssertEqual(engine.project!.textStories![0].annotations,[note])
    XCTAssertNil(engine.project!.textStories![0].textRuns)
    XCTAssertEqual(engine.undoStack.count,1,"Exact source normalization is a real edit even when anchors and formatting stay unchanged")
    engine.undo()
    XCTAssertTrue(engine.project!.textStories![0].text.utf16.elementsEqual(nfc.utf16))
    XCTAssertEqual(engine.project!.textStories![0].annotations,[note])
    engine.redo()
    XCTAssertTrue(engine.project!.textStories![0].text.utf16.elementsEqual(nfd.utf16))
  }

  func testExactStoryEqualityStillComparesEveryPersistedSourceAndMetadataField()throws {
    var (project,id)=try fixture("Original source")
    try PublicationCommands.upsertAnnotation(in:&project,storyID:id,
      annotation:.init(location:0,length:8,body:"Original note"))
    let original=project.textStories![0]
    let edits:[(String,(inout TextStory)->Void)]=[
      ("id",{$0.id=UUID()}),("name",{$0.name+=" revised"}),("text",{$0.text+="!"}),
      ("typography",{$0.typography!.tracking+=1}),("fontSize",{$0.fontSize+=1}),("color",{$0.color="#654321"}),
      ("fillSwatchID",{$0.fillSwatchID=UUID()}),("textStyle",{$0.textStyle = .init(styleID:UUID())}),
      ("paragraphStyle",{$0.paragraphStyle = .init(styleID:UUID())}),("textRuns",{$0.textRuns=[]}),
      ("annotations",{$0.annotations![0].body="Revised note"}),("paintStack",{$0.paintStack=[]}),
      ("glyphOverrides",{$0.glyphOverrides=[]}),("listItems",{$0.listItems=[]}),
      ("language",{$0.language="fr"}),("publicationID",{$0.publicationID=UUID()}),
      ("frames",{$0.frames.append(.init(objectID:UUID(),elementID:UUID()))})]
    for (field,edit) in edits {
      var changed=original;edit(&changed)
      XCTAssertNotEqual(changed,original,"Exact equality must retain field: "+field)
      let decoded=try JSONDecoder.form.decode(TextStory.self,from:JSONEncoder.form.encode(changed))
      XCTAssertEqual(decoded,changed,"Persisted field roundtrip: "+field)
    }
    var normalized=original;normalized.text="e\u{0301}"
    var composed=normalized;composed.text="\u{00E9}"
    XCTAssertNotEqual(normalized,composed)
  }

  @MainActor func testAnnotationsNeverEnterPrintSourceRuntimeRenderIdentityOrActualPixels()throws {
    _=NSApplication.shared
    var (project,id)=try fixture("Print only")
    let page=project.objects[0],before=project.resolvingTextStories(in:page.artwork!,objectID:page.id)
    func pixels(_ artwork:Artwork)throws->Data {
      let image=ArtworkRenderer.image(artwork,width:100,height:80,assets:FileManager.default.temporaryDirectory,pixelsPerMM:2)
      let bitmap=try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
      return Data(bytes:try XCTUnwrap(bitmap.bitmapData),count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
    let oldPixels=try pixels(before),oldKey=try before.renderCacheData(),oldSource=project.textStories![0].sourceElement
    let note=StoryAnnotation(location:0,length:5,kind:.reference,body:"PRIVATE EDITORIAL REFERENCE — never print")
    try PublicationCommands.upsertAnnotation(in:&project,storyID:id,annotation:note)
    XCTAssertEqual(project.textStories![0].sourceElement,oldSource)
    XCTAssertNil(project.resolvedTextStory(id)?.story.annotations)
    let after=project.resolvingTextStories(in:page.artwork!,objectID:page.id)
    XCTAssertEqual(try after.renderCacheData(),oldKey)
    XCTAssertEqual(try pixels(after),oldPixels)
    XCTAssertFalse(String(decoding:try JSONEncoder.form.encode(after),as:UTF8.self).contains(note.body))
    XCTAssertTrue(String(decoding:try JSONEncoder.form.encode(project),as:UTF8.self).contains("PRIVATE EDITORIAL REFERENCE"))
  }

  func testPublicToolSchemaAdvertisesBoundedNonprintingAnnotationCommands()throws {
    let tool=try XCTUnwrap(MCP.tools.first{$0["name"] as? String=="form_story"})
    let schema=try XCTUnwrap(tool["inputSchema"] as? [String:Any]),properties=try XCTUnwrap(schema["properties"] as? [String:Any])
    let command=try XCTUnwrap(properties["command"] as? [String:Any]),commands=try XCTUnwrap(command["enum"] as? [String])
    XCTAssertTrue(commands.contains("annotation_upsert"));XCTAssertTrue(commands.contains("annotation_remove"))
    let annotation=try XCTUnwrap(properties["annotation"] as? [String:Any])
    XCTAssertEqual(annotation["additionalProperties"] as? Bool,false)
    XCTAssertEqual(Set(try XCTUnwrap(annotation["required"] as? [String])),["location","length","kind","body"])
    XCTAssertTrue((tool["description"] as? String)?.contains("nonprinting")==true)
  }
}
