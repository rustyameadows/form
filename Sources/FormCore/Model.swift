import Foundation
import FormMeshAssets
import FormCADModel

public struct Vector3: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var z: Double
  public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
    self.x = x
    self.y = y
    self.z = z
  }
}

public struct Parameter: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var unit: String
  public var minimum: Double
  public var maximum: Double
  public var step: Double
  public var value: Double
  public init(
    _ id: String, _ name: String, _ value: Double, _ range: ClosedRange<Double>,
    unit: String = "mm", step: Double = 1
  ) {
    self.id = id
    self.name = name
    self.value = value
    minimum = range.lowerBound
    maximum = range.upperBound
    self.unit = unit
    self.step = step
  }
}

public struct Material: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var category: String
  public var color: String
  public var roughness: Double
  public var metallic: Double
  public var thickness: Double
  public var fabric: FabricProfile?
  public var paperStock: PaperStock?
  public var appearance: PhysicalAppearance?
  public var backSurface: MaterialSurfaceResponse?
  public var references: [MaterialReference]?
  public init(
    _ id: String, _ name: String, _ category: String, _ color: String, roughness: Double = 0.65,
    metallic: Double = 0, thickness: Double = 0.3
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.color = color
    self.roughness = roughness
    self.metallic = metallic
    self.thickness = thickness
  }
  public static let presets: [Material] = [
    .init("cobalt", "Cyanotype blue", "Paper", "#224B9B", roughness: 0.86),
    .init("chalk", "Warm white", "Paper", "#EDE8DA", roughness: 0.93),
    .init("kraft", "Natural kraft", "Paper", "#B49A71", roughness: 0.98, thickness: 0.45),
    .init("vermillion", "Vermilion", "Powder coat", "#D45A37", roughness: 0.42),
    .init("sage", "Sage", "Powder coat", "#849381", roughness: 0.52),
    .init("butter", "Butter", "Powder coat", "#DCCB83", roughness: 0.48),
    .init("graphite", "Graphite", "Metal", "#353B3C", roughness: 0.36, metallic: 0.6),
    .init("aluminum", "Brushed aluminum", "Metal", "#BFC4C6", roughness: 0.29, metallic: 0.92),
    .init("oak", "Pale oak", "Wood", "#CDAE7D", roughness: 0.78, thickness: 18),
    .init("clay", "Unglazed clay", "Ceramic", "#B57860", roughness: 0.92, thickness: 4),
    .init("linen", "Natural linen", "Fabric", "#D4CDBB", roughness: 1, thickness: 0.8),
    .init("petg", "Frosted PETG", "Plastic", "#C4D6D3", roughness: 0.48, thickness: 1.2),
    .init("paper-superfine", "Uncoated white paper", "Paper", "#F7F5EF", roughness:0.94, metallic:0, thickness:0.35),
  ] + TextileDesign.materials
}

public struct ArtworkElement: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var kind: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var text: String
  public var color: String
  public var fontSize: Double
  public var fillSwatchID: UUID?
  public var asset: String?
  public var imageCrop: ImageCrop?
  public var imageAdjustments: ImageAdjustments?
  public var name: String?
  public var rotation: Double?
  public var transformOrigin: Point2?
  public var opacity: Double?
  public var blendMode: String?
  public var isolatedBlending: Bool?
  public var blur: ArtworkBlur?
  public var shadow: ArtworkShadow?
  public var hidden: Bool?
  public var locked: Bool?
  public var parentID: UUID?
  public var contentSize: Point2?
  public var affine: Affine2?
  public var flipX: Bool?
  public var flipY: Bool?
  public var fillEnabled: Bool?
  public var fillOpacity: Double?
  public var paintStack: [ArtworkPaintLayer]?
  public var effectStack: ArtworkEffectStack?
  public var booleanOperation: String?
  public var component: ArtworkComponentReference?
  public var stroke: ArtworkStroke?
  public var gradient: ArtworkGradient?
  public var cornerRadius: Double?
  public var sides: Int?
  public var starInset: Double?
  public var path: VectorPath?
  public var typography: Typography?
  public var textStyle: TextStyleReference?
  public var paragraphStyle: TextStyleReference?
  public var textRuns: [TextSpan]?
  public var glyphOverrides: [GlyphOverride]?
  public var listItems: [ParagraphListItem]?
  public var storyFrame: StoryFrameReference?
  public var productionRole: String?
  public var sewingPiece: SewingPatternPiece?
  public var clipID: UUID?
  public var clipMode: String?
  /// Original node settings for interoperability/recovery; native fields remain authoritative after edits.
  public var sourceMetadata: ArtworkSourceMetadata?
  public var imageGeneration: CanvasImageGenerationProvenance?
  public var objectView: ObjectViewSettings?
  public init(
    kind: String, x: Double, y: Double, width: Double = 60, height: Double = 30, text: String = "",
    color: String = "#FFFFFF", fontSize: Double = 14, asset: String? = nil
  ) {
    self.kind = kind
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.text = text
    self.color = color
    self.fontSize = fontSize
    self.asset = asset
  }
}

