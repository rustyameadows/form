import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Project designs reference project artwork; physical stock remains a Studio Library resource.
struct FabricPatternEditor: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  let material: FormCore.Material
  var onEditSource: ((UUID) -> Void)?
  @State private var draft: FabricPattern
  @State private var sourceID: UUID?
  @State private var error = ""
  @State private var dpi = 150.0
  init(material: FormCore.Material, project: Project?, onEditSource: ((UUID) -> Void)? = nil) {
    self.material = material
    self.onEditSource = onEditSource
    let saved = project?.material(material.id).fabric?.pattern
    let source = saved?.sourceObjectID ?? project?.objects.first { $0.recipeID == "artboard" && !$0.isCanvasWorkspace && $0.artworkSourceID == nil && $0.artwork != nil }?.id
    var pattern = saved ?? FabricPattern(sourceObjectID: source ?? UUID())
    if saved == nil { pattern.outputWidth = material.fabric?.usableWidth.flatMap { $0 > 0 ? $0 : nil } ?? 1400 }
    _draft = State(initialValue: pattern); _sourceID = State(initialValue: source)
  }
  private var sources: [ProductObject] {
    store.project?.objects.filter { $0.recipeID == "artboard" && !$0.isCanvasWorkspace && $0.artworkSourceID == nil && $0.artwork != nil } ?? []
  }
  private var design: ResolvedFabricPattern? {
    guard var project = store.project, let sourceID else { return nil }
    var value = draft; value.sourceObjectID = sourceID
    guard (try? project.setFabricPattern(value, materialID: material.id)) != nil else { return nil }
    return try? project.resolvedFabricPattern(materialID: material.id)
  }
  private var assets: URL {
    guard let project = store.project else { return store.repository.root }
    return store.repository.url(for: project.id).appendingPathComponent("Assets")
  }
  private var colorwayIndex: Int? { draft.colorways.firstIndex { $0.id == draft.activeColorwayID } }
  private var sourceColors: [String] {
    guard let project = store.project, let sourceID, let source = project.objects.first(where: { $0.id == sourceID }),
      let stored = source.artwork, let art = try? project.resolvingComponents(in: stored) else { return [] }
    var colors = Set<String>()
    for element in art.elements {
      colors.insert(element.color.uppercased())
      if let stroke = element.stroke { colors.insert(stroke.color.uppercased()) }
      for stop in element.gradient?.stops ?? [] { colors.insert(stop.color.uppercased()) }
      for run in element.textRuns ?? [] { colors.insert(run.color.uppercased()) }
    }
    return Array(colors.sorted().prefix(64))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Fabric repeat").font(.system(size: 25, design: .serif))
          Text("\(material.name) · design saved in this project").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack(alignment: .top, spacing: 22) {
        VStack(alignment: .leading, spacing: 12) {
          if let design {
            FabricPatternPreview(design: design, assets: assets, fontRevision: GeometryFactory.fontRevision)
              .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 9))
            HStack {
              Text(String(format: "%.0f × %.0f mm yardage", draft.outputWidth, draft.outputLength))
              Spacer(); Text(String(format: "Repeat %.1f × %.1f mm", design.supertileSize.x, design.supertileSize.y))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
          } else {
            ContentUnavailableView("Choose an artwork tile", systemImage: "square.grid.3x3", description: Text("Use an editable frame, or create a motif tile below."))
              .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 9))
          }
          Text("Physical repeat on the bomber fabric and in exported yardage. The source tile stays editable; patch and label artwork stays independent.")
            .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Create motif tile") { createTile() }
            Button("Edit source tile") { editSource() }.disabled(sourceID == nil)
            Spacer()
          }
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Group {
              Text("REPEAT DESIGN").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
              Picker("Artwork tile", selection: $sourceID) {
                Text("Choose frame").tag(Optional<UUID>.none)
                ForEach(sources) { source in Text(source.name).tag(Optional(source.id)) }
              }
              Picker("Repeat", selection: $draft.repeatMode) { ForEach(FabricPattern.Repeat.allCases, id: \.self) { Text($0.name).tag($0) } }
              number("Motif scale", value: $draft.scale, suffix: "×")
              pair("Spacing", x: $draft.spacing.x, y: $draft.spacing.y)
              number("Rotation", value: $draft.rotation, suffix: "°")
              pair("Offset", x: $draft.offset.x, y: $draft.offset.y)
              Toggle("Include tile background", isOn: $draft.includeTileBackground).font(.system(size: 11))
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Text("COLORWAYS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
                Spacer(); Button { addColorway() } label: { Image(systemName: "plus") }.help("Add an independent fabric colorway")
              }
              Picker("Active", selection: $draft.activeColorwayID) {
                Text("Source colors").tag(Optional<UUID>.none)
                ForEach(draft.colorways) { Text($0.name).tag(Optional($0.id)) }
              }
              if let i = colorwayIndex {
                TextField("Colorway name", text: $draft.colorways[i].name).textFieldStyle(.roundedBorder)
                ColorPicker("Fabric base", selection: Binding(get: { Color(nsColor: NSColor(hex: draft.colorways[i].baseColor ?? material.color)) },
                  set: { draft.colorways[i].baseColor = NSColor($0).hexString }), supportsOpacity: false)
                ForEach(sourceColors, id: \.self) { color in
                  ColorPicker(color, selection: Binding(get: { Color(nsColor: NSColor(hex: draft.colorways[i].replacements[color] ?? color)) },
                    set: { draft.colorways[i].replacements[color] = NSColor($0).hexString }), supportsOpacity: false)
                    .font(.system(size: 10, design: .monospaced))
                }
                HStack {
                  Button("Reset paints") { draft.colorways[i].replacements = [:] }
                  Spacer(); Button("Delete") { draft.colorways.remove(at: i); draft.activeColorwayID = nil }
                }.font(.system(size: 10))
              } else {
                Text("Add a colorway to recolor vector fills, strokes, gradients, and type without changing the source. Embedded image colors stay intact.")
                  .font(.system(size: 10)).foregroundStyle(Palette.secondary)
              }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
              Text("YARDAGE OUTPUT").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
              number("Width", value: $draft.outputWidth, suffix: "mm")
              number("Length", value: $draft.outputLength, suffix: "mm")
              number("Raster / effect DPI", value: $dpi, suffix: "DPI")
              HStack { ForEach(["svg", "pdf", "png"], id: \.self) { format in
                Button(format.uppercased()) { export(format) }.disabled(design == nil)
              } }
              Text("Export applies this design first. SVG and PDF retain vector motifs; PNG renders at the requested physical DPI.")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
          }.padding(.trailing, 8)
        }.frame(width: 310)
      }
      if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      HStack {
        Button("Remove pattern") { remove() }.disabled(store.project?.material(material.id).fabric?.pattern == nil)
        Spacer(); Button("Apply fabric design") { _ = apply() }.keyboardShortcut(.defaultAction).disabled(design == nil)
      }
    }.padding(26).frame(width: 1040, height: 735).background(Palette.paper)
  }
  private func number(_ label: String, value: Binding<Double>, suffix: String) -> some View {
    HStack { Text(label).font(.system(size: 11)); Spacer(); TextField(label, value: value, format: .number.precision(.fractionLength(0...3)))
      .labelsHidden().multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 92)
      Text(suffix).font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 25, alignment: .leading) }
  }
  private func pair(_ label: String, x: Binding<Double>, y: Binding<Double>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label + " (mm)").font(.system(size: 11))
      HStack { Text("X"); TextField("X", value: x, format: .number); Text("Y"); TextField("Y", value: y, format: .number) }
        .font(.system(size: 10)).textFieldStyle(.roundedBorder)
    }
  }
  private func addColorway() {
    let colorway = FabricColorway(name: "Colorway \(draft.colorways.count + 1)", baseColor: material.color)
    draft.colorways.append(colorway); draft.activeColorwayID = colorway.id
  }
  @discardableResult private func apply() -> Bool {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let sourceID else { throw FormError.invalid("Choose a source artwork frame first.") }
      var next = draft; next.sourceObjectID = sourceID
      try store.engine.edit("Edited fabric repeat", source: "Studio") { try $0.setFabricPattern(next, materialID: material.id) }
      store.revision += 1; error = ""; store.toast("Fabric design applied"); return true
    } catch { self.error = error.localizedDescription; return false }
  }
  private func remove() {
    do { try store.engine.edit("Removed fabric repeat", source: "Studio") { try $0.setFabricPattern(nil, materialID: material.id) }; store.revision += 1; dismiss() }
    catch { self.error = error.localizedDescription }
  }
  private func createTile() {
    do {
      var created: UUID?
      try store.engine.edit("Created fabric motif tile", source: "Studio") { project in
        var frame = try project.makeObject(recipeID: "artboard", name: "Fabric motif tile", parameters: ["width": 40, "depth": 40])
        var art = Artwork(background: "#F4E9D0", bleed: 0)
        art.backgroundOpacity = 0; art.canvasPosition = .init(-80, -80)
        art.elements = [ArtworkElement(kind: "star", x: 12, y: 9, width: 16, height: 16, color: "#D78045"),
          ArtworkElement(kind: "ellipse", x: 6, y: 29, width: 3, height: 3, color: "#E6D6B4"),
          ArtworkElement(kind: "ellipse", x: 30, y: 4, width: 3, height: 3, color: "#E6D6B4")]
        frame.artwork = art; created = frame.id; project.objects.append(frame)
      }
      sourceID = created; store.revision += 1; error = ""
    } catch { self.error = error.localizedDescription }
  }
  private func editSource() {
    guard let sourceID, apply() else { return }
    dismiss()
    if let onEditSource { onEditSource(sourceID) }
    else {
      store.showSurface(.artwork); store.artworkSession.activate(sourceID)
      DispatchQueue.main.async { store.artworkSession.canvas?.fit(all: false) }
    }
  }
  private func export(_ format: String) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = material.name + "-yardage." + format
    panel.allowedContentTypes = [format == "svg" ? .svg : format == "pdf" ? .pdf : .png]
    guard panel.runModal() == .OK, let url = panel.url, apply() else { return }
    do { _ = try store.exportFabricPattern(materialID: material.id, arguments: ["format": format, "path": url.path, "dpi": dpi]); error = ""; store.toast("Fabric yardage exported") }
    catch { self.error = error.localizedDescription }
  }
}

