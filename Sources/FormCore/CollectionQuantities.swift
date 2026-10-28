import Foundation

public struct CollectionFinding:Codable,Equatable,Sendable {
  public var severity:String,rowID:String?,message:String
  public init(_ message:String,rowID:String?=nil,severity:String="warning") {self.message=message;self.rowID=rowID;self.severity=severity}
}
public struct CollectionOccurrence:Codable,Equatable,Sendable {
  public var id:String,runID:UUID,objectID:UUID?,name:String,quantity:Int,parentID:String?
}
public struct CollectionLine:Codable,Equatable,Identifiable,Sendable {
  public var id:String,name:String,role:String
  public var unit:CollectionUnit
  public var quantity:String?
  public var evidence:CollectionEvidence
  public var formula:String
  public var costBasis:CollectionCostBasis?
  public var stockConflict:Bool?
  public var stockAvailabilityUnknown:Bool?
  public var requiredCost:Bool
  public var unitPrice:String?,currency:String?,cost:String?
  public var stock:CollectionStockSnapshot?
  public var excludedReason:String?
  public var supplier:String?,sku:String?,notes:String?
  public var calculation:CollectionCalculation?
  public init(id:String,name:String,role:String,unit:CollectionUnit,quantity:String?,evidence:CollectionEvidence,formula:String,requiredCost:Bool=true) {self.id=id;self.name=name;self.role=role;self.unit=unit;self.quantity=quantity;self.evidence=evidence;self.formula=formula;self.requiredCost=requiredCost}
}
public struct CollectionScope:Sendable {
  public var occurrences:[CollectionOccurrence]=[]
  public var lines:[CollectionLine]=[]
  public var findings:[CollectionFinding]=[]
  public var expectedCopies:[UUID:Set<String>]=[:]
  public var expectedMaterials:[UUID:[String:String]]=[:]
  public var expectedStocks:[UUID:[String:Material]]=[:]
}
public enum CollectionQuantities {
  public static func parent(_ o:ProductObject)->UUID? {o.textile?.attachment?.garmentID ?? o.patternAssemblyAttachment?.surfaceObjectID ?? o.clothAttachment?.surfaceObjectID}
  public static func pieceKey(_ owner:UUID,_ element:UUID,_ copy:Int)->String {owner.uuidString+"/"+element.uuidString+"/"+String(copy)}
  public static func scope(_ plan:CollectionProductionPlan,project:Project)throws->CollectionScope {
    try plan.validate()
    guard project.objects.count<=CollectionLimits.objects else{throw FormError.invalid("Collection source exceeds256 objects; split this project before preflight/capture.")}
    let rules=Dictionary(uniqueKeysWithValues:plan.rules.map{($0.rowID,$0)})
    let objects=Dictionary(uniqueKeysWithValues:project.objects.map{($0.id,$0)}),children=Dictionary(grouping:project.objects.filter{parent($0) != nil},by:{parent($0)!})
    var result=CollectionScope(),claimed=Set<UUID>(),managedClaims=Set<String>(),assemblyClaims=Set<String>()
    func append(_ line:CollectionLine)throws {guard result.lines.count<CollectionLimits.rows else{throw FormError.invalid("The collection exceeds2,000 BOM rows before geometry/rendering.")};result.lines.append(line)}
    func material(_ materialID:String?,prefix:String,name:String,required:Bool)throws {
      let value=materialID.flatMap{id -> Material? in let value=project.material(id);return value.id==id ? value:nil}
      var line=CollectionLine(id:prefix,name:name+(value.map{" / "+$0.name} ?? " / Unassigned"),role:"specification",unit:.m,quantity:nil,evidence:.unknown,formula:"Material identity only; visual geometry supplies no consumption.",requiredCost:required)
      line.supplier=value?.fabric?.supplier;line.sku=value?.fabric?.sku;try append(line)
    }
    for run in plan.runs {
      if let id=run.objectID {
        guard let object=objects[id],object.textile != nil || object.patternAssembly != nil || object.cloth != nil else{throw FormError.invalid("Choose an actual textile/assembly object; source artboards and preview meshes are not production units.")}
        var pending:[(ProductObject,String?)]=[(object,nil)]
        while let (item,parentPath)=pending.popLast() {
          guard claimed.insert(item.id).inserted else{throw FormError.invalid("A physical object is counted through multiple roots/attachments. Choose one authoritative run or a separate spare object.")}
          let path=run.id.uuidString+"/"+item.id.uuidString
          result.occurrences.append(.init(id:path,runID:run.id,objectID:item.id,name:item.name,quantity:run.quantity,parentID:parentPath))
          let rule=rules[path],basis=rule?.costBasis ?? (item.patternAssembly != nil || item.cloth != nil ? .made:item.textile?.kind == .garment ? .purchased:.unresolved)
          var component=CollectionLine(id:path,name:item.name,role:"component",unit:.piece,quantity:String(run.quantity),evidence:.computed,formula:"Explicit run quantity × one physical occurrence; attached/source appearances counted once.",requiredCost:basis != .made)
          component.costBasis=basis;component.sku=item.textile?.sku;component.notes=item.textile?.notes
          if item.patternAssembly != nil || item.cloth != nil {component.requiredCost=false;component.role="finishedProduct";component.costBasis=nil}
          try append(component)
          try material(item.materialID,prefix:path+"/material",name:"Material",required:basis == .made && item.patternAssembly==nil)
          if let lining=item.textile?.liningMaterialID {try material(lining,prefix:path+"/lining",name:"Lining",required:basis == .made)}
          if let trim=item.textile?.trimMaterialID {try material(trim,prefix:path+"/trim",name:"Trim",required:basis == .made)}
          if item.textile?.process == .directPrint {result.findings.append(.init("Transfer geometry identifies dimensions, not ink/film/powder consumption. Declare allocation/rates explicitly.",rowID:path))}
          if let assembly=item.patternAssembly {
            var expected=Set<String>()
            for panel in assembly.panels {
              guard let owner=objects[assembly.sourceObjectID],let e=owner.artwork?.elements.first(where:{$0.id==panel.panel.elementID}),let sourcePiece=e.sewingPiece,panel.panel.copy>=1,panel.panel.copy<=sourcePiece.cutQuantity else{throw FormError.invalid("An assembly's original cut copy is missing. Collection preflight never repairs or meshes it.")}
              let key=pieceKey(assembly.sourceObjectID,panel.panel.elementID,panel.panel.copy)
              result.expectedMaterials[run.id,default:[:]][key]=panel.material.id;result.expectedStocks[run.id,default:[:]][key]=panel.material
              guard !managedClaims.contains(key) else{throw FormError.invalid("Managed size and assembled preview duplicate the same physical source copies.")};assemblyClaims.insert(key);expected.insert(key)}
            result.expectedCopies[run.id,default:[]].formUnion(expected)
            result.findings.append(.init("Assembly source/material coordinates captured without meshing, preparation or cloth Run.",rowID:path))
          }
          let attached=children[item.id] ?? []
          if run.includeAttachments {pending.append(contentsOf:attached.sorted{$0.id.uuidString>$1.id.uuidString}.map{($0,path)})}
          else if !attached.isEmpty {result.findings.append(.init("\(attached.count) attached source objects are deliberately outside this run.",rowID:path))}
        }
      } else {
        guard let block=project.garmentBlocks?.first(where:{$0.id==run.garmentBlockID}),let size=block.sizes.first(where:{$0.id==run.sizeID}) else{throw FormError.invalid("A managed garment run refers to a missing block/size.")}
        let prefix=run.id.uuidString+"/garment",resolved=try block.resolved(size),bindings=block.bindings.filter{$0.sizeID==size.id}
        guard bindings.count==3 else{throw FormError.invalid("The managed size needs all actual front/back/elastic source bindings.")}
        try append(.init(id:prefix,name:block.name+" / "+size.label,role:"finishedProduct",unit:.piece,quantity:String(run.quantity),evidence:.computed,formula:"Explicit finished-garment run; source pieces are not additional sale units.",requiredCost:false))
        result.occurrences.append(.init(id:prefix,runID:run.id,objectID:nil,name:block.name+" / "+size.label,quantity:run.quantity,parentID:nil))
        for conflict in try GarmentBlockSources.conflicts(block,in:project) {result.findings.append(.init(conflict,rowID:prefix))}
        for ref in bindings {
          guard let owner=objects[ref.objectID],let art=owner.artwork,let e=art.elements.first(where:{$0.id==ref.elementID}),let piece=e.sewingPiece else{throw FormError.invalid("A managed source piece is missing; capture never recreates it.")}
          let geometry=try SewingPatterns.geometry(e,in:art),key=pieceKey(owner.id,e.id,1)
          guard !assemblyClaims.contains(key),managedClaims.insert(key).inserted else{throw FormError.invalid("Managed size and assembly roots duplicate an existing source copy.")}
          if ref.role != .elastic {for copy in 1...piece.cutQuantity {let k=pieceKey(owner.id,e.id,copy);result.expectedCopies[run.id,default:[]].insert(k);if let material=piece.materialID {result.expectedMaterials[run.id,default:[:]][k]=material}}}
          let current=try GarmentBlockSources.fingerprint(e)==ref.fingerprint
          if ref.role == .elastic {
            let length=current ? try CollectionDecimal.computed(resolved.elasticCutLength/1000*Double(run.quantity)):nil
            var line=CollectionLine(id:prefix+"/elastic",name:"Elastic cut / "+size.label,role:"trim",unit:.m,quantity:length,evidence:length==nil ? .unknown:.computed,formula:"Recorded elastic cut (including lap once) × run quantity /1000; source declaration, not worn-fit measurement.")
            line.notes=block.style.elasticMaterialID;try append(line)
          } else {
            let area=try CollectionDecimal.computed(SewingLayoutGeometry.materialArea(geometry.allCutContours)*Double(piece.cutQuantity*run.quantity)/1_000_000)
            try append(.init(id:prefix+"/"+ref.role.rawValue+"/cutArea",name:piece.name+" / net cut area",role:"geometry",unit:.m2,quantity:area,evidence:.computed,formula:"Actual cut contours/holes × source cut quantity × run; this is not allocated fabric yardage.",requiredCost:false))
          }
        }
      }
    }
    // Layout quantities are actual allocation, not sums of component silhouettes.
    var covered:[UUID:Set<String>]=[:]
    for allocation in plan.layouts {
      guard let run=plan.runs.first(where:{$0.id==allocation.runID}),let owner=objects[allocation.objectID],let art=owner.artwork,let layout=art.sewingLayout else{throw FormError.invalid("An allocation needs an existing actual material layout.")}
      let preflight=try SewingLayouts.preflight(layout,source:art)
      guard preflight.isValid else{throw FormError.invalid("Allocated layout is incomplete/invalid: "+preflight.issues.map(\.message).joined(separator:" "))}
      let copies=Set(preflight.placements.flatMap{p in p.placement.copies.map{pieceKey(owner.id,p.placement.elementID,$0)}})
      guard let expected=result.expectedCopies[run.id],!copies.isEmpty,copies.isSubset(of:expected),copies.isDisjoint(with:covered[run.id] ?? []) else{throw FormError.invalid("Layout copies do not match the run or duplicate previously allocated material.")}
      guard copies.allSatisfy({result.expectedMaterials[run.id]?[$0].map({$0==layout.materialID}) ?? true}) else{throw FormError.invalid("A layout material does not match the actual managed/assembly source assignment.")}
      covered[run.id,default:[]].formUnion(copies)
      let id=run.id.uuidString+"/layout/"+layout.id.uuidString
      let length=try CollectionDecimal.product(CollectionDecimal.computed(preflight.consumedLength/1000),String(run.quantity))
      var line=CollectionLine(id:id,name:layout.name+" / repeated actual layout",role:"allocation",unit:.m,quantity:length,evidence:.computed,formula:"Complete one-unit layout length × \(run.quantity) identical units; full open width \(layout.stockWidth!) mm, no cross-unit nesting assumption.")
      let snapshots=copies.compactMap{result.expectedStocks[run.id]?[$0]}
      let stockMaterial=snapshots.first ?? project.material(layout.materialID)
      line.stock = .init(fabric:stockMaterial)
      if let width=stockMaterial.fabric?.usableWidth,abs(width-layout.stockWidth!)>0.001 {line.stockConflict=true;result.findings.append(.init("Allocated width differs from its portable stock width; combined availability is unknown.",rowID:id))}
      else if stockMaterial.fabric?.usableWidth==nil {line.stockAvailabilityUnknown=true;result.findings.append(.init("Portable fabric width is unknown; linear stock comparison needs an explicit matching width.",rowID:id))}
      if snapshots.contains(where:{$0 != stockMaterial}) {line.stockConflict=true;result.findings.append(.init("Assembly panel stock snapshots conflict; availability stays unknown.",rowID:id))}
      if let rate=layout.costPerSquareMeter,let currency=layout.costCurrency {
        // Keep the rate unit as area. Availability still has its own length row.
        let area=try CollectionDecimal.product(CollectionDecimal.computed(preflight.allocatedAreaMM2/1_000_000),String(run.quantity))
        var costLine=CollectionLine(id:id+"/area",name:layout.name+" / allocated open-stock area",role:"allocationCost",unit:.m2,quantity:area,evidence:.computed,formula:"Full open stock width × allocated length, folded plies not charged twice.")
        costLine.unitPrice=try CollectionDecimal.computed(rate);costLine.currency=currency;try append(costLine);line.requiredCost=false
      }
      try append(line)
    }
    for (run,copies) in result.expectedCopies where !copies.isSubset(of:covered[run] ?? []) {result.findings.append(.init("Some source cut copies have no complete allocated layout; fabric usage/cost is unknown.",rowID:run.uuidString))
      try append(.init(id:run.uuidString+"/unallocated",name:"Unallocated source fabric",role:"material",unit:.m,quantity:nil,evidence:.unknown,formula:"No validated layout coverage; net area is not yardage."))}
    for extra in plan.extras {
      let count=extra.runID.flatMap{id in plan.runs.first{$0.id==id}?.quantity} ?? 1
      let quantity=try extra.quantity.map{try CollectionDecimal.product($0,String(count))}
      var line=CollectionLine(id:"extra/"+extra.id.uuidString,name:extra.name,role:"declared",unit:extra.unit,quantity:quantity,evidence:quantity==nil ? .unknown:.declared,formula:extra.runID == nil ? "Declared once per collection":"Declared per run item × \(count)")
      line.unitPrice=extra.unitPrice;line.currency=extra.currency;line.supplier=extra.supplier;line.sku=extra.sku;line.notes=extra.notes;try append(line)
    }
    guard result.lines.count<=CollectionLimits.rows else{throw FormError.invalid("Too many collection rows.")}
    return result
  }
}
