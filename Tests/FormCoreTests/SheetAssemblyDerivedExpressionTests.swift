import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class SheetAssemblyDerivedExpressionTests:XCTestCase {
  private func fixture()throws->(Project,UUID) {
    var project=Project(name:"Named physical arithmetic"),pages=[UUID]()
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Source \(index)",parameters:["width":100,"depth":140])
      page.artwork=Artwork(elements:[]);project.objects.append(page);pages.append(page.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical run",pages:pages)
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.2)))
    return(project,id)
  }
  func testDerivedGeometryUsesBoundedNamedArithmeticAtClosedPartialAndFullyOpenPoses()throws {
    var(project,id)=try fixture()
    var definition=project.objects.first{$0.id==id}!.sheetAssembly!
    definition.binding = .init(style:.adhesive,flexWidthMM:13)
    definition.derived=["theta":"radians(openingDegrees)","arcAngle":"max(theta,0.000001)",
      "arcX":"bindingFlexWidth*sin(arcAngle)/arcAngle","arcY":"bindingFlexWidth*(1-cos(arcAngle))/arcAngle",
      "panelWidth":"width+6","surfaceY":"stackThickness+arcY"]
    definition.enclosure=[.init(id:"part",name:"Authored physical part",size:.init("panelWidth","height"),
      positionMM:.init("arcX","surfaceY",0),rotationDegrees:.init(0,0,"degrees(theta)"))]
    for angle in [0.0,95,180] {
      definition.openingDegrees=angle;definition.activeSpread=angle==0 ? 0:1
      try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition)
      let object=project.objects.first{$0.id==id}!,resolved=try project.resolvedSheetAssembly(object),part=try XCTUnwrap(resolved.enclosure.first)
      let a=max(angle*Double.pi/180,0.000001)
      XCTAssertEqual(part.size.x,106,accuracy:1e-10)
      XCTAssertEqual(part.positionMM.x,13*sin(a)/a,accuracy:1e-10)
      XCTAssertEqual(part.positionMM.y,0.4+13*(1-cos(a))/a,accuracy:1e-10)
      XCTAssertEqual(part.rotationDegrees.z,angle,accuracy:1e-10)
      XCTAssertEqual(resolved.bindingFlexWidth,13)
      XCTAssertEqual(try project.sheetAssemblyMeasurements(object).bindingFlexWidth,13)
      XCTAssertTrue(definition.requiresAdvancedStructureSchema)
      let decoded=try JSONDecoder.form.decode(SheetAssemblyDefinition.self,from:JSONEncoder.form.encode(definition))
      XCTAssertEqual(decoded.derived,definition.derived)
    }
  }
  func testClosedMeasurementsRecomputeAliasesFromClosedBaseWithoutRequiringSourceCrop()throws {
    let(project,id)=try fixture()
    var object=project.objects.first{$0.id==id}!
    object.sheetAssembly!.derived=["theta":"radians(openingDegrees)","liveX":"20+100*sin(theta)",
      "liveWidth":"width+openingDegrees/10","sourceX":"500+openingDegrees"]
    object.sheetAssembly!.enclosure=[.init(id:"part",name:"Dependent physical panel",size:.init("liveWidth",140),
      positionMM:.init("liveX",0,0),front:.init(sourceObjectID:project.objects[0].id,sourceOriginMM:.init("sourceX",0)))]
    var measurements=[SheetAssemblyMeasurements]()
    for angle in [0.0,95,180] {
      object.sheetAssembly!.openingDegrees=angle
      object.sheetAssembly!.activeSpread=angle==0 ? 0:1
      XCTAssertThrowsError(try project.resolvedSheetAssembly(object),"The real source crop remains invalid rather than silently fitting.")
      measurements.append(try project.sheetAssemblyMeasurements(object))
    }
    XCTAssertEqual(measurements[0],measurements[1]);XCTAssertEqual(measurements[0],measurements[2],
      "Closed dimensions must not retain aliases resolved from the currently open pose.")
    XCTAssertEqual(measurements[0].closedWidth,120,accuracy:1e-10)
    XCTAssertEqual(measurements[0].bindingFlexWidth,0,"A binding without a flex operation contributes no implied hinge width.")
  }
  func testInvalidAliasesRejectAtomicallyForCyclesDomainsUnknownNamesCollisionsAndLimits()throws {
    var(project,id)=try fixture();let accepted=project
    let invalid:[[String:String]]=[
      ["first":"second+1","second":"first+1"],
      ["bad":"sqrt(-1)"],["bad":"1/0"],["bad":"undefinedName+1"],
      ["width":"7"],["bindingFlexWidth":"7"],
      ["bad":"1"+String(repeating:"+1",count:130)],
      Dictionary(uniqueKeysWithValues:(0...256).map{("v\($0)","1")})]
    for expressions in invalid {
      var definition=accepted.objects.first{$0.id==id}!.sheetAssembly!;definition.derived=expressions
      XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition),"Invalid arithmetic must reject before committing any physical dimensions.")
      XCTAssertEqual(project,accepted)
    }
  }
  func testAliasNeededOnlyForClosedEnvelopeStillValidatesItsDomain()throws {
    var(project,id)=try fixture();let accepted=project
    var definition=project.objects.first{$0.id==id}!.sheetAssembly!
    definition.openingDegrees=95;definition.activeSpread=1
    definition.derived=["value":"sqrt(openingDegrees-20)"]
    // Runtime95 is valid, but a rest-envelope evaluation at0 is undefined.
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:id,definition:definition))
    XCTAssertEqual(project,accepted)
  }
}
