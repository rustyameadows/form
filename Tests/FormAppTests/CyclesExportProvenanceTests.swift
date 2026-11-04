import Foundation
import XCTest
@testable import FormApp

final class CyclesExportProvenanceTests:XCTestCase {
  private func fixture(packaged:Bool=true)throws->(URL,CyclesExportProvenance.Locations) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-export-provenance-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let app=root.appendingPathComponent("Ordinary.app/Contents"),executable=app.appendingPathComponent("MacOS/LAB"),helper=app.appendingPathComponent("Helpers/lab-cycles-render")
    for url in [executable,helper] {try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)}
    try Data("abc".utf8).write(to:executable);try Data("renderer-v1\n".utf8).write(to:helper)
    let locations=CyclesExportProvenance.Locations(executable:executable,helper:helper)
    if packaged {
      let display=try JSONSerialization.data(withJSONObject:["id":"LAB-sRGB-v1","loadedByRenderer":false],options:.sortedKeys)
      try write(display,to:locations.display!)
      try write(try JSONSerialization.data(withJSONObject:["source_commit":"pinned-cycles","dependency_commit":"pinned-dependencies","protocol_version":1,"display_transform":"LAB-sRGB-v1","source_inputs":["Native/LabCycles/LAB-sRGB-v1.json":StudioRenderFolder.hash(display)]]),to:locations.engine!)
      try write(try JSONSerialization.data(withJSONObject:["format_version":1,"build_id":"sha256:exact-build","configuration":"release","source_revision":"app-source"]),to:locations.build!)
    }
    return(root,locations)
  }
  private func write(_ data:Data,to url:URL)throws {
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)
  }
  private func dictionary(_ value:Any?)throws->[String:Any] {try XCTUnwrap(value as? [String:Any])}
  func testCapturedRuntimeIdentitiesAreActualBytesAndPortableBuildMetadata()async throws {
    let (root,locations)=try fixture(),capture=try await CyclesExportProvenance.capture(locations)
    let record=try capture.record(engineRevision:"pinned-cycles"),app=try dictionary(record["application"]),renderer=try dictionary(record["renderer"])
    let executable=try dictionary(app["executable"]),helper=try dictionary(renderer["helper"])
    XCTAssertEqual(executable["sha256"] as? String,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(executable["size_bytes"] as? Int,3)
    XCTAssertEqual(helper["sha256"] as? String,StudioRenderFolder.hash(try Data(contentsOf:locations.helper)))
    let build=try dictionary(app["packaged_build"]),engine=try dictionary(renderer["engine_provenance"]),display=try dictionary(renderer["display_transform"])
    XCTAssertEqual(try dictionary(build["metadata"])["build_id"] as? String,"sha256:exact-build")
    for (value,url) in [(build,locations.build!),(engine,locations.engine!),(display,locations.display!)] {
      XCTAssertEqual(value["status"] as? String,"available");XCTAssertEqual(value["sha256"] as? String,StudioRenderFolder.hash(try Data(contentsOf:url)))
    }
    XCTAssertEqual(display["id"] as? String,"LAB-sRGB-v1")
    XCTAssertFalse(String(decoding:capture.data,as:UTF8.self).contains(root.path))
    XCTAssertThrowsError(try capture.record(engineRevision:"another-engine"))
  }
  func testChangedHelperWithSameUpstreamPinCannotReuseCapturedIdentity()async throws {
    let (_,locations)=try fixture(),before=try await CyclesExportProvenance.capture(locations)
    try Data("renderer-v2\n".utf8).write(to:locations.helper)
    let after=try await CyclesExportProvenance.capture(locations)
    XCTAssertEqual(before.engineRevision,after.engineRevision)
    XCTAssertThrowsError(try before.requireUnchanged(after));XCTAssertNoThrow(try before.requireUnchanged(before))
  }
  func testDevelopmentMetadataAbsenceIsExplicitAndMissingBinariesStillFail()async throws {
    let (_,locations)=try fixture(packaged:false),capture=try await CyclesExportProvenance.capture(locations)
    let record=try capture.record(engineRevision:"development-engine"),app=try dictionary(record["application"]),renderer=try dictionary(record["renderer"])
    for value in [app["packaged_build"],renderer["engine_provenance"],renderer["display_transform"]] {
      let item=try dictionary(value);XCTAssertEqual(item["status"] as? String,"unavailable");XCTAssertNil(item["sha256"])
    }
    try FileManager.default.removeItem(at:locations.helper)
    do {_=try await CyclesExportProvenance.capture(locations);XCTFail("Missing runtime helper cannot receive an invented digest.")}catch{}
  }
  func testMalformedOrMismatchedPresentMetadataAndSizeBudgetsReject()async throws {
    let (_,locations)=try fixture()
    try Data("{broken".utf8).write(to:locations.build!)
    do {_=try await CyclesExportProvenance.capture(locations);XCTFail("Malformed metadata must not become unavailable.")}catch{}
    try FileManager.default.removeItem(at:locations.build!)
    try Data("{\"id\":\"LAB-sRGB-v1\",\"loadedByRenderer\":false,\"changed\":true}".utf8).write(to:locations.display!)
    do {_=try await CyclesExportProvenance.capture(locations);XCTFail("A transform hash mismatch must reject.")}catch{}
    let (_,plain)=try fixture(packaged:false)
    var limits=CyclesExportProvenance.Limits();limits.binaryBytes=2
    do {_=try await CyclesExportProvenance.capture(plain,limits:limits);XCTFail("The binary read must be bounded.")}catch{}
  }
  func testAtomicExportContainsExactCapturedRuntimeFields()async throws {
    let (root,locations)=try fixture(),capture=try await CyclesExportProvenance.capture(locations)
    let runtime=try capture.record(engineRevision:"pinned-cycles")
    let png=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
    let folder=root.appendingPathComponent("result.render")
    let record:[String:Any]=["width":1,"height":1,"png_sha256":StudioRenderFolder.hash(png),"runtime_provenance":runtime]
    _=try StudioRenderFolder.write(png:png,record:record,to:folder)
    let saved=try dictionary(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("render.json"))))
    XCTAssertEqual(try dictionary(saved["runtime_provenance"]) as NSDictionary,runtime as NSDictionary)
    XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("result.png")),png)
  }
  func testCancelledIdentityReadDoesNotReturnARecord()async throws {
    let (_,locations)=try fixture()
    let task=Task {try await CyclesExportProvenance.capture(locations)};task.cancel()
    do {_=try await task.value;XCTFail("Cancellation must not publish runtime identities.")}catch {XCTAssertTrue(error is CancellationError)}
  }
}
