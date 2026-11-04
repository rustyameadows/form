import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class SheetPanelFeatureTests:XCTestCase {
  private func profile()->PaperStock {
    .init(thicknessMM:2,plies:[.init(name:"Backing",color:"#EEEEEE",thicknessMM:0.3),.init(name:"Core",color:"#776644",thicknessMM:1.7)])
  }
  func testGenericPanelSharesPlanarHoleValidationAndResolvesCaliperWrapFlexAndSteppedInsert()throws {
    let source=UUID()
    let features=SheetPanelFeatures(
      outline:[.init(4,0),.init(96,0),.init(100,4),.init(100,136),.init(96,140),.init(4,140),.init(0,136),.init(0,4)],
      cutouts:[.init(id:"slot",polygon:[.init(70,20),.init(80,20),.init(80,30),.init(70,30)])],stockThickness:"caliper",
      wrap:.init(stock:.init(thicknessMM:0.1,profile:.init(texture:.linen,color:"#234455")),turnInMM:10,cornerRadiusMM:4),
      flex:.init(edge:.left,widthMM:15,angleDegrees:"angle"),
      recesses:[.init(id:"image-seat",origin:.init(15,20),size:.init(40,50),depthMM:"caliper/3",cornerRadiusMM:3,
        insert:.init(stock:.init(thicknessMM:0.2),face:.init(sourceObjectID:source)))])
    let resolved=try features.resolved(size:.init(100,140),stock:profile(),variables:["caliper":3,"angle":60]) {face,_ in
      face.map{.init(sourceObjectID:$0.sourceObjectID)}
    }
    XCTAssertEqual(resolved.0.resolvedThicknessMM,3,accuracy:1e-12)
    XCTAssertEqual(resolved.0.plies![0].thicknessMM,0.45,accuracy:1e-12)
    XCTAssertEqual(resolved.0.plies![1].thicknessMM,2.55,accuracy:1e-12)
    XCTAssertEqual(resolved.1.cutouts.count,1)
    XCTAssertEqual(resolved.1.wrap?.turnInMM,10);XCTAssertEqual(resolved.1.wrap?.stock.profile?.texture,.linen)
    XCTAssertEqual(resolved.1.flex?.angleDegrees,60)
    XCTAssertEqual(resolved.1.recesses.first?.depthMM,1)
    XCTAssertEqual(resolved.1.recesses.first?.insert?.face?.sourceObjectID,source)
    XCTAssertEqual(try JSONDecoder.form.decode(SheetPanelFeatures.self,from:JSONEncoder.form.encode(features)),features)
  }
  func testRecessRejectsMissingFloorOversizedInsertCrossingHoleAndConcaveOutline()throws {
    func resolved(_ value:SheetPanelFeatures)throws {
      _ = try value.resolved(size:.init(100,140),stock:profile(),variables:[:]){_,_ in nil}
    }
    var value=SheetPanelFeatures(recesses:[.init(id:"pocket",origin:.init(10,10),size:.init(30,40),depthMM:2)])
    XCTAssertThrowsError(try resolved(value),"A recess must retain positive physical floor thickness.")
    value.recesses![0].depthMM=0.5
    value.recesses![0].insert = .init(stock:.init(thicknessMM:0.6))
    XCTAssertThrowsError(try resolved(value),"An insert cannot project above its declared seating depth.")
    value.recesses![0].insert=nil
    value.cutouts=[.init(id:"through-hole",polygon:[.init(15,15),.init(20,15),.init(20,20),.init(15,20)])]
    XCTAssertThrowsError(try resolved(value),"A pocket cannot overlap a through-cut.")
    value.cutouts=nil
    value.outline=[.init(0,0),.init(100,0),.init(100,40),.init(20,40),.init(20,140),.init(0,140)]
    XCTAssertThrowsError(try resolved(value),"A rectangular pocket cannot cross the concave outline.")
    value.outline=nil
    value.recesses=[.init(id:"first",origin:.init(10,10),size:.init(30,40),depthMM:0.5),
      .init(id:"second",origin:.init(20,20),size:.init(30,40),depthMM:0.5)]
    XCTAssertThrowsError(try resolved(value),"Independent stepped seats cannot overlap.")
    value.recesses=nil;value.flex = .init(widthMM:0.1,angleDegrees:180)
    XCTAssertThrowsError(try resolved(value),"A finite-width flex cannot invert the panel caliper.")
  }
  func testEnclosureSourceInventoryIncludesRecessesWithoutInventingArtworkCopies()throws {
    let publication=UUID(),a=UUID(),b=UUID(),c=UUID(),d=UUID()
    let definition=SheetAssemblyDefinition(publicationID:publication,
      enclosure:[.init(id:"part",name:"Layered physical panel",size:.init(100,140),front:.init(sourceObjectID:a),
        features:.init(recesses:[.init(id:"seat",origin:.init(10,10),size:.init(30,40),depthMM:0.2,insert:.init(stock:.init(thicknessMM:0.1),face:.init(sourceObjectID:b)))]))],
      auxiliaryLeaves:[.init(front:.init(sourceObjectID:c))],edgeArtwork:.init(head:.init(sourceObjectID:d)))
    XCTAssertEqual(definition.artworkSourceObjectIDs,[a,b,c,d])
    XCTAssertTrue(definition.requiresAdvancedStructureSchema)
  }
  func testOrdinaryPlanarPanelFeaturesUseSamePhysicalPrimitiveWithoutPublicationAndKeepCanonicalCoordinates()throws {
    let source=UUID()
    let feature=SheetPanelFeatures(outline:[.init(4,0),.init(96,0),.init(100,4),.init(100,136),.init(96,140),.init(4,140),.init(0,136),.init(0,4)],
      cutouts:[.init(id:"local-window",polygon:[.init(10,10),.init(20,10),.init(20,20),.init(10,20)])],
      stockThickness:1.4,wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:8),
      flex:.init(widthMM:8,angleDegrees:"opening"),
      recesses:[.init(id:"inset",origin:.init(40,30),size:.init(30,40),depthMM:0.5,
        insert:.init(stock:.init(thicknessMM:0.2),face:.init(sourceObjectID:source)))])
    let panel=PlanarPanelDefinition(id:"part",name:"Unnumbered structural panel",polygon:[.init(10,20),.init(110,20),.init(110,160),.init(10,160)],features:feature)
    var definition=PlanarConstructionDefinition(name:"Generic layered shell",size:.init(120,180),panels:[panel],rootPanelID:"part")
    let net=try definition.net(),resolved=try XCTUnwrap(net.panels.first)
    XCTAssertEqual(resolved.bounds.x,10);XCTAssertEqual(resolved.bounds.y,20)
    XCTAssertEqual(resolved.bounds.width,100);XCTAssertEqual(resolved.bounds.height,140)
    XCTAssertEqual(resolved.cutouts?.first?.polygon.first,Point2(20,30))
    XCTAssertEqual(resolved.features,feature,"Raw expressions remain canonical; numeric feature geometry is derived with the actual material.")
    XCTAssertTrue(definition.requiresAdvancedPanelFeaturesSchema)
    XCTAssertEqual(definition.featureArtworkSourceObjectIDs,[source])
    XCTAssertEqual(try JSONDecoder.form.decode(PlanarConstructionDefinition.self,from:JSONEncoder.form.encode(definition)),definition)
    definition.panels[0].features!.recesses![0].depthMM=2
    XCTAssertThrowsError(try definition.net(),"Ordinary planar constructions enforce the same positive recess floor as publication enclosure panels.")
  }
  func testWrappedPanelRequiresTrueNeighboringSourcePixelsForSidewallsAndTurnIns()throws {
    var project=Project(name:"Wrap registration")
    var page=try project.makeObject(recipeID:"artboard",name:"Canonical page",parameters:["width":100,"depth":140])
    page.artwork = .init(background:"#FFFFFF",elements:[],bleed:0);project.objects.append(page)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Single source",pages:[page.id])
    var wrapSource=try project.makeObject(recipeID:"artboard",name:"Physical wrap sheet",parameters:["width":124,"depth":164])
    wrapSource.artwork = .init(background:"#FFFFFF",elements:[],bleed:0);project.objects.append(wrapSource)
    let front=SheetAssemblyFace(sourceObjectID:wrapSource.id,sourceOriginMM:.init(12,12))
    let plane=SheetAssemblyPlane(id:"core",name:"Wrapped panel",size:.init(100,140),stock:.init(thicknessMM:2),front:front,
      features:.init(wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:10)))
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:[plane]))
    let accepted=project
    var definition=project.objects.first{$0.id==id}!.sheetAssembly!
    definition.enclosure![0].front!.sourceOriginMM = .init(0,0)
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition),"A cap-fitting source must not silently stretch to cover sidewalls/turn-ins.")
    XCTAssertEqual(project,accepted)
  }

  func testRecessLayerMinimumAcceptsExactBoundaryAndRejectsSubminimumDepthFloorAndIntermediateSlab()throws {
    func resolved(_ recesses:[SheetPanelRecess])throws {
      _ = try SheetPanelFeatures(recesses:recesses).resolved(size:.init(100,140),stock:profile(),variables:[:]){_,_ in nil}
    }
    let first=SheetPanelRecess(id:"first",origin:.init(10,10),size:.init(20,20),depthMM:0.01)
    let second=SheetPanelRecess(id:"second",origin:.init(50,50),size:.init(20,20),depthMM:0.02)
    XCTAssertNoThrow(try resolved([first,second]))
    var value=first;value.depthMM=0.0099
    XCTAssertThrowsError(try resolved([value]))
    value.depthMM=1.99
    XCTAssertNoThrow(try resolved([value]),"An exact 0.01 mm retained floor is supported.")
    value.depthMM=1.9901
    XCTAssertThrowsError(try resolved([value]))
    value=second;value.depthMM=0.0199
    XCTAssertThrowsError(try resolved([first,value]),"Independent seat depths still share the panel's physical layer decomposition.")
    value=first;value.insert = .init(stock:.init(thicknessMM:0.01));value.depthMM=0.0101
    XCTAssertNoThrow(try resolved([value]),"Subminimum insert clearance is air, not a synthetic paper layer.")
  }

}
