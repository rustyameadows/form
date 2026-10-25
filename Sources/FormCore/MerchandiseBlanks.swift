import Foundation

public struct MerchandiseZone: Equatable, Sendable {
  public var id: TextileAttachment.Zone
  public var name: String
  public var width: Double
  public var height: Double
  public var origin: Vector3
  public var right: Vector3
  public var down: Vector3
  public var normal: Vector3
  public var curved = false
}
public struct MerchandiseSurface: Equatable, Sendable {
  public var point: Vector3
  public var normal: Vector3
}
/// Authored presentation blanks and bounded decoration surfaces, separate from sewing patterns/cloth.
public enum MerchandiseBlanks {
  public static let capSeamAngles: [Double] = [-2.42, -0.72, 0.72, 2.42]
  public static let garmentIDs: Set<String> = ["crewTee", "curvedCap", "canvasTote"]
  public static let recipeIDs = garmentIDs.union(["textilePrint"])
  public static func defaultMaterial(_ recipe: String) -> String? {
    switch recipe {
    case "crewTee": return "jersey-ecru"
    case "curvedCap": return "merch-twill"
    case "canvasTote": return "merch-canvas"
    case "textilePrint": return "merch-ink"
    default: return nil
    }
  }
  public static let recipes: [Recipe] = [
    .init(
      "crewTee", "Crew-neck tee", "tshirt",
      "A dimensioned generic flat-lay jersey blank with a real neck opening, rib collar, short sleeves and bounded independent decorations.",
      [
        .init("width", "Body width", 540, 360...760), .init("depth", "Body length", 700, 480...900),
        .init("sleeveLength", "Sleeve extension", 190, 120...280),
        .init("sleeveWidth", "Sleeve opening", 200, 140...280),
        .init("neckWidth", "Neck opening", 180, 130...240),
        .init("neckDrop", "Front neck drop", 95, 50...140),
        .init("loft", "Front surface height", 22, 12...40),
        .init("collarWidth", "Collar rib width", 18, 10...28),
      ]),
    .init(
      "curvedCap", "Curved-front cap", "hat.cap",
      "A circular crown with a cylindrical decoration band, domed roof, curved visor, back opening and sweatband. Generic concept geometry.",
      [
        .init("width", "Crown diameter", 200, 160...260),
        .init("height", "Crown height", 140, 100...180),
        .init("depth", "Visor reach", 75, 45...100),
        .init("brimWidth", "Visor width", 210, 170...280),
        .init("brimCurve", "Visor curve", 12, 0...25),
      ]),
    .init(
      "canvasTote", "Canvas tote", "bag",
      "An open gusseted canvas blank with two webbing handles and independent front, back and side decoration regions.",
      [
        .init("width", "Body width", 380, 240...600), .init("depth", "Body height", 420, 240...650),
        .init("gusset", "Open gusset", 80, 40...150),
        .init("handleDrop", "Handle drop", 230, 140...340),
        .init("handleWidth", "Handle width", 26, 18...45),
        .init("handleSpan", "Handle spacing", 190, 100...300),
        .init("topHem", "Top hem", 24, 15...40),
      ]),
    .init(
      "textilePrint", "Direct artwork region", "paintbrush.pointed",
      "An independent physically sized artwork region. Curved cap artwork conforms to the actual cylindrical crown; no rigid floating plate is used.",
      [
        .init("width", "Artwork width", 80, 5...400, step: 0.5),
        .init("depth", "Artwork height", 28, 5...400, step: 0.5),
        .init("height", "Ink relief", 0.15, 0.05...0.5, step: 0.05),
      ]),
  ]
  public static var materials: [Material] {
    func fabric(
      _ id: String, _ name: String, _ color: String, _ structure: FabricProfile.Structure,
      _ gsm: Double, _ thickness: Double
    ) -> Material {
      var m = Material(id, name, "Fabric", color, roughness: 0.92, thickness: thickness)
      m.fabric = .init(
        composition: name + " · generic concept declaration", structure: structure, weightGSM: gsm,
        usableWidth: 1500)
      return m
    }
    return [
      fabric("jersey-ecru", "Cotton jersey · ecru", "#E9E2D2", .knit, 220, 0.8),
      fabric("jersey-navy", "Cotton jersey · navy", "#152D43", .knit, 220, 0.8),
      fabric("merch-rib", "Cotton rib · ecru", "#D8D1BF", .knit, 320, 1.4),
      fabric("merch-twill", "Cotton twill · midnight", "#203448", .woven, 260, 0.7),
      fabric("merch-canvas", "Cotton canvas · natural", "#D4C5A5", .woven, 340, 1.1),
      fabric("merch-webbing", "Cotton webbing · navy", "#233C50", .woven, 600, 2.0),
      Material(
        "merch-ink", "Direct artwork / source colors", "Artwork", "#FFFFFF", roughness: 0.8,
        thickness: 0.15),
    ]
  }
  public static func blankArtwork(width: Double, height: Double) -> Artwork {
    var e = ArtworkElement(
      kind: "text", x: 0, y: 0, width: width, height: height, text: "ARTWORK", color: "#203448",
      fontSize: min(18, width * 0.6, height * 1.4))
    var t = Typography()
    t.alignment = "center"
    t.verticalAlignment = "center"
    e.typography = t
    var art = Artwork(background: "#FFFFFF", elements: [e], bleed: 0)
    art.backgroundOpacity = 0
    return art
  }
  public static func defaults(_ recipe: String) -> TextileProduct? {
    guard recipeIDs.contains(recipe) else { return nil }
    var spec = TextileProduct(
      kind: recipe == "textilePrint" ? .patch : .garment,
      process: recipe == "textilePrint" ? .directPrint : .decoratedBlank)
    spec.blankName =
      recipe == "crewTee"
      ? "Generic crew-neck tee"
      : recipe == "curvedCap"
        ? "Generic curved-front cap" : recipe == "canvasTote" ? "Generic canvas tote" : nil
    spec.size = recipe == "textilePrint" ? nil : "Concept dimensions"
    spec.trimMaterialID =
      recipe == "crewTee" ? "merch-rib" : recipe == "canvasTote" ? "merch-webbing" : "merch-twill"
    return spec
  }
  public static func zones(_ o: ProductObject) -> [MerchandiseZone] {
    let w = o["width"]
    let d = o["depth"]
    func flat(
      _ id: TextileAttachment.Zone, _ name: String, _ width: Double, _ height: Double, _ x: Double,
      _ y: Double, _ z: Double, _ back: Bool = false
    ) -> MerchandiseZone {
      .init(
        id: id, name: name, width: width, height: height, origin: .init(x, y, z),
        right: .init(back ? -1 : 1, 0, 0), down: .init(0, 0, 1), normal: .init(0, back ? -1 : 1, 0))
    }
    switch o.recipeID {
    case "crewTee":
      let y = o["loft"]
      return [
        flat(.front, "Front body", w * 0.66, d * 0.50, 0, y, d * 0.08),
        flat(.back, "Back body", w * 0.66, d * 0.52, 0, 4, d * 0.11, true),
        flat(.leftChest, "Left chest", w * 0.28, d * 0.2, w * 0.23, y, -d * 0.12),
        flat(.rightChest, "Right chest", w * 0.28, d * 0.2, -w * 0.23, y, -d * 0.12),
        flat(
          .leftSide, "Left sleeve", o["sleeveLength"] * 0.5, o["sleeveWidth"] * 0.6,
          w / 2 + o["sleeveLength"] * 0.5, y, -d * 0.43 + o["sleeveWidth"] / 2),
        flat(
          .rightSide, "Right sleeve", o["sleeveLength"] * 0.5, o["sleeveWidth"] * 0.6,
          -w / 2 - o["sleeveLength"] * 0.5, y, -d * 0.43 + o["sleeveWidth"] / 2),
        flat(
          .collar, "Inside neck label", o["neckWidth"] * 0.6, 32, 0, y + 0.5,
          -d / 2 + o["neckDrop"] + 40),
      ]
    case "canvasTote":
      let g = o["gusset"]
      var result = [
        flat(.front, "Front canvas", w * 0.72, d * 0.65, 0, g + 6, d * 0.06),
        flat(.back, "Back canvas", w * 0.72, d * 0.65, 0, 6, d * 0.06, true),
        flat(
          .collar, "Inside top label", min(110, w * 0.4), 24, 0, g + 6, -d / 2 + o["topHem"] + 16),
      ]
      for sign in [-1.0, 1.0] {
        result.append(
          .init(
            id: sign > 0 ? .leftSide : .rightSide, name: sign > 0 ? "Left gusset" : "Right gusset",
            width: g * 0.6, height: d * 0.55, origin: .init(sign * w / 2, g / 2 + 6, d * 0.06),
            right: .init(0, -sign, 0), down: .init(0, 0, 1), normal: .init(sign, 0, 0)))
      }
      return result
    case "curvedCap":
      let wall = o["height"] * 0.72
      return [
        MerchandiseZone(
          id: .front, name: "Curved front crown", width: w * 0.55, height: wall * 0.4,
          origin: .init(0, wall * 0.62, 0), right: .init(1, 0, 0), down: .init(0, -1, 0),
          normal: .init(0, 0, -1), curved: true),
        .init(
          id: .leftSide, name: "Left crown", width: w * 0.3, height: wall * 0.35,
          origin: .init(Double.pi / 2, wall * 0.62, 0), right: .init(1, 0, 0),
          down: .init(0, -1, 0), normal: .init(1, 0, 0), curved: true),
        .init(
          id: .rightSide, name: "Right crown", width: w * 0.3, height: wall * 0.35,
          origin: .init(-Double.pi / 2, wall * 0.62, 0), right: .init(1, 0, 0),
          down: .init(0, -1, 0), normal: .init(-1, 0, 0), curved: true),
        .init(
          id: .back, name: "Back above adjustment opening", width: w * 0.4, height: wall * 0.2,
          origin: .init(Double.pi, wall * 0.82, 0), right: .init(1, 0, 0), down: .init(0, -1, 0),
          normal: .init(0, 0, 1), curved: true),
      ]
    default: return []
    }
  }
  public static func sample(
    _ garment: ProductObject, zone: MerchandiseZone, u: Double, v: Double, clearance: Double = 0
  ) -> MerchandiseSurface {
    if zone.curved {
      let r = garment["width"] / 2
      let angle = zone.origin.x - u / r
      let n = Vector3(sin(angle), 0, -cos(angle))
      return .init(
        point: .init((r + clearance) * n.x, zone.origin.y - v, (r + clearance) * n.z), normal: n)
    }
    return .init(
      point: .init(
        zone.origin.x + u * zone.right.x + v * zone.down.x + clearance * zone.normal.x,
        zone.origin.y + u * zone.right.y + v * zone.down.y + clearance * zone.normal.y,
        zone.origin.z + u * zone.right.z + v * zone.down.z + clearance * zone.normal.z),
      normal: zone.normal)
  }
  public static func crown(_ o: ProductObject, angle: Double, t: Double) -> Vector3 {
    let wall = o["height"] * 0.72
    let phi = max(0, (t - 0.72) / 0.28) * Double.pi / 2
    let r = o["width"] / 2 * (t <= 0.72 ? 1 : cos(phi))
    let y = t <= 0.72 ? t / 0.72 * wall : wall + (o["height"] - wall) * sin(phi)
    return .init(r * sin(angle), y, -r * cos(angle))
  }
  public static func validate(_ object: ProductObject, in project: Project) throws {
    if object.recipeID == "curvedCap", object.textile?.laidFaceDown == true {
      throw FormError.invalid(
        "The cap remains upright; orbit to view its back. Front/back turnover applies to flat-lay tee and tote blanks."
      )
    }
    if garmentIDs.contains(object.recipeID) {
      guard project.material(object.materialID).fabric != nil else {
        throw FormError.invalid("Choose a fabric material for this merchandise blank.")
      }
      if object.recipeID == "crewTee" {
        guard object["neckWidth"] + 2 * object["collarWidth"] < object["width"] * 0.7,
          object["neckDrop"] < object["depth"] * 0.25
        else { throw FormError.invalid("The crew neck must fit inside the shoulder region.") }
      }
      if object.recipeID == "canvasTote" {
        guard object["handleSpan"] + object["handleWidth"] < object["width"] - 20 else {
          throw FormError.invalid("Handle spacing and width must fit inside the tote's top edge.")
        }
      }
    }
    guard let a = object.textile?.attachment,
      let host = project.objects.first(where: { $0.id == a.garmentID }),
      garmentIDs.contains(host.recipeID)
    else { return }
    guard let zone = zones(host).first(where: { $0.id == a.zone }) else {
      throw FormError.invalid("This region does not exist on the selected blank.")
    }
    if host.recipeID == "curvedCap" {
      guard object.recipeID == "textilePrint", object.textile?.process == .directPrint,
        object.textile?.embroidery == nil
      else {
        throw FormError.invalid(
          "This curved cap supports conforming direct artwork only. Rigid patches, sewn labels and embroidery require a supported constructed placement instead of a floating plate."
        )
      }
    }
    let maximumClearance = object.recipeID == "textilePrint" ? 0.25 : 3.0
    guard (0...maximumClearance).contains(a.clearance) else {
      throw FormError.invalid(
        "Direct artwork uses 0–0.25 mm clearance; new blank patches/labels use 0–3 mm. Choose a supported surface placement."
      )
    }
    let w = object["width"]
    let h = object["depth"]
    let angle = a.rotation * Double.pi / 180
    let c = cos(angle)
    let s = sin(angle)
    for x in [-w / 2, w / 2] {
      for y in [-h / 2, h / 2] {
        let u = a.offset.x + x * c + y * s
        let v = a.offset.y - x * s + y * c
        guard abs(u) <= zone.width / 2 + 1e-8, abs(v) <= zone.height / 2 + 1e-8 else {
          throw FormError.invalid(
            "The complete rotated decoration must fit inside \(zone.name)'s \(Int(zone.width)) × \(Int(zone.height)) mm region. Reduce its dimensions or offset."
          )
        }
      }
    }
  }
}

