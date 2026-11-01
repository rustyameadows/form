import Foundation
import CryptoKit

/// Portable visual paper description. These values are design assumptions,
/// independently of any measured stock or manufacturing approval.
public struct PaperSurfaceProfile: Codable, Equatable, Sendable {
  public enum Texture: String, Codable, CaseIterable, Sendable { case smooth, cotton, coated, laid, linen, recycled, vellum }
  public var texture: Texture
  public var color: String?
  public var roughness: Double
  public var textureScaleMM: Double
  public var textureDepthMM: Double
  public var opacity: Double
  public init(texture: Texture = .smooth, color: String? = nil, roughness: Double = 0.9,
    textureScaleMM: Double = 0.8, textureDepthMM: Double = 0.015, opacity: Double = 1) {
    self.texture = texture; self.color = color; self.roughness = roughness
    self.textureScaleMM = textureScaleMM; self.textureDepthMM = textureDepthMM; self.opacity = opacity
  }
  public func validate() throws {
    if let color { try validateColor(color) }
    guard roughness.isFinite, (0...1).contains(roughness), textureScaleMM.isFinite,
      (0.05...100).contains(textureScaleMM), textureDepthMM.isFinite,
      (0...0.5).contains(textureDepthMM), opacity.isFinite, (0...1).contains(opacity) else {
      throw FormError.invalid("Paper appearance needs roughness/opacity 0–1, texture scale 0.05–100 mm and texture depth 0–0.5 mm.")
    }
  }
}

/// One bonded ply, ordered back to front. It is not a front/back print side.
public struct PaperPly: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var color: String
  public var thicknessMM: Double
  public var profile: PaperSurfaceProfile?
  public var gsm: Double?
  public init(id: UUID = UUID(), name: String, color: String, thicknessMM: Double,
    profile: PaperSurfaceProfile? = nil, gsm: Double? = nil) {
    self.id = id; self.name = name; self.color = color; self.thicknessMM = thicknessMM
    self.profile = profile; self.gsm = gsm
  }
  public func validate() throws {
    try validateColor(color); try profile?.validate()
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
      thicknessMM.isFinite, (0.01...20).contains(thicknessMM),
      gsm.map({ $0.isFinite && (10...5000).contains($0) }) ?? true else {
      throw FormError.invalid("Each paper ply needs a bounded name, 0.01–20 mm caliper, color and optional 10–5000 GSM declaration.")
    }
  }
}

public struct PaperFinishAssignment: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable { case flatInk, letterpress, emboss, deboss, foil, screenPrint }
  public enum Side: String, Codable, CaseIterable, Sendable { case outside, inside }
  public var id: UUID
  public var name: String
  public var kind: Kind
  public var side: Side
  public var elementIDs: [UUID]
  public var color: String?
  public var depthMM: Double
  public var heightMM: Double
  public var roughness: Double?
  public var metallic: Double?
  public var opacity: Double
  public var enabled: Bool
  public init(id: UUID = UUID(), name: String, kind: Kind, side: Side = .outside, elementIDs: [UUID],
    color: String? = nil, depthMM: Double = 0, heightMM: Double = 0,
    roughness: Double? = nil, metallic: Double? = nil, opacity: Double = 1, enabled: Bool = true) {
    self.id = id; self.name = name; self.kind = kind; self.side = side; self.elementIDs = elementIDs
    self.color = color; self.depthMM = depthMM; self.heightMM = heightMM
    self.roughness = roughness; self.metallic = metallic; self.opacity = opacity; self.enabled = enabled
  }
  public func validate() throws {
    if let color { try validateColor(color) }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
      !elementIDs.isEmpty, elementIDs.count <= 5000, Set(elementIDs).count == elementIDs.count,
      depthMM.isFinite, (0...2).contains(depthMM), heightMM.isFinite, (0...2).contains(heightMM),
      roughness.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
      metallic.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
      opacity.isFinite, (0...1).contains(opacity) else {
      throw FormError.invalid("Finishes require unique artwork IDs, bounded names, 0–2 mm relief intent and 0–1 appearance channels.")
    }
    guard (kind != .flatInk || depthMM == 0 && heightMM == 0),
      (kind != .emboss || depthMM == 0),
      (![Kind.deboss, .letterpress].contains(kind) || heightMM == 0),
      (kind != .screenPrint || depthMM == 0) else {
      throw FormError.invalid("Use letterpress/deboss for impressions, emboss for raised blind work, and screenPrint for raised ink. Flat ink has no relief.")
    }
  }
}