private struct FabricPatternPreview: NSViewRepresentable {
  var design: ResolvedFabricPattern
  var assets: URL
  var fontRevision: Int
  func makeNSView(context: Context) -> FabricPreviewNSView { FabricPreviewNSView() }
  func updateNSView(_ view: FabricPreviewNSView, context: Context) { view.design = design; view.assets = assets; view.fontRevision = fontRevision; view.needsDisplay = true }
}
private final class FabricPreviewNSView: NSView {
  var design: ResolvedFabricPattern?
  var assets = URL(fileURLWithPath: "/")
  var fontRevision = 0
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    guard let design, let context = NSGraphicsContext.current?.cgContext else { return }
    NSColor(hex: "#E4E3DE").setFill(); bounds.fill()
    let width = design.pattern.outputWidth, height = design.pattern.outputLength
    let scale = min((bounds.width - 44) / width, (bounds.height - 44) / height)
    guard scale > 0 else { return }
    let rect = CGRect(x: (bounds.width - width * scale) / 2, y: (bounds.height - height * scale) / 2, width: width * scale, height: height * scale)
    context.saveGState(); context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: scale, y: scale)
    FabricPatternRenderer.drawPreview(design, assets: assets, width: width, height: height, fontRevision: fontRevision)
    context.restoreGState()
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.15).cgColor); context.stroke(rect)
    let length = min(100, width / 4), bar = length * scale, y = min(bounds.height - 10, rect.maxY + 13)
    context.setStrokeColor(NSColor(hex: "#5B625D").cgColor); context.setLineWidth(1)
    context.move(to: .init(x: rect.minX, y: y)); context.addLine(to: .init(x: rect.minX + bar, y: y)); context.strokePath()
    (String(format: "%.0f mm", length) as NSString).draw(at: .init(x: rect.minX + bar + 6, y: y - 6), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
  }
}

