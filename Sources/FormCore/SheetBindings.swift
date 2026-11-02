import Foundation

public enum SheetBindingStyle:String,Codable,CaseIterable,Sendable {case none,saddleStitch,sideStaple}
public enum SheetParentPrintIntent:String,Codable,CaseIterable,Sendable {case color,blackOnly}

/// Physical fasteners and the free margin's viewing flex, independent of artwork.
public struct SheetBindingDefinition:Codable,Equatable,Sendable {
  public var style:SheetBindingStyle
  public var count:Int
  /// Crown centers measured down from the physical head edge, in millimeters.
  public var positionsMM:[Double]?
  public var endMarginMM:Double
  public var edgeInsetMM:Double
  public var crownLengthMM:Double
  public var wireDiameterMM:Double
  public var clinchLengthMM:Double
  public var flexWidthMM:Double
  public init(style:SheetBindingStyle = .none,count:Int=2,positionsMM:[Double]?=nil,
    endMarginMM:Double=45,edgeInsetMM:Double=7,crownLengthMM:Double=12,
    wireDiameterMM:Double=0.45,clinchLengthMM:Double=2,flexWidthMM:Double=8) {
    self.style=style;self.count=count;self.positionsMM=positionsMM;self.endMarginMM=endMarginMM
    self.edgeInsetMM=edgeInsetMM;self.crownLengthMM=crownLengthMM;self.wireDiameterMM=wireDiameterMM
    self.clinchLengthMM=clinchLengthMM;self.flexWidthMM=flexWidthMM
  }
  private enum CodingKeys:String,CodingKey {case style,count,positionsMM,endMarginMM,edgeInsetMM,crownLengthMM,wireDiameterMM,clinchLengthMM,flexWidthMM}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    self.init(style:try c.decodeIfPresent(SheetBindingStyle.self,forKey:.style) ?? .none,
      count:try c.decodeIfPresent(Int.self,forKey:.count) ?? 2,
      positionsMM:try c.decodeIfPresent([Double].self,forKey:.positionsMM),
      endMarginMM:try c.decodeIfPresent(Double.self,forKey:.endMarginMM) ?? 45,
      edgeInsetMM:try c.decodeIfPresent(Double.self,forKey:.edgeInsetMM) ?? 7,
      crownLengthMM:try c.decodeIfPresent(Double.self,forKey:.crownLengthMM) ?? 12,
      wireDiameterMM:try c.decodeIfPresent(Double.self,forKey:.wireDiameterMM) ?? 0.45,
      clinchLengthMM:try c.decodeIfPresent(Double.self,forKey:.clinchLengthMM) ?? 2,
      flexWidthMM:try c.decodeIfPresent(Double.self,forKey:.flexWidthMM) ?? 8)
  }
  public func resolvedPositions(heightMM:Double)throws->[Double] {
    guard (1...8).contains(count),heightMM.isFinite,heightMM>0,
      [endMarginMM,edgeInsetMM,crownLengthMM,wireDiameterMM,clinchLengthMM,flexWidthMM].allSatisfy(\.isFinite),
      (0...5000).contains(endMarginMM),(0.5...40).contains(edgeInsetMM),
      (1...40).contains(crownLengthMM),(0.1...2).contains(wireDiameterMM),
      (0.5...10).contains(clinchLengthMM),(1...50).contains(flexWidthMM),
      crownLengthMM>wireDiameterMM*2,clinchLengthMM<crownLengthMM/2 else {
      throw FormError.invalid("Use one to eight bounded physical fasteners, finite crown/wire/clinch dimensions and margin flex.")
    }
    let positions:[Double]
    if let positionsMM {guard positionsMM.count==count else{throw FormError.invalid("Fastener count must match its explicit physical center positions.")};positions=positionsMM}
    else if count==1 {positions=[heightMM/2]}
    else {positions=(0..<count).map{endMarginMM+(heightMM-2*endMarginMM)*Double($0)/Double(count-1)}}
    let radius=crownLengthMM/2+wireDiameterMM
    let sorted=positions.sorted()
    guard sorted.allSatisfy({$0.isFinite && $0>=radius && $0<=heightMM-radius}),
      zip(sorted,sorted.dropFirst()).allSatisfy({pair in pair.1-pair.0>=crownLengthMM+2*wireDiameterMM}) else {
      throw FormError.invalid("Keep fastener crowns within the head/tail edges and distinct from neighboring crowns.")
    }
    return sorted
  }
  public var pinnedWidthMM:Double {edgeInsetMM+max(1,2*wireDiameterMM)}
}

