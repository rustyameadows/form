import AppKit
import FormCore
import FormGeometry
import SwiftUI

struct PrintWorkspace: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @ObservedObject var printing: PrintCoordinator
  var onClose: (() -> Void)? = nil
  @State private var settings = false
  private func setting<Value>(_ path: WritableKeyPath<PrintConfiguration, Value>) -> Binding<Value>
  {
    Binding(
      get: { printing.configuration[keyPath: path] },
      set: { value in printing.updateConfiguration { $0[keyPath: path] = value } })
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "printer").font(.system(size: 22, weight: .light)).foregroundStyle(
          Palette.accent)
        VStack(alignment: .leading, spacing: 4) {
          Text("Print preparation").font(.system(size: 23, weight: .regular, design: .default))
          Text("A physical object, ready for its next form.").font(.system(size: 11))
            .foregroundStyle(Palette.secondary)
        }
        Spacer()
        Text("LOCAL PREPARATION").font(.system(size: 8, weight: .semibold, design: .monospaced))
          .tracking(1).foregroundStyle(Palette.secondary).padding(8).background(
            .black.opacity(0.035), in: Capsule())
        Button {
          settings = true
        } label: {
          Image(systemName: "slider.horizontal.3")
        }.buttonStyle(.plain).help("Filaments, printers & slicing engine")
        Button("Done") { close() }.keyboardShortcut(.cancelAction)
      }.padding(.horizontal, 25).frame(height: 76)
      Divider()
      HStack(spacing: 0) {
        ZStack(alignment: .topLeading) {
          PrintBedCanvas(printing: printing)
          VStack(alignment: .leading, spacing: 9) {
            Text(printing.printer.model.uppercased()).font(.system(size: 9, weight: .semibold))
              .tracking(1.3)
            Text(
              "\(Int(printing.printer.bedWidth)) × \(Int(printing.printer.bedDepth)) × \(Int(printing.printer.buildHeight)) mm"
            ).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
          }.padding(24)
          VStack {
            Spacer()
            HStack {
              VStack(alignment: .leading, spacing: 8) {
                if let path = printing.toolpath {
                  Toggle("Toolpath preview", isOn: $printing.showToolpath).toggleStyle(.switch)
                    .controlSize(.mini).font(.system(size: 11))
                  if printing.showToolpath {
                    HStack {
                      Text("Layer \(printing.layer+1) / \(path.layers.count)")
                      Spacer()
                      Text(
                        String(
                          format: "Z %.2f mm",
                          path.layers[min(printing.layer, max(0, path.layers.count - 1))]))
                    }.font(.system(size: 10, design: .monospaced))
                    Slider(
                      value: Binding(
                        get: { Double(printing.layer) }, set: { printing.layer = Int($0.rounded()) }
                      ), in: 0...Double(max(1, path.layers.count - 1))
                    ).tint(Palette.accent)
                  }
                } else {
                  Label(
                    "Drag to orbit · Shift-drag to pan · Scroll to zoom",
                    systemImage: "cube.transparent"
                  ).font(
                    .system(size: 10)
                  ).foregroundStyle(Palette.secondary)
                }
              }.padding(14).frame(width: 300).background(
                Palette.paper, in: RoundedRectangle(cornerRadius: 12))
              Spacer()
              HStack(spacing: 5) {
                IconButton("Fit print bed", symbol: "square.dashed") { printing.frame("bed") }
                IconButton("Focus object", symbol: "viewfinder") { printing.frame("object") }
              }.padding(6).background(Palette.paper, in: RoundedRectangle(cornerRadius: 11))
            }.padding(20)
          }
        }
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            SectionLabel("OBJECT & COMPONENT")
            Picker(
              "Object",
              selection: Binding(
                get: { printing.objectID }, set: { if let id = $0 { printing.chooseObject(id) } })
            ) {
              Text("Choose an object").tag(Optional<UUID>.none)
              ForEach(store.project?.objects ?? []) { object in
                Text(object.name).tag(Optional(object.id))
              }
            }.labelsHidden().frame(maxWidth: .infinity)
            if printing.components.count > 1 {
              Picker("Component", selection: setting(\.component)) {
                ForEach(printing.components, id: \.self) { Text($0) }
              }.font(.system(size: 11))
            }
            if let mesh = printing.mesh {
              Text(String(format: "%.1f × %.1f × %.1f mm", mesh.size.x, mesh.size.y, mesh.size.z))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
            Divider()
            SectionLabel("PRINTER & FILAMENT")
            Picker(
              "Printer",
              selection: setting(\.printerID)
            ) { ForEach(store.library.printers) { Text($0.name).tag(Optional($0.id)) } }
            .labelsHidden()
            HStack {
              Circle().fill(Color(nsColor: NSColor(hex: printing.filament.color))).frame(
                width: 15, height: 15)
              Picker(
                "Filament",
                selection: setting(\.filamentID)
              ) { ForEach(store.library.filaments) { Text($0.name).tag(Optional($0.id)) } }
              .labelsHidden()
            }
            Text(
              "\(printing.filament.polymer)  ·  \(Int(printing.filament.nozzleTemperature)) °C nozzle  ·  \(Int(printing.filament.bedTemperature)) °C bed"
            ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            Button("Manage filaments & printers…") { settings = true }.buttonStyle(.plain).font(
              .system(size: 11)
            ).foregroundStyle(Palette.accent)
            Divider()
            SectionLabel("SLICE SETTINGS")
            PrintNumber(
              "Layer height", value: setting(\.layerHeight), unit: "mm",
              range: 0.04...(printing.printer.nozzleDiameter * 0.8))
            PrintNumber(
              "Infill", value: setting(\.infillPercent), unit: "%", range: 0...100)
            Stepper(
              "Walls: \(printing.configuration.wallLoops)",
              value: setting(\.wallLoops), in: 1...12
            ).font(.system(size: 11))
            Toggle("Generate supports", isOn: setting(\.supports)).font(
              .system(size: 11)
            ).toggleStyle(.switch).controlSize(.mini)
            PrintNumber(
              "Brim width", value: setting(\.brimWidth), unit: "mm", range: 0...30)
            Divider()
            SectionLabel("ORIENTATION & SCALE")
            PrintNumber(
              "Scale", value: setting(\.scalePercent), unit: "%", range: 1...1000)
            HStack(spacing: 7) {
              ForEach(["X", "Y", "Z"], id: \.self) { axis in
                Button("\(axis) +90°") {
                  printing.updateConfiguration {
                    if axis == "X" { $0.rotation.x += 90 }
                    if axis == "Y" { $0.rotation.y += 90 }
                    if axis == "Z" { $0.rotation.z += 90 }
                  }
                }.font(.system(size: 10))
              }
            }
            Button("Reset orientation") {
              printing.updateConfiguration {
                $0.rotation = .init()
                $0.scalePercent = 100
              }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            if let error = printing.validationError {
              Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11))
                .foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                .padding(11).background(
                  Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if let path = printing.toolpath {
              Divider()
              SectionLabel("SLICE RESULT")
              Text(path.estimatedTime.isEmpty ? "\(path.layers.count) layers" : path.estimatedTime)
                .font(.system(size: 17, weight: .medium, design: .default))
              Text(
                "\(path.filamentGrams.isEmpty ? "—" : path.filamentGrams) g filament  ·  \(path.layers.count) layers"
              ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
              if path.truncated {
                Text("Preview detail is capped; the exported toolpath is complete.").font(
                  .system(size: 9)
                ).foregroundStyle(Palette.secondary)
              }
            }
          }.padding(22).disabled(printing.busy)
        }.frame(width: 308).background(Palette.paper)
      }
      Divider()
      HStack(spacing: 13) {
        if printing.busy {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: printing.toolpath == nil ? "circle.dotted" : "checkmark.circle")
            .foregroundStyle(Palette.accent)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(printing.status).font(.system(size: 11, weight: .medium))
          Text("Files stay on this Mac. Sending and starting prints are disabled.").font(
            .system(size: 10)
          ).foregroundStyle(Palette.secondary)
        }
        Spacer()
        Button("Export STL…") { printing.exportSTL() }.disabled(
          printing.mesh == nil || printing.busy)
        if printing.outputDirectory != nil && !printing.busy {
          Button("Show slice files") { printing.revealFiles() }
        }
        if printing.busy {
          Button("Cancel") { printing.cancel() }
        } else {
          Button {
            do { try printing.slice() } catch { store.error = error.localizedDescription }
          } label: {
            Label(
              printing.toolpath == nil ? "Slice & preview" : "Slice again",
              systemImage: "square.3.layers.3d"
            ).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(
              .vertical, 10
            ).background(Palette.ink, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
          }.buttonStyle(.plain).disabled(!printing.canSlice)
        }
      }.padding(.horizontal, 22).frame(height: 70)
    }.frame(minWidth: 980, minHeight: 640).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper)
      .sheet(isPresented: $settings) {
        PrintingSettingsView(printing: printing).environmentObject(store)
      }
      .onChange(of: store.library) { _, _ in printing.reconcile() }
      .onExitCommand { close() }
  }
  private func close() { if let onClose { onClose() } else { dismiss() } }
}