extension StudioStore {
  func exportFabricPattern(materialID: String, arguments: [String: Any]) throws -> Any {
    guard arguments["roles"] == nil else {
      throw FormError.invalid("Export fabric yardage and manufacturing role layers separately.")
    }
    guard let project, let design = try project.resolvedFabricPattern(materialID: materialID) else { throw FormError.missing("Choose a fabric with a repeat pattern in this project.") }
    let format = arguments["format"] as? String ?? "svg"
    let dpi: Double
    if let raw = arguments["dpi"] {
      guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw FormError.invalid("Fabric export DPI must be a number.")
      }
      dpi = number.doubleValue
    } else { dpi = 150 }
    guard dpi.isFinite, (36...1200).contains(dpi) else { throw FormError.invalid("Choose 36–1200 DPI for fabric raster output and PDF effects.") }
    let width = design.pattern.outputWidth, height = design.pattern.outputLength
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    let url: URL
    if let path = arguments["path"] as? String {
      guard path.hasPrefix("/") else { throw FormError.invalid("Export path must be absolute.") }; url = URL(fileURLWithPath: path)
    } else {
      let folder = repository.url(for: project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      url = folder.appendingPathComponent(project.material(materialID).name.replacingOccurrences(of: "/", with: "-") + "-yardage." + format)
    }
    let data: Data
    switch format {
    case "svg": data = Data(try FabricPatternRenderer.svg(design, assets: assets, width: width, height: height).utf8)
    case "pdf": data = try FabricPatternRenderer.pdf(design, assets: assets, width: width, height: height, dpi: dpi)
    case "png", "jpeg":
      let image = try FabricPatternRenderer.image(design, assets: assets, width: width, height: height, pixelsPerMM: dpi / 25.4)
      guard let bitmap = image.representations.first as? NSBitmapImageRep else { throw FormError.invalid("Could not render fabric yardage.") }
      bitmap.size = .init(width: width * TypographyEngine.pointsPerMM, height: height * TypographyEngine.pointsPerMM)
      guard let output = bitmap.representation(using: format == "jpeg" ? .jpeg : .png, properties: [.compressionFactor: 0.94]) else { throw FormError.invalid("Could not encode fabric yardage.") }; data = output
    default: throw FormError.invalid("Fabric output format must be svg, pdf, png, or jpeg.")
    }
    try data.write(to: url, options: .atomic)
    return ["path": url.path, "format": format, "width_mm": width, "height_mm": height, "dpi": dpi, "bytes": data.count,
      "fabric_pattern_material": materialID, "source_object_id": design.pattern.sourceObjectID.uuidString,
      "repeat_width_mm": design.supertileSize.x, "repeat_height_mm": design.supertileSize.y] as [String: Any]
  }
}
