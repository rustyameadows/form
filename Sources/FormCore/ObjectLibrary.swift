import Foundation

/// A reference is evidence about a form, not a SKU, live offer, or executable recipe.
public struct ObjectLibraryReference: Codable, Equatable, Identifiable, Sendable {
  public var id, name, domain, category, construction, distinction, options: String
  public var referenceType, referenceName, referenceURL, notes: String
}
public struct ObjectMaterialOptions: Codable, Equatable, Sendable {
  public var domain, group, choices, details, referenceName, referenceURL: String
}
public struct ObjectWorkExample: Codable, Equatable, Sendable {
  public var name, components, catalogIDs, sizing, surfaces, notes: String
  public var referenceIDs: [String] { catalogIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
}
public struct ObjectLibraryReferenceCatalog: Codable, Equatable, Sendable {
  public var sourceName, sourceDate: String
  public var references: [ObjectLibraryReference]
  public var materialOptions: [ObjectMaterialOptions]
  public var workExamples: [ObjectWorkExample]
}

public struct BlankIdentity: Codable, Equatable, Sendable {
  public var manufacturer, style, productName, productURL: String
  public var specifications: String
  public var fabricComposition, fabricWeight, fit, reviewedOn: String?
  public var referenceSizes, decorationMethods: [String]?
  /// Date of the supplied reference workbook; this does not assert supplier verification.
  public var referenceDate = "2026-10-25"
  public init(_ manufacturer: String, _ style: String, _ productName: String, _ productURL: String,
              _ specifications: String, fabric: String? = nil, weight: String? = nil, fit: String? = nil,
              sizes: [String]? = nil, methods: [String]? = nil, reviewedOn: String? = nil) {
    self.manufacturer = manufacturer; self.style = style; self.productName = productName
    self.productURL = productURL; self.specifications = specifications
    fabricComposition=fabric; fabricWeight=weight; self.fit=fit; referenceSizes=sizes
    decorationMethods=methods; self.reviewedOn=reviewedOn
  }
}
public struct ObjectLibraryEntry: Codable, Equatable, Identifiable, Sendable {
  public var id, referenceID, name, recipeID, materialID, reason, representation: String
  public var parameters: [String: Double]
  public var blank: BlankIdentity?
  public init(_ id: String, _ referenceID: String, _ name: String, _ recipeID: String,
              _ materialID: String, _ parameters: [String: Double], _ reason: String,
              representation: String = "Geometry and display fabric are approximate. Dimensions are starting proportions, not supplier measurements.",
              blank: BlankIdentity? = nil) {
    self.id = id; self.referenceID = referenceID; self.name = name; self.recipeID = recipeID
    self.materialID = materialID; self.parameters = parameters; self.reason = reason
    self.representation = representation; self.blank = blank
  }
}

/// Portable snapshot: saved projects never resolve their product identity from today's catalog.
/// Artwork and production jobs keep their existing independent owners.
public struct ObjectLibrarySelection: Codable, Equatable, Sendable {
  public enum State: String, Codable, CaseIterable, Sendable {
    case concept, proposedBlank, chosenBlank, custom
    public var name: String {
      switch self {
      case .concept: return "Concept"
      case .proposedBlank: return "Proposed blank"
      case .chosenBlank: return "Chosen blank"
      case .custom: return "Custom variation"
      }
    }
  }
  public var entry: ObjectLibraryEntry
  public var reference: ObjectLibraryReference
  public var sourceName, sourceDate: String
  public var state: State
  public var initialParameters: [String: Double]
  public var alternatives: [ObjectLibraryEntry] = []
}

public enum ObjectLibrary {
  public static let catalog: ObjectLibraryReferenceCatalog = {
    // A required, versioned resource. Catalog integrity is checked in the core tests.
    let url = Bundle.module.url(forResource: "ObjectReferences", withExtension: "json")!
    return try! JSONDecoder().decode(ObjectLibraryReferenceCatalog.self, from: Data(contentsOf: url))
  }()
  public static func reference(_ id: String) -> ObjectLibraryReference? { catalog.references.first { $0.id == id } }
  public static func entry(_ id: String) -> ObjectLibraryEntry? { starters.first { $0.id == id } }
  public static func search(_ query: String = "", domain: String? = nil, readyOnly: Bool = false) -> [ObjectLibraryReference] {
    let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
    let ready = Set(starters.map(\.referenceID))
    return catalog.references.filter { r in
      let text = [r.id, r.name, r.domain, r.category, r.construction, r.referenceName, r.options].joined(separator: " ").lowercased()
      return (domain == nil || r.domain == domain) && (!readyOnly || ready.contains(r.id)) && words.allSatisfy { text.contains($0) }
    }
  }
  public static let starters: [ObjectLibraryEntry] = [
    .init("jersey-tee", "FAB-001", "Classic jersey tee", "crewTee", "jersey-ecru", [:],
      "A conventional short-sleeve starting point for printed collections.", blank: .init("BELLA+CANVAS", "3001", "Unisex Jersey Short Sleeve Tee", "https://www.bellacanvas.com/3001", "Solid cotton reference. Composition varies by color; select a size and confirm its chart before production.", fabric:"Cotton for solids; Ash includes polyester.", weight:"4.2 oz (manufacturer declaration)", fit:"Classic, side-seamed jersey", sizes:["XS","S","M","L","XL","2XL","3XL","4XL","5XL"], reviewedOn:"2026-10-26")),
    .init("heavy-tee", "FAB-003", "Heavy relaxed tee", "crewTee", "jersey-ecru",
      ["width": 600, "depth": 740, "sleeveLength": 210, "sleeveWidth": 230, "collarWidth": 24],
      "A roomier alternative for a substantial souvenir or streetwear collection.", blank: .init("AS Colour", "5080", "Heavy Tee", "https://ascolour.com/heavy-tee-5080/", "Heavy cotton tee reference. Fit and fabric weight remain separate from the approximate preview.", fabric:"Carded cotton; marles include viscose.", weight:"8.2 oz (manufacturer declaration)", fit:"Relaxed and boxy, dropped shoulder", methods:["Screen printing","DTG","Embroidery"], reviewedOn:"2026-10-26")),
    .init("box-tee", "FAB-002", "Boxy shortened tee", "crewTee", "jersey-ecru",
      ["width": 610, "depth": 640, "sleeveLength": 210, "sleeveWidth": 230],
      "A shorter, wider silhouette for comparing collection proportions.", blank: .init("AS Colour", "5030", "Box Tee", "https://ascolour.com/box-tee-5030/", "Workbook product reference; confirm current product specifications and size chart.")),
    .init("pullover-hoodie", "FAB-024", "Pullover hoodie", "pulloverHoodie", "library-fleece", [:],
      "A hood and pouch pocket establish the main artwork interruptions.", blank: .init("Independent Trading Co.", "SS4500", "Midweight Pullover Hood", "https://www.independenttradingco.com/products/ss4500", "Workbook product reference. Preview fleece, cut, hood and pocket are approximate; verify the chosen size and color.")),
    .init("heavy-hoodie", "FAB-025", "Heavy streetwear hoodie", "pulloverHoodie", "library-fleece",
      ["width": 650, "depth": 750, "sleeveLength": 430, "hoodWidth": 290],
      "A broader hoodie for comparing a heavier collection direction.", blank: .init("Independent Trading Co.", "IND420XD", "Mainstreet Heavyweight Pullover Hood", "https://www.independenttradingco.com/pages/sales-sheets", "Workbook specification-library reference. Use the linked sheet and a physical sample for fit.")),
    .init("dad-cap", "FAB-046", "Unstructured dad cap", "curvedCap", "merch-twill", [:],
      "A soft curved-bill option; the preview uses a generic crown rather than the manufacturer's six-panel pattern.", blank: .init("YP Classics", "6245CM", "Classic Dad Cap", "https://www.flexfit.com/hat/yp-classics-classic-dad-cap", "Unstructured six-panel cotton cap with buckle closure. Green Camo has a different fiber blend. Generic crown dimensions are not the supplier's crown-height measurement.", fabric:"Cotton; Green Camo is a polyester/cotton blend.", fit:"Low crown, adjustable buckle", sizes:["OSFA"], reviewedOn:"2026-10-26")),
    .init("cuffed-beanie", "FAB-054", "Cuffed knit beanie", "cuffedBeanie", "library-acrylic", [:],
      "A flat presentation with a distinct turned cuff for a compact winter collection.", blank: .init("YP Classics", "1501KC", "Cuffed Knit Beanie", "https://www.flexfit.com/hat/beanie-cuffed-knit-cap", "Acrylic knit, one size. Manufacturer describes approximately 12 inches uncuffed; the flat cuffed preview is approximate.", fabric:"Acrylic knit", sizes:["OSFA"], methods:["Embroidery"], reviewedOn:"2026-10-26")),
    .init("canvas-tote", "FAB-057", "Gusseted canvas tote", "canvasTote", "merch-canvas",
      ["width": 420, "depth": 420, "gusset": 95, "handleSpan": 200],
      "An open bag with independently bounded body and gusset artwork.", blank: .init("AS Colour", "1001", "Carrie Tote", "https://ascolour.com/carrie-tote-1001/", "Workbook gives approximately 420 × 420 mm body and 95 mm gusset. Handle drop is a preview assumption, not total strap length.", fabric:"Cotton canvas", weight:"9.4 oz (manufacturer declaration)", sizes:["One size"], methods:["Screen printing","DTG","Embroidery"], reviewedOn:"2026-10-26")),
    .init("bandana", "FAB-068", "Square bandana", "hemmedTextile", "library-polyester", ["width": 550, "depth": 550],
      "A flat square for all-over artwork studies; tied form is a separate future depiction.", blank: .init("Printful", "All-Over Print Bandana", "All-Over Print Bandana", "https://www.printful.com/custom/collections/halloween/all-over-print-bandana", "Polyester, single-sided print and folded edges. 550 mm is a concept size; select the actual S/M/L template before production.", fabric:"US: recycled polyester. EU: recycled and virgin polyester blend.", weight:"US 110 g/m²; EU 100 g/m²", sizes:["S","M","L"], methods:["All-over synthetic printing"], reviewedOn:"2026-10-26")),
    .init("tea-towel", "FAB-067", "Tea towel", "hemmedTextile", "merch-canvas", ["width": 500, "depth": 700], "A hemmed rectangular textile for kitchen and gift-shop artwork."),
    .init("woven-label", "FAB-073", "Flat woven label", "textileLabel", "label-ecru", ["width": 60, "depth": 20], "An independent label with its own artwork and sew-in allowance."),
    .init("care-label", "FAB-078", "Printed care label", "textileLabel", "label-ecru", ["width": 30, "depth": 60], "Keep care information and seam allowance separate from garment graphics."),
    .init("embroidered-patch", "FAB-080", "Embroidered patch", "textilePatch", "patch-twill", ["width": 80, "depth": 60], "A separate patch base and decoration study, ready for explicit digitizing."),
    .init("business-card", "PAP-001", "Business card · US", "artboard", "chalk", ["width": 88.9, "depth": 50.8], "A familiar finished trim for identity work.", representation: "Exact 3.5 × 2 inch trim. Stock, reverse and finishing remain to be specified."),
    .init("postcard", "PAP-002", "Postcard · 4 × 6", "artboard", "chalk", ["width": 152.4, "depth": 101.6], "A thank-you insert or souvenir card at physical print size.", representation: "Exact 6 × 4 inch trim. No postal or supplier compliance is implied."),
    .init("notecard", "PAP-003", "Flat notecard · 5 × 7", "artboard", "chalk", ["width": 127, "depth": 177.8], "A correspondence or invitation layout; choose an envelope independently."),
    .init("letterhead", "PAP-004", "Letterhead · US Letter", "artboard", "chalk", ["width": 215.9, "depth": 279.4], "An editable stationery sheet with a named physical size."),
    .init("flyer-a5", "PAP-005", "Flyer · A5", "artboard", "chalk", ["width": 148, "depth": 210], "A loose instruction insert or event handout."),
    .init("poster", "PAP-006", "Art print · 8 × 10", "artboard", "chalk", ["width": 203.2, "depth": 254], "A small print for a retail collection."),
    .init("bookmark", "PAP-007", "Bookmark", "artboard", "chalk", ["width": 50.8, "depth": 177.8], "A narrow artwork sheet; holes and tassels are not part of this preview."),
    .init("sticker-sheet", "PAP-047", "Sticker sheet · A6", "artboard", "chalk", ["width": 105, "depth": 148], "Lay out individual graphics; cut paths and liner remain to be prepared."),
    .init("hang-tag", "PAP-051", "Hang tag", "artboard", "chalk", ["width": 50, "depth": 90], "A separate retail tag layout; add hole and attachment details before manufacture."),
    .init("backing-card", "PAP-054", "Product backing card", "artboard", "chalk", ["width": 100, "depth": 150], "A flat card behind an accessory; retain usable graphic space around attachments."),
    .init("pocket-notebook", "PAP-026", "Pocket notebook", "booklet", "chalk", ["width": 88.9, "depth": 139.7, "pages": 48], "A closed notebook volume and editable cover inspired by the workbook's Field Notes reference.", representation: "Approximate bound stack. The preview does not reproduce staples or the referenced product's construction."),
    .init("booklet-a6", "PAP-021", "Instruction booklet · A6", "booklet", "chalk", ["width": 105, "depth": 148, "pages": 16], "A cover and physical page-stack study; create ordered publication pages independently."),
    .init("belly-band", "PAP-055", "Paper belly band", "sleeve", "chalk", ["width": 110, "depth": 55, "height": 18, "tab": 12], "A scored wrap around a stationery stack. Check the complete stack and glue overlap."),
    .init("paper-sleeve", "PKG-018", "Paperboard product sleeve", "sleeve", "chalk", ["width": 120, "depth": 160, "height": 30, "stock": 0.45], "A four-sided wrap with a live dieline; verify stock and clearances for the product."),
    .init("interlayer", "PKG-059", "Flat backing pad", "paperStack", "chalk", ["width": 200, "depth": 150, "sheets": 1, "thickness": 1.5], "A simple backing pad. Corrugated flute and strength are supplier choices."),
  ]
}

extension Project {
  public mutating func addLibraryObject(_ entryID: String, position: Vector3 = .init()) throws -> ProductObject {
    guard let entry = ObjectLibrary.entry(entryID), let reference = ObjectLibrary.reference(entry.referenceID) else {
      throw FormError.missing("Unknown starter. Use form_object_library list to find editable starters.")
    }
    var object = try makeObject(recipeID: entry.recipeID, name: entry.name, parameters: entry.parameters,
                                materialID: entry.materialID, position: position)
    if object.supportsArtworkFace { object.artwork = Artwork(background: "#F2EDE1", bleed: 0) }
    object.librarySelection = .init(entry: entry, reference: reference, sourceName: ObjectLibrary.catalog.sourceName,
      sourceDate: ObjectLibrary.catalog.sourceDate, state: entry.blank == nil ? .concept : .proposedBlank,
      initialParameters: object.parameters)
    if let blank = entry.blank {
      object.textile?.blankName = blank.productName; object.textile?.manufacturer = blank.manufacturer
      object.textile?.sku = blank.style; object.textile?.size = "Preview proportions · size unselected"
    }
    objects.append(object)
    return object
  }