public struct Artwork: Codable, Equatable, Sendable {
  public var background: String
  public var outputColorProfile: ArtworkOutputProfile?
  /// Derived surface guard only; never encoded or used in visual signatures.
  public var requiresInkOutput=false
  private enum CodingKeys:String,CodingKey {
    case background,outputColorProfile,sewingSeams,sewingLayout,sewingTiles,language,elements,bleed,safeInset,unit,guides,gridSpacing,showGrid,snapEnabled,nudge,showGuides,canvasPosition,boundary,backgroundOpacity,backgroundSwatchID,imports
  }
  public var sewingSeams: [SewingSeam]?
  public var sewingTiles: SewingTileOptions?
  public var sewingLayout: SewingCutLayout?
  public var language: String?
  public var elements: [ArtworkElement]
  public var bleed: Double
  /// Optional declared inward rectangular safety guide; omitted for legacy pages.
  public var safeInset:Double?
  public var unit: PhysicalUnit?
  public var guides: [ArtworkGuide]?
  public var gridSpacing: Double?
  public var showGrid: Bool?
  public var snapEnabled: Bool?
  public var nudge: Double?
  public var showGuides: Bool?
  public var canvasPosition: Point2?
  public var boundary: VectorPath?
  public var backgroundOpacity: Double?
  public var backgroundSwatchID: UUID?
  public var imports: [ArtworkImport]?
  public init(background: String = "#224B9B", elements: [ArtworkElement] = [], bleed: Double = 3) {
    self.background = background
    self.elements = elements
    self.bleed = bleed
  }
  public static var cyanotype: Artwork {
    .init(elements: [
      .init(
        kind: "text", x: 18, y: 22, width: 180, height: 12, text: "EXPERIMENTS IN LIGHT  /  NO. 01",
        fontSize: 9),
      .init(
        kind: "text", x: 16, y: 49, width: 180, height: 72, text: "Sun\nstudies.", fontSize: 64),
      .init(
        kind: "text", x: 18, y: 133, width: 175, height: 20,
        text: "A little light. Endless possibility.", fontSize: 12),
      .init(kind: "ellipse", x: 122, y: 160, width: 65, height: 65, color: "#E4D8A9"),
      .init(
        kind: "text", x: 18, y: 241, width: 185, height: 25, text: "CYANOTYPE KIT  /  20 SHEETS",
        fontSize: 9),
    ])
  }
}

