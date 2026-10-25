import AppKit
import CryptoKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class SVGImportReview: Identifiable {
  let id = UUID()
  let data: Data
  let name: String
  let result: SVGImportResult
  let projectID: UUID?
  let target: ProductObject?
  let assets: URL
  let preview: NSImage
  init(data: Data, name: String, result: SVGImportResult, projectID: UUID?, target: ProductObject?)
    throws
  {
    self.data = data
    self.name = name
    self.result = result
    self.projectID = projectID
    self.target = target
    assets = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FORM-SVG-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    do {
      for (name, data) in result.assets {
        try data.write(to: assets.appendingPathComponent(name), options: .atomic)
      }
      preview = ArtworkRenderer.image(
        result.artwork, width: result.width, height: result.height, assets: assets,
        pixelsPerMM: 1000 / max(result.width, result.height))
    } catch {
      try? FileManager.default.removeItem(at: assets)
      throw error
    }
  }
  deinit { try? FileManager.default.removeItem(at: assets) }
}

extension StudioStore {
  func readSVG(_ path: String) throws -> Data {
    guard path.hasPrefix("/") else { throw FormError.invalid("SVG import path must be absolute.") }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard url.pathExtension.lowercased() == "svg" else {
      throw FormError.invalid("Choose an SVG file.")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? Int ?? Int.max) <= 10_000_000
    else { throw FormError.invalid("Choose a regular SVG file under 10 MB.") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 10_000_001) ?? Data()
    guard data.count <= 10_000_000 else { throw FormError.invalid("SVG file exceeds 10 MB.") }
    return data
  }
  func importSVG(arguments: [String: Any]) throws -> Any {
    guard let path = arguments["path"] as? String else {
      throw FormError.invalid("SVG path is required.")
    }
    let data = try readSVG(path)
    let name =
      arguments["name"] as? String
      ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let result = try SVGImporter.read(data, name: name)
    var target: UUID?
    if let raw = arguments["object_id"] {
      guard let value = raw as? String, let id = UUID(uuidString: value) else {
        throw FormError.invalid("Invalid artwork target ID.")
      }
      target = id
    }
    if arguments["dry_run"] as? Bool == true { return result.report }
    guard !result.hasWarnings || arguments["allow_unsupported"] as? Bool == true else {
      throw FormError.invalid(
        "SVG import needs fidelity review: \(result.issues.filter{$0.severity == "warning"}.prefix(3).map(\.summary).joined(separator:" ")) Run form_import_svg with dry_run=true, then allow_unsupported=true to accept the reported differences."
      )
    }
    return try commitSVG(result, data: data, name: name, targetID: target)
  }
  func commitSVG(_ result: SVGImportResult, data: Data, name: String, targetID: UUID?) throws
    -> [String: Any]
  {
    guard let project else {
      throw FormError.missing("Open or create a project before importing SVG artwork.")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let original = "source-\(digest).svg"
    let source = ArtworkImport(
      asset: original, name: String(name.prefix(500)), width: result.width, height: result.height,
      issues: result.issues.map(\.summary))
    // Validate the complete candidate before creating any project assets.
    var candidate = project
    let objectID = try candidate.importArtwork(result.artwork, source: source, targetID: targetID)
    let folder = repository.url(for: project.id).appendingPathComponent("Assets")
    var files = result.assets
    files[original] = data
    var written: [URL] = []
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for (name, bytes) in files {
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
          guard try Data(contentsOf: url) == bytes else {
            throw FormError.invalid("Imported asset name conflicts with an existing file.")
          }
        } else {
          try bytes.write(to: url, options: .atomic)
          written.append(url)
        }
      }
      try engine.edit("Imported SVG · \(name)", source: "SVG import") { $0 = candidate }
    } catch {
      for url in written { try? FileManager.default.removeItem(at: url) }
      throw error
    }
    engine.selection = [objectID]
    showingHome = false
    mode = .artwork
    artworkSession.objectID = objectID
    artworkSession.linkedTargetID = targetID != objectID ? targetID : nil
    artworkSession.scopeID = nil
    let roots = result.artwork.elements.filter { $0.parentID == nil && $0.hidden != true }.map(\.id)
    artworkSession.selection = Set(roots)
    changed()
    DispatchQueue.main.async { self.artworkSession.fit() }
    var report = result.report
    report["object_id"] = objectID.uuidString
    report["original_asset"] = original
    report["selected_elements"] = roots.map(\.uuidString)
    return report
  }
  func importSVGDialog() {
    guard !choosingSVG, svgImport == nil else { return }
    choosingSVG = true
    let window = NSApp.keyWindow
    finishArtworkEditing()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.svg]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message =
      "Import SVG as editable paths, groups, and typography. The original file is preserved."
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
      guard let self else { return }
      self.choosingSVG = false
      guard response == .OK, let url = panel.url else { return }
      DispatchQueue.main.async {
        do {
          let data = try self.readSVG(url.path)
          let name = url.deletingPathExtension().lastPathComponent
          let result = try SVGImporter.read(data, name: name)
          let current = self.mode == .artwork ? self.artworkSession.object : self.primary
          let target = current.flatMap {
            $0.supportsArtworkFace ? self.project?.artworkOwner($0) : nil
          }
          self.svgImport = try .init(
            data: data, name: name, result: result, projectID: self.project?.id, target: target)
        } catch { self.error = error.localizedDescription }
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }
}

