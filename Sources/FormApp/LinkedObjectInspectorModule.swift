import AppKit
import FormCore
import FormGraphics
import SwiftUI

/// A relationship to existing source, never a second artwork document.
struct LinkedInspectorAssociation: Equatable, Identifiable {
  enum Kind: Equatable { case artwork, paper(inside: Bool), cuttingSource, surface(String), unassigned }
  let objectID: UUID
  let sourceID: UUID?
  let kind: Kind
  let title: String
  var review: String?
  var id: String {
    let suffix: String
    switch kind {
    case .artwork: suffix = "artwork"
    case .paper(let inside): suffix = inside ? "inside" : "outside"
    case .cuttingSource: suffix = "cutting"
    case .surface(let id): suffix = "surface:" + id
    case .unassigned: suffix = "unassigned"
    }
    return objectID.uuidString + ":" + suffix
  }
}

@MainActor enum LinkedInspectorRelationships {
  static func table(_ object: ProductObject, in project: Project) -> [LinkedInspectorAssociation] {
    if PaperConstruction.isPaper(object) {
      guard (try? PaperConstruction.definition(for: object).net()) != nil else { return [] }
      var result = [LinkedInspectorAssociation(objectID: object.id, sourceID: project.artworkOwner(object).id,
        kind: .paper(inside: false), title: "Outside dieline")]
      if let id = object.paperConstruction?.insideArtworkSourceID, project.objects.contains(where: { $0.id == id }) {
        result.append(.init(objectID: object.id, sourceID: id, kind: .paper(inside: true), title: "Inside dieline"))
      }
      return result
    }
    if let context = FabricEnvironmentContext(object: object, project: project), let source = context.sourceID,
      project.objects.contains(where: { $0.id == source }) {
      return [.init(objectID: object.id, sourceID: source, kind: .cuttingSource,
        title: project.objects.first(where: { $0.id == source })?.name ?? "Cutting source")]
    }
    let surfaces = object.cadRepresentation?.resolvedSurfaces ?? []
    let bindings = object.surfaceArtworkBindings ?? []
    if object.cadModel != nil || object.cadRepresentation != nil || !bindings.isEmpty {
      var result = surfaces.map { surface -> LinkedInspectorAssociation in
        let binding = bindings.first { $0.surfaceID == surface.id }
        return .init(objectID: object.id, sourceID: binding?.sourceObjectID, kind: .surface(surface.id),
          title: surface.name, review: binding == nil ? "Link a Canvas frame to this surface to compose its artwork." : nil)
      }
      result += bindings.filter { binding in !surfaces.contains { $0.id == binding.surfaceID } }.map { binding in
        .init(objectID: object.id, sourceID: binding.sourceObjectID, kind: .surface(binding.surfaceID),
          title: binding.surfaceID, review: "This surface needs review; its Canvas source is retained.")
      }
      return result.isEmpty ? [.init(objectID: object.id, sourceID: nil, kind: .unassigned,
        title: "Canvas surfaces", review: "Declare a planar surface and link a Canvas frame to compose artwork.")] : result
    }
    if object.artwork != nil || object.artworkSourceID != nil || object.supportsArtworkFace {
      let source = project.artworkOwner(object)
      return [.init(objectID: object.id, sourceID: source.id, kind: .artwork, title: source.name,
        review: source.artwork == nil ? "Add or link Canvas artwork to compose this surface." : nil)]
    }
    if object.isFlexibleSurface {
      return [.init(objectID: object.id, sourceID: nil, kind: .unassigned,
        title: "Cutting source", review: "No linked flat cutting source is available for this object.")]
    }
    return []
  }

  static func canvas(_ session: ArtworkSession, in project: Project) -> [LinkedInspectorAssociation] {
    guard let sourceID = session.objectID else { return [] }
    let all = project.objects.filter { !$0.isCanvasWorkspace && hasPhysicalView($0, in: project) }
      .flatMap { table($0, in: project) }.filter { $0.sourceID == sourceID }
    if let target = session.activeProjection?.constructionID ?? session.linkedTargetID {
      let focused = all.filter { $0.objectID == target }
      if !focused.isEmpty { return focused }
    }
    let consumers = all.filter { $0.objectID != sourceID }
    return consumers.isEmpty ? all : consumers
  }

