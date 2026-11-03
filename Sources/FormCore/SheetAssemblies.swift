import Foundation
import FormCADModel

/// A canonical physical face; cropping is translation in millimeters, never a fit.
public struct SheetAssemblyFace: Codable, Equatable, Sendable {
  public var sourceObjectID: UUID
  public var sourceSide: PaperFinishAssignment.Side
  public var sourceOriginMM: CADExpressionPoint2?
  public init(sourceObjectID: UUID, sourceSide: PaperFinishAssignment.Side = .outside,
    sourceOriginMM: CADExpressionPoint2? = nil) {
    self.sourceObjectID=sourceObjectID;self.sourceSide=sourceSide;self.sourceOriginMM=sourceOriginMM
  }
}

/// Optional explicit pairing. Page IDs are PublicationPage.id, not artboard IDs.
public struct SheetAssemblyLeaf: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var frontPageID: UUID?
  public var backPageID: UUID?
  public var stock: PaperStock?
  public var finishes: [PaperFinishAssignment]?
  public init(id: UUID = UUID(), frontPageID: UUID? = nil, backPageID: UUID? = nil,
    stock: PaperStock? = nil, finishes: [PaperFinishAssignment]? = nil) {
    self.id=id;self.frontPageID=frontPageID;self.backPageID=backPageID;self.stock=stock;self.finishes=finishes
  }
}

/// Authored enclosure planes use the same expression language as other models.
/// Local +X is width, -Y is page-down, and +Z is the front face. Rotation is X,
/// then Y, then Z, about the source's top-left corner; translation is world mm.
public struct SheetAssemblyPlane: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var size: CADExpressionPoint2
  public var positionMM: CADExpressionPoint
  public var rotationDegrees: CADExpressionPoint
  public var stock: PaperStock
  public var front: SheetAssemblyFace?
  public var back: SheetAssemblyFace?
  public var finishes: [PaperFinishAssignment]?
  public init(id: String, name: String, size: CADExpressionPoint2,
    positionMM: CADExpressionPoint = .init(), rotationDegrees: CADExpressionPoint = .init(),
    stock: PaperStock = .init(), front: SheetAssemblyFace? = nil, back: SheetAssemblyFace? = nil,
    finishes: [PaperFinishAssignment]? = nil) {
    self.id=id;self.name=name;self.size=size;self.positionMM=positionMM;self.rotationDegrees=rotationDegrees
    self.stock=stock;self.front=front;self.back=back;self.finishes=finishes
  }
}

/// Ordered physical sheets linked to one publication. Covers, wraps, flaps and
/// spines are authored planes rather than product categories or built-in models.
public struct SheetAssemblyDefinition: Codable, Equatable, Sendable {
  public var version: Int = 1
  public var publicationID: UUID
  public var stock: PaperStock
  public var openingDegrees: Double
  /// Number of physical leaves turned toward the left stack.
  public var activeSpread: Int
  /// Requested free-edge rise for an isometric cylindrical viewing bend.
  public var bendMM: Double
  public var leaves: [SheetAssemblyLeaf]?
  public var enclosure: [SheetAssemblyPlane]?
  public var binding: SheetBindingDefinition?
  public var parentSheets: [SheetAssemblyParentSheet]?
  public init(publicationID: UUID, stock: PaperStock = .init(thicknessMM:0.12),
    openingDegrees: Double = 0, activeSpread: Int = 0, bendMM: Double = 0,
    leaves: [SheetAssemblyLeaf]? = nil, enclosure: [SheetAssemblyPlane]? = nil,
    binding: SheetBindingDefinition? = nil, parentSheets: [SheetAssemblyParentSheet]? = nil) {
    self.publicationID=publicationID;self.stock=stock;self.openingDegrees=openingDegrees
    self.activeSpread=activeSpread;self.bendMM=bendMM;self.leaves=leaves;self.enclosure=enclosure
    self.binding=binding;self.parentSheets=parentSheets
  }
}

