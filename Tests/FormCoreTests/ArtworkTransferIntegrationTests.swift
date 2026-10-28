import Foundation
import XCTest
@testable import FormCore

final class ArtworkTransferIntegrationTests:XCTestCase {
  func testKnownPositionAndPageContextSurvivePortableRoundTripWithoutReplacingDestinationGuides()throws {
    var source=Project(name:"Position and page source")
    var owner=try source.makeObject(recipeID:"artboard",parameters:["width":200,"depth":150])
    var raised=Typography();raised.characterPosition = .superscript;raised.baseline=3;raised.opticalSizing = .init(.automatic);raised.variations=[1869640570:72]
    var lowered=raised;lowered.characterPosition = .subscript
    let style=ArtworkTextStyle(name:"Source intent",typography:raised,fontSize:36);source.textStyles=[style]
    var text=ArtworkElement(kind:"text",x:12,y:20,width:140,height:30,text:"12abQ",fontSize:36);text.typography=raised;text.textStyle = .init(styleID:style.id)
    text.textRuns=[.init(location:0,length:2,typography:raised,fontSize:36,color:text.color),.init(location:2,length:2,typography:lowered,fontSize:36,color:text.color),.init(location:4,length:1,typography:raised,fontSize:36,color:text.color)]
    var art=Artwork(background:"#FFFFFF",elements:[text],bleed:3);art.safeInset=7.125;owner.artwork=art;source.objects=[owner];try source.validateArtworkLinks()
    let original=source
    let bundle=try ArtworkTransferGraph.capture(project:source,objectID:owner.id,ids:[text.id],readAsset:{_,_ in XCTFail("No asset read is needed");return Data()})
    XCTAssertEqual(bundle.metadata.sourceSchema,49)
    let decoded=try ArtworkTransferBundle.decode(bundle.encoded())
    XCTAssertEqual(decoded.metadata.artwork.safeInset,7.125);XCTAssertEqual(decoded.metadata.artwork.bleed,3)
    var destination=Project(name:"Independent destination")
    var frame=try destination.makeObject(recipeID:"artboard",parameters:["width":240,"depth":180]);frame.artwork=Artwork(background:"#F4F0E8",elements:[],bleed:1.25);frame.artwork!.safeInset=6.5;destination.objects=[frame]
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root);try repository.save(destination);let engine=OperationEngine(repository:repository);try engine.open(destination.id)
    destination=try XCTUnwrap(engine.project);let before=engine.project
    let plan=try ArtworkTransferGraph.plan(decoded,into:destination,objectID:frame.id)
    let result=try XCTUnwrap(plan.project.objects.first{$0.id==frame.id}?.artwork),copy=try XCTUnwrap(result.elements.first)
    XCTAssertEqual(result.safeInset,6.5);XCTAssertEqual(result.bleed,1.25);XCTAssertEqual(result.background,"#F4F0E8")
    XCTAssertEqual(copy.text,text.text);XCTAssertEqual(copy.fontSize,36);XCTAssertEqual(copy.typography,raised);XCTAssertEqual(copy.textRuns,text.textRuns)
    XCTAssertEqual(plan.project.textStyles?.first?.typography,raised);XCTAssertNotEqual(copy.textStyle?.styleID,style.id)
    XCTAssertEqual(plan.project.minimumSchemaVersion,49);XCTAssertEqual(source,original)
    var positionOnly=source;positionOnly.objects[0].artwork!.safeInset=nil
    let legacy=try ArtworkTransferGraph.capture(project:positionOnly,objectID:owner.id,ids:[text.id],readAsset:{_,_ in Data()})
    XCTAssertEqual(legacy.metadata.sourceSchema,47);XCTAssertEqual(try ArtworkTransferBundle.decode(legacy.encoded()).metadata.artwork.elements[0].textRuns,text.textRuns)
    try engine.edit("Paste source-preserving artwork"){$0=try plan.applying(to:$0)};XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,before);engine.redo();try engine.flush()
    XCTAssertEqual(try repository.load(destination.id).objects,plan.project.objects)
  }
  func testPageGuideFastPathNeverHidesACharacterPositionSourceEdit()throws {
    var source=Project(name:"Exact source comparison"),frame=try source.makeObject(recipeID:"artboard",parameters:["width":200,"depth":150])
    var text=ArtworkElement(kind:"text",x:10,y:10,text:"Original",fontSize:36);text.typography=Typography();frame.artwork=Artwork(elements:[text]);source.objects=[frame]
    var guides=source;guides.objects[0].artwork!.bleed=3;guides.objects[0].artwork!.safeInset=7
    XCTAssertTrue(ArtworkPageSetup.containsOnlyPageSetupChanges(source,guides))
    var positioned=guides;positioned.objects[0].artwork!.elements[0].typography!.characterPosition = .superscript
    XCTAssertFalse(ArtworkPageSetup.containsOnlyPageSetupChanges(source,positioned));XCTAssertFalse(ArtworkPageSetup.containsOnlyPageSetupChanges(guides,positioned))
    XCTAssertNotEqual(source.objects[0].artwork!.renderDefinition,positioned.objects[0].artwork!.renderDefinition)
    XCTAssertEqual(source.objects[0].artwork!.renderDefinition,guides.objects[0].artwork!.renderDefinition)
  }
}
