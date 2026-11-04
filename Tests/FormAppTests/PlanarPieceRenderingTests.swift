import AppKit
import FormCore
import FormCADModel
import FormGeometry
import simd
import XCTest
@testable import FormApp

@MainActor final class PlanarPieceRenderingTests:XCTestCase {
  private func rectangle(_ id:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double)->PlanarPanelDefinition {
    .init(id:id,name:id,polygon:[.init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y+height)),.init(CADScalar(x),CADScalar(y+height))])
  }
  private func object(_ definition:PlanarConstructionDefinition)->ProductObject {
    var object=ProductObject(name:"Independent material assembly",recipeID:"box",parameters:[:],materialID:"paper")
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:200,height:100,depth:2),stock:.init(thicknessMM:2),explosionPercent:0)
    paper.authored=definition;object.paperConstruction=paper;return object
  }
  private func sources()throws->(Project,ProductObject) {
    var project=Project(name:"Canonical piece material sources")
    var ink=ProductObject(name:"Readable ink",recipeID:"artboard",parameters:["width":100,"depth":80],materialID:"paper")
    ink.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:8,y:13,width:4,height:5,color:"#124567")]);ink.artwork?.backgroundOpacity=0
    let cloth=PaperStock(name:"Physical cloth and backing",thicknessMM:0.3,plies:[.init(name:"Backing",color:"#A08050",thicknessMM:0.1),.init(name:"Cloth",color:"#235E40",thicknessMM:0.2)])
    let definition=PlanarConstructionDefinition(name:"Two physical stocks",size:.init(150,80),stockThickness:2,panels:[rectangle("support",0,0,40,30),rectangle("main",70,0,30,30),rectangle("edge",100,0,10,30)],
      hinges:[.init(id:"edge-fold",parentPanelID:"main",childPanelID:"edge",start:.init(100,0),end:.init(100,30),angleDegrees:90)],rootPanelID:"support",components:[
        .init(id:"support-piece",name:"Support",rootPanelID:"support",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),stock:.init(name:"Board",thicknessMM:2)),
        .init(id:"facing-piece",name:"Facing",rootPanelID:"main",anchor:.init(70,0),position:.init(0,2.2,0),rotationDegrees:.init(-90,0,0),stock:cloth,
          front:.init(sourceObjectID:ink.id,sourceOriginMM:.init(5,7)),back:.init(sourceObjectID:ink.id,sourceOriginMM:.init(5,7)),finishes:[])])
    let owner=object(definition);project.objects=[owner,ink];return(project,owner)
  }
  func testConnectedPieceFrontAndReverseShareWholePieceAxesAndCanonicalArtworkIsUnchanged()throws {
    let(project,owner)=try sources(),before=project,definition=try PaperConstruction.definition(for:owner),net=try definition.net()
    let main=try XCTUnwrap(net.panels.first{$0.id=="main"}),edge=try XCTUnwrap(net.panels.first{$0.id=="edge"})
    let a=try PaperGeometry.panelArtwork(main,definition:definition,project:project,outside:nil,inside:nil)
    let b=try PaperGeometry.panelArtwork(edge,definition:definition,project:project,outside:nil,inside:nil)
    let front=try XCTUnwrap(a.outside?.elements.first),secondFront=try XCTUnwrap(b.outside?.elements.first)
    XCTAssertEqual(front.affine?.tx,65);XCTAssertEqual(secondFront.affine?.tx,65)
    XCTAssertEqual(front.width,4);XCTAssertEqual(front.height,5)
    let reverse=try XCTUnwrap(a.inside?.elements.first),secondReverse=try XCTUnwrap(b.inside?.elements.first)
    XCTAssertEqual(reverse.affine?.a,-1);XCTAssertEqual(reverse.affine?.tx,115)
    XCTAssertEqual(secondReverse.affine?.a,-1);XCTAssertEqual(secondReverse.affine?.tx,115,"Every face must use the whole cut-piece reverse axis.")
    XCTAssertEqual(project,before)
    var withOwnerFinish=definition
    withOwnerFinish.finishes=[.init(name:"Owner-only process",kind:.foil,elementIDs:[front.id])]
    let explicitEmpty=try PaperGeometry.panelArtwork(main,definition:withOwnerFinish,project:project,outside:nil,inside:nil)
    XCTAssertTrue(explicitEmpty.outsideFinishes.isEmpty);XCTAssertTrue(explicitEmpty.insideFinishes.isEmpty)
  }
  func testActualPieceCalipersPlyBandsAndCanonicalSourceRevisionReachRegularRenderer()throws {
    _=NSApplication.shared
    var(project,owner)=try sources();let before=project
    let preparations=PaperSurfaceRasterizer.sourcePreparations
    let root=try PaperGeometry.make(owner,project:project,assets:FileManager.default.temporaryDirectory,limit:128)
    XCTAssertEqual(PaperSurfaceRasterizer.sourcePreparations-preparations,2,"The connected faces must share one exact front source and one exact reverse source preparation, rather than prepare both for every panel.")
    func geometry(_ id:String)throws->MeshGeometry {try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+id,recursively:true)?.geometry)}
    func caliper(_ geometry:MeshGeometry)throws->Double {let z=try XCTUnwrap(geometry.sources(for:.vertex).first).vectors.map(\.z);return (try XCTUnwrap(z.max())-XCTUnwrap(z.min()))*100}
    XCTAssertEqual(try caliper(geometry("support")),2,accuracy:1e-8)
    XCTAssertEqual(try caliper(geometry("main")),0.3,accuracy:1e-8)
    XCTAssertEqual(try geometry("main").materials.count,4,"Both real bonded edge plies need distinct physical bands.")
    let revision=PaperGeometry.sourceRevision(owner,project:project)
    owner.paperConstruction?.openingPercent=90;owner.paperConstruction?.explosionPercent=80
    XCTAssertEqual(PaperGeometry.sourceRevision(owner,project:project),revision,"View poses must retain immutable physical buffers.")
    project.objects[1].artwork!.elements[0].color="#998877"
    XCTAssertNotEqual(PaperGeometry.sourceRevision(owner,project:project),revision,"Canonical piece artwork must invalidate the ordinary renderer source key.")
    XCTAssertEqual(before.objects[1].artwork?.elements[0].color,"#124567")
  }
  func testSeventeenConnectedFacesPrepareEachCanonicalPieceSideOnce()throws {
    var project=Project(name:"Shared source preparation across a connected blank")
    var ink=ProductObject(name:"Canonical ink",recipeID:"artboard",parameters:["width":200,"depth":30],materialID:"paper")
    ink.artwork = .init(elements:[.init(kind:"rectangle",x:2,y:3,width:4,height:5,color:"#124567")]);ink.artwork?.backgroundOpacity=0
    let panels=(0..<17).map{rectangle("face-\($0)",Double($0)*10,0,10,20)}
    let hinges=(1..<17).map{index in PlanarHingeDefinition(id:"join-\(index)",parentPanelID:"face-\(index-1)",childPanelID:"face-\(index)",start:.init(CADScalar(Double(index*10)),0),end:.init(CADScalar(Double(index*10)),20),angleDegrees:0)}
    let definition=PlanarConstructionDefinition(name:"Connected physical source",size:.init(200,30),stockThickness:0.3,panels:panels,hinges:hinges,rootPanelID:"face-0",components:[
      .init(id:"one-piece",name:"One actual connected blank",rootPanelID:"face-0",anchor:.init(0,0),position:.init(0,0.15,0),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:0.3),front:.init(sourceObjectID:ink.id),back:.init(sourceObjectID:ink.id))])
    var owner=object(definition);owner.paperConstruction!.stock.thicknessMM=0.3;project.objects=[owner,ink]
    let before=PaperSurfaceRasterizer.sourcePreparations,root=try PaperGeometry.make(owner,project:project,assets:FileManager.default.temporaryDirectory,limit:128)
    XCTAssertEqual(root.childNodes.filter{$0.name?.hasPrefix(PaperGeometry.panelPrefix)==true}.count,17)
    XCTAssertEqual(PaperSurfaceRasterizer.sourcePreparations-before,2,"Seventeen connected faces share one exactly matched preparation for each piece side; their individual raster crops remain independent.")
  }
  private func fastened()throws->(ProductObject,ResolvedPlanarStaple) {
    var definition=PlanarConstructionDefinition(name:"Physical board joint",size:.init(240,140),stockThickness:2,
      panels:[rectangle("first",0,0,100,100),rectangle("second",120,0,80,20)],joins:[.init(id:"joint",name:"Actual receiving edge",firstPanelID:"first",secondPanelID:"second",overlapMM:2)],rootPanelID:"first",components:[
        .init(id:"first-piece",name:"First",rootPanelID:"first",anchor:.init(0,0),position:.init(-50,1,-50),rotationDegrees:.init(-90,0,0),groupID:"frame",stock:.init(thicknessMM:2)),
        .init(id:"second-piece",name:"Second",rootPanelID:"second",anchor:.init(120,20),position:.init(-40,2,0),groupID:"frame",stock:.init(thicknessMM:2))],groups:[.init(id:"frame",name:"Physical parent",position:.init("opening/2","explosion/3",0))])
    definition.jointAttachments=[.init(id:"attachment",joinID:"joint",staples:[.init(id:"wire",entryPanelID:"first",receivingPanelID:"second",anchor:.init(50,50),entrySide:.inside,crownWidthMM:8,wireWidthMM:0.4,wireDepthMM:0.2,legLengthMM:8,minimumReceivingDepthMM:2,tool:"Declared edge driver",installation:.init(order:1,presentComponentIDs:["first-piece","second-piece"]))])]
    let owner=object(definition),wire=try XCTUnwrap(definition.resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    return(owner,wire)
  }
  func testInstalledRectangularWireMeshHasPhysicalSectionClosedCapsAndOneRootGroundingOffset()throws {
    let(owner,wire)=try fastened(),mesh=try PlanarFastenerGeometry.mesh(wire)
    let positions=try XCTUnwrap(mesh.sources(for:.vertex).first).vectors,indices=mesh.elements[0].indices
    XCTAssertEqual(mesh.elements[0].primitiveCount,28)
    var volume=0.0
    for index in stride(from:0,to:indices.count,by:3) {
      let a=positions[Int(indices[index])].simd,b=positions[Int(indices[index+1])].simd,c=positions[Int(indices[index+2])].simd
      volume += simd_dot(a,simd_cross(b,c))/6
    }
    XCTAssertEqual(volume*1_000_000,(8+8+8)*0.4*0.2,accuracy:1e-8,"The closed rectangular sweep must preserve actual wire volume and outward winding.")
    let definition=try PaperConstruction.definition(for:owner),envelope=try PlanarAssemblyEnvelope.resolve(definition)
    var project=Project(name:"Installed wire display");project.objects=[owner]
    let root=try PaperGeometry.make(owner,project:project,assets:FileManager.default.temporaryDirectory,limit:128)
    let node=try XCTUnwrap(root.childNode(withName:PlanarFastenerGeometry.prefix+wire.id,recursively:false))
    XCTAssertEqual(root.position.y,envelope.groundOffsetMM.y/100,accuracy:1e-10)
    let bounds=node.boundingBox
    XCTAssertEqual(bounds.min.y*100+envelope.groundOffsetMM.y,0,accuracy:1e-8)
    try PaperGeometry.updatePose(root,object:owner);try PaperGeometry.updatePose(root,object:owner)
    XCTAssertEqual(root.position.y,envelope.groundOffsetMM.y/100,accuracy:1e-10,"Repeated updates cannot accumulate grounding per piece or fastener.")
    XCTAssertEqual(root.childNodes.filter{$0.name?.hasPrefix(PlanarFastenerGeometry.prefix)==true}.count,1)
  }
  func testCameraSelectionAndPresentationPoseReuseClosedValidationAndWireBuffers()throws {
    let(owner,wire)=try fastened();var project=Project(name:"Immutable physical source during navigation");project.objects=[owner]
    let root=try PaperGeometry.make(owner,project:project,assets:FileManager.default.temporaryDirectory,limit:128)
    let node=try XCTUnwrap(root.childNode(withName:PlanarFastenerGeometry.prefix+wire.id,recursively:false)),geometry=try XCTUnwrap(node.geometry)
    let builds=PaperGeometry.poseSourceBuilds,envelopes=PaperGeometry.closedEnvelopeBuilds,resolutions=PaperGeometry.poseResolutions,validations=PaperGeometry.sourceValidations
    for _ in 0..<12 {try PaperGeometry.updatePose(root,object:owner);try PaperGeometry.updatePose(root,object:owner,selectedPanelID:"first")}
    XCTAssertEqual(PaperGeometry.poseSourceBuilds,builds);XCTAssertEqual(PaperGeometry.closedEnvelopeBuilds,envelopes);XCTAssertEqual(PaperGeometry.poseResolutions,resolutions)
    for _ in 0..<12 {_=try PaperGeometry.renderDefinition(for:owner);_=PaperGeometry.sourceRevision(owner,project:project)}
    XCTAssertEqual(PaperGeometry.sourceValidations,validations,"Stable camera/selection callers must not rerun full source validation.")
    var movedFrame=owner;movedFrame.canvasProjectionPositions=["view":.init(500,600)]
    _=try PaperGeometry.renderDefinition(for:movedFrame);try PaperGeometry.updatePose(root,object:movedFrame)
    XCTAssertEqual(PaperGeometry.sourceValidations,validations);XCTAssertEqual(PaperGeometry.poseSourceBuilds,builds)
    var posed=owner;posed.parameters["opening"]=80;posed.parameters["explosion"]=60
    try PaperGeometry.updatePose(root,object:posed)
    XCTAssertEqual(PaperGeometry.poseSourceBuilds,builds);XCTAssertEqual(PaperGeometry.closedEnvelopeBuilds,envelopes)
    XCTAssertEqual(PaperGeometry.poseResolutions,resolutions+1);XCTAssertTrue(node.geometry === geometry)
    XCTAssertEqual(node.position.x,0.4,accuracy:1e-8);XCTAssertEqual(node.position.y,0.2,accuracy:1e-8)
    let source=try PaperConstruction.definition(for:posed),section=try ConstructionAssemblyDrawings.resolve(source:source,view:.init(id:"wire-section",title:"Actual wire cross section",projection:.front,sectionAxis:.z,sectionOffsetMM:0))
    XCTAssertTrue(section.shapes.contains{$0.panelID==wire.id && $0.closed},"Section drawings must contain the actual rectangular wire material, not omit fasteners.")
    var invalid=owner;invalid.paperConstruction!.authored!.components![0].stockThickness = -1
    XCTAssertThrowsError(try PaperGeometry.renderDefinition(for:invalid),"A changed invalid source must never borrow an accepted cached definition.")
  }
  func testWeakPoseCacheDoesNotRetainAnObsoletePhysicalRenderRoot()throws {
    let(owner,_)=try fastened();var project=Project(name:"Weak render source lifetime");project.objects=[owner]
    var root:MeshNode?=try PaperGeometry.make(owner,project:project,assets:FileManager.default.temporaryDirectory,limit:128)
    weak var observed=root
    XCTAssertNotNil(observed);root=nil;XCTAssertNil(observed)
  }
  func testExplosionUpdatesRegularTableBoundsWithoutRebuildingPhysicalGeometryOrMovingCamera()throws {
    let(owner,_)=try fastened();var project=Project(name:"Presentation bounds remain current");project.objects=[owner]
    let controller=TableSceneController();defer{controller.renderer?.reset()}
    func sync(){controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:FileManager.default.temporaryDirectory,textureLimit:128)}
    sync();let before=try XCTUnwrap(controller.localBounds(for:owner.id)),builds=controller.geometryBuilds,camera=controller.camera
    project.objects[0].parameters["explosion"]=60
    sync();let after=try XCTUnwrap(controller.localBounds(for:owner.id))
    XCTAssertEqual(after.min.y-before.min.y,0.2,accuracy:1e-8)
    XCTAssertEqual(after.max.y-before.max.y,0.2,accuracy:1e-8)
    XCTAssertEqual(controller.geometryBuilds,builds);XCTAssertEqual(controller.camera,camera)
  }
  func testTableHighlightsOnlyExplicitMatchingOwnerWhenTwoAssembliesSharePanelIDs()throws {
    let(first,_)=try fastened();var second=first;second.id=UUID();second.position.x=250
    var project=Project(name:"Independent Table piece selection");project.objects=[first,second]
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    store.engine.project=project;store.engine.selection=[first.id]
    let controller=TableSceneController(store:store)
    defer{controller.renderer?.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    func sync(){controller.sync(project,selection:store.engine.selection,isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:directory,textureLimit:128)}
    func visible(_ ownerID:UUID,_ panelID:String)throws->Bool {
      let root=try XCTUnwrap(controller.logicalNode(for:ownerID))
      let panel=try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+panelID,recursively:true))
      return !(try XCTUnwrap(panel.childNode(withName:PaperGeometry.highlightName,recursively:false))).isHidden
    }
    store.selectPaperPanel(objectID:first.id,panelID:"first");sync()
    XCTAssertTrue(try visible(first.id,"first"));XCTAssertFalse(try visible(second.id,"first"))
    let camera=controller.camera
    store.artworkSession.paperFocusPanelID="second";sync()
    XCTAssertTrue(try visible(first.id,"first"));XCTAssertFalse(try visible(first.id,"second"))
    store.engine.selection=[second.id];sync()
    XCTAssertFalse(try visible(first.id,"first"));XCTAssertFalse(try visible(second.id,"first"),"A panel ID from another assembly must never select this identically named face.")
    store.selectPaperPanel(objectID:second.id,panelID:"second");sync()
    XCTAssertTrue(try visible(second.id,"second"));XCTAssertFalse(try visible(first.id,"second"))
    XCTAssertEqual(controller.camera,camera);XCTAssertEqual(store.engine.selection,[second.id])
    XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(store.project,project)
  }
  func testRealWireAndTapeNodesResolveOwnerScopedTargetsAndIndependentHighlightsWithoutDocumentEdits()throws {
    var(first,wire)=try fastened(),definition=try XCTUnwrap(first.paperConstruction?.authored)
    definition.size = .init(400,140);definition.panels += [rectangle("strip-a",240,0,80,5),rectangle("strip-b",240,5,80,5)]
    definition.hinges=[.init(id:"strip-bend",parentPanelID:"strip-a",childPanelID:"strip-b",start:.init(240,5),end:.init(320,5),angleDegrees:90)]
    definition.components!.append(.init(id:"strip",name:"Physical reinforcement",rootPanelID:"strip-a",anchor:.init(240,5),position:.init(-40,2.15,1.1),rotationDegrees:.init(90,0,0),groupID:"frame",stock:.init(thicknessMM:0.1)))
    let a=PlanarJointSurfaceRegion(polygon:[.init(10.1,51.2),.init(89.9,51.2),.init(89.9,55.9),.init(10.1,55.9)])
    let b=PlanarJointSurfaceRegion(polygon:[.init(120.1,15.2),.init(199.9,15.2),.init(199.9,19.8),.init(120.1,19.8)])
    definition.jointAttachments!.append(.init(id:"tape-attachment",joinID:"joint",tape:.init(componentID:"strip",firstRegion:a,secondRegion:b,widthMM:10,lengthMM:80,bondThicknessMM:0.1,installation:.init(order:2,presentComponentIDs:["first-piece","second-piece","strip"]))))
    first.paperConstruction!.authored=definition;var second=first;second.id=UUID();second.position.x=250
    var project=Project(name:"Explicit joint and fastener targets");project.objects=[first,second]
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false);store.engine.project=project;store.engine.selection=[first.id]
    let controller=TableSceneController(store:store)
    defer{controller.renderer?.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    func sync(){controller.sync(project,selection:store.engine.selection,isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:directory,textureLimit:128)}
    sync();let before=try XCTUnwrap(store.project),camera=controller.camera,canvasID=store.artworkSession.activeFrameID
    let root=try XCTUnwrap(controller.logicalNode(for:first.id)),other=try XCTUnwrap(controller.logicalNode(for:second.id))
    let installed=try XCTUnwrap(root.childNode(withName:PlanarFastenerGeometry.prefix+wire.id,recursively:true)),otherWire=try XCTUnwrap(other.childNode(withName:PlanarFastenerGeometry.prefix+wire.id,recursively:true))
    let target=try XCTUnwrap(controller.constructionTarget(from:installed,objectID:first.id))
    XCTAssertEqual(target.kind,.fastener);XCTAssertEqual(target.jointID,"joint");XCTAssertEqual(target.fastenerDefinitionID,"wire");XCTAssertEqual(target.fastenerInstanceID,"wire:0")
    XCTAssertTrue(store.selectConstructionTarget(objectID:first.id,jointID:target.jointID,fastenerInstanceID:target.fastenerInstanceID));sync()
    XCTAssertFalse(try XCTUnwrap(installed.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)
    XCTAssertTrue(try XCTUnwrap(otherWire.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)
    for panel in ["first","second"] {XCTAssertFalse(try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+panel,recursively:true)?.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)}
    let tapeNode=try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+"strip-a",recursively:true)),tape=try XCTUnwrap(controller.constructionTarget(from:tapeNode,objectID:first.id))
    XCTAssertEqual(tape.kind,.joint);XCTAssertEqual(tape.componentID,"strip");XCTAssertEqual(tape.attachmentID,"tape-attachment")
    XCTAssertTrue(store.selectConstructionTarget(objectID:first.id,jointID:tape.jointID,attachmentID:tape.attachmentID,componentID:tape.componentID));sync()
    XCTAssertTrue(try XCTUnwrap(installed.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)
    XCTAssertFalse(try XCTUnwrap(tapeNode.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)
    let accepted=store.constructionTableTarget
    XCTAssertFalse(store.selectConstructionTarget(objectID:first.id,jointID:"joint",fastenerInstanceID:"wire:999"));XCTAssertEqual(store.constructionTableTarget,accepted)
    XCTAssertTrue(store.selectConstructionTarget(objectID:second.id,jointID:"joint",fastenerDefinitionID:"wire"));sync()
    XCTAssertTrue(try XCTUnwrap(installed.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)
    XCTAssertFalse(try XCTUnwrap(otherWire.childNode(withName:PaperGeometry.highlightName,recursively:false)).isHidden)
    XCTAssertEqual(store.constructionTableTarget?.metadata()["object_id"] as? String,second.id.uuidString)
    XCTAssertEqual(store.artworkSession.activeFrameID,canvasID);XCTAssertEqual(controller.camera,camera)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testActualTableRayPickResolvesInstalledWireInstanceBeforeItsOwner()throws {
    let(owner,wire)=try fastened();var project=Project(name:"Real installed wire ray pick");project.objects=[owner]
    let controller=TableSceneController(),view=TableSceneView(frame:.init(x:0,y:0,width:700,height:600))
    view.controller=controller;controller.view=view
    defer{controller.renderer?.reset()}
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:FileManager.default.temporaryDirectory,textureLimit:128)
    controller.fitAll();controller.camera.elevation = -0.8;controller.camera.azimuth=0;controller.updateCamera();controller.renderScene()
    let root=try XCTUnwrap(controller.logicalNode(for:owner.id)),node=try XCTUnwrap(root.childNode(withName:PlanarFastenerGeometry.prefix+wire.id,recursively:true))
    let a=wire.pointsMM[1],b=wire.pointsMM[2],world=node.convertPosition(.init((a.x+b.x)/200,(a.y+b.y)/200,(a.z+b.z)/200),to:nil)
    let pixel=view.projectPoint(world)
    XCTAssertTrue(pixel.x.isFinite && pixel.y.isFinite)
    let target=try XCTUnwrap(controller.constructionTarget(at:.init(x:pixel.x,y:pixel.y)))
    XCTAssertEqual(target.ownerID,owner.id);XCTAssertEqual(target.fastenerInstanceID,wire.id);XCTAssertEqual(target.jointID,"joint")
  }
}