public struct ProductObject: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var name: String
  public var recipeID: String
  public var parameters: [String: Double]
  public var materialID: String
  public var color: String?
  public var position: Vector3
  public var rotation: Double
  public var groupID: UUID?
  public var designID: UUID
  public var parentIterationID: UUID?
  public var relationship: String
  public var artwork: Artwork?
  public var artworkParameterBindings:[ArtworkParameterBinding]?
  public var dimensionBindings:[PhysicalDimensionBinding]?
  public var artworkRegions:[PhysicalArtworkRegion]?
  public var artworkSourceID: UUID?
  public var artworkFit: String?
  public var componentDefinition: Bool?
  public var canvasWorkspace: Bool?
  public var asset: String?
  public var locked: Bool
  public var textile: TextileProduct?
  public var cloth: ClothStudy?
  public var clothAttachment: ClothAttachment?
  public var patternAssembly:PatternAssemblyDefinition?
  public var patternAssemblyAttachment:PatternAssemblyAttachment?
  public var librarySelection: ObjectLibrarySelection?
  public var meshAsset: MeshAssetReference?
  public var cadModel: CADModelDefinition?
  public var cadRepresentation: CADRepresentation?
  public var paperConstruction:PaperConstruction?
  public var sheetAssembly:SheetAssemblyDefinition?
  public var paperTemplateReference:PaperTemplateReference?
  public var canvasSourceOnly:Bool?
  public var canvasProjectionPositions:[String:Point2]?
  public var surfaceArtworkBindings:[PhysicalSurfaceArtworkBinding]?
  public var physicalArtworkIntents:[PhysicalArtworkIntent]?
  public init(
    name: String, recipeID: String, parameters: [String: Double], materialID: String = "chalk",
    position: Vector3 = .init(), rotation: Double = 0, artwork: Artwork? = nil
  ) {
    self.name = name
    self.recipeID = recipeID
    self.parameters = parameters
    self.materialID = materialID
    self.position = position
    self.rotation = rotation
    self.artwork = artwork
    designID = UUID()
    relationship = "original"
    locked = false
  }
  public subscript(_ key: String) -> Double { parameters[key] ?? 0 }
  public var footprintWidth: Double {
    if PaperConstruction.isPaper(self),let source=try? PaperConstruction.definition(for:self){return source.foldPercent==0 ? ((try? source.net().size.x) ?? source.dimensions.width):source.dimensions.width+2*source.stock.thicknessMM}
    if let meshAsset {return meshAsset.boundsMM.size.x * max(0.001,self["scalePercent"]/100)}
    if let cadRepresentation {return cadRepresentation.maximum.x-cadRepresentation.minimum.x}
    if recipeID=="pulloverHoodie" {return self["width"]+self["sleeveLength"]*2}
    if recipeID=="crewTee" {return self["width"]+self["sleeveLength"]*2}
    if recipeID=="curvedCap" {return max(self["width"],self["brimWidth"])}
    return max(self["width"], self["shadeDiameter"], self["baseDiameter"], self["diameter"], 100)
  }
  public var footprintDepth: Double {
    if PaperConstruction.isPaper(self),let source=try? PaperConstruction.definition(for:self){return source.foldPercent==0 ? ((try? source.net().size.y) ?? source.dimensions.height):source.dimensions.depth+2*source.stock.thicknessMM}
    if let meshAsset {return meshAsset.boundsMM.size.z * max(0.001,self["scalePercent"]/100)}
    if let cadRepresentation {return cadRepresentation.maximum.z-cadRepresentation.minimum.z}
    if recipeID=="pulloverHoodie" {return self["depth"]+self["hoodHeight"]}
    if recipeID=="curvedCap" {return self["width"]+self["depth"]}
    if recipeID=="canvasTote" {return self["depth"]+self["handleDrop"]}
    return max(self["depth"], self["shadeDiameter"], self["baseDiameter"], self["diameter"], 100)
  }
}

public struct PartDefinition: Codable, Equatable, Sendable {
  public var kind: String
  public var values: [String: String]
  public var color: String?
  public init(_ kind: String, _ values: [String: String], color: String? = nil) {
    self.kind = kind
    self.values = values
    self.color = color
  }
  public func evaluate(_ parameters: [String: Double]) throws -> [String: Double] {
    try values.mapValues { try Expression.evaluate($0, variables: parameters) }
  }
}