public struct ResolvedSheetAssemblyFace: Codable, Equatable, Sendable {
  public var sourceObjectID: UUID
  public var sourceSide: PaperFinishAssignment.Side
  public var originMM: Point2
  public init(sourceObjectID:UUID,sourceSide:PaperFinishAssignment.Side = .outside,originMM:Point2 = .init()) {
    self.sourceObjectID=sourceObjectID;self.sourceSide=sourceSide;self.originMM=originMM
  }
}
public struct ResolvedSheetAssemblyLeaf: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var frontPageID: UUID?
  public var backPageID: UUID?
  public var front: ResolvedSheetAssemblyFace?
  public var back: ResolvedSheetAssemblyFace?
  public var size: Point2
  public var stock: PaperStock
  public var finishes: [PaperFinishAssignment]
  public var stackOffsetMM: Double
  public var turned: Bool
  public var frontVisible: Bool
  public var backVisible: Bool
  /// Allocation priority only; a low value never removes canonical artwork.
  public var frontSamplingWeight: Double = 0
  public var backSamplingWeight: Double = 0
  public var parentSheetID: UUID? = nil
}
public struct ResolvedSheetAssemblyPlane: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var size: Point2
  public var positionMM: Vector3
  public var rotationDegrees: Vector3
  public var stock: PaperStock
  public var front: ResolvedSheetAssemblyFace?
  public var back: ResolvedSheetAssemblyFace?
  public var finishes: [PaperFinishAssignment]
}
public struct ResolvedSheetAssembly: Codable, Equatable, Sendable {
  public var publicationID: UUID
  public var size: Point2
  public var stackThicknessMM: Double
  public var openingDegrees: Double
  public var activeSpread: Int
  public var bendMM: Double
  public var leaves: [ResolvedSheetAssemblyLeaf]
  public var enclosure: [ResolvedSheetAssemblyPlane]
  public var binding: ResolvedSheetBinding?
  public var parentSheets: [SheetAssemblyParentSheet]
  public var sourceObjectIDs: Set<UUID> {
    Set(leaves.flatMap{[$0.front?.sourceObjectID,$0.back?.sourceObjectID].compactMap{$0}}
      + enclosure.flatMap{[$0.front?.sourceObjectID,$0.back?.sourceObjectID].compactMap{$0}})
  }
}

extension PaperStock {
  public func sheetFaceOpacity(inside:Bool)->Double {
    let ply=inside ? plies?.first:plies?.last
    return (ply?.profile ?? profile)?.opacity ?? 1
  }
}

