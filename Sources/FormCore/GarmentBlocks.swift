import Foundation

public struct GarmentBodyMeasurements: Codable, Equatable, Sendable {
  public var waist = 760.0
  public var hip = 980.0
  public var waistToHip = 200.0
  public init() {}
}
public struct GarmentBlockStyle: Codable, Equatable, Sendable {
  public var bodyLength = 650.0
  public var bodyEase = 120.0
  public var sideAllowance = 10.0
  public var casingDepth = 30.0
  public var casingTurnUnder = 8.0
  public var hemAllowance = 30.0
  public var elasticWidth = 25.0
  public var elasticLoopAdjustment = -20.0
  public var elasticOverlap = 25.0
  public var materialID: String?
  public var elasticMaterialID: String?
  public init() {}
}
public struct GarmentGradeRule: Codable, Equatable, Sendable {
  public var waist = 40.0
  public var hip = 40.0
  public var waistToHip = 5.0
  public var bodyLength = 10.0
  public init() {}
}
public struct GarmentSizeOverrides: Codable, Equatable, Sendable {
  public var waist: Double?
  public var hip: Double?
  public var waistToHip: Double?
  public var bodyLength: Double?
  public init() {}
  public var isEmpty: Bool { waist == nil && hip == nil && waistToHip == nil && bodyLength == nil }
}
public struct GarmentSizeRow: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var label: String
  public var step: Int
  public var overrides: GarmentSizeOverrides?
  public init(_ label: String, step: Int) { self.label=label; self.step=step }
}
public enum GarmentPieceRole: String, Codable, CaseIterable, Sendable { case front, back, elastic }
public struct GarmentBlockBinding: Codable, Equatable, Sendable {
  public var sizeID: UUID
  public var objectID: UUID
  public var elementID: UUID
  public var role: GarmentPieceRole
  public var fingerprint: String
  public init(sizeID: UUID, objectID: UUID, elementID: UUID, role: GarmentPieceRole, fingerprint: String) {
    self.sizeID=sizeID;self.objectID=objectID;self.elementID=elementID;self.role=role;self.fingerprint=fingerprint
  }
}
public struct GarmentBlockSeamBinding: Codable, Equatable, Sendable {
  public var sizeID: UUID
  public var objectID: UUID
  public var seamID: UUID
  public var fingerprint: String
  public var name: String
  public init(sizeID: UUID, objectID: UUID, seamID: UUID, name: String, fingerprint: String) {
    self.sizeID=sizeID;self.objectID=objectID;self.seamID=seamID;self.name=name;self.fingerprint=fingerprint
  }
}
public struct GarmentBlock: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var recipe = "fieldGatheredSkirt"
  public var recipeVersion = 1
  public var name: String
  public var body = GarmentBodyMeasurements()
  public var style = GarmentBlockStyle()
  public var grade = GarmentGradeRule()
  public var sizes: [GarmentSizeRow]
  public var baseSizeID: UUID
  public var bindings: [GarmentBlockBinding] = []
  public var seams: [GarmentBlockSeamBinding] = []
  public init(name: String = "Field gathered skirt") {
    self.name=name
    sizes=[.init("Study 01",step:-1),.init("Study 02",step:0),.init("Study 03",step:1)]
    baseSizeID=sizes[1].id
  }
  public func validate() throws {
    guard recipe == "fieldGatheredSkirt",recipeVersion == 1,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
      name.count<=80,(1...12).contains(sizes.count),Set(sizes.map(\.id)).count == sizes.count,
      Set(sizes.map{$0.label.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}).count == sizes.count,
      let base=sizes.first(where:{$0.id == baseSizeID}),base.step == 0,base.overrides?.isEmpty != false,
      sizes.allSatisfy({!$0.label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.label.count<=40 && (-12...12).contains($0.step)}) else {
      throw FormError.invalid("Use the supported original block, a name up to 80 characters and 1–12 distinctly named sizes. The base size has step zero and uses the base measurements directly.")
    }
    func finite(_ value:Double,_ range:ClosedRange<Double>)->Bool {value.isFinite && range.contains(value)}
    guard finite(body.waist,300...2000),finite(body.hip,300...2000),finite(body.waistToHip,50...500),
      finite(style.bodyLength,300...1200),finite(style.bodyEase,0...1000),finite(style.sideAllowance,2...30),
      finite(style.casingDepth,8...100),finite(style.casingTurnUnder,3...20),finite(style.hemAllowance,10...80),
      finite(style.elasticWidth,3...60),finite(style.elasticLoopAdjustment,-200...200),finite(style.elasticOverlap,5...60),
      style.casingDepth>=style.elasticWidth+3,(style.materialID?.count ?? 0)<=160,(style.elasticMaterialID?.count ?? 0)<=160,
      [grade.waist,grade.hip].allSatisfy({finite($0,-200...200)}),
      [grade.waistToHip,grade.bodyLength].allSatisfy({finite($0,-50...50)}) else {
      throw FormError.invalid("Check finite declared body/garment measurements, bounded grade increments, construction allowances and at least 3 mm casing clearance above the elastic width.")
    }
    for size in sizes { _ = try resolved(size) }
    let sizeIDs=Set(sizes.map(\.id))
    guard bindings.count<=36,seams.count<=24,
      bindings.allSatisfy({sizeIDs.contains($0.sizeID) && $0.fingerprint.count == 64 && $0.fingerprint.allSatisfy(\.isHexDigit)}),
      seams.allSatisfy({sizeIDs.contains($0.sizeID) && ["left","right"].contains($0.name) && $0.fingerprint.count == 64 && $0.fingerprint.allSatisfy(\.isHexDigit)}),
      Set(bindings.map{$0.sizeID.uuidString+"/"+$0.role.rawValue}).count == bindings.count,
      Set(seams.map{$0.sizeID.uuidString+"/"+$0.name}).count == seams.count else {
      throw FormError.invalid("A managed size has one source per role and one seam per side, with valid recorded fingerprints.")
    }
  }
  public func resolved(_ size: GarmentSizeRow) throws -> GarmentResolvedSize {
    let n=Double(size.step),o=size.overrides
    let waist=o?.waist ?? body.waist+n*grade.waist
    let hip=o?.hip ?? body.hip+n*grade.hip
    let depth=o?.waistToHip ?? body.waistToHip+n*grade.waistToHip
    let length=o?.bodyLength ?? style.bodyLength+n*grade.bodyLength
    let circumference=max(waist,hip)+style.bodyEase
    let loop=waist+style.elasticLoopAdjustment
    let rawHeight=length+style.casingDepth+style.casingTurnUnder+style.hemAllowance
    guard [waist,hip,depth,length,circumference,loop,rawHeight].allSatisfy(\.isFinite),
      (300...2000).contains(waist),(300...2000).contains(hip),(50...500).contains(depth),
      (300...1200).contains(length),depth+40<length,(100...3000).contains(loop),loop<=circumference,
      (300...3000).contains(circumference),(300...1400).contains(rawHeight) else {
      throw FormError.invalid("Size ‘\(size.label)’ resolves outside the declared body/garment limits. Check grade steps, overrides, hip depth, body length and elastic loop target; values are never clamped.")
    }
    return .init(sizeID:size.id,label:size.label,waist:waist,hip:hip,waistToHip:depth,
      bodyLength:length,bodyCircumference:circumference,panelWidth:circumference/2,
      rawHeight:rawHeight,elasticLoop:loop,elasticCutLength:loop+style.elasticOverlap,
      waistFold:style.casingDepth+style.casingTurnUnder,hemFold:style.casingDepth+style.casingTurnUnder+length)
  }
}
public struct GarmentResolvedSize: Codable, Equatable, Sendable {
  public var sizeID:UUID
  public var label:String
  public var waist:Double
  public var hip:Double
  public var waistToHip:Double
  public var bodyLength:Double
  public var bodyCircumference:Double
  public var panelWidth:Double
  public var rawHeight:Double
  public var elasticLoop:Double
  public var elasticCutLength:Double
  public var waistFold:Double
  public var hemFold:Double
}

