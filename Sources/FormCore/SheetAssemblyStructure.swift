import Foundation
import FormCADModel

/// Ordered gathers refer to the authoritative parent records, never copied stock.
public struct SheetAssemblySignature:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var parentSheetIDs:[UUID]
  public init(id:UUID=UUID(),parentSheetIDs:[UUID]) {self.id=id;self.parentSheetIDs=parentSheetIDs}
}
public enum SheetPanelEdge:String,Codable,CaseIterable,Sendable {case left,right,head,tail}
public struct SheetLeafAttachment:Codable,Equatable,Sendable {
  public var planeID:String?
  public var edge:SheetPanelEdge
  public var widthMM:Double
  public init(planeID:String?=nil,edge:SheetPanelEdge = .left,widthMM:Double=8) {self.planeID=planeID;self.edge=edge;self.widthMM=widthMM}
}
/// Unnumbered physical leaves, such as interleaves, flyleaves and attached liners.
public struct SheetAssemblyAuxiliaryLeaf:Codable,Equatable,Identifiable,Sendable {
  public enum Placement:String,Codable,CaseIterable,Sendable {case front,back}
  public var id:UUID
  public var name:String
  public var placement:Placement
  public var size:CADExpressionPoint2?
  public var stock:PaperStock
  public var front:SheetAssemblyFace?
  public var back:SheetAssemblyFace?
  public var attachment:SheetLeafAttachment?
  public init(id:UUID=UUID(),name:String="Auxiliary sheet",placement:Placement = .front,
    size:CADExpressionPoint2?=nil,stock:PaperStock = .init(thicknessMM:0.12),
    front:SheetAssemblyFace?=nil,back:SheetAssemblyFace?=nil,attachment:SheetLeafAttachment?=nil) {
    self.id=id;self.name=name;self.placement=placement;self.size=size;self.stock=stock
    self.front=front;self.back=back;self.attachment=attachment
  }
}
public struct SheetEdgeArtwork:Codable,Equatable,Sendable {
  public var head:SheetAssemblyFace?
  public var tail:SheetAssemblyFace?
  public var foreEdge:SheetAssemblyFace?
  public init(head:SheetAssemblyFace?=nil,tail:SheetAssemblyFace?=nil,foreEdge:SheetAssemblyFace?=nil) {self.head=head;self.tail=tail;self.foreEdge=foreEdge}
}
public struct ResolvedSheetEdgeArtwork:Codable,Equatable,Sendable {
  public var head:ResolvedSheetAssemblyFace?
  public var tail:ResolvedSheetAssemblyFace?
  public var foreEdge:ResolvedSheetAssemblyFace?
}
/// Rest dimensions, independent of viewing pose and source crop acceptance.
public struct SheetAssemblyMeasurements:Codable,Equatable,Sendable {
  public var trimWidth:Double,trimHeight:Double,textBlockThickness:Double,bindingAllowance:Double,spineThickness:Double
  public var closedWidth:Double,closedHeight:Double,closedThickness:Double
  public var bindingFlexWidth:Double = 0
}

