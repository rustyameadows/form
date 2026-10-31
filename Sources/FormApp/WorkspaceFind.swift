import AppKit
import FormCore
import FormGraphics
import SwiftUI

enum WorkspaceFindTarget: Hashable {
  case canvasFrame(UUID)
  case canvasElement(frameID: UUID, sourceID: UUID, elementID: UUID)
  case tableObject(UUID)
}

struct WorkspaceFindResult: Identifiable, Equatable {
  let projectID: UUID
  let target: WorkspaceFindTarget
  let title: String
  let subtitle: String
  let symbol: String
  var id: String {
    switch target {
    case .canvasFrame(let frame): return "\(projectID):frame:\(frame)"
    case .canvasElement(let frame, let source, let element): return "\(projectID):\(frame):\(source):\(element)"
    case .tableObject(let object): return "\(projectID):table:\(object)"
    }
  }
}

enum WorkspaceFindMatching {
  static func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
  static func matches(_ query: String, in fields: [String]) -> Bool {
    let text = normalized(fields.joined(separator: " "))
    return normalized(query).split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
  }
}

extension StudioStore {
  func requestWorkspaceFind(_ surface: WorkspaceMode? = nil) {
    guard project != nil, !showingHome, environment == .form else { return }
    artworkSession.canvas?.prepareForGroupNavigation()
    scene?.view?.cancelPointerInteraction()
    finishArtworkEditing()
    if (surface ?? mode) == .artwork {
      activateDesignSurface(.artwork)
      canvasFindVisible = true; canvasSearchFocusRequest += 1
    } else { requestTableSearchFocus() }
  }
  func requestTableSearchFocus() {
    guard project != nil, !showingHome, environment == .form else { return }
    activateDesignSurface(.table)
    tableNavigatorVisible = true; tableSearchFocusRequest += 1
  }
  @discardableResult func navigateToTableObject(_ id: UUID) -> Bool {
    guard let object = project?.objects.first(where: { $0.id == id }), object.hasTablePresentation else { return false }
    finishArtworkEditing()
    if !isolated.isEmpty, !isolated.contains(id) { isolated = [] }
    engine.selection = [id]
    changed(save: false)
    activateDesignSurface(.table)
    designSurfaceHost?.refresh()
    synchronizeScene()
    scene?.focusSelection()
    return true
  }

