import CoreGraphics
import FormCore
import Foundation

extension FigmaSceneBuilder {
  func nativePath(_ path:CGPath,width:Double,height:Double) throws -> ArtworkElement {
    var element=try VectorGeometry.element(from:path,color:"#000000")
    let x=element.x,y=element.y
    for c in element.path!.contours.indices {
      for n in element.path!.contours[c].nodes.indices {
        var node=element.path!.contours[c].nodes[n]
        node.anchor.x+=x;node.anchor.y+=y
        if let p=node.incoming {node.incoming = .init(p.x+x,p.y+y)}
        if let p=node.outgoing {node.outgoing = .init(p.x+x,p.y+y)}
        element.path!.contours[c].nodes[n]=node
      }
    }
    element.x=0;element.y=0;element.width=width;element.height=height
    element.path!.width=width;element.path!.height=height
    return element
  }
  func baseShapes(_ node:FigmaValue,id:String,width:Double,height:Double) throws -> [ArtworkElement] {
    let type=node["type"]?.stringValue ?? "UNKNOWN"
    var element=ArtworkElement(kind:"rectangle",x:0,y:0,width:width,height:height,color:"#000000")
    let supplied=try vectorShapes(node,id:id)
    if !supplied.isEmpty, type != "TEXT" {
      return supplied.map { shape in
        var e=element;e.id=UUID();e.kind="path"
        e.path = .init(width:width,height:height,contours:shape.contours,evenOdd:shape.evenOdd)
        if let style=shape.styleID {geometryStyles[e.id]=style}
        return e
      }
    }
    switch type {
    case "RECTANGLE","ROUNDED_RECTANGLE","FRAME","GROUP","SECTION","SYMBOL","INSTANCE":
      let radius=try number(node["cornerRadius"])*scale
      let corners=try ["rectangleTopLeftCornerRadius","rectangleTopRightCornerRadius","rectangleBottomRightCornerRadius","rectangleBottomLeftCornerRadius"].map {
        try number(node[$0],radius/scale)*scale
      }
      guard corners.allSatisfy({$0>=0}) else {throw FigmaClipboardError.invalid("Negative corner radius.")}
      if corners.allSatisfy({$0==corners[0]}) {element.cornerRadius=corners[0]}
      else {
        let factor=min(1,width/max(1e-12,corners[0]+corners[1]),width/max(1e-12,corners[2]+corners[3]),
          height/max(1e-12,corners[0]+corners[3]),height/max(1e-12,corners[1]+corners[2]))
        let r=corners.map{$0*factor},path=CGMutablePath()
        path.move(to:.init(x:r[0],y:0));path.addLine(to:.init(x:width-r[1],y:0))
        path.addArc(tangent1End:.init(x:width,y:0),tangent2End:.init(x:width,y:height),radius:r[1])
        path.addLine(to:.init(x:width,y:height-r[2]))
        path.addArc(tangent1End:.init(x:width,y:height),tangent2End:.init(x:0,y:height),radius:r[2])
        path.addLine(to:.init(x:r[3],y:height))
        path.addArc(tangent1End:.init(x:0,y:height),tangent2End:.init(x:0,y:0),radius:r[3])
        path.addLine(to:.init(x:0,y:r[0]))
        path.addArc(tangent1End:.zero,tangent2End:.init(x:width,y:0),radius:r[0]);path.closeSubpath()
        element=try nativePath(path,width:width,height:height)
      }
      if try number(node["cornerSmoothing"]) != 0 {issue(id,"corners","Smoothed corners require supplied vector geometry; circular corners are an approximation.")}
    case "ELLIPSE":
      element.kind="ellipse"
      if let arc=node["arcData"] {
        let start=try number(arc["startingAngle"]),end=try number(arc["endingAngle"],2 * .pi),inner=try number(arc["innerRadius"])
        guard (0...1).contains(inner),abs(end-start)<=2 * .pi+0.0001 else {throw FigmaClipboardError.invalid("Invalid ellipse arc.")}
        if inner>0 || abs(abs(end-start)-2 * .pi)>0.0001 {
          let path=CGMutablePath(),clockwise=end<start
          path.addArc(center:.zero,radius:1,startAngle:start,endAngle:end,clockwise:clockwise)
          if inner>0 {
            path.addLine(to:.init(x:cos(end)*inner,y:sin(end)*inner))
            path.addArc(center:.zero,radius:inner,startAngle:end,endAngle:start,clockwise:!clockwise)
          } else {path.addLine(to:.zero)}
          path.closeSubpath()
          var transform=CGAffineTransform(a:width/2,b:0,c:0,d:height/2,tx:width/2,ty:height/2)
          element=try nativePath(path.copy(using:&transform)!,width:width,height:height)
        }
      }
    case "REGULAR_POLYGON","POLYGON","STAR":
      element.kind=type=="STAR" ? "star":"polygon"
      let count=node["count"]?.integerValue ?? 5
      guard (3...100).contains(count) else {throw FigmaClipboardError.invalid("Invalid polygon point count.")}
      element.sides=count;element.starInset=try number(node["starInnerScale"],0.5)
    case "LINE":
      element.kind="path"
      let rawHeight=try number(node["size"]?["y"])*scale
      element.path = .init(width:width,height:height,contours:[.init([.init(.init(0,0)),.init(.init(width,rawHeight))],closed:false)])
    case "TEXT":
      element.kind="text"
      var fields=node.objectValue ?? [:];if fields["colorProfile"]==nil {fields["colorProfile"] = .string(currentColorProfile)}
      let textIssues=try FigmaTypography.apply(node:.object(fields),to:&element,scale:scale,
        paints:{try self.textPaintStack($0,width:width,height:height,id:id)})
      for value in textIssues {issue(value.nodeID,value.feature,value.message,severity:value.severity)}
    case "VECTOR":
      issue(id,"vector","No supported path commands or vector network were supplied.",severity:"error")
      element.fillEnabled=false
    default:
      issue(id,"node","Node type \(type) has no editable native mapping.",severity:"error");element.fillEnabled=false
    }
    return [element]
  }
  func visuals(_ node:FigmaValue,id:String,width:Double,height:Double) throws -> [ArtworkElement] {
    let bases=try baseShapes(node,id:id,width:width,height:height)
    let fills=(node["fillPaints"]?.arrayValue ?? []).filter{$0["visible"]?.boolValue != false}
    let strokes=(node["strokePaints"]?.arrayValue ?? []).filter{$0["visible"]?.boolValue != false}
    let styles=node["vectorData"]?["styleOverrideTable"]?.arrayValue ?? []
    var output:[ArtworkElement]=[]
    for base in bases {
      var selectedFills=fills
      if let style=geometryStyles[base.id],let override=styles.first(where:{$0["styleID"]?.integerValue==style}),
        let paints=override["fillPaints"]?.arrayValue {selectedFills=paints.filter{$0["visible"]?.boolValue != false}}
      if base.kind=="text" {
        var text=base
        // The ink stack owns paint alpha, including per-range fills. Applying
        // legacy fillOpacity here would multiply it a second time.
        text.fillOpacity=nil
        if let fill=selectedFills.first,fill["type"]?.stringValue == "SOLID" || fill["type"] == nil {
          text.color=try color(fill["color"]).0
        }
        output.append(text);continue
      }
      var painted:[ArtworkElement]=[]
      // NodeChange paints are stored in drawing order, bottom to top.
      for fill in selectedFills {painted += try paint(fill,on:base,id:id)}
      let outlines=try stroke(strokes,node:node,geometry:base,id:id)
      if painted.count==1,outlines.count==1,painted[0].kind != "image",painted[0].clipID==nil,
        painted[0].paintStack==nil,outlines[0].stroke != nil,painted[0].blendMode==outlines[0].blendMode {
        painted[0].stroke=outlines[0].stroke
      } else {painted += outlines}
      if painted.isEmpty {var invisible=base;invisible.fillEnabled=false;painted=[invisible]}
      output += painted
    }
    return output
  }
}