  static func hasPhysicalView(_ object: ProductObject, in project: Project) -> Bool {
    PaperConstruction.isPaper(object) || object.isFlexibleSurface || object.meshAsset != nil
      || object.cadModel != nil || object.cadRepresentation != nil
      || project.recipe(object.recipeID)?.parts.isEmpty == false
  }

  static func canOpenCanvas(_ link: LinkedInspectorAssociation, in project: Project) -> Bool {
    guard let sourceID = link.sourceID, let source = project.objects.first(where: { $0.id == sourceID }),
      let object = project.objects.first(where: { $0.id == link.objectID }) else { return false }
    switch link.kind {
    case .paper: return (try? PaperConstruction.definition(for: object).net()) != nil
    case .surface(let id):
      return source.artwork != nil && object.cadModel != nil
        && object.cadRepresentation?.resolvedSurfaces?.contains(where: { $0.id == id }) == true
    case .artwork, .cuttingSource: return project.editableArtwork(source) != nil
    case .unassigned: return false
    }
  }

  /// Layout and source identities are retained; navigation never creates artwork.
  @discardableResult static func openCanvas(_ link: LinkedInspectorAssociation, store: StudioStore) -> Bool {
    guard let project = store.project, canOpenCanvas(link, in: project),
      let object = project.objects.first(where: { $0.id == link.objectID }), let sourceID = link.sourceID else { return false }
    let surfaceFrameID: UUID?
    if case .surface(let id) = link.kind {
      guard let frame = store.artworkSession.frames.first(where: {
        $0.projection?.constructionID == object.id && $0.projection?.sourceID == sourceID && $0.projection?.panelID == id
      }) else { return false }
      surfaceFrameID = frame.id
    } else { surfaceFrameID = nil }
    store.finishArtworkEditing()
    store.showEnvironment(.form)
    switch link.kind {
    case .paper(let inside):
      store.paperInside = inside
      store.activatePaperArtwork(object)
      store.focusConstructionCanvas(objectID: object.id, panelID: nil)
    case .cuttingSource:
      guard store.activateFabricPatternSource(for: object.id) != nil else { return false }
    case .surface:
      guard let surfaceFrameID else { return false }
      store.artworkSession.activate(surfaceFrameID)
    case .artwork:
      store.artworkSession.activate(sourceID)
      store.artworkSession.linkedTargetID = sourceID == object.id ? nil : object.id
    case .unassigned: return false
    }
    store.showingHome = false
    store.activateDesignSurface(.artwork)
    if store.surfaceLayout == .detached {
      store.canvasWindowController?.showWindow(nil)
      store.canvasWindowController?.window?.makeKeyAndOrderFront(nil)
    }
    store.artworkSession.canvas?.synchronize()
    store.artworkSession.canvas?.fit(all: false)
    return true
  }

  @discardableResult static func openTable(_ link: LinkedInspectorAssociation, store: StudioStore) -> Bool {
    store.findOnTable(link.objectID)
  }

  static func previewProject(object: ProductObject, in project: Project) -> Project {
    var preview = project
    if let index = preview.objects.firstIndex(where: { $0.id == object.id }) {
      preview.objects[index] = object
      preview.objects[index].position = .init(); preview.objects[index].rotation = 0
    }
    return preview
  }
}

struct LinkedInspectorArtworkContent: Equatable {
  var artwork: Artwork
  var size: Point2
  var net: PaperNet? = nil
  var frame: PhysicalArtworkFrame? = nil
  var boundary: [Point2] = []
  var stockColor = "#FFFFFF"
  var guides = true
  var hiddenRoles: Set<ArtworkProductionRole> = []
}

