import XCTest
import FormGraphics
@testable import FormApp

final class FontBrowserModelTests:XCTestCase {
  private func face(_ family:String,_ style:String,_ traits:InstalledFontTraits = .init())->InstalledFontFace {
    .init(name:family+"-"+style.replacingOccurrences(of:" ",with:""),family:family,style:style,traits:traits)
  }
  private var fixture:[InstalledFontFace] {
    [face("Aster","Regular",.init(classification:.serif)),
     face("Aster","Bold",.init(classification:.serif,isBold:true,weight:0.4)),
     face("Aster","Bold Italic",.init(classification:.serif,isItalic:true,isBold:true,weight:0.4,slant:0.2)),
     face("Beryl","Regular",.init(classification:.sans)),
     face("Beryl","Bold Italic",.init(classification:.sans,isItalic:true,isBold:true,weight:0.4,slant:0.2)),
     face("Circuit","Regular",.init(isMonospaced:true)),
     face("Dancer","Regular",.init(classification:.script)),
     face("Elastic","Regular",.init(isVariable:true)),
     face("Sans Mono Script Variable","Regular")]
  }
  func testFamilyRowsAreUniqueAcrossSemanticSectionsAndRetainEveryAvailableFace()throws {
    let model=FontBrowserModel(faces:fixture.reversed(),projectSaved:["Aster-Bold"],projectUsed:["Aster-Regular","Beryl-Regular"],
      studioSaved:["Aster-Regular","Circuit-Regular"],recent:["Beryl-BoldItalic","Dancer-Regular"])
    let sections=model.sections(),rows=sections.flatMap(\.rows)
    XCTAssertEqual(sections.map(\.kind),[.projectSaved,.projectUsed,.studioSaved,.recent,.installed])
    XCTAssertEqual(rows.map(\.id),["Aster","Beryl","Circuit","Dancer","Elastic","Sans Mono Script Variable"])
    XCTAssertEqual(Set(rows.map(\.id)).count,rows.count)
    let aster=try XCTUnwrap(rows.first)
    XCTAssertEqual(aster.face.name,"Aster-Bold","An explicit saved face seeds a family when no current style is available")
    XCTAssertEqual(aster.family.faces.map(\.name),["Aster-Regular","Aster-Bold","Aster-BoldItalic"])
  }
  func testStyleSearchChoosesMatchingFaceWithoutRemovingOtherFamilyStyles()throws {
    let model=FontBrowserModel(faces:fixture)
    let rows=model.sections(query:"  áster   bold  ",currentFace:"Aster-Regular").flatMap(\.rows)
    XCTAssertEqual(rows.count,1)
    let row=try XCTUnwrap(rows.first)
    XCTAssertTrue(row.face.style.contains("Bold"));XCTAssertEqual(row.family.faces.count,3)
    XCTAssertEqual(model.sections(query:"Aster-BoldItalic").flatMap(\.rows).map(\.face.name),["Aster-BoldItalic"])
    XCTAssertTrue(model.sections(query:"Aster nonexistent").isEmpty)
  }
  func testFamilySelectionPreservesExactCurrentFaceThenMatchingStyle()throws {
    let model=FontBrowserModel(faces:fixture)
    let rows=model.sections(currentFace:"Aster-BoldItalic").flatMap(\.rows)
    XCTAssertEqual(rows.first{$0.id=="Aster"}?.face.name,"Aster-BoldItalic")
    XCTAssertEqual(rows.first{$0.id=="Beryl"}?.face.name,"Beryl-BoldItalic")
    let unknownCurrent=model.sections(currentFace:"Uninstalled Face").flatMap(\.rows)
    XCTAssertEqual(unknownCurrent.first{$0.id=="Aster"}?.face.name,"Aster-Regular")
  }
  func testSavedUsedAndRecentRowsChooseOnlyAnExactFaceInTheirOwnCollection() {
    let model=FontBrowserModel(faces:fixture,projectSaved:["Aster-Bold"],projectUsed:["Beryl-BoldItalic"],
      studioSaved:["Aster-Bold"],recent:["Aster-BoldItalic"])
    XCTAssertEqual(model.sections(scope:.studio,currentFace:"Aster-Regular").flatMap(\.rows).map(\.face.name),["Aster-Bold"])
    XCTAssertEqual(model.sections(scope:.project,currentFace:"Aster-Regular").flatMap(\.rows).map(\.face.name),["Aster-Bold","Beryl-BoldItalic"])
    XCTAssertEqual(model.sections(scope:.recent,currentFace:"Aster-Regular").flatMap(\.rows).map(\.face.name),["Aster-BoldItalic"])
    XCTAssertTrue(model.sections(scope:.studio,query:"Regular",currentFace:"Aster-Regular").isEmpty,
      "An unsaved style must not make a saved-family row match the query")
    let all=model.sections(query:"Aster Regular",currentFace:"Aster-Regular")
    XCTAssertEqual(all.map(\.kind),[.installed]);XCTAssertEqual(all.flatMap(\.rows).map(\.face.name),["Aster-Regular"])
  }
  func testProjectStudioAndRecentScopesDoNotLeakIntoEachOther() {
    let model=FontBrowserModel(faces:fixture,projectSaved:["Aster-Bold"],projectUsed:["Beryl-Regular"],studioSaved:["Circuit-Regular"],
      recent:["Dancer-Regular","Aster-Regular","Dancer-Regular"],legacyStudioFamilies:["Elastic"])
    XCTAssertEqual(model.sections(scope:.project).flatMap(\.rows).map(\.id),["Aster","Beryl"])
    XCTAssertEqual(model.sections(scope:.studio).flatMap(\.rows).map(\.id),["Circuit","Elastic"])
    XCTAssertEqual(model.sections(scope:.recent).flatMap(\.rows).map(\.id),["Dancer","Aster"])
    XCTAssertTrue(FontBrowserModel(faces:fixture).sections(scope:.project).isEmpty)
  }
  func testRecentFamilyKeepsNewestExactFaceEvenWhenCurrentStyleMatchesOlderFace() {
    let model=FontBrowserModel(faces:fixture,recent:["Aster-Bold","Aster-Regular","Beryl-BoldItalic"])
    let rows=model.sections(scope:.recent,currentFace:"Beryl-Regular").flatMap(\.rows)
    XCTAssertEqual(rows.map(\.face.name),["Aster-Bold","Beryl-BoldItalic"])
    XCTAssertEqual(model.sections(scope:.recent,query:"Regular",currentFace:"Beryl-Regular").flatMap(\.rows).map(\.face.name),["Aster-Regular"])
    XCTAssertEqual(model.sections(currentFace:"Beryl-Regular").first{$0.kind == .recent}?.rows.first?.face.name,"Aster-Bold")
  }
  func testUnavailableExactFaceNamesRemainScopedAndSearchable() {
    let model=FontBrowserModel(faces:fixture,projectSaved:["Missing Family Bold","Aster-Bold"],projectUsed:["Missing Family Bold","Old Face"],
      studioSaved:["Studio Missing"],recent:["Recent Missing"])
    XCTAssertEqual(model.unavailableFaces(scope:.project),["Missing Family Bold","Old Face"])
    XCTAssertEqual(model.unavailableFaces(scope:.project,query:"family BOLD"),["Missing Family Bold"])
    XCTAssertEqual(model.unavailableFaces(scope:.studio),["Studio Missing"])
    XCTAssertEqual(model.unavailableFaces(scope:.recent),["Recent Missing"])
    XCTAssertFalse(model.sections().flatMap(\.rows).contains{$0.face.name=="Missing Family Bold"})
  }
  func testInstalledAliasesShareFaceIdentityWithoutHidingTrulyMissingNames() {
    let model=FontBrowserModel(faces:fixture,projectSaved:["Aster","Aster-Regular","Missing Family"],
      projectUsed:["Aster"],studioSaved:["Aster"],recent:["Aster","Aster-Bold"],
      aliases:["Aster":"Aster-Regular","Missing Family":"Unavailable Substitute"])
    for scope in [FontBrowserScope.project,.studio,.recent] {
      let rows=model.sections(scope:scope,currentFace:"Aster").flatMap(\.rows)
      XCTAssertEqual(rows.map(\.face.name),["Aster-Regular"])
    }
    XCTAssertEqual(model.unavailableFaces(scope:.project),["Missing Family"])
    XCTAssertTrue(model.unavailableFaces(scope:.studio).isEmpty)
    XCTAssertTrue(model.sections(scope:.studio,query:"Bold").isEmpty,
      "Resolving an installed alias must not add unsaved styles to the collection")
    XCTAssertEqual(model.sections(query:"Aster",currentFace:"Aster").flatMap(\.rows).map(\.face.name),["Aster-Regular"])
  }
  func testFiltersUseReportedTraitsNeverSuggestiveFamilyNames() {
    let model=FontBrowserModel(faces:fixture)
    for (category,names) in [(FontBrowserCategory.serif,["Aster"]),(.sans,["Beryl"]),(.mono,["Circuit"]),(.script,["Dancer"]),(.variable,["Elastic"])] {
      XCTAssertEqual(model.sections(category:category).flatMap(\.rows).map(\.id),names)
    }
    XCTAssertTrue(model.sections(category:.mono,query:"Script").isEmpty)
    XCTAssertEqual(model.sections(category:.all,query:"Sans Mono").flatMap(\.rows).map(\.id),["Sans Mono Script Variable"])
  }
  func testOrderingIsIndependentOfCatalogInputAndUsesNaturalFamilyOrder() {
    let faces=fixture+[face("Family 10","Regular"),face("Family 2","Regular")]
    let first=FontBrowserModel(faces:faces),second=FontBrowserModel(faces:faces.reversed())
    XCTAssertEqual(first.sections(),second.sections())
    XCTAssertEqual(first.sections(query:"Family").flatMap(\.rows).map(\.id),["Family 2","Family 10"])
  }
  func testTraitDistancePreservesItalicWeightAndWidthWhenStylesDiffer()throws {
    let current=face("Original","Semi Bold Oblique",.init(isItalic:true,isBold:true,weight:0.3,width:-0.2,slant:0.2))
    let light=face("Target","Light Italic",.init(isItalic:true,weight:-0.4,width:-0.2,slant:0.2))
    let upright=face("Target","Heavy",.init(isBold:true,weight:0.4,width:-0.2))
    let closest=face("Target","Demi Oblique",.init(isItalic:true,isBold:true,weight:0.35,width:-0.2,slant:0.2))
    let family=InstalledFontFamily(name:"Target",faces:[light,upright,closest])
    XCTAssertEqual(family.representative(preserving:current),closest)
    XCTAssertEqual(FontBrowserModel(faces:[current,light,upright,closest]).sections(query:"Target",currentFace:current.name).flatMap(\.rows).first?.face,closest)
  }
}
