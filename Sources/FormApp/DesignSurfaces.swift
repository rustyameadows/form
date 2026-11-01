import AppKit
import FormCore
import SwiftUI

enum DesignSurfaceLayout: String { case single, split, detached }
enum DesignSurfaceSplitDirection: String, CaseIterable {
  case sideBySide, stacked
}

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
    if surface == .studio { showEnvironment(.studio); return }
    if environment == .studio { showEnvironment(.form) }
    if surfaceLayout == .detached, surface == .artwork {
      canvasWindowController?.showWindow(nil)
      canvasWindowController?.window?.makeKeyAndOrderFront(nil)
      return
    }
    if surface == .table { finishArtworkEditing() }
    if surfaceLayout != .detached || surface == .studio {
      closeDetachedCanvas()
      surfaceLayout = .single
    }
    showingHome = false
    mode = surface
    if surface == .artwork { _ = ensureCanvas() }
    designSurfaceHost?.refresh()
  }

  func showSplit(_ direction: DesignSurfaceSplitDirection? = nil) {
    guard project != nil else { return }
    if environment == .studio { showEnvironment(.form) }
    closeDetachedCanvas()
    if let direction { splitDirection = direction }
    _ = ensureCanvas()
    surfaceLayout = .split
    showingHome = false
    if mode == .studio { mode = .table }
    designSurfaceHost?.refresh()
  }

  func detachCanvas() {
    guard project != nil else { return }
    if environment == .studio { showEnvironment(.form) }
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
    designSurfaceHost?.refresh()
  }

  func closeDetachedCanvas() {
    guard let controller = canvasWindowController else { return }
    finishArtworkEditing()
    surfaceLayout = .single
    canvasWindowController = nil
    controller.returnCanvasToMain()
    controller.close()
    controller.window?.contentView = nil
  }
}

/// Owns each SwiftUI graph once. Display layout only reparents its existing
/// native host; neither rootView nor its State graph is replaced on a view switch.
@MainActor final class DesignSurfaceHostController: NSObject, NSSplitViewDelegate {
  weak var store: StudioStore?
  private(set) var canvasHost: NSHostingView<AnyView>?
  private(set) var tableHost: NSHostingView<AnyView>?
  private weak var mainView: DesignSurfaceSplitView?
  private weak var detachedOwner: CanvasWindowController?
  private var fractions: [DesignSurfaceSplitDirection: CGFloat] = [.sideBySide: 0.5, .stacked: 0.5]
  private var applyingLayout = false
  private var inputMonitor: Any?
  private var keyWindowObservation:NSObjectProtocol?
  private var projectID: UUID?

