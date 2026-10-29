import CFormClipper
import CryptoKit
import Foundation
import FormCADModel

/// Identity is independent of a view's order or rectangle. In particular an
/// authored panel named "net" is distinct from the construction-wide proof.
public struct PhysicalArtworkSurfaceIdentity: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case net, panel, cadSurface, sewingPiece }
  public enum Side: String, Codable, Sendable { case outside, inside }
  public var kind: Kind
  public var surfaceID: String?
  public var side: Side
  public init(kind: Kind, surfaceID: String? = nil, side: Side = .outside) {
    self.kind=kind;self.surfaceID=surfaceID;self.side=side
  }
  public var key: String {
    let raw=kind == .sewingPiece ? (surfaceID.flatMap(UUID.init(uuidString:))?.uuidString ?? surfaceID):surfaceID
    let value=raw?.precomposedStringWithCanonicalMapping
    return "\(side.rawValue):\(kind.rawValue):\(value?.utf8.count ?? 0):\(value ?? "")"
  }
  public func validate() throws {
    guard kind == .net ? surfaceID == nil : (surfaceID.map{!$0.isEmpty && $0.utf8.count<=128} ?? false),
      (kind == .net || kind == .panel) || side == .outside else {
      throw FormError.invalid("Use an explicit net, panel, cadSurface or sewingPiece identity. Only paper net/panel views currently expose an inside source.")
    }
    if kind == .sewingPiece, surfaceID.flatMap(UUID.init(uuidString:)) == nil {
      throw FormError.invalid("A sewingPiece surface identity uses its original element UUID.")
    }
  }
}

/// Saved production intent. Geometry is always derived from the current
/// physical source; offset vertices and view transforms are not persisted.
public struct PhysicalArtworkIntent: Codable, Equatable, Sendable, Identifiable {
  public var surface: PhysicalArtworkSurfaceIdentity
  public var bleedMM: Double
  public var safeInsetMM: Double
  public var id: String {surface.key}
  public init(surface:PhysicalArtworkSurfaceIdentity,bleedMM:Double=3,safeInsetMM:Double=0) {
    self.surface=surface;self.bleedMM=bleedMM;self.safeInsetMM=safeInsetMM
  }
  public func validate() throws {
    try surface.validate()
    guard bleedMM.isFinite,(0...25).contains(bleedMM),safeInsetMM.isFinite,(0...100).contains(safeInsetMM) else {
      throw FormError.invalid("Physical artwork intent needs 0–25mm bleed and 0–100mm safety inset.")
    }
  }
}

public struct PhysicalArtworkIntentGuides: Codable, Equatable, Sendable {
  public var intent: PhysicalArtworkIntent
  public var coordinateSpace: String
  public var trim: [[Point2]]
  public var bleed: [[Point2]]
  public var safe: [[Point2]]
  public func transformed(by transform:Affine2) -> Self {
    var copy=self
    copy.trim=trim.map{$0.map(transform.apply)}
    copy.bleed=bleed.map{$0.map(transform.apply)}
    copy.safe=safe.map{$0.map(transform.apply)}
    return copy
  }
}
public struct PhysicalArtworkIntentIssue: Codable, Equatable, Sendable {
  public var code: String
  public var surfaceIDs: [String]
  public var message: String
  public var overlapAreaMM2: Double?
}
public struct PhysicalArtworkIntentReport: Codable, Equatable, Sendable {
  public var objectID: UUID
  public var sourceRevision: String
  public var guides: [PhysicalArtworkIntentGuides]
  public var issues: [PhysicalArtworkIntentIssue]
  public var units: String = "mm"
  public var requiresReview: Bool {!issues.isEmpty}
}

/// Uses the same robust 0.001mm integer grid as the sewing allowance kernel.
/// These operations add no saved or editable polygon representation.
enum PhysicalArtworkPolygonKernel {
  static func union(_ contours:[[Point2]]) throws -> [[Point2]] {
    let counts=contours.map{Int32($0.count)},xy=contours.flatMap{$0.flatMap{[$0.x,$0.y]}}
    return try xy.withUnsafeBufferPointer {a in
      try counts.withUnsafeBufferPointer {b in try SewingPolygonKernel.unpack(fc_union(a.baseAddress,b.baseAddress,Int32(b.count))) }
    }
  }
  static func intersectionArea(_ first:[[Point2]],_ second:[[Point2]]) throws -> Double {
    let an=first.map{Int32($0.count)},a=first.flatMap{$0.flatMap{[$0.x,$0.y]}}
    let bn=second.map{Int32($0.count)},b=second.flatMap{$0.flatMap{[$0.x,$0.y]}}
    let area=a.withUnsafeBufferPointer {ap in an.withUnsafeBufferPointer {np in
      b.withUnsafeBufferPointer {bp in bn.withUnsafeBufferPointer {mp in
        fc_intersection_area(ap.baseAddress,np.baseAddress,Int32(np.count),bp.baseAddress,mp.baseAddress,Int32(mp.count))
      }}
    }}
    guard area.isFinite,area>=0 else{throw FormError.invalid("Physical artwork overlap exceeded the polygon work limit.")}
    return area
  }
  static func outer(_ ring:[Point2]) -> [Point2] {SewingCurves.signedArea(ring)>=0 ? ring:Array(ring.reversed())}
}