  func workspaceFindResults(for surface: WorkspaceMode, query: String) -> [WorkspaceFindResult] {
    guard let project else { return [] }
    if surface != .artwork {
      return TableNavigationInventory.items(in: project, query: query, isolated: isolated).map {
        .init(projectID: project.id, target: .tableObject($0.id), title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol)
      }
    }
    let frames = artworkSession.frames
    var results = frames.compactMap { frame -> WorkspaceFindResult? in
      let title = frame.isWorkspace ? "Canvas" : frame.title
      guard WorkspaceFindMatching.matches(query, in: [title]) else { return nil }
      return .init(projectID: project.id, target: .canvasFrame(frame.id), title: title,
        subtitle: frame.isWorkspace ? "Freeform canvas" : frame.role.title, symbol: frame.isWorkspace ? "square.dashed" : frame.role.symbolName)
    }
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Array(results.prefix(80)) }
    // A canonical layer can appear in a proof and many surface crops. Offer it
    // once, preferring the current readable view, then its complete source.
    let activeFrameID = artworkSession.activeFrameID
    let ordered = frames.enumerated().sorted { a, b in
      func rank(_ f: CanvasFrame) -> Int {
        f.id == activeFrameID ? 0 : f.projection == nil ? 1 : f.projection?.isProof == true ? 2 : 3
      }
      let ar = rank(a.element), br = rank(b.element)
      return ar == br ? a.offset < b.offset : ar < br
    }.map(\.element)
    var seen = Set<String>()
    var clips: [UUID: CGPath] = [:]
    for frame in ordered {
      let canonical = findSourceArtwork(for: frame, in: project)
      let sourceID = frame.projection?.sourceID ?? project.artworkOwner(frame.object).id
      let context = frame.projection?.requiresInsideSource == true ? ":inside" : ""
      let displayedByID = Dictionary(uniqueKeysWithValues: frame.artwork.elements.map { ($0.id, $0) })
      for original in canonical.elements {
        guard let displayed = displayedByID[original.id] else { continue }
        let layerName = original.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = layerName.isEmpty ? original.sewingPiece?.name ?? "" : layerName
        var text = displayed.storyFrame?.resolved?.story.text ?? displayed.text
        if original.component != nil {
          let descendants = frame.artwork.descendants(of: [original.id])
          text += " " + frame.artwork.elements.filter { descendants.contains($0.id) }.map { ($0.name ?? "") + " " + $0.text }.joined(separator: " ")
        }
        guard WorkspaceFindMatching.matches(query, in: [name, text, original.kind]) else { continue }
        guard findLayerIsVisible(displayed, elements: displayedByID),
          findLayerIntersects(displayed, frame: frame, clips: &clips) else { continue }
        let storyMatch = displayed.storyFrame != nil && !WorkspaceFindMatching.matches(query, in: [name])
        let key = storyMatch ? "story:\(displayed.storyFrame!.storyID)" : "\(sourceID)\(context):\(original.id)"
        guard seen.insert(key).inserted else { continue }
        let title = !name.isEmpty ? name : !text.isEmpty ? String(text.split(separator: "\n").first.map(String.init)?.prefix(70) ?? "") : original.kind.capitalized
        results.append(.init(projectID: project.id,
          target: .canvasElement(frameID: frame.id, sourceID: sourceID, elementID: original.id),
          title: title, subtitle: frame.isWorkspace ? "Canvas · \(original.kind)" : frame.title,
          symbol: original.component != nil ? "diamond" : original.kind == "text" ? "textformat" : original.kind == "image" ? "photo" : original.kind == "group" ? "square.stack" : "square"))
      }
    }
    return Array(results.sorted { a, b in
      func rank(_ item: WorkspaceFindResult) -> Int {
        let name = WorkspaceFindMatching.normalized(item.title), q = WorkspaceFindMatching.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return name == q ? 0 : name.hasPrefix(q) ? 1 : name.contains(q) ? 2 : 3
      }
      return rank(a) < rank(b)
    }.prefix(80))
  }

  @discardableResult func revealFindResult(_ result: WorkspaceFindResult) -> Bool {
    guard let project, project.id == result.projectID else { return false }
    if case .tableObject(let id) = result.target { return navigateToTableObject(id) }
    let frameID: UUID
    var elementID: UUID?
    switch result.target {
    case .canvasFrame(let id): frameID = id
    case .canvasElement(let id, let sourceID, let element):
      frameID = id; elementID = element
      guard let frame = artworkSession.frames.first(where: { $0.id == id }),
        (frame.projection?.sourceID ?? project.artworkOwner(frame.object).id) == sourceID,
        findSourceArtwork(for: frame, in: project).elements.contains(where: { $0.id == element }) else { return false }
    case .tableObject: return false
    }
    guard let frame = artworkSession.frames.first(where: { $0.id == frameID }),
      elementID == nil || frame.artwork.elements.contains(where: { $0.id == elementID }) else { return false }
    if let elementID, let displayed = frame.artwork.elements.first(where: { $0.id == elementID }) {
      let elements = Dictionary(uniqueKeysWithValues: frame.artwork.elements.map { ($0.id, $0) })
      var clips: [UUID: CGPath] = [:]
      guard findLayerIsVisible(displayed, elements: elements),
        findLayerIntersects(displayed, frame: frame, clips: &clips) else { return false }
    }
    finishArtworkEditing()
    artworkSession.canvas?.prepareForGroupNavigation()
    artworkSession.activate(frameID)
    if let elementID, let element = frame.artwork.elements.first(where: { $0.id == elementID }) {
      artworkSession.navigateGroup(to: element.parentID, selection: [elementID])
      let bounds = frame.artwork.bounds(of: element)
      var b = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
      if frame.projection?.isProof == false { b = b.intersection(CGRect(origin: .zero, size: frame.rect.size)) }
      artworkSession.canvas?.synchronize()
      _ = artworkSession.canvas?.focusSearchBounds(b.offsetBy(dx: frame.rect.minX, dy: frame.rect.minY))
    } else {
      artworkSession.navigateGroup(to: nil)
      artworkSession.canvas?.synchronize()
      _ = artworkSession.canvas?.fit(frameIDs: [frameID])
    }
    canvasFindVisible = false
    activateDesignSurface(.artwork)
    return true
  }

  private func findSourceArtwork(for frame: CanvasFrame, in project: Project) -> Artwork {
    if let projection = frame.projection, projection.requiresInsideSource {
      return frame.surfaceObject.paperConstruction?.insideArtwork ?? .init()
    }
    return project.editableArtwork(frame.object) ?? .init()
  }
  private func findLayerIsVisible(_ element: ArtworkElement, elements: [UUID: ArtworkElement]) -> Bool {
    var current: ArtworkElement? = element, visited = Set<UUID>()
    while let item = current, visited.insert(item.id).inserted {
      if item.hidden == true { return false }
      current = item.parentID.flatMap { elements[$0] }
    }
    return true
  }
  private func findLayerIntersects(_ element: ArtworkElement, frame: CanvasFrame, clips: inout [UUID: CGPath]) -> Bool {
    if frame.isWorkspace { return true }
    let b = frame.artwork.bounds(of: element)
    let rect = CGRect(x: b.x, y: b.y, width: max(b.width, 0.001), height: max(b.height, 0.001))
    guard rect.intersects(CGRect(origin: .zero, size: frame.rect.size)) else { return false }
    guard frame.projection != nil else { return true }
    let clip: CGPath
    if let cached = clips[frame.id] { clip = cached }
    else { clip = frame.physicalMaterialClip ?? CGMutablePath(); clips[frame.id] = clip }
    return !clip.intersection(CGPath(rect: rect, transform: nil), using: .evenOdd).isEmpty
  }
}