@MainActor enum LinkedInspectorArtwork {
  static func content(_ link: LinkedInspectorAssociation, in project: Project,
    guides: Bool = true, hiddenRoles: Set<ArtworkProductionRole> = []) -> LinkedInspectorArtworkContent? {
    guard let object = project.objects.first(where: { $0.id == link.objectID }) else { return nil }
    if case .paper(let inside) = link.kind {
      guard let net = try? PaperConstruction.definition(for: object).net(),
        let frame = try? PhysicalArtworkFrame.paper(net: net, inside: inside) else { return nil }
      let source = link.sourceID.flatMap { id in project.objects.first { $0.id == id } }
      let art = source.flatMap { project.surfaceArtwork($0) } ?? Artwork(background: "#FFFFFF")
      return .init(artwork: art, size: frame.size, net: net, frame: frame,
        stockColor: object.color ?? project.material(object.materialID).color, guides: guides && art.showGuides != false, hiddenRoles: hiddenRoles)
    }
    if case .surface(let id) = link.kind {
      guard let binding = object.surfaceArtworkBindings?.first(where: { $0.surfaceID == id }),
        let art = project.physicalSurfaceArtwork(binding),
        let surface = object.cadRepresentation?.resolvedSurfaces?.first(where: { $0.id == id }) else { return nil }
      return .init(artwork: art, size: .init(surface.width, surface.height),
        boundary: surface.boundary.map { .init($0.x, $0.y) }, hiddenRoles: hiddenRoles)
    }
    guard let id = link.sourceID, let source = project.objects.first(where: { $0.id == id }),
      let art = project.surfaceArtwork(source) else { return nil }
    return .init(artwork: art, size: project.artworkSize(source), hiddenRoles: hiddenRoles)
  }
}

/// One bounded cached raster; resize, inspector collapse and pointer motion do not regenerate it.
@MainActor final class LinkedInspectorArtworkView: NSView {
  private var content: LinkedInspectorArtworkContent?
  private var assets = URL(fileURLWithPath: "/")
  private var cached: NSImage?
  private let sewing = CanvasSewingGuideCache()
  private(set) var builds = 0
  func update(_ value: LinkedInspectorArtworkContent?, assets: URL) {
    guard content != value || self.assets != assets else { return }
    content = value; self.assets = assets; cached = nil; sewing.clear(); needsDisplay = true
  }
  func renderedImage() -> NSImage? {
    if let cached { return cached }
    guard let content, content.size.x.isFinite, content.size.y.isFinite,
      content.size.x > 0, content.size.y > 0 else { return nil }
    let density = 512 / max(content.size.x, content.size.y)
    guard density.isFinite, density > 0 else { return nil }
    let width = max(1, Int((content.size.x * density).rounded())), height = max(1, Int((content.size.y * density).rounded()))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    builds += 1
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: density, y: -density)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    var art = content.artwork
    let roles = ArtworkProduction.effectiveRoles(in: art)
    art.elements.removeAll { content.hiddenRoles.contains(roles[$0.id] ?? .print) }
    if let net = content.net, let frame = content.frame {
      context.saveGState(); context.concatenate(frame.sourceToLocal.cg)
      PaperOutput.drawNet(net, artwork: art, assets: assets, context: context,
        guides: content.guides, lineWidth: max(0.18, 2 / density), stockColor: content.stockColor)
      context.restoreGState()
    } else {
      context.saveGState()
      if !content.boundary.isEmpty { context.addPath(PaperOutput.path(content.boundary)); context.clip() }
      let overlay = content.guides ? content.artwork.elements.first(where: { $0.sewingPiece != nil })
        .flatMap { sewing.overlay(frameID: $0.id, source: content.artwork) } : nil
      if let overlay { art.elements.removeAll { overlay.sourceStrokeIDs.contains($0.id) } }
      ArtworkRenderer.draw(art, width: content.size.x, height: content.size.y, assets: assets, production: false)
      if let overlay {
        var technical = overlay.interfaceArtwork(scale: density / 2)
        let technicalRoles = ArtworkProduction.effectiveRoles(in: technical)
        technical.elements.removeAll { content.hiddenRoles.contains(technicalRoles[$0.id] ?? .guide) }
        technical.backgroundOpacity = 0
        ArtworkRenderer.draw(technical, width: content.size.x, height: content.size.y, assets: assets, production: false)
      }
      context.restoreGState()
    }
    guard let image = context.makeImage() else { return nil }
    let result = NSImage(cgImage: image, size: .init(width: width, height: height)); cached = result; return result
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let image = renderedImage() else { return }
    let area = bounds.insetBy(dx: 8, dy: 8), ratio = min(area.width / image.size.width, area.height / image.size.height)
    let target = CGRect(x: area.midX - image.size.width * ratio / 2, y: area.midY - image.size.height * ratio / 2,
      width: image.size.width * ratio, height: image.size.height * ratio)
    image.draw(in: target)
  }
}

private struct LinkedInspectorArtworkThumbnail: NSViewRepresentable {
  let content: LinkedInspectorArtworkContent
  let assets: URL
  func makeNSView(context: Context) -> LinkedInspectorArtworkView { LinkedInspectorArtworkView() }
  func updateNSView(_ view: LinkedInspectorArtworkView, context: Context) { view.update(content, assets: assets) }
}

