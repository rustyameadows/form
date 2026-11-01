import AppKit
import FormCore
import FormGeometry
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class PaperPreviewPerformanceTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  private func fixture(copies:Int=12)throws->Project {
    var project=Project(name:"Repeated printed cartons")
    var object=try project.makeObject(recipeID:"tuckCarton")
    object.artwork = .init(background:"#BC5033",elements:[.init(kind:"rectangle",x:2,y:2,width:12,height:12,color:"#173725")])
    var definition=try PaperConstruction.definition(for:object)
    definition.insideArtwork = .init(background:"#E9DFB4",elements:[.init(kind:"ellipse",x:8,y:8,width:10,height:10,color:"#426DB2")])
    object.paperConstruction=definition
    project.objects=(0..<copies).map { index in
      var copy=object;copy.id=UUID();copy.name="Copy \(index)";copy.position.x=Double(index)*130
      copy.rotation=Double(index)*5;copy.parameters["opening"]=Double(index%3)*45
      return copy
    }
    return project
  }
  private func panels(_ node:MeshNode)->[MeshNode] {
    var result:[MeshNode]=[]
    node.enumerateChildNodes { child, _ in
      if child.name?.hasPrefix(PaperGeometry.panelPrefix)==true { result.append(child) }
    }
    return result
  }
  private func panel(_ node:MeshNode,_ id:String="front")throws->MeshNode {
    try XCTUnwrap(panels(node).first{$0.name==PaperGeometry.panelPrefix+id})
  }
  private func sync(_ project:Project,_ stage:TableSceneController,selection:Set<UUID>=[],sampling:[UUID:SourceTextureSamplingPlan]=[:]) {
    stage.sync(project,selection:selection,isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:assets,textureLimit:128,sourceSampling:sampling)
  }

  func testRepeatedPaperInstancesShareBuffersWithIndependentPoseAndNoCopiedSelection()throws {
    var project=try fixture(),saved=project
    let stage=TableSceneController();stage.showsStudioSelection=true
    let preparations=PaperSurfaceRasterizer.sourcePreparations
    sync(project,stage,selection:[project.objects[0].id])
    XCTAssertEqual(stage.paperSourceBuilds,1)
    XCTAssertEqual(stage.paperTemplateReuses,project.objects.count-1)
    XCTAssertEqual(PaperSurfaceRasterizer.sourcePreparations-preparations,2,"Prepare each face once, not once per panel or copy")
    let first=try XCTUnwrap(stage.logicalNode(for:project.objects[0].id)),firstPanel=try panel(first)
    let mesh=try XCTUnwrap(firstPanel.geometry)
    for (index,object) in project.objects.enumerated() {
      let node=try XCTUnwrap(stage.logicalNode(for:object.id))
      XCTAssertTrue(try panel(node).geometry === mesh)
      XCTAssertEqual(node.position.x,object.position.x/100,accuracy:1e-8)
      XCTAssertEqual(node.childNodes.filter{$0.name=="selection"}.count,index==0 ? 1:0)
    }
    let firstTop=try panel(first,"top-tuck")
    let secondTop=try panel(XCTUnwrap(stage.logicalNode(for:project.objects[1].id)),"top-tuck")
    let closed=firstTop.transform.raw,opened=secondTop.transform.raw
    XCTAssertTrue((0..<4).contains{column in (0..<4).contains{row in closed[column,row] != opened[column,row]}},"Each copy retains its independent opening pose")
    let vertices=try XCTUnwrap(mesh.sources(for:.vertex).first).vectors
    let stock=try PaperConstruction.definition(for:project.objects[0]).stock.resolvedThicknessMM
    XCTAssertEqual((vertices.map(\.z).max()!-vertices.map(\.z).min()!)*100,stock,accuracy:1e-8)
    XCTAssertEqual(project,saved)

    let reused=stage.paperTemplateReuses,textures=PaperGeometry.textureBuilds
    project.objects=project.objects.map { source in
      var copy=source;copy.id=UUID();copy.name="Returned "+source.name;copy.position.z+=70;return copy
    }
    saved=project
    sync(project,stage)
    XCTAssertEqual(stage.paperTemplateReuses-reused,project.objects.count,"A scene switch may reuse the previous live source buffers")
    XCTAssertEqual(PaperGeometry.textureBuilds,textures)
    for object in project.objects {
      let node=try XCTUnwrap(stage.logicalNode(for:object.id))
      XCTAssertTrue(try panel(node).geometry === mesh)
      XCTAssertFalse(node.childNodes.contains{$0.name=="selection"},"Selection adornments are never part of a paper template")
    }
    XCTAssertEqual(project,saved)
  }

  func testPaperReuseInvalidatesForInsideInkStockMaterialAndOutputSampling()throws {
    var project=try fixture(copies:3)
    let stage=TableSceneController();sync(project,stage)
    let unchangedID=project.objects[1].id,changedID=project.objects[0].id
    let unchanged=try panel(XCTUnwrap(stage.logicalNode(for:unchangedID)))
    let original=try XCTUnwrap(unchanged.geometry)
    project.objects[0].paperConstruction?.insideArtwork?.background="#113399"
    sync(project,stage)
    let recolored=try panel(XCTUnwrap(stage.logicalNode(for:changedID)))
    XCTAssertFalse(recolored.geometry === original,"Inside ink is a real dependency even when outside artwork is identical")
    let oldInside=try XCTUnwrap(original.materials[1].diffuse.contents as? NSImage)
    let newInside=try XCTUnwrap(recolored.geometry?.materials[1].diffuse.contents as? NSImage)
    XCTAssertNotEqual(oldInside.tiffRepresentation,newInside.tiffRepresentation)
    XCTAssertTrue(try panel(XCTUnwrap(stage.logicalNode(for:unchangedID))).geometry === original)

    let oldMesh=try XCTUnwrap(recolored.geometry)
    project.objects[0].parameters["stock"]=0.9
    sync(project,stage)
    let thicker=try XCTUnwrap(panel(XCTUnwrap(stage.logicalNode(for:changedID))).geometry)
    XCTAssertFalse(thicker === oldMesh)
    let vertices=try XCTUnwrap(thicker.sources(for:.vertex).first).vectors
    XCTAssertEqual((vertices.map(\.z).max()!-vertices.map(\.z).min()!)*100,0.9,accuracy:1e-8)
    project.objects[0].color="#445566"
    sync(project,stage)
    XCTAssertFalse(try panel(XCTUnwrap(stage.logicalNode(for:changedID))).geometry === thicker)

    let beforeSampling=try XCTUnwrap(panel(XCTUnwrap(stage.logicalNode(for:unchangedID))).geometry)
    let sample=SourceTextureSamplingPlan(raster:.init(maximumEdge:256,maximumPixels:65_536))
    sync(project,stage,sampling:[unchangedID:sample])
    let sampled=try XCTUnwrap(panel(XCTUnwrap(stage.logicalNode(for:unchangedID))).geometry)
    XCTAssertFalse(sampled === beforeSampling,"Final/explicit surface allocations cannot reuse a different preview template")
    let standard=try XCTUnwrap(beforeSampling.materials[0].diffuse.contents as? NSImage)
    let larger=try XCTUnwrap(sampled.materials[0].diffuse.contents as? NSImage)
    XCTAssertGreaterThan(larger.size.width*larger.size.height,standard.size.width*standard.size.height)
  }

  func testPreparedFaceMatchesUnpreparedPixelsAndRejectsStaleSourceOrFinish()throws {
    let element=ArtworkElement(kind:"rectangle",x:2,y:2,width:10,height:10,color:"#A34022")
    let artwork=Artwork(background:"#FFFFFF",elements:[element])
    let finish=PaperFinishAssignment(name:"Foil",kind:.foil,elementIDs:[element.id],color:"#D8A32D",roughness:0.18)
    let profile=PaperSurfaceProfile(texture:.smooth,roughness:0.9,textureDepthMM:0)
    func make(_ art:Artwork,_ finishes:[PaperFinishAssignment],x:Double=0,prepared:PaperSurfaceRasterizer.PreparedArtwork?=nil)throws->PaperSurfaceRasterizer.Maps {
      try PaperSurfaceRasterizer.make(rect:.init(x:x,y:0,width:20,height:20),netSize:.init(40,20),profile:profile,color:"#FFFFFF",grain:.unknown,artwork:art,finishes:finishes,assets:assets,maximumEdge:128,pixelBudget:16_384,preparedArtwork:prepared)
    }
    let expected=try make(artwork,[finish])
    let prepared=try PaperSurfaceRasterizer.PreparedArtwork(artwork,finishes:[finish],assets:assets)
    let preparations=PaperSurfaceRasterizer.sourcePreparations
    let actual=try make(artwork,[finish],prepared:prepared)
    XCTAssertEqual(actual.revision,expected.revision)
    for (a,b) in [(actual.color,expected.color),(actual.normal,expected.normal),(actual.roughness,expected.roughness),(actual.metallic,expected.metallic)] {
      XCTAssertEqual(a.tiffRepresentation,b.tiffRepresentation)
    }
    _ = try make(artwork,[finish],x:20,prepared:prepared)
    XCTAssertEqual(PaperSurfaceRasterizer.sourcePreparations,preparations)
    var changed=artwork;changed.elements[0].x=22
    let moved=try make(changed,[finish],prepared:prepared)
    XCTAssertNotEqual(moved.revision,actual.revision)
    XCTAssertNotEqual(moved.color.tiffRepresentation,actual.color.tiffRepresentation)
    let unfoiled=try make(artwork,[],prepared:prepared)
    XCTAssertNotEqual(unfoiled.revision,actual.revision)
    XCTAssertNotEqual(unfoiled.metallic.tiffRepresentation,actual.metallic.tiffRepresentation)
  }
}
