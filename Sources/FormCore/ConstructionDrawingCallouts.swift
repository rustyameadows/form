import Foundation

public struct ConstructionDrawingCallout:Sendable {
  public var number:Int,pieceID:String,anchor:Point2,position:Point2
}
public struct ConstructionDrawingLegend:Sendable {
  public var number:Int,pieceID:String,position:Point2,lines:[String]
}
public struct ConstructionDrawingCalloutLayout:Sendable {
  public var bounds:PaperBounds,fontSize:Double,radius:Double
  public var callouts:[ConstructionDrawingCallout],legend:[ConstructionDrawingLegend]
}
extension ConstructionAssemblyDrawings {
  /// Numbered gutters have disjoint vertical slots. Source IDs live in a
  /// separate wrapped legend, so stacked or coincident pieces cannot collide.
  /// A PDF may request a subset while keeping stable numbers across its pages.
  public static func calloutLayout(_ drawing:ConstructionResolvedDrawing,pieceIDs:Set<String>?=nil)->ConstructionDrawingCalloutLayout {
    let groups=Dictionary(grouping:drawing.shapes,by:\.pieceID),all=groups.keys.sorted(),b=drawing.bounds
    let font=max(2.5,b.width/60),radius=font*0.82,gutter=font*3
    let selected=all.enumerated().compactMap {index,id->ConstructionDrawingCallout? in
      guard pieceIDs?.contains(id) ?? true else{return nil}
      let box=MaterialContourGeometry.bounds(groups[id]!.flatMap(\.points))
      return .init(number:index+1,pieceID:id,anchor:.init(box.x+box.width/2,box.y+box.height/2),position:.init())
    }.sorted{$0.anchor.x == $1.anchor.x ? $0.pieceID<$1.pieceID:$0.anchor.x<$1.anchor.x}
    let split=(selected.count+1)/2,left=Array(selected.prefix(split)),right=Array(selected.dropFirst(split))
    let span=max(b.height,Double(max(left.count,right.count)-1)*font*2.5),top=b.y+b.height/2-span/2
    var callouts=[ConstructionDrawingCallout]()
    for (column,items) in [left,right].enumerated() {
      let ordered=items.sorted{$0.anchor.y == $1.anchor.y ? $0.pieceID<$1.pieceID:$0.anchor.y<$1.anchor.y}
      for (row,original) in ordered.enumerated() {
        var item=original
        item.position = .init(column==0 ? b.x-gutter:b.x+b.width+gutter,ordered.count<=1 ? b.y+b.height/2:top+Double(row)*span/Double(ordered.count-1))
        callouts.append(item)
      }
    }
    let x=b.x-gutter-radius*1.5,width=b.width+2*gutter+radius*3,columnWidth=width/2
    let legendTop=max(b.y+b.height,top+span+radius)+font*3,columns=2
    let limit=max(8,Int((columnWidth-font*4)/(font*0.62)))
    var legend=[ConstructionDrawingLegend](),ys=[Double](repeating:legendTop,count:columns)
    for (index,item) in callouts.sorted(by:{$0.number<$1.number}).enumerated() {
      let column=index%columns,characters=Array(item.pieceID),lines=stride(from:0,to:characters.count,by:limit).map{String(characters[$0..<min(characters.count,$0+limit)])}
      legend.append(.init(number:item.number,pieceID:item.pieceID,position:.init(x+Double(column)*columnWidth,ys[column]),lines:lines))
      ys[column]+=Double(max(1,lines.count))*font*1.45+font*0.65
    }
    let minY=min(b.y,top-radius),maxY=max(b.y+b.height,ys.max() ?? legendTop)
    return .init(bounds:.init(x:x,y:minY,width:width,height:maxY-minY),fontSize:font,radius:radius,callouts:callouts,legend:legend)
  }
  static func calloutSVG(_ layout:ConstructionDrawingCalloutLayout)->String {
    func n(_ value:Double)->String {String(value)}
    var result="<g data-role=\"part-callouts\" data-not-tool-path=\"true\" font-family=\"Helvetica,Arial,sans-serif\">"
    for c in layout.callouts {
      result+="<path fill=\"none\" stroke=\"#586267\" stroke-width=\"\(n(layout.fontSize*0.07))\" d=\"M \(n(c.anchor.x)),\(n(c.anchor.y)) L \(n(c.position.x)),\(n(c.position.y))\"/>"
      result+="<circle cx=\"\(n(c.position.x))\" cy=\"\(n(c.position.y))\" r=\"\(n(layout.radius))\" fill=\"white\" stroke=\"#303636\" stroke-width=\"\(n(layout.fontSize*0.07))\"/><text x=\"\(n(c.position.x))\" y=\"\(n(c.position.y+layout.fontSize*0.34))\" text-anchor=\"middle\" font-size=\"\(n(layout.fontSize))\">\(c.number)</text>"
    }
    result+="</g><g data-role=\"part-legend\" font-family=\"Menlo,monospace\" font-size=\"\(n(layout.fontSize))\" fill=\"#303636\">"
    for item in layout.legend {
      for (line,value) in item.lines.enumerated() {
        let title=(line==0 ? "\(item.number)  ":"   ")+value
        result+="<text x=\"\(n(item.position.x))\" y=\"\(n(item.position.y+layout.fontSize*(1+Double(line)*1.45)))\">\(ConstructionPacketDrawing.xml(title))</text>"
      }
    }
    return result+"</g>"
  }
}
