import AppKit
import CoreText
import XCTest
@testable import FormGraphics

@MainActor final class FontFamilyCatalogTests:XCTestCase {
  func testInstalledFamiliesPartitionFacesWithoutBuildingSpecimenPreviews()throws {
    FontLibraryCatalog.invalidate()
    let builds=try XCTUnwrap(FontLibraryCatalog.diagnostics["preview_builds"] as? Int)
    let faces=FontLibraryCatalog.faces,families=FontLibraryCatalog.families
    XCTAssertGreaterThan(families.count,10)
    XCTAssertEqual(Set(families.map(\.name)).count,families.count)
    XCTAssertEqual(Set(families.flatMap(\.faces).map(\.name)),Set(faces.map(\.name)))
    XCTAssertEqual(families.reduce(0){$0+$1.faces.count},faces.count)
    XCTAssertEqual(FontLibraryCatalog.diagnostics["preview_builds"] as? Int,builds)
    let family=try XCTUnwrap(FontLibraryCatalog.family(named:"Georgia"))
    XCTAssertEqual(family.representative()?.name,"Georgia")
    XCTAssertEqual(family.representative(preserving:FontLibraryCatalog.face(named:"Georgia-BoldItalic"))?.name,"Georgia-BoldItalic")
    XCTAssertEqual(FontLibraryCatalog.searchFamilies("Georgia Bold").map(\.name),["Georgia"])
  }
  func testCoreTextTraitsIdentifyInstalledMonoAndVariableFacesWithoutNameHeuristics()throws {
    let mono=try XCTUnwrap(FontLibraryCatalog.face(named:"Menlo-Regular"))
    XCTAssertTrue(mono.traits.isMonospaced);XCTAssertFalse(mono.traits.isItalic)
    let italic=try XCTUnwrap(FontLibraryCatalog.face(named:"Georgia-BoldItalic"))
    XCTAssertTrue(italic.traits.isItalic);XCTAssertTrue(italic.traits.isBold)
    for name in ["Georgia","Helvetica","Zapfino","Skia"] {
      guard let face=FontLibraryCatalog.face(named:name),let native=NSFont(name:name,size:12) else{continue}
      let font=native as CTFont,classification=(CTFontGetSymbolicTraits(font).rawValue >> 28) & 15
      let expected:InstalledFontTraits.Classification
      switch classification {case 1...5,7:expected = .serif;case 8:expected = .sans;case 10:expected = .script;default:expected = .unknown}
      XCTAssertEqual(face.traits.classification,expected)
      XCTAssertEqual(face.traits.isVariable,!(CTFontCopyVariationAxes(font) as? [Any] ?? []).isEmpty)
      XCTAssertTrue(face.traits.weight.isFinite && face.traits.width.isFinite && face.traits.slant.isFinite)
    }
  }
  func testLargePreviewKeepsExactFaceAndSizeWithoutAliasingSmallCachedSpecimen()throws {
    let before=try XCTUnwrap(FontLibraryCatalog.diagnostics["preview_builds"] as? Int)
    let large=try XCTUnwrap(FontLibraryCatalog.preview("Georgia-BoldItalic",size:96))
    let small=try XCTUnwrap(FontLibraryCatalog.preview("Georgia-BoldItalic",size:18))
    XCTAssertEqual(large.fontName,"Georgia-BoldItalic");XCTAssertEqual(large.pointSize,96)
    XCTAssertEqual(small.pointSize,18);XCTAssertFalse(large===small)
    XCTAssertTrue(FontLibraryCatalog.preview("Georgia-BoldItalic",size:96)===large)
    XCTAssertLessThanOrEqual((FontLibraryCatalog.diagnostics["preview_builds"] as? Int ?? 0)-before,2)
    for size in [Double.nan,Double.infinity,0,-1,513] {XCTAssertNil(FontLibraryCatalog.preview("Georgia",size:size))}
  }
  func testInstalledAliasResolutionKeepsMissingNamesAndBuildsNoSpecimenPreviews()throws {
    FontLibraryCatalog.invalidate()
    let before=try XCTUnwrap(FontLibraryCatalog.diagnostics["preview_builds"] as? Int)
    let native=try XCTUnwrap(NSFont(name:"Skia",size:12))
    let exact=try XCTUnwrap(FontLibraryCatalog.faces.first{$0.name==native.fontName})
    for _ in 0..<3 {
      XCTAssertEqual(FontLibraryCatalog.face(named:"Skia"),exact)
      XCTAssertEqual(FontLibraryCatalog.canonicalName("Skia"),native.fontName)
      XCTAssertEqual(FontLibraryCatalog.face(named:native.fontName),exact)
      XCTAssertNil(FontLibraryCatalog.face(named:"FORM Definitely Missing Typeface"))
      XCTAssertEqual(FontLibraryCatalog.canonicalName("FORM Definitely Missing Typeface"),"FORM Definitely Missing Typeface")
    }
    XCTAssertEqual(FontLibraryCatalog.diagnostics["preview_builds"] as? Int,before)
    FontLibraryCatalog.invalidate()
    XCTAssertEqual(FontLibraryCatalog.canonicalName("Skia"),native.fontName)
  }
}