extension PaperStock {
  public var resolvedThicknessMM: Double { plies.map { $0.reduce(0) { $0 + $1.thicknessMM } } ?? thicknessMM }
  public func validate() throws {
    try profile?.validate()
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
      (vendor?.utf8.count ?? 0) <= 512, notes.utf8.count <= 2048,
      thicknessMM.isFinite, (0.01...20).contains(thicknessMM),
      gsm.map({ $0.isFinite && (10...5000).contains($0) }) ?? true else {
      throw FormError.invalid("Declare bounded paper stock metadata, 0.01–20 mm caliper and optional 10–5000 GSM; omit unknown measurements.")
    }
    if let size = sheetSizeMM {
      guard size.x.isFinite, size.y.isFinite, (50...5000).contains(size.x), (50...5000).contains(size.y) else {
        throw FormError.invalid("Declared stock sheets need 50–5000 mm edges.")
      }
    }
    if let plies {
      guard !plies.isEmpty, plies.count <= 16, Set(plies.map(\.id)).count == plies.count else {
        throw FormError.invalid("Bonded stock needs 1–16 uniquely identified plies in back-to-front order.")
      }
      for ply in plies { try ply.validate() }
      guard resolvedThicknessMM <= 20, abs(thicknessMM - resolvedThicknessMM) <= 1e-9 else {
        throw FormError.invalid("Stock thicknessMM must equal the sum of its bonded ply calipers; update the construction caliper atomically.")
      }
    }
  }
}