extension Project {
  public func resolvedSheetAssembly(_ object: ProductObject) throws -> ResolvedSheetAssembly {
    guard let definition=object.sheetAssembly,
      let document=publications?.first(where:{$0.id==definition.publicationID}),!document.pages.isEmpty else {
      throw FormError.invalid("A sheet assembly needs an existing nonempty publication.")
    }
    guard definition.version==1,definition.openingDegrees.isFinite,(0...180).contains(definition.openingDegrees),
      definition.bendMM.isFinite,(0...20).contains(definition.bendMM),
      (definition.enclosure?.count ?? 0)<=32 else {
      throw FormError.invalid("Sheet assemblies support opening 0–180°, bending 0–20 mm and up to 32 enclosure planes.")
    }
    guard document.pages.count<=200,Set(document.pages.map(\.id)).count==document.pages.count else {
      throw FormError.invalid("A linked publication must contain at most 200 distinct logical page identities.")
    }
    try definition.stock.validate()
    let byPage=Dictionary(uniqueKeysWithValues:document.pages.map{($0.id,$0)})
    let parents=try sheetParentAssignments(definition,document:document)
    let parentDeclarations=parents.isEmpty ? []:parentLeafDeclarations(definition,document:document)
    let declarations=definition.leaves ?? (parents.isEmpty ? document.leafPairs().map {
      SheetAssemblyLeaf(id:$0.id,frontPageID:$0.front?.id,backPageID:$0.back?.id)
    }:parentDeclarations.map(\.leaf))
    guard !declarations.isEmpty,declarations.count<=200,Set(declarations.map(\.id)).count==declarations.count,
      (0...declarations.count).contains(definition.activeSpread) else {
      throw FormError.invalid("A sheet assembly needs 1–200 distinct leaves and an active spread within that physical leaf count.")
    }
    let sideBound=definition.binding?.style == .sideStaple
    var used=Set<UUID>(),usedParentHalves=Set<UUID>(),leaves=[ResolvedSheetAssemblyLeaf](),thickness=0.0
    func page(_ id:UUID?)throws->ProductObject? {
      guard let id else{return nil}
      guard used.insert(id).inserted,let entry=byPage[id],let source=objects.first(where:{$0.id==entry.objectID}),
        source.id != object.id,source.sheetAssembly==nil,source.recipeID=="artboard",source.artwork != nil else {
        throw FormError.invalid("Physical leaf faces must refer once to canonical pages in this publication.")
      }
      return source
    }
    func finishes(_ values:[PaperFinishAssignment]?)throws->[PaperFinishAssignment] {
      let list=values ?? []
      guard list.count<=128,Set(list.map(\.id)).count==list.count else{throw FormError.invalid("Use at most 128 distinct finish assignments per sheet.")}
      for finish in list {try finish.validate()};return list
    }
    for (index,leaf) in declarations.enumerated() {
      let front=try page(leaf.frontPageID),back=try page(leaf.backPageID)
      let frontParent=leaf.frontPageID.flatMap{parents[$0]},backParent=leaf.backPageID.flatMap{parents[$0]}
      if let frontParent,let backParent,frontParent.id != backParent.id {
        throw FormError.invalid("Both faces of a viewing leaf must belong to the same declared folded parent sheet.")
      }
      let physicalHalf=parentDeclarations.first { expected in
        expected.leaf.frontPageID==leaf.frontPageID && expected.leaf.backPageID==leaf.backPageID &&
          (leaf.frontPageID != nil || leaf.backPageID != nil || expected.leaf.id==leaf.id)
      }
      if !parents.isEmpty {
        guard let physicalHalf,usedParentHalves.insert(physicalHalf.leaf.id).inserted else {
          throw FormError.invalid("Each viewing leaf must use one complete declared right or left parent half in its physical front/reverse orientation, including identified blank halves.")
        }
      }
      let parent=physicalHalf?.parent ?? frontParent ?? backParent
      guard let size=(front ?? back)?.artworkSize ?? parent.map({Point2($0.sizeMM.x/2,$0.sizeMM.y)}) else {
        throw FormError.invalid("A blank physical leaf needs its declared folded parent; other leaves need at least one canonical page face.")
      }
      guard [size.x,size.y].allSatisfy({$0.isFinite && (1...10000).contains($0)}),
        back.map({abs($0.artworkSize.x-size.x)<1e-6 && abs($0.artworkSize.y-size.y)<1e-6}) ?? true else {
        throw FormError.invalid("The two faces of a physical leaf must have compatible trim sizes; artwork is never fitted.")
      }
      if let explicit=leaf.stock,let parent,explicit != parent.stock {
        throw FormError.invalid("A viewing leaf's explicit stock conflicts with its authoritative folded parent. Edit the parent stock instead.")
      }
      var stock=parent?.stock ?? leaf.stock ?? definition.stock
      // The left half reverses stock faces, not its saved parent declaration.
      if let physicalHalf,
        parentDeclarations.suffix((definition.parentSheets?.count ?? 0)).contains(where:{$0.leaf.id==physicalHalf.leaf.id}),
        let plies=stock.plies {stock.plies=Array(plies.reversed())}
      try stock.validate()
      let turned=definition.openingDegrees != 0 && index<definition.activeSpread
      let offset=turned && !sideBound ? -(thickness+stock.resolvedThicknessMM/2):0
      leaves.append(.init(id:leaf.id,frontPageID:leaf.frontPageID,backPageID:leaf.backPageID,
        front:front.map{.init(sourceObjectID:$0.id,sourceSide:.outside,originMM:.init())},
        back:back.map{.init(sourceObjectID:$0.id,sourceSide:.outside,originMM:.init())},size:size,stock:stock,
        finishes:try finishes(leaf.finishes),stackOffsetMM:offset,turned:turned,
        frontVisible:false,backVisible:false,parentSheetID:parent?.id))
      thickness+=stock.resolvedThicknessMM
    }
    if !parents.isEmpty,(used != Set(document.pages.map(\.id)) || usedParentHalves.count != parentDeclarations.count || leaves.count != (definition.parentSheets?.count ?? 0)*2) {
      throw FormError.invalid("A parent-sheet assembly must include every physical publication face exactly once.")
    }
    var accumulated=0.0
    let isClosed=definition.openingDegrees==0,active=isClosed ? 0:definition.activeSpread
    for index in leaves.indices {
      if !leaves[index].turned || sideBound {leaves[index].stackOffsetMM=thickness-accumulated-leaves[index].stock.resolvedThicknessMM/2}
      accumulated+=leaves[index].stock.resolvedThicknessMM
    }
    let size=Point2(leaves.map(\.size.x).max()!,leaves.map(\.size.y).max()!)
    guard thickness<=2000,leaves.allSatisfy({definition.bendMM<=$0.size.x*0.5}) else {
      throw FormError.invalid("Keep a sheet stack within 2000 mm and its viewing bend below half the leaf width.")
    }
    let bent = !isClosed && definition.bendMM>0
    let sideFlex = sideBound && !isClosed && active>0
    let radii=try leaves.map {leaf->Double in
      guard bent && !sideBound else{return 0}
      var low=0.0,high=Double.pi/2
      for _ in 0..<40 {let angle=(low+high)/2;if leaf.size.x*(1-cos(angle))/angle<definition.bendMM {low=angle}else{high=angle}}
      let radius=leaf.size.x/((low+high)/2)
      guard radius>abs(leaf.stackOffsetMM)+leaf.stock.resolvedThicknessMM/2 else {
        throw FormError.invalid("The page bend radius must exceed its physical stack offset and caliper.")
      }
      return leaf.turned ? -radius:radius
    }
    func contains(_ outer:Int,_ inner:Int,inside:Bool)->Bool {
      leaves[outer].stock.sheetFaceOpacity(inside:inside)>=0.999 &&
        leaves[outer].size.x+1e-7>=leaves[inner].size.x && leaves[outer].size.y+1e-7>=leaves[inner].size.y
    }
    func samplingWeight(_ index:Int,blockers:[Int],inside:Bool)->Double {
      guard !blockers.isEmpty else{return 1}
      if sideBound && (bent || sideFlex) {
        // Pinned-margin flex exposes small tails between otherwise equal-trim
        // leaves. Keep all artwork; the reserve shares the bounded allocation.
        return max(1.0/1024,min(1,definition.bendMM/leaves[index].size.x+thickness*definition.openingDegrees * .pi/180/leaves[index].size.x))
      }
      guard bent else{return 0}
      // Flat containment is not occlusion after bending: concentric leaves keep
      // their own neutral arc lengths and therefore end at different angles.
      // Retain every bent face, prioritizing exposed foreedge/angle tails. This
      // estimate allocates textures; it never culls geometry or printed content.
      let leaf=leaves[index]
      if leaf.stock.sheetFaceOpacity(inside:inside)<0.999 {return 1}
      func curve(_ i:Int)->(angle:Double,surfaceRadius:Double,neutralRadius:Double) {
        let value=leaves[i],neutral=abs(radii[i]-value.stackOffsetMM)
        let z=(inside ? -1.0:1.0)*value.stock.resolvedThicknessMM/2
        return(value.size.x/neutral,abs(radii[i]-value.stackOffsetMM-z),neutral)
      }
      let target=curve(index)
      var fraction=1.0
      for blocker in blockers {
        let outer=leaves[blocker]
        if abs(outer.size.x-leaf.size.x)>1e-7 || abs(outer.size.y-leaf.size.y)>1e-7 {continue}
        let covering=curve(blocker)
        let extent=covering.surfaceRadius*(covering.angle>=Double.pi/2 ? 1:sin(covering.angle))
        let crossing=asin(min(1,max(0,extent/target.surfaceRadius)))
        let projectedTail=max(0,1-crossing*target.neutralRadius/leaf.size.x)
        let angularTail=max(0,1-covering.angle/target.angle)
        fraction=min(fraction,max(projectedTail,angularTail))
      }
      // A bounded reserve protects grazing views and bevel/sliver exposure that
      // this one-dimensional priority estimate intentionally does not ray trace.
      return max(1.0/1024,min(1,fraction))
    }
    for index in leaves.indices {
      let frontBlockers:[Int],backBlockers:[Int]
      if index<active {
        frontBlockers=(0..<index).filter{contains($0,index,inside:false)}
        backBlockers=((index+1)..<active).filter{contains($0,index,inside:true)}
      }else{
        frontBlockers=(active..<index).filter{contains($0,index,inside:false)}
        backBlockers=((index+1)..<leaves.count).filter{contains($0,index,inside:true)}
      }
      leaves[index].frontVisible=bent || sideFlex || frontBlockers.isEmpty
      leaves[index].backVisible=bent || sideFlex || backBlockers.isEmpty
      leaves[index].frontSamplingWeight=samplingWeight(index,blockers:frontBlockers,inside:false)
      leaves[index].backSamplingWeight=samplingWeight(index,blockers:backBlockers,inside:true)
    }
    let resolvedBinding:ResolvedSheetBinding?
    if let binding=definition.binding {
      let positions=binding.style == .none ? []:try binding.resolvedPositions(heightMM:size.y)
      if binding.style == .saddleStitch,leaves.count<2 {throw FormError.invalid("Saddle stitching needs at least one folded parent, represented by two physical leaves.")}
      if binding.style == .sideStaple {
        guard leaves.allSatisfy({binding.pinnedWidthMM+binding.flexWidthMM<$0.size.x}) else {
          throw FormError.invalid("Keep side fasteners and their free flex within each physical page width.")
        }
        if !isClosed {
          for leaf in leaves {_ = try SheetSideFlexProfile(binding:binding,leaf:leaf,
            stackThicknessMM:thickness,openingDegrees:definition.openingDegrees,bendMM:definition.bendMM)}
        }
      }
      resolvedBinding = .init(definition:binding,positionsMM:positions,
        penetrationMM:binding.style == .saddleStitch ? thickness/2:thickness)
    }else{resolvedBinding=nil}
    var variables=object.parameters
    for (key,value) in ["width":size.x,"height":size.y,"leafCount":Double(leaves.count),
      "pageCount":Double(document.pages.count),"stackThickness":thickness,"openingDegrees":definition.openingDegrees,
      "activeSpread":Double(definition.activeSpread),"bendMM":definition.bendMM] {variables[key]=value}
    func number(_ value:CADScalar)throws->Double {try CADExpression.evaluate(value.expression,variables:variables)}
    func vector(_ value:CADExpressionPoint)throws->Vector3 {.init(try number(value.x),try number(value.y),try number(value.z))}
    func face(_ declaration:SheetAssemblyFace?,size:Point2)throws->ResolvedSheetAssemblyFace? {
      guard let declaration else{return nil}
      guard let source=objects.first(where:{$0.id==declaration.sourceObjectID}),source.id != object.id,
        source.sheetAssembly==nil,!source.isCanvasWorkspace,
        source.recipeID=="artboard" || PaperConstruction.isPaper(source),
        let artwork=(PaperConstruction.isPaper(source) ? paperArtwork(for:source,inside:declaration.sourceSide == .inside):surfaceArtwork(source)) else {
        throw FormError.invalid("Enclosure faces need canonical artwork or ordinary paper sources; assembly/source cycles are not supported.")
      }
      let origin=try declaration.sourceOriginMM.map{Point2(try number($0.x),try number($0.y))} ?? .init()
      let extent=source.artworkSize,bleed=artwork.bleed
      guard origin.x>=(-bleed)-1e-6,origin.y>=(-bleed)-1e-6,
        origin.x+size.x<=extent.x+bleed+1e-6,origin.y+size.y<=extent.y+bleed+1e-6 else {
        throw FormError.invalid("An enclosure crop must stay within its source's physical artboard and bleed; it is never scaled to fit.")
      }
      return .init(sourceObjectID:source.id,sourceSide:declaration.sourceSide,originMM:origin)
    }
    let planes=try (definition.enclosure ?? []).map { plane -> ResolvedSheetAssemblyPlane in
      guard !plane.id.isEmpty,plane.id.utf8.count<=128,!plane.name.isEmpty,plane.name.utf8.count<=256 else {
        throw FormError.invalid("Enclosure planes need bounded stable identities and names.")
      }
      let dimensions=Point2(try number(plane.size.x),try number(plane.size.y))
      guard [dimensions.x,dimensions.y].allSatisfy({(0.01...10000).contains($0)}) else{throw FormError.invalid("Enclosure dimensions must be 0.01–10000 physical millimeters.")}
      try plane.stock.validate()
      let position=try vector(plane.positionMM),rotation=try vector(plane.rotationDegrees)
      guard [position.x,position.y,position.z].allSatisfy({abs($0)<=100000}),
        [rotation.x,rotation.y,rotation.z].allSatisfy({abs($0)<=36000}) else{throw FormError.invalid("Enclosure poses exceed bounded physical coordinates.")}
      return .init(id:plane.id,name:plane.name,size:dimensions,positionMM:position,rotationDegrees:rotation,
        stock:plane.stock,front:try face(plane.front,size:dimensions),back:try face(plane.back,size:dimensions),
        finishes:try finishes(plane.finishes))
    }
    guard Set(planes.map(\.id)).count==planes.count else{throw FormError.invalid("Enclosure plane identities must be distinct.")}
    return .init(publicationID:document.id,size:size,stackThicknessMM:thickness,
      openingDegrees:definition.openingDegrees,activeSpread:definition.activeSpread,bendMM:definition.bendMM,
      leaves:leaves,enclosure:planes,binding:resolvedBinding,parentSheets:definition.parentSheets ?? [])
  }
  public func validateSheetAssemblies() throws {
    for object in objects where object.sheetAssembly != nil {
      guard object.paperConstruction==nil,object.cloth==nil,object.patternAssembly==nil,object.cadModel==nil,
        object.cadRepresentation==nil,object.meshAsset==nil,object.textile==nil,object.artwork==nil,
        object.artworkSourceID==nil,!object.isCanvasWorkspace else {
        throw FormError.invalid("A linked sheet assembly owns no duplicate artwork or competing physical model.")
      }
      _ = try resolvedSheetAssembly(object)
    }
  }
  public var consumedSheetSourceIDs: Set<UUID> {
    objects.filter{$0.sheetAssembly != nil}.reduce(into:Set<UUID>()) { result,object in
      if let resolved=try? resolvedSheetAssembly(object){result.formUnion(resolved.sourceObjectIDs)}
      if let id=object.sheetAssembly?.publicationID,let document=publications?.first(where:{$0.id==id}) {
        result.formUnion((document.masters ?? []).map(\.sourceObjectID))
      }
    }
  }
  /// Consumed sources remain editable Canvas objects and explicit scene subjects.
  public var tablePresentationObjects: [ProductObject] {
    let consumed=consumedSheetSourceIDs
    return objects.filter{$0.hasTablePresentation && !consumed.contains($0.id)}
  }
}