struct SVGImportSheet: View {
  @EnvironmentObject var store: StudioStore
  let review: SVGImportReview
  @State private var addToCurrent = false
  @State private var acceptDifferences = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "square.and.arrow.down").font(.system(size: 24, weight: .light))
          .foregroundStyle(Palette.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text("Bring artwork into FORM").font(.system(size: 25, design: .serif))
          Text(review.name).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
        Spacer()
        Text("EDITABLE SVG").font(.system(size: 9, weight: .semibold, design: .monospaced))
          .tracking(1).foregroundStyle(Palette.secondary)
      }.padding(24)
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 14) {
          Image(nsImage: review.preview).resizable().interpolation(.high).scaledToFit()
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
          Text(
            "\(review.result.width.formatted(.number.precision(.fractionLength(0...3)))) × \(review.result.height.formatted(.number.precision(.fractionLength(0...3)))) mm"
          )
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
        }.padding(24).frame(maxWidth: .infinity).background(Color(nsColor: NSColor(hex: "#E9E9E3")))
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            SectionLabel("NATIVE ARTWORK")
            Text("Paths, groups, and text stay editable.").font(.system(size: 14, weight: .medium))
            Text(elementSummary)
              .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            Divider()
            SectionLabel("DESTINATION")
            if let target = review.target {
              Toggle("Add to \(target.name)", isOn: $addToCurrent).toggleStyle(.checkbox).font(
                .system(size: 12))
            }
            Text(
              addToCurrent
                ? "Place at original physical size, centered in this frame."
                : "Create a new artwork frame at the original physical size."
            )
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Divider()
            SectionLabel(review.result.hasWarnings ? "FIDELITY REVIEW" : "IMPORT DETAILS")
            if review.result.issues.isEmpty {
              Label("No unsupported features found", systemImage: "checkmark.circle").font(
                .system(size: 12)
              ).foregroundStyle(Palette.secondary)
            } else {
              ForEach(Array(review.result.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 5) {
                  Label(
                    issue.element,
                    systemImage: issue.severity == "warning"
                      ? "exclamationmark.triangle" : "info.circle"
                  ).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                  Text(issue.message).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                }
              }
            }
            if review.result.hasWarnings {
              Toggle("Import with these differences", isOn: $acceptDifferences).toggleStyle(
                .checkbox
              ).font(.system(size: 12, weight: .medium))
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.frame(width: 310)
      }
      Divider()
      HStack {
        Text("Original SVG and embedded images are preserved in the project.").font(
          .system(size: 10)
        ).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Cancel") { store.svgImport = nil }.keyboardShortcut(.cancelAction)
        Button("Import artwork") {
          do {
            guard store.project?.id == review.projectID else {
              throw FormError.invalid(
                "The project changed while reviewing this import. Open the import again.")
            }
            if store.project == nil { store.createProject() }
            _ = try store.commitSVG(
              review.result, data: review.data, name: review.name,
              targetID: addToCurrent ? review.target?.id : nil)
            store.svgImport = nil
            store.toast("SVG artwork imported")
          } catch { store.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).disabled(review.result.hasWarnings && !acceptDifferences)
      }.padding(20)
    }.frame(width: 900, height: 660).background(Palette.paper)
  }
  private var elementSummary: String {
    let paths = review.result.artwork.elements.filter { $0.kind == "path" }.count
    let texts = review.result.artwork.elements.filter { $0.kind == "text" }.count
    let images = review.result.assets.count
    return
      "\(paths) \(paths == 1 ? "path" : "paths") · \(texts) \(texts == 1 ? "text object" : "text objects") · \(images) \(images == 1 ? "image" : "images")"
  }
}
