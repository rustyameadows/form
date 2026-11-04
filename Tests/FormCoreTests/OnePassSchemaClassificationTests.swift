import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class OnePassSchemaClassificationTests:XCTestCase {
  private func object(_ name:String="Ordinary row")->ProductObject {
    .init(name:name,recipeID:"box",parameters:["width":100,"height":100,"depth":100])
  }
  private func minimum(_ object:ProductObject)->Int {
    var project=Project(name:"Exact schema contribution");project.objects=[object];return project.minimumSchemaVersion
  }
  func testMixedProjectAndLaterObjectFeaturesSelectHighestRequirementIndependentlyOfOrder()throws {
    var project=Project(name:"Mixed schema tiers"),plain=object()
    plain.recipeID="clock"
    var view=ArtworkElement(kind:"rectangle",x:0,y:0,width:10,height:10)
    view.objectView = .init(sourceID:plain.id)
    var page=object("Later feature row");page.recipeID="artboard";page.artwork = .init(elements:[view])
    project.objects=[plain,page];project.fontLibrary = .init(faceNames:["Helvetica"])
    XCTAssertEqual(project.minimumSchemaVersion,61)
    project.objects.reverse();XCTAssertEqual(project.minimumSchemaVersion,61)
    let recipe=Recipe("schemaSolid","Generic shape","cube","Existing exact feature",[],solid:.init(nodes:[.init(kind:"ellipsoid",values:["x":"0","y":"0","z":"0","radiusX":"1","radiusY":"1","radiusZ":"1"])]))
    project.recipes=[recipe];XCTAssertEqual(project.minimumSchemaVersion,62)
    var story=TextStory(source:.init(kind:"text",x:0,y:0,text:"Source words"));story.annotations=[.init(location:0,length:6,kind:.note,body:"Editorial source")]
    project.textStories=[story];XCTAssertEqual(project.minimumSchemaVersion,64)
    project.objects[1].dimensionBindings=[];XCTAssertEqual(project.minimumSchemaVersion,65,"A present empty declaration retains its historical reader requirement.")
    project.objects[1].dimensionBindings=nil;project.textStories=nil;project.recipes=[]
    project.objects[0].artwork!.elements[0].objectView=nil
    XCTAssertEqual(project.minimumSchemaVersion,59,"A resource can outrank every remaining object.")
    project.fontLibrary=nil;XCTAssertEqual(project.minimumSchemaVersion,3,"The legacy clock requirement remains after removing higher tiers.")
    // The portable ISO8601 date encoding retains whole seconds. Keep this
    // schema/source equality fixture independent of the current clock fraction.
    project.createdAt=Date(timeIntervalSince1970:1_700_000_000)
    project.updatedAt=Date(timeIntervalSince1970:1_700_000_001)
    let source=project
    let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
    XCTAssertEqual(decoded,source);XCTAssertEqual(decoded.minimumSchemaVersion,3)
  }
  func testNilAndPresentEmptyOptionalObjectFieldsKeepTheirExactHistoricalLevels()throws {
    let edits:[(String,Int,(inout ProductObject)->Void)]=[
      ("dimension declarations",65,{$0.dimensionBindings=[]}),
      ("construction regions",65,{$0.artworkRegions=[]}),
      ("false Canvas source role",57,{$0.canvasSourceOnly=false}),
      ("empty artwork bindings",56,{$0.artworkParameterBindings=[]}),
      ("empty physical intents",56,{$0.physicalArtworkIntents=[]}),
      ("empty projection positions",55,{$0.canvasProjectionPositions=[:]}),
      ("empty surface bindings",55,{$0.surfaceArtworkBindings=[]}),
      ("false component marker",1,{$0.componentDefinition=false})]
    for (label,expected,edit) in edits {
      var row=object();XCTAssertEqual(minimum(row),1,label);edit(&row)
      XCTAssertEqual(minimum(row),expected,label)
      let decoded=try JSONDecoder.form.decode(ProductObject.self,from:JSONEncoder.form.encode(row))
      XCTAssertEqual(minimum(decoded),expected,label)
    }
    var paper=object();paper.paperConstruction = .init(kind:.envelope,dimensions:.init(width:100,height:140,depth:10))
    XCTAssertEqual(minimum(paper),53)
    paper.paperConstruction!.finishes=[];XCTAssertEqual(minimum(paper),57)
    paper.paperConstruction!.finishes=nil;paper.paperConstruction!.stock.plies=[];XCTAssertEqual(minimum(paper),57)
    paper.paperConstruction!.stock.plies=nil;XCTAssertEqual(minimum(paper),53)
  }
  func testLegacyRecipeOnlyAndEmptyProjectResourceSemanticsAreUnchanged() {
    for (id,expected) in [("box",1),("clock",3),("deskClock",50),("paperEnvelope",53),("tuckCarton",53)] {
      var row=object();row.recipeID=id;XCTAssertEqual(minimum(row),expected,id)
    }
    if let id=StarterTextiles.recipeIDs.sorted().first {var row=object();row.recipeID=id;XCTAssertEqual(minimum(row),51)}
    var project=Project(name:"Empty optional resources")
    project.textStories=[];project.publications=[];project.textStyles=[];project.swatches=[]
    project.garmentBlocks=[];project.decorationPreparations=[];project.productionJobs=[]
    project.studioPresentation = .init(shots:[]);project.studioPresentation?.scenes=[]
    project.recipes=[Recipe("unusedRequirements","Generic source","square","No active rules",[],requirements:[])]
    project.objects=[object()]
    XCTAssertEqual(project.minimumSchemaVersion,1,"Presence-only fields and nonempty-only fields must not be conflated.")
  }
  func testStoryAndStyleCharacterOpticalAndPaintRequirementsRemainProjectContributions() {
    var project=Project(name:"Global typography features")
    var type=Typography();type.characterPosition = .normal
    project.textStyles=[.init(name:"Explicit normal character position",typography:type)]
    XCTAssertEqual(project.minimumSchemaVersion,47)
    type.characterPosition=nil;type.opticalSizing = .init(.none)
    project.textStyles=[.init(name:"Optical policy",typography:type)]
    XCTAssertEqual(project.minimumSchemaVersion,42)
    project.textStyles=nil
    var story=TextStory(source:.init(kind:"text",x:0,y:0,text:"Global source"))
    var position=Typography();position.characterPosition = .superscript
    story.textRuns=[.init(location:0,length:6,typography:position,fontSize:12,color:"#000000")]
    project.textStories=[story];XCTAssertEqual(project.minimumSchemaVersion,47)
    story.textRuns=nil;story.typography=type;project.textStories=[story]
    XCTAssertEqual(project.minimumSchemaVersion,42)
    story.typography=nil;story.paintStack=[];project.textStories=[story]
    XCTAssertEqual(project.minimumSchemaVersion,58,"Empty but authored source paint remains a newer persisted field.")
    story.paintStack=nil;project.textStories=[story];XCTAssertEqual(project.minimumSchemaVersion,26)
  }
  func testDetachedStorySnapshotAndInsideArtworkParticipateInHigherStoredDocumentRequirements()throws {
    var project=Project(name:"Detached canonical snapshot features"),row=object()
    var source=ArtworkElement(kind:"text",x:0,y:0,text:"Frozen source");source.paintStack=[.init(.init(color:"#123456"))]
    let snapshot=ResolvedTextStory(story:.init(source:source),frames:[],baselineGrid:nil,language:nil)
    var binding=PhysicalSurfaceArtworkBinding(surfaceID:"top",sourceObjectID:UUID(),widthMM:100,heightMM:100)
    binding.sourceObjectID=nil;binding.artwork = .init(elements:[]);binding.storySnapshots=[snapshot]
    row.surfaceArtworkBindings=[binding];project.objects=[row]
    XCTAssertNil(row.artwork);XCTAssertEqual(project.minimumSchemaVersion,58)
    project.objects[0].surfaceArtworkBindings![0].storySnapshots=[];XCTAssertEqual(project.minimumSchemaVersion,55)
    var view=ArtworkElement(kind:"rectangle",x:0,y:0);view.objectView = .init(sourceID:UUID())
    project.objects[0].surfaceArtworkBindings![0].artwork = .init(elements:[view])
    XCTAssertEqual(project.minimumSchemaVersion,61)
    let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
    XCTAssertEqual(decoded.minimumSchemaVersion,61);XCTAssertEqual(decoded.objects,project.objects)
    row.surfaceArtworkBindings=nil;row.paperConstruction = .init(kind:.envelope,dimensions:.init(width:100,height:140,depth:10),insideArtwork:.init(elements:[view]))
    project.objects=[row];XCTAssertEqual(project.minimumSchemaVersion,61)
  }
  func testExistingAndFutureSchemaFloorsRemainMonotonicWithoutMutatingSources() {
    var project=Project(name:"Schema floor"),row=object();row.artworkRegions=[];project.objects=[row]
    project.schemaVersion=63;XCTAssertEqual(project.minimumSchemaVersion,65)
    project.objects=[];XCTAssertEqual(project.minimumSchemaVersion,63)
    for floor in [Project.maximumSchemaVersion,Project.maximumSchemaVersion+1,Project.maximumSchemaVersion+20] {
      project.schemaVersion=floor;project.objects=[row]
      let original=project
      XCTAssertEqual(project.minimumSchemaVersion,floor);XCTAssertEqual(project,original)
    }
  }
}
