import Foundation

extension Recipe {
  public static let builtins: [Recipe] = [
    .init(
      "clock", "Clock", "clock",
      "A physical dial with shaft opening, linked typography, and adjustable hand positions.",
      [
        .init("diameter", "Dial diameter", 240, 80...500),
        .init("thickness", "Dial thickness", 6, 2...30, step: 0.5),
        .init("bore", "Shaft opening", 8, 2...18, step: 0.5),
        .init("hour", "Hour", 10, 1...12, unit: "h", step: 1),
        .init("minute", "Minute", 8, 0...59, unit: "min", step: 1),
        .init("hands", "Show hands", 1, 0...1, unit: "", step: 1),
      ]),
    .init(
      "artboard", "Artwork sheet", "square.and.pencil",
      "An independent vector artwork sheet on the Table.",
      [
        .init("width", "Width", 210, 1...1000, step: 0.1), .init("depth", "Height", 297, 1...1000, step: 0.1),
      ]),
    .init(
      "lamp", "Table lamp", "lamp.desk", "A shade, stem, and weighted base.",
      [
        .init("height", "Height", 350, 120...900),
        .init("shadeDiameter", "Shade diameter", 230, 80...500),
        .init("shadeHeight", "Shade height", 140, 40...300),
        .init("topDiameter", "Top opening", 85, 20...250),
        .init("baseDiameter", "Base diameter", 160, 60...350),
        .init("stemDiameter", "Stem diameter", 14, 6...40),
        .init("wall", "Wall thickness", 2, 0.5...8, step: 0.5),
      ]),
    .init(
      "paperStack", "Paper stack", "square.stack.3d.up", "Real sheet dimensions and count.",
      [
        .init("width", "Width", 203.2, 20...600, step: 0.1),
        .init("depth", "Height", 254, 20...800, step: 0.1),
        .init("sheets", "Sheet count", 20, 1...500, unit: "sheets"),
        .init("thickness", "Sheet thickness", 0.28, 0.05...2, step: 0.01),
      ]),
    .init(
      "booklet", "Booklet", "book.closed", "A bound booklet with editable cover artwork.",
      [
        .init("width", "Width", 105, 30...400), .init("depth", "Height", 148, 40...500),
        .init("pages", "Page count", 16, 4...240, unit: "pages", step: 4),
        .init("thickness", "Paper thickness", 0.12, 0.05...0.5, step: 0.01),
      ]),
    .init(
      "sleeve", "Folding sleeve", "shippingbox",
      "A scored wrap with a glue tab and a live dieline.",
      [
        .init("width", "Width", 216, 40...600), .init("depth", "Height", 275, 40...800),
        .init("height", "Spine depth", 15, 3...120),
        .init("stock", "Stock thickness", 0.45, 0.1...2, step: 0.05),
        .init("tab", "Glue tab", 18, 6...50), .init("fold", "Fold", 100, 0...100, unit: "%"),
      ]),
    .init(
      "box", "Box", "cube", "A rounded solid with three independent dimensions.",
      [
        .init("width", "Width", 140, 5...1000), .init("height", "Height", 100, 5...1000),
        .init("depth", "Depth", 140, 5...1000), .init("corner", "Corner radius", 3, 0...40),
      ],
      parts: [
        .init(
          "box",
          [
            "width": "width", "height": "height", "depth": "depth", "y": "height/2",
            "corner": "corner",
          ])
      ]),
    .init(
      "cylinder", "Cylinder", "cylinder", "A circular solid for components and studies.",
      [
        .init("diameter", "Diameter", 100, 5...600), .init("height", "Height", 160, 2...1000),
      ], parts: [.init("cylinder", ["radius": "diameter/2", "height": "height", "y": "height/2"])]),
    .init(
      "profile", "Extruded profile", "hexagon",
      "An extruded polygon for components and profile studies.",
      [
        .init("width", "Width", 140, 10...600), .init("depth", "Depth", 120, 10...600),
        .init("height", "Extrusion", 50, 1...600),
        .init("sides", "Sides", 6, 3...12, unit: "sides"),
      ]),
    .init(
      "vase", "Vessel", "waterbottle", "A hollow revolved profile with a rounded silhouette.",
      [
        .init("height", "Height", 240, 40...600), .init("diameter", "Body diameter", 150, 30...400),
        .init("neck", "Opening diameter", 65, 15...250), .init("wall", "Wall thickness", 4, 1...15),
      ]),
    .init(
      "swatch", "Material swatch", "square.on.square",
      "A physical sample from your Studio Library.",
      [
        .init("width", "Width", 75, 20...200), .init("depth", "Height", 75, 20...200),
        .init("height", "Thickness", 3, 0.1...30, step: 0.1),
      ],
      parts: [
        .init(
          "box",
          ["width": "width", "height": "height", "depth": "depth", "y": "height/2", "corner": "2"])
      ]),
    .init(
      "reference", "Image reference", "photo", "An image placed on the Table at physical scale.",
      [
        .init("width", "Width", 210, 20...1000), .init("depth", "Height", 148, 20...1000),
      ]),
  ]
}