struct WorkspaceFindCommands: Commands {
  @ObservedObject var store: StudioStore
  @FocusedValue(\.designSurface) private var focusedSurface: WorkspaceMode?
  private var title: String { (focusedSurface ?? store.mode) == .artwork ? "Find in Canvas…" : "Find in Table…" }
  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button(title) { store.requestWorkspaceFind(focusedSurface ?? store.mode) }
        .keyboardShortcut("f").disabled(store.project == nil || store.showingHome || store.environment != .form)
    }
  }
}

struct CanvasFindPanel: View {
  @EnvironmentObject var store: StudioStore
  @FocusState private var focused: Bool
  @State private var highlighted: String?
  private var results: [WorkspaceFindResult] { store.workspaceFindResults(for: .artwork, query: store.canvasSearchQuery) }
  var body: some View {
    let values = results
    VStack(spacing: 0) {
      FloatingPanelHeader("FIND ON CANVAS", closeLabel: "Close Canvas search", onClose: close)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
        TextField("Frames, layers, or text", text: $store.canvasSearchQuery)
          .textFieldStyle(InspectorTextFieldStyle()).focused($focused)
          .accessibilityLabel("Find on Canvas").onSubmit(openHighlighted)
          .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in moveHighlight(-1); return .handled }
          .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in moveHighlight(1); return .handled }
      }.padding(12)
      InspectorDivider().padding(.horizontal, 12)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            if values.isEmpty { Text("No matches").foregroundStyle(Palette.secondary).padding(16) }
            ForEach(values) { result in
              WorkspaceNavigationRow(title: result.title, subtitle: result.subtitle, symbol: result.symbol,
                highlighted: highlighted == result.id, accessibilityLabel: "Find " + result.title,
                identifier: "canvas-find-result-" + result.id) { _ = store.revealFindResult(result) }
                .id(result.id)
            }
          }.padding(6)
        }.onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
      }
    }.frame(width: 300, height: 360).floatingPanelSurface()
      .onAppear { highlighted = results.first?.id; focused = true }
      .onChange(of: store.canvasSearchFocusRequest) { _, _ in focused = true }
      .onChange(of: store.canvasSearchQuery) { _, _ in highlighted = results.first?.id }
      .onMoveCommand { direction in
        guard focused, direction == .up || direction == .down else { return }
        moveHighlight(direction == .up ? -1 : 1)
      }
      .onExitCommand { if store.canvasSearchQuery.isEmpty { close() } else { store.canvasSearchQuery = "" } }
  }
  private func openHighlighted() {
    let values = results
    if let result = values.first(where: { $0.id == highlighted }) ?? values.first { _ = store.revealFindResult(result) }
  }
  private func moveHighlight(_ delta: Int) {
    let values = results
    guard !values.isEmpty else { return }
    let current = values.firstIndex { $0.id == highlighted } ?? 0
    highlighted = values[max(0, min(values.count-1, current+delta))].id
  }
  private func close() { store.canvasFindVisible = false; store.artworkSession.canvas?.window?.makeFirstResponder(store.artworkSession.canvas) }
}
