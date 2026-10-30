import AppKit
import Combine
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasFrameColorPreferencesTests:XCTestCase {
  private func directory()throws->URL {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("frame-colors-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock {try? FileManager.default.removeItem(at:root)}
    return root
  }
  private func write(_ value:[String:Any],to file:URL)throws {
    try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:file)
  }
  private func ratio(_ a:NSColor,_ b:NSColor)->Double {
    let r=InterfaceAppearance.whiteContrast(a)/InterfaceAppearance.whiteContrast(b)
    return max(r,1/r)
  }
  func testFileRoundTripPreservesEveryPreferenceAndResetDoesNotEditProject()throws {
    _ = NSApplication.shared
    let root=try directory(),file=root.appendingPathComponent("Appearance.json"),prefs=InterfaceAppearance(file:file)
    let store=StudioStore(repository:try ProjectRepository(root:root.appendingPathComponent("Library")),seedLibrary:false)
    store.engine.project=Project(name:"Appearance is not artwork")
    let before=store.project,undo=store.engine.undoStack.count
    try prefs.setFrameColor("  229966 ",for:.artboard)
    try prefs.setFrameColor("#8855AA",for:.construction)
    try prefs.setCanvasBackground("#223344");try prefs.setAccent("#CC5522")
    try prefs.setFrameColor(NSColor(srgbRed:1,green:0.5,blue:0,alpha:1),for:.surface)
    let reopened=InterfaceAppearance(file:file)
    XCTAssertEqual(reopened.frameHex(for:.artboard),"#229966")
    XCTAssertEqual(reopened.frameHex(for:.construction),"#8855AA")
    XCTAssertEqual(reopened.frameHex(for:.surface),"#FF8000")
    XCTAssertEqual(reopened.canvasBackgroundHex,"#223344");XCTAssertEqual(reopened.accentHex,"#CC5522")
    try reopened.resetFrameColors()
    let reset=InterfaceAppearance(file:file)
    for role in CanvasFrameRole.allCases {XCTAssertEqual(reset.frameHex(for:role),role.defaultHex)}
    XCTAssertEqual(reset.accentHex,"#CC5522");XCTAssertEqual(reset.canvasBackgroundHex,"#223344")
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.engine.project=nil
  }
  func testLegacyAndCorruptFrameValuesKeepValidAccentBackgroundAndOtherRoles()throws {
    let file=try directory().appendingPathComponent("Appearance.json")
    try write(["accentHex":"#8822CC"],to:file)
    let legacy=InterfaceAppearance(file:file)
    XCTAssertEqual(legacy.accentHex,"#8822CC")
    for role in CanvasFrameRole.allCases {XCTAssertEqual(legacy.frameHex(for:role),role.defaultHex)}
    try write(["accentHex":"#8822CC","canvasBackgroundHex":"#223344",
      "frameColors":["artboard":"#113355","construction":12,"surface":"invalid","future":"#ABCDEF"]],to:file)
    let partial=InterfaceAppearance(file:file)
    XCTAssertEqual(partial.accentHex,"#8822CC");XCTAssertEqual(partial.canvasBackgroundHex,"#223344")
    XCTAssertEqual(partial.frameHex(for:.artboard),"#113355")
    XCTAssertEqual(partial.frameHex(for:.construction),CanvasFrameRole.construction.defaultHex)
    XCTAssertEqual(partial.frameHex(for:.surface),CanvasFrameRole.surface.defaultHex)
    XCTAssertEqual(partial.frameColors.count,1)
    try write(["accentHex":"#8822CC","canvasBackgroundHex":"#223344","frameColors":[1,2,3]],to:file)
    let corrupt=InterfaceAppearance(file:file)
    XCTAssertEqual(corrupt.accentHex,"#8822CC");XCTAssertEqual(corrupt.canvasBackgroundHex,"#223344")
    for role in CanvasFrameRole.allCases {XCTAssertEqual(corrupt.frameHex(for:role),role.defaultHex)}
    let suite="frame-colors-"+UUID().uuidString,defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
    defer {defaults.removePersistentDomain(forName:suite)}
    defaults.set(["artboard":"#AABBCC","surface":false],forKey:"LAB.canvasFrameColors")
    let app=InterfaceAppearance(defaults:defaults)
    XCTAssertEqual(app.frameHex(for:.artboard),"#AABBCC")
    try app.setAccent("#123456");try app.setCanvasBackground("#FEDCBA")
    XCTAssertEqual(InterfaceAppearance(defaults:defaults).frameHex(for:.artboard),"#AABBCC")
  }
  func testReadableFrameTonesRetainHueAcrossBackgroundsAndInvalidateBoundedCache()throws {
    let prefs=InterfaceAppearance(file:try directory().appendingPathComponent("Appearance.json"))
    let colors=["#FFFF77","#FF3355","#22CCAA"]
    for (role,hex) in zip(CanvasFrameRole.allCases,colors) {try prefs.setFrameColor(hex,for:role)}
    for background in ["#FFFFFF","#000000","#808080","#F2F2F2","#224D47"] {
      try prefs.setCanvasBackground(background)
      let backdrop=NSColor(hex:background)
      for role in CanvasFrameRole.allCases {
        let tone=prefs.frameColor(for:role),source=try XCTUnwrap(NSColor(hex:prefs.frameHex(for:role)).usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(ratio(tone,backdrop),4.5)
        XCTAssertEqual(tone.alphaComponent,1)
        let hue=abs(tone.hueComponent-source.hueComponent)
        XCTAssertLessThan(min(hue,1-hue),1e-5)
        XCTAssertTrue(tone === prefs.frameColor(for:role),"Repeated frames reuse the resolved role/background tone")
        XCTAssertGreaterThanOrEqual(ratio(prefs.frameColor(for:role,against:.white),.white),4.5)
        XCTAssertGreaterThanOrEqual(ratio(prefs.frameColor(for:role,against:.black),.black),4.5)
      }
    }
    let before=prefs.frameColor(for:.artboard)
    try prefs.setFrameColor("#884422",for:.artboard)
    XCTAssertFalse(before === prefs.frameColor(for:.artboard))
  }
  func testInvalidAndFailedWritesDoNotPublishOrChangeAnyPreferences()throws {
    let root=try directory(),file=root.appendingPathComponent("Appearance.json"),prefs=InterfaceAppearance(file:file)
    try prefs.setFrameColor("#449966",for:.artboard)
    let bytes=try Data(contentsOf:file),frames=prefs.frameColors,accent=prefs.accentHex,background=prefs.canvasBackgroundHex
    var published=0
    let subscription=prefs.$frameColors.dropFirst().sink {_ in published+=1}
    defer {subscription.cancel()}
    for value in ["red","#12","#12345678","#GG2211"] {
      XCTAssertThrowsError(try prefs.setFrameColor(value,for:.surface))
      XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    try FileManager.default.removeItem(at:file)
    try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
    XCTAssertThrowsError(try prefs.setFrameColor("#BB5522",for:.surface))
    XCTAssertThrowsError(try prefs.resetFrameColors())
    XCTAssertThrowsError(try prefs.setAccent("#112233"))
    XCTAssertThrowsError(try prefs.setCanvasBackground("#332211"))
    XCTAssertEqual(prefs.frameColors,frames);XCTAssertEqual(prefs.accentHex,accent)
    XCTAssertEqual(prefs.canvasBackgroundHex,background);XCTAssertEqual(published,0)
  }
}
