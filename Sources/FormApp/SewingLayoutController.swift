import AppKit
import FormCore
import FormGraphics
import SwiftUI

@MainActor final class SewingLayoutController: ObservableObject {
  weak var store: StudioStore?
  let projectID: UUID?
  let objectID: UUID?
  @Published private(set) var source: Artwork
  @Published var layout: SewingCutLayout
  @Published private(set) var report: SewingLayoutPreflight?
  @Published private(set) var checking = false
  @Published private(set) var planning = false
  @Published private(set) var sourceAvailable = true
  @Published private(set) var error = ""
  @Published private(set) var notice = ""
  @Published private(set) var externalEpoch = 0
  @Published var selectedID: UUID?
  @Published var showFabric = true
  @Published var fitRequest = 0
  @Published private(set) var inputErrors = Set<String>()
  @Published private(set) var unsaved = false
  private var savedLayout: SewingCutLayout?
  private var geometry: [UUID: SewingPieceGeometry] = [:]
  private var checkTask: Task<Void, Never>?
  private var sequence = 0
  private var lastLocked = false
  private var dragStart: SewingCutLayout?
  private(set) var dragging = false
  var gestureKey: String { "cut-layout-\(objectID?.uuidString ?? "none")" }
  var assets: URL {
    guard let store, let projectID else { return URL(fileURLWithPath: "/") }
    return store.repository.url(for: projectID).appendingPathComponent("Assets")
  }
  var sourceName: String { store?.project?.objects.first { $0.id == objectID }?.name ?? "Source document" }
  var previewPlacements: [SewingLayoutResolvedPlacement] {
    layout.placements.compactMap { p in
      guard [p.x,p.y,p.rotation].allSatisfy(\.isFinite), abs(p.x) <= 100000, abs(p.y) <= 100000, abs(p.rotation) <= 36000 else { return nil }
      return geometry[p.elementID].map { SewingLayoutGeometry.resolve(p, geometry: $0) }
    }
  }
  var selected: SewingCutPlacement? { layout.placements.first { $0.id == selectedID } }
  var canEdit: Bool { sourceAvailable && store?.project?.id == projectID && store?.project?.objects.first(where: { $0.id == objectID })?.locked == false }
  var canExport: Bool { sourceAvailable && !unsaved && inputErrors.isEmpty && !checking && !planning && report?.isValid == true }
  var canPlan: Bool { canEdit && inputErrors.isEmpty && !planning && (try? layout.validateMetadata()) != nil }
  init(session: ArtworkSession) {
    store = session.store; projectID = session.store?.project?.id
    if let p = session.store?.project, let object = session.object { objectID = p.artworkOwner(object).id }
    else { objectID = nil }
    let art = session.art; source = art; savedLayout = art.sewingLayout
    let materialID = art.sewingLayout?.materialID ?? art.elements.compactMap { $0.sewingPiece?.materialID }.first ?? ""
    let material = session.store?.materials.first { $0.id == materialID }
    layout = art.sewingLayout ?? SewingCutLayout(materialID: materialID, stockWidth: material?.fabric?.usableWidth.flatMap { $0 > 0 ? $0 : nil })
    lastLocked = session.store?.project?.objects.first { $0.id == objectID }?.locked ?? false
    rebuildGeometry(); scheduleCheck(immediate: true)
  }
  private func rebuildGeometry() {
    geometry = Dictionary(uniqueKeysWithValues: source.elements.compactMap { e -> (UUID, SewingPieceGeometry)? in
      guard e.sewingPiece != nil, let value = try? SewingPatterns.geometry(e, in: source) else { return nil }; return (e.id, value)
    })
  }
  @discardableResult func refreshContext() -> Bool {
    guard let store, let p = store.project, p.id == projectID, let objectID,
      let object = p.objects.first(where: { $0.id == objectID }), let latest = p.editableArtwork(object) else {
      if sourceAvailable { externalEpoch += 1; sequence += 1; checkTask?.cancel() }
      dragging = false; sourceAvailable = false; error = "The source document is no longer open."; report = nil; return false
    }
    sourceAvailable = true
    let externalLayout = latest.sewingLayout != savedLayout
    let changedGeometry = latest.elements != source.elements || latest.sewingSeams != source.sewingSeams
    let lockChanged = object.locked != lastLocked; lastLocked = object.locked
    if externalLayout || changedGeometry || lockChanged {
      endDrag()
      externalEpoch += 1; inputErrors = []
      if externalLayout || lockChanged {
        savedLayout = latest.sewingLayout
        if let replacement = latest.sewingLayout { layout = replacement }
        else {
          let id = latest.elements.compactMap { $0.sewingPiece?.materialID }.first ?? layout.materialID
          let fabric = store.materials.first { $0.id == id }?.fabric
          layout = SewingCutLayout(materialID: id, stockWidth: fabric?.usableWidth.flatMap { $0 > 0 ? $0 : nil })
        }
        unsaved = false
        notice = "Loaded the layout updated in the document."
      }
      source = latest; rebuildGeometry(); scheduleCheck(immediate: true)
    } else { source = latest }
    return true
  }
  func setInputError(_ key: String, invalid: Bool) {
    if invalid { inputErrors.insert(key) } else { inputErrors.remove(key) }
  }
  func edit(_ change: (inout SewingCutLayout) -> Void) {
    guard refreshContext(), canEdit else { return }
    var candidate = layout; change(&candidate)
    if candidate == layout { return }
    layout = candidate; notice = ""; unsaved = true
    do { try persist(); error = "" } catch { self.error = error.localizedDescription }
    scheduleCheck()
  }
  func editPlacement(_ id: UUID, _ change: (inout SewingCutPlacement) -> Void) {
    edit { l in guard let index = l.placements.firstIndex(where: { $0.id == id }) else { return }; change(&l.placements[index]) }
  }
  func removePlacement(_ id: UUID) { edit { $0.placements.removeAll { $0.id == id } }; if selectedID == id { selectedID = nil } }
  func chooseMaterial(_ material: FormCore.Material) {
    edit { $0.materialID = material.id; $0.stockWidth = material.fabric?.usableWidth.flatMap { $0 > 0 ? $0 : nil } }
  }
  private func persist() throws {
    guard inputErrors.isEmpty else { throw FormError.invalid("Finish the invalid numeric field before saving layout changes.") }
    try layout.validateMetadata()
    guard let store, let p = store.project, p.id == projectID, let objectID,
      let owner = p.objects.first(where: { $0.id == objectID }), !owner.locked,
      let material = store.materials.first(where: { $0.id == layout.materialID }), material.fabric != nil else {
      throw FormError.invalid("Choose an unlocked source document and a known fabric material.")
    }
    let value = layout
    try store.engine.edit(dragging ? "Moved cutting-layout piece" : "Edited cutting layout", source: "Studio", coalescing: dragging ? gestureKey : nil) { project in
      if project.material(material.id).id != material.id { project.materials.append(material) }
      guard let target = project.objects.first(where: { $0.id == objectID }), var art = project.editableArtwork(target) else { throw FormError.missing("The cutting source is missing.") }
      art.sewingLayout = value; try project.setArtwork(art, for: objectID)
    }
    savedLayout = value
    unsaved = false
    if let updated = store.project?.objects.first(where: { $0.id == objectID }).flatMap({ store.project?.editableArtwork($0) }) { source = updated }
    store.changed(save: !dragging)
  }
  func beginDrag() -> Int? {
    guard refreshContext(), canEdit, inputErrors.isEmpty, (try? layout.validateMetadata()) != nil, let store else { return nil }
    sequence += 1; checkTask?.cancel(); planning = false
    store.engine.beginInteraction(gestureKey); dragStart = layout; dragging = true; return externalEpoch
  }
  func move(_ id: UUID, x: Double, y: Double, epoch: Int) {
    guard refreshContext(), epoch == externalEpoch, dragging else { return }
    editPlacement(id) { $0.x = x; $0.y = y }
  }
  func endDrag() {
    guard dragging else { return }; dragging = false; dragStart = nil
    if store?.project?.id == projectID { store?.engine.endInteraction(); store?.changed() }
    scheduleCheck(immediate: true)
  }
  func restoreDrag() {
    guard refreshContext(), dragging, let original = dragStart else { return }
    layout = original; unsaved = true
    do { try persist() } catch { self.error = error.localizedDescription }
    endDrag(); externalEpoch += 1
  }
  func finish() { endDrag(); sequence += 1; checkTask?.cancel() }
  func commitFields() -> Bool {
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil); NSApp.keyWindow?.makeFirstResponder(nil)
    guard inputErrors.isEmpty else { error = "Correct the invalid numeric field before continuing."; return false }
    guard !unsaved else { return false }
    return true
  }
  private func scheduleCheck(immediate: Bool = false) {
    sequence += 1; let token = sequence
    checkTask?.cancel(); checking = true
    let captured = layout, source = self.source
    checkTask = Task { [weak self] in
      if !immediate { try? await Task.sleep(for: .milliseconds(35)) }
      guard !Task.isCancelled else { return }
      let result = await Task.detached(priority: .userInitiated) { Result { try SewingLayouts.preflight(captured, source: source) } }.value
      guard let self, self.sequence == token, self.sourceAvailable else { return }
      self.checking = false
      switch result {
      case .success(let report): self.report = report; if self.inputErrors.isEmpty && !self.unsaved { self.error = "" }
      case .failure(let error): self.report = nil; self.error = error.localizedDescription
      }
    }
  }
  func plan() {
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil); NSApp.keyWindow?.makeFirstResponder(nil)
    guard refreshContext(), canPlan else { return }
    endDrag(); sequence += 1; let token = sequence
    checkTask?.cancel(); planning = true; checking = true; error = ""
    let captured = layout, source = self.source
    checkTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) { Result { try SewingLayouts.planned(captured, source: source) } }.value
      guard let self, self.sequence == token, self.sourceAvailable else { return }
      self.planning = false; self.checking = false
      switch result {
      case .success(let value):
        self.layout = value.layout; self.report = value.preflight; self.unsaved = true
        do { try self.persist(); self.notice = "Planned \(value.layout.placements.count) placements in \(value.preflight.candidateChecks) bounded candidate checks." }
        catch { self.error = error.localizedDescription }
      case .failure(let error): self.error = error.localizedDescription
      }
    }
  }
  func removeLayout() {
    guard refreshContext(), let store, let objectID else { return }
    endDrag()
    do {
      _ = try store.engine.call("form_edit_artwork", arguments: ["object_id": objectID.uuidString, "command": "cut_layout", "cutting_layout": NSNull()])
      savedLayout = nil; layout.placements = []; selectedID = nil; unsaved = false; store.changed(); scheduleCheck(immediate: true)
    } catch { self.error = error.localizedDescription }
  }
  func fabricReference() -> (design: ResolvedFabricPattern?, color: String) {
    guard let p = store?.project, p.id == projectID else { return (nil, "#DDD5C5") }
    let material = p.material(layout.materialID)
    var design = try? p.resolvedFabricPattern(materialID: layout.materialID)
    if design != nil {
      design!.pattern.offset.x += layout.fabricOrigin.x - (layout.stock == .foldedPair ? (layout.stockWidth ?? 0)/2 : 0)
      design!.pattern.offset.y += layout.fabricOrigin.y
    }
    return (design, material.color)
  }
}