public struct Recipe: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var symbol: String
  public var summary: String
  public var parameters: [Parameter]
  public var parts: [PartDefinition]
  public var requirements: [CADModelRequirement]?
  public var solid: ParametricSolid?
  public init(
    _ id: String, _ name: String, _ symbol: String, _ summary: String, _ parameters: [Parameter],
    parts: [PartDefinition] = [], requirements: [CADModelRequirement]? = nil, solid: ParametricSolid? = nil
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.summary = summary
    self.parameters = parameters
    self.parts = parts
    self.requirements = requirements
    self.solid = solid
  }
  public var defaults: [String: Double] {
    Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.value) })
  }
  public func validate(_ values: [String: Double]) throws {
    for (key, value) in values {
      guard let parameter = parameters.first(where: { $0.id == key }) else {
        throw FormError.invalid("Unknown parameter '\(key)' for \(name).")
      }
      guard value.isFinite, value >= parameter.minimum, value <= parameter.maximum else {
        throw FormError.invalid(
          "\(parameter.name) must be between \(parameter.minimum) and \(parameter.maximum) \(parameter.unit)."
        )
      }
    }
    let all = defaults.merging(values) { _, new in new }
    guard (requirements?.count ?? 0)<=128,Set((requirements ?? []).map(\.id)).count==(requirements?.count ?? 0) else {
      throw FormError.invalid("Recipe parameter requirements must have unique bounded identities.")
    }
    for requirement in requirements ?? [] {try requirement.validate(using:all)}
    if let solid {try solid.validateDefinitions(all)}
    for parameter in parameters where ["sheets", "pages"].contains(parameter.unit) {
      guard all[parameter.id]!.rounded() == all[parameter.id]! else {
        throw FormError.invalid("\(parameter.name) must be a whole number.")
      }
    }
    if id == "lamp" {
      guard let height = all["height"], let shadeHeight = all["shadeHeight"],
        let top = all["topDiameter"], let wall = all["wall"]
      else { throw FormError.invalid("Lamp recipe parameters are incomplete.") }
      guard height >= shadeHeight + 30 else {
        throw FormError.invalid("Lamp height must leave at least 30 mm below the shade.")
      }
      guard top > wall * 2 else {
        throw FormError.invalid("The top opening must exceed twice the shade's wall thickness.")
      }
    }
    if id == "vase" {
      guard let neck = all["neck"], let wall = all["wall"], neck / 2 > wall else {
        throw FormError.invalid("Vessel walls must leave an open neck.")
      }
    }
    if ["clock","deskClock"].contains(id) {
      for key in ["hour", "minute", "hands"] {
        guard let value = all[key], value.isFinite, value.rounded() == value else {
          throw FormError.invalid("Clock time and hand visibility require whole values.")
        }
      }
    }
    for part in parts {
      let evaluated = try part.evaluate(all)
      for (key, value) in evaluated {
        guard value.isFinite, abs(value) <= 100_000 else {
          throw FormError.invalid("Part value '\(key)' exceeds the supported size.")
        }
        if [
          "width", "height", "depth", "radius", "topRadius", "bottomRadius", "ringRadius",
          "pipeRadius", "corner",
        ].contains(key),
          value < 0
        {
          throw FormError.invalid("Part dimension '\(key)' cannot be negative.")
        }
      }
    }
  }
}

public struct ProjectNote: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var text: String
  public var kind: String
  public var resolved: Bool = false
  public init(_ text: String, kind: String = "decision") {
    self.text = text
    self.kind = kind
  }
}

public struct ProjectEvent: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var date = Date()
  public var source: String
  public var text: String
  public init(_ text: String, source: String = "Studio") {
    self.text = text
    self.source = source
  }
}

public struct CameraState: Codable, Equatable, Sendable {
  public var azimuth: Double = 0.55
  public var elevation: Double = 0.70
  public var orientation: CameraOrientation?
  public var distance: Double = 12
  public var target: Vector3 = .init(0, 0.6, 0)
  public var projection: String = "perspective"
  public var viewportAspect: Double?
  public init() {}
}

