import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct CanvasFrame: Identifiable {
  var object: ProductObject
  var surfaceObject: ProductObject
  var rect: CGRect
  var artwork: Artwork
  var sourceReview:String? = nil
  var projection: CanvasSourceProjection? = nil
  var legacyDieline = false
  var id: UUID { projection?.id ?? object.id }
  var title: String { projection?.title ?? (object.name + (sourceReview == nil ? "":" · Registered source")) }
  var isWorkspace: Bool { object.isCanvasWorkspace }
  var editable: Bool { !object.locked && (projection==nil || !surfaceObject.locked) }
  @MainActor func contains(_ point: CGPoint) -> Bool {
    rect.contains(point) && (projection?.contains(.init(x: point.x-rect.minX, y: point.y-rect.minY)) ?? true)
  }
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
  var transferPasteboard:NSPasteboard?
  var transferPasteboardPublisher:((NSPasteboard,Data,NSPasteboard.PasteboardType)throws->Bool)?
  var transferTask:Task<Void,Never>?
  var transferGeneration=UUID()
  @Published var transferInFlight=false
  var lastTransferError:String?
  var lastTransferResult:[String:Any]?
  private struct FrameInputs:Equatable {
    let project:Project
    let objectID:UUID?
    let linkedTargetID:UUID?
    let dieline:Bool
    let editingComponent:Bool
  }
  private struct FrameMemo {
    let inputs:FrameInputs
    let frames:[CanvasFrame]
  }
  // One COW document snapshot, not a history of frame graphs. A revision-only
  // key misses direct project assignments and shared story/style dependencies.
  private var frameMemo:FrameMemo?
  private(set) var frameBuildCount=0
  private var artworkGesture:(key:String,token:UUID)?

  @Published var croppingImageID: UUID?
  @Published var objectID: UUID? {didSet{if objectID != oldValue {cancelArtworkTransfer();projectionFrameID=nil}}}
  @Published var projectionFrameID: UUID? {didSet{if projectionFrameID != oldValue {cancelArtworkTransfer()}}}
  @Published var linkedTargetID: UUID?
  @Published var selection = Set<UUID>() {
    didSet {
      if let croppingImageID, selection != [croppingImageID] { self.croppingImageID = nil }
      if let selectedGradientStopID, primary?.gradient?.stops.contains(where: { $0.id == selectedGradientStopID }) != true {
        self.selectedGradientStopID = nil
      }
      if let maskEditing, !selection.isEmpty,
        !selection.isSubset(of:art.editableMaskElementIDs(rootID:maskEditing.maskID)) { self.maskEditing = nil }
      pruneNodeSelection()
      store?.objectWillChange.send()
    }
  }
  @Published var nodes = Set<UUID>() { didSet { store?.objectWillChange.send() } }
  @Published var scopeID: UUID? {didSet{if scopeID != oldValue {cancelArtworkTransfer()}}}
  @Published var componentReturn: ComponentEditingContext?
  @Published var selectedGradientStopID: UUID?
  @Published var maskEditing: MaskEditingContext?
  @Published var tool: ArtworkTool = .select {
    didSet { if tool != oldValue { croppingImageID = nil; canvas?.finishPath() } }
  }
  @Published var zoom = 1.0
  @Published var dieline = false
  @Published var paperFocusPanelID: String?
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
  /// The Canvas owns its physical editing context independently of Table selection.
  var physicalObject: ProductObject? {
    if let target = linkedTargetID, let object = store?.project?.objects.first(where: { $0.id == target }) { return object }
    return object?.isCanvasWorkspace == true ? nil : object
  }
  var paperContext: ProductObject? {
    guard let physical = physicalObject, PaperConstruction.isPaper(physical),
      objectID == physical.id || objectID == physical.paperConstruction?.insideArtworkSourceID
        || objectID == store?.project?.artworkOwner(physical).id else { return nil }
    return physical
  }
  var art: Artwork {
    let source = sourceArtwork
    return activeProjection?.display(source) ?? source
  }
  private static var blankInsideArtwork:Artwork {var value=Artwork(background:"#F7F5EF");value.backgroundOpacity=0;return value}
  var sourceArtwork: Artwork {
    if let projection=activeProjection,let project=store?.project {
      if projection.requiresInsideSource {
        return project.objects.first{$0.id==projection.constructionID}?.paperConstruction?.insideArtwork ?? Self.blankInsideArtwork
      }
      if let source=project.objects.first(where:{$0.id==projection.sourceID}) {return project.editableArtwork(source) ?? .init(background:"#FFFFFF")}
    }
    return object.flatMap { store?.project?.editableArtwork($0) } ?? .init(background:"#FFFFFF")
  }
  var activeFrameID: UUID? { projectionFrameID ?? objectID }
  var activeCanvasFrame: CanvasFrame? {
    activeCanvasFrame(in:frames)
  }
  func activeCanvasFrame(in values:[CanvasFrame])->CanvasFrame? {
    return values.first { $0.id == activeFrameID }
      ?? values.first { $0.projection?.sourceID == objectID && $0.projection?.isProof == true }
  }
  var activeProjection: CanvasSourceProjection? { activeCanvasFrame?.projection }
  var isConstructionProof: Bool { activeProjection?.isProof == true }
  var previewObject: ProductObject? { physicalObject }
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
    guard activeProjection.flatMap({p in store.project?.objects.first{$0.id==p.constructionID}})?.locked != true else {
      store.error="Unlock the physical construction before editing this face.";return
    }
    var args = arguments
    args["object_id"] = object.id.uuidString
    args["element_ids"] = selection.map(\.uuidString)
    args["node_ids"] = nodes.map(\.uuidString)
    args["operation"] = operation
    do {
      if let projection=activeProjection,projection.panelID != nil || projection.sourceToLocal != Affine2() {
        var value = art
        let result = try PathCommands.edit(operation, artwork: &value, elements: selection,
          nodes: nodes, arguments: args)
        // Discrete commands match the raw command engine's Undo boundary;
        // only an explicit native gesture may coalesce multiple path updates.
        if !store.engine.isInteracting(with:"artwork-\(object.id)") {store.engine.endInteraction()}
        save(value); nodes = result.nodes; selection = result.elements
        return
      }
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
  private func hasSewingSourceRole(_ object:ProductObject,in project:Project)->Bool {
    project.isIndependentSewingSource(object) || project.objects.contains{$0.patternAssembly?.sourceObjectID==object.id}
  }
  private func hasCanonicalSourceRole(_ object:ProductObject,in project:Project)->Bool {
    object.componentDefinition == true || hasSewingSourceRole(object,in:project)
      || project.objects.contains { consumer in
        consumer.id != object.id && !PaperConstruction.isPaper(consumer)
          && (project.artworkOwner(consumer).id == object.id
            || consumer.surfaceArtworkBindings?.contains { $0.sourceObjectID == object.id } == true)
      }
  }
  private func paperUses(of sourceID:UUID,in project:Project)->[(object:ProductObject,inside:Bool)] {
    var uses:[(ProductObject,Bool)]=[]
    for object in project.objects where PaperConstruction.isPaper(object) {
      if object.paperConstruction?.insideArtworkSourceID==sourceID {uses.append((object,true))}
      if object.id != sourceID && project.artworkOwner(object).id==sourceID {uses.append((object,false))}
    }
    return uses
  }
  var frames: [CanvasFrame] {
    guard let project=store?.project else{frameMemo=nil;return []}
    // Table camera motion cannot alter canonical frame content or placement.
    // Keep every other document input exact, including shared resources.
    var frameProject=project;frameProject.camera = .init()
    var frameObjectID=objectID,frameTargetID=linkedTargetID
    if componentReturn==nil,let object=project.objects.first(where:{$0.id==objectID}),
      let target=project.objects.first(where:{$0.id==linkedTargetID}),PaperConstruction.isPaper(target),
      (object.id==target.id || project.artworkOwner(target).id==object.id || target.paperConstruction?.insideArtworkSourceID==object.id),
      !hasCanonicalSourceRole(object,in:project),PaperConstruction.isPaper(object) || paperUses(of:object.id,in:project).count==1 {
      // Choosing another readable face does not change the complete frame graph.
      frameObjectID=nil;frameTargetID=nil
    }
    let inputs=FrameInputs(project:frameProject,objectID:frameObjectID,linkedTargetID:frameTargetID,
      dieline:dieline,editingComponent:componentReturn != nil)
    if let memo=frameMemo,memo.inputs==inputs {return memo.frames}
    let values=buildFrames(project:project)
    frameBuildCount+=1;frameMemo = .init(inputs:inputs,frames:values)
    return values
  }
  private func buildFrames(project:Project)->[CanvasFrame] {
    let objects=project.objects
    let related = objects.filter { $0.isCanvasWorkspace } + objects.filter {object in
      guard !object.isCanvasWorkspace,!PaperConstruction.isPaper(object),
        object.recipeID=="artboard" || project.isIndependentFlatArtworkSource(object) || project.isIndependentSewingSource(object) || object.artworkParameterBindings?.isEmpty == false || object.id==objectID else{return false}
      // Transferred component definitions are resources for their instances,
      // not additional artboards. Expose a source only while it is explicitly
      // active (for example, Edit component source), then hide it on return.
      // Paper/CAD projections below still present their actual physical faces.
      if object.canvasSourceOnly == true, object.componentDefinition == true,
        object.id != objectID {return false}
      if hasCanonicalSourceRole(object,in:project) || componentReturn != nil && object.id==objectID {return true}
      let uses=paperUses(of:object.id,in:project)
      let selected=uses.first{$0.object.id==linkedTargetID}
      if let owner=selected ?? (uses.count==1 ? uses.first:nil),
        (try? PaperConstruction.definition(for:owner.object).net()) != nil {return false}
      return true
    }
    var x = 36.0
    var y = 40.0
    var rowHeight = 0.0
    var result: [CanvasFrame] = []
    var finiteIndex = 0
    for object in related {
      let surface = object.id == objectID ? paperContext ?? previewObject ?? object : object
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
            ?? .init(background: "#FFFFFF"),
          sourceReview:!paperUses(of:object.id,in:project).isEmpty && object.componentDefinition == true
            ? "This registered source is also a component definition. Its original editor stays in canonical coordinates; select a construction for its readable paper face."
            : !paperUses(of:object.id,in:project).isEmpty && hasSewingSourceRole(object,in:project)
            ? "This source also owns sewing geometry. Its original contours stay in canonical source coordinates; select a construction for its readable paper face."
            : paperUses(of:object.id,in:project).count>1
              ? "This registered artwork has multiple physical owners. Select a construction to edit its readable face; this fallback preserves canonical source coordinates.":nil,
          legacyDieline: unfolding))
      if !object.isCanvasWorkspace {
        x += size.0 + 36
        rowHeight = max(rowHeight, size.1)
        finiteIndex += 1
      }
    }
    // Keep constructions on the same surface as loose artwork and independent frames.
    // Defaults begin below existing frame/content bounds; user positions are saved separately.
    var bottom = result.filter { !$0.isWorkspace }.map(\.rect.maxY).max() ?? 0
    for workspace in result where workspace.isWorkspace {
      for element in workspace.artwork.elements where element.parentID == nil {
        bottom = max(bottom, workspace.artwork.bounds(of: element).maxY)
      }
    }
    var constructionY = max(40, bottom + 70)
    for construction in objects where PaperConstruction.isPaper(construction) {
      guard let definition=try? PaperConstruction.definition(for:construction),let net=try? definition.net() else{continue}
      for inside in [false,true] {
      let requiresSource=inside && definition.insideArtworkSourceID==nil
      let sourceID=inside ? definition.insideArtworkSourceID ?? construction.id:project.artworkOwner(construction).id
      guard let source=objects.first(where:{$0.id==sourceID}) else{continue}
      let raw=requiresSource ? definition.insideArtwork ?? Self.blankInsideArtwork:project.editableArtwork(source) ?? Artwork(background:"#FFFFFF")
      let resolved = project.resolvingTextStories(in: raw, objectID: sourceID)
      let artwork = (try? project.resolvingComponents(in: resolved)) ?? resolved
      let projections = CanvasSourceProjection.views(of: construction, sourceID: sourceID, inside: inside, net: net,requiresInsideSource:requiresSource)
      var panelX = 36 + net.size.x + 65
      var panelY = constructionY
      var panelRowHeight = 0.0
      for projection in projections {
        let fallback = projection.isProof ? Point2(36, constructionY) : Point2(panelX, panelY)
        let origin = construction.canvasProjectionPositions?[projection.key]
          ?? construction.canvasProjectionPositions?[projection.legacyKey] ?? fallback
        result.append(.init(object: source, surfaceObject: construction,
          rect: .init(x: origin.x, y: origin.y, width: projection.size.x, height: projection.size.y),
          artwork: projection.display(artwork), projection: projection))
        if !projection.isProof {
          panelRowHeight = max(panelRowHeight, projection.size.y)
          panelX += projection.size.x + 36
          if panelX > 36 + net.size.x + 700 {
            panelX = 36 + net.size.x + 65; panelY += panelRowHeight + 48; panelRowHeight = 0
          }
        }
      }
      constructionY = max(constructionY + net.size.y, panelY + panelRowHeight) + 90
      }
    }
    // Exact-model surfaces use the same source-frame view as flat constructions.
    // Their bound artboard already has upright physical coordinates.
    var surfaceY = constructionY
    for model in objects where model.cadModel != nil {
      var surfaceX = 36.0
      var rowHeight = 0.0
      for surface in model.cadRepresentation?.resolvedSurfaces ?? [] {
        guard let binding = model.surfaceArtworkBindings?.first(where: { $0.surfaceID == surface.id }),
          let sourceID = binding.sourceObjectID,
          let source = objects.first(where: { $0.id == sourceID }),
          let project = store?.project, let raw = project.editableArtwork(source) else { continue }
        let resolved = project.resolvingTextStories(in: raw, objectID: source.id)
        let artwork = (try? project.resolvingComponents(in: resolved)) ?? resolved
        let projection = CanvasSourceProjection(constructionID: model.id, sourceID: source.id,
          panelID: surface.id, inside: false, title: model.name + " · " + surface.name,
          size: .init(surface.width, surface.height), sourceToLocal: .init(),
          boundary: surface.boundary.map { .init($0.x, $0.y) },surfaceKind:.cadSurface)
        let point = model.canvasProjectionPositions?[projection.key]
          ?? model.canvasProjectionPositions?[projection.legacyKey] ?? .init(surfaceX, surfaceY)
        result.append(.init(object: source, surfaceObject: model,
          rect: .init(x: point.x, y: point.y, width: surface.width, height: surface.height),
          artwork: artwork, projection: projection))
        rowHeight = max(rowHeight, surface.height); surfaceX += surface.width + 40
        if surfaceX > 1000 { surfaceX = 36; surfaceY += rowHeight + 55; rowHeight = 0 }
      }
      surfaceY += rowHeight + 80
    }
    return result
  }
  func reconcile() {
    if let maskEditing, !art.elements.contains(where: { $0.id == maskEditing.maskID }) { self.maskEditing = nil }
    if componentReturn != nil && object?.componentDefinition != true { componentReturn = nil }
    if let linkedTargetID, store?.project?.objects.contains(where: { $0.id == linkedTargetID }) != true {
      self.linkedTargetID = nil
    }
    if let projectionFrameID,let projection=frames.first(where:{$0.id==projectionFrameID})?.projection,
      objectID != projection.sourceID {adoptProjectionSource(projection)}
    if object == nil {
      componentReturn = nil; linkedTargetID = nil; projectionFrameID = nil
      objectID = store?.project?.canvasWorkspace?.id ?? store?.project?.objects.first {
          store?.project?.editableArtwork($0) != nil && ($0["width"] > 0 || $0.recipeID == "clock")
        }?.id
    }
    if let projectionFrameID, !frames.contains(where: { $0.id == projectionFrameID }) {
      self.projectionFrameID = nil
    }
    if componentReturn==nil,projectionFrameID==nil,let object,let project=store?.project,
      paperUses(of:object.id,in:project).count==1,!hasCanonicalSourceRole(object,in:project) {
      activate(object.id)
    }
    if previewObject?.recipeID != "sleeve" { dieline = false }
    selection.formIntersection(Set(art.elements.map(\.id)))
    pruneNodeSelection()
    if scopeID != nil && !art.elements.contains(where: { $0.id == scopeID }) { scopeID = nil }
  }
  func activate(_ id: UUID) {
    if let project=store?.project {
      if let paper=project.objects.first(where:{$0.id==id}),PaperConstruction.isPaper(paper) {
        let source=project.artworkOwner(paper).id
        canvas?.finishText();cancelArtworkTransfer()
        store?.paperInside=false;objectID=source;projectionFrameID=nil;linkedTargetID=paper.id
        if let proof=frames.first(where:{$0.projection?.constructionID==paper.id && $0.projection?.sourceID==source && $0.projection?.isProof==true}) {activate(proof.id)}
        return
      }
      let uses=paperUses(of:id,in:project)
      if uses.count==1,let owner=uses.first,let source=project.objects.first(where:{$0.id==id}),!hasCanonicalSourceRole(source,in:project),
        (try? PaperConstruction.definition(for:owner.object).net()) != nil {
        canvas?.finishText();cancelArtworkTransfer()
        store?.paperInside=owner.inside
        objectID=id;projectionFrameID=nil;linkedTargetID=owner.object.id
        if let proof=frames.first(where:{$0.projection?.constructionID==owner.object.id && $0.projection?.sourceID==id && $0.projection?.isProof == true}) {
          activate(proof.id);return
        }
      }
    }
    if let frame = frames.first(where: { $0.id == id }), let projection = frame.projection {
      guard projectionFrameID != id else { return }
      canvas?.finishText(); cancelArtworkTransfer()
      componentReturn = nil; maskEditing = nil; selectedGradientStopID = nil
      objectID = projection.sourceID; projectionFrameID = id; linkedTargetID = projection.constructionID
      if PaperConstruction.isPaper(frame.surfaceObject) {
        store?.paperInside = projection.inside
        paperFocusPanelID = projection.panelID
      }
      dieline = false; selection = []; scopeID = nil; nodes = []
      return
    }
    guard id != objectID || projectionFrameID != nil else { return }
    canvas?.finishText()
    componentReturn = nil
    maskEditing = nil
    selectedGradientStopID = nil
    objectID = id
    projectionFrameID = nil
    linkedTargetID = nil
    dieline = false
    selection = []
    scopeID = nil
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
  func selectionCandidates(in artwork: Artwork) -> [ArtworkElement] {
    let projection = activeProjection
    let editing=maskEditing.map{artwork.editableMaskElementIDs(rootID:$0.maskID)}
    return artwork.elements.filter {
      $0.parentID == scopeID && (editing?.contains($0.id) ?? artwork.editable($0))
        && (projection?.intersects(artwork.bounds(of: $0)) ?? true)
    }
  }
  func selectAllInActiveFrame() {
    choose(Set(selectionCandidates(in: art).map(\.id)))
  }
  func save(_ artwork: Artwork) {
    if object==nil {reconcile()}
    guard let store,let object else { return }
    let projection=activeProjection
    let destination=projection.flatMap{p in store.project?.objects.first{$0.id==p.sourceID}} ?? object
    guard projection.flatMap({p in store.project?.objects.first{$0.id==p.constructionID}})?.locked != true,
      !destination.locked,projection?.requiresInsideSource == true || store.project?.artworkOwner(destination).locked != true else {
      store.error = "Unlock the physical construction and artwork source before editing this face."; return
    }
    let original=sourceArtwork,value=projection?.source(from:artwork,original:original) ?? artwork
    if projection?.requiresInsideSource==true,artworkGesture.map({store.engine.isInteracting(withGeneration:$0.token)}) != true {
      let key="artwork-\(object.id)"
      if store.engine.isInteracting(with:key) {artworkGesture=(key,store.engine.beginInteraction(key))}
    }
    let gestureKey=artworkGesture.flatMap{store.engine.isInteracting(withGeneration:$0.token) ? $0.key:nil}
    if let projection,projection.requiresInsideSource {
      guard value != original else{return}
      do {
        try validateArtwork(value)
        try store.engine.edit("Edited artwork",coalescing:gestureKey ?? "artwork-\(object.id)") {project in
          let sourceID=try PaperCommands.ensureInside(in:&project,objectID:projection.constructionID)
          try project.setArtwork(value,for:sourceID)
        }
        if let current=frames.first(where:{$0.id==projection.id})?.projection {adoptProjectionSource(current)}
        store.changed()
      } catch {store.error=error.localizedDescription}
    } else if let gestureKey,gestureKey != "artwork-\(destination.id)" {
      // A blank face can acquire its canonical sheet during a held native gesture.
      // Keep its original generation/coalescing key through pointer-up or text end.
      do {try validateArtwork(value);try store.engine.edit("Edited artwork",coalescing:gestureKey){try $0.setArtwork(value,for:destination.id)};store.changed()}
      catch {store.error=error.localizedDescription}
    } else {store.saveArtwork(value,for:destination)}
  }
  private func adoptProjectionSource(_ projection:CanvasSourceProjection) {
    guard objectID != projection.sourceID else{return}
    let frameID=projection.id
    objectID=projection.sourceID;projectionFrameID=frameID;linkedTargetID=projection.constructionID
  }
  func moveCanvasFrame(to point: Point2) {
    guard let store, let frame = activeCanvasFrame else { return }
    if let projection = frame.projection {
      do {
        try store.engine.edit("Moved Canvas representation", source: "Studio", coalescing: "artwork-\(objectID?.uuidString ?? "")") { project in
          guard let i = project.objects.firstIndex(where: { $0.id == projection.constructionID }) else { return }
          if project.objects[i].canvasProjectionPositions == nil { project.objects[i].canvasProjectionPositions = [:] }
          project.objects[i].canvasProjectionPositions?[projection.key] = point
        }
        store.changed()
      } catch { store.error = error.localizedDescription }
    } else {
      mutate { $0.canvasPosition = point }
    }
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
    if object==nil {reconcile()}
    canvas?.finishText()
    guard let store, let object else { return }
    guard activeProjection.flatMap({p in store.project?.objects.first{$0.id==p.constructionID}})?.locked != true else {
      store.error="Unlock the physical construction before editing this face.";return
    }
    var input = args
    input["object_id"] = object.id.uuidString
    input["command"] = command
    if !selection.isEmpty { input["element_ids"] = selection.map(\.uuidString) }
    do {
      if let projection=activeProjection,projection.requiresInsideSource || ((projection.panelID != nil || projection.sourceToLocal != Affine2()) &&
        ["add", "replace", "delete", "duplicate", "group", "ungroup", "align", "distribute", "reorder", "flip", "clip", "release_clip", "origin", "transform"].contains(command)) {
        var value = art
        let selected = try ArtworkCommands.apply(command, to: &value, ids: selection, arguments: input)
        // saveArtwork also serves continuous typing. A command without an
        // explicit gesture must not merge with a preceding discrete command.
        if !store.engine.isInteracting(with:"artwork-\(object.id)") {store.engine.endInteraction()}
        save(value); selection = selected
        return
      }
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
    reconcile()
    guard let id=objectID else{return nil}
    let key="artwork-\(id)"
    guard let token=store?.engine.beginInteraction(key) else{return nil}
    artworkGesture=(key,token);return token
  }
  func endGesture() {store?.engine.endInteraction();artworkGesture=nil}
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
      e.recolorTextFill(color)
    }) {return}
    update {
      if $0.kind == "text" { $0.recolorTextFill(color); return }
      $0.color = color
      $0.fillSwatchID = nil
      if let stack=$0.paintStack { $0.paintStack=ArtworkPaintLayer.recoloringFills(stack,color:color) }
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
    guard activeProjection.flatMap({p in store.project?.objects.first{$0.id==p.constructionID}})?.locked != true else {
      store.error="Unlock the physical construction before editing this face.";return
    }
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
    guard activeProjection.flatMap({p in store.project?.objects.first{$0.id==p.constructionID}})?.locked != true else {
      store.error="Unlock the physical construction before editing this face.";return
    }
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
    let tableSelection = store.engine.selection
    let previousIDs = Set(store.project?.objects.map(\.id) ?? [])
    store.perform(
      "form_add_object",
      [
        "recipe_id": "artboard", "name": name, "parameters": ["width": width, "depth": height],
        "material_id": "chalk",
      ])
    store.engine.selection = tableSelection
    if let object = store.project?.objects.first(where: { !previousIDs.contains($0.id) }) {
      store.saveArtwork(.init(background: "#FFFFFF"), for: object)
      objectID = object.id; linkedTargetID = nil; projectionFrameID = nil
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

  @discardableResult func copy() -> Bool {copyArtwork()}
  func paste() {pasteArtwork()}
  func export(_ format: String) {
    guard let store, let object else { return }
    store.exportArtworkDialog(format,object:object,dpi:exportDPI,outlineText:exportOutline,
      elementIDs:object.isCanvasWorkspace ? selection : [])
  }
}