  /// Compatible swaps preserve artwork/source IDs, placements and physical artwork sizes.
  /// Validation is atomic: an attached graphic that no longer fits rejects the entire swap.
  public mutating func replaceLibraryObject(_ id: UUID, with entryID: String) throws {
    guard let index = objects.firstIndex(where: { $0.id == id }), let entry = ObjectLibrary.entry(entryID),
          let reference = ObjectLibrary.reference(entry.referenceID) else { throw FormError.missing("Starter or object not found.") }
    let old = objects[index]
    guard !old.locked, old.recipeID == entry.recipeID, !old.isCanvasWorkspace else {
      throw FormError.invalid("Choose an unlocked object and a starter with the same construction recipe.")
    }
    guard !objects.contains(where: { $0.id != id && $0.designID == old.designID }) else {
      throw FormError.invalid("Make an independent iteration before changing the blank of linked variants.")
    }
    var candidate = self
    var updated = old
    let parameters = try makeObject(recipeID: entry.recipeID, parameters: entry.parameters, materialID: entry.materialID).parameters
    var alternatives = old.librarySelection?.alternatives ?? []
    if let previous = old.librarySelection?.entry, previous.id != entry.id {
      alternatives.removeAll { $0.id == previous.id || $0.id == entry.id }
      alternatives.insert(previous, at: 0)
    }
    updated.parameters = parameters; updated.materialID = entry.materialID; updated.color = nil
    updated.librarySelection = .init(entry: entry, reference: reference, sourceName: ObjectLibrary.catalog.sourceName,
      sourceDate: ObjectLibrary.catalog.sourceDate, state: entry.blank == nil ? .concept : .proposedBlank,
      initialParameters: parameters, alternatives: Array(alternatives.prefix(20)))
    updated.textile?.blankName = entry.blank?.productName
    updated.textile?.manufacturer = entry.blank?.manufacturer; updated.textile?.sku = entry.blank?.style
    updated.textile?.measurementsVerified = false
    updated.textile?.size = "Preview proportions · size unselected"
    candidate.objects[index] = updated
    try candidate.validateArtworkLinks()
    self = candidate
  }

