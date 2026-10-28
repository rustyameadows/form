import AppKit
import FormCore
import FormGraphics
import SwiftUI

/// String bindings keep the active native field authoritative when Save is clicked.
@MainActor final class SewingTileDraft: ObservableObject {
  enum Field: Int, CaseIterable {
    case width, height, top, right, bottom, left, overlap
    var title: String {
      ["Sheet width", "Sheet height", "Top margin", "Right margin", "Bottom margin", "Left margin", "Overlap"][rawValue]
    }
  }
  @Published var values = [String](repeating: "", count: Field.allCases.count)
  init(_ options: SewingTileOptions = .init()) { load(options) }
  func load(_ options: SewingTileOptions) {
    values = [options.sheetSize.x, options.sheetSize.y, options.margins.top, options.margins.right,
      options.margins.bottom, options.margins.left, options.overlap].map {
        $0 == $0.rounded() ? String(Int($0)) : String($0)
      }
  }
  func options() throws -> SewingTileOptions {
    let numbers = try zip(Field.allCases, values).map { field, text -> Double in
      guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
        throw FormError.invalid("\(field.title) needs a finite measurement in millimeters.")
      }
      return value
    }
    let options = SewingTileOptions(sheetSize: .init(numbers[0], numbers[1]),
      margins: .init(top: numbers[2], right: numbers[3], bottom: numbers[4], left: numbers[5]), overlap: numbers[6])
    try options.validate()
    return options
  }
  func preset(_ name: String) {
    var size = name.hasPrefix("Letter") ? SewingTileOptions.letter : SewingTileOptions.a4
    if name.hasSuffix("landscape") { size = .init(size.y, size.x) }
    values[Field.width.rawValue] = String(size.x)
    values[Field.height.rawValue] = String(size.y)
  }
}

