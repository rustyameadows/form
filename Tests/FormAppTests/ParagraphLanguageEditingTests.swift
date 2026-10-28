import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class ParagraphLanguageEditingTests:XCTestCase {
  private func window()->NSWindow {
    _=NSApplication.shared
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:350),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;return window
  }
  func testNativeLocaleTypingAndUndoUseTheSharedPublicationStorage() throws {
    let window=window();defer{window.close()}
    let view=CanvasTextView(frame:window.contentView!.bounds);window.contentView=view;window.makeFirstResponder(view)
    view.isRichText=true;view.allowsUndo=true
    XCTAssertTrue(view.textStorage is PublicationTextStorage)
    var type=Typography();type.language="tr";type.caseTreatment="uppercase"
    view.typingAttributes=TypographyEngine.attributes(type,size:24,color:"#26323C",millimeters:false)
    view.insertText("istanbul",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"İSTANBUL");XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"istanbul")
    view.undoManager?.undo();XCTAssertEqual(view.string,"")
    view.undoManager?.redo();XCTAssertEqual(view.string,"İSTANBUL")
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"istanbul")
  }
  func testOpeningAndFinishingInheritedLanguageDoesNotChangeProjectOrHistory() throws {
    let window=window();defer{window.close()}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root)
    var p=Project(name:"Inherited language"),object=try p.makeObject(recipeID:"artboard")
    var e=ArtworkElement(kind:"text",x:10,y:10,width:100,height:40,text:"I\u{301} I",color:"#26323C",fontSize:24)
    var type=Typography();type.caseTreatment="lowercase";e.typography=type
    object.artwork = Artwork(elements:[e]);object.artwork!.language="lt";p.objects=[object];try repo.save(p)
    let store=StudioStore(repository:repo,seedLibrary:false);try store.engine.open(p.id)
    let before=store.project
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=object.id;session.choose([e.id]);window.contentView=canvas
    canvas.synchronize();canvas.beginText(e)
    let native=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    XCTAssertEqual(native.string,e.text.lowercased(with:Locale(identifier:"lt")))
    native.didChangeText();canvas.finishText()
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testMCPDocumentLanguageResizesPointTextAndKeepsAreaBoundsInOneUndo() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p=Project(name:"Point language"),object=try p.makeObject(recipeID:"artboard")
    var point=ArtworkElement(kind:"text",x:0,y:0,width:5,height:10,text:"iiii",fontSize:30)
    var type=Typography();type.fontName="HelveticaNeue";type.frameMode="point";type.caseTreatment="uppercase";point.typography=type
    var area=point;area.id=UUID();area.typography!.frameMode="area";area.width=80;area.height=40
    let size=TypographyEngine.measured(point);point.width=size.width+0.5;point.height=max(30/TypographyEngine.pointsPerMM*1.4,size.height+0.5)
    object.artwork = Artwork(elements:[point,area]);p.objects=[object];store.engine.project=p
    _=try store.engine.call("form_edit_artwork",arguments:["object_id":object.id.uuidString,"command":"language","language":"tr"])
    let changed=store.project!.objects[0].artwork!
    XCTAssertEqual(changed.language,"tr");XCTAssertEqual(changed.elements[1],area)
    XCTAssertEqual(changed.elements[0].width,TypographyEngine.measured(point.inheritingLanguage("tr")).width+0.5,accuracy:1e-6)
    XCTAssertNil(changed.elements[0].typography!.language)
    store.engine.undo();XCTAssertEqual(store.project,p)
  }
  func testMultilingualPhysicalExportAgreesWithOutlinesAndPreservesSource() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p=Project(name:"Publication language proof"),sheet=try p.makeObject(recipeID:"artboard",parameters:["width":160,"depth":210])
    var heading=ArtworkElement(kind:"text",x:14,y:12,width:132,height:18,text:"ORBITAL / FIELD NOTES",color:"#24353D",fontSize:24)
    heading.typography=Typography();heading.typography!.fontName="HelveticaNeue-Medium"
    var art=Artwork(background:"#F5F1E6",elements:[heading],bleed:0);art.language="en"
    for (i,sample) in [("en","English / Dictionary","Extraordinary photographic observations illuminate the relationship between objects and light."),
      ("de","Deutsch / Wörterbuch","Donaudampfschifffahrtsgesellschaft und außergewöhnliche Beobachtungen verbinden Material und Konstruktion."),
      ("tr","Türkçe / büyük harf","istanbul ışık i ı I İ"),("lt","Lietuvių / mažosios raidės","I\u{301} J\u{301} Į\u{301} — IŠRAIŠKA"),
      ("el","Ελληνικά / πεζά","ΟΣ ΟΣΑ — ΦΩΣ ΚΑΙ ΣΧΗΜΑ")].enumerated() {
      let y=40+Double(i)*30
      var label=ArtworkElement(kind:"text",x:14,y:y,width:132,height:7,text:sample.1,color:"#A55135",fontSize:10)
      label.typography=Typography();label.typography!.fontName="HelveticaNeue-Medium"
      var body=ArtworkElement(kind:"text",x:14,y:y+8,width:122,height:21,text:sample.2,color:"#24353D",fontSize:14)
      body.typography=Typography();body.typography!.fontName="Georgia";body.typography!.language=sample.0
      body.typography!.hyphenation=1;body.typography!.hyphenationLimits = .init(minimumWordLength:6,minimumPrefix:2,minimumSuffix:3)
      body.typography!.caseTreatment=sample.0=="tr" ? "uppercase":(["lt","el"].contains(sample.0) ? "lowercase":"original")
      art.elements += [label,body]
    }
    sheet.artwork=art;p.objects=[sheet];store.engine.project=p
    let before=store.project
    let outputs=root.appendingPathComponent("proof");try FileManager.default.createDirectory(at:outputs,withIntermediateDirectories:true)
    for format in ["pdf","svg","png"] {
      let path=outputs.appendingPathComponent("publication-language."+format)
      _=try store.graphicsCall("form_export_artwork",["object_id":sheet.id.uuidString,"format":format,"path":path.path,"dpi":144,"outline_text":false])
      let data=try Data(contentsOf:path);XCTAssertGreaterThan(data.count,1000)
      if format=="pdf" {
        let document=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data as CFData)!)),page=try XCTUnwrap(document.page(at:1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).width/TypographyEngine.pointsPerMM,160,accuracy:0.001)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height/TypographyEngine.pointsPerMM,210,accuracy:0.001)
      }
      if let destination=ProcessInfo.processInfo.environment["FORM_PUBLICATION_PROOF_DIR"] {
        let folder=URL(fileURLWithPath:destination);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try data.write(to:folder.appendingPathComponent(path.lastPathComponent),options:.atomic)
      }
    }
    let converted=try ArtworkOutlines.convert(art,ids:Set(art.elements.filter{$0.kind=="text"}.map(\.id)),mode:"text").artwork
    let native=ArtworkRenderer.image(art,width:160,height:210,assets:root,pixelsPerMM:3).representations[0] as! NSBitmapImageRep
    let outlined=ArtworkRenderer.image(converted,width:160,height:210,assets:root,pixelsPerMM:3).representations[0] as! NSBitmapImageRep
    var sum=0.0,count=0
    for y in 0..<native.pixelsHigh {for x in 0..<native.pixelsWide {
      let a=native.colorAt(x:x,y:y)!,b=outlined.colorAt(x:x,y:y)!
      if min(a.redComponent,b.redComponent)<0.6 {sum+=abs(a.redComponent-b.redComponent);count+=1}
    }}
    print("Explicit-language native/outline foreground error: \(sum/Double(max(1,count)))")
    XCTAssertGreaterThan(count,1000);XCTAssertLessThan(sum/Double(count),0.15)
    XCTAssertEqual(store.project,before)
  }
}
