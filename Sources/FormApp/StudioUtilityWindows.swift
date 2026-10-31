import AppKit
import Combine
import SwiftUI

/// A presenter owns these windows; the shared store keeps only a weak lifecycle hook.
/// Utility content can therefore observe the store without forming an ownership cycle.
@MainActor final class StudioUtilityWindows: NSObject, NSWindowDelegate {
  enum Kind: String, CaseIterable {
    case library, projectInfo, printPreparation, assets, openAISetup

    var title: String {
      switch self {
      case .library: return "LAB Library"
      case .projectInfo: return "Project notebook"
      case .printPreparation: return "Print preparation"
      case .assets: return "Library"
      case .openAISetup: return "OpenAI connection"
      }
    }
    var size: NSSize {
      switch self {
      case .library: return .init(width: 760, height: 740)
      case .projectInfo: return .init(width: 640, height: 650)
      case .printPreparation: return .init(width: 1120, height: 760)
      case .assets: return .init(width: 1120, height: 780)
      case .openAISetup: return .init(width: 520, height: 650)
      }
    }
    var minimumSize: NSSize {
      switch self {
      case .library: return .init(width: 680, height: 520)
      case .projectInfo: return .init(width: 590, height: 440)
      case .printPreparation: return .init(width: 980, height: 640)
      case .assets: return .init(width: 880, height: 580)
      case .openAISetup: return .init(width: 480, height: 570)
      }
    }
    var isProjectScoped: Bool { self == .projectInfo || self == .printPreparation }
  }

  private(set) weak var store: StudioStore?
  private var windows: [Kind: NSWindow] = [:]
  private var owners = Set<UUID>()
  private var subscriptions = Set<AnyCancellable>()
  private var projectID: UUID?
  private var shuttingDown = false

