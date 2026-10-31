import AppKit
import Combine
import CryptoKit
import FormCore
import ImageIO

enum CanvasImageGenerationStatus: String, Equatable {
  case draft, preparing, generating, succeeded, failed, cancelled, stale
}

struct CanvasImageGenerationDraft: Identifiable, Equatable {
  let id: UUID
  let projectID: UUID
  let projectEpoch: UUID
  let destinationID: UUID
  var prompt = ""
  var options = StudioImageGenerationOptions()
  var references: [CanvasGenerationReference] = []
  var status: CanvasImageGenerationStatus = .draft
  var resultElementID: UUID?
  var resultAssetID: UUID?
  var generationID: UUID?
}

/// A local-only provider workflow. The draft is transient; the delivered image
/// and all request provenance live in the ordinary portable artwork document.
@MainActor final class CanvasImageGenerationController: ObservableObject {
  weak var store: StudioStore?
  let library: StudioAssetLibrary
  let connection: OpenAIConnectionPreviewController
  let projectID: UUID?
  let promptLibrary: ImageGenerationPromptLibrary?
  @Published private(set) var draft: CanvasImageGenerationDraft?
  @Published private(set) var busy = false
  @Published private(set) var progress = 0.0
  @Published private(set) var phase: StudioGenerationPhase = .idle
  @Published private(set) var error: String?
  private let provider: any StudioImageGenerationProvider
  private var destination: CanvasImageGenerationDestination?
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var observations = Set<AnyCancellable>()
  private var committing = false

  init(store: StudioStore, library: StudioAssetLibrary,
    provider: (any StudioImageGenerationProvider)? = nil,
    connection: OpenAIConnectionPreviewController? = nil) {
    self.store = store; self.library = library
    self.provider = provider ?? LocalStudioImageGenerationProvider()
    self.connection = connection ?? OpenAIConnectionPreviewController()
    projectID = library.projectID ?? store.project?.id
    promptLibrary = projectID.map { ImageGenerationPromptLibrary(root: store.repository.root, projectID: $0) }
    store.$revision.dropFirst().sink { [weak self] _ in self?.reconcile() }.store(in: &observations)
  }

  var canGenerate: Bool {
    guard !busy, let draft, draft.status != .succeeded,
      CanvasImageGenerationProvenance.validPrompt(draft.prompt), draft.options.count == 1,
      draft.references.count <= 8 else { return false }
    return (try? checkedDestination(for: draft)) != nil
  }

  @discardableResult func begin(at position: Point2, reference: CanvasGenerationReference? = nil) throws -> UUID {
    guard !busy else { throw FormError.invalid("Finish or cancel the current image generation first.") }
    guard let store, let project = store.project, project.id == projectID, !store.showingHome else {
      throw FormError.invalid("Open the current project before generating a Canvas image.")
    }
    if let reference { try validateReference(reference, in: project) }
    store.finishArtworkEditing(); store.engine.endInteraction()
    var objectID: UUID?
    try store.engine.edit("Created image artboard", source: "Studio") { project in
      objectID = try CanvasImageGeneration.createArtboard(in: &project, at: position).id
    }
    guard let objectID, let current = store.project else { throw FormError.invalid("The image artboard could not be created.") }
    destination = try CanvasImageGeneration.destination(in: current, objectID: objectID)
    draft = .init(id: UUID(), projectID: current.id, projectEpoch: store.artworkTransferProjectEpoch,
      destinationID: objectID, references: reference.map { [$0] } ?? [])
    generation = UUID(); error = nil; progress = 0; phase = .idle
    store.changed(); store.artworkSession.activate(objectID); store.artworkSession.choose([])
    return objectID
  }

