import AppKit
import FormCore
import SwiftUI

struct ArtworkWorkspace: View {
  @EnvironmentObject var store: StudioStore
  @State private var tool = "select"
  @State private var selectedID: UUID?
  @State private var dieline = false
  var object: ProductObject? {
    if let primary = store.primary {
      return primary["width"] > 0 && primary["depth"] > 0 ? primary : nil
    }
    return store.project?.objects.first { $0.artwork != nil && $0["width"] > 0 && $0["depth"] > 0 }
  }
  var body: some View {
    if let object, let project = store.project {
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          HStack(spacing: 6) {
            ForEach(
              [
                ("select", "cursorarrow"), ("text", "textformat"), ("rectangle", "square"),
                ("ellipse", "circle"), ("line", "line.diagonal"),
              ], id: \.0
            ) { item in
              Button {
                tool = item.0
                dieline = false
              } label: {
                Image(systemName: item.1).font(.system(size: 14)).frame(width: 33, height: 33)
                  .background(
                    tool == item.0 ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain).help(item.0.capitalized)
            }
            IconButton("Import image", symbol: "photo.badge.plus") { importImage(object) }
            Spacer()
            if object.recipeID == "sleeve" {
              Picker("Representation", selection: $dieline) {
                Text("Artwork").tag(false)
                Text("Dieline").tag(true)
              }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            Text("\(Int(object["width"])) × \(Int(object["depth"])) mm").font(
              .system(size: 10, design: .monospaced)
            ).foregroundStyle(Palette.secondary).padding(.leading, 12)
          }.padding(.horizontal, 22).frame(height: 56).background(Palette.paper)
          Rectangle().fill(Palette.line).frame(height: 1)
          ArtworkEditor(
            object: object,
            artwork: object.artwork ?? .init(background: project.material(object.materialID).color),
            tool: tool, dieline: dieline, selectedID: $selectedID,
            assets: store.repository.url(for: project.id).appendingPathComponent("Assets")
          ) { store.saveArtwork($0, for: object) }
          HStack(spacing: 15) {
            Text(dieline ? "RED  /  CUT" : "BLEED  /  \(Int(object.artwork?.bleed ?? 3)) mm")
              .foregroundStyle(Palette.accent)
            Text(
              dieline
                ? "BLUE DASHED  /  SCORE" : "Drag elements to arrange · Shift for 5 mm snapping"
            ).foregroundStyle(Palette.secondary)
            Spacer()
            Text("1:1 PHYSICAL UNITS").foregroundStyle(Palette.secondary)
          }.font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.6).padding(16)
            .background(Palette.paper)
        }
        Rectangle().fill(Palette.line).frame(width: 1)
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            SectionLabel("LIVE OBJECT")
            Spacer()
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Palette.accent)
          }.padding(19)
          ObjectPreview(
            object: object, project: project,
            assets: store.repository.url(for: project.id).appendingPathComponent("Assets")
          ).frame(height: 235).clipped()
          VStack(alignment: .leading, spacing: 17) {
            Text(object.name).font(.system(size: 19, weight: .regular, design: .serif))
            if let art = object.artwork,
              let element = art.elements.first(where: { $0.id == selectedID })
            {
              ArtworkElementInspector(object: object, element: element)
            } else {
              Text(
                "Select an element to edit its content and dimensions. Changes appear on your object as you work."
              ).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(3)
              if let art = object.artwork {
                ColorPicker(
                  "Background",
                  selection: Binding(
                    get: { Color(nsColor: NSColor(hex: art.background)) },
                    set: {
                      var changed = art
                      changed.background = NSColor($0).hexString
                      store.saveArtwork(changed, for: object)
                    }), supportsOpacity: false
                ).font(.system(size: 12))
              }
            }
            Divider()
            SectionLabel("LAYERS")
            ScrollView {
              VStack(spacing: 4) {
                ForEach((object.artwork?.elements ?? []).reversed()) { element in
                  Button {
                    selectedID = element.id
                    tool = "select"
                  } label: {
                    HStack {
                      Image(
                        systemName: element.kind == "text"
                          ? "textformat" : element.kind == "ellipse" ? "circle" : "square"
                      ).frame(width: 20)
                      Text(
                        element.kind == "text"
                          ? element.text.replacingOccurrences(of: "\n", with: " ")
                          : element.kind.capitalized
                      ).lineLimit(1)
                      Spacer()
                    }.font(.system(size: 11)).padding(9).background(
                      selectedID == element.id ? Color.white : .clear,
                      in: RoundedRectangle(cornerRadius: 6))
                  }.buttonStyle(.plain)
                }
              }
            }.frame(maxHeight: 140)
            Spacer(minLength: 0)
            HStack {
              Button("Export PDF") { store.exportDialog("pdf", object: object) }
              if object.recipeID == "sleeve" {
                Button("Export SVG") { store.exportDialog("svg", object: object) }
              }
            }.controlSize(.small)
          }.padding(20)
        }.frame(width: 310).background(Palette.paper)
      }
    } else {
      VStack(spacing: 17) {
        Image(systemName: "square.and.pencil").font(.system(size: 35, weight: .ultraLight))
        Text("Give an object a little character.").font(.system(size: 26, design: .serif))
        Text("Select a sleeve, booklet, paper stack, or box on the Table to edit its artwork.")
          .font(.system(size: 13)).foregroundStyle(Palette.secondary)
        Button("Back to the Table") { store.mode = .table }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper)
    }
  }
  func importImage(_ object: ProductObject) {
    guard let project = store.project else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    if panel.runModal() == .OK, let url = panel.url {
      do {
        let asset = try store.repository.importAsset(url, into: project.id)
        var art = object.artwork ?? .init()
        let element = ArtworkElement(
          kind: "image", x: 15, y: 15, width: 80, height: 60, asset: asset)
        art.elements.append(element)
        selectedID = element.id
        store.saveArtwork(art, for: object)
      } catch { store.error = error.localizedDescription }
    }
  }
}