@MainActor private struct LinkedInspectorObjectPreview: NSViewRepresentable {
  let object: ProductObject
  let project: Project
  let assets: URL
  let revision: Int
  @MainActor final class Coordinator {
    let controller = TableSceneController()
    var projectID: UUID?, targetID: UUID?, revision: Int?, object: ProductObject?
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> TableSceneView {
    let view = TableSceneView(frame: .zero); view.controller = context.coordinator.controller
    context.coordinator.controller.view = view; return view
  }
  func updateNSView(_ view: TableSceneView, context: Context) {
    let c = context.coordinator
    guard c.projectID != project.id || c.targetID != object.id || c.revision != revision || c.object != object else { return }
    let preview = LinkedInspectorRelationships.previewProject(object: object, in: project)
    let first = c.targetID != object.id || c.projectID != project.id, builds = c.controller.geometryBuilds
    c.controller.sync(preview, selection: [], isolated: [], showGrid: false, studio: false,
      preset: "Daylight", assets: assets, textureLimit: 512, renderObjectIDs: [object.id])
    if first || builds != c.controller.geometryBuilds { c.controller.fitAll() }
    c.projectID = project.id; c.targetID = object.id; c.revision = revision; c.object = object
  }
}

/// The same inspector module presents the opposite side of a canonical relationship.
struct LinkedObjectInspectorModule: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  private let object: ProductObject?
  @State private var expanded = true
  @State private var selectedID: String?
  init(session: ArtworkSession) { self.session = session; object = nil }
  init(object: ProductObject, session: ArtworkSession) { self.object = object; self.session = session }
  private var isCanvas: Bool { object == nil }
  private var expansion: Binding<Bool> {
    isCanvas ? Binding(get: { session.preview }, set: { session.preview = $0 }) : $expanded
  }
  var body: some View {
    if let project = store.project {
      let links = object.map { LinkedInspectorRelationships.table($0, in: project) }
        ?? LinkedInspectorRelationships.canvas(session, in: project)
      if let link = links.first(where: { $0.id == selectedID }) ?? links.first {
        InspectorModule("Linked views", symbol: "link", isExpanded: expansion) {
          if links.count > 1 {
            Picker("Related view", selection: Binding(get: { link.id }, set: { selectedID = $0 })) {
              ForEach(links) { Text($0.title).tag($0.id) }
            }.inspectorPicker()
          }
          let target = project.objects.first { $0.id == link.objectID }
          let content = LinkedInspectorArtwork.content(link, in: project,
            guides: store.paperShowingGuides, hiddenRoles: session.hiddenProductionRoles)
          Button {
            if isCanvas { _ = LinkedInspectorRelationships.openTable(link, store: store) }
            else { _ = LinkedInspectorRelationships.openCanvas(link, store: store) }
          } label: {
            InspectorRow(isCanvas ? "Find on Table" : "Find on Canvas") {
              Text(isCanvas ? target?.name ?? link.title : link.title).lineLimit(1)
              Image(systemName: "arrow.up.forward").foregroundStyle(Palette.secondary)
            }
          }.buttonStyle(.plain).disabled(!isCanvas && !LinkedInspectorRelationships.canOpenCanvas(link, in: project))
          InspectorPreviewTile(height: 140) {
            if isCanvas, let target {
              Button { _ = LinkedInspectorRelationships.openTable(link, store: store) } label: {
                LinkedInspectorObjectPreview(object: target, project: project,
                  assets: session.assets, revision: store.revision).allowsHitTesting(false)
              }.buttonStyle(.plain).accessibilityLabel("Find " + target.name + " on Table")
            } else if let content {
              Button { _ = LinkedInspectorRelationships.openCanvas(link, store: store) } label: {
                LinkedInspectorArtworkThumbnail(content: content, assets: session.assets)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }.buttonStyle(.plain).disabled(!LinkedInspectorRelationships.canOpenCanvas(link, in: project))
                .accessibilityLabel("Open " + link.title + " on Canvas")
            } else {
              VStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 22, weight: .light))
                Text("No linked Canvas artwork").font(InspectorStyle.captionFont)
              }.foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          if let review = link.review { Text(review).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary) }
        }
      }
    }
  }
}