  func updatePrompt(_ value: String) {
    guard !busy, draft?.status != .succeeded else { return }
    draft?.prompt = value; error = nil
  }
  func updateOptions(_ value: StudioImageGenerationOptions) {
    guard !busy, draft?.status != .succeeded else { return }
    guard value.count == 1 else { error = "Generate one image per Canvas artboard."; return }
    draft?.options = value; error = nil
  }
  @discardableResult func addReference(_ reference: CanvasGenerationReference) -> Bool {
    guard !busy, let draft, draft.status != .succeeded, let project = store?.project,
      project.id == draft.projectID, store?.artworkTransferProjectEpoch == draft.projectEpoch else { return false }
    do {
      try validateReference(reference, in: project)
      guard reference.objectID != draft.destinationID else { throw FormError.invalid("Choose another Canvas asset as the reference.") }
      if draft.references.contains(where: { $0.id == reference.id }) { return true }
      guard draft.references.count < 8 else { throw FormError.invalid("Use up to eight Canvas references.") }
      self.draft?.references.append(reference); error = nil; return true
    } catch { self.error = error.localizedDescription; return false }
  }
  func removeReference(id: String) {
    guard !busy, draft?.status != .succeeded else { return }
    draft?.references.removeAll { $0.id == id }; error = nil
  }
  func clearError() { error = nil }
  func dismissError() { clearError() }
  func cancel() {
    let wasBusy = busy
    generation = UUID(); task?.cancel(); task = nil; busy = false; progress = 0; phase = .idle
    if wasBusy { draft?.status = .cancelled; error = nil }
  }
  func dismiss() { cancel(); draft = nil; destination = nil; error = nil }
  func resetForProjectChange() { dismiss() }
  func reconcile() {
    guard !committing, let draft else { return }
    guard store?.project?.id == draft.projectID, store?.artworkTransferProjectEpoch == draft.projectEpoch else {
      resetForProjectChange(); return
    }
    if let resultID = draft.resultElementID,
      let element = store?.project?.objects.first(where: { $0.id == draft.destinationID })?.artwork?.elements.first(where: { $0.id == resultID }),
      element.imageGeneration?.id == draft.generationID {
      self.draft?.status = .succeeded; error = nil; return
    }
    do {
      _ = try checkedDestination(for: draft)
      if draft.status == .succeeded || draft.status == .stale { self.draft?.status = .draft; error = nil }
    }
    catch {
      if busy { cancel() }
      self.draft?.status = .stale; self.error = error.localizedDescription
    }
  }
  func retry() async { await generate() }