  init(store: StudioStore) {
    self.store = store; projectID = store.project?.id
    super.init()
    store.designSurfaceHost = self
    inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
      MainActor.assumeIsolated { self?.observeFocus(event) }
      return event
    }
    keyWindowObservation=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:nil,queue:.main) { [weak self] notification in
      MainActor.assumeIsolated {self?.observeWindowFocus(notification)}
    }
  }
  deinit {
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    if let keyWindowObservation {NotificationCenter.default.removeObserver(keyWindowObservation)}
  }

  private func host(_ content: AnyView) -> NSHostingView<AnyView> {
    let view = NSHostingView(rootView: content)
    view.frame = .init(x: 0, y: 0, width: 1000, height: 760)
    view.autoresizingMask = []
    view.clipsToBounds = true
    return view
  }
  func canvas() -> NSHostingView<AnyView> {
    if let canvasHost { return canvasHost }
    guard let store else { preconditionFailure("The design workspace was closed") }
    let view = host(AnyView(ArtworkStudio(session: store.artworkSession).environmentObject(store).labInterface()))
    canvasHost = view
    return view
  }
  private func table() -> NSHostingView<AnyView> {
    if let tableHost { return tableHost }
    guard let store else { preconditionFailure("The design workspace was closed") }
    let view = host(AnyView(TableWorkspace().environmentObject(store).labInterface()))
    tableHost = view
    return view
  }
  func attachMain(_ view: DesignSurfaceSplitView) {
    mainView = view; view.controller = self; view.delegate = self
    refresh()
  }
  func detachMain(_ view: DesignSurfaceSplitView) {
    guard mainView === view else { return }
    view.subviews.forEach { $0.removeFromSuperview() }
    view.delegate = nil; view.controller = nil; mainView = nil
  }
  func attachDetached(_ owner: CanvasWindowController) {
    detachedOwner = owner
    canvasHost?.removeFromSuperview()
    refresh()
  }
  func returnDetached(_ owner: CanvasWindowController) {
    guard detachedOwner === owner else { return }
    detachedOwner = nil
    canvasHost?.removeFromSuperview()
    refresh()
  }
  func resetForProjectChange() {
    canvasHost?.removeFromSuperview(); tableHost?.removeFromSuperview()
    canvasHost = nil; tableHost = nil
    fractions = [.sideBySide: 0.5, .stacked: 0.5]
    projectID = store?.project?.id
  }
  func refresh() {
    guard let store, let view = mainView else { return }
    if projectID != store.project?.id { resetForProjectChange() }
    guard store.project != nil, !store.showingHome else {
      view.subviews.forEach { $0.removeFromSuperview() }; return
    }
    let desired: [NSView]
    if store.surfaceLayout == .split, detachedOwner == nil { desired = [canvas(), table()] }
    else if detachedOwner != nil || store.surfaceLayout == .detached || store.mode != .artwork { desired = [table()] }
    else { desired = [canvas()] }
    applyingLayout = true
    defer { applyingLayout = false }
    let direction = store.splitDirection
    view.isVertical = direction == .sideBySide
    if view.subviews.count != desired.count || zip(view.subviews, desired).contains(where: { $0.0 !== $0.1 }) {
      // A still-visible pane must not transiently leave its NSWindow: doing so
      // can resign an active text editor and end marked-text composition.
      for child in view.subviews where !desired.contains(where: { $0 === child }) { child.removeFromSuperview() }
      for (index, child) in desired.enumerated() where child.superview !== view {
        child.removeFromSuperview()
        if index == 0, let following = view.subviews.first { view.addSubview(child, positioned: .below, relativeTo: following) }
        else { view.addSubview(child) }
      }
    }
    layoutPanes(view)
  }
  func layoutPanes(_ view: DesignSurfaceSplitView) {
    guard let store, view.bounds.width > 0, view.bounds.height > 0 else { return }
    let old = applyingLayout; applyingLayout = true; defer { applyingLayout = old }
    if view.subviews.count == 1 { view.subviews[0].frame = view.bounds; return }
    guard view.subviews.count == 2 else { return }
    let vertical = view.isVertical, length = (vertical ? view.bounds.width : view.bounds.height) - view.dividerThickness
    guard length > 0 else { return }
    let fraction = fractions[store.splitDirection] ?? 0.5
    let firstMinimum = min(vertical ? 440.0 : 220.0, length * 0.45)
    let secondMinimum = min(vertical ? 360.0 : 220.0, length * 0.4)
    let first = min(length - secondMinimum, max(firstMinimum, length * fraction))
    if vertical {
      view.subviews[0].frame = .init(x: 0, y: 0, width: first, height: view.bounds.height)
      view.subviews[1].frame = .init(x: first + view.dividerThickness, y: 0, width: length - first, height: view.bounds.height)
    } else {
      view.subviews[0].frame = .init(x: 0, y: 0, width: view.bounds.width, height: first)
      view.subviews[1].frame = .init(x: 0, y: first + view.dividerThickness, width: view.bounds.width, height: length - first)
    }
  }
  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard !applyingLayout, let store, let view = notification.object as? DesignSurfaceSplitView,
      view.subviews.count == 2 else { return }
    let available = (view.isVertical ? view.bounds.width : view.bounds.height) - view.dividerThickness
    guard available > 0 else { return }
    let first = view.isVertical ? view.subviews[0].frame.width : view.subviews[0].frame.height
    fractions[store.splitDirection] = first / available
  }
  func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
    min(splitView.isVertical ? 440 : 220, (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) * 0.45)
  }
  func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
    let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    return length - splitView.dividerThickness - min(splitView.isVertical ? 360 : 220, length * 0.4)
  }
  private func observeWindowFocus(_ notification:Notification) {
    guard let store,store.project != nil,!store.showingHome,
      let window=notification.object as? NSWindow,let mainView,mainView.window === window,
      !mainView.isHiddenOrHasHiddenAncestor else{return}
    let surfaces:[(NSView?,WorkspaceMode)]=[(canvasHost,.artwork),(tableHost,.table)]
    let visible=surfaces.filter {host,_ in
      guard let host else{return false}
      return host.superview === mainView && !host.isHiddenOrHasHiddenAncestor
    }
    // Returning from the separate Canvas window to a single Table pane is an
    // actual surface change. Returning from another app to a split workspace
    // must retain the last LAB pane, even when its native responder is stale.
    if visible.count==1 {store.activateDesignSurface(visible[0].1)}
  }
  private func observeFocus(_ event: NSEvent) {
    guard let store,store.project != nil,!store.showingHome,let window = event.window else { return }
    for (host, surface) in [(canvasHost, WorkspaceMode.artwork), (tableHost, .table)] {
      guard let host, host.window === window, host.superview != nil, !host.isHiddenOrHasHiddenAncestor else { continue }
      if event.type == .keyDown {
        // A SwiftUI panel button can leave the old pane's native canvas as first
        // responder. Retain its pointer-established mode; only an actual native
        // text/control focus should override it during keyboard navigation.
        var responder = window.firstResponder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSView }
        guard responder is NSTextView || responder is NSControl else { continue }
        if let responder, responder === host || responder.isDescendant(of: host) { store.activateDesignSurface(surface); return }
      } else if host.visibleRect.contains(host.convert(event.locationInWindow, from: nil)) {
        store.activateDesignSurface(surface); return
      }
    }
  }
}