struct PrintNumber: View {
  let title: String
  @Binding var value: Double
  let unit: String
  let range: ClosedRange<Double>
  init(_ title: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>) {
    self.title = title
    _value = value
    self.unit = unit
    self.range = range
  }
  var body: some View {
    HStack {
      Text(title)
      Spacer()
      TextField(
        title,
        value: Binding(
          get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
        format: .number.precision(.fractionLength(0...2))
      ).font(Palette.numericFont).multilineTextAlignment(.trailing).frame(width: 65).textFieldStyle(.roundedBorder)
        .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
      Text(unit).foregroundStyle(Palette.secondary).fixedSize().frame(
        minWidth: 21, alignment: .leading)
    }.font(.system(size: 11))
  }
}

struct PrintBedCanvas: NSViewRepresentable {
  @ObservedObject var printing: PrintCoordinator
  func makeCoordinator() -> BedRenderer {
    BedRenderer()
  }
  func makeNSView(context: Context) -> TableSceneView {
    let view = TableSceneView(frame: .zero)
    view.onEscape = { [weak printing] in printing?.store?.showingPrint = false }
    view.controller = context.coordinator.controller
    context.coordinator.controller.view = view
    view.setAccessibilityLabel("Print bed preview, object and sliced layers")
    return view
  }
  func updateNSView(_ view: TableSceneView, context: Context) {
    context.coordinator.update(printing)
    view.needsDisplay = true
  }
}

@MainActor final class BedRenderer {
  let controller = TableSceneController()
  private let content = MeshNode(), pathRoot = MeshNode(), plateRoot = MeshNode()
  private var lastMesh = -1, lastPath = -1
  private var lastBed = ""
  private var lastCamera = -1
  private var layers: [MeshNode] = []
  init() {
    controller.scene.rootNode.addChildNode(content)
    controller.scene.rootNode.addChildNode(pathRoot)
    controller.scene.rootNode.addChildNode(plateRoot)
    controller.camera.distance = 6.8
    controller.camera.elevation = 0.78
    controller.camera.azimuth = 0.6
    controller.camera.target.y = 0.25
    controller.updateCamera()
  }
  private func point(_ p: Vector3, _ printer: PrinterProfile) -> MeshVector3 {
    .init((p.x - printer.bedWidth / 2) / 100, p.z / 100, -(p.y - printer.bedDepth / 2) / 100)
  }
  func update(_ printing: PrintCoordinator) {
    let printer = printing.printer
    let key = "\(printer.bedWidth)-\(printer.bedDepth)"
    if key != lastBed {
      plateRoot.childNodes.forEach { $0.removeFromParentNode() }
      lastBed = key
      let material = MeshMaterial()
      material.lightingModel = .physicallyBased
      material.diffuse.contents = NSColor(hex: "#666666")
      material.roughness.contents = 0.8
      let bed = MeshNode(
        geometry: MeshBox(
          width: printer.bedWidth / 100, height: 0.045, length: printer.bedDepth / 100,
          chamferRadius: 0.035))
      bed.geometry?.materials = [material]
      bed.position.y = -0.028
      plateRoot.addChildNode(bed)
      var points: [MeshVector3] = []
      for i in stride(from: 0.0, through: printer.bedWidth, by: 10) {
        points += [
          point(.init(i, 0, 0.1), printer), point(.init(i, printer.bedDepth, 0.1), printer),
        ]
      }
      for i in stride(from: 0.0, through: printer.bedDepth, by: 10) {
        points += [
          point(.init(0, i, 0.1), printer), point(.init(printer.bedWidth, i, 0.1), printer),
        ]
      }
      let grid = MeshGeometry(
        sources: [MeshGeometrySource(vertices: points)],
        elements: [
          MeshGeometryElement(indices: Array(0..<Int32(points.count)), primitiveType: .line)
        ])
      let line = MeshMaterial()
      line.lightingModel = .constant
      line.diffuse.contents = NSColor.white.withAlphaComponent(0.16)
      grid.materials = [line]
      plateRoot.addChildNode(MeshNode(geometry: grid))
      let exclusion = MeshNode(geometry: MeshPlane(width: 0.18, height: 0.28))
      exclusion.eulerAngles.x = -.pi / 2
      exclusion.position = point(.init(9, 14, 0.3), printer)
      let warning = MeshMaterial()
      warning.lightingModel = .constant
      warning.diffuse.contents = NSColor(hex: "#111111").withAlphaComponent(0.6)
      exclusion.geometry?.materials = [warning]
      plateRoot.addChildNode(exclusion)
    }
    if printing.meshVersion != lastMesh {
      lastMesh = printing.meshVersion
      content.childNodes.forEach { $0.removeFromParentNode() }
      if let mesh = printing.mesh {
        let vertices = mesh.triangles.flatMap {
          [point($0.a, printer), point($0.b, printer), point($0.c, printer)]
        }
        let geo = MeshGeometry(
          sources: [MeshGeometrySource(vertices: vertices)],
          elements: [
            MeshGeometryElement(indices: Array(0..<Int32(vertices.count)), primitiveType: .triangles)
          ])
        let material = MeshMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(hex: printing.filament.color)
        material.roughness.contents = 0.6
        material.isDoubleSided = true
        geo.materials = [material]
        content.addChildNode(MeshNode(geometry: geo))
      }
    }
    if printing.toolpathVersion != lastPath {
      lastPath = printing.toolpathVersion
      pathRoot.childNodes.forEach { $0.removeFromParentNode() }
      layers = []
      if let path = printing.toolpath {
        var grouped = [[MeshVector3]](repeating: [], count: path.layers.count)
        for segment in path.segments where segment.layer < grouped.count {
          grouped[segment.layer] += [point(segment.from, printer), point(segment.to, printer)]
        }
        let material = MeshMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(hex: printing.filament.color)
        for points in grouped {
          let geo = MeshGeometry(
            sources: [MeshGeometrySource(vertices: points)],
            elements: [
              MeshGeometryElement(indices: Array(0..<Int32(points.count)), primitiveType: .line)
            ])
          geo.materials = [material]
          let node = MeshNode(geometry: geo)
          pathRoot.addChildNode(node)
          layers.append(node)
        }
      }
    }
    content.isHidden = printing.showToolpath && printing.toolpath != nil
    pathRoot.isHidden = !printing.showToolpath
    for (index, node) in layers.enumerated() {
      node.isHidden = index > printing.layer
      node.opacity = index == printing.layer ? 1 : 0.5
    }
    if lastCamera != printing.cameraRevision {
      lastCamera = printing.cameraRevision
      if printing.cameraRequest == "object", let mesh = printing.mesh {
        let size = mesh.size
        controller.camera.target = .init(0, size.z / 200, 0)
        controller.camera.distance = max(1.2, max(size.x, size.y, size.z) / 100 * 2.8)
      } else {
        controller.camera.target = .init(0, 0.25, 0)
        controller.camera.distance = 6.8
      }
      controller.updateCamera(animated: true)
    }
    controller.renderScene()
  }
}