  func generate() async {
    guard !busy, let draft, draft.status != .succeeded else { return }
    let token = UUID()
    do {
      guard CanvasImageGenerationProvenance.validPrompt(draft.prompt) else {
        throw FormError.invalid("Enter a prompt up to 8,000 characters and 32,000 UTF-8 bytes.")
      }
      try draft.options.validate()
      guard draft.options.count == 1, draft.references.count <= 8,
        Set(draft.references.map(\.id)).count == draft.references.count else {
        throw FormError.invalid("Generate one image with up to eight different Canvas references.")
      }
      let referenceProject = try checkedDestination(for: draft)
      generation = token; busy = true; progress = 0; phase = .preparing; error = nil
      self.draft?.status = .preparing
      let work = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          if self.generation == token { self.busy = false; self.task = nil; self.phase = self.draft?.status == .succeeded ? .finished : .idle }
        }
        do {
          var payloads: [StudioGenerationReferenceImage] = []
          var references: [StudioGenerationReference] = []
          var provenanceReferences: [CanvasImageGenerationReferenceMetadata] = []
          for reference in draft.references {
            await Task.yield(); _ = try self.check(token, draft: draft)
            let capture = try CanvasGenerationReferenceCapture.capture(project: referenceProject,
              repository: self.libraryRepository(), reference: reference)
            let id = UUID()
            payloads.append(.init(assetID: id, name: capture.reference.title, png: capture.png))
            references.append(.init(assetID: id, role: .composition))
            provenanceReferences.append(.init(id: id, sourceProjectID: capture.projectID,
              objectID: capture.reference.objectID, elementIDs: capture.reference.elementIDs,
              name: capture.reference.title, sourceSHA256: capture.sourceSHA256, renderedSHA256: capture.pngSHA256))
          }
          await Task.yield(); _ = try self.check(token, draft: draft)
          let request = StudioGenerationRequest(inputPNG: nil, prompt: draft.prompt, style: "",
            references: references, options: draft.options, context: nil, source: .canvas, referenceImages: payloads)
          self.draft?.status = .generating; self.phase = .generating
          let images = try await self.provider.generate(request) { [weak self] value in
            guard let self, self.generation == token, value.isFinite else { return }
            self.progress = max(0, min(1, value)) * 0.85
          }
          _ = try self.check(token, draft: draft)
          guard images.count == 1, let png = images.first else { throw FormError.invalid("The image provider returned an incomplete result.") }
          try self.validatePNG(png, options: draft.options)
          let provenance = CanvasImageGenerationProvenance(createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            prompt: draft.prompt, model: draft.options.model.rawValue, provider: "Local demo · no AI request", isDemo: true,
            settings: draft.options.redactedMetadata, references: provenanceReferences,
            outputSHA256: Self.hash(png), pixelWidth: draft.options.pixels.width, pixelHeight: draft.options.pixels.height)
          try provenance.validate()
          self.phase = .writing; self.progress = 0.9
          await Task.yield(); _ = try self.check(token, draft: draft)
          // Do not interrupt marked text, a held pointer drag or an inspector
          // transaction. Keep the completed result until the user's edit ends.
          if self.waitingForDocumentInteraction { self.phase = .waitingForEditor }
          while self.waitingForDocumentInteraction {
            try await Task.sleep(nanoseconds: 100_000_000)
            _ = try self.check(token, draft: draft)
          }
          try self.commit(png, provenance: provenance, draft: draft, token: token)
        } catch {
          guard self.generation == token else { return }
          self.draft?.status = error is CancellationError ? .cancelled : .failed
          self.error = error is CancellationError ? nil : error.localizedDescription
        }
      }
      task = work; await work.value
    } catch { self.error = error.localizedDescription; self.draft?.status = .failed }
  }

  private var waitingForDocumentInteraction: Bool {
    store?.artworkSession.editingText == true || store?.engine.hasActiveInteraction == true
  }
  private func libraryRepository() throws -> ProjectRepository {
    guard let store else { throw CancellationError() }; return store.repository
  }
  private func checkedDestination(for draft: CanvasImageGenerationDraft) throws -> Project {
    guard let store, let project = store.project, project.id == projectID, project.id == draft.projectID,
      store.artworkTransferProjectEpoch == draft.projectEpoch, !store.showingHome,
      library.projectID == nil || library.projectID == project.id,
      let destination, destination.objectID == draft.destinationID else {
      throw FormError.invalid("The project changed. Start a new image generation in the current project.")
    }
    try CanvasImageGeneration.validateDestination(destination, in: project)
    return project
  }
  private func check(_ token: UUID, draft: CanvasImageGenerationDraft) throws -> Project {
    try Task.checkCancellation()
    guard generation == token, self.draft?.id == draft.id else { throw CancellationError() }
    return try checkedDestination(for: draft)
  }
  private func validateReference(_ reference: CanvasGenerationReference, in project: Project) throws {
    guard let object = project.objects.first(where: { $0.id == reference.objectID }), object.recipeID == "artboard", object.canvasSourceOnly != true,
      object.componentDefinition != true, object.artworkSourceID == nil,
      !reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      reference.title.count <= 500, reference.title.utf8.count <= 2_000,
      reference.elementIDs.count <= 5_000, Set(reference.elementIDs).count == reference.elementIDs.count,
      !object.isCanvasWorkspace || !reference.elementIDs.isEmpty,
      Set(reference.elementIDs).isSubset(of: Set((project.editableArtwork(object)?.elements ?? []).map(\.id))) else {
      throw FormError.invalid("Choose existing Canvas artwork or a finite artboard as the reference.")
    }
  }
  private func validatePNG(_ data: Data, options: StudioImageGenerationOptions) throws {
    guard data.count <= 32 * 1024 * 1024, data.starts(with: [137,80,78,71,13,10,26,10]),
      let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == options.pixels.width,
      (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == options.pixels.height,
      CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
      throw FormError.invalid("The image provider returned an invalid or incorrectly sized PNG.")
    }
  }
  private func commit(_ png: Data, provenance: CanvasImageGenerationProvenance,
    draft: CanvasImageGenerationDraft, token: UUID) throws {
    guard let store, let destination else { throw CancellationError() }
    _ = try check(token, draft: draft)
    var candidate = try check(token, draft: draft)
    let filename = "generated-\(provenance.id.uuidString).png"
    let imageID = try CanvasImageGeneration.placeResult(in: &candidate, destination: destination, asset: filename, provenance: provenance)
    guard let resultObject = candidate.objects.first(where: { $0.id == destination.objectID }) else { throw CancellationError() }
    let selectResult = store.artworkSession.activeFrameID == destination.objectID
    let directory = store.repository.url(for: draft.projectID).appendingPathComponent("Assets")
    let root = store.repository.root.standardizedFileURL.resolvingSymlinksInPath()
    let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard canonical.path.hasPrefix(root.path + "/") else { throw FormError.invalid("The generated asset destination must remain inside this Library.") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(filename)
    try png.write(to: file, options: .withoutOverwriting)
    do {
      // There are no suspension points between the final destination check,
      // Library registration and document edit, so a late callback cannot steal
      // or overwrite a different artboard while publication is in progress.
      _ = try check(token, draft: draft)
      let asset = try library.register(data: png, filename: filename, name: "Generated Canvas image · Local demo",
        metadata: .init(kind: .image, origin: .generated, projectID: draft.projectID, projectName: candidate.name,
          generationID: provenance.id, isMock: true, prompt: draft.prompt, provider: provenance.provider,
          options: provenance.settings.merging(["canvas_destination_id": draft.destinationID.uuidString,
            "reference_count": String(provenance.references.count)]) { _, new in new }))
      committing = true; defer { committing = false }
      try store.engine.edit("Generated Canvas image", source: "Studio") { project in
        try CanvasImageGeneration.validateDestination(destination, in: project)
        guard let index = project.objects.firstIndex(where: { $0.id == destination.objectID }) else { throw CancellationError() }
        project.objects[index] = resultObject
      }
      self.draft?.status = .succeeded; self.draft?.resultElementID = imageID
      self.draft?.resultAssetID = asset.id; self.draft?.generationID = provenance.id
      progress = 1; error = nil; store.changed()
      if selectResult { store.artworkSession.choose([imageID]) }
    } catch { try? FileManager.default.removeItem(at: file); throw error }
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