@MainActor final class DesignSurfaceSplitView: NSSplitView {
  weak var controller: DesignSurfaceHostController?
  override var isFlipped: Bool { true }
  override func resizeSubviews(withOldSize oldSize: NSSize) { controller?.layoutPanes(self) }
}

/// Keeps the two lazy graphs alive when a different project environment is
/// displayed. Home/project boundaries explicitly clear them, not display modes.
struct DesignSurfaceLifecyclePresenter: NSViewRepresentable {
  @ObservedObject var store: StudioStore
  @MainActor final class Coordinator {
    var controller: DesignSurfaceHostController?
    func bind(_ store: StudioStore) {
      if controller?.store !== store { controller = store.designSurfaceHost ?? DesignSurfaceHostController(store: store) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    context.coordinator.bind(store)
    return NSView(frame: .zero)
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.bind(store) }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.controller?.store?.closeDetachedCanvas()
    coordinator.controller?.resetForProjectChange()
    coordinator.controller = nil
  }
}

struct DesignSurfaceWorkspace: NSViewRepresentable {
  @ObservedObject var store: StudioStore
  @MainActor final class Coordinator {
    var controller: DesignSurfaceHostController?
    func bind(_ store: StudioStore, view: DesignSurfaceSplitView) {
      if controller?.store !== store {
        if let controller { controller.detachMain(view) }
        controller = store.designSurfaceHost ?? DesignSurfaceHostController(store: store)
      }
      controller?.attachMain(view)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> DesignSurfaceSplitView {
    let view = DesignSurfaceSplitView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
    view.dividerStyle = .thin
    context.coordinator.bind(store, view: view)
    return view
  }
  func updateNSView(_ view: DesignSurfaceSplitView, context: Context) { context.coordinator.bind(store, view: view) }
  static func dismantleNSView(_ view: DesignSurfaceSplitView, coordinator: Coordinator) {
    coordinator.controller?.detachMain(view); coordinator.controller = nil
  }
}

@MainActor final class CanvasWindowController: NSWindowController, NSWindowDelegate {
  weak var store: StudioStore?
  private let hosts: DesignSurfaceHostController
  init(store: StudioStore) {
    self.store = store
    hosts = store.designSurfaceHost ?? DesignSurfaceHostController(store: store)
    let window = NSWindow(contentRect:.init(x:0,y:0,width:1160,height:820),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = "\(store.project?.name ?? "LAB") · Canvas"
    window.minSize = .init(width:860,height:600)
    window.isReleasedWhenClosed = false
    super.init(window:window)
    window.delegate = self
    hosts.attachDetached(self)
    window.contentView = DetachedCanvasHost(store: store, canvas: hosts.canvas())
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  func returnCanvasToMain() { hosts.returnDetached(self) }
  func windowDidBecomeKey(_ notification: Notification) {
    guard let store,store.project != nil,!store.showingHome,store.surfaceLayout == .detached,
      store.canvasWindowController === self,notification.object as? NSWindow === window else { return }
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
    hosts.returnDetached(self)
  }
}

@MainActor private final class DetachedCanvasHost: NSView {
  private let heading: NSHostingView<AnyView>
  private let canvas: NSView
  override var isFlipped: Bool { true }
  init(store: StudioStore, canvas: NSView) {
    self.canvas = canvas
    heading = NSHostingView(rootView: AnyView(DetachedCanvasHeading().environmentObject(store).labInterface()))
    super.init(frame: .init(x: 0, y: 0, width: 1160, height: 820))
    addSubview(heading); canvas.removeFromSuperview(); addSubview(canvas)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func layout() {
    super.layout()
    heading.frame = .init(x: 0, y: 0, width: bounds.width, height: 42)
    if canvas.superview === self {
      canvas.frame = .init(x: 0, y: 43, width: bounds.width, height: max(1, bounds.height - 43))
    }
  }
}

private struct DetachedCanvasHeading: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    HStack {
      Text("Canvas").font(.system(size:13,weight:.semibold))
      Text(store.project?.name ?? "").font(.system(size:12)).foregroundStyle(Palette.secondary)
      Spacer()
      Button("Dock beside Table") { store.dockCanvas() }.buttonStyle(.borderless)
    }.padding(.horizontal,18).frame(height:42).background(Palette.paper)
      .onChange(of:store.project?.name) { _,_ in
        store.canvasWindowController?.window?.title = "\(store.project?.name ?? "LAB") · Canvas"
      }
  }
}