  public mutating func setLibraryState(_ id: UUID, _ state: ObjectLibrarySelection.State) throws {
    guard let index = objects.firstIndex(where: { $0.id == id }), !objects[index].locked,
          var selection = objects[index].librarySelection else { throw FormError.invalid("Choose an unlocked library object.") }
    if state == .chosenBlank || state == .proposedBlank {
      guard selection.entry.blank != nil, selection.state != .custom else {
        throw FormError.invalid("Select a real blank before choosing it. Reapply a starter to reset custom proportions.")
      }
    }
    guard state != .custom else { throw FormError.invalid("Custom variation is derived from changes to the blank's form or material.") }
    selection.state = state; objects[index].librarySelection = selection
  }

  public mutating func refreshLibrarySelections() {
    for i in objects.indices {
      guard let s = objects[i].librarySelection else { continue }
      let identityChanged = s.entry.blank.map { b in
        objects[i].textile?.manufacturer != b.manufacturer || objects[i].textile?.sku != b.style || objects[i].textile?.blankName != b.productName
      } ?? false
      if objects[i].parameters != s.initialParameters || objects[i].materialID != s.entry.materialID || identityChanged {
        objects[i].librarySelection?.state = .custom
      }
    }
  }

  public func validateLibrarySelections() throws {
    for object in objects {
      guard let s = object.librarySelection else { continue }
      guard s.entry.recipeID == object.recipeID, s.entry.referenceID == s.reference.id,
        !s.entry.id.isEmpty, !s.sourceName.isEmpty, s.alternatives.count <= 20 else {
        throw FormError.invalid("The object's saved library source is inconsistent.")
      }
      try recipe(object.recipeID)?.validate(s.initialParameters)
      if s.state == .chosenBlank || s.state == .proposedBlank {
        guard let blank = s.entry.blank, object.parameters == s.initialParameters,
          object.materialID == s.entry.materialID, object.textile?.manufacturer == blank.manufacturer,
          object.textile?.sku == blank.style, object.textile?.blankName == blank.productName else {
          throw FormError.invalid("A changed blank must be stored as a custom variation.")
        }
      }
    }
  }
}
