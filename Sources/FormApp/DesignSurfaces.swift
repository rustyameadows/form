import AppKit
import FormCore
import SwiftUI

enum DesignSurfaceLayout: String { case single, split, detached }

private struct DesignSurfaceFocusKey: FocusedValueKey { typealias Value = WorkspaceMode }
extension FocusedValues {
  var designSurface: WorkspaceMode? {
    get { self[DesignSurfaceFocusKey.self] }
    set { self[DesignSurfaceFocusKey.self] = newValue }
  }
}

extension StudioStore {
  @discardableResult func ensureCanvas() -> UUID? {
    guard project != nil else { return nil }
    do {
      if project?.canvasWorkspace == nil {
        try engine.edit("Created freeform Canvas") { _ = try $0.ensureCanvasWorkspace() }
        changed()
      }
      let id = project?.canvasWorkspace?.id
      if artworkSession.object == nil { artworkSession.objectID = id }
      return id
    } catch { self.error = error.localizedDescription; return nil }
  }

  func activateDesignSurface(_ surface: WorkspaceMode) {
    // Studio uses the same 3D surface. Pointer focus must retain its presentation settings.
    if surface == .table, mode == .studio { return }
    if mode != surface { mode = surface }
  }

  func showSurface(_ surface: WorkspaceMode) {
    guard project != nil else { return }
    if surfaceLayout == .detached, surface == .artwork {
      canvasWindowController?.showWindow(nil)
      canvasWindowController?.window?.makeKeyAndOrderFront(nil)
      return
    }
    finishArtworkEditing()
    if surfaceLayout != .detached || surface == .studio {
      closeDetachedCanvas()
      surfaceLayout = .single
    }
    showingHome = false
    mode = surface
    if surface == .artwork, let id = ensureCanvas() {
      artworkSession.activate(id)
    }
  }

  func showSplit() {
    guard project != nil else { return }
    finishArtworkEditing()
    closeDetachedCanvas()
    _ = ensureCanvas()
    surfaceLayout = .split
    showingHome = false
    mode = .artwork
  }

  func detachCanvas() {
    guard project != nil else { return }
    if surfaceLayout == .detached, let controller = canvasWindowController {
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    finishArtworkEditing()
    _ = ensureCanvas()
    surfaceLayout = .detached
    showingHome = false
    mode = .table
    let controller = CanvasWindowController(store:self)
    canvasWindowController = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  func dockCanvas() {
    finishArtworkEditing()
    closeDetachedCanvas()
    surfaceLayout = .split
    mode = .artwork
  }

  func closeDetachedCanvas() {
    guard let controller = canvasWindowController else { return }
    finishArtworkEditing()
    surfaceLayout = .single
    canvasWindowController = nil
    controller.close()
    controller.window?.contentView = nil
  }
}

@MainActor final class CanvasWindowController: NSWindowController, NSWindowDelegate {
  weak var store: StudioStore?
  init(store: StudioStore) {
    self.store = store
    let window = NSWindow(contentRect:.init(x:0,y:0,width:1160,height:820),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = "\(store.project?.name ?? "LAB") · Canvas"
    window.minSize = .init(width:860,height:600)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView:DetachedCanvasView().environmentObject(store))
    super.init(window:window)
    window.delegate = self
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  func windowDidBecomeKey(_ notification: Notification) {
    guard let store, store.canvasWindowController === self else { return }
    store.activateDesignSurface(.artwork)
  }
  func windowWillClose(_ notification: Notification) {
    defer { window?.contentView = nil }
    guard let store, store.surfaceLayout == .detached,
      store.canvasWindowController === self else { return }
    store.finishArtworkEditing()
    store.canvasWindowController = nil
    store.surfaceLayout = .single
    store.mode = .table
  }
}

private struct DetachedCanvasView: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    VStack(spacing:0) {
      HStack {
        Text("Canvas").font(.system(size:13,weight:.semibold))
        Text(store.project?.name ?? "").font(.system(size:12)).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Dock beside Table") { store.dockCanvas() }.buttonStyle(.borderless)
      }.padding(.horizontal,18).frame(height:42).background(Palette.paper)
      Divider()
      ArtworkWorkspace()
    }.preferredColorScheme(.light)
      .onChange(of:store.project?.id) { _,_ in
        store.canvasWindowController?.window?.title = "\(store.project?.name ?? "LAB") · Canvas"
      }
  }
}