extension Project {
  public func sheetAssemblyMeasurements(_ object:ProductObject)throws->SheetAssemblyMeasurements {
    var rest=object;rest.sheetAssembly?.openingDegrees=0;rest.sheetAssembly?.bendMM=0
    let resolved=try resolvedSheetAssembly(rest,validateSourceCrops:false)
    return .init(trimWidth:resolved.trimWidth,trimHeight:resolved.trimHeight,textBlockThickness:resolved.textBlockThickness,
      bindingAllowance:resolved.bindingAllowance,spineThickness:resolved.spineThickness,
      closedWidth:resolved.closedWidth,closedHeight:resolved.closedHeight,closedThickness:resolved.closedThickness,
      bindingFlexWidth:resolved.bindingFlexWidth)
  }
  /// Signature order is reading order; parent order within a gather is outer to inner.
  func sheetParentGroups(_ definition:SheetAssemblyDefinition)throws->[[SheetAssemblyParentSheet]] {
    let parents=definition.parentSheets ?? []
    guard let groups=definition.signatures else{return parents.isEmpty ? []:[parents]}
    let byID=Dictionary(parents.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
    let ids=groups.flatMap(\.parentSheetIDs)
    guard !groups.isEmpty,groups.count<=51,Set(groups.map(\.id)).count==groups.count,
      groups.allSatisfy({!$0.parentSheetIDs.isEmpty}),ids.count==parents.count,Set(ids).count==ids.count,
      Set(ids)==Set(parents.map(\.id)) else {
      throw FormError.invalid("Gathered signatures must reference every authoritative parent once, in distinct nonempty ordered groups.")
    }
    return groups.map{$0.parentSheetIDs.map{byID[$0]!}}
  }
}

extension Project {
  func resolvedSheetFace(_ declaration:SheetAssemblyFace?,size:Point2,variables:[String:Double],
    assemblyID:UUID,validateSourceCrops:Bool)throws->ResolvedSheetAssemblyFace? {
    guard let declaration else{return nil}
    let origin=try declaration.sourceOriginMM.map{Point2(
      try CADExpression.evaluate($0.x.expression,variables:variables),try CADExpression.evaluate($0.y.expression,variables:variables))} ?? .init()
    guard [origin.x,origin.y].allSatisfy({$0.isFinite && abs($0)<=100000}) else{throw FormError.invalid("A physical source crop needs finite bounded millimeter coordinates.")}
    // Dimension dependencies must resolve before their dependent 2D sources can
    // be resized. Crops and source ownership are checked by the full validator.
    guard validateSourceCrops else{return .init(sourceObjectID:declaration.sourceObjectID,sourceSide:declaration.sourceSide,originMM:origin)}
    guard let source=objects.first(where:{$0.id==declaration.sourceObjectID}),source.id != assemblyID,
      source.sheetAssembly==nil,!source.isCanvasWorkspace,
      isIndependentFlatArtworkSource(source) || PaperConstruction.isPaper(source),
      let artwork=(PaperConstruction.isPaper(source) ? paperArtwork(for:source,inside:declaration.sourceSide == .inside):surfaceArtwork(source)) else {
      throw FormError.invalid("Physical faces need canonical artwork or ordinary paper sources; assembly/source cycles are not supported.")
    }
    let extent=source.artworkSize,bleed=artwork.bleed
    guard origin.x>=(-bleed)-1e-6,origin.y>=(-bleed)-1e-6,
      origin.x+size.x<=extent.x+bleed+1e-6,origin.y+size.y<=extent.y+bleed+1e-6 else {
      throw FormError.invalid("A physical crop must stay within its source's actual artboard and bleed; it is never scaled to fit.")
    }
    return .init(sourceObjectID:source.id,sourceSide:declaration.sourceSide,originMM:origin)
  }
}

extension SheetAssemblyCommands {
  /// Regroup and reimpose in a candidate without rewriting pages or parent stock.
  public static func reimposingSignatures(in project:Project,objectID:UUID,parentSheetsPerSignature:Int)throws->SheetAssemblyDefinition {
    guard (0...51).contains(parentSheetsPerSignature),
      let index=project.objects.firstIndex(where:{$0.id==objectID}),
      var definition=project.objects[index].sheetAssembly,definition.leaves==nil,
      let parents=definition.parentSheets,!parents.isEmpty else {
      throw FormError.invalid("Regrouping needs implicit leaves and existing authoritative parent sheets, using 0–51 parents per signature.")
    }
    let ordered=try project.sheetParentGroups(definition).flatMap{$0}
    if parentSheetsPerSignature==0 {definition.signatures=nil}
    else {
      let existing=definition.signatures ?? []
      definition.signatures=stride(from:0,to:ordered.count,by:parentSheetsPerSignature).enumerated().map{ordinal,start in
        SheetAssemblySignature(id:existing.indices.contains(ordinal) ? existing[ordinal].id:UUID(),
          parentSheetIDs:ordered[start..<min(ordered.count,start+parentSheetsPerSignature)].map(\.id))
      }
    }
    var candidate=project;candidate.objects[index].sheetAssembly=definition
    try reconcileParentSheets(in:&candidate,publicationID:definition.publicationID)
    return candidate.objects[index].sheetAssembly!
  }
}

extension SheetAssemblyDefinition {
  public var requiresAdvancedStructureSchema:Bool {
    derived != nil || signatures != nil || auxiliaryLeaves != nil || edgeArtwork != nil || (enclosure?.count ?? 0)>32 || enclosure?.contains(where:{$0.features != nil}) == true ||
      binding.map{$0.style == .adhesive || $0.style == .sewn || $0.adhesiveMM != nil || $0.sewingSwellMM != nil} == true
  }
  /// Canonical artwork consumers only. Dimension-input products are not hidden.
  public var artworkSourceObjectIDs:Set<UUID> {
    var result=Set((enclosure ?? []).flatMap{[$0.front?.sourceObjectID,$0.back?.sourceObjectID].compactMap{$0}})
    result.formUnion((auxiliaryLeaves ?? []).flatMap{[$0.front?.sourceObjectID,$0.back?.sourceObjectID].compactMap{$0}})
    result.formUnion([edgeArtwork?.head?.sourceObjectID,edgeArtwork?.tail?.sourceObjectID,edgeArtwork?.foreEdge?.sourceObjectID].compactMap{$0})
    for plane in enclosure ?? [] {result.formUnion((plane.features?.recesses ?? []).compactMap{$0.insert?.face?.sourceObjectID})}
    return result
  }
}