extension Project {
  public func validateGarmentBlocks() throws {
    let blocks=garmentBlocks ?? []
    guard blocks.count<=32,Set(blocks.map(\.id)).count == blocks.count else {
      throw FormError.invalid("A project supports up to 32 distinct managed garment blocks.")
    }
    var bound=Set<String>()
    for block in blocks {
      try block.validate()
      for row in block.sizes {
        let refs=block.bindings.filter{$0.sizeID==row.id},seams=block.seams.filter{$0.sizeID==row.id}
        guard (refs.isEmpty && seams.isEmpty) || (refs.count==3 && seams.count==2 && Set(refs.map(\.objectID)).count==1) else {
          throw FormError.invalid("Each managed size has a complete front/back/elastic source set and two recorded side seams in one source document.")
        }
      }
      for ref in block.bindings {
        if let owner=objects.first(where:{$0.id==ref.objectID}) {
          guard owner.recipeID == "artboard",artworkOwner(owner).id == owner.id else {
            throw FormError.invalid("Managed garment bindings refer to independent artwork owners, not linked physical faces.")
          }
        }
        guard bound.insert(ref.objectID.uuidString+"/"+ref.elementID.uuidString).inserted else {
          throw FormError.invalid("A source piece can have only one managed garment binding. Duplicate it as independent source or detach its current binding first.")
        }
      }
    }
    // Missing source is retained as a review conflict, not repaired or silently recreated.
  }
}
