import Foundation

/// Historical source identity, not a live artwork link. References may be moved
/// or removed later without invalidating a generated image's provenance.
public struct CanvasImageGenerationReferenceMetadata: Codable, Equatable, Sendable {
  public var id: UUID
  public var sourceProjectID: UUID
  public var objectID: UUID
  public var elementIDs: [UUID]
  public var name: String
  public var role: String
  public var sourceSHA256: String
  public var renderedSHA256: String
  public init(id: UUID = UUID(), sourceProjectID: UUID, objectID: UUID, elementIDs: [UUID] = [],
    name: String, role: String = "composition", sourceSHA256: String, renderedSHA256: String) {
    self.id = id; self.sourceProjectID = sourceProjectID; self.objectID = objectID
    self.elementIDs = elementIDs; self.name = name; self.role = role
    self.sourceSHA256 = sourceSHA256; self.renderedSHA256 = renderedSHA256
  }
}

public struct CanvasImageGenerationProvenance: Codable, Equatable, Sendable {
  public static let maximumBytes = 512 * 1024
  public var version = 1
  public var id: UUID
  public var createdAt: Date
  public var prompt: String
  public var model: String
  public var provider: String
  public var isDemo: Bool
  public var settings: [String: String]
  public var references: [CanvasImageGenerationReferenceMetadata]
  public var outputSHA256: String
  public var pixelWidth: Int
  public var pixelHeight: Int
  public init(id: UUID = UUID(), createdAt: Date = Date(), prompt: String, model: String,
    provider: String, isDemo: Bool, settings: [String: String],
    references: [CanvasImageGenerationReferenceMetadata] = [], outputSHA256: String,
    pixelWidth: Int, pixelHeight: Int) {
    self.id = id; self.createdAt = createdAt; self.prompt = prompt; self.model = model
    self.provider = provider; self.isDemo = isDemo; self.settings = settings; self.references = references
    self.outputSHA256 = outputSHA256; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
  }
  public static func validPrompt(_ value: String) -> Bool {
    value.utf8.count <= 32_000 && value.count <= 8_000
      && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  public func validate() throws {
    func bounded(_ value: String, _ characters: Int, _ bytes: Int) -> Bool {
      value.utf8.count <= bytes && value.count <= characters
    }
    func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII } }
    guard version == 1, createdAt.timeIntervalSince1970.isFinite, Self.validPrompt(prompt),
      !model.isEmpty, bounded(model, 200, 800), !provider.isEmpty, bounded(provider, 200, 800),
      settings.count <= 32, settings.allSatisfy({ !$0.key.isEmpty && bounded($0.key, 128, 512) && bounded($0.value, 4_000, 16_000) }),
      references.count <= 8, Set(references.map(\.id)).count == references.count,
      (1...8_192).contains(pixelWidth), (1...8_192).contains(pixelHeight), hash(outputSHA256) else {
      throw FormError.invalid("Image generation provenance must contain bounded prompt, model, settings, dimensions and unique references.")
    }
    for reference in references {
      guard !reference.name.isEmpty, bounded(reference.name, 500, 2_000),
        ["composition", "subject", "style"].contains(reference.role), reference.elementIDs.count <= 5_000,
        Set(reference.elementIDs).count == reference.elementIDs.count,
        hash(reference.sourceSHA256), hash(reference.renderedSHA256) else {
        throw FormError.invalid("Generated-image references must retain a bounded name, selection and content hashes.")
      }
    }
    guard try JSONEncoder.form.encode(self).count <= Self.maximumBytes else {
      throw FormError.invalid("Image generation provenance exceeds its 512 KiB limit.")
    }
  }
}

/// A destination snapshot protects user's later edits while allowing the board
/// to be moved or renamed during a generation.
public struct CanvasImageGenerationDestination: Equatable, Sendable {
  public let projectID: UUID
  public let objectID: UUID
  public let designID: UUID
  public let width: Double
  public let height: Double
  public let artwork: Artwork
}

public enum CanvasImageGeneration {
  public static let artboardLongEdgeMM = 160.0

  /// Project packages and ordinary history edits validate links without fully
  /// revalidating every legacy artwork shape. Check the new portable metadata at
  /// that boundary too, so malformed saved provenance cannot bypass validation.
  public static func validateProvenance(in artwork: Artwork) throws {
    guard artwork.elements.contains(where: { $0.imageGeneration != nil }) else { return }
    var bytes = 0
    for element in artwork.elements {
      bytes += element.sourceMetadata?.properties.count ?? 0
      if let provenance = element.imageGeneration {
        guard element.kind == "image" else { throw FormError.invalid("Generation provenance belongs only to image layers.") }
        try provenance.validate()
        bytes += try JSONEncoder.form.encode(provenance).count
      }
      guard bytes <= 8 * 1024 * 1024 else { throw FormError.invalid("Artwork source and generation settings exceed the artwork metadata budget.") }
    }
  }

