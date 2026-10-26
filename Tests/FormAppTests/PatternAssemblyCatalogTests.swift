import AppKit
import SwiftUI
import XCTest
@testable import FormCore
@testable import FormApp

@MainActor final class PatternAssemblyCatalogTests:XCTestCase {
  func testAcceptedFeaturedStudyOrderStaysIntactAndAssemblyIsDiscoverableAtEnd()throws {
    let ids=Samples.templates.map(\.id)
    XCTAssertEqual(Array(ids.prefix(3)),["affinities","clothLab","merchandise"])
    XCTAssertEqual(ids.last,"pouchAssembly");XCTAssertEqual(ids.count,Set(ids).count)
    let study=try Samples.make("pouchAssembly")
    XCTAssertEqual(study.objects.filter{$0.patternAssembly != nil}.count,1)
    XCTAssertEqual(study.minimumSchemaVersion,36)
  }
  func testNativeHomeProofKeepsAcceptedFeaturedCardsAndCompactStudyMenu()async throws {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("home-assembly36-\(UUID().uuidString)")
    let repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    let window=NSWindow(contentRect:.init(x:0,y:0,width:1280,height:980),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let hosting=NSHostingView(rootView:HomeView().environmentObject(store).preferredColorScheme(.light).frame(width:1280,height:980).background(Palette.paper).foregroundStyle(Palette.ink))
    hosting.frame = .init(x:0,y:0,width:1280,height:980);window.contentView=hosting
    defer {window.contentView=nil;window.close();try? FileManager.default.removeItem(at:root)}
    hosting.layoutSubtreeIfNeeded()
    // Let the actual native StudyCard tasks populate their bounded previews.
    try await Task.sleep(nanoseconds:500_000_000)
    hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
    let bitmap=try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds))
    hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
    let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    XCTAssertGreaterThan(png.count,10000);XCTAssertFalse(window.isVisible);XCTAssertNil(store.project);XCTAssertTrue(store.projects.isEmpty)
    if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {try png.write(to:URL(fileURLWithPath:directory).appendingPathComponent("integrated-native-home-featured.png"))}
  }
}
