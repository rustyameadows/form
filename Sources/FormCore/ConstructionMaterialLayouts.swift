import CryptoKit
import Foundation

public struct ConstructionPacketIssue:Codable,Equatable,Sendable {
  public enum Severity:String,Codable,Sendable {case warning,error}
  public var severity:Severity
  public var code:String
  public var message:String
  public var pieceIDs:[String]
  public init(_ severity:Severity,_ code:String,_ message:String,pieceIDs:[String]=[]) {self.severity=severity;self.code=code;self.message=message;self.pieceIDs=pieceIDs}
}
public struct ConstructionLayoutPlacement:Codable,Equatable,Sendable {
  public var pieceID:String
  public var copy:Int
  public var sheetIndex:Int
  public var origin:Point2
  public var rotationDegrees:Double
  public var transform:Affine2
  public var bounds:PaperBounds
}
public struct ConstructionMaterialBatch:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var format:ConstructionStockFormat
  public var stock:PaperStock
  public var stockDigest:String
  public var placements:[ConstructionLayoutPlacement]
  public var sheetCount:Int
  public var usedLengthMM:Double
  public var cutAreaMM2:Double
  public var stockAreaMM2:Double
  public var candidateChecks:Int
  public var wasteAreaMM2:Double {max(0,stockAreaMM2-cutAreaMM2)}
  public var wasteFraction:Double {stockAreaMM2>0 ? wasteAreaMM2/stockAreaMM2:0}
  public var declaredAdditionalAllowanceAreaMM2:Double {stockAreaMM2*format.wasteAllowanceFraction}
}
public struct ConstructionLayoutReport:Codable,Equatable,Sendable {
  public var batches:[ConstructionMaterialBatch]
  public var issues:[ConstructionPacketIssue]
  public var isValid:Bool {!issues.contains{$0.severity == .error}}
}
public enum ConstructionMaterialLayouts {
  public static let maximumPlacements=2048
  public static let maximumSheets=64
  public static let maximumCandidates=100_000
  public static func stockDigest(_ stock:PaperStock)throws->String {
    var physical=stock;physical.grain = .unknown;physical.sheetSizeMM=nil
    if physical.plies != nil {for i in physical.plies!.indices {
      physical.plies![i].id=ComponentCommands.derivedID(UUID(uuidString:"587FF113-A86F-40CB-9097-CDF690FFED19")!,UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",i))!)
    }}
    return digest(try JSONEncoder.form.encode(physical))
  }
  public static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static func rotations(_ piece:ResolvedConstructionPiece,_ format:ConstructionStockFormat)->[Double] {
    if format.grain == .unrestricted {return format.allowRotation ? [0,90,-90,180]:[0]}
    if piece.stock.grain == .unknown {return [0]}
    let base=piece.stock.grain == .parallelWidth ? 90.0:0
    if !format.allowRotation {return base==0 ? [0]:[]}
    return format.grain == .directional ? [base]:[base,base==0 ? 180:-90]
  }
  public static func plan(pieces:[ResolvedConstructionPiece],production:ConstructionProductionDefinition)throws->ConstructionLayoutReport {
    guard !pieces.isEmpty,pieces.count<=128,Set(pieces.map(\.id)).count==pieces.count else {throw FormError.invalid("Material layouts need 1–128 distinctly identified physical cut pieces.")}
    var issues=[ConstructionPacketIssue](),grouped=[String:(ConstructionStockFormat,PaperStock,String,[ResolvedConstructionPiece])](),assigned=Set<String>()
    let byID=Dictionary(uniqueKeysWithValues:pieces.map{($0.id,$0)})
    for format in production.materials {
      try format.validate()
      if format.spacingMM+1e-7<production.bleedMM*2 {issues.append(.init(.error,"bleedSpacing","‘\(format.name)’ spacing must accommodate the declared print bleed on both adjacent pieces."))}
      for id in format.componentIDs {
        guard let piece=byID[id] else{continue} // Saved disabled pieces retain their assignments.
        guard assigned.insert(id).inserted else{throw FormError.invalid("Cut piece ‘\(id)’ is assigned to multiple material formats.")}
        let hash=try stockDigest(piece.stock),key=format.id+":"+hash
        if grouped[key]==nil {grouped[key]=(format,piece.stock,hash,[])}
        grouped[key]!.3.append(piece)
      }
    }
    for piece in pieces where !assigned.contains(piece.id) {issues.append(.init(.error,"unassignedStock","Choose a sheet/roll material format for ‘\(piece.name)’.",pieceIDs:[piece.id]))}
    var batches=[ConstructionMaterialBatch](),totalCopies=0
    for key in grouped.keys.sorted() {
      let (format,stock,hash,source)=grouped[key]!
      struct Work {var piece:ResolvedConstructionPiece;var copy:Int}
      struct Placed {var record:ConstructionLayoutPlacement;var contours:[[Point2]];var bounds:Rect2}
      var work=[Work]()
      for piece in source {
        guard (1...1000).contains(piece.quantity),(1...1000).contains(production.quantity) else{throw FormError.invalid("Cut quantities must be 1–1000 before material planning.")}
        let count=piece.quantity*production.quantity;totalCopies+=count
        guard totalCopies<=maximumPlacements else{throw FormError.invalid("This packet exceeds 2048 physical placements; split the production quantity into bounded packets.")}
        for copy in 1...count {work.append(.init(piece:piece,copy:copy))}
        if piece.stock.grain == .unknown,format.grain != .unrestricted {issues.append(.init(.warning,"unknownGrain","‘\(piece.name)’ has unknown grain; its authored direction is retained without claiming grain verification.",pieceIDs:[piece.id]))}
      }
      work.sort {a,b in
        if abs(a.piece.areaMM2-b.piece.areaMM2)>1e-8{return a.piece.areaMM2>b.piece.areaMM2}
        let aa=max(a.piece.bounds.width,a.piece.bounds.height),bb=max(b.piece.bounds.width,b.piece.bounds.height)
        if abs(aa-bb)>1e-8{return aa>bb};return a.piece.id==b.piece.id ? a.copy<b.copy:a.piece.id<b.piece.id
      }
      var sheets=[[Placed]](),checks=0,comparisons=0
      for item in work {
        let angles=rotations(item.piece,format)
        if angles.isEmpty {issues.append(.init(.error,"grainRotation","‘\(item.piece.name)’ needs a grain-respecting rotation that this format forbids.",pieceIDs:[item.piece.id]));continue}
        var best:Placed?,bestScore:[Double]?
        let last=min(sheets.count,format.surface == .roll ? 0:maximumSheets-1)
        for sheetIndex in 0...last {
          let placed=sheets.indices.contains(sheetIndex) ? sheets[sheetIndex]:[]
          let xs=Array(Set([format.marginMM]+placed.map{$0.bounds.maxX+format.spacingMM})).sorted()
          let ys=Array(Set([format.marginMM]+placed.map{$0.bounds.maxY+format.spacingMM})).sorted()
          let used=placed.map{$0.bounds.maxY}.max() ?? format.marginMM
          for angle in angles {
            var candidate:Placed?
            search: for y in ys {for x in xs {
              checks+=1;guard checks<=maximumCandidates else{throw FormError.invalid("Material layout reached its 100000-candidate budget; split the production scope.")}
              let rotation=Affine2.rotation(angle),box=MaterialContourGeometry.bounds(item.piece.cutContours[0].map(rotation.apply))
              let transform=Affine2.translation(x-box.x,y-box.y).followed(by:rotation)
              let contours=item.piece.cutContours.map{$0.map(transform.apply)},bounds=MaterialContourGeometry.bounds(contours[0])
              guard bounds.x>=format.marginMM-1e-7,bounds.y>=format.marginMM-1e-7,bounds.maxX<=format.widthMM-format.marginMM+1e-7,
                bounds.maxY<=format.lengthMM-format.marginMM+1e-7 else{continue}
              var clear=true
              for other in placed {
                let separation=try MaterialContourGeometry.separation(contours,other.contours,required:format.spacingMM,comparisons:&comparisons)
                if separation.overlaps || separation.distance+1e-7<format.spacingMM {clear=false;break}
              }
              if clear {
                let record=ConstructionLayoutPlacement(pieceID:item.piece.id,copy:item.copy,sheetIndex:sheetIndex,origin:.init(x,y),rotationDegrees:angle,
                  transform:transform,bounds:.init(x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height))
                candidate = .init(record:record,contours:contours,bounds:bounds);break search
              }
            }}
            if let candidate {
              let score=[Double(sheetIndex),max(used,candidate.bounds.maxY),candidate.bounds.y,candidate.bounds.x,abs(angle),angle]
              if bestScore==nil || score.lexicographicallyPrecedes(bestScore!) {best=candidate;bestScore=score}
            }
          }
          if best != nil {break}
        }
        if let best {
          while sheets.count<=best.record.sheetIndex {sheets.append([])}
          sheets[best.record.sheetIndex].append(best)
        }else{issues.append(.init(.error,"unplacedCopy","‘\(item.piece.name)’ copy \(item.copy) does not fit the declared stock/margins/grain within the bounded material layout.",pieceIDs:[item.piece.id]))}
      }
      let records=sheets.flatMap{$0.map(\.record)},usedLength=sheets.flatMap{$0}.map{$0.bounds.maxY}.max().map{$0+format.marginMM} ?? 0
      let allocated=format.surface == .sheet ? format.widthMM*format.lengthMM*Double(sheets.count):format.widthMM*usedLength
      let area=records.reduce(0.0){$0+(byID[$1.pieceID]?.areaMM2 ?? 0)}
      batches.append(.init(id:format.id+"-"+String(hash.prefix(12)),format:format,stock:stock,stockDigest:hash,placements:records,sheetCount:sheets.count,
        usedLengthMM:usedLength,cutAreaMM2:area,stockAreaMM2:allocated,candidateChecks:checks))
    }
    if batches.reduce(0,{$0+$1.sheetCount})>256 {issues.append(.init(.error,"sheetBudget","The material plan exceeds256 sheets; split its production scope before preparing bounded proof files."))}
    return .init(batches:batches,issues:issues)
  }
}