public struct PaperAppearanceIssue: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var finishID: UUID?
  public init(_ code: String, _ message: String, finishID: UUID? = nil) { self.code = code; self.message = message; self.finishID = finishID }
}
public struct PaperFinishInspection: Codable, Equatable, Sendable {
  public var assignment: PaperFinishAssignment
  public var sourceObjectID: UUID?
  public var sourceRevision: String?
  public var resolvedElementIDs: [UUID]
  public var missingElementIDs: [UUID]
}
public struct PaperAppearanceInspection: Codable, Equatable, Sendable {
  public var stock: PaperStock
  public var resolvedThicknessMM: Double
  public var finishes: [PaperFinishInspection]
  public var issues: [PaperAppearanceIssue]
  public var reliefRepresentation = "surfaceShading"
  public var finalCaptureReliefRepresentation: String? = "boundedMacroGeometryAndSurfaceShading"
  public var manufacturingVerified = false
  public var units = "millimeters"
  public var plyOrder = "backToFront"
}
public enum PaperAppearance {
  /// Structural print visibility, using the same role/ancestor/clip policy as
  /// production artwork. Pixel alpha, glyph availability and final clipping
  /// still require the normal output validation and actual render review.
  public static func visiblePrintTargetIDs(artwork:Artwork,project:Project)throws->Set<UUID> {
    let expanded=try project.resolvingComponents(in:artwork)
    let printed=try ArtworkProduction.filtered(expanded,roles:[.print])
    let leaves=Set(printed.artwork.elements.filter { element in
      guard printed.contentIDs.contains(element.id) else{return false}
      if element.kind=="text" {return !element.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || element.storyFrame != nil || element.listItems?.isEmpty == false}
      if element.kind=="image" {return true}
      let stroke=element.visibleStroke.map{($0.opacity ?? 1)>0} ?? false
      if element.kind=="line" {return stroke}
      let fill=element.fillEnabled != false && (element.fillOpacity ?? 1)>0 && (element.gradient?.stops.contains{($0.opacity ?? 1)>0} ?? true)
      return fill || stroke
    }.map(\.id))
    return Set(artwork.elements.compactMap { element in
      expanded.descendants(of:[element.id]).isDisjoint(with:leaves) ? nil:element.id
    })
  }
  public static func validateVisibleTargets(_ finish:PaperFinishAssignment,artwork:Artwork,project:Project)throws {
    let visible=try visiblePrintTargetIDs(artwork:artwork,project:project)
    guard Set(finish.elementIDs).isSubset(of:visible) else {
      throw FormError.invalid("Each finish target must contain visible print artwork. Restore its Print role/visibility/paint, select a group with visible print content, or choose another source target.")
    }
  }
  public static func validateColorOverride(_ finish:PaperFinishAssignment,artwork:Artwork,project:Project)throws {
    guard finish.color != nil,[PaperFinishAssignment.Kind.flatInk,.letterpress,.screenPrint].contains(finish.kind) else{return}
    let expanded=try project.resolvingComponents(in:artwork)
    let selected=expanded.descendants(of:Set(finish.elementIDs))
    guard !expanded.elements.contains(where:{selected.contains($0.id) && $0.kind=="image"}) else {
      throw FormError.invalid("A colored ink override on bitmap artwork requires a raster ink plate. Keep the image's original colors or use a vector mask; image-alpha foil and relief remain supported.")
    }
  }
  public static func source(project: Project, object: ProductObject, side: PaperFinishAssignment.Side) -> (id: UUID?, artwork: Artwork?) {
    if side == .outside {
      let owner = project.artworkOwner(object)
      return (owner.id, owner.artwork)
    }
    guard let paper = try? PaperConstruction.definition(for: object) else { return (nil, nil) }
    if let id = paper.insideArtworkSourceID, let inside = project.objects.first(where: { $0.id == id }) {
      let owner = project.artworkOwner(inside)
      return (owner.id, owner.artwork)
    }
    return (paper.insideArtwork == nil ? nil : object.id, paper.insideArtwork)
  }
  public static func inspect(project: Project, object: ProductObject) throws -> PaperAppearanceInspection {
    let paper = try PaperConstruction.definition(for: object)
    var issues = [PaperAppearanceIssue("unverifiedManufacturing", "Paper profiles and finishes are editable appearance/production intent. Press tooling, die geometry, trapping, registration, adhesive, strength and physical samples are not verified.")]
    if !paper.stock.verified { issues.append(.init("unmeasuredStock", "The declared paper stock is not marked measured; its caliper, GSM and visual profile remain assumptions.")) }
    if paper.stock.plies != nil { issues.append(.init("bondedPlyAssumptions", "Ply calipers are summed. Adhesive thickness, compressibility, bond strength and fold performance require a physical sample.")) }
    var inspections = [PaperFinishInspection]()
    var sources = [String: (id: UUID?, artwork: Artwork?, available: Set<UUID>, visible: Set<UUID>, revision: String?)]()
    for finish in paper.finishes ?? [] {
      if sources[finish.side.rawValue] == nil {
        let value = source(project: project, object: object, side: finish.side)
        let revision = try value.artwork.map { SHA256.hash(data: try JSONEncoder.form.encode($0)).map { String(format: "%02x", $0) }.joined() }
        let visible=try value.artwork.map{try visiblePrintTargetIDs(artwork:$0,project:project)} ?? []
        sources[finish.side.rawValue] = (value.id, value.artwork, Set(value.artwork?.elements.map(\.id) ?? []), visible, revision)
      }
      let source = sources[finish.side.rawValue]!
      let missing = finish.elementIDs.filter { !source.available.contains($0) }
      let selected = Set(finish.elementIDs).intersection(source.available)
      let resolved = source.artwork?.descendants(of: selected).sorted { $0.uuidString < $1.uuidString } ?? []
      inspections.append(.init(assignment: finish, sourceObjectID: source.id, sourceRevision: source.revision, resolvedElementIDs: resolved, missingElementIDs: missing))
      if source.artwork == nil { issues.append(.init("missingFinishSide", "The \(finish.side.rawValue) source for finish ‘\(finish.name)’ is unavailable.", finishID: finish.id)) }
      if !missing.isEmpty { issues.append(.init("missingFinishTargets", "Finish ‘\(finish.name)’ retains \(missing.count) missing source IDs for repair; no replacement target is inferred.", finishID: finish.id)) }
      let invisible=selected.subtracting(source.visible)
      if finish.enabled,!invisible.isEmpty {issues.append(.init("invisibleFinishTargets","Finish ‘\(finish.name)’ retains \(invisible.count) source targets without visible print content. Restore their Print role/visibility/paint or retarget; no substitute mask is inferred.",finishID:finish.id))}
      if finish.depthMM > paper.stock.resolvedThicknessMM * 0.5 { issues.append(.init("deepImpression", "Finish ‘\(finish.name)’ requests an impression deeper than half the stock caliper; physical feasibility is unverified.", finishID: finish.id)) }
      if [.letterpress, .emboss, .deboss, .foil, .screenPrint].contains(finish.kind) {
        issues.append(.init("reliefIsAppearance", "Finish ‘\(finish.name)’ uses surface shading in native presentation. Its depth/height is saved intent, not displaced tooling or manufacturing geometry.", finishID: finish.id))
      }
    }
    return .init(stock: paper.stock, resolvedThicknessMM: paper.stock.resolvedThicknessMM, finishes: inspections, issues: issues)
  }
}