public enum SheetAssemblyCommands {
  @discardableResult public static func create(in project:inout Project,definition:SheetAssemblyDefinition,
    name:String="Sheet assembly",position:Vector3 = .init()) throws -> UUID {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=500,
      [position.x,position.y,position.z].allSatisfy({$0.isFinite && abs($0)<=100000}) else {
      throw FormError.invalid("Use a sheet assembly name and finite physical placement.")
    }
    var candidate=project
    let identifier="sheet-source-"+UUID().uuidString
    candidate.recipes.append(Recipe(identifier,"Linked sheets","square.stack.3d.up","A project-authored ordered physical sheet assembly.",[]))
    var object=ProductObject(name:name,recipeID:identifier,parameters:[:],materialID:"paper-superfine",position:position)
    object.sheetAssembly=definition;candidate.objects.append(object)
    if let index=candidate.publications?.firstIndex(where:{$0.id==definition.publicationID}),candidate.publications![index].layout==nil {
      candidate.publications![index].layout = .init(facingPages:true)
    }
    try candidate.validateSheetAssemblies();project=candidate;return object.id
  }
  public static func setParentStock(in project:inout Project,objectID:UUID,parentSheetID:UUID,stock:PaperStock)throws {
    guard var definition=project.objects.first(where:{$0.id==objectID})?.sheetAssembly,
      let index=definition.parentSheets?.firstIndex(where:{$0.id==parentSheetID}) else {
      throw FormError.invalid("Choose an existing authoritative parent sheet.")
    }
    definition.parentSheets![index].stock=stock
    try configure(in:&project,objectID:objectID,definition:definition)
  }
  public static func configure(in project:inout Project,objectID:UUID,definition:SheetAssemblyDefinition) throws {
    guard let index=project.objects.firstIndex(where:{$0.id==objectID}),project.objects[index].sheetAssembly != nil,
      !project.objects[index].locked else{throw FormError.invalid("Choose an unlocked linked sheet assembly.")}
    var candidate=project;candidate.objects[index].sheetAssembly=definition
    try candidate.validateSheetAssemblies();project=candidate
  }
}