  init(store: StudioStore) {
    self.store = store
    projectID = store.project?.id
    super.init()
    store.utilityWindows = self
    subscribe(store.$showingLibrary, kind: .library)
    subscribe(store.$showingProjectInfo, kind: .projectInfo)
    subscribe(store.$showingPrint, kind: .printPreparation)
    subscribe(store.$showingAssets, kind: .assets)
    subscribe(store.$showingOpenAISetup, kind: .openAISetup)
    store.$showingHome.dropFirst().sink { [weak self] home in
      guard home else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.store?.showingHome == true else { return }
        self.closeProjectWindows()
      }
    }.store(in: &subscriptions)
  }

  func attach(_ owner: UUID) { owners.insert(owner) }
  func detach(_ owner: UUID) {
    owners.remove(owner)
    if owners.isEmpty { shutdown() }
  }
  func window(for kind: Kind) -> NSWindow? { windows[kind] }

  private func subscribe(_ publisher: Published<Bool>.Publisher, kind: Kind) {
    publisher.sink { [weak self] requested in
      // @Published emits in willSet. Process the completed state, and discard a
      // superseded request rather than presenting a window after a close/project change.
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.shuttingDown, self.isRequested(kind) == requested else { return }
        self.present(kind, requested: requested)
      }
    }.store(in: &subscriptions)
  }

  private func isRequested(_ kind: Kind) -> Bool {
    guard let store else { return false }
    switch kind {
    case .library: return store.showingLibrary
    case .projectInfo: return store.showingProjectInfo
    case .printPreparation: return store.showingPrint
    case .assets: return store.showingAssets
    case .openAISetup: return store.showingOpenAISetup
    }
  }
  private func setRequested(_ kind: Kind, _ value: Bool) {
    guard let store, isRequested(kind) != value else { return }
    switch kind {
    case .library: store.showingLibrary = value
    case .projectInfo: store.showingProjectInfo = value
    case .printPreparation: store.showingPrint = value
    case .assets: store.showingAssets = value
    case .openAISetup: store.showingOpenAISetup = value
    }
  }

  private func present(_ kind: Kind, requested: Bool) {
    guard let store else { return }
    guard requested else { windows[kind]?.close(); return }
    guard !kind.isProjectScoped || (store.project != nil && !store.showingHome) else {
      setRequested(kind, false)
      return
    }
    reconcileProject()
    if kind.isProjectScoped, !isRequested(kind) { return }
    let window = windows[kind] ?? makeWindow(kind, store: store)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow(_ kind: Kind, store: StudioStore) -> NSWindow {
    let window = StudioUtilityWindow(contentRect: .init(origin: .zero, size: kind.size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.identifier = .init("lab.utility." + kind.rawValue)
    window.title = kind.title
    window.contentMinSize = kind.minimumSize
    window.isReleasedWhenClosed = false
    window.delegate = self
    let close: () -> Void = { [weak self] in self?.dismiss(kind) }
    let content: AnyView
    switch kind {
    case .library: content = AnyView(LibraryView(onClose: close).environmentObject(store).labInterface())
    case .projectInfo: content = AnyView(ProjectInfoView(onClose: close).environmentObject(store).labInterface())
    case .printPreparation: content = AnyView(PrintWorkspace(printing: store.printing, onClose: close).environmentObject(store).labInterface())
    case .assets:
      content = AnyView(AssetLibraryWorkspace(library:store.studioAssets,onClose:close,
        onUseInCanvas:{[weak store] asset in store?.placeLibraryAssetOnCanvas(asset)},
        onUseAsReference:{[weak store] asset in store?.useLibraryAssetAsReference(asset)},
        onOpenGeneration:{[weak store] id in store?.reviewStudioImageRun(id)}).labInterface())
    case .openAISetup:
      content = AnyView(OpenAIConnectionPreviewView(controller:store.studioImages.connection,onClose:close).labInterface())
    }
    window.contentViewController = NSHostingController(rootView: content)
    window.center()
    windows[kind] = window
    return window
  }

  func dismiss(_ kind: Kind) {
    setRequested(kind, false)
    windows[kind]?.close()
  }

  /// Called synchronously before replacing a project or going Home, so an old
  /// field editor cannot subsequently send a notes/print edit to the next project.
  func closeProjectWindows() {
    for kind in Kind.allCases where kind.isProjectScoped {
      setRequested(kind, false)
      discardWindow(kind)
    }
    projectID = store?.project?.id
  }

  func reconcileProject() {
    guard let store else { return }
    if projectID != store.project?.id || store.showingHome {
      closeProjectWindows()
      projectID = store.project?.id
    }
  }

  private func discardWindow(_ kind: Kind) {
    guard let window = windows[kind] else { return }
    window.makeFirstResponder(nil)
    window.endEditing(for: nil)
    for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
    window.close()
    window.delegate = nil
    window.contentViewController = nil
    windows[kind] = nil
  }

  func shutdown() {
    guard !shuttingDown else { return }
    shuttingDown = true
    subscriptions.removeAll()
    for kind in Kind.allCases {
      setRequested(kind, false)
      discardWindow(kind)
    }
    if store?.utilityWindows === self { store?.utilityWindows = nil }
    store = nil
    owners = []
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let kind = windows.first(where: { $0.value === window })?.key else { return }
    setRequested(kind, false)
    if kind == .openAISetup {
      // A native traffic-light close must release preview SecureField state,
      // just like the view's own Close action. Never cache credential editors.
      window.makeFirstResponder(nil)
      window.endEditing(for:nil)
      window.delegate=nil
      window.contentViewController=nil
      windows[kind]=nil
    }
  }
}

private final class StudioUtilityWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// RootView adds this once as a zero-sized background. Multiple main windows
/// reuse the same coordinator for their shared store; the last presenter closes it.
struct StudioUtilityWindowPresenter: NSViewRepresentable {
  @ObservedObject var store: StudioStore

  @MainActor final class Coordinator {
    let owner = UUID()
    var windows: StudioUtilityWindows?
    weak var sourceStore: StudioStore?
    func bind(_ store: StudioStore) {
      sourceStore = store
      if windows?.store === store { windows?.reconcileProject(); return }
      unbind()
      windows = store.utilityWindows ?? StudioUtilityWindows(store: store)
      windows?.attach(owner)
    }
    func unbind() { windows?.detach(owner); windows = nil }
  }
  @MainActor final class HostView: NSView {
    weak var coordinator: Coordinator?
    var sourceWindowClosed = false
    private var observers = [NSObjectProtocol]()
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      clearObservers()
      guard let window else { coordinator?.unbind(); return }
      let center = NotificationCenter.default
      observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.sourceWindowClosed = true
          self?.coordinator?.unbind()
        }
      })
      observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
        DispatchQueue.main.async { [weak self, weak window] in
          guard let self, window?.isVisible == true else { return }
          self.sourceWindowClosed = false
          if let store = self.coordinator?.sourceStore { self.coordinator?.bind(store) }
        }
      })
    }
    func clearObservers() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> HostView {
    context.coordinator.bind(store)
    let view = HostView(frame: .zero)
    view.coordinator = context.coordinator
    return view
  }
  func updateNSView(_ view: HostView, context: Context) {
    if !view.sourceWindowClosed { context.coordinator.bind(store) }
  }
  static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
    view.clearObservers(); view.coordinator = nil; coordinator.unbind()
  }
}
