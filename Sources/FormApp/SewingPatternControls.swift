import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

struct SewingPatternControls: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  @State private var expanded = false
  private var geometry: SewingPieceGeometry? { try? SewingPatterns.geometry(element, in: session.art) }
  var body: some View {
    if ["rectangle", "polygon", "path"].contains(element.kind), session.elements.count == 1 {
      DisclosureGroup("Sewing pattern piece", isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 11) {
          if let piece = element.sewingPiece, let geometry {
            TextField("Piece name", text: Binding(get: { piece.name }, set: { value in session.update { $0.sewingPiece?.name = value } }))
              .font(.system(size: 12, design: .serif)).textFieldStyle(.roundedBorder)
            ArtworkUnitField("Seam allowance", value: piece.seamAllowance, unit: session.unit) { value in session.update { $0.sewingPiece?.seamAllowance = value } }
            Stepper("Cut \(piece.cutQuantity)", value: Binding(get: { piece.cutQuantity }, set: { value in session.update { $0.sewingPiece?.cutQuantity = value } }), in: 1...100).font(.system(size: 11))
            ScalarArtworkField("Grain angle", value: piece.grainAngle, unit: "°") { value in session.update { $0.sewingPiece?.grainAngle = value } }
            Picker("Fabric", selection: Binding(get: { piece.materialID ?? "" }, set: { value in session.update { $0.sewingPiece?.materialID = value.isEmpty ? nil : value } })) {
              Text("Unspecified").tag("")
              ForEach(store.materials.filter { $0.fabric != nil }) { Text($0.name).tag($0.id) }
            }.font(.system(size: 10))
            Picker("Cut on fold", selection: Binding(get: { piece.onFoldEdge ?? -1 }, set: { value in session.update { $0.sewingPiece?.onFoldEdge = value < 0 ? nil : value } })) {
              Text("None").tag(-1)
              ForEach(geometry.stitch.indices, id: \.self) { Text("Edge \($0 + 1)").tag($0) }
            }.font(.system(size: 10))
            ForEach(geometry.stitch.indices, id: \.self) { index in edge(index, geometry: geometry) }
            TextField("Construction notes", text: Binding(get: { piece.notes ?? "" }, set: { value in session.update { $0.sewingPiece?.notes = value } }), axis: .vertical)
              .font(.system(size: 10)).textFieldStyle(.roundedBorder).lineLimit(2...5)
            Button("Remove piece annotation") { session.execute("pattern_piece", ["piece": NSNull()]) }.font(.system(size: 10))
          } else {
            Text("The selected shape becomes the finished stitch outline. Allowances are generated outside it in physical millimeters.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            Button("Use as pattern piece") { session.execute("pattern_piece", ["piece": ["name": element.name ?? "Pattern piece"]]) }
            Text(SewingPatterns.supportedShapes).font(.system(size: 9)).foregroundStyle(Palette.secondary)
          }
        }.padding(.top, 8)
      }.font(.system(size: 11, weight: .medium)).onAppear { expanded = element.sewingPiece != nil }
        .onChange(of: element.id) { _, _ in expanded = element.sewingPiece != nil }
    }
  }
  @ViewBuilder private func edge(_ index: Int, geometry: SewingPieceGeometry) -> some View {
    let piece = geometry.piece, length = geometry.edgeLengths[index]
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("EDGE \(index + 1)").font(.system(size: 8, weight: .semibold)).tracking(1)
        Spacer(); Text(String(format: "%.1f %@", session.unit.display(length), session.unit.rawValue)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary)
      }
      if piece.onFoldEdge == index {
        Text("Place this edge on the fabric fold; no cut pass.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
      } else {
        ArtworkUnitField("Allowance", value: piece.allowance(for: index), unit: session.unit) { value in session.update { $0.sewingPiece?.edgeAllowances[index] = value } }
        if piece.edgeAllowances[index] != nil {
          Button("Use default allowance") { session.update { $0.sewingPiece?.edgeAllowances.removeValue(forKey: index) } }.font(.system(size: 9))
        }
        if !piece.notches.contains(where: { $0.edge == index }) {
          Button("Add midpoint notch") {
            var notch = SewingNotch(edge: index, position: 0.5); notch.depth = min(3, piece.allowance(for: index) / 2)
            session.update { $0.sewingPiece?.notches.append(notch) }
          }.font(.system(size: 9)).disabled(length < 8 || piece.allowance(for: index) < 1.1)
        }
      }
      ForEach(piece.notches.filter { $0.edge == index }) { notch in
        VStack(alignment: .leading, spacing: 5) {
          HStack {
            ScalarArtworkField("Notch position", value: notch.position * 100, unit: "%") { value in editNotch(notch.id) { $0.position = value / 100 } }
            Button { session.update { $0.sewingPiece?.notches.removeAll { $0.id == notch.id } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
          }
          ArtworkUnitField("Notch width", value: notch.width, unit: session.unit) { value in editNotch(notch.id) { $0.width = value } }
          ArtworkUnitField("Notch depth", value: notch.depth, unit: session.unit) { value in editNotch(notch.id) { $0.depth = value } }
        }
      }
    }.padding(8).background(Palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
  }
  private func editNotch(_ id: UUID, _ change: @escaping (inout SewingNotch) -> Void) {
    session.update { element in
      guard let index = element.sewingPiece?.notches.firstIndex(where: { $0.id == id }) else { return }
      change(&element.sewingPiece!.notches[index])
    }
  }
}

struct SewingPatternActions: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  @State private var preview = false
  @State private var pairing = false
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if session.art.elements.contains(where: { $0.sewingPiece != nil }) {
        Divider(); SectionLabel("SEWING PATTERN")
        Button("Preview cutting pattern") { preview = true }
        Button("Pair seam edges") { pairing = true }
        if let checks = try? SewingPatterns.diagnostics(session.art) {
          ForEach(checks, id: \.seam.id) { check in
            HStack(alignment: .top) {
              Image(systemName: check.matches ? "checkmark.circle" : "exclamationmark.circle")
              Text(check.seam.name + (check.matches ? " · matched" : String(format: " · %.1f mm mismatch", check.difference)))
              Spacer(); Button { session.execute("seam_pair", ["seam": NSNull(), "seam_id": check.seam.id.uuidString]) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }.font(.system(size: 9)).foregroundStyle(check.matches ? Palette.secondary : Palette.accent)
          }
        }
      }
      Button("Add tote cutting study") { store.createTotePattern() }.font(.system(size: 10))
    }.font(.system(size: 10)).sheet(isPresented: $preview) { SewingPatternPreview(session: session).environmentObject(store) }
      .sheet(isPresented: $pairing) { SewingSeamEditor(session: session).environmentObject(store) }
  }
}