struct ArtworkElementInspector: View {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  let element: ArtworkElement
  func update(_ body: (inout ArtworkElement) -> Void) {
    guard var art = object.artwork, let i = art.elements.firstIndex(where: { $0.id == element.id })
    else { return }
    body(&art.elements[i])
    store.saveArtwork(art, for: object)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionLabel("\(element.kind.uppercased()) PROPERTIES")
      if element.kind == "text" {
        TextField(
          "Text", text: Binding(get: { element.text }, set: { text in update { $0.text = text } }),
          axis: .vertical
        ).textFieldStyle(.roundedBorder).font(.system(size: 12)).lineLimit(2...5)
        HStack {
          Text("Type size")
          Spacer()
          TextField(
            "Points",
            value: Binding(
              get: { element.fontSize }, set: { value in update { $0.fontSize = max(1, value) } }),
            format: .number
          ).frame(width: 55)
          Text("pt").foregroundStyle(Palette.secondary)
        }.font(.system(size: 11))
      }
      HStack {
        PlacementField("X", value: element.x) { value in update { $0.x = value } }
        PlacementField("Y", value: element.y) { value in update { $0.y = value } }
      }
      HStack {
        PlacementField("W", value: element.width) { value in update { $0.width = max(1, value) } }
        PlacementField("H", value: element.height) { value in update { $0.height = max(1, value) } }
      }
      ColorPicker(
        "Color",
        selection: Binding(
          get: { Color(nsColor: NSColor(hex: element.color)) },
          set: { value in update { $0.color = NSColor(value).hexString } }), supportsOpacity: false
      ).font(.system(size: 11))
      HStack {
        Button {
          guard var art = object.artwork,
            let i = art.elements.firstIndex(where: { $0.id == element.id }),
            i < art.elements.count - 1
          else { return }
          art.elements.swapAt(i, i + 1)
          store.saveArtwork(art, for: object)
        } label: {
          Image(systemName: "square.3.layers.3d.top.filled")
        }.help("Bring forward")
        Button {
          guard var art = object.artwork,
            let i = art.elements.firstIndex(where: { $0.id == element.id }), i > 0
          else { return }
          art.elements.swapAt(i, i - 1)
          store.saveArtwork(art, for: object)
        } label: {
          Image(systemName: "square.3.layers.3d.bottom.filled")
        }.help("Send backward")
        Spacer()
        Button("Remove") {
          guard var art = object.artwork else { return }
          art.elements.removeAll { $0.id == element.id }
          store.saveArtwork(art, for: object)
        }
      }.controlSize(.small)
    }
  }
}

