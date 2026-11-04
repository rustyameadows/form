import AppKit
import FormCore
import FormGeometry
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class CyclesLightingRigTests:XCTestCase {
  private func scene(studio:Bool=true,preset:String="classic-v1")throws->TableSceneController {
    _=NSApplication.shared
    var project=Project(name:"Lighting workflow")
    project.objects=[try project.makeObject(recipeID:"box")]
    let scene=TableSceneController()
    scene.sync(project,selection:[],isolated:[],showGrid:false,studio:studio,preset:"Paper",assets:FileManager.default.temporaryDirectory)
    scene.applyShotLighting(preset,studio:studio)
    return scene
  }
  private func assertLights(_ a:[SceneAreaLight],_ b:[SceneAreaLight],file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertEqual(a.count,b.count,file:file,line:line)
    for (x,y) in zip(a,b) {
      XCTAssertEqual(x.power,y.power,accuracy:1e-12,file:file,line:line)
      XCTAssertEqual(x.sizeMM,y.sizeMM,file:file,line:line)
      XCTAssertEqual(x.color,y.color,file:file,line:line)
      XCTAssertEqual(x.shape,y.shape,file:file,line:line)
      for column in 0..<4 {XCTAssertLessThan(simd_length(x.transform[column]-y.transform[column]),1e-8,file:file,line:line)}
    }
  }
  func testCurrentTableAndEachStudioPresetSurviveConversionInActualSnapshot()async throws {
    for (studio,preset) in [(false,"rim-v1"),(true,"classic-v1"),(true,"soft-side-v1"),(true,"rim-v1")] {
      let scene=try scene(studio:studio,preset:preset),settings=CyclesRenderSettings()
      scene.camera.target = .init(33,19,-71);scene.camera.distance=5;scene.updateCamera()
      let before=try await scene.cyclesSnapshot(settings:settings)
      let editable=try scene.cyclesLightingPreset().makeEditable(settings)
      let after=try await scene.cyclesSnapshot(settings:editable)
      assertLights(before.lights,after.lights)
      XCTAssertEqual(before.environment.color,after.environment.color,"Default white retains exact preset tint.")
      XCTAssertEqual(before.environment.strength,after.environment.strength)
      XCTAssertEqual(before.camera.worldFromCameraMM,after.camera.worldFromCameraMM)
      XCTAssertEqual(before.renderables.map(\.mesh.revision),after.renderables.map(\.mesh.revision))
      XCTAssertEqual(editable.areaLights?.map(\.sizeMM),[.init(500,500),.init(700,700)])
      scene.applyShotLighting("soft-side-v1",studio:true)
      let later=try await scene.cyclesSnapshot(settings:editable)
      assertLights(after.lights,later.lights)
      XCTAssertEqual(after.environment.color,later.environment.color)
      XCTAssertEqual(after.environment.strength,later.environment.strength)
    }
  }
  func testArbitraryAmbientTintRoundsToNearestAuthoredByteAndPreservesPowerAndMap()throws {
    let scene=try scene(preset:"soft-side-v1"),preset=scene.cyclesLightingPreset()
    var settings=CyclesRenderSettings();settings.environmentColor="#3B84D9";settings.environmentStrength=0.37
    settings.environmentRotationDegrees=123
    settings.environmentTexture = .init(asset:"environment.exr",sha256:String(repeating:"a",count:64),colorSpace:.linearSRGB)
    let editable=try preset.makeEditable(settings),resolved=preset.resolve(editable)
    func decode(_ byte:Int)->Double {let x=Double(byte)/255;return x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
    func encode(_ value:Double)->Double {value<=0.0031308 ? value*12.92:1.055*pow(value,1/2.4)-0.055}
    let original=[59,132,217],ambient=[247,247,242]
    let expected=zip(original,ambient).map{Int((encode(decode($0)*decode($1))*255).rounded())}
    XCTAssertEqual(editable.environmentColor,String(format:"#%02X%02X%02X",expected[0],expected[1],expected[2]))
    for index in 0..<3 {
      XCTAssertLessThanOrEqual(abs(encode(Double(resolved.environment.color[index]))-encode(decode(original[index])*decode(ambient[index]))),0.5/255+1e-6)
    }
    XCTAssertEqual(editable.environmentStrength,0.37*250/400,accuracy:1e-15)
    XCTAssertEqual(editable.environmentRotationDegrees,123)
    XCTAssertEqual(editable.environmentTexture,settings.environmentTexture)
  }
  func testAddRetainsPresetAndExistingAuthoredLightsAndHiddenState()throws {
    let scene=try scene(preset:"rim-v1"),preset=scene.cyclesLightingPreset(),settings=CyclesRenderSettings()
    let added=try preset.makeEditable(settings,addingLight:true)
    XCTAssertEqual(added.areaLights?.count,3)
    assertLights(preset.resolve(settings).lights,Array(preset.resolve(added).lights.prefix(2)))
    XCTAssertEqual(added.areaLights?.last?.powerWatts,3)
    let next=try preset.makeEditable(added,addingLight:true)
    XCTAssertEqual(Array(next.areaLights!.prefix(3)),added.areaLights!)
    XCTAssertEqual(next.environmentColor,added.environmentColor)
    XCTAssertEqual(next.environmentStrength,added.environmentStrength)
    scene.keyLight.isHidden=true
    let ambient=try XCTUnwrap(scene.scene.rootNode.childNodes.first{$0.light?.type == .ambient});ambient.isHidden=true
    let hidden=try scene.cyclesLightingPreset().makeEditable(settings)
    XCTAssertEqual(hidden.areaLights?.count,1);XCTAssertEqual(hidden.environmentStrength,0)
    XCTAssertEqual(hidden.areaLights?.first?.positionMM,.init(600,600,-600))
  }
  func testLegacyCustomLightsRemainIndependentAndConversionRejectsOverflowOrRoll()throws {
    let scene=try scene(preset:"soft-side-v1"),preset=scene.cyclesLightingPreset()
    var malformed=CyclesRenderSettings();malformed.environmentColor="not a color"
    XCTAssertThrowsError(try preset.makeEditable(malformed))
    XCTAssertEqual(malformed.environmentColor,"not a color");XCTAssertNil(malformed.areaLights)
    var custom=CyclesRenderSettings();custom.areaLights=[.init()];custom.areaLights?[0].shape = .disk
    custom.environmentColor="#2468AC";custom.environmentStrength=0.73
    XCTAssertEqual(try preset.makeEditable(custom),custom)
    let resolved=preset.resolve(custom)
    XCTAssertEqual(resolved.environment.color,LabCyclesRuntime.color(custom.environmentColor))
    XCTAssertEqual(resolved.environment.strength,0.73);XCTAssertEqual(resolved.lights[0].shape,.disk)
    var excessive=preset;excessive.ambientStrength=2
    var settings=CyclesRenderSettings();settings.environmentStrength=1000
    XCTAssertThrowsError(try excessive.makeEditable(settings)) {error in XCTAssertTrue(error.localizedDescription.contains("environment strength"))}
    XCTAssertNil(settings.areaLights);XCTAssertEqual(settings.environmentStrength,1000)
    var rolled=preset
    let q=simd_double4x4(simd_quatd(angle:0.2,axis:.init(0,0,1)))
    rolled.lights[0].transform=rolled.lights[0].transform*q
    XCTAssertThrowsError(try rolled.makeEditable(.init()))
  }
  func testPresetEditableRoundTripsRestoreOriginalAmbientWithoutAccumulatedTint()throws {
    let preset=try scene(preset:"soft-side-v1").cyclesLightingPreset()
    var original=CyclesRenderSettings();original.environmentColor="#3B84D9";original.environmentStrength=0.37
    var settings=original,draft=CyclesLightingConversionDraft()
    for _ in 0..<3 {
      settings=try draft.makeEditable(settings,using:preset,addingLight:true)
      XCTAssertEqual(settings.areaLights?.count,3)
      XCTAssertNotEqual(settings.environmentColor,original.environmentColor)
      settings=try draft.makeEditable(settings,using:preset,addingLight:true)
      settings=draft.usePreset(settings)
      XCTAssertEqual(settings,original)
    }
    // Existing saved custom settings have no conversion provenance: selecting
    // a preset retains their authored environment, matching legacy behavior.
    var custom=original;custom.areaLights=[.init()]
    var reopened=CyclesLightingConversionDraft()
    XCTAssertEqual(reopened.usePreset(custom),original)
  }
  func testNativeTableApplyPersistsOneUndoWithoutEditingCameraOrObjects()throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("lighting-draft-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var project=Project(name:"Lighting persistence");project.objects=[try project.makeObject(recipeID:"box")]
    project.renderSettings = .init();store.engine.project=project;store.scene=TableSceneController(store:store);store.synchronizeScene()
    let before=try XCTUnwrap(store.project),source=try XCTUnwrap(store.scene)
    let editable=try source.cyclesLightingPreset().makeEditable(try XCTUnwrap(before.renderSettings),addingLight:true)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty,"Draft conversion does not commit.")
    store.setTableRenderSettings(editable)
    XCTAssertNil(store.error);XCTAssertEqual(store.project?.renderSettings,editable);XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertEqual(store.project?.camera,before.camera);XCTAssertEqual(store.project?.objects,before.objects)
    let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(try XCTUnwrap(store.project)))
    XCTAssertEqual(decoded.renderSettings,editable)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
}
