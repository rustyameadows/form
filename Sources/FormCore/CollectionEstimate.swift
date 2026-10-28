import Foundation

public struct CollectionStockCheck:Codable,Equatable,Sendable {
  public var key:String,name:String,unit:CollectionUnit,knownDemand:String,available:String?,status:String
  public var contributors:[String]
}
public struct CollectionPreflight:Codable,Equatable,Sendable {
  public var occurrences:[CollectionOccurrence],rows:[CollectionLine],findings:[CollectionFinding],stock:[CollectionStockCheck]
  public var knownSubtotals:[String:String]
  public var completeTotal:String?,currency:String?
  public var unknowns:[String]
  public var canCapture:Bool {findings.allSatisfy{$0.severity != "error"}}
}
public enum CollectionEstimate {
  public static func embroideryLines(job:ProductionJob,revision:ProductionJobRevision,expectedQuantity:Int)throws->[CollectionLine] {
    guard revision.quantity==expectedQuantity,job.quantity==expectedQuantity else{throw FormError.invalid("Archived process quantity does not match its exact object's collection occurrences; it was not multiplied again.")}
    let a=revision.assumptions,prefix="process/"+job.id.uuidString,n=String(expectedQuantity),palette=revision.object.textile?.embroidery?.threads ?? []
    var rows:[CollectionLine]=[]
    for u in revision.usage {
      guard palette.indices.contains(u.threadIndex) else{throw FormError.invalid("An archived thread schedule has no matching palette entry.")}
      let t=palette[u.threadIndex],id=prefix+"/thread/"+String(u.threadIndex),needle=try CollectionDecimal.product(CollectionDecimal.computed(u.needleMeters),n)
      rows.append(.init(id:id+"/needle",name:t.name+" / generated needle path",role:"geometry",unit:.m,quantity:needle,evidence:.computed,formula:"Archived generated stitch length × quantity; includes underlay/ties, excludes travel; not actual thread consumption.",requiredCost:false))
      var amount:String?
      if let f=a.upperThreadFactor,let extra=a.allowanceMetersPerThreadPerItem {
        let per=try CollectionDecimal.add(CollectionDecimal.multiply(CollectionDecimal.resolved(CollectionDecimal.computed(u.needleMeters)),CollectionDecimal.resolved(CollectionDecimal.computed(f))),CollectionDecimal.resolved(CollectionDecimal.computed(extra)))
        amount=try CollectionDecimal.string(CollectionDecimal.multiply(per,CollectionDecimal.resolved(n)))
      }
      var row=CollectionLine(id:id,name:t.name+" / planned upper thread",role:"thread",unit:.m,quantity:amount,evidence:amount==nil ? .unknown:.declared,formula:"(Archived needle m × declared factor \(a.upperThreadFactor.map(String.init(describing:)) ?? "unknown") + declared extra m \(a.allowanceMetersPerThreadPerItem.map(String.init(describing:)) ?? "unknown")) × \(n)")
      if let stock=t.stock {
        row.stock = .init(thread:stock);row.supplier=stock.supplier;row.sku=stock.sku;row.currency=stock.currency
        if let amount,let price=stock.spoolPrice,let meters=stock.spoolMeters {
          do {let calculation=try CollectionDecimal.estimateDivision(CollectionDecimal.multiply(CollectionDecimal.resolved(amount),CollectionDecimal.resolved(CollectionDecimal.computed(price))),CollectionDecimal.resolved(CollectionDecimal.computed(meters)),inputs:["estimated_meters":amount,"spool_price":String(price),"spool_meters":String(meters)]);row.calculation=calculation;row.cost=calculation.result}
          catch {row.notes="Exact cost cannot be represented within decimal bounds: "+error.localizedDescription}
        }
      }
      rows.append(row)
    }
    var base=CollectionLine(id:prefix+"/base",name:revision.object.name+" / legacy base component",role:"unmapped",unit:.piece,quantity:n,evidence:.declared,formula:"Captured component base cost × captured job quantity; requires one explicit collection cost owner.",requiredCost:false)
    base.unitPrice=try a.baseUnitCost.map{try CollectionDecimal.computed($0)};base.currency=a.baseCurrency;base.excludedReason="Unmapped legacy base cost; link to one physical BOM row instead of adding it twice.";rows.append(base)
    for e in a.extraBOM {
      let unit=["item":CollectionUnit.piece,"piece":.piece,"m":.m,"m2":.m2,"min":.minute][e.unit]
      var row=CollectionLine(id:prefix+"/bom/"+e.id.uuidString,name:e.name,role:"unmapped",unit:unit ?? .piece,quantity:unit==nil ? nil:try CollectionDecimal.product(CollectionDecimal.computed(e.quantityPerItem),n),evidence:.declared,formula:"Captured extra BOM: \(e.quantityPerItem) \(e.unit) per component × \(n); original source unit retained.",requiredCost:false)
      row.unitPrice=try e.unitCost.map{try CollectionDecimal.computed($0)};row.currency=e.currency;row.supplier=e.supplier;row.sku=e.sku;row.excludedReason="Unmapped legacy extra; explicitly map its unit/cost owner before inclusion.";rows.append(row)
    }
    let minutes=try a.laborMinutesPerItem.map{try CollectionDecimal.product(CollectionDecimal.computed($0),n)}
    var labor=CollectionLine(id:prefix+"/labor",name:revision.object.name+" / declared labor",role:"labor",unit:.minute,quantity:minutes,evidence:minutes==nil ? .unknown:.declared,formula:"Captured minutes/item × \(n), multiplied by declared hourly rate/60; no machine timing inferred.")
    labor.currency=a.laborCurrency
    if let minutes,let rate=a.hourlyLaborRate {
      do {let calculation=try CollectionDecimal.estimateDivision(CollectionDecimal.multiply(CollectionDecimal.resolved(minutes),CollectionDecimal.resolved(CollectionDecimal.computed(rate))),Decimal(60),inputs:["minutes":minutes,"hourly_rate":String(rate)]);labor.calculation=calculation;labor.cost=calculation.result}catch {labor.notes="Exact labor cost is unknown: "+error.localizedDescription}
    }
    rows.append(labor);return rows
  }
  public static func evaluate(_ plan:CollectionProductionPlan,scope:CollectionScope,processRows:[CollectionLine]=[])throws->CollectionPreflight {
    guard scope.lines.count+processRows.count<=CollectionLimits.rows else{throw FormError.invalid("The collection exceeds2,000 rows before rendering.")}
    var rows=scope.lines+processRows,findings=scope.findings,excludedRequired:[String]=[]
    let known=Set(rows.map(\.id)),indices=Dictionary(rows.indices.map{(rows[$0].id,$0)},uniquingKeysWith:{first,_ in first});guard known.count==rows.count else{throw FormError.invalid("A BOM contribution is represented more than once.")}
    for rule in plan.rules {
      guard let i=indices[rule.rowID] else{throw FormError.invalid("A saved rule refers to a missing BOM row; refresh the plan rather than silently dropping it.")}
      if rule.costBasis != nil,rows[i].role != "component" {throw FormError.invalid("Purchased/made cost basis applies only to a physical component row.")}
      if let quantity=rule.quantity {
        guard rows[i].quantity==nil else{throw FormError.invalid("Computed/archived quantities cannot be overwritten by a declaration. Add an explicit extra line instead.")}
        rows[i].quantity=quantity;rows[i].unit=rule.unit!;rows[i].evidence = .declared;rows[i].formula="Explicit total-row declaration, not multiplied by the run again. "+(rule.notes ?? "")
      } else if let unit=rule.unit,unit != rows[i].unit {throw FormError.invalid("A unit change needs a declared quantity; dimensions are never guessed.")}
      if let stock=rule.stock {guard stock.unit==rows[i].unit else{throw FormError.invalid("Assigned stock and demand units differ. Area is not converted to roll length without an allocation.")};rows[i].stock=stock
        if let supply=stock.supply,rule.unitPrice==nil,rows[i].unitPrice==nil,rows[i].cost==nil {rows[i].unitPrice=supply.unitPrice;rows[i].currency=supply.currency;rows[i].supplier=supply.supplier;rows[i].sku=supply.sku}
      }
      if rule.unitPrice != nil,rows[i].role=="geometry" || rows[i].role=="finishedProduct" {throw FormError.invalid("Reference geometry/finished-product counts are not separately chargeable material. Use an explicit material/process declaration.")}
      if let price=rule.unitPrice {rows[i].unitPrice=price;rows[i].currency=rule.currency;rows[i].cost=nil}
      if let reason=rule.excludedReason {if rows[i].requiredCost {excludedRequired.append(rows[i].name+": required costing stage explicitly excluded ("+reason+"). Complete product cost remains unknown.")};rows[i].excludedReason=reason;rows[i].requiredCost=false}
      if let note=rule.notes {rows[i].notes=note}
    }
    for i in rows.indices {
      let inactiveComponent=rows[i].role=="component" && rows[i].costBasis != .purchased
      let coveredSpecification=rows[i].role=="specification" && !rows[i].requiredCost
      if inactiveComponent || coveredSpecification {
        if rows[i].unitPrice != nil || rows[i].stock != nil || (coveredSpecification && rows[i].quantity != nil) {findings.append(.init("Retained complete-component/raw-material declaration is inactive for its chosen purchased/made basis.",rowID:rows[i].id))}
        rows[i].unitPrice=nil;rows[i].cost=nil;rows[i].currency=nil;rows[i].stock=nil
        if coveredSpecification {rows[i].quantity=nil;rows[i].evidence = .unknown}
      }

      if let stock=rows[i].stock {try stock.validate();guard stock.unit==rows[i].unit else{throw FormError.invalid("Stock comparison requires the same physical unit.")}}
      if let quantity=rows[i].quantity {_ = try CollectionDecimal.resolved(quantity)}
      if let price=rows[i].unitPrice {try CollectionDecimal.currency(rows[i].currency);guard rows[i].currency != nil else{throw FormError.invalid("A cost needs its explicit currency.")};if let quantity=rows[i].quantity {rows[i].cost=try CollectionDecimal.product(quantity,price)}}
      if let cost=rows[i].cost {_ = try CollectionDecimal.resolved(cost);guard rows[i].currency != nil else{throw FormError.invalid("A computed process cost needs currency.")}}
    }
    for row in rows where row.role=="allocation" && row.cost != nil && row.excludedReason==nil {
      if rows.contains(where:{$0.id==row.id+"/area" && $0.cost != nil && $0.excludedReason==nil}) {throw FormError.invalid("The same stock allocation has both linear and area prices. Choose one declared cost basis in the source layout/plan; it cannot be charged twice.")}
    }
    var transferred=Set<String>()
    for rule in plan.rules {
      if let source=rule.costSourceRowID {
        guard source != rule.rowID,transferred.insert(source).inserted,let i=indices[rule.rowID],let j=indices[source],rows[j].role=="unmapped",rows[i].role != "geometry",(rows[i].role != "component" || rows[i].costBasis == .purchased),(rows[i].role != "specification" || rows[i].requiredCost),rows[i].cost==nil,rows[i].quantity==rows[j].quantity,rows[i].unit==rows[j].unit,rows[i].excludedReason==nil else{throw FormError.invalid("A captured base/extra cost needs one matching physical owner, identical quantity/unit and no second price.")}
        rows[i].calculation=rows[j].calculation;rows[i].cost=rows[j].cost;rows[i].unitPrice=rows[j].unitPrice;rows[i].currency=rows[j].currency;rows[i].formula += " Cost source: "+source
        rows[j].excludedReason="Allocated to "+rule.rowID+"; not added again."
      }
    }
    var subtotals:[String:String]=[:],unknowns:[String]=excludedRequired
    for row in rows where row.excludedReason==nil {
      if let cost=row.cost,let currency=row.currency {subtotals[currency]=try CollectionDecimal.sum([subtotals[currency] ?? "0",cost])}
      else if row.requiredCost {unknowns.append(row.name+": quantity/rate/currency is unknown.")}
    }
    let assigned=rows.filter{$0.stock != nil && $0.excludedReason==nil},groups=Dictionary(grouping:assigned,by:{$0.stock!.key})
    var stockChecks:[CollectionStockCheck]=[]
    for key in groups.keys.sorted() {
      let lines=groups[key]!,first=lines[0].stock!,same=try lines.allSatisfy{line in guard let stock=line.stock else{return false};if stock==first {return true};return try JSONEncoder.form.encode(stock)==JSONEncoder.form.encode(first)}
      let demand=try CollectionDecimal.sum(lines.compactMap(\.quantity)),available=try lines.contains(where:{$0.stockAvailabilityUnknown==true}) ? nil:first.available,complete=lines.allSatisfy{$0.quantity != nil}
      let status:String
      if !same || lines.contains(where:{$0.unit != first.unit || $0.stockConflict==true}) {status="conflict";findings.append(.init("Conflicting portable stock snapshots/units for "+first.name+"; combined availability is unknown."))}
      else if let available {
        if try CollectionDecimal.resolved(demand)>CollectionDecimal.resolved(available) {status="insufficient"}
        else {status=complete ? "sufficient":"unknown"}
      } else {status="unknown"}
      stockChecks.append(.init(key:key,name:first.name,unit:first.unit,knownDemand:demand,available:status=="conflict" ? nil:available,status:status,contributors:lines.map(\.id)))
    }
    let currency=subtotals.count==1 ? subtotals.keys.first:nil
    if subtotals.count>1 {unknowns.append("Mixed currencies are separate; no converted collection total.")}
    return .init(occurrences:scope.occurrences,rows:rows,findings:findings,stock:stockChecks,knownSubtotals:subtotals,completeTotal:unknowns.isEmpty ? currency.flatMap{subtotals[$0]}:nil,currency:currency,unknowns:unknowns)
  }
  public static func csv(_ report:CollectionPreflight)->Data {
    let header=["row_id","name","role","quantity","unit","evidence","formula","unit_price","currency","cost","supplier","sku","excluded_reason","notes","calculation_numerator","calculation_denominator","rounding_mode","rounding_scale","rounding_occurred","rounding_policy_version","calculation_inputs_json"]
    let all=[header]+report.rows.map{r in [r.id,r.name,r.role,r.quantity ?? "Unknown",r.unit.rawValue,r.evidence.rawValue,r.formula,r.unitPrice ?? "Unknown",r.currency ?? "Unknown",r.cost ?? "Unknown",r.supplier ?? "",r.sku ?? "",r.excludedReason ?? "",r.notes ?? "",r.calculation?.numerator ?? "",r.calculation?.denominator ?? "",r.calculation?.roundingMode ?? "",r.calculation.map{String($0.scale)} ?? "",r.calculation.map{String($0.rounded)} ?? "",r.calculation.map{String($0.policyVersion)} ?? "",r.calculation.flatMap{try? JSONSerialization.data(withJSONObject:$0.originalInputs,options:.sortedKeys)}.map{String(decoding:$0,as:UTF8.self)} ?? ""]}
    return Data((all.map{$0.map(CollectionDecimal.csv).joined(separator:",")}.joined(separator:"\r\n")+"\r\n").utf8)
  }
}