/// A complete folded parent: front/back each name physical left/right print slots.
/// Stock is authoritative here; viewing leaves derive it rather than copying it.
public struct SheetAssemblyParentSheet:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var frontPageIDs:[UUID?]
  public var backPageIDs:[UUID?]
  public var stock:PaperStock
  public var sizeMM:Point2
  public var printIntent:SheetParentPrintIntent
  public init(id:UUID=UUID(),frontPageIDs:[UUID?],backPageIDs:[UUID?],stock:PaperStock,
    sizeMM:Point2,printIntent:SheetParentPrintIntent = .color) {
    self.id=id;self.frontPageIDs=frontPageIDs;self.backPageIDs=backPageIDs;self.stock=stock
    self.sizeMM=sizeMM;self.printIntent=printIntent
  }
  private enum CodingKeys:String,CodingKey {case id,frontPageIDs,backPageIDs,stock,sizeMM,printIntent}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    self.init(id:try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID(),
      frontPageIDs:try c.decode([UUID?].self,forKey:.frontPageIDs),backPageIDs:try c.decode([UUID?].self,forKey:.backPageIDs),
      stock:try c.decode(PaperStock.self,forKey:.stock),sizeMM:try c.decode(Point2.self,forKey:.sizeMM),
      printIntent:try c.decodeIfPresent(SheetParentPrintIntent.self,forKey:.printIntent) ?? .color)
  }
  public var pageIDs:[UUID] {(frontPageIDs+backPageIDs).compactMap{$0}}
}

public struct ResolvedSheetBinding:Codable,Equatable,Sendable {
  public var definition:SheetBindingDefinition
  public var positionsMM:[Double]
  public var penetrationMM:Double
}

extension Project {
  func sheetParentAssignments(_ definition:SheetAssemblyDefinition,document:PublicationDocument)throws->[UUID:SheetAssemblyParentSheet] {
    guard let parents=definition.parentSheets,!parents.isEmpty else{return [:]}
    guard parents.count<=51,Set(parents.map(\.id)).count==parents.count else {
      throw FormError.invalid("Use at most 51 distinct folded parent sheets.")
    }
    let pages=Dictionary(uniqueKeysWithValues:document.pages.map{($0.id,$0)})
    var assignments=[UUID:SheetAssemblyParentSheet]()
    for parent in parents {
      try parent.stock.validate()
      guard parent.frontPageIDs.count==2,parent.backPageIDs.count==2,
        [parent.sizeMM.x,parent.sizeMM.y].allSatisfy({$0.isFinite && (1...20000).contains($0)}),!parent.pageIDs.isEmpty else {
        throw FormError.invalid("A folded parent needs two front and two reverse print slots and finite physical sheet dimensions.")
      }
      for id in parent.pageIDs {
        guard assignments[id]==nil,let page=pages[id],let source=objects.first(where:{$0.id==page.objectID}),
          abs(parent.sizeMM.x-2*source.artworkSize.x)<0.001,abs(parent.sizeMM.y-source.artworkSize.y)<0.001 else {
          throw FormError.invalid("Each parent-sheet slot must use one distinct canonical page at its actual two-up physical trim size.")
        }
        assignments[id]=parent
      }
    }
    guard Set(assignments.keys)==Set(pages.keys) else{throw FormError.invalid("Declared parent sheets must cover every canonical publication page exactly once.")}
    do {
      var slots:[UUID?]=document.layout?.firstPageSide == .verso ? [nil]:[]
      slots+=document.pages.map{Optional($0.id)}
      while slots.count%4 != 0 {slots.append(nil)}
      guard parents.count==slots.count/4 else{throw FormError.invalid("Folded parent-sheet count must match the complete nested page run.")}
      for (index,parent) in parents.enumerated() {
        guard parent.frontPageIDs==[slots[slots.count-1-index*2],slots[index*2]],
          parent.backPageIDs==[slots[index*2+1],slots[slots.count-2-index*2]] else {
          throw FormError.invalid("Folded parent sheets must follow the actual nested front/reverse page order, including declared blank slots.")
        }
      }
    }
    return assignments
  }
  func parentLeafDeclarations(_ definition:SheetAssemblyDefinition,document:PublicationDocument)->[(leaf:SheetAssemblyLeaf,parent:SheetAssemblyParentSheet)] {
    let parents=definition.parentSheets ?? []
    func leaf(_ parent:SheetAssemblyParentSheet,front:UUID?,back:UUID?)->(SheetAssemblyLeaf,SheetAssemblyParentSheet) {
      let identity:UUID
      if let page=front ?? back {identity=ComponentCommands.derivedID(document.id,page)}
      else {identity=ComponentCommands.derivedID(parent.id,UUID(uuidString:"E57412D3-7D2F-4F34-A766-8118151941BD")!)}
      return(.init(id:identity,frontPageID:front,backPageID:back),parent)
    }
    return parents.map{leaf($0,front:$0.frontPageIDs[1],back:$0.backPageIDs[0])}
      + parents.reversed().map{leaf($0,front:$0.backPageIDs[1],back:$0.frontPageIDs[0])}
  }
  public func parentSheet(forPageObjectID objectID:UUID,in assembly:ProductObject)throws->SheetAssemblyParentSheet? {
    guard let definition=assembly.sheetAssembly,let document=publications?.first(where:{$0.id==definition.publicationID}),
      let page=document.pages.first(where:{$0.objectID==objectID}) else{return nil}
    return try sheetParentAssignments(definition,document:document)[page.id]
  }
}


