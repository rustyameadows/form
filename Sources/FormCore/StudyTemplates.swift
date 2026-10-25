import Foundation

public struct StudyTemplate: Identifiable, Sendable {
  public var id: String
  public var name: String
  public var title: String
  public var summary: String
  public var symbol: String
}
extension Samples {
  public static let templates: [StudyTemplate] = [
    .init(id:"fieldGuide",name:"ORBITAL / Field notes",title:"Instruction booklet",summary:"Illustrated pages and one flowing text story.",symbol:"book.closed"),
    .init(id: "flightJacket", name: "ORBITAL / Flight systems", title: "Flight bomber",
      summary: "A shaped blank, mission patches, and sewn labels.", symbol: "jacket"),
    .init(
      id: "clock", name: "Time, well spent", title: "Clock dial",
      summary: "One editable dial. Two physical clocks.", symbol: "clock"),
    .init(
      id: "cyanotype", name: "Sun studies", title: "Fold & print",
      summary: "Artwork, paper, and an unfolding package.", symbol: "shippingbox"),
    .init(
      id: "lamps", name: "Soft light", title: "Light & proportion",
      summary: "Explore a family of parametric lamps.", symbol: "lamp.desk"),
    .init(
      id: "forms", name: "Objects in good company", title: "Material & form",
      summary: "Compare clay, wood, and aluminum.", symbol: "cube"),
  ]
  public static func make(_ template: String) throws -> Project {
    switch template {
    case "blank": return Project(name: "Untitled study")
    case "clock": return clock()
    case "flightJacket": return flightJacket()
    case "fieldGuide":return try fieldGuide()
    case "cyanotype": return cyanotype()
    case "lamps": return lamps()
    case "forms": return studies()
    default: throw FormError.invalid("Unknown study template.")
    }
  }
  public static func clock() -> Project {
    var p = Project(
      name: "Time, well spent",
      subtitle: "A shared dial, two clocks, and the quiet pleasure of good type.")
    var original = try! p.makeObject(
      recipeID: "clock", name: "01 · Oak", materialID: "oak", position: .init(-280, 0, -25))
    var source = try! ClockDesign.source(for: original, in: p)
    source.name = "Dial / 01 · Shared artwork"
    source.position = .init(320, 0, 5)
    source.artwork?.canvasPosition = .init(36, 40)
    original.artworkSourceID = source.id
    original.artworkFit = "actual"
    original.rotation = -8
    var variant = original
    variant.id = UUID()
    variant.name = "02 · Graphite"
    variant.materialID = "graphite"
    variant.position = .init(20, 0, 30)
    variant.rotation = 7
    variant.relationship = "variant"
    p.objects = [original, variant, source]
    p.notes = [
      .init(
        "The two clocks share their dial document. Edit its numerals or signature to update both physical faces."
      ),
      .init(
        "Actual-size placement preserves typographic point sizes. Fit scales the artwork proportionally when the physical dial changes."
      ),
      .init(
        "The shaft opening is 8 mm and the dial is 6 mm thick. Confirm the actual movement, shaft length, clearances, and mounting before fabrication.",
        kind: "question"),
    ]
    p.camera.distance = 9
    p.camera.target = .init(0.2, 0.05, 0)
    p.camera.elevation = 0.99
    p.camera.azimuth = 0.22
    p.history = [.init("Created the linked clock-dial study.")]
    p.schemaVersion = 3
    return p
  }
}
