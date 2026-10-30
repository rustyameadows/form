import AppKit
import FormCore
import SwiftUI

/// Shared actions keep the canvas dock and inspector consistent. Alignment is
/// measured in canvas coordinates, even when selected objects have different parents.
struct CanvasArrangementAction: Identifiable {
  let title: String
  let symbol: String
  let command: String
  let mode: String
  var id: String { command + "." + mode }
  var minimumSelection: Int { command == "distribute" ? 3 : 2 }

  static let alignment: [Self] = [
    .init(title: "Align left", symbol: "align.horizontal.left", command: "align", mode: "left"),
    .init(title: "Align horizontal centers", symbol: "align.horizontal.center", command: "align", mode: "center_x"),
    .init(title: "Align right", symbol: "align.horizontal.right", command: "align", mode: "right"),
    .init(title: "Align top", symbol: "align.vertical.top", command: "align", mode: "top"),
    .init(title: "Align vertical centers", symbol: "align.vertical.center", command: "align", mode: "center_y"),
    .init(title: "Align bottom", symbol: "align.vertical.bottom", command: "align", mode: "bottom"),
  ]
  static let distribution: [Self] = [
    .init(title: "Distribute horizontal spacing", symbol: "distribute.horizontal.left", command: "distribute", mode: "horizontal"),
    .init(title: "Distribute vertical spacing", symbol: "distribute.vertical.top", command: "distribute", mode: "vertical"),
    .init(title: "Distribute horizontal centers", symbol: "distribute.horizontal.center", command: "distribute", mode: "horizontal_centers"),
    .init(title: "Distribute vertical centers", symbol: "distribute.vertical.center", command: "distribute", mode: "vertical_centers"),
  ]

  @MainActor func isEnabled(in session: ArtworkSession) -> Bool {
    guard session.activeCanvasFrame?.editable == true else { return false }
    let artwork = session.art, roots = artwork.selectionRoots(session.selection)
    return roots.count >= minimumSelection && roots.allSatisfy { !artwork.isLocked($0) }
  }
  @MainActor func perform(in session: ArtworkSession) {
    session.canvas?.prepareForGroupNavigation()
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    session.canvas?.finishText()
    session.endGesture()
    guard isEnabled(in: session) else { return }
    session.execute(command, ["mode": mode])
    session.canvas?.synchronize()
    session.canvas?.window?.makeFirstResponder(session.canvas)
  }
}

private struct CanvasArrangementMenuItems: View {
  @ObservedObject var session: ArtworkSession
  let actions: [CanvasArrangementAction]
  var body: some View {
    ForEach(actions) { action in
      Button(action.title, systemImage: action.symbol) { action.perform(in: session) }
        .disabled(!action.isEnabled(in: session))
    }
  }
}

struct CanvasArrangementMenu: View {
  @ObservedObject var session: ArtworkSession
  var body: some View {
    Menu {
      CanvasArrangementMenuItems(session: session, actions: CanvasArrangementAction.alignment)
      Divider()
      CanvasArrangementMenuItems(session: session, actions: CanvasArrangementAction.distribution)
    } label: {
      WorkspaceToolbarMenuLabel(symbol: "align.horizontal.left")
    }.menuStyle(.borderlessButton).fixedSize()
      .help("Align and distribute selected objects")
      .accessibilityLabel("Align and distribute")
      .disabled(!CanvasArrangementAction.alignment[0].isEnabled(in: session))
  }
}

struct CanvasArrangementControls: View {
  @ObservedObject var session: ArtworkSession
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: WorkspaceToolbarMetrics.spacing) {
        ForEach(CanvasArrangementAction.alignment) { action in
          WorkspaceToolbarButton(action.title, symbol: action.symbol,
            identifier: "canvas-" + action.id) { action.perform(in: session) }
            .disabled(!action.isEnabled(in: session))
        }
      }
      Menu("Distribute") {
        CanvasArrangementMenuItems(session: session, actions: CanvasArrangementAction.distribution)
      }.disabled(!CanvasArrangementAction.distribution[0].isEnabled(in: session))
        .help("Distribute three or more objects by spacing or center")
    }
  }
}
