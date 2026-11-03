import AppKit
import FormCore
import FormGeometry
import simd
import XCTest
@testable import FormApp

@MainActor final class SheetBindingGeometryTests:XCTestCase {
  private func fixture(style:SheetBindingStyle,opening:Double=150)throws->(Project,ProductObject) {
    var project=Project(name:"Source-preserving generic fastening")
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Canonical \(index+1)",parameters:["width":100,"depth":140])
      page.artwork=Artwork(background:"#FFFFFF",elements:[ArtworkElement(kind:"rectangle",x:8,y:12,width:13,height:19,color:index==1 ? "#AA3322":"#225599")])
      project.objects.append(page)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical source order",pages:project.objects.map(\.id))
    let definition=SheetAssemblyDefinition(publicationID:publication,stock:.init(thicknessMM:0.2),openingDegrees:opening,activeSpread:1,
      binding:.init(style:style,positionsMM:[30,110],edgeInsetMM:8,flexWidthMM:10))
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    return(project,project.objects.first{$0.id==id}!)
  }
  func testWireCrownLegsAndClinchesHaveActualBoundedCaliperAndHeadRegistration()throws {
    let(project,object)=try fixture(style:.sideStaple),before=project
    let resolved=try project.resolvedSheetAssembly(object),root=try XCTUnwrap(SheetBindingGeometry.make(resolved))
    XCTAssertEqual(root.childNodes.count,2)
    for (index,node) in root.childNodes.enumerated() {
      let mesh=try XCTUnwrap(node.geometry),p=try XCTUnwrap(mesh.sources(for:.vertex).first?.vectors)
      XCTAssertLessThan(p.count,1024);XCTAssertGreaterThan(mesh.elements[0].indices.count,100)
      let x=p.map{$0.x*100},y=p.map{$0.y*100},z=p.map{$0.z*100}
      XCTAssertEqual(x.min()!,8-0.225,accuracy:0.001);XCTAssertEqual(x.max()!,8+0.225,accuracy:0.001)
      XCTAssertLessThan(y.min()!,0);XCTAssertGreaterThan(y.max()!,resolved.stackThicknessMM)
      XCTAssertEqual((z.min()!+z.max()!)/2,[30.0,110.0][index]-70,accuracy:0.0001)
      XCTAssertEqual(mesh.materials[0].metalness.contents as? Double,0.94)
      for n in mesh.sources(for:.normal).first!.vectors {XCTAssertEqual(simd_length(n.simd),1,accuracy:1e-10)}
    }
    XCTAssertEqual(project,before)
    var none=object;none.sheetAssembly!.binding!.style = .none
    XCTAssertNil(try SheetBindingGeometry.make(project.resolvedSheetAssembly(none)))
  }
  func testSideFlexUsesPinnedMarginUnitNormalsAndDistinctGeometryPoseIdentity()throws {
    var(project,object)=try fixture(style:.sideStaple),before=project
    let resolved=try project.resolvedSheetAssembly(object),revision=SheetAssemblyGeometry.sourceRevision(object,project:project)
    let root=try SheetAssemblyGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:128)
    let panel=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(resolved.leaves[0].id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
    let mesh=try XCTUnwrap(panel.geometry),p=mesh.sources(for:.vertex).first!.vectors,n=mesh.sources(for:.normal).first!.vectors
    let uv=mesh.sources(for:.texcoord).first!.points
    XCTAssertTrue(mesh.name?.hasPrefix("sheet.side-flex:")==true);XCTAssertLessThan(p.count,500_000)
    var pinned=0
    for index in p.indices {
      XCTAssertTrue(p[index].x.isFinite && p[index].z.isFinite)
      XCTAssertEqual(simd_length(n[index].simd),1,accuracy:1e-10)
      if uv[index].x*100<7 {pinned+=1;XCTAssertEqual(p[index].x,uv[index].x,accuracy:1e-8)}
    }
    XCTAssertGreaterThan(pinned,5)
    XCTAssertNotNil(root.childNode(withName:SheetBindingGeometry.name,recursively:true))
    object.sheetAssembly!.openingDegrees=80;project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    XCTAssertNotEqual(SheetAssemblyGeometry.sourceRevision(object,project:project),revision,"Side-margin flex changes actual mesh geometry.")
    XCTAssertEqual(project.objects.filter{$0.id != object.id},before.objects.filter{$0.id != object.id})
    let document=try XCTUnwrap(project.publications?.first)
    XCTAssertEqual(SheetPoseControls.spreadLabel(0,document:document,leaves:resolved.leaves),"Page 1")
    XCTAssertEqual(SheetPoseControls.spreadLabel(1,document:document,leaves:resolved.leaves),"Pages 2–3")
    XCTAssertEqual(SheetPoseControls.spreadLabel(2,document:document,leaves:resolved.leaves),"Page 4")
  }
}
