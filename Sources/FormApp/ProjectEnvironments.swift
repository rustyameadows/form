import AppKit
import FormCore
import SwiftUI

/// Environments describe intent; Canvas/Table describe editing surfaces.
enum ProjectEnvironment: String, CaseIterable, Identifiable {
  case form, function, fabricate, studio
  static let primary: [Self] = [.form, .function, .fabricate]
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var symbol: String {
    switch self {
    case .form: return "square.and.pencil"
    case .function: return "ruler"
    case .fabricate: return "square.stack.3d.up"
    case .studio: return "camera.aperture"
    }
  }
}

extension StudioStore {
  func showEnvironment(_ next: ProjectEnvironment) {
    guard project != nil else { return }
    showingHome = false
    guard next != environment else { return }
    finishArtworkEditing()
    if next == .studio {
      studioReturnSurface = (mode, surfaceLayout)
      closeDetachedCanvas()
      surfaceLayout = .single
      environment = .studio
      mode = .studio
    } else {
      let returning = environment == .studio ? studioReturnSurface : nil
      environment = next
      studioReturnSurface = nil
      if let returning {
        // Restore focus/layout without activating a different artwork source.
        mode = returning.mode == .studio ? .table : returning.mode
        surfaceLayout = returning.layout == .detached ? .single : returning.layout
        if returning.layout == .detached { detachCanvas() }
      } else if mode == .studio { mode = .table }
    }
    changed(save: false)
  }

  func presentFabrication(_ destination: FabricationDestination) {
    guard let project, destination.available(in: project, object: primary) else { return }
    let sourceProjectID = project.id, sourceObjectID = primary?.id
    finishArtworkEditing()
    guard let current = self.project, current.id == sourceProjectID else { return }
    let source = current.objects.first { $0.id == sourceObjectID }
    guard destination.available(in: current, object: source) else { return }
    if destination == .print3D { printing.open(objectID: sourceObjectID); return }
    if [.pattern, .layout].contains(destination), let id = sourceObjectID { artworkSession.activate(id) }
    fabricationReview = .init(destination: destination, objectID: sourceObjectID, projectID: sourceProjectID)
  }
}

enum FabricationDestination: String, CaseIterable, Identifiable {
  case print3D, page, pattern, layout, embroidery, decoration, jobs, collection
  var id: String { rawValue }
  var title: String {
    switch self {
    case .print3D: return "3D print preparation"
    case .page: return "Physical page & PDF"
    case .pattern: return "Cutting pattern & tiled PDF"
    case .layout: return "Material cutting layout"
    case .embroidery: return "Embroidery & stitch preview"
    case .decoration: return "HTV / DTF preparation"
    case .jobs: return "Production jobs & archives"
    case .collection: return "Collection production"
    }
  }
  var symbol: String {
    switch self {
    case .print3D: return "printer"
    case .page: return "doc"
    case .pattern: return "scissors"
    case .layout: return "rectangle.split.3x1"
    case .embroidery: return "point.topleft.down.to.point.bottomright.curvepath"
    case .decoration: return "tshirt"
    case .jobs: return "archivebox"
    case .collection: return "list.bullet.rectangle"
    }
  }
  func available(in project: Project, object: ProductObject?) -> Bool {
    if self == .jobs || self == .collection { return true }
    guard let object, !object.isCanvasWorkspace else { return false }
    switch self {
    case .print3D:
      return !object.isFlexibleSurface && object.textile == nil && object.patternAssembly == nil
        && !["reference", "swatch", "paperStack", "booklet", "sleeve", "artboard"].contains(object.recipeID)
    case .page: return (try? ArtworkPageSetup.source(project, objectID: object.id)) != nil
    case .pattern, .layout: return project.editableArtwork(object)?.elements.contains(where: { $0.sewingPiece != nil }) == true
    case .embroidery:
      let spec = object.textile ?? TextileProduct.defaults(for: object.recipeID)
      guard let spec else { return false }
      return !object.locked && (spec.embroidery != nil || [.embroideredPatch, .directEmbroidery].contains(spec.process))
    case .decoration: return object.supportsArtworkFace && project.editableArtwork(object) != nil
    case .jobs, .collection: return true
    }
  }
}

struct FabricationReview: Identifiable {
  let id = UUID()
  let destination: FabricationDestination
  let objectID: UUID?
  let projectID: UUID
}

struct FabricationReviewView: View {
  @EnvironmentObject var store: StudioStore
  let review: FabricationReview
  var body: some View {
    if let project = store.project, project.id == review.projectID {
      let object = project.objects.first { $0.id == review.objectID }
      switch review.destination {
      case .page: if let object { ArtworkPageReview(store: store, objectID: object.id) }
      case .pattern: SewingPatternPreview(session: store.artworkSession)
      case .layout: SewingLayoutEditor(session: store.artworkSession)
      case .embroidery: if let object { EmbroideryEditor(object: object, project: project) }
      case .decoration: if let object { DecorationPreparationView(store: store, objectID: object.id) }
      case .jobs: ProductionJobsView(objectID: review.objectID)
      case .collection: CollectionProductionView(store: store)
      case .print3D: EmptyView() // Print has its existing dedicated sheet/lifecycle.
      }
    }
  }
}

struct EnvironmentContextPanel: View {
  @EnvironmentObject var store: StudioStore
  private var objects: [ProductObject] { store.project?.objects.filter { !$0.isCanvasWorkspace } ?? [] }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        Label(store.environment.title.uppercased(), systemImage: store.environment.symbol)
          .font(.system(size: 10, weight: .semibold)).tracking(1.5)
        Text(store.environment == .function ? "Dimensions, construction & relationships" : "Prepare the same source for making")
          .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        Picker("Object", selection: Binding<UUID?>(get: { store.primary?.id }, set: { store.select($0) })) {
          Text("Choose an object").tag(UUID?.none)
          ForEach(objects) { Text($0.name).tag(Optional($0.id)) }
        }.font(.system(size: 11)).accessibilityLabel("Environment object")
      }.padding(16)
      Divider()
      if store.environment == .function {
        if let object = store.primary {
          if let source = object.artworkSourceID, let name = store.project?.objects.first(where: { $0.id == source })?.name {
            Label("Artwork source · " + name, systemImage: "link").font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(14)
          }
          ObjectInspector().id(object.id).frame(maxWidth: .infinity)
        } else {
          Text("Choose a component to inspect its dimensions, parameters, placement and existing construction controls.")
            .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(18)
          Spacer()
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if let project = store.project {
              ForEach(FabricationDestination.allCases) { destination in
                Button { store.presentFabrication(destination) } label: {
                  Label(destination.title, systemImage: destination.symbol)
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.buttonStyle(.borderless).disabled(!destination.available(in: project, object: store.primary))
              }
            }
            Divider()
            Button("Filaments, materials & equipment…") { store.showingLibrary = true }.font(.system(size: 11))
            Text("Choose a source object to enable its processes. Preparation and review use the existing project assets.")
              .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
          }.padding(16)
        }
      }
    }.frame(width: 310).background(Palette.paper)
      .accessibilityElement(children: .contain).accessibilityLabel(store.environment.title + " controls")
  }
}