extension Project {
  /// Moving an existing cut piece keeps its production intent in the same
  /// artwork-transfer transaction, including any destination ID remapping.
  mutating func transferPhysicalArtworkIntents(from sourceID:UUID,to targetID:UUID,
    moved:Set<UUID>,mapping:[UUID:UUID]) throws {
    guard let source=objects.firstIndex(where:{$0.id==sourceID}),
      let target=objects.firstIndex(where:{$0.id==targetID}),source != target else {
      throw FormError.missing("Choose different source owners for physical artwork transfer.")
    }
    func affected(_ intent:PhysicalArtworkIntent) -> Bool {
      intent.surface.kind == .sewingPiece && intent.surface.surfaceID.flatMap(UUID.init(uuidString:)).map(moved.contains) == true
    }
    // setArtwork propagates this move to every shared-design artwork owner.
    // Differing production declarations have no implied cross-family mapping.
    let sourceFamily=objects.filter{$0.id != sourceID && $0.designID==objects[source].designID}
    guard !sourceFamily.contains(where:{($0.physicalArtworkIntents ?? []).contains(where:affected)}) else {
      throw FormError.invalid("A shared-design variant owns physical guide intent for a moving sewing piece. Clear or separate that intent before transferring the shared geometry.")
    }
    let outgoing=(objects[source].physicalArtworkIntents ?? []).filter(affected)
    guard !outgoing.isEmpty else{return}
    guard !objects.contains(where:{$0.id != targetID && $0.designID==objects[target].designID}) else {
      throw FormError.invalid("The destination shares its artwork with design variants. Choose an independent destination to retain the moving piece's physical guide intent.")
    }
    var destination=objects[target].physicalArtworkIntents ?? []
    for intent in outgoing {
      guard let original=intent.surface.surfaceID.flatMap(UUID.init(uuidString:)),let replacement=mapping[original] else {
        throw FormError.invalid("A transferred sewing guide lost its original piece identity.")
      }
      var copy=intent;copy.surface.surfaceID=replacement.uuidString
      guard !destination.contains(where:{$0.id==copy.id}) else {
        throw FormError.invalid("The destination already has production intent for the remapped sewing piece.")
      }
      destination.append(copy)
    }
    guard destination.count<=128 else{throw FormError.invalid("The transfer exceeds128 physical artwork intents on the destination.")}
    let leaving=Set(outgoing.map(\.id)),remaining=(objects[source].physicalArtworkIntents ?? []).filter{!leaving.contains($0.id)}
    objects[source].physicalArtworkIntents=remaining.isEmpty ? nil:remaining
    objects[target].physicalArtworkIntents=destination
  }
  public func validatePhysicalArtworkIntents() throws {
    for object in objects {
      guard let intents=object.physicalArtworkIntents else{continue}
      guard intents.count<=128,Set(intents.map(\.id)).count==intents.count,
        !object.isCanvasWorkspace || intents.allSatisfy({$0.surface.kind == .sewingPiece}) else {
        throw FormError.invalid("Use up to128 unique physical surfaces. Shared Canvas guides must target finite sewing pieces.")
      }
      for intent in intents {try intent.validate()}
    }
  }
  public func physicalArtworkIntentRevision(for object:ProductObject) throws -> String {
    struct Snapshot:Encodable {
      var paper:PaperNet?
      var surfaces:[CADResolvedPlanarSurface]?
      var artwork:Artwork?
      var intents:[PhysicalArtworkIntent]
    }
    let intents=object.physicalArtworkIntents ?? []
    let paper=PaperConstruction.isPaper(object) ? try PaperConstruction.definition(for:object).net():nil
    let art=intents.contains{$0.surface.kind == .sewingPiece} ? editableArtwork(object):nil
    return SHA256.hash(data:try JSONEncoder.form.encode(Snapshot(paper:paper,
      surfaces:object.cadRepresentation?.resolvedSurfaces,artwork:art,intents:intents))).map{String(format:"%02x",$0)}.joined()
  }
  public func physicalArtworkIntentReport(for object:ProductObject) throws -> PhysicalArtworkIntentReport {
    let intents=object.physicalArtworkIntents ?? []
    let paper=PaperConstruction.isPaper(object) ? try PaperConstruction.definition(for:object):nil
    let art=editableArtwork(object),revision=try physicalArtworkIntentRevision(for:object)
    var report=PhysicalArtworkIntentReport(objectID:object.id,sourceRevision:revision,guides:[],issues:[])
    var derivedPoints=0
    for intent in intents {
      try intent.validate()
      func issue(_ code:String,_ message:String) {
        report.issues.append(.init(code:code,surfaceIDs:[intent.id],message:message))
      }
      do {
        let trim:[[Point2]],space:String
        switch intent.surface.kind {
        case .net,.panel:
          guard let paper else{throw FormError.invalid("This physical paper source is unavailable.")}
          let net=try paper.net()
          if intent.surface.kind == .net {
            trim=try PhysicalArtworkPolygonKernel.union(net.panels.map{PhysicalArtworkPolygonKernel.outer($0.polygon)})
          } else {
            guard let panel=net.panels.first(where:{$0.id==intent.surface.surfaceID}) else {
              throw FormError.missing("The authored panel was removed or renamed; reassign its production intent.")
            }
            trim=[PhysicalArtworkPolygonKernel.outer(panel.polygon)]
          }
          space="paper:"+intent.surface.side.rawValue
        case .cadSurface:
          guard let surface=object.cadRepresentation?.resolvedSurfaces?.first(where:{$0.id==intent.surface.surfaceID}) else {
            throw FormError.missing("The exact physical surface is unresolved; re-evaluate or reassign its production intent.")
          }
          trim=[PhysicalArtworkPolygonKernel.outer(surface.boundary.map{.init($0.x,$0.y)})]
          space="cad:"+(intent.surface.surfaceID ?? "")
        case .sewingPiece:
          guard let art,let element=art.elements.first(where:{$0.id==intent.surface.surfaceID.flatMap(UUID.init(uuidString:)) && $0.sewingPiece != nil}) else {
            throw FormError.missing("The sewing piece source is unavailable; reassign its production intent.")
          }
          trim=try SewingPatterns.geometry(element,in:art).allCutContours
          space="sewing:outside"
        }
        var guides=PhysicalArtworkIntentGuides(intent:intent,coordinateSpace:space,trim:trim,bleed:[],safe:[])
        do {guides.bleed=intent.bleedMM == 0 ? trim:try SewingPolygonKernel.offset(trim,distance:intent.bleedMM)}
        catch {issue("bleed_unresolved",error.localizedDescription)}
        do {
          guides.safe=intent.safeInsetMM == 0 ? trim:try SewingPolygonKernel.offset(trim,distance:-intent.safeInsetMM)
          if guides.safe.count != trim.count {issue("safe_topology_changed","The safety inset changes material islands or holes. Review the current derived regions.")}
        } catch {issue("safe_inset_collapsed","The declared safety inset collapsed or exceeded the robust polygon limit. Reduce it or revise the source.")}
        let points=(guides.trim+guides.bleed+guides.safe).reduce(0){$0+$1.count}
        guard points<=262144-derivedPoints else {
          issue("guide_work_limit","The physical guide report exceeds262,144 derived points. Simplify the contour or review smaller groups; this surface's guides were not retained.")
          continue
        }
        derivedPoints+=points;report.guides.append(guides)
      } catch {issue("unresolved_surface",error.localizedDescription)}
    }
    func bounds(_ rings:[[Point2]]) -> Rect2? {
      var x=Double.infinity,y=Double.infinity,maxX = -Double.infinity,maxY = -Double.infinity
      for ring in rings {for p in ring {x=min(x,p.x);y=min(y,p.y);maxX=max(maxX,p.x);maxY=max(maxY,p.y)}}
      return x.isFinite ? .init(x,y,maxX-x,maxY-y):nil
    }
    let boxes=report.guides.map{bounds($0.bleed)}
    var pairs=0
    for i in report.guides.indices {
      let first=report.guides[i]
      guard !first.bleed.isEmpty,first.intent.surface.kind != .net else{continue}
      for j in report.guides.indices where j>i {
        let second=report.guides[j]
        guard first.coordinateSpace==second.coordinateSpace,!second.bleed.isEmpty,
          second.intent.surface.kind != .net else{continue}
        guard let a=boxes[i],let b=boxes[j],a.maxX>b.x,a.x<b.maxX,a.maxY>b.y,a.y<b.maxY else{continue}
        pairs+=1
        guard pairs<=1024 else {
          report.issues.append(.init(code:"overlap_review_incomplete",surfaceIDs:report.guides.map{$0.intent.id},
            message:"More than1024 surface pairs need overlap review. Review smaller explicit groups."))
          return report
        }
        let area=try PhysicalArtworkPolygonKernel.intersectionArea(first.bleed,second.bleed)
        if area>0.001 {
          report.issues.append(.init(code:"bleed_overlap",surfaceIDs:[first.intent.id,second.intent.id],
            message:"Declared bleed regions overlap in the same physical source. Review shared-crease or independent artwork placement explicitly.",overlapAreaMM2:area))
        }
      }
    }
    return report
  }
}