@MainActor final class SewingPatternReviewModel: ObservableObject {
  weak var session: ArtworkSession?
  let draft = SewingTileDraft()
  @Published var tiled = false
  @Published var dpi = "150"
  @Published private(set) var proof: Data?
  @Published private(set) var error = ""
  @Published private(set) var size = Point2()
  @Published private(set) var pieceCount = 0
  @Published private(set) var pageCount = 1
  @Published private(set) var gridDescription = ""
  private(set) var sourceBuilds = 0
  private var context: String?
  private var savedOptions: SewingTileOptions?
  private var sourceKey: Data?
  private var proofKey: Data?
  private var source: SewingPatternOutput?
  private var largeProof: Data?
  init(session: ArtworkSession) { self.session = session }
  var identity: String {
    PhysicalDocumentController.key(project: session?.store?.project?.id,
      object: session?.object?.id, kind: tiled ? "sewing-pattern-tiles" : "sewing-pattern")
  }
  var hasSavedOptions: Bool { session?.art.sewingTiles != nil }
  func refresh() {
    do {
      guard let session, session.object != nil else { throw FormError.missing("Choose a cutting-pattern source.") }
      let nextContext = PhysicalDocumentController.key(project: session.store?.project?.id,
        object: session.object?.id, kind: "sewing-pattern-source")
      let saved = session.art.sewingTiles
      if context != nextContext {
        context = nextContext
        savedOptions = saved
        draft.load(saved ?? .init())
        tiled = saved != nil
        sourceKey = nil
        proofKey = nil
      } else if savedOptions != saved {
        savedOptions = saved
        draft.load(saved ?? .init())
      }
      var art = session.art
      art.sewingTiles = nil
      var key = try JSONEncoder.form.encode(art)
      key.append(Data("\(nextContext)/\(session.assets.path)/\(GeometryFactory.fontRevision)".utf8))
      if sourceKey != key {
        let output = try SewingPatternOutput(source: art)
        let data = try output.pdf(assets: session.assets, dpi: 150)
        source = output
        largeProof = data
        size = output.plan.frameSize
        pieceCount = output.plan.pieces.count
        sourceBuilds += 1
        sourceKey = key
        proofKey = nil
      }
      guard let source, let largeProof else { throw FormError.invalid("Could not build the source pattern.") }
      var nextProofKey = key
      if tiled {
        let options = try draft.options()
        nextProofKey.append(try JSONEncoder.form.encode(options))
        if proofKey != nextProofKey || proof == nil {
          let output = try SewingTileOutput(source: source, options: options)
          proof = try output.pdf(assets: session.assets, name: session.object?.name ?? "Cutting pattern")
          pageCount = output.plan.pageCount
          gridDescription = "\(output.plan.rows) rows × \(output.plan.columns) columns + calibration page"
        }
      } else {
        nextProofKey.append(Data("large-format".utf8))
        if proofKey != nextProofKey || proof == nil { proof = largeProof }
        pageCount = 1
        gridDescription = "One full-size source page"
      }
      proofKey = nextProofKey
      error = ""
    } catch {
      proof = nil
      proofKey = nil
      self.error = error.localizedDescription
    }
  }
  @discardableResult func saveOptions(clear: Bool = false) -> Bool {
    do {
      guard let session, let store = session.store, let object = session.object else {
        throw FormError.missing("The pattern source is no longer open.")
      }
      let value: Any = clear ? NSNull() : try jsonObject(draft.options())
      _ = try store.engine.call("form_edit_artwork", arguments: ["object_id": object.id.uuidString,
        "command": "pattern_tiles", "tile_options": value])
      store.changed()
      refresh()
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
  @discardableResult func export(_ format: String, path: URL) -> Bool {
    do {
      guard let session, let store = session.store, let object = session.object else {
        throw FormError.missing("The pattern source is no longer open.")
      }
      guard let density = Double(dpi), density.isFinite else {
        throw FormError.invalid("Export DPI needs a finite number from 36 to 1200.")
      }
      var arguments: [String: Any] = ["format": format, "path": path.path, "dpi": density]
      if tiled { arguments["pattern_tiles"] = try jsonObject(draft.options()) }
      _ = try store.exportSewingPattern(object: object, arguments: arguments)
      error = ""
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
}

struct SewingTileSettings: View {
  @ObservedObject var draft: SewingTileDraft
  var saved: Bool
  var save: () -> Void
  var clear: () -> Void
  private func field(_ field: SewingTileDraft.Field) -> some View {
    HStack(spacing: 6) {
      Text(field.title).foregroundStyle(Palette.secondary)
      Spacer(minLength: 2)
      TextField(field.title, text: $draft.values[field.rawValue])
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 62)
        .accessibilityLabel(field.title + " in millimeters")
      Text("mm").foregroundStyle(Palette.secondary)
    }.font(.system(size: 10))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Menu("Sheet preset") {
        ForEach(["A4 portrait", "A4 landscape", "Letter portrait", "Letter landscape"], id: \.self) { name in
          Button(name) { draft.preset(name) }
        }
      }.accessibilityLabel("Tiled pattern sheet preset")
      Text("Custom physical sheet").font(.system(size: 11, weight: .medium))
      field(.width)
      field(.height)
      Divider()
      Text("Declared printable margins").font(.system(size: 11, weight: .medium))
      ForEach([SewingTileDraft.Field.top, .right, .bottom, .left], id: \.rawValue) { field($0) }
      field(.overlap)
      Text("3 mm mark gutters and a 12 mm label footer stay outside the drawing. Margins are declared; printer capabilities are not inferred.")
        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
      Divider()
      Button("Save sheet options") { save() }.accessibilityLabel("Save pattern sheet options")
      if saved { Button("Clear saved options") { clear() }.accessibilityLabel("Clear saved pattern sheet options") }
      Text("Preview and export use these values. Only Save changes the document; it is one Undo.")
        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
      Spacer(minLength: 0)
    }.frame(width: 217)
  }
}
