import Foundation
import XCTest
@testable import FormCore

final class PublicationDependencyTests:XCTestCase {
  private func fixture()throws->(Project,UUID,UUID,UUID) {
    var project=Project(name:"Live physical source dependencies")
    for index in 0..<2 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":100,"depth":140])
      page.artwork = .init(elements:[.init(kind:"text",x:10,y:10,text:"Original")]);project.objects.append(page)
    }
    let document=try PublicationCommands.createPublication(in:&project,name:"Publication",pages:project.objects.map(\.id))
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document))
    return(project,document,assembly,project.publications![0].pages[0].objectID)
  }
  func testLiveAssemblyViewInsideItsPageRejectsAtomicallyButFrozenPixelsRemainAllowed()throws {
    let (project,_,assembly,page)=try fixture()
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try .init(root:root));engine.project=project
    var element=ArtworkElement(kind:"image",x:0,y:0,width:20,height:20,asset:"frozen.png")
    element.objectView = .init(sourceID:assembly,style:"rendered",linked:true)
    XCTAssertThrowsError(try engine.edit("Live source loop"){candidate in
      let index=candidate.objects.firstIndex{$0.id==page}!;candidate.objects[index].artwork!.elements.append(element)
    })
    XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty)
    element.objectView?.linked=false
    try engine.edit("Frozen source picture"){candidate in
      let index=candidate.objects.firstIndex{$0.id==page}!;candidate.objects[index].artwork!.elements.append(element)
    }
    XCTAssertFalse(engine.project!.artworkDependencyCycle(from:assembly));XCTAssertEqual(engine.undoStack.count,1)
  }
  func testAppliedMasterAndNestedComponentDependenciesRejectLiveAssemblyLoop()throws {
    var (project,_,assembly,_)=try fixture()
    var component=try project.makeObject(recipeID:"artboard",name:"Reusable source",parameters:["width":100,"depth":140])
    var image=ArtworkElement(kind:"image",x:0,y:0,width:20,height:20,asset:"old.png")
    image.objectView = .init(sourceID:assembly,style:"rendered",linked:true);component.artwork = .init(elements:[image]);component.componentDefinition=true
    project.objects.append(component)
    var master=try project.makeObject(recipeID:"artboard",name:"Canonical master",parameters:["width":100,"depth":140])
    var instance=ArtworkElement(kind:"group",x:0,y:0,width:100,height:140);instance.contentSize = .init(100,140);instance.component = .init(sourceObjectID:component.id)
    master.artwork = .init(elements:[instance]);project.objects.append(master)
    let before=project;var document=project.publications![0];document.masters=[.init(sourceObjectID:master.id)]
    XCTAssertThrowsError(try PublicationCommands.setPublication(in:&project,document:document));XCTAssertEqual(project,before)
    project.objects[project.objects.firstIndex{$0.id==component.id}!].artwork!.elements[0].objectView?.linked=false
    XCTAssertNoThrow(try PublicationCommands.setPublication(in:&project,document:document))
    XCTAssertFalse(project.artworkDependencyCycle(from:assembly))
  }
}