  @discardableResult public static func createArtboard(in project: inout Project, at position: Point2,
    aspectRatio: Double = 1.5) throws -> ProductObject {
    guard position.x.isFinite, position.y.isFinite, abs(position.x) <= 100_000, abs(position.y) <= 100_000,
      aspectRatio.isFinite, (0.125...8).contains(aspectRatio) else {
      throw FormError.invalid("Choose a finite Canvas position and a supported image aspect ratio.")
    }
    let width = aspectRatio >= 1 ? artboardLongEdgeMM : artboardLongEdgeMM * aspectRatio
    let height = aspectRatio >= 1 ? artboardLongEdgeMM / aspectRatio : artboardLongEdgeMM
    var object = try project.makeObject(recipeID: "artboard", name: "Image artboard",
      parameters: ["width": width, "depth": height])
    var artwork = Artwork(background: "#FFFFFF", bleed: 0)
    artwork.canvasPosition = position; object.artwork = artwork
    var candidate = project; candidate.objects.append(object)
    try candidate.validateArtworkLinks(); project = candidate
    return object
  }

  public static func destination(in project: Project, objectID: UUID) throws -> CanvasImageGenerationDestination {
    guard let object = project.objects.first(where: { $0.id == objectID }),
      object.recipeID == "artboard", !object.isCanvasWorkspace, object.componentDefinition != true, object.canvasSourceOnly != true,
      object.artworkSourceID == nil, !object.locked, !project.artworkOwner(object).locked,
      let artwork = object.artwork, artwork.elements.isEmpty,
      object["width"].isFinite, object["depth"].isFinite,
      object["width"] > 0, object["depth"] > 0, object["width"] <= 100_000, object["depth"] <= 100_000 else {
      throw FormError.invalid("Use the unlocked blank image artboard as the generation destination.")
    }
    return .init(projectID: project.id, objectID: object.id, designID: object.designID,
      width: object["width"], height: object["depth"], artwork: artwork)
  }

  public static func validateDestination(_ expected: CanvasImageGenerationDestination, in project: Project, allowingResize: Bool = false) throws {
    let current = try destination(in: project, objectID: expected.objectID)
    func renderingIdentity(_ artwork: Artwork) -> Artwork {
      var value = artwork
      // Ruler/grid preferences and local guide coordinates are editing aids.
      // Moving a left/top frame edge translates guides to preserve their world
      // positions; that must not invalidate a still-blank generation target.
      value.canvasPosition = nil; value.guides = nil; value.showGuides = nil
      value.showGrid = nil; value.gridSpacing = nil; value.snapEnabled = nil
      value.nudge = nil; value.unit = nil
      return value
    }
    let before = renderingIdentity(expected.artwork), after = renderingIdentity(current.artwork)
    guard current.projectID == expected.projectID, current.designID == expected.designID,
      (allowingResize || (current.width == expected.width && current.height == expected.height)), before == after else {
      throw FormError.invalid("The image artboard changed. Start a new generation to preserve its current contents.")
    }
  }

  @discardableResult public static func placeResult(in project: inout Project,
    destination: CanvasImageGenerationDestination, asset: String,
    provenance: CanvasImageGenerationProvenance) throws -> UUID {
    try validateDestination(destination, in: project); try provenance.validate()
    guard !asset.isEmpty, asset.utf8.count <= 240, !asset.contains("/"), !asset.contains("\\"),
      !asset.contains(".."), !asset.contains("\0"), asset.hasSuffix(".png"),
      let index = project.objects.firstIndex(where: { $0.id == destination.objectID }) else {
      throw FormError.invalid("Use a generated PNG stored in this project's Assets folder.")
    }
    // Pixel dimensions describe output resolution. The user's physical Canvas
    // frame is authoritative and must not jump or resize when the image arrives.
    let width = destination.width, height = destination.height
    var element = ArtworkElement(kind: "image", x: 0, y: 0, width: width, height: height, asset: asset)
    element.name = provenance.isDemo ? "Generated image · Local demo" : "Generated image"
    element.imageGeneration = provenance
    var candidate = project
    candidate.objects[index].artwork!.elements = [element]
    try candidate.validateArtworkLinks(); project = candidate
    return element.id
  }
}