struct ObjectPreview: NSViewRepresentable {
  let object: ProductObject
  let project: Project
  let assets: URL
  func makeCoordinator() -> TableSceneController { TableSceneController() }
  func makeNSView(context: Context) -> TableSCNView {
    let view = TableSCNView(frame: .zero)
    view.controller = context.coordinator
    context.coordinator.view = view
    view.scene = context.coordinator.scene
    view.pointOfView = context.coordinator.cameraNode
    view.antialiasingMode = .multisampling4X
    view.rendersContinuously = false
    return view
  }
  func updateNSView(_ view: TableSCNView, context: Context) {
    var preview = project
    preview.objects = [object]
    preview.objects[0].position = .init()
    preview.objects[0].rotation = 0
    context.coordinator.sync(
      preview, selection: [], isolated: [], showGrid: false, studio: false, preset: "Daylight",
      assets: assets)
    context.coordinator.fitAll()
  }
}

struct ArtworkEditor: NSViewRepresentable {
  let object: ProductObject
  let artwork: Artwork
  let tool: String
  let dieline: Bool
  @Binding var selectedID: UUID?
  let assets: URL
  let onChange: (Artwork) -> Void
  func makeNSView(context: Context) -> ArtworkNSView {
    let view = ArtworkNSView()
    view.setAccessibilityLabel("Artwork canvas")
    return view
  }
  func updateNSView(_ view: ArtworkNSView, context: Context) {
    view.object = object
    view.artwork = artwork
    view.tool = tool
    view.dieline = dieline
    view.selectedID = selectedID
    view.assets = assets
    view.onChange = onChange
    view.onSelection = { selectedID = $0 }
    view.needsDisplay = true
  }
}