public struct Equipment: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var width: Double
  public var height: Double
  public var format: String
  public init(_ name: String, width: Double, height: Double, format: String) {
    self.name = name
    self.width = width
    self.height = height
    self.format = format
  }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
  public static let maximumSchemaVersion=67
  public var schemaVersion = 1
  public var renderSettings:CyclesRenderSettings?
  public var id: UUID = UUID()
  public var name: String
  public var subtitle: String
  public var createdAt: Date = Date()
  public var updatedAt: Date = Date()
  public var objects: [ProductObject] = []
  public var recipes: [Recipe] = []
  public var materials: [Material] = []
  public var notes: [ProjectNote] = []
  public var history: [ProjectEvent] = []
  public var camera: CameraState = .init()
  public var unit: String = "mm"
  public var conversationReference: String?
  public var printSetups: [String: PrintConfiguration]?
  public var swatches: [ArtworkSwatch]?
  public var textStyles: [ArtworkTextStyle]?
  public var fontLibrary: ProjectFontLibrary?
  public var textStories:[TextStory]?
  public var publications:[PublicationDocument]?
  public var productionJobs:[ProductionJob]?
  public var studioPresentation: StudioPresentation?
  public var decorationPreparations:[DecorationPreparation]?
  public var garmentBlocks:[GarmentBlock]?
  public var collectionProduction:CollectionProduction?
  public var minimumSchemaVersion: Int {
    // The schema is monotonic. No supported feature can raise this floor.
    if schemaVersion>=Self.maximumSchemaVersion {return schemaVersion}
    var required=max(schemaVersion,requiredResourceSchemaVersion)
    if required>=Self.maximumSchemaVersion {return required}
    // ProductObject is a wide value. Read each row once rather than copying
    // every row again for each historical schema predicate.
    for object in objects {
      required=max(required,object.requiredObjectSchemaVersion)
      if required>=Self.maximumSchemaVersion {return required}
    }
    return required
  }
  private var requiredResourceSchemaVersion:Int {
    if materials.contains(where:{$0.paperStock?.usesCutEdgeAppearance == true}) {return 67}
    if renderSettings != nil || materials.contains(where:{$0.usesPhysicalAppearance}) || studioPresentation?.shots.contains(where:{$0.renderSettings != nil}) == true || studioPresentation?.scenes?.contains(where:{$0.renderSettings != nil}) == true {return 66}
    if studioPresentation?.scenes?.contains(where:{$0.instances.contains(where:{$0.sheetPose?.bindingStyle == .adhesive || $0.sheetPose?.bindingStyle == .sewn})}) == true {return 65}
    if textStories?.contains(where:{$0.annotations?.isEmpty==false})==true {return 64}
    if publications?.contains(where:{$0.requiresExtendedPublicationSchema}) == true {return 63}
    if recipes.contains(where:{$0.solid != nil}) {return 62}
    if fontLibrary != nil {return 59}
    if textStories?.contains(where:{$0.paintStack != nil || $0.textRuns?.contains(where:{$0.paintStack != nil}) == true}) == true {return 58}
    if materials.contains(where:{$0.paperStock != nil}) {return 57}
    if recipes.contains(where:{$0.requirements?.isEmpty == false}) {return 55}
    if studioPresentation?.scenes?.isEmpty == false {return 54}
    if textStyles?.contains(where:{$0.typography.characterPosition != nil})==true || textStories?.contains(where:{$0.typography?.characterPosition != nil || $0.textRuns?.contains(where:{$0.typography.characterPosition != nil})==true})==true {return 47}
    if collectionProduction.map({!$0.plans.isEmpty || !$0.captures.isEmpty}) == true {return 45}
    if studioPresentation?.shots.isEmpty == false {return 43}
    if textStyles?.contains(where:{$0.typography.opticalSizing != nil})==true || textStories?.contains(where:{$0.typography?.opticalSizing != nil || $0.textRuns?.contains(where:{$0.typography.opticalSizing != nil})==true})==true {return 42}
    if garmentBlocks?.isEmpty == false {return 41}
    if decorationPreparations?.isEmpty==false {return 38}
    if swatches?.contains(where:{$0.printInk != nil})==true {return 35}
    if productionJobs?.isEmpty==false {return 29}
    if textStories?.isEmpty==false || publications?.isEmpty==false || textStyles?.contains(where:{$0.typography.alignToBaselineGrid != nil})==true {return 26}
    if materials.contains(where:{$0.fabric?.pattern != nil}) {return 21}
    if textStyles?.contains(where:{$0.typography.usesPublicationLanguage})==true {return 20}
    if materials.contains(where:{$0.fabric != nil}) {return 17}
    if camera.orientation != nil {return 16}
    if textStyles?.contains(where:{$0.typography.usesCustomTabs || $0.typography.hyphenation>0})==true {return 14}
    if textStyles?.contains(where:{$0.typography.kerningMode != nil})==true {return 13}
    if textStyles?.isEmpty == false {return 12}
    if swatches?.isEmpty == false {return 7}
    return 1
  }
  public init(name: String, subtitle: String = "A new place to make things.") {
    self.name = name
    self.subtitle = subtitle
  }
  public func recipe(_ id: String) -> Recipe? {
    recipes.first { $0.id == id } ?? Recipe.builtins.first { $0.id == id }
  }
  public func material(_ id: String) -> Material {
    materials.first { $0.id == id } ?? Material.presets.first { $0.id == id } ?? Material.presets[1]
  }
  public func makeObject(
    recipeID: String, name: String? = nil, parameters: [String: Double] = [:],
    materialID: String? = nil, position: Vector3 = .init()
  ) throws -> ProductObject {
    guard let recipe = recipe(recipeID) else {
      throw FormError.invalid(
        "Unknown recipe '\(recipeID)'. Use form_list_recipes to discover available recipes.")
    }
    try recipe.validate(parameters)
    var object = ProductObject(
      name: name ?? recipe.name, recipeID: recipeID,
      parameters: recipe.defaults.merging(parameters) { _, new in new }, materialID: materialID ?? MerchandiseBlanks.defaultMaterial(recipeID) ?? "chalk",
      position: position)
    if PaperConstruction.recipeIDs.contains(recipeID){object.paperConstruction=try PaperConstruction.definition(for:object);if materialID==nil{object.materialID="paper-superfine"}}
    object.textile = TextileProduct.defaults(for: recipeID)
    if ClothDesign.recipeIDs.contains(recipeID) {object.cloth = try ClothDesign.definition(for:object)}
    if recipeID=="textilePrint" {object.artwork=MerchandiseBlanks.blankArtwork(width:object["width"],height:object["depth"])}
    return object
  }
}

