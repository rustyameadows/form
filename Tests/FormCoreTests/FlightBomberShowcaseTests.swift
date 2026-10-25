import XCTest
@testable import FormCore
import FormGraphics

@MainActor final class FlightBomberShowcaseTests:XCTestCase {
  func testAuthoredMissionPatchesProduceRealUnderlayAndPortableNeedlePrograms()throws {
    let project=Samples.flightJacket()
    let patches=project.objects.filter {$0.textile?.embroidery != nil}
    XCTAssertEqual(patches.count,5)
    for patch in patches {
      let design=try XCTUnwrap(patch.textile?.embroidery)
      let program=try EmbroideryDigitizer.generate(object:patch,project:project)
      try program.validate()
      XCTAssertGreaterThan(program.stitchCount,1000)
      XCTAssertEqual(program.threadOrder,[0,1,2,3])
      XCTAssertEqual(Set(program.commands.compactMap(\.regionID)),Set(design.regions.map(\.id)))
      XCTAssertTrue(program.commands.contains {$0.purpose == .underlay})
      XCTAssertFalse(program.commands.contains {$0.purpose == .tieIn || $0.purpose == .tieOff})
      XCTAssertTrue(design.regions.contains {$0.method == .satin && $0.satinWidth == 2.2})
      let data=try EmbroideryDST.data(program)
      XCTAssertGreaterThan(data.count,512)
      XCTAssertEqual(Array(data.suffix(3)),[0,0,0xF3])
    }
    XCTAssertFalse(project.objects.filter {$0.textile?.kind == .garment}.contains {$0.textile?.measurementsVerified == true})
  }

  func testSourceWordEditRegeneratesEveryPlacementAndReopenPreservesExactIntent()throws {
    var project=Samples.flightJacket()
    let patches=project.objects.filter {$0.textile?.embroidery != nil}
    let before=try patches.map {try EmbroideryDigitizer.generate(object:$0,project:project)}
    let consumer=try XCTUnwrap(patches.first)
    let owner=project.artworkOwner(consumer)
    var art=try XCTUnwrap(owner.artwork)
    let title=try XCTUnwrap(art.elements.firstIndex {$0.kind == "text" && $0.text == "NASA"})
    art.elements[title].text="NOVA"
    let fixedObjects=project.objects.filter {$0.id != owner.id}
    try project.setArtwork(art,for:consumer.id)
    XCTAssertEqual(project.objects.filter {$0.id != owner.id},fixedObjects)
    let after=try patches.map {try EmbroideryDigitizer.generate(object:$0,project:project)}
    for index in patches.indices {XCTAssertNotEqual(before[index].sourceDigest,after[index].sourceDigest)}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root)
    try repository.save(project)
    let loaded=try repository.load(project.id)
    XCTAssertEqual(loaded.objects,project.objects)
    XCTAssertEqual(loaded.schemaVersion,28)
    for (index,patch) in patches.enumerated() {
      let reopened=try XCTUnwrap(loaded.objects.first {$0.id == patch.id})
      XCTAssertEqual(try EmbroideryDigitizer.generate(object:reopened,project:loaded),after[index])
    }
  }
}
