import Foundation
import XCTest
@testable import FormCore

final class PublicationSpreadArtworkTests: XCTestCase {
  private func fixture() throws -> (Project, UUID, [UUID], UUID) {
    var project=Project(name:"Canonical reader artwork")
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":100,"depth":140])
      page.artwork = .init(background:"#FFFFFF",elements:[],bleed:3)
      page.artwork?.canvasPosition = .init(Double(index)*136+36,40)
      project.objects.append(page)
    }
    let pages=project.objects.map(\.id)
    let id=try PublicationCommands.createPublication(in:&project,name:"Facing source",pages:pages)
    var document=project.publications![0];document.layout = .init(facingPages:true)
    try PublicationCommands.setPublication(in:&project,document:document)
    var image=ArtworkElement(kind:"image",x:70,y:20,width:60,height:40,asset:"asymmetric.png")
    image.name="Asymmetric gutter image"
    let text=ArtworkElement(kind:"text",x:75,y:70,width:70,height:16,text:"Across the gutter",fontSize:14)
    var artwork=project.objects[1].artwork!;artwork.elements=[image,text]
    try project.setArtwork(artwork,for:pages[1]);try project.validateArtworkLinks()
    return(project,id,pages,image.id)
  }
  func testReaderGeometryAndDerivedNeighborCropKeepOneCanonicalImageAndOriginalCoordinates() throws {
    let(project,id,pages,imageID)=try fixture(),before=project
    let spreads=project.publicationReaderSpreads(id)
    XCTAssertEqual(spreads.map{$0.pages.count},[1,2,1])
    let spread=try XCTUnwrap(project.publicationReaderSpread(for:pages[1]))
    XCTAssertEqual(spread.pages.map(\.objectID),Array(pages[1...2]))
    XCTAssertEqual(spread.pages.map(\.originMM),[.init(0,0),.init(100,0)])
    XCTAssertEqual(spread.sizeMM,.init(200,140))
    let left=try XCTUnwrap(project.surfaceArtwork(project.objects[1]))
    let right=try XCTUnwrap(project.surfaceArtwork(project.objects[2]))
    let leftImage=try XCTUnwrap(left.elements.first{$0.id==imageID})
    let rightImage=try XCTUnwrap(right.elements.first{$0.kind=="image"})
    XCTAssertEqual(left.bounds(of:leftImage).x,70,accuracy:0.000001)
    XCTAssertEqual(right.bounds(of:rightImage).x,-30,accuracy:0.000001)
    XCTAssertEqual(right.bounds(of:rightImage).width,60,accuracy:0.000001)
    XCTAssertEqual(rightImage.asset,leftImage.asset);XCTAssertEqual(rightImage.locked,true)
    XCTAssertNotEqual(rightImage.id,imageID)
    XCTAssertEqual(right,project.surfaceArtwork(project.objects[2]),"Derived identities and source ranges must be stable")
    XCTAssertEqual(project.objects.flatMap{$0.artwork?.elements ?? []}.filter{$0.kind=="image"}.count,1)
    XCTAssertEqual(project,before)
    var saved=project
    try saved.setArtwork(right,for:pages[2]);try saved.validateArtworkLinks()
    XCTAssertEqual(saved.objects[2].artwork?.elements,[],"A resolved page crop must never save a copied neighbor image")
  }
  func testOwnerMoveResizeChangesBothCropsAndRetainsExactSourceUndoAndReopen() throws {
    let(project,_,pages,imageID)=try fixture()
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let repository=try ProjectRepository(root:folder),engine=OperationEngine(repository:repository)
    engine.project=project
    let beforeRight=try XCTUnwrap(project.surfaceArtwork(project.objects[2]))
    try engine.edit("Move and resize one gutter source"){candidate in
      var artwork=candidate.objects[1].artwork!
      let index=artwork.elements.firstIndex{$0.id==imageID}!
      artwork.elements[index].x=85;artwork.elements[index].width=80
      try candidate.setArtwork(artwork,for:pages[1])
    }
    let changed=try XCTUnwrap(engine.project)
    let left=try XCTUnwrap(changed.surfaceArtwork(changed.objects[1]))
    let right=try XCTUnwrap(changed.surfaceArtwork(changed.objects[2]))
    XCTAssertEqual(left.bounds(of:try XCTUnwrap(left.elements.first{$0.id==imageID})).x,85,accuracy:0.000001)
    let image=try XCTUnwrap(right.elements.first{$0.kind=="image"})
    XCTAssertEqual(right.bounds(of:image).x,-15,accuracy:0.000001);XCTAssertEqual(right.bounds(of:image).width,80,accuracy:0.000001)
    XCTAssertNotEqual(try beforeRight.renderCacheData(),try right.renderCacheData())
    XCTAssertEqual(changed.objects[2],project.objects[2],"Neighbor source remains canonical and untouched")
    XCTAssertEqual(changed.objects.flatMap{$0.artwork?.elements ?? []}.filter{$0.id==imageID}.count,1)
    XCTAssertEqual(engine.undoStack.count,1)
    engine.undo();XCTAssertEqual(engine.project,project)
    engine.redo();XCTAssertEqual(engine.project,changed)
    try engine.flush();let reopened=try repository.load(changed.id)
    XCTAssertEqual(reopened.objects,changed.objects);XCTAssertEqual(reopened.publications,changed.publications)
    XCTAssertEqual(reopened.surfaceArtwork(reopened.objects[2]),right)
  }
  func testMastersStayPageLocalWhileCanonicalArtworkCrossesGutter() throws {
    var(project,_,pages,_)=try fixture()
    var master=try project.makeObject(recipeID:"artboard",name:"Canonical running source",parameters:["width":100,"depth":140])
    master.artwork = .init(elements:[.init(kind:"text",x:80,y:5,width:50,height:10,text:"Folio {{page.number}}",fontSize:10)])
    project.objects.append(master)
    var document=project.publications![0];document.masters=[.init(sourceObjectID:master.id)]
    try PublicationCommands.setPublication(in:&project,document:document)
    let right=try XCTUnwrap(project.surfaceArtwork(project.objects[2]))
    XCTAssertTrue(right.elements.contains{$0.kind=="text" && $0.text=="Across the gutter"})
    XCTAssertTrue(right.elements.contains{$0.kind=="text" && $0.text=="Folio 3"})
    XCTAssertFalse(right.elements.contains{$0.kind=="text" && $0.text=="Folio 2"},"Neighbor furniture is a page-local projection")
    XCTAssertEqual(project.objects.last?.artwork?.elements[0].text,"Folio {{page.number}}")
  }
  func testSymmetricReaderCompositionIsAcyclicButActualLiveRenderedFeedbackRejectsAtomically() throws {
    let(project,_,pages,_)=try fixture()
    XCTAssertFalse(project.artworkDependencyCycle(from:pages[1]));XCTAssertFalse(project.artworkDependencyCycle(from:pages[2]))
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try .init(root:folder));engine.project=project
    var view=ArtworkElement(kind:"image",x:-15,y:10,width:30,height:30,asset:"frozen.png")
    view.objectView = .init(sourceID:pages[1],style:"rendered",linked:true)
    XCTAssertThrowsError(try engine.edit("Feedback through a reader crop"){candidate in
      candidate.objects[2].artwork?.elements.append(view)
    })
    XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty)
    view.objectView?.linked=false
    XCTAssertNoThrow(try engine.edit("Frozen printed snapshot"){candidate in candidate.objects[2].artwork?.elements.append(view)})
    XCTAssertFalse(engine.project!.artworkDependencyCycle(from:pages[1]))
  }
}
