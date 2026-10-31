import AppKit
import FormCore
import FormGraphics

/// While text is open, collection edits join its native Undo timeline. Ending
/// the editor retains the same single document history group as other native
/// text edits; the portable collection remains independent of text contents.
@MainActor private final class ProjectFontTextHistory {
  weak var view: CanvasTextView?
  weak var manager: UndoManager?
  let projectID: UUID
  let epoch: UUID
  let interaction: UUID
  let key: String
  init(view: CanvasTextView, manager: UndoManager, projectID: UUID, epoch: UUID,
    interaction: UUID, key: String) {
    self.view = view; self.manager = manager; self.projectID = projectID
    self.epoch = epoch; self.interaction = interaction; self.key = key
  }
}

extension ArtworkSession {
  /// Saved choices intentionally include missing and currently unused faces.
  var projectFontNames: [String] { store?.project?.fontLibrary?.faceNames ?? [] }
  /// Derived assignments are not persisted into the saved collection.
  var projectUsedFontNames: [String] {
    guard let project = store?.project else { return [] }
    return Set(FontUsage.uses(in: project).map(\.fontName)).sorted()
  }
  func isProjectFont(_ name: String) -> Bool {
    guard ProjectFontLibrary.validFaceName(name) else { return false }
    let canonical = FontLibraryCatalog.canonicalName(name)
    return projectFontNames.contains { FontLibraryCatalog.canonicalName($0) == canonical }
  }

  @discardableResult func toggleProjectFont(_ name: String, projectID expectedID: UUID? = nil) -> Bool {
    guard let store, let project = store.project else { return false }
    guard expectedID == nil || expectedID == project.id else {
      store.error = "The project changed. Choose the font again in the current project's library."
      return false
    }
    let saved = !isProjectFont(name)
    do {
      guard ProjectFontLibrary.validFaceName(name) else { throw FormError.invalid("Choose a valid exact font face name.") }
      var library = project.fontLibrary ?? .init()
      if saved { try library.setSaved(name, saved: true) }
      else {
        let canonical = FontLibraryCatalog.canonicalName(name)
        for stored in library.faceNames where FontLibraryCatalog.canonicalName(stored) == canonical {
          try library.setSaved(stored, saved: false)
        }
      }
      let next: ProjectFontLibrary? = library.faceNames.isEmpty ? nil : library
      let label = saved ? "Saved font to project" : "Removed font from project"
      if editingText, let canvas, let view = canvas.activeTextView, let manager = view.undoManager,
        let objectID {
        guard !canvas.hasMarkedTextInput else {
          throw FormError.invalid("Finish the current text input before saving a project font.")
        }
        let key = canvas.storyEditor.map { "story-\($0.storyID)" } ?? "artwork-\(objectID)"
        let token = store.engine.beginInteraction(key)
        let history = ProjectFontTextHistory(view: view, manager: manager, projectID: project.id,
          epoch: store.artworkTransferProjectEpoch, interaction: token, key: key)
        view.breakUndoCoalescing()
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping(); view.breakUndoCoalescing() }
        try setProjectFontLibrary(next, replacing: project.fontLibrary, label: label, history: history)
        return true
      }
      try store.engine.edit(label) { value in
        guard value.id == project.id else { throw FormError.invalid("The project changed before the font was saved.") }
        value.fontLibrary = next
      }
      store.metadataRecordsChanged()
      return true
    } catch { store.error = error.localizedDescription; return false }
  }

  private func setProjectFontLibrary(_ next: ProjectFontLibrary?, replacing previous: ProjectFontLibrary?,
    label: String, history: ProjectFontTextHistory) throws {
    guard let store, let manager = history.manager, history.view?.window != nil,
      canvas?.activeTextView?.undoManager === manager, editingText,
      store.project?.id == history.projectID, store.artworkTransferProjectEpoch == history.epoch,
      store.engine.isInteracting(withGeneration: history.interaction),
      store.project?.fontLibrary == previous else {
      throw FormError.invalid("The project or text editing session changed. Reopen the font library for the current project.")
    }
    try store.engine.edit(label, coalescing: history.key) { $0.fontLibrary = next }
    manager.registerUndo(withTarget: self) { session in
      do { try session.setProjectFontLibrary(previous, replacing: next, label: label, history: history) }
      catch { session.store?.error = error.localizedDescription }
    }
    manager.setActionName(label)
    store.metadataRecordsChanged()
  }
}
