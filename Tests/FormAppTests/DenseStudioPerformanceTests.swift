import AppKit
import CryptoKit
import FormCore
import XCTest
@testable import FormApp

/// Opt-in real-document measurements. Only the isolated repository is writable;
/// the supplied package is fingerprinted before and after the complete run.
@MainActor final class DenseStudioPerformanceTests: XCTestCase {
  private func fingerprint(_ package: URL) throws -> String {
    let iterator = try XCTUnwrap(FileManager.default.enumerator(at: package,
      includingPropertiesForKeys: [.isRegularFileKey]))
    let files = try iterator.compactMap { $0 as? URL }.filter {
      try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }.sorted { $0.path < $1.path }
    var digest = SHA256()
    for file in files {
      digest.update(data: Data(file.path.dropFirst(package.path.count).utf8))
      digest.update(data: Data([0]))
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
      }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func testExternalStudioSceneSwitchingAndThumbnailReentry() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["FORM_DENSE_PROJECT_PATH"], !path.isEmpty else {
      throw XCTSkip("Set FORM_DENSE_PROJECT_PATH for optional real-document Studio measurements.")
    }
    let input = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let before = try fingerprint(input)
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("dense-studio-benchmark-" + UUID().uuidString)
    let repository = try ProjectRepository(root: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let project = try repository.load(url: input)
    let savedScenes = project.studioPresentation?.scenes ?? []
    guard !savedScenes.isEmpty else { throw XCTSkip("The supplied package has no saved Studio scenes.") }
    // Eight is the resolution cache's bounded working set and covers every
    // saved scene in the dense collection used for this investigation.
    let scenes = Array(savedScenes.prefix(8))
    try repository.save(project)
    let sourceAssets = input.appendingPathComponent("Assets")
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    if FileManager.default.fileExists(atPath: sourceAssets.path) {
      for file in try FileManager.default.contentsOfDirectory(at: sourceAssets, includingPropertiesForKeys: nil) {
        try FileManager.default.copyItem(at: file, to: assets.appendingPathComponent(file.lastPathComponent))
      }
    }
    _ = NSApplication.shared
    let store = StudioStore(repository: repository, seedLibrary: false)
    store.engine.project = project; store.showingHome = false
    store.linkedObjectViews = LinkedObjectViewRenderer(store: store) { _, _, _, _, _, _, _ in
      throw CancellationError()
    }
    let controller = store.studioComposition
    defer {
      controller.reset(); store.linkedObjectViews.reset(); store.solids.reset()
      store.engine.project = nil
    }
    var samples: [[String: Any]] = [], metrics: [String: Any] = [:]
    func record(_ stage: String, _ scene: StudioComposition?, _ started: UInt64) {
      var sample: [String: Any] = ["stage": stage,
        "milliseconds": Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000]
      if let scene { sample["scene_id"] = scene.id.uuidString; sample["scene_name"] = scene.name }
      samples.append(sample)
    }
    let repetitions = min(5, max(1, Int(environment["FORM_DENSE_BENCHMARK_SAMPLES"] ?? "3") ?? 3))
    let resolution = StudioCompositionResolutionCache()
    for scene in scenes {
      let start = DispatchTime.now().uptimeNanoseconds
      let result = try resolution.resolve(scene, in: project)
      record("resolution.cold", scene, start)
      XCTAssertEqual(result.visible.count, try scene.resolved(in: project).visible.count)
    }
    let coldBuilds = resolution.builds
    for _ in 0..<repetitions {
      for scene in scenes {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try resolution.resolve(scene, in: project)
        record("resolution.warm", scene, start)
      }
    }
    XCTAssertEqual(resolution.builds, coldBuilds)
    metrics["resolution_builds_cold"] = coldBuilds
    metrics["resolution_builds_after_return"] = resolution.builds

    var start = DispatchTime.now().uptimeNanoseconds
    controller.reconcile()
    record("stage.first-entry", scenes.first, start)
    for scene in scenes {
      start = DispatchTime.now().uptimeNanoseconds
      controller.load(scene.id)
      record("stage.first-scene-switch", scene, start)
      XCTAssertEqual(controller.draft?.id, scene.id); XCTAssertNil(controller.error)
    }
    let firstStageBuilds = controller.resolutionBuildCount
    for scene in scenes {
      start = DispatchTime.now().uptimeNanoseconds
      controller.load(scene.id)
      record("stage.return-to-scene", scene, start)
      XCTAssertEqual(controller.draft?.id, scene.id); XCTAssertNil(controller.error)
    }
    XCTAssertEqual(controller.resolutionBuildCount, firstStageBuilds)
    metrics["stage_resolution_builds_first_pass"] = firstStageBuilds
    metrics["stage_resolution_builds_after_return"] = controller.resolutionBuildCount
    metrics["stage_syncs"] = controller.stageSyncCount

    let thumbnails = controller.thumbnails
    start = DispatchTime.now().uptimeNanoseconds
    thumbnails.synchronize(project: project, assets: assets)
    let keys = scenes.map { thumbnails.key(for: $0) }
    record("thumbnails.initial-source-and-keys", nil, start)
    let keyBuilds = thumbnails.keyBuildCount
    for _ in 0..<repetitions {
      start = DispatchTime.now().uptimeNanoseconds
      for _ in 0..<100 {
        thumbnails.synchronize(project: project, assets: assets)
        XCTAssertEqual(scenes.map { thumbnails.key(for: $0) }, keys)
      }
      record("thumbnails.100-repeated-source-and-key-reads", nil, start)
    }
    XCTAssertEqual(thumbnails.keyBuildCount, keyBuilds)
    var images: [UUID: NSImage] = [:]
    for scene in scenes {
      start = DispatchTime.now().uptimeNanoseconds
      let image = try await thumbnails.image(for: scene) { project, shot in
        try store.studioShots.runtimePreflight(project, shot)
      }
      record("thumbnails.native-first-capture", scene, start)
      let pixels = StudioSceneThumbnailCache.pixels(for: scene)
      XCTAssertEqual(image.size, NSSize(width: pixels.width, height: pixels.height))
      images[scene.id] = image
    }
    let firstRenders = thumbnails.renderCount
    XCTAssertEqual(firstRenders, scenes.count)
    thumbnails.suspend()
    start = DispatchTime.now().uptimeNanoseconds
    controller.reconcile()
    thumbnails.synchronize(project: project, assets: assets)
    record("stage.workspace-reentry", nil, start)
    for scene in scenes {
      start = DispatchTime.now().uptimeNanoseconds
      let image = try await thumbnails.image(for: scene) { project, shot in
        try store.studioShots.runtimePreflight(project, shot)
      }
      record("thumbnails.cached-after-workspace-reentry", scene, start)
      XCTAssertTrue(image === images[scene.id])
    }
    XCTAssertEqual(thumbnails.renderCount, firstRenders)
    XCTAssertEqual(thumbnails.keyBuildCount, keyBuilds)
    XCTAssertEqual(store.project, project)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertTrue(store.engine.redoStack.isEmpty)
    metrics["thumbnail_renders_first_pass"] = firstRenders
    metrics["thumbnail_renders_after_reentry"] = thumbnails.renderCount
    metrics["thumbnail_key_builds_first_pass"] = keyBuilds
    metrics["thumbnail_key_builds_after_reentry"] = thumbnails.keyBuildCount
    let after = try fingerprint(input)
    XCTAssertEqual(before, after, "The supplied source package must remain byte-for-byte unchanged.")
    let report: [String: Any] = ["format_version": 1, "input_path": input.path,
      "input_sha256": before, "source_unchanged": before == after,
      "saved_scenes": savedScenes.count, "measured_scenes": scenes.count,
      "measured_instances": scenes.reduce(0) { $0 + $1.instances.count },
      "stored_elements": project.storedArtworks.reduce(0) { $0 + $1.elements.count },
      "metrics": metrics, "samples": samples]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print("DENSE_STUDIO_BENCHMARK\n" + String(decoding: data, as: UTF8.self))
    if let outputPath = environment["FORM_DENSE_STUDIO_BENCHMARK_OUTPUT"], !outputPath.isEmpty {
      let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
      guard output.path != input.path, !output.path.hasPrefix(input.path + "/") else {
        throw FormError.invalid("Write the Studio benchmark report outside the supplied package.")
      }
      try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: output, options: .atomic)
    }
  }
}
