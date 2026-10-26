import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct CanvasFrame: Identifiable {
  var object: ProductObject
  var surfaceObject: ProductObject
  var rect: CGRect
  var artwork: Artwork
  var id: UUID { object.id }
  var isWorkspace: Bool { object.isCanvasWorkspace }
}

enum ArtworkTool: String, CaseIterable {
  case select, direct, text, rectangle, ellipse, line, polygon, star, pen, hand, eyedropper
  var symbol: String {
    switch self {
    case .select: return "cursorarrow"
    case .direct: return "cursorarrow.and.square.on.square.dashed"
    case .text: return "textformat"
    case .rectangle: return "square"
    case .ellipse: return "circle"
    case .line: return "line.diagonal"
    case .polygon: return "pentagon"
    case .star: return "star"
    case .pen: return "point.topleft.down.to.point.bottomright.curvepath"
    case .hand: return "hand.draw"
    case .eyedropper: return "eyedropper"
    }
  }
  var shortcut: String {
    switch self {
    case .select: return "V"
    case .direct: return "A"
    case .text: return "T"
    case .rectangle: return "R"
    case .ellipse: return "O"
    case .line: return "L"
    case .polygon: return "P"
    case .star: return "S"
    case .pen: return "B"
    case .hand: return "H"
    case .eyedropper: return "I"
    }
  }
}

