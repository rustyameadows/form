import Foundation

/// Authored flat presentation geometry. These are not sewing patterns or reconstructed products.
public enum StarterTextiles {
  public static let recipeIDs: Set<String> = ["pulloverHoodie", "cuffedBeanie", "hemmedTextile"]
  public static let recipes: [Recipe] = [
    .init("pulloverHoodie", "Pullover hoodie", "tshirt", "Approximate flat hoodie with long sleeves, open hood and pouch pocket.", [
      .init("width", "Body width", 600, 420...800), .init("depth", "Body length", 720, 500...900),
      .init("sleeveLength", "Sleeve extension", 420, 300...550), .init("sleeveWidth", "Sleeve width", 180, 140...260),
      .init("hoodWidth", "Hood width", 270, 200...340), .init("hoodHeight", "Hood length", 280, 200...360),
      .init("pocketWidth", "Pocket width", 320, 220...380), .init("pocketHeight", "Pocket height", 180, 130...220),
      .init("loft", "Body surface height", 30, 20...45), .init("ribHeight", "Hem rib", 60, 40...80),
    ]),
    .init("cuffedBeanie", "Cuffed knit beanie", "hat.cap", "Approximate flat knit crown with a separate turned cuff.", [
      .init("width", "Flat width", 220, 170...300), .init("depth", "Cuffed length", 240, 180...330),
      .init("cuffHeight", "Cuff height", 65, 40...90), .init("loft", "Crown surface height", 18, 10...30),
    ]),
    .init("hemmedTextile", "Hemmed textile", "square", "Flat cloth panel with folded edge seams; tied and draped states are separate.", [
      .init("width", "Width", 550, 200...1800), .init("depth", "Length", 550, 200...2200),
      .init("hem", "Hem inset", 10, 5...25), .init("loft", "Surface height", 2, 1...5, step: 0.1),
    ]),
  ]
  public static var materials: [Material] {
    func fabric(_ id: String, _ name: String, _ color: String, _ composition: String,
                _ structure: FabricProfile.Structure, _ thickness: Double) -> Material {
      var m = Material(id, name, "Fabric", color, roughness: 0.95, thickness: thickness)
      m.fabric = .init(composition: composition + " · preview declaration", structure: structure)
      return m
    }
    return [fabric("library-fleece", "Fleece · warm gray", "#A49F94", "Cotton/polyester fleece", .knit, 2),
      fabric("library-acrylic", "Acrylic knit · charcoal", "#3E4545", "Acrylic knit", .knit, 3),
      fabric("library-polyester", "Polyester cloth · ivory", "#E8DFCC", "Polyester woven cloth", .woven, 0.3)]
  }
  public static func zones(_ o: ProductObject) -> [MerchandiseZone] {
    let w = o["width"], d = o["depth"], y = o["loft"]
    func zone(_ id: TextileAttachment.Zone, _ name: String, _ width: Double, _ height: Double,
              _ x: Double = 0, _ z: Double = 0, _ back: Bool = false, _ surface: Double? = nil) -> MerchandiseZone {
      .init(id: id, name: name, width: width, height: height, origin: .init(x, surface ?? (back ? 1 : y), z),
        right: .init(back ? -1 : 1, 0, 0), down: .init(0, 0, 1), normal: .init(0, back ? -1 : 1, 0))
    }
    switch o.recipeID {
    case "pulloverHoodie":
      // Chest is above the pocket. The back region is clear of the laid-out hood.
      return [zone(.front, "Chest above pocket", w * 0.6, d * 0.23, 0, -d * 0.12),
        zone(.back, "Back body", w * 0.65, d * 0.5, 0, d * 0.02, true),
        zone(.leftSide, "Left sleeve", o["sleeveLength"] * 0.4, o["sleeveWidth"] * 0.5, w / 2 + o["sleeveLength"] * 0.5, -d * 0.20),
        zone(.rightSide, "Right sleeve", o["sleeveLength"] * 0.4, o["sleeveWidth"] * 0.5, -w / 2 - o["sleeveLength"] * 0.5, -d * 0.20)]
    case "cuffedBeanie":
      return [zone(.front, "Front cuff", w * 0.64, o["cuffHeight"] * 0.64, 0, d / 2 - o["cuffHeight"] / 2, false, y + 3),
        zone(.back, "Back cuff", w * 0.64, o["cuffHeight"] * 0.64, 0, d / 2 - o["cuffHeight"] / 2, true),
        zone(.leftSide, "Left crown", w * 0.22, d * 0.25, w * 0.25, -d * 0.02),
        zone(.rightSide, "Right crown", w * 0.22, d * 0.25, -w * 0.25, -d * 0.02)]
    case "hemmedTextile":
      return [zone(.front, "Front cloth", w - o["hem"] * 4, d - o["hem"] * 4),
        zone(.back, "Reverse cloth", w - o["hem"] * 4, d - o["hem"] * 4, 0, 0, true),
        zone(.leftSide, "Left field", w * 0.2, d * 0.6, w * 0.3),
        zone(.rightSide, "Right field", w * 0.2, d * 0.6, -w * 0.3)]
    default: return []
    }
  }
}
