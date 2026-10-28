import Foundation

extension Samples {
  public static func merchandiseCollection() throws -> Project {
    var p = Project(
      name: "ORBITAL / Field collection",
      subtitle: "Original NASA-inspired editable art on three generic merchandise blanks.")
    let flight = flightJacket()
    let badge = flight.objects.first { $0.name == "Artwork / ORBITAL mission" }!.artwork!
    var tape = flight.objects.first { $0.name == "Artwork / NASA flight research" }!.artwork!
    if let i = tape.elements.firstIndex(where: { $0.text == "NASA" }) {
      tape.elements[i].fontSize = 60
      tape.elements[i].y = 0
      tape.elements[i].height = 25
    }
    if let i = tape.elements.firstIndex(where: { $0.text == "FLIGHT RESEARCH" }) {
      tape.elements[i].y = 26
      tape.elements[i].height = 7
      tape.elements[i].fontSize = 8
    }
    var label = flight.objects.first { $0.name == "Artwork / sewn flight label" }!.artwork!
    for i in label.elements.indices {
      if label.elements[i].text == "ORBITAL PROGRAM  ·  M" {
        label.elements[i].text = "ORBITAL / FIELD COLLECTION"
      }
      if label.elements[i].text == "CONCEPT SAMPLE / 001" {
        label.elements[i].text = "CONCEPT COLLECTION / 034"
      }
    }
    var mark = Artwork(background: "#FFFFFF", elements: [], bleed: 0)
    mark.backgroundOpacity = 0
    func type(
      _ value: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double, _ size: Double,
      _ color: String
    ) -> ArtworkElement {
      var e = ArtworkElement(
        kind: "text", x: x, y: y, width: width, height: height, text: value, color: color,
        fontSize: size)
      var t = Typography()
      t.fontName = "HelveticaNeue-CondensedBlack"
      t.alignment = "center"
      e.typography = t
      return e
    }
    mark.elements = [
      type("NASA", 0, 0, 220, 92, 160, "#15324B"),
      type("ORBITAL FIELD DIVISION", 0, 94, 220, 15, 25, "#15324B"),
      type("EXPLORATION / SYSTEMS / 034", 0, 165, 220, 12, 13, "#15324B"),
    ]
    var orbit = ArtworkElement(
      kind: "ellipse", x: 18, y: 116, width: 184, height: 36, color: "#FFFFFF")
    orbit.fillEnabled = false
    orbit.stroke = .init(color: "#C7573B", width: 2)
    orbit.rotation = -12
    mark.elements.append(orbit)
    var star = ArtworkElement(kind: "star", x: 98, y: 126, width: 24, height: 24, color: "#C7573B")
    star.sides = 4
    mark.elements.append(star)
    func source(_ name: String, _ size: Point2, _ art: Artwork, _ x: Double) -> ProductObject {
      var o = try! p.makeObject(
        recipeID: "artboard", name: name, parameters: ["width": size.x, "depth": size.y],
        position: .init(x, 0, 700))
      o.artwork = art
      return o
    }
    let markSource = source("Artwork / ORBITAL field division", .init(220, 180), mark, -800)
    let badgeSource = source("Artwork / shared mission roundel", .init(90, 90), badge, -500)
    let tapeSource = source("Artwork / shared NASA flight research", .init(118, 34), tape, -300)
    let labelSource = source("Artwork / shared collection label", .init(90, 32), label, -100)
    let tee = try p.makeObject(
      recipeID: "crewTee", name: "01 / Crew-neck jersey", materialID: "jersey-ecru",
      position: .init(-590, 0, 0))
    var cap = try p.makeObject(
      recipeID: "curvedCap", name: "02 / Curved-front field cap", materialID: "merch-twill",
      position: .init(280, 0, -400))
    cap.rotation = 180
    let tote = try p.makeObject(
      recipeID: "canvasTote", name: "03 / Canvas field tote", materialID: "merch-canvas",
      position: .init(360, 0, 360))
    p.objects = [tee, cap, tote, markSource, badgeSource, tapeSource, labelSource]
    func decoration(
      _ name: String, _ recipe: String, _ size: Point2, _ source: ProductObject,
      _ host: ProductObject, _ zone: TextileAttachment.Zone, _ offset: Point2 = .init()
    ) -> ProductObject {
      var o = try! p.makeObject(
        recipeID: recipe, name: name, parameters: ["width": size.x, "depth": size.y],
        materialID: recipe == "textilePatch"
          ? "patch-twill" : recipe == "textilePrint" ? "merch-ink" : "label-ecru")
      o.artwork = nil
      o.artworkSourceID = source.id
      o.artworkFit = "fit"
      o.textile?.attachment = .init(
        garmentID: host.id, zone: zone, offset: offset, clearance: recipe == "textilePrint" ? 0 : 1)
      return o
    }
    p.objects += [
      decoration(
        "Tee / field-division direct art", "textilePrint", .init(240, 200), markSource, tee, .front,
        .init(0, 60)),
      decoration(
        "Tee / left chest mission patch", "textilePatch", .init(100, 100), badgeSource, tee,
        .leftChest),
      decoration(
        "Tee / independent back signature", "textilePrint", .init(118, 34), tapeSource, tee, .back),
      decoration("Tee / sewn neck label", "textileLabel", .init(90, 32), labelSource, tee, .collar),
      decoration(
        "Cap / conforming NASA front art", "textilePrint", .init(96, 30), tapeSource, cap, .front),
      decoration(
        "Cap / independent back signature", "textilePrint", .init(64, 16), tapeSource, cap, .back),
      decoration(
        "Tote / direct field-division artwork", "textilePrint", .init(220, 180), markSource, tote,
        .front),
      decoration(
        "Tote / independent back roundel", "textilePrint", .init(150, 150), badgeSource, tote, .back
      ),
      decoration(
        "Tote / sewn inside label", "textileLabel", .init(90, 24), labelSource, tote, .collar),
      decoration(
        "Tote / left gusset label", "textileLabel", .init(90, 32), labelSource, tote, .leftSide),
    ]
    if let side = p.objects.firstIndex(where: { $0.name == "Tote / left gusset label" }) {
      p.objects[side].textile?.attachment?.rotation = 90
    }
    p.notes = [
      .init(
        "Original NASA-inspired editable collection artwork; generic concept blanks and material declarations, with no supplier, standard-size or verified-fit claim."
      ),
      .init(
        "Each physical decoration remains an independent linked artwork object. Show back turns over the flat-lay tee or tote with every attached region; orbit the cap to inspect its curved front/back/side surfaces."
      ),
      .init(
        "These are presentation blanks. Sewing source patterns and cloth-simulation studies are separate until explicitly connected and tested."
      ),
    ]
    p.camera.distance = 28
    p.camera.elevation = 0.95
    p.camera.azimuth = 0.25
    p.camera.target = .init(-1, 0.2, 1.8)
    p.schemaVersion = p.minimumSchemaVersion
    try p.validateArtworkLinks()
    return p
  }
}