final class ArtworkNSView: NSView {
  var object: ProductObject?
  var artwork = Artwork()
  var tool = "select"
  var dieline = false
  var selectedID: UUID?
  var assets = URL(fileURLWithPath: "/")
  var onChange: ((Artwork) -> Void)?
  var onSelection: ((UUID?) -> Void)?
  private var origin = NSPoint.zero
  private var scale = 1.0
  private var down = NSPoint.zero
  private var elementOrigin = NSPoint.zero
  private var creating = false
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(hex: "#E9E8E2").setFill()
    bounds.fill()
    guard let object else { return }
    let size = dieline ? Dieline.dimensions(object) : (object["width"], object["depth"])
    let w = max(size.0, 1)
    let h = max(size.1, 1)
    scale = max(0.05, min((bounds.width - 100) / w, (bounds.height - 100) / h))
    origin = .init(x: (bounds.width - w * scale) / 2, y: (bounds.height - h * scale) / 2)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 18 / scale
    shadow.shadowOffset = .init(width: 0, height: 3 / scale)
    shadow.set()
    NSColor.white.setFill()
    rect.fill()
    NSGraphicsContext.restoreGraphicsState()
    if dieline {
      let frontX = object["width"] + object["height"]
      context.saveGState()
      context.translateBy(x: frontX, y: 0)
      ArtworkDrawing.draw(artwork, width: object["width"], height: h, assets: assets)
      context.restoreGState()
      NSColor(hex: "#D45A37").setStroke()
      let cut = NSBezierPath(rect: rect)
      cut.lineWidth = 1 / scale
      cut.stroke()
      NSColor(hex: "#4589B0").setStroke()
      for x in Dieline.scores(object) {
        let line = NSBezierPath()
        line.move(to: .init(x: x, y: 0))
        line.line(to: .init(x: x, y: h))
        line.lineWidth = 1 / scale
        line.setLineDash([4 / scale, 3 / scale], count: 2, phase: 0)
        line.stroke()
      }
    } else {
      ArtworkDrawing.draw(artwork, width: w, height: h, assets: assets)
      NSColor.white.withAlphaComponent(0.45).setStroke()
      let safe = NSBezierPath(rect: rect.insetBy(dx: artwork.bleed, dy: artwork.bleed))
      safe.lineWidth = 0.6 / scale
      safe.setLineDash([3 / scale, 3 / scale], count: 2, phase: 0)
      safe.stroke()
      if let element = artwork.elements.first(where: { $0.id == selectedID }) {
        let selection = NSRect(
          x: element.x, y: element.y, width: element.width, height: element.height)
        NSColor(hex: "#E49B6E").setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 1.5 / scale
        path.stroke()
        for p in [
          selection.origin, .init(x: selection.maxX, y: selection.minY),
          .init(x: selection.maxX, y: selection.maxY), .init(x: selection.minX, y: selection.maxY),
        ] {
          NSColor.white.setFill()
          let handle = NSBezierPath(
            rect: NSRect(
              x: p.x - 2.5 / scale, y: p.y - 2.5 / scale, width: 5 / scale, height: 5 / scale))
          handle.fill()
          handle.stroke()
        }
      }
    }
    NSGraphicsContext.restoreGraphicsState()
  }
  private func physical(_ event: NSEvent) -> NSPoint {
    let p = convert(event.locationInWindow, from: nil)
    return .init(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
  }
  override func mouseDown(with event: NSEvent) {
    guard !dieline else { return }
    window?.makeFirstResponder(self)
    let point = physical(event)
    down = point
    creating = false
    if tool == "select" {
      selectedID =
        artwork.elements.reversed().first {
          NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point)
        }?.id
      if let e = artwork.elements.first(where: { $0.id == selectedID }) {
        elementOrigin = .init(x: e.x, y: e.y)
      }
      onSelection?(selectedID)
      needsDisplay = true
    } else if let object, point.x >= 0, point.y >= 0, point.x < object["width"],
      point.y < object["depth"]
    {
      let e = ArtworkElement(
        kind: tool, x: point.x.rounded(), y: point.y.rounded(), width: tool == "text" ? 110 : 40,
        height: tool == "text" ? 25 : 40, text: tool == "text" ? "Something worth making." : "",
        color: "#F1E9D0", fontSize: 18)
      artwork.elements.append(e)
      selectedID = e.id
      elementOrigin = .init(x: e.x, y: e.y)
      creating = tool != "text"
      onSelection?(e.id)
      onChange?(artwork)
      needsDisplay = true
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard !dieline, let i = artwork.elements.firstIndex(where: { $0.id == selectedID }) else {
      return
    }
    let point = physical(event)
    let step = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
    if creating {
      artwork.elements[i].x = min(point.x, down.x).rounded()
      artwork.elements[i].y = min(point.y, down.y).rounded()
      artwork.elements[i].width = max(1, abs(point.x - down.x).rounded())
      artwork.elements[i].height = max(1, abs(point.y - down.y).rounded())
    } else {
      artwork.elements[i].x = ((elementOrigin.x + point.x - down.x) / step).rounded() * step
      artwork.elements[i].y = ((elementOrigin.y + point.y - down.y) / step).rounded() * step
    }
    onChange?(artwork)
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117 {
      artwork.elements.removeAll { $0.id == selectedID }
      selectedID = nil
      onSelection?(nil)
      onChange?(artwork)
      needsDisplay = true
    } else if event.keyCode == 53 {
      selectedID = nil
      onSelection?(nil)
      needsDisplay = true
    } else {
      super.keyDown(with: event)
    }
  }
}
