import AppKit
import CryptoKit
import Foundation
import FormCore
import XCTest
@testable import FormApp

/// Opt-in measurements against an existing, read-only package. No document
/// fixture belongs in the application or test bundle. Run the same release
/// binary/configuration before and after a change and compare the JSON samples.
@MainActor final class DenseDocumentPerformanceTests: XCTestCase {
  private struct Sample: Codable {
    let stage: String
    let milliseconds: [Double]
  }
  private struct Report: Codable {
    let formatVersion: Int
    let inputPath: String
    let inputSHA256: String
    let inputBytes: Int
    let sourceUnchanged: Bool
    let objects: Int
    let storedElements: Int
    let pathNodes: Int
    let frames: Int
    let projectedElements: Int
    let frameBuilds: Int
    let samples: [Sample]
  }
  private struct Fingerprint: Equatable {
    let digest: String
    let bytes: Int
  }
  private func fingerprint(_ package: URL) throws -> Fingerprint {
    let fm = FileManager.default
    let iterator = try XCTUnwrap(fm.enumerator(at: package,
      includingPropertiesForKeys: [.isRegularFileKey], options: []))
    let files = try iterator.compactMap { $0 as? URL }.filter {
      try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }.sorted { $0.path < $1.path }
    var hash = SHA256(), bytes = 0
    for file in files {
      let relative = String(file.path.dropFirst(package.path.count))
      hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hash.update(data: data); bytes += data.count
      }
    }
    return .init(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
  }

  func testReadOnlyExternalDocumentStages() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["FORM_DENSE_PROJECT_PATH"], !path.isEmpty else {
      throw XCTSkip("Set FORM_DENSE_PROJECT_PATH to an existing .form package for the opt-in dense-document benchmark.")
    }
    let input = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let before = try fingerprint(input)
    let count = min(10, max(1, Int(env["FORM_DENSE_BENCHMARK_SAMPLES"] ?? "3") ?? 3))
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("dense-document-benchmark-" + UUID().uuidString)
    let repository = try ProjectRepository(root: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    var samples: [Sample] = []
    @discardableResult func time<T>(_ stage: String, repetitions: Int? = nil,
      _ work: () throws -> T) rethrows -> T {
      var times: [Double] = []
      let start = DispatchTime.now().uptimeNanoseconds
      var result = try work()
      times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
      for _ in 1..<(repetitions ?? count) {
        let start = DispatchTime.now().uptimeNanoseconds
        result = try work()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
      }
      samples.append(.init(stage: stage, milliseconds: times))
      return result
    }
    let project = try time("repository.load-and-validate") { try repository.load(url: input) }
    try time("project.validateArtworkLinks") { try project.validateArtworkLinks() }
    try time("repository.first-save", repetitions: 1) { try repository.save(project) }
    try time("repository.unchanged-save") { try repository.save(project) }
    // Edit hooks may inspect embedded artwork when updating a linked vector
    // view. Copy assets into the isolated repository rather than redirecting
    // any writable derived-output path to the original package.
    let sourceAssets = input.appendingPathComponent("Assets")
    let isolatedAssets = repository.url(for: project.id).appendingPathComponent("Assets")
    if FileManager.default.fileExists(atPath: sourceAssets.path) {
      for file in try FileManager.default.contentsOfDirectory(at: sourceAssets, includingPropertiesForKeys: nil) {
        try FileManager.default.copyItem(at: file, to: isolatedAssets.appendingPathComponent(file.lastPathComponent))
      }
    }
    _ = NSApplication.shared
    let store = StudioStore(repository: repository, seedLibrary: false)
    store.engine.project = project; store.showingHome = false
    // This harness isolates synchronous document work; it does not start GPU
    // captures or attempt to manufacture missing external assets in a copy.
    store.linkedObjectViews = LinkedObjectViewRenderer(store: store) { _, _, _, _, _, _, _ in
      throw CancellationError()
    }
    defer {
      store.linkedObjectViews.reset(); store.solids.reset()
      store.engine.project = nil
    }
    let session = store.artworkSession
    let frames = time("canvas.frames-cold", repetitions: 1) { session.frames }
    XCTAssertFalse(frames.isEmpty)
    time("canvas.frames-warm-100-reads") {
      for _ in 0..<100 { XCTAssertEqual(session.frames.count, frames.count) }
    }
    let assets = input.appendingPathComponent("Assets")
    let linkedIDs = Set(project.storedArtworks.flatMap(\.elements).compactMap {
      $0.objectView?.linked == true ? $0.objectView?.sourceID : nil
    })
    time("linked-views.unchanged-source-signatures") {
      for object in project.objects where linkedIDs.contains(object.id) {
        _ = LinkedObjectViewRenderer.state(object, in: project)
      }
    }
    time("linked-views.unchanged-refresh-hooks") {
      var unchanged = project
      let failures = ObjectViewUpdates.refreshChangedSources(before: project, project: &unchanged, assets: assets)
      XCTAssertTrue(failures.isEmpty)
      LinkedObjectViewRenderer.markPending(before: project, project: &unchanged)
      XCTAssertEqual(unchanged, project)
    }
    let linkedFrame = frames.first { $0.projection.map { linkedIDs.contains($0.constructionID) } == true }
      ?? frames.first { $0.projection != nil }
    if let frame = linkedFrame, let projection = frame.projection {
      session.objectID = projection.sourceID; session.linkedTargetID = projection.constructionID
      session.projectionFrameID = frame.id
      time("canvas.frame-position-edit-and-frame-read") {
        store.engine.project = project
        _ = session.frames
        session.moveCanvasFrame(to: .init(frame.rect.minX + 5, frame.rect.minY + 5))
        XCTAssertNil(store.error)
        _ = session.frames
      }
    }
    store.engine.project = project
    if let frame = frames.filter({ $0.projection == nil && !$0.artwork.elements.isEmpty })
      .max(by: { $0.artwork.elements.count < $1.artwork.elements.count }),
      let element = frame.artwork.elements.first(where: { $0.parentID == nil && !frame.artwork.isLocked($0) }) {
      session.objectID = frame.object.id; session.linkedTargetID = nil; session.projectionFrameID = nil
      session.selection = [element.id]
      time("canvas.artwork-translate-and-frame-read") {
        store.engine.project = project
        _ = session.beginGesture()
        session.translate(dx: 1, dy: 1)
        session.endGesture()
        XCTAssertNil(store.error)
        _ = session.frames
      }
    }
    let after = try fingerprint(input)
    XCTAssertEqual(before, after, "The supplied real document must remain byte-for-byte unchanged.")
    let elements = project.storedArtworks.flatMap(\.elements)
    let report = Report(formatVersion: 1, inputPath: input.path, inputSHA256: before.digest,
      inputBytes: before.bytes, sourceUnchanged: before == after, objects: project.objects.count,
      storedElements: elements.count,
      pathNodes: elements.reduce(0) { $0 + ($1.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? 0) },
      frames: frames.count, projectedElements: frames.reduce(0) { $0 + $1.artwork.elements.count },
      frameBuilds: session.frameBuildCount, samples: samples)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    print("DENSE_DOCUMENT_BENCHMARK\n" + String(decoding: data, as: UTF8.self))
    if let outputPath = env["FORM_DENSE_BENCHMARK_OUTPUT"], !outputPath.isEmpty {
      let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
      guard output.path != input.path, !output.path.hasPrefix(input.path + "/") else {
        throw FormError.invalid("Write the benchmark report outside the read-only input package.")
      }
      try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: output, options: .atomic)
    }
  }
}
