import Foundation
import XCTest
@testable import FormCore

final class PublicationParentLifecycleTests:XCTestCase {
  private func parents(_ document:PublicationDocument,stock:PaperStock)->[SheetAssemblyParentSheet] {
    var slots:[UUID?]=document.layout?.firstPageSide == .verso ? [nil]:[]
    slots+=document.pages.map{Optional($0.id)}
    while slots.count%4 != 0{slots.append(nil)}
    return (0..<(slots.count/4)).map{index in
      .init(frontPageIDs:[slots[slots.count-1-index*2],slots[index*2]],
        backPageIDs:[slots[index*2+1],slots[slots.count-2-index*2]],stock:stock,sizeMM:.init(200,140))
    }
  }
  func testPublicPageSettingsAndMultiRunDeletionReimposeParentsPreserveWordsStockAndUndo()throws {
    var project=Project(name:"Atomic physical publication lifecycle")
    var documents=[UUID](),assemblies=[UUID](),stories=[UUID]()
    let stock=PaperStock(thicknessMM:0.2)
    for run in 0..<2 {
      var ids=[UUID]()
      for index in 0..<4 {
        var page=try project.makeObject(recipeID:"artboard",name:"Run \(run) page \(index)",parameters:["width":100,"depth":140])
        page.artwork = .init(elements:[.init(kind:"text",x:10,y:10,width:80,height:80,text:index==0 ? "Keep every original chapter word \(run)":"",fontSize:14)])
        project.objects.append(page);ids.append(page.id)
      }
      let id=try PublicationCommands.createPublication(in:&project,name:"Run \(run)",pages:ids)
      var document=project.publications!.first{$0.id==id}!
      document.layout = .init(facingPages:true,firstPageSide:run==0 ? .recto:.verso)
      try PublicationCommands.setPublication(in:&project,document:document)
      let element=project.objects.first{$0.id==ids[0]}!.artwork!.elements[0]
      stories.append(try PublicationCommands.createStory(in:&project,frames:[.init(objectID:ids[0],elementID:element.id)],publicationID:id))
      var definition=SheetAssemblyDefinition(publicationID:id,stock:stock,openingDegrees:180,activeSpread:run==0 ? 2:4)
      definition.parentSheets=parents(document,stock:stock)
      assemblies.append(try SheetAssemblyCommands.create(in:&project,definition:definition));documents.append(id)
    }
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try .init(root:folder));engine.project=project
    _=try engine.call("form_publication",arguments:["command":"settings","publication_id":documents[1].uuidString,"name":"Renamed without losing blank leaves"])
    XCTAssertEqual(engine.project?.objects.first{$0.id==assemblies[1]}?.sheetAssembly?.activeSpread,4,"A padded verso-first run must not clamp to its three logical leaf pairs")
    engine.undo();XCTAssertEqual(engine.project,project)
    let removed=documents.map{id in project.publications!.first{$0.id==id}!.pages.last!.objectID}
    let originalSources=project.textStories!.map(\.sourceElement)
    let originalParents=assemblies.map{id in project.objects.first{$0.id==id}!.sheetAssembly!.parentSheets!}
    _=try engine.call("form_delete_objects",arguments:["object_ids":removed.map(\.uuidString)])
    let changed=try XCTUnwrap(engine.project)
    XCTAssertEqual(changed.textStories?.map(\.sourceElement),originalSources)
    XCTAssertEqual(engine.undoStack.count,1)
    for (index,id) in documents.enumerated() {
      let document=try XCTUnwrap(changed.publications?.first{$0.id==id})
      XCTAssertEqual(document.pages.count,3)
      let definition=try XCTUnwrap(changed.objects.first{$0.id==assemblies[index]}?.sheetAssembly)
      let expected=parents(document,stock:stock)
      XCTAssertEqual(definition.parentSheets?.map(\.frontPageIDs),expected.map(\.frontPageIDs))
      XCTAssertEqual(definition.parentSheets?.map(\.backPageIDs),expected.map(\.backPageIDs))
      XCTAssertEqual(definition.parentSheets?.first?.id,originalParents[index][0].id)
      XCTAssertEqual(definition.parentSheets?.first?.stock,originalParents[index][0].stock)
      XCTAssertEqual(definition.activeSpread,2)
    }
    engine.undo();XCTAssertEqual(engine.project,project)
    engine.redo();XCTAssertEqual(engine.project,changed)
    _=try engine.call("form_publication",arguments:["command":"add_page","publication_id":documents[0].uuidString,
      "width":100.0,"height":140.0,"index":1,"story_id":stories[0].uuidString])
    let added=try XCTUnwrap(engine.project),document=try XCTUnwrap(added.publications?.first{$0.id==documents[0]})
    XCTAssertEqual(document.pages.count,4);XCTAssertEqual(added.textStories?.map(\.sourceElement),originalSources)
    let physical=try XCTUnwrap(added.objects.first{$0.id==assemblies[0]}?.sheetAssembly?.parentSheets?.first)
    XCTAssertEqual(physical.frontPageIDs,[document.pages[3].id,document.pages[0].id])
    XCTAssertEqual(physical.backPageIDs,[document.pages[1].id,document.pages[2].id])
    XCTAssertEqual(physical.id,originalParents[0][0].id)
    engine.undo();XCTAssertEqual(engine.project,changed)
  }
}