@MainActor final class ArtworkSession: ObservableObject {
  weak var store: StudioStore?
  weak var canvas: VectorCanvasView?
  var imageDragStarts = 0
  @Published var croppingImageID: UUID?
  @Published var objectID: UUID?
  @Published var linkedTargetID: UUID?
  @Published var selection = Set<UUID>() {
    didSet {
      if let croppingImageID, selection != [croppingImageID] { self.croppingImageID = nil }
      if let selectedGradientStopID, primary?.gradient?.stops.contains(where: { $0.id == selectedGradientStopID }) != true {
        self.selectedGradientStopID = nil
      }
      if let maskEditing, !selection.isEmpty && selection != [maskEditing.maskID] { self.maskEditing = nil }
      pruneNodeSelection()
      store?.objectWillChange.send()
    }
  }
  @Published var nodes = Set<UUID>() { didSet { store?.objectWillChange.send() } }
  @Published var scopeID: UUID?
  @Published var componentReturn: ComponentEditingContext?
  @Published var selectedGradientStopID: UUID?
  @Published var maskEditing: MaskEditingContext?
  @Published var tool: ArtworkTool = .select {
    didSet { if tool != oldValue { croppingImageID = nil; canvas?.finishPath() } }
  }
  @Published var zoom = 1.0
  @Published var dieline = false
  @Published var hiddenProductionRoles:Set<ArtworkProductionRole> = []
  @Published var preview = true
  @Published var editingText = false { didSet { store?.objectWillChange.send() } }
  @Published var characterRange = NSRange(location: 0, length: 0)
  @Published var exportDPI = 300.0
  @Published var exportOutline = true
  @Published var showingPalette = false
  @Published var showingTextStyles = false
  @Published var showingTabs = false
  @Published var showingGlyphs = false
  init(store: StudioStore) { self.store = store }
  var object: ProductObject? { store?.project?.objects.first { $0.id == objectID } }
  var art: Artwork {
    object.flatMap { store?.project?.editableArtwork($0) } ?? .init(background: "#FFFFFF")
  }
  var previewObject: ProductObject? {
    guard object?.isCanvasWorkspace != true else { return nil }
    return store?.project?.objects.first { $0.id == linkedTargetID } ?? object
  }
  var elements: [ArtworkElement] { art.elements.filter { selection.contains($0.id) } }
  var primary: ArtworkElement? { elements.first }
  var unit: PhysicalUnit { art.unit ?? .mm }
  var nodeBounds: Rect2? {
    let artwork = art
    let points = elements.flatMap { e -> [Point2] in
      guard let path = e.path else { return [] }
      let t = artwork.worldTransform(e).followed(
        by: .scale(e.width / path.width, e.height / path.height))
      return path.contours.flatMap(\.nodes).filter { nodes.contains($0.id) }.map {
        t.apply($0.anchor)
      }
    }
    guard let first = points.first else { return nil }
    return points.dropFirst().reduce(.init(first.x, first.y, 0, 0)) {
      $0.union(.init($1.x, $1.y, 0, 0))
    }
  }
  func editPath(_ operation: String, _ arguments: [String: Any] = [:]) {
    canvas?.finishText()
    guard let store, let object, !selection.isEmpty else { return }
    var args = arguments
    args["object_id"] = object.id.uuidString
    args["element_ids"] = selection.map(\.uuidString)
    args["node_ids"] = nodes.map(\.uuidString)
    args["operation"] = operation
    do {
      let result =
        try store.engine.call("form_edit_path", arguments: args, source: "Studio") as? [String: Any]
      nodes = Set((result?["selected_nodes"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
      selection = Set(
        (result?["selected_elements"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
      store.changed()
      canvas?.window?.makeFirstResponder(canvas)
    } catch { store.error = error.localizedDescription }
  }
  func transformNodes(_ transform: Affine2) {
    editPath(
      "transform",
      [
        "matrix": [
          "a": transform.a, "b": transform.b, "c": transform.c, "d": transform.d,
          "tx": transform.tx, "ty": transform.ty,
        ]
      ])
  }
  func sizeNodes(width: Double? = nil, height: Double? = nil) {
    guard let b = nodeBounds else { return }
    guard width == nil || (width! >= 0 && b.width > 1e-9),
      height == nil || (height! >= 0 && b.height > 1e-9)
    else {
      store?.error = "Choose nodes spanning a nonzero distance in this direction."
      return
    }
    transformNodes(
      .translation(b.x, b.y).followed(
        by: .scale(width.map { $0 / b.width } ?? 1, height.map { $0 / b.height } ?? 1)
      ).followed(by: .translation(-b.x, -b.y)))
  }
  var inspectedTypography: Typography {
    canvas?.textInspection()?.typography ?? sourceTextElement?.typography ?? .init()
  }
  var inspectedSize: Double { canvas?.textInspection()?.fontSize ?? sourceTextElement?.fontSize ?? 14 }
  var caseTreatments:Set<String> {
    if let values=canvas?.textCaseTreatments() {return values}
    return sourceTextElements.filter{$0.kind=="text"}.reduce(into:Set<String>()) {values,e in
      let runs=e.textRuns ?? []
      if e.text.isEmpty || runs.reduce(0,{$0+$1.length})<e.text.utf16.count {values.insert(e.typography?.caseTreatment ?? "original")}
      for run in runs {values.insert(run.typography.caseTreatment)}
    }
  }
  func colored(_ element: ArtworkElement) -> ArtworkElement {
    let contextual=objectID.flatMap{id in store?.project?.resolvingTextStories(in:art,objectID:id)} ?? art
    let resolved=contextual.resolvingLists.elements.first(where:{$0.id==element.id}) ?? element
    return (store?.project?.resolvingSwatches(in: .init(elements: [resolved]), keepingReferences: true).elements.first ?? resolved).inheritingLanguage(art.language)
  }
  var inspectedColor: String { canvas?.textInspection()?.color ?? sourceTextElement.map(colored)?.color ?? "#292D2C" }
  var assets: URL {
    guard let store, let project = store.project else { return URL(fileURLWithPath: "/") }
    return store.repository.url(for: project.id).appendingPathComponent("Assets")
  }
  var selectionBounds: Rect2? {
    let values = art.selectionRoots(selection).map { art.bounds(of: $0) }
    guard let first = values.first else { return nil }
    return values.dropFirst().reduce(first) { $0.union($1) }
  }
  var transformOrigin: Point2? { ArtworkTransforms.selectionOrigin(in:art,ids:selection) }
  func setTransformOrigin(_ point:Point2?) {
    var arguments:[String:Any] = ["origin":NSNull()]
    if let point { arguments["origin"] = ["x":point.x,"y":point.y] }
    execute("origin",arguments)
  }
  var frames: [CanvasFrame] {
    guard let objects = store?.project?.objects else { return [] }
    let related = objects.filter { $0.isCanvasWorkspace } + objects.filter { !$0.isCanvasWorkspace && ($0.recipeID == "artboard" || $0.id == objectID) }
    var x = 36.0
    var y = 40.0
    var rowHeight = 0.0
    var result: [CanvasFrame] = []
    var finiteIndex = 0
    for object in related {
      let surface = object.id == objectID ? previewObject ?? object : object
      let unfolding = dieline && object.id == objectID && surface.recipeID == "sleeve"
      let size =
        unfolding ? Dieline.dimensions(surface) : ArtworkDrawing.dimensions(object)
      if !object.isCanvasWorkspace, finiteIndex > 0 && finiteIndex % 3 == 0 {
        x = 36
        y += rowHeight + 44
        rowHeight = 0
      }
      result.append(
        .init(
          object: object,
          surfaceObject: surface,
          rect: .init(
            x: object.isCanvasWorkspace ? 0 : object.artwork?.canvasPosition?.x ?? x,
            y: object.isCanvasWorkspace ? 0 : object.artwork?.canvasPosition?.y ?? y,
            width: size.0, height: size.1),
          artwork: (unfolding
            ? store?.project?.surfaceArtwork(surface) : store?.project?.editableArtwork(object))
            .map { artwork in
              let resolved=store?.project?.resolvingTextStories(in:artwork,objectID:store?.project?.artworkOwner(object).id ?? object.id) ?? artwork
              return (try? store?.project?.resolvingComponents(in:resolved)) ?? resolved
            }
            ?? .init(background: "#FFFFFF")))
      if !object.isCanvasWorkspace {
        x += size.0 + 36
        rowHeight = max(rowHeight, size.1)
        finiteIndex += 1
      }
    }
    return result
  }
  func reconcile() {
    if let maskEditing, !art.elements.contains(where: { $0.id == maskEditing.maskID }) { self.maskEditing = nil }
    if componentReturn != nil && object?.componentDefinition != true { componentReturn = nil }
    if componentReturn == nil, object?.isCanvasWorkspace != true, let primary = store?.primary, primary.supportsArtworkFace {
      let owner = store?.project?.artworkOwner(primary) ?? primary
      linkedTargetID = owner.id == primary.id ? nil : primary.id
      if objectID != owner.id {
        objectID = owner.id
        selection = []
        scopeID = nil
      }
    }
    if object == nil {
      componentReturn = nil
      objectID = store?.project?.canvasWorkspace?.id ?? store?.project?.objects.first {
          store?.project?.editableArtwork($0) != nil && ($0["width"] > 0 || $0.recipeID == "clock")
        }?.id
    }
    if previewObject?.recipeID != "sleeve" { dieline = false }
    selection.formIntersection(Set(art.elements.map(\.id)))
    pruneNodeSelection()
    if scopeID != nil && !art.elements.contains(where: { $0.id == scopeID }) { scopeID = nil }
  }
  func activate(_ id: UUID) {
    guard id != objectID else { return }
    canvas?.finishText()
    componentReturn = nil
    maskEditing = nil
    selectedGradientStopID = nil
    objectID = id
    linkedTargetID = nil
    dieline = false
    selection = []
    scopeID = nil
    if object?.isCanvasWorkspace != true { store?.select(id) }
  }
  @discardableResult func transferSelection(to target:UUID,offset:Point2) -> Bool {
    guard let store,let source = objectID,!selection.isEmpty else { return false }
    do {
      var moved = Set<UUID>()
      try store.engine.edit("Moved artwork between frames",source:"Studio",coalescing:"artwork-\(source)") {
        moved = try $0.transferArtwork(from:source,to:target,ids:self.selection,offset:offset)
      }
      objectID = target; linkedTargetID = nil; scopeID = nil; nodes = []; croppingImageID = nil
      choose(moved); store.changed()
      return true
    } catch { store.error = error.localizedDescription; return false }
  }
  private func pruneNodeSelection() {
    guard !nodes.isEmpty else { return }
    let available = Set(elements.flatMap { $0.path?.contours.flatMap(\.nodes).map(\.id) ?? [] })
    let remaining = nodes.intersection(available)
    if nodes != remaining { nodes = remaining }
  }
  func choose(_ ids: Set<UUID>) {
    selection = ids
    nodes = []
  }
  func save(_ artwork: Artwork) {
    guard let object else { return }
    store?.saveArtwork(artwork, for: object)
  }
  func mutate(_ body: (inout Artwork) -> Void) {
    var value = art
    body(&value)
    save(value)
  }
  func update(_ body: (inout ArtworkElement) -> Void) {
    canvas?.finishText()
    mutate { art in
      for i in art.elements.indices where selection.contains(art.elements[i].id) {
        body(&art.elements[i])
      }
    }
  }
  func execute(_ command: String, _ args: [String: Any] = [:]) {
    canvas?.finishText()
    guard let store, let object else { return }
    var input = args
    input["object_id"] = object.id.uuidString
    input["command"] = command
    if !selection.isEmpty { input["element_ids"] = selection.map(\.uuidString) }
    do {
      let result =
        try store.engine.call("form_edit_artwork", arguments: input, source: "Studio")
        as? [String: Any]
      if let ids = result?["selected_elements"] as? [String] {
        selection = Set(ids.compactMap(UUID.init(uuidString:)))
      }
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
  func add(_ elements: [ArtworkElement]) {
    do { execute("add", ["elements": try elements.map { try jsonObject($0) }]) } catch {
      store?.error = error.localizedDescription
    }
  }
  @discardableResult func beginGesture()->UUID? {
    guard let id=objectID else{return nil}
    return store?.engine.beginInteraction("artwork-\(id)")
  }
  func endGesture() { store?.engine.endInteraction() }
  func translate(dx: Double, dy: Double) {
    canvas?.finishText()
    guard !elements.contains(where: { art.isLocked($0) }) else { return }
    var value = art
    for root in art.selectionRoots(selection) {
      if let i = value.elements.firstIndex(where: { $0.id == root.id }) {
        value.elements[i] = transformed(root, delta: .translation(dx, dy), in: art)
      }
    }
    save(value)
  }
  func transformed(_ element: ArtworkElement, delta: Affine2, in artwork: Artwork) -> ArtworkElement
  {
    var e = element
    let parent =
      artwork.elements.first { $0.id == e.parentID }.map { artwork.worldTransform($0) } ?? .init()
    e.affine = (parent.inverse ?? .init()).followed(by: delta).followed(by: parent).followed(
      by: e.affine ?? .init())
    return e
  }
  func transformBounds(
    x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil
  ) {
    canvas?.finishText()
    guard let b = selectionBounds, !elements.contains(where: { art.isLocked($0) }) else { return }
    if width != nil || height != nil, let e = primary, elements.count == 1, e.kind == "text",
      e.typography?.frameMode != "point"
    {
      let anchor = ArtworkTransforms.worldOrigin(e,in:art)
      var changed = e
      changed.width = max(0.1, e.width * (width ?? b.width) / max(0.001, b.width))
      changed.height = max(0.1, e.height * (height ?? b.height) / max(0.001, b.height))
      var value = art
      let index = value.elements.firstIndex { $0.id == e.id }!
      value.elements[index] = changed
      let next = ArtworkTransforms.worldOrigin(changed,in:value)
      value.elements[index] = transformed(
        changed, delta: .translation(anchor.x-next.x,anchor.y-next.y), in: value)
      if x != nil || y != nil {
        let bounds = value.bounds(of:value.elements[index])
        value.elements[index] = transformed(value.elements[index],
          delta:.translation((x ?? bounds.x)-bounds.x,(y ?? bounds.y)-bounds.y),in:value)
      }
      save(value)
      return
    }
    let pivot = transformOrigin ?? b.center
    var delta = Affine2.translation(pivot.x,pivot.y).followed(
      by: .scale(
        (width ?? b.width) / max(b.width, 0.001), (height ?? b.height) / max(b.height, 0.001))
    ).followed(by: .translation(-pivot.x,-pivot.y))
    let scaled = delta.bounds(b)
    delta = Affine2.translation((x ?? scaled.x)-scaled.x,(y ?? scaled.y)-scaled.y).followed(by:delta)
    var value = art
    for e in art.selectionRoots(selection) {
      let i = value.elements.firstIndex { $0.id == e.id }!
      value.elements[i] = transformed(e, delta: delta, in: art)
    }
    save(value)
  }
  func rotate(_ degrees: Double) {
    execute("transform",["rotation":degrees])
  }
  func typography(_ body: (inout Typography) -> Void) {
    if canvas?.applyTextStyle(body) == true { return }
    let language = selectedTextStory?.language ?? currentPublication?.language ?? art.language
    if editLinkedTextSources({ e in
      var style=e.typography ?? .init();body(&style);e.typography=style
      for i in e.textRuns?.indices ?? 0..<0 {body(&e.textRuns![i].typography)}
    }) {return}
    update { e in
      if e.kind == "text" {
        var style = e.typography ?? .init()
        body(&style)
        e.typography = style
        for i in e.textRuns?.indices ?? 0..<0 { body(&e.textRuns![i].typography) }
        if style.frameMode == "point" {
          let size = TypographyEngine.measured(e.inheritingLanguage(language))
          e.width = max(1, size.width + 0.5)
          e.height = max(e.fontSize / TypographyEngine.pointsPerMM * 1.4, size.height + 0.5)
        }
      }
    }
  }
  func paragraphList(_ arguments:[String:Any]) {
    if canvas?.applyList(arguments)==true {return}
    execute("list",arguments)
  }
  func typeSize(_ size: Double) {
    if canvas?.applyTextSize(size) == true { return }
    if editLinkedTextSources({e in e.fontSize=max(0.1,size);for i in e.textRuns?.indices ?? 0..<0 {e.textRuns?[i].fontSize=max(0.1,size)}}) {return}
    update {
      if $0.kind == "text" {
        $0.fontSize = max(0.1, size)
        for i in $0.textRuns?.indices ?? 0..<0 { $0.textRuns?[i].fontSize = max(0.1, size) }
      }
    }
  }
  func textColor(_ color: String) {
    if canvas?.applyTextColor(color) == true { return }
    if editLinkedTextSources({e in
      e.color=color;e.fillSwatchID=nil
      for i in e.textRuns?.indices ?? 0..<0 {e.textRuns?[i].color=color;e.textRuns?[i].swatchID=nil}
    }) {return}
    update {
      $0.color = color
      $0.fillSwatchID = nil
      if $0.kind != "text" { $0.gradient = nil; $0.fillEnabled = true }
      for i in $0.textRuns?.indices ?? 0..<0 {
        $0.textRuns?[i].color = color
        $0.textRuns?[i].swatchID = nil
      }
    }
  }
  func manualKerning(_ value: Double) {
    if canvas?.applyManualKerning(value) == true { return }
    typography { $0.pairKerning[max(0, characterRange.location - 1)] = value }
  }
  func convert(_ mode: String = "text") {
    canvas?.finishText()
    guard let store, let object else { return }
    do {
      let result =
        try store.graphicsCall(
          "form_convert_to_paths",
          [
            "object_id": object.id.uuidString, "element_ids": selection.map(\.uuidString),
            "mode": mode,
          ]) as? [String: Any]
      selection = Set(
        (result?["selected_elements"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
  func boolean(_ operation: String, mode: String = "live") {
    canvas?.finishText()
    guard let store, let object else { return }
    do {
      let result =
        try store.graphicsCall(
          "form_boolean_artwork",
          [
            "object_id": object.id.uuidString, "element_ids": selection.map(\.uuidString),
            "operation": operation, "mode": mode,
          ]) as? [String: Any]
      selection = Set(
        (result?["selected_elements"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
      if mode == "release" {
        let parents = Set(elements.map(\.parentID))
        scopeID = parents.count == 1 ? parents.first! : nil
      }
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
  func makeMask() {
    execute("clip")
  }
  func addGuide(axis: String, position: Double) {
    mutate { a in
      if a.guides == nil { a.guides = [] }
      a.guides?.append(.init(axis: axis, position: position))
    }
  }
  func fit() { canvas?.fit(all: true) }
  func setZoom(_ value: Double) { canvas?.setZoom(value) }
  func createFrame(width: Double, height: Double, name: String) {
    canvas?.finishText()
    guard let store else { return }
    if store.project == nil { store.createProject() }
    store.perform(
      "form_add_object",
      [
        "recipe_id": "artboard", "name": name, "parameters": ["width": width, "depth": height],
        "material_id": "chalk",
      ])
    if let object = store.primary {
      store.saveArtwork(.init(background: "#FFFFFF"), for: object)
      objectID = object.id
      selection = []
      scopeID = nil
    }
    store.mode = .artwork
    DispatchQueue.main.async { self.fit() }
  }
  func importImage(replacing: Bool = false) {
    guard store?.project != nil else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .pdf]
    panel.allowsMultipleSelection = !replacing
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    let point = object?.isCanvasWorkspace == true ? canvas.map { Point2($0.visibleCanvasRect.midX,$0.visibleCanvasRect.midY) } : nil
    placeImages(panel.urls,point:point,replacing:replacing)
  }

  func copy() {
    let ids = art.descendants(of: selection)
    guard !ids.isEmpty else { return }
    do {
      let data = try JSONEncoder.form.encode(art.elements.filter { ids.contains($0.id) })
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setData(data, forType: .init("studio.form.artwork"))
    } catch { store?.error = error.localizedDescription }
  }
  func paste() {
    guard let data = NSPasteboard.general.data(forType: .init("studio.form.artwork")),
      let source = try? JSONDecoder.form.decode([ArtworkElement].self, from: data)
    else { return }
    let mapping = Dictionary(uniqueKeysWithValues: source.map { ($0.id, UUID()) })
    let pasted = source.map { e -> ArtworkElement in
      var value = e
      value.id = mapping[e.id]!
      PathCommands.refreshNodeIDs(in: &value)
      value.parentID = e.parentID.flatMap { mapping[$0] } ?? scopeID
      value.clipID = e.clipID.flatMap { mapping[$0] }
      if e.parentID == nil {
        value.x += 10
        value.y += 10
      }
      return value
    }
    add(pasted)
  }
  func export(_ format: String) {
    guard let store, let object else { return }
    store.exportArtworkDialog(format,object:object,dpi:exportDPI,outlineText:exportOutline,
      elementIDs:object.isCanvasWorkspace ? selection : [])
  }
}