public enum Samples {
  public static func cyanotype() -> Project {
    var project = Project(
      name: "Sun studies", subtitle: "A cyanotype kit, made for a little wonder.")
    var sleeve = try! project.makeObject(
      recipeID: "sleeve", name: "Printed folding sleeve", materialID: "cobalt",
      position: .init(-150, 0, 15))
    sleeve.artwork = .cyanotype
    sleeve.rotation = -8
    let paper = try! project.makeObject(
      recipeID: "paperStack", name: "Sensitized paper · 20 sheets", materialID: "chalk",
      position: .init(145, 0, -30))
    var booklet = try! project.makeObject(
      recipeID: "booklet", name: "Field notes & instructions", materialID: "kraft",
      position: .init(100, 8, 135))
    booklet.rotation = 12
    booklet.artwork = .init(
      background: "#D8C7A5",
      elements: [
        .init(
          kind: "text", x: 12, y: 20, width: 85, height: 40, text: "Chasing\nthe sun.",
          color: "#384234", fontSize: 16),
        .init(
          kind: "text", x: 12, y: 123, width: 85, height: 15, text: "A FIELD GUIDE",
          color: "#384234", fontSize: 7),
      ])
    project.objects = [sleeve, paper, booklet]
    for (i, material) in ["cobalt", "chalk", "kraft"].enumerated() {
      project.objects.append(
        try! project.makeObject(
          recipeID: "swatch", name: project.material(material).name,
          parameters: ["width": 45, "depth": 45, "height": 2], materialID: material,
          position: .init(-240 + Double(i) * 62, 0, 230)))
    }
    project.notes = [
      .init("The kit contains twenty 8 × 10 inch sheets."),
      .init("Paper should feel substantial. Avoid visible plastic."),
      .init("Confirm clearance after testing the final paper stock.", kind: "question"),
    ]
    project.history = [.init("Created the cyanotype kit study.")]
    project.camera.distance = 9
    project.camera.elevation = 0.91
    return project
  }
  public static func lamps() -> Project {
    var project = Project(
      name: "Soft light", subtitle: "A study in warmth, proportion, and everyday objects.")
    let original = try! project.makeObject(
      recipeID: "lamp", name: "01 · Vermilion", materialID: "vermillion",
      position: .init(-245, 0, 0))
    project.objects = [original]
    for (i, material) in ["butter", "sage"].enumerated() {
      var lamp = try! project.makeObject(
        recipeID: "lamp", name: "0\(i+2) · \(project.material(material).name)",
        parameters: ["height": i == 0 ? 300 : 390, "shadeDiameter": i == 0 ? 245 : 210],
        materialID: material, position: .init(Double(i) * 250, 0, i == 0 ? 70 : -35))
      lamp.designID = original.designID
      lamp.relationship = "variant"
      project.objects.append(lamp)
    }
    project.camera.distance = 12
    project.camera.elevation = 0.51
    project.camera.target.y = 1.4
    project.notes = [
      .init("Soft, downward light with no exposed bulb."),
      .init("Explore a powder-coated aluminum shade."),
    ]
    return project
  }
  public static func studies() -> Project {
    var project = Project(
      name: "Objects in good company", subtitle: "Material, volume, and a few happy accidents.")
    project.objects = [
      try! project.makeObject(
        recipeID: "vase", name: "Terracotta vessel", materialID: "clay", position: .init(-180, 0, 0)
      ),
      try! project.makeObject(
        recipeID: "box", name: "Oak volume",
        parameters: ["width": 160, "height": 120, "depth": 180, "corner": 2], materialID: "oak",
        position: .init(75, 0, 45)),
      try! project.makeObject(
        recipeID: "cylinder", name: "Aluminum study", parameters: ["diameter": 75, "height": 190],
        materialID: "aluminum", position: .init(240, 0, -100)),
    ]
    project.camera.distance = 10
    return project
  }
}
