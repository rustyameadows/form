import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class ConstructionStarterTests:XCTestCase {
  func testEveryBundledStarterImportsAnEditableValidSourceGraph()throws {
    let catalog=try ConstructionStarterCatalog.bundled()
    XCTAssertFalse(catalog.starters.isEmpty)
    for starter in catalog.starters {
      do {
        var project=Project(name:"Bundled construction source review")
        let imported=try project.importConstructionStarter(starter)
        try project.validateArtworkLinks()
        let owner=try XCTUnwrap(project.objects.first{$0.id==imported.objectID})
        XCTAssertEqual(Set(imported.artworkSourceIDs).count,starter.artworkSources.count)
        let saved=try JSONEncoder.form.encode(project)
        let reopened=try JSONDecoder.form.decode(Project.self,from:saved)
        XCTAssertEqual(try JSONEncoder.form.encode(reopened),saved,"The saved source graph must round-trip at its declared schema.")
        if starter.definition.production != nil {
          let packet=try ConstructionPacketModel(project:project,object:owner)
          XCTAssertTrue(packet.isValid,packet.issues.map(\.message).joined(separator:"\n"))
          XCTAssertEqual(Set(packet.pieces.map(\.id)),Set(try starter.definition.activeComponents().map(\.id)))
        }
      }catch{XCTFail("Bundled source ‘\(starter.id)’ cannot be imported: \(error.localizedDescription)")}
    }
  }
  private func fixture()throws->ConstructionStarter {
    let sourceID=UUID(),layer=ArtworkElement(kind:"text",x:7,y:8,width:70,height:12,text:sourceID.uuidString,color:"#102A34",fontSize:10)
    let artwork=Artwork(background:"#FFFFFF",elements:[layer])
    var component=PlanarComponentDefinition(id:"plate",name:"Separate plate",rootPanelID:"plate",anchor:.init(0,"height"),position:.init(),rotationDegrees:.init(-90,0,0))
    component.front = .init(sourceObjectID:sourceID)
    var definition=PlanarConstructionDefinition(name:"Independent display plate",parameters:[.init("width",100,40...200),.init("height",50,20...120)],size:.init("width","height"),stockThickness:0.6,panels:[
      .init(id:"plate",name:"Display plate",polygon:[.init(0,0),.init("width",0),.init("width","height"),.init(0,"height")])],rootPanelID:"plate",components:[component])
    definition.version=4
    definition.controls = .init(groups:[.init(id:"size",title:"Finished size")],parameters:[.init(parameter:"width",label:"Width",group:"size"),.init(parameter:"height",label:"Height",group:"size")],measurements:[.init(id:"area",label:"Area",expression:"width*height",unit:"mm²",group:"size")])
    return .init(id:"independent-plate",name:"Independent display plate",ownerID:UUID(),definition:definition,stock:.init(thicknessMM:0.6),artworkSources:[
      .init(id:sourceID,name:"Plate artwork",width:"width",height:"height",artwork:artwork,artworkRegions:[.init(id:"face",name:"Face",origin:.init(0,0),size:.init("width","depth"),anchors:[.init(elementIDs:[layer.id])])])])
  }
  func testImportCreatesIndependentEditableSourceGraphAndKeepsUUIDLookingText()throws {
    let starter=try fixture();var project=Project(name:"Independent plates")
    let first=try project.importConstructionStarter(starter),second=try project.importConstructionStarter(starter)
    XCTAssertEqual(project.objects.count,4);XCTAssertNotEqual(first.objectID,second.objectID)
    XCTAssertTrue(Set(first.artworkSourceIDs).isDisjoint(with:second.artworkSourceIDs))
    let original=try XCTUnwrap(starter.artworkSources.first)
    for result in [first,second] {
      let owner=try XCTUnwrap(project.objects.first{$0.id==result.objectID}),source=try XCTUnwrap(project.objects.first{$0.id==result.artworkSourceIDs.first})
      XCTAssertEqual(owner.paperConstruction?.authored?.components?.first?.front?.sourceObjectID,source.id)
      XCTAssertEqual(source.artwork?.elements.first?.text,original.artwork.elements.first?.text)
      XCTAssertNotEqual(source.artwork?.elements.first?.id,original.artwork.elements.first?.id)
      XCTAssertEqual(source.artworkRegions?.first?.anchors?.first?.elementIDs,source.artwork?.elements.map(\.id))
      XCTAssertEqual(source.canvasSourceOnly,true);XCTAssertEqual(source.parameters["width"],100)
      XCTAssertTrue(project.isIndependentFlatArtworkSource(source));XCTAssertEqual(source.dimensionBindings?.count,2)
    }
  }
  func testImportedSourceTracksOwnerDimensionsWithoutScalingArtwork()throws {
    var project=Project(name:"Dimensioned plate");let result=try project.importConstructionStarter(fixture()),before=project
    let index=try XCTUnwrap(project.objects.firstIndex{$0.id==result.objectID})
    var definition=try XCTUnwrap(project.objects[index].paperConstruction?.authored)
    try definition.setParameters(["width":130]);project.objects[index].paperConstruction!.authored=definition
    project.objects[index].parameters["width"]=130
    try project.reconcilePhysicalDimensions(previous:before)
    let source=try XCTUnwrap(project.objects.first{$0.id==result.artworkSourceIDs[0]}),old=try XCTUnwrap(before.objects.first{$0.id==source.id})
    XCTAssertEqual(source.parameters["width"],130);XCTAssertEqual(source.artwork,old.artwork)
    XCTAssertEqual(source.artwork?.elements.first?.fontSize,10)
  }
  func testInvalidStarterDoesNotPartiallyAppendObjectsRecipesOrSources()throws {
    var project=Project(name:"Safe import"),starter=try fixture();let before=project
    starter.artworkSources[0].width="unknownDimension"
    XCTAssertThrowsError(try project.importConstructionStarter(starter));XCTAssertEqual(project,before)
  }
  func testDataRoundTripAndControlValidationRejectsInvalidReferenceChoices()throws {
    let original=try fixture(),decoded=try ConstructionStarterCatalog.decode(JSONEncoder.form.encode(original))
    XCTAssertEqual(original,decoded)
    let parameters:[CADModelParameter]=[.init("reference",0,0...1),.init("length",40,10...100)]
    let controls=ConstructionControlSurface(parameters:[.init(parameter:"reference",label:"Dimension reference",choices:[.init(label:"Clear",value:0),.init(label:"Envelope",value:1)])],dimensionReferenceParameter:"reference")
    XCTAssertNoThrow(try controls.validate(parameters:parameters,derived:nil))
    var invalid=controls;invalid.parameters[0].choices=[.init(label:"Unknown",value:0),.init(label:"Out of range",value:3)]
    XCTAssertThrowsError(try invalid.validate(parameters:parameters,derived:nil))
    invalid=controls;invalid.dimensionReferenceParameter="length"
    XCTAssertThrowsError(try invalid.validate(parameters:parameters,derived:nil))
  }
}