extension Project {
  public func textileZoneReport(objectID: UUID) throws -> [String: Any] {
    guard let o = objects.first(where: { $0.id == objectID }),
      MerchandiseBlanks.garmentIDs.contains(o.recipeID)
    else {
      throw FormError.invalid(
        "Choose a crewTee, curvedCap or canvasTote to inspect bounded decoration regions.")
    }
    return [
      "object_id": o.id.uuidString, "recipe_id": o.recipeID, "units": "mm",
      "concept_dimensions": true,
      "measurements_declared_verified": o.textile?.measurementsVerified ?? false,
      "showing_back": o.textile?.laidFaceDown ?? false,
      "zones": MerchandiseBlanks.zones(o).map { z in
        [
          "id": z.id.rawValue, "name": z.name, "width_mm": z.width, "height_mm": z.height,
          "surface": z.curved ? "cylindrical arc-length band" : "planar fabric panel",
          "coordinates":
            "Centered across/down in physical millimeters; complete rotated corners must remain inside the region.",
          "allowed_processes": z.curved
            ? [TextileProduct.Process.directPrint.rawValue]
            : TextileProduct.Process.allCases.filter { $0 != .decoratedBlank }.map(\.rawValue),
          "clearance_mm": z.curved
            ? "0–0.25 for direct surface artwork" : "0–0.25 direct artwork; 0–3 patch/label",
          "constructed_or_simulated": false,
        ] as [String: Any]
      },
    ]
  }
}