extension SheetAssemblyCommands {
  /// Reimpose implicit physical parents in the same transaction as a reading-order
  /// edit. Parent identity, stock and printing intent belong to physical sheets;
  /// nullable slots express actual padding without adding logical source pages.
  public static func reconcileParentSheets(in project:inout Project,publicationID:UUID)throws {
    guard let document=project.publications?.first(where:{$0.id==publicationID}) else {
      throw FormError.invalid("Choose an existing publication before reconciling its physical sheets.")
    }
    var candidate=project
    for index in candidate.objects.indices {
      guard var definition=candidate.objects[index].sheetAssembly,
        definition.publicationID==publicationID,definition.leaves==nil,
        let existing=definition.parentSheets,!existing.isEmpty else{continue}
      guard !document.pages.isEmpty else{throw FormError.invalid("A physical sheet assembly needs a nonempty publication.")}
      var slots:[UUID?]=document.layout?.firstPageSide == .verso ? [nil]:[]
      slots+=document.pages.map{Optional($0.id)}
      while slots.count%4 != 0{slots.append(nil)}
      var parents=[SheetAssemblyParentSheet]()
      for ordinal in 0..<(slots.count/4) {
        let front=[slots[slots.count-1-ordinal*2],slots[ordinal*2]]
        let back=[slots[ordinal*2+1],slots[slots.count-2-ordinal*2]]
        let parent:SheetAssemblyParentSheet
        if existing.indices.contains(ordinal) {parent=existing[ordinal]}
        else {
          guard let pageID=(front+back).compactMap({$0}).first,
            let page=document.pages.first(where:{$0.id==pageID}),
            let source=candidate.objects.first(where:{$0.id==page.objectID}) else {
            throw FormError.invalid("New parent sheets need an actual canonical page trim.")
          }
          parent = .init(frontPageIDs:front,backPageIDs:back,stock:definition.stock,
            sizeMM:.init(source.artworkSize.x*2,source.artworkSize.y),printIntent:.color)
        }
        var updated=parent;updated.frontPageIDs=front;updated.backPageIDs=back;parents.append(updated)
      }
      definition.parentSheets=parents
      definition.activeSpread=min(definition.activeSpread,parents.count*2)
      candidate.objects[index].sheetAssembly=definition
    }
    // A generic multi-publication delete reconciles each updated run in turn.
    // Other publications may be temporarily between their list and parent edit.
    for object in candidate.objects where object.sheetAssembly?.publicationID==publicationID {
      _ = try candidate.resolvedSheetAssembly(object)
    }
    project=candidate
  }
}
