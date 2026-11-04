import Foundation

/// Annotation placement only. Cut contours and stock placement never change.
public struct ConstructionMaterialLayoutLabel:Equatable,Sendable {
  public let origin:Point2
  public let rotationDegrees:Double
  public let size:Point2
  public let fontSize:Double
}

public enum ConstructionPacketDrawing {
  public static func xml(_ value:String)->String {value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
  public static func path(_ points:[Point2],closed:Bool=true)->String {
    guard let first=points.first else{return ""}
    return "M \(first.x),\(first.y) "+points.dropFirst().map{"L \($0.x),\($0.y)"}.joined(separator:" ")+(closed ? " Z":"")
  }
  public static func header(width:Double,height:Double,title:String,viewBox:String?=nil)->String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(width)mm\" height=\"\(height)mm\" viewBox=\"\(viewBox ?? "0 0 \(width) \(height)")\"><title>\(xml(title))</title>"
  }
  private static func annotation(_ label:String,x:Double,y:Double,fontSize:Double=3)->String {
    "<text x=\"\(x)\" y=\"\(y)\" font-family=\"Helvetica,Arial,sans-serif\" font-size=\"\(fontSize)\" fill=\"#303636\">\(xml(label))</text>"
  }
  /// Thin material strips need their identity along the long axis, rather
  /// than silently losing their label because a horizontal box cannot fit.
  public static func materialLayoutLabel(in bounds:PaperBounds)->ConstructionMaterialLayoutLabel {
    let rotated=(bounds.width<20 || bounds.height<12) && bounds.height>bounds.width
    let width=rotated ? bounds.height:bounds.width,height=rotated ? bounds.width:bounds.height
    let inset=min(2,max(0.25,height*0.15)),font=2.6
    return .init(origin:.init(bounds.x+inset,rotated ? bounds.y+bounds.height-inset:bounds.y+inset),
      rotationDegrees:rotated ? -90:0,size:.init(max(0.1,width-inset*2),max(font*1.6,height-inset*2)),fontSize:font)
  }
  public static func pieceSVG(_ piece:ResolvedConstructionPiece,labels:Bool=true,registrationMarks:Bool=false)->String {
    let margin=registrationMarks ? 5.0:0,w=piece.bounds.width,h=piece.bounds.height
    var output=header(width:w+margin*2,height:h+margin*2,title:piece.name+" / nominal cut pattern",viewBox:"\(-margin) \(-margin) \(w+margin*2) \(h+margin*2)")
    output+="<metadata>\(xml("pieceID=\(piece.id); root=\(piece.rootPanelID); quantity=\(piece.quantity); material=\(piece.stock.name); caliperMM=\(piece.stock.resolvedThicknessMM); nominal=true; toolCompensationApplied=false"))</metadata>"
    output+="<g id=\"cut\" data-piece-id=\"\(xml(piece.id))\" fill=\"none\" stroke=\"#222222\" stroke-width=\"0.18\"><path fill-rule=\"evenodd\" d=\"\(piece.cutContours.map{path($0)}.joined(separator:" "))\"/></g>"
    for guide in piece.guides {
      let color=guide.role.isToolPath ? "#AD4E39":"#507C9A",dash=guide.role.isToolPath ? "":" stroke-dasharray=\"2 1\""
      output+="<g data-role=\"\(guide.role.rawValue)\" data-guide-id=\"\(xml(guide.id))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"0.15\"\(dash)><path d=\"\(path(guide.points,closed:guide.closed))\"/></g>"
    }
    if labels,w>=20,h>=12 {output+=annotation(piece.id+" / "+piece.name,x:2,y:4);output+=annotation("\(w) × \(h) mm / \(piece.stock.resolvedThicknessMM) mm / Qty \(piece.quantity)",x:2,y:8)}
    if registrationMarks {
      output+="<g id=\"registration-guides\" data-role=\"registration\" fill=\"none\" stroke=\"#777777\" stroke-width=\"0.15\">"
      for p in [Point2(-2,-2),.init(w+2,-2),.init(w+2,h+2),.init(-2,h+2)] {output+="<path d=\"M \(p.x-1),\(p.y) L \(p.x+1),\(p.y) M \(p.x),\(p.y-1) L \(p.x),\(p.y+1)\"/>"}
      output+="</g>"
    }
    return output+"</svg>"
  }
  public static func layoutSVG(_ batch:ConstructionMaterialBatch,sheetIndex:Int,pieces:[ResolvedConstructionPiece],labels:Bool=true)->String {
    let width=batch.format.widthMM,height=batch.format.surface == .roll ? batch.usedLengthMM:batch.format.lengthMM
    var output=header(width:width,height:height,title:batch.stock.name+" / material layout / sheet \(sheetIndex+1)")
    output+="<metadata>\(xml("formatID=\(batch.format.id); stockDigest=\(batch.stockDigest); nominal=true; toolCompensationApplied=false; layoutDoesNotMoveCanonicalArtwork=true"))</metadata>"
    output+="<g id=\"stock-guide\" data-role=\"guide\" fill=\"none\" stroke=\"#999999\" stroke-width=\"0.15\"><rect x=\"0\" y=\"0\" width=\"\(width)\" height=\"\(height)\"/></g>"
    let byID=Dictionary(uniqueKeysWithValues:pieces.map{($0.id,$0)})
    for placement in batch.placements where placement.sheetIndex==sheetIndex {
      guard let piece=byID[placement.pieceID] else{continue}
      let contours=piece.cutContours.map{$0.map(placement.transform.apply)}
      output+="<g data-piece-id=\"\(xml(piece.id))\" data-copy=\"\(placement.copy)\" data-rotation=\"\(placement.rotationDegrees)\" fill=\"none\" stroke=\"#222222\" stroke-width=\"0.18\"><path d=\"\(contours.map{path($0)}.joined(separator:" "))\"/></g>"
      if labels {
        let label=materialLayoutLabel(in:placement.bounds)
        output+="<g data-role=\"placement-label\" data-piece-id=\"\(xml(piece.id))\" data-copy=\"\(placement.copy)\" transform=\"translate(\(label.origin.x) \(label.origin.y)) rotate(\(label.rotationDegrees))\">"
        output+=annotation("\(piece.id) / copy \(placement.copy)",x:0,y:label.fontSize,fontSize:label.fontSize)+"</g>"
      }
    }
    return output+"</svg>"
  }
  public static func logicalPartsSVG(_ pieces:[ResolvedConstructionPiece],labels:Bool=true)->String {
    let gap=12.0,rowLimit=max(700,pieces.map(\.bounds.width).max() ?? 700)
    var x=gap,y=gap,rowHeight=0.0,width=0.0,groups=[String]()
    for piece in pieces {
      if x>gap,x+piece.bounds.width>rowLimit {x=gap;y+=rowHeight+gap;rowHeight=0}
      var fragment="<g data-piece-id=\"\(xml(piece.id))\" transform=\"translate(\(x) \(y))\">"
      fragment+="<g data-role=\"cut\" fill=\"none\" stroke=\"#222222\" stroke-width=\"0.18\"><path d=\"\(piece.cutContours.map{path($0)}.joined(separator:" "))\"/></g>"
      for guide in piece.guides {fragment+="<path data-role=\"\(guide.role.rawValue)\" fill=\"none\" stroke=\"#507C9A\" stroke-width=\"0.15\" stroke-dasharray=\"2 1\" d=\"\(path(guide.points,closed:guide.closed))\"/>"}
      if labels {fragment+=annotation(piece.id+" / "+piece.name+" / Qty \(piece.quantity)",x:0,y:-3)}
      groups.append(fragment+"</g>");width=max(width,x+piece.bounds.width+gap);rowHeight=max(rowHeight,piece.bounds.height);x+=piece.bounds.width+gap
    }
    return header(width:width,height:y+rowHeight+gap,title:"Independent nominal cut pieces / logical layout, not stock nesting")+"<metadata>nominal geometry; one outline per part identity; cut quantities are recorded separately; no sparse assembly-net rectangle</metadata>"+groups.joined()+"</svg>"
  }
}
