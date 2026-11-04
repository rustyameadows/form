import Foundation
import FormCADModel
import XCTest
@testable import FormCore

@MainActor final class SheetAssemblyClosedBoundsTests:XCTestCase {
  private func fixture()throws->(Project,UUID) {
    var project=Project(name:"Native physical envelope authority"),pages=[UUID]()
    for _ in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140]);page.artwork = .init(elements:[],bleed:0)
      project.objects.append(page);pages.append(page.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Ordered canonical pages",pages:pages)
    let profile=SheetPanelNeutralCurve(points:[.init(0,0),.init(8,10),.init(22,10),.init(30,0)],fitLength:true)
    let curved=SheetAssemblyPlane(id:"arched",name:"Curved generic reinforcement",size:.init("bridgeLength",20),
      positionMM:.init(-40,30,100),stock:.init(thicknessMM:1),features:.init(wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:2),
        flex:.init(widthMM:"bridgeLength",curve:profile)))
    let remote=SheetAssemblyPlane(id:"far",name:"Separate enclosure",size:.init(12,12),positionMM:.init(180,0,0),stock:.init(thicknessMM:0.2))
    let definition=SheetAssemblyDefinition(publicationID:publication,openingDegrees:95,activeSpread:1,bendMM:1,
      enclosure:[curved,remote],binding:.init(style:.sewn,flexWidthMM:8),derived:["bridgeLength":"bindingFlexWidth*4.5"])
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition,position:.init(321,41,-81))
    return(project,id)
  }
  func testClosedCoordinatesUseNativeAliasCurveAndWrapCaliperAuthorityRatherThanPlaneCornerApproximation()throws {
    let(project,id)=try fixture(),object=try XCTUnwrap(project.objects.first{$0.id==id})
    let resolved=try project.resolvedSheetAssembly(object),bounds=try XCTUnwrap(resolved.closedBoundsMM)
    XCTAssertEqual(bounds.maximum.z,108.1,accuracy:1e-5,"The cubic's interior7.5mm rise plus0.6mm actual core/wrap half-caliper lies beyond every undeformed plane corner.")
    XCTAssertEqual(bounds.minimum.z,-70,accuracy:1e-10)
    XCTAssertEqual(bounds.maximum.y,30.1,accuracy:1e-8)
    XCTAssertEqual(resolved.closedWidth,bounds.maximum.x-bounds.minimum.x,accuracy:1e-10)
    XCTAssertEqual(resolved.closedHeight,bounds.maximum.z-bounds.minimum.z,accuracy:1e-10)
    XCTAssertEqual(resolved.closedThickness,bounds.maximum.y-bounds.minimum.y,accuracy:1e-10)
    var closed=object;closed.sheetAssembly?.openingDegrees=0;closed.sheetAssembly?.bendMM=0;closed.position = .init()
    XCTAssertEqual(try project.resolvedSheetAssembly(closed).closedBoundsMM,bounds,"Rest bounds exclude presentation pose and source object placement.")
  }
  func testPublicInspectionExposesCompleteClosedCoordinatesIndependentlyOfEnclosurePaginationWithoutMutation()throws {
    let(project,id)=try fixture()
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("sheet-closed-bounds-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=project
    let generation=engine.projectGeneration
    let object=try XCTUnwrap(project.objects.first{$0.id==id}),native=try XCTUnwrap(project.resolvedSheetAssembly(object).closedBoundsMM)
    for offset in [0,1] {
      let report=try XCTUnwrap(engine.call("form_publication",arguments:["command":"sheet_assembly_inspect","object_id":id.uuidString,"limit":1,"offset":offset]) as? [String:Any])
      let resolved=try XCTUnwrap(report["resolved"] as? [String:Any]),bounds=try XCTUnwrap(resolved["closed_bounds_mm"] as? [String:[Double]])
      XCTAssertEqual(bounds["minimum_mm"],[native.minimum.x,native.minimum.y,native.minimum.z])
      XCTAssertEqual(bounds["maximum_mm"],[native.maximum.x,native.maximum.y,native.maximum.z])
      XCTAssertEqual((report["enclosure"] as? [String:Any])?["truncated"] as? Bool,true)
    }
    XCTAssertEqual(engine.project,project);XCTAssertEqual(engine.projectGeneration,generation);XCTAssertTrue(engine.undoStack.isEmpty)
    var old=try XCTUnwrap(jsonObject(try project.resolvedSheetAssembly(object)) as? [String:Any]);old.removeValue(forKey:"closedBoundsMM")
    let decoded=try JSONDecoder.form.decode(ResolvedSheetAssembly.self,from:JSONSerialization.data(withJSONObject:old))
    XCTAssertNil(decoded.closedBoundsMM,"Older derived reports retain their optional-data compatibility.")
  }
}