private struct SewingSeamEditor: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @ObservedObject var session: ArtworkSession
  @State private var first: UUID?
  @State private var second: UUID?
  @State private var firstEdge = 0
  @State private var secondEdge = 0
  @State private var firstCopy = 1
  @State private var secondCopy = 1
  @State private var name = "Seam"
  @State private var tolerance = 1.0
  @State private var reversed = true
  @State private var error = ""
  private var pieces: [ArtworkElement] { session.art.elements.filter { $0.sewingPiece != nil } }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Pair seam edges").font(.system(size: 24, design: .serif))
      TextField("Seam name", text: $name).textFieldStyle(.roundedBorder)
      endpoint("First edge", selected: $first, edge: $firstEdge, copy: $firstCopy)
      endpoint("Second edge", selected: $second, edge: $secondEdge, copy: $secondCopy, isSecond: true)
      Toggle("Reverse edge direction when matching", isOn: $reversed)
      HStack { Text("Length tolerance (mm)"); TextField("Tolerance", value: $tolerance, format: .number).textFieldStyle(.roundedBorder).frame(width: 85) }
      Text("Copy numbers refer to the piece's cut quantity. A mismatch stays visible in the pattern check and exported instructions; pairing does not simulate sewing or stretch.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
      if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
      HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save seam") { save() }.keyboardShortcut(.defaultAction) }
    }.padding(28).frame(width: 540).background(Palette.paper).onAppear {
      first = pieces.first?.id; second = pieces.dropFirst().first?.id ?? first
      if first == second, (pieces.first?.sewingPiece?.cutQuantity ?? 1) > 1 { secondCopy = 2 }
    }
  }
  @ViewBuilder private func endpoint(_ title: String, selected: Binding<UUID?>, edge: Binding<Int>, copy: Binding<Int>, isSecond: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 11, weight: .semibold))
      Picker("Piece", selection: selected) { ForEach(pieces) { Text($0.sewingPiece!.name).tag(Optional($0.id)) } }
      if let e = pieces.first(where: { $0.id == selected.wrappedValue }), let geometry = try? SewingPatterns.geometry(e, in: session.art) {
        HStack {
          Picker("Edge", selection: edge) { ForEach(geometry.edgeLengths.indices, id: \.self) { i in Text(String(format: "%d · %.1f mm", i + 1, geometry.edgeLengths[i])).tag(i) } }
          Stepper("Copy \(copy.wrappedValue)", value: copy, in: 1...geometry.piece.cutQuantity)
        }
      }
    }.onChange(of: selected.wrappedValue) { _, value in
      edge.wrappedValue = 0
      let quantity = pieces.first { $0.id == value }?.sewingPiece?.cutQuantity ?? 1
      copy.wrappedValue = isSecond && value == first && quantity > 1 ? 2 : 1
    }
  }
  private func save() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let first, let second, let object = session.object else { throw FormError.invalid("Choose two pattern edges.") }
      var seam = SewingSeam(name: name, first: .init(elementID: first, edge: firstEdge, copy: firstCopy), second: .init(elementID: second, edge: secondEdge, copy: secondCopy))
      seam.tolerance = tolerance; seam.reversed = reversed
      _ = try store.engine.call("form_edit_artwork", arguments: ["object_id": object.id.uuidString, "command": "seam_pair", "seam": try jsonObject(seam)])
      store.revision += 1; dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private struct SewingPatternPreview: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @ObservedObject var session: ArtworkSession
  @State private var dpi = 150.0
  @State private var error = ""
  private var output: SewingPatternOutput? { try? SewingPatternOutput(source: session.art) }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack { Text("Cutting pattern").font(.system(size: 25, design: .serif)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
      if let output {
        let size = output.plan.frameSize
        let image = ArtworkRenderer.image(output.combinedArtwork, width: size.x, height: size.y, assets: session.assets, pixelsPerMM: min(2, 1400 / max(size.x, size.y)))
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
        HStack {
          Text(String(format: "%.1f × %.1f mm · %d piece templates · print at 100%%", size.x, size.y, output.plan.pieces.count)).font(.system(size: 10, design: .monospaced))
          Spacer(); TextField("DPI", value: $dpi, format: .number).textFieldStyle(.roundedBorder).frame(width: 70); Text("DPI").font(.system(size: 10))
        }
        Text("Black: cut contour and notches. Blue: stitch outline. Gold: grain and fold guides. Check the 50 mm square before cutting fabric.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
        HStack { ForEach(["pdf", "svg", "png"], id: \.self) { format in Button("Export " + format.uppercased()) { export(format) } }; Spacer() }
      } else { ContentUnavailableView("No sewing pieces", systemImage: "scissors", description: Text("Annotate supported closed shapes in Canvas first.")) }
      if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
    }.padding(26).frame(width: 900, height: 790).background(Palette.paper)
  }
  private func export(_ format: String) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard let object = session.object else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = object.name + "-sewing-pattern." + format
    panel.allowedContentTypes = [format == "pdf" ? .pdf : format == "svg" ? .svg : .png]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { _ = try store.exportSewingPattern(object: object, arguments: ["format": format, "path": url.path, "dpi": dpi]); error = ""; store.toast("Sewing pattern exported") }
    catch { self.error = error.localizedDescription }
  }
}
