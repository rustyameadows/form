import SwiftUI

/// These actions copy a captured identity without selecting its row, finishing
/// a text edit, navigating to another surface, or saving a Studio draft.
struct SelectionReferenceMenuActions: View {
  @ObservedObject var store: StudioStore
  let reference: LABSelectionReference?
  var multiple = false
  var body: some View {
    Button("Copy reference") { store.copySelectionReference(reference) }
      .accessibilityIdentifier("copy-selection-reference")
      .disabled(reference == nil)
    Button(multiple ? "Copy IDs" : "Copy ID") { store.copySelectionReference(reference, idsOnly: true) }
      .accessibilityIdentifier("copy-selection-ids")
      .disabled(reference == nil)
  }
}

struct SelectionReferenceCommands: Commands {
  @ObservedObject var store: StudioStore
  @ObservedObject private var composition: StudioCompositionController
  @ObservedObject private var shots: StudioShotController
  init(store: StudioStore) {
    self.store = store; composition = store.studioComposition; shots = store.studioShots
  }
  var body: some Commands {
    CommandGroup(after: .pasteboard) {
      Button("Copy reference") { store.copySelectionReference(store.currentSelectionReference) }
        .keyboardShortcut("c", modifiers: [.command, .option])
        .disabled(store.currentSelectionReference == nil)
      Button("Copy IDs") { store.copySelectionReference(store.currentSelectionReference, idsOnly: true) }
        .disabled(store.currentSelectionReference == nil)
    }
  }
}