/// Each object's schema contribution retains the historical nil/empty and
/// canonical-versus-detached artwork distinctions. This is only feature
/// classification; document validation still runs through the editing engine.
extension ProductObject {
  fileprivate var requiredObjectSchemaVersion:Int {
    if usesPaperMateriality {return 67}
    if usesPhysicalAppearance {return 66}
    let paper=paperConstruction
    if dimensionBindings != nil || artworkRegions != nil || sheetAssembly?.requiresAdvancedStructureSchema == true || paper?.authored?.panels.contains(where:{$0.features != nil}) == true {return 65}
    if sheetAssembly != nil {return 63}
    // Only these high-version predicates historically include inside artwork,
    // detached surface artwork and frozen story snapshots.
    if artwork != nil || paper?.insideArtwork != nil || surfaceArtworkBindings?.isEmpty == false {
      let documents=storedArtworks
      if documents.contains(where:{$0.elements.contains(where:{$0.objectView != nil})}) {return 61}
      if documents.contains(where:{$0.elements.contains(where:{$0.imageGeneration != nil})}) {return 60}
      if documents.contains(where:{$0.elements.contains(where:{$0.sourceMetadata != nil || $0.paintStack != nil || $0.effectStack != nil || $0.clipMode != nil || ["angular","diamond"].contains($0.gradient?.kind ?? "") || $0.textRuns?.contains(where:{$0.paintStack != nil}) == true}) || $0.imports?.contains(where:{$0.elementIDs != nil || $0.format != nil}) == true}) {return 58}
    }
    if paperTemplateReference != nil || canvasSourceOnly != nil {return 57}
    if (paper?.authored?.version ?? 1)>=3 || paper?.authored?.components != nil || paper?.authored?.interiors != nil || paper?.authored?.panels.contains(where:{$0.cutouts != nil}) == true {return 57}
    if paper?.stock.profile != nil || paper?.stock.plies != nil || paper?.finishes != nil {return 57}
    if artworkParameterBindings != nil || physicalArtworkIntents != nil {return 56}
    if cadModel?.version ?? 1 > 1 {return 55}
    if paper?.authored != nil || canvasProjectionPositions != nil || surfaceArtworkBindings != nil {return 55}
    if PaperConstruction.isPaper(self) {return 53}
    if meshAsset != nil || cadModel != nil || cadRepresentation != nil {return 52}
    if librarySelection != nil || StarterTextiles.recipeIDs.contains(recipeID) {return 51}
    if recipeID=="deskClock" {return 50}
    let art=artwork
    if art?.safeInset != nil {return 49}
    if art?.requiresCharacterPositionSchema==true {return 47}
    if art?.requiresSchemaFortyTwo==true {return 42}
    if art?.elements.contains(where:{$0.sewingPiece?.hasConstructionMetadata == true}) == true {return 41}
    if art?.sewingTiles != nil {return 40}
    if patternAssembly != nil || patternAssemblyAttachment != nil || cloth?.preparation != nil {return 36}
    if MerchandiseBlanks.recipeIDs.contains(recipeID) || textile?.process == .directPrint || textile?.attachment.map({[TextileAttachment.Zone.front,.leftSide,.rightSide].contains($0.zone)}) == true {return 34}
    if art?.elements.contains(where:{element in
      guard let piece=element.sewingPiece else{return false}
      return SewingPatterns.needsGeneralGeometry(element) || piece.onFoldEdgeID != nil || piece.notches.contains(where:{$0.edgeID != nil})
    }) == true || art?.sewingSeams?.contains(where:{$0.first.edgeID != nil || $0.second.edgeID != nil}) == true {return 32}
    if cloth != nil || clothAttachment != nil {return 31}
    if art?.outputColorProfile != nil {return 30}
    if textile?.embroidery?.threads.contains(where:{$0.stock != nil})==true {return 29}
    if textile?.embroidery?.requiresSchemaTwentyEight == true {return 28}
    if art?.sewingLayout != nil {return 27}
    if art?.requiresSchemaTwentySix==true {return 26}
    if textile?.embroidery != nil {return 25}
    if art?.elements.contains(where:{$0.sewingPiece != nil}) == true || art?.sewingSeams?.isEmpty == false {return 24}
    if art?.elements.contains(where:{$0.listItems?.isEmpty == false}) == true {return 23}
    if art?.requiresSchemaTwentyTwo == true {return 22}
    if art?.requiresSchemaTwenty == true {return 20}
    if isCanvasWorkspace {return 19}
    if art?.requiresSchemaEighteen == true {return 18}
    if textile != nil || TextileDesign.recipeIDs.contains(recipeID) {return 17}
    if art?.requiresSchemaFifteen == true {return 15}
    if art?.requiresSchemaFourteen == true {return 14}
    if art?.requiresSchemaThirteen == true {return 13}
    if art?.referencedTextStyles.isEmpty == false {return 12}
    if art?.requiresSchemaEleven == true {return 11}
    if art?.requiresSchemaTen == true {return 10}
    if art?.requiresSchemaNine == true {return 9}
    if art?.requiresSchemaEight == true {return 8}
    if art?.referencedSwatches.isEmpty == false {return 7}
    if componentDefinition == true || art?.elements.contains(where:{$0.component != nil}) == true {return 6}
    if art?.requiresSchemaFive == true {return 5}
    if art?.requiresSchemaFour == true {return 4}
    if artworkSourceID != nil || recipeID=="clock" || art?.boundary != nil {return 3}
    if art?.usesExtendedFormat == true {return 2}
    return 1
  }
}

public enum FormError: LocalizedError {
  case invalid(String)
  case missing(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let message), .missing(let message): return message
    }
  }
}

public enum FormPaths {
  public static var library: URL {
    if let path = LabIdentity.libraryOverride() {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(LabIdentity.libraryDirectory, isDirectory: true)
  }
  public static var socket: String {
    LabIdentity.socketOverride() ?? "/tmp/form-\(getuid()).sock"
  }
}

extension JSONEncoder {
  public static var form: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
extension JSONDecoder {
  public static var form: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
public func jsonObject<T: Encodable>(_ value: T) throws -> Any {
  try JSONSerialization.jsonObject(with: JSONEncoder.form.encode(value))
}