enum PhysicalArtworkIntentCommands {
  static func identity(_ raw:Any) throws -> PhysicalArtworkSurfaceIdentity {
    guard let value=raw as? [String:Any],Set(value.keys).isSubset(of:["kind","surfaceID","side"]) else {
      throw FormError.invalid("A physical surface identity accepts only kind, surfaceID and side.")
    }
    let result=try JSONDecoder().decode(PhysicalArtworkSurfaceIdentity.self,from:JSONSerialization.data(withJSONObject:value))
    try result.validate();return result
  }
  static func call(engine:OperationEngine,arguments args:[String:Any],source:String) throws -> Any {
    let command=args["command"] as? String ?? ""
    let allowed:Set<String>=command == "set_intent"
      ? ["command","object_id","intent","expected_revision"]:["command","object_id","surface","expected_revision"]
    guard ["set_intent","clear_intent"].contains(command),Set(args.keys).isSubset(of:allowed),
      let project=engine.project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),
      let object=project.objects.first(where:{$0.id==id}),!object.locked else {
      throw FormError.invalid("Choose an unlocked physical object and set_intent or clear_intent.")
    }
    if let expected=args["expected_revision"] {
      guard let value=expected as? String,value == (try project.physicalArtworkIntentRevision(for:object)) else {
        throw FormError.invalid("The physical source or artwork intent changed; inspect before applying the edit.")
      }
    }
    var next=object.physicalArtworkIntents ?? []
    if command == "set_intent" {
      guard let value=args["intent"] as? [String:Any],Set(value.keys).isSubset(of:["surface","bleedMM","safeInsetMM"]),
        let rawSurface=value["surface"] else {
        throw FormError.invalid("intent requires surface, bleedMM and safeInsetMM, without unrelated fields.")
      }
      _ = try identity(rawSurface)
      let intent=try JSONDecoder().decode(PhysicalArtworkIntent.self,from:JSONSerialization.data(withJSONObject:value))
      try intent.validate()
      guard !object.isCanvasWorkspace || intent.surface.kind == .sewingPiece else {
        throw FormError.invalid("Shared Canvas guides need a finite sewingPiece surface; page/net bleed is not defined for unbounded space.")
      }
      next.removeAll{$0.id==intent.id};next.append(intent)
      guard next.count<=128 else{throw FormError.invalid("Use up to128 explicit physical artwork intents per object.")}
      var probe=object;probe.physicalArtworkIntents=next
      let report=try project.physicalArtworkIntentReport(for:probe)
      guard report.guides.contains(where:{$0.intent.id==intent.id}) else {
        throw FormError.invalid(report.issues.first(where:{$0.surfaceIDs.contains(intent.id)})?.message ?? "The physical surface is unresolved.")
      }
    } else {
      guard let raw=args["surface"] else{throw FormError.invalid("clear_intent needs an explicit surface identity.")}
      let surface=try identity(raw);next.removeAll{$0.surface.key==surface.key}
    }
    try engine.edit("Changed physical artwork guides",source:source) {p in
      guard let i=p.objects.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Physical source missing.")}
      p.objects[i].physicalArtworkIntents=next.isEmpty ? nil:next
    }
    guard let current=engine.project,let object=current.objects.first(where:{$0.id==id}) else{throw FormError.missing("Physical source missing.")}
    let report=try current.physicalArtworkIntentReport(for:object)
    return ["report":try jsonObject(report),"requires_review":report.requiresReview]
  }
}
