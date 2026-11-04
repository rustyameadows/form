import Foundation
import FormCADModel

public struct ConstructionDrawingShape:Codable,Equatable,Sendable {
  public var pieceID:String,panelID:String,color:String
  public var points:[Point2]
  public var holes:[[Point2]] = []
  public var closed:Bool
  public var lineWidthMM:Double
  public var depth:Double
}
public struct ConstructionResolvedDrawing:Codable,Equatable,Sendable {
  public var view:ConstructionDrawingView
  public var shapes:[ConstructionDrawingShape]
  public var bounds:PaperBounds
  public var assembledDimensionsMM:Vector3
  public var representation:String
}
public enum ConstructionAssemblyDrawings {
  public static func svg(_ drawing:ConstructionResolvedDrawing,labels:Bool=true)->String {
    let callouts=labels && drawing.view.explosionPercent>0 ? calloutLayout(drawing):nil
    let b=callouts?.bounds ?? drawing.bounds,pad=10.0
    var result=ConstructionPacketDrawing.header(width:b.width+pad*2,height:b.height+pad*2,title:drawing.view.title,viewBox:"\(b.x-pad) \(b.y-pad) \(b.width+pad*2) \(b.height+pad*2)")
    result+="<metadata>\(ConstructionPacketDrawing.xml(drawing.representation))</metadata><g data-role=\"assembly-reference\" data-not-tool-path=\"true\">"
    for shape in drawing.shapes {
      let contours=[shape.points]+shape.holes
      result+="<path data-piece-id=\"\(ConstructionPacketDrawing.xml(shape.pieceID))\" data-panel-id=\"\(ConstructionPacketDrawing.xml(shape.panelID))\" fill=\"\(shape.closed ? ConstructionPacketDrawing.xml(shape.color):"none")\" fill-rule=\"evenodd\" stroke=\"\(shape.closed ? "#303636":ConstructionPacketDrawing.xml(shape.color))\" stroke-width=\"\(shape.lineWidthMM)\" d=\"\(contours.map{ConstructionPacketDrawing.path($0,closed:shape.closed)}.joined(separator:" "))\"/>"
    }
    if let callouts {result+=calloutSVG(callouts)}
    if labels {result+="<text x=\"\(b.x)\" y=\"\(b.y-4)\" font-family=\"Helvetica,Arial,sans-serif\" font-size=\"3\">\(ConstructionPacketDrawing.xml(drawing.view.title)) / reference diagram</text>"}
    return result+"</g></svg>"
  }
  public static func defaultViews()->[ConstructionDrawingView] {
    [.init(id:"assembled",title:"Assembled construction"),.init(id:"exploded",title:"Exploded source assembly",explosionPercent:100),
      .init(id:"section-x",title:"Center section / X",projection:.side,sectionAxis:.x,sectionOffsetMM:0),
      .init(id:"section-z",title:"Center section / Z",projection:.front,sectionAxis:.z,sectionOffsetMM:0)]
  }
  public static func resolve(source:PaperConstruction,view:ConstructionDrawingView)throws->ConstructionResolvedDrawing {
    guard let definition=source.authored else{throw FormError.invalid("Assembly drawings need authored part geometry.")}
    var posed=source;posed.foldPercent=100;posed.openingPercent=view.openingPercent;posed.explosionPercent=view.explosionPercent
    let net=try posed.net(),poses=try posed.resolvedPanels(),byPose=Dictionary(uniqueKeysWithValues:poses.map{($0.panelID,$0.flatToWorld)})
    let values=try definition.poseValues(fold:100,opening:view.openingPercent,explosion:view.explosionPercent)
    let sectionOffset=try view.sectionOffsetMM.map{try CADExpression.evaluate($0.expression,variables:values)} ?? 0
    guard sectionOffset.isFinite,abs(sectionOffset)<=100000 else{throw FormError.invalid("Section offset must be finite within the construction coordinate budget.")}
    let wanted=view.componentIDs.map(Set.init)
    var shapes=[ConstructionDrawingShape](),worldBounds=[Vector3]()
    func world(_ matrix:[Double],_ point:Point2,_ z:Double)->Vector3 {
      .init(matrix[0]*point.x-matrix[1]*point.y+matrix[2]*z+matrix[3],matrix[4]*point.x-matrix[5]*point.y+matrix[6]*z+matrix[7],matrix[8]*point.x-matrix[9]*point.y+matrix[10]*z+matrix[11])
    }
    func project(_ p:Vector3)->Point2 {
      if let axis=view.sectionAxis {return axis == .x ? .init(p.z,-p.y):.init(p.x,-p.y)}
      switch view.projection {
      case .top:return .init(p.x,p.z)
      case .front:return .init(p.x,-p.y)
      case .side:return .init(p.z,-p.y)
      case .isometric:return .init(0.866025403784*p.x-0.5*p.z,0.25*p.x+0.433012701892*p.z-0.866025403784*p.y)
      }
    }
    for panel in net.panels {
      let pieceID=panel.componentID ?? panel.id
      if let wanted,!wanted.contains(pieceID){continue}
      guard let matrix=byPose[panel.id] else{continue}
      var stock=try panel.resolvedStock(fallback:source.stock)
      if let thickness=panel.features?.stockThickness {stock=try PlanarConstructionDefinition.resizedStock(stock,thickness:CADExpression.evaluate(thickness.expression,variables:values))}
      let contours=[panel.polygon]+(panel.cutouts ?? []).map(\.polygon),total=stock.resolvedThicknessMM
      var layers=[(low:Double,high:Double,color:String)](),depth = -total/2
      if let plies=stock.plies {
        for ply in plies {layers.append((depth,depth+ply.thicknessMM,ply.color));depth+=ply.thicknessMM}
      }else{layers=[(-total/2,total/2,stock.profile?.color ?? "#D8D1C1")]}
      for layer in layers {
        let lower=contours.map{$0.map{world(matrix,$0,layer.low)}},upper=contours.map{$0.map{world(matrix,$0,layer.high)}}
        worldBounds+=lower.flatMap{$0}+upper.flatMap{$0}
        if let axis=view.sectionAxis {
          let loops=sectionLoops(lower:lower,upper:upper,axis:axis,offset:sectionOffset).map{$0.map(project)}
          var parents=[Int:Int]()
          for i in loops.indices where loops[i].count>=3 {
            let containers=loops.indices.filter{$0 != i && loops[$0].count>=3 && MaterialContourGeometry.area(loops[$0])>MaterialContourGeometry.area(loops[i])+1e-8 && SewingCurves.contains(loops[i][0],ring:loops[$0])}
            if let parent=containers.min(by:{MaterialContourGeometry.area(loops[$0])<MaterialContourGeometry.area(loops[$1])}) {parents[i]=parent}
          }
          func level(_ i:Int)->Int {var value=i,n=0;while let parent=parents[value] {n+=1;value=parent};return n}
          for i in loops.indices where loops[i].count>=2 && level(i)%2==0 {
            let holes=loops.indices.filter{parents[$0]==i}.map{loops[$0]}
            shapes.append(.init(pieceID:pieceID,panelID:panel.id,color:layer.color,points:loops[i],holes:holes,closed:loops[i].count>=3,lineWidthMM:0.12,depth:0))
          }
        }else{
          // All nominal solid faces, sorted back-to-front for diagram occlusion.
          for cap in [lower,upper] {
            guard let face=cap.first else{continue}
            let d=face.reduce(0){$0+($1.x*0.4+$1.z*0.7+$1.y*0.6)}/Double(face.count)
            shapes.append(.init(pieceID:pieceID,panelID:panel.id,color:layer.color,points:face.map(project),holes:cap.dropFirst().map{$0.map(project)},closed:true,lineWidthMM:0.12,depth:d))
          }
          var faces=[[Vector3]]()
          for i in contours.indices {for j in contours[i].indices {let k=(j+1)%contours[i].count;faces.append([lower[i][j],lower[i][k],upper[i][k],upper[i][j]])}}
          for face in faces {
            let d=face.reduce(0){$0+($1.x*0.4+$1.z*0.7+$1.y*0.6)}/Double(face.count)
            shapes.append(.init(pieceID:pieceID,panelID:panel.id,color:layer.color,points:face.map(project),closed:true,lineWidthMM:0.12,depth:d))
          }
        }
      }
    }
    if definition.jointAttachments?.isEmpty == false {
      let attachments=try definition.resolveJointAttachments(stock:source.stock,foldPercent:100,openingPercent:view.openingPercent,explosionPercent:view.explosionPercent,validateEngagement:false)
      let owners=Dictionary(uniqueKeysWithValues:net.panels.map{($0.id,$0.componentID ?? $0.id)})
      for staple in attachments.staples {
        let owner=owners[staple.entryPanelID] ?? staple.entryPanelID
        if let wanted,!wanted.contains(owner){continue}
        let rings=try PlanarWireSection.corners(pointsMM:staple.pointsMM,widthMM:staple.wireWidthMM,depthMM:staple.wireDepthMM)
        worldBounds+=rings.flatMap{$0}
        for index in 0..<rings.count-1 {
          let lower=rings[index],upper=rings[index+1]
          let faces:[[Vector3]]
          if let axis=view.sectionAxis {faces=sectionLoops(lower:[lower],upper:[upper],axis:axis,offset:sectionOffset)}
          else {faces=[lower,upper]+(0..<4).map{side in let next=(side+1)%4;return [lower[side],lower[next],upper[next],upper[side]]}}
          for face in faces where face.count>=3 {
            let d=face.reduce(0){$0+($1.x*0.4+$1.z*0.7+$1.y*0.6)}/Double(face.count)
            shapes.append(.init(pieceID:owner,panelID:staple.id,color:"#747B7F",points:face.map(project),closed:true,lineWidthMM:0.035,depth:d+0.001))
          }
        }
      }
    }
    if view.sectionAxis==nil {shapes.sort{$0.depth<$1.depth}}
    let all=shapes.flatMap(\.points),box=MaterialContourGeometry.bounds(all)
    guard !all.isEmpty,box.width>0,box.height>0 else{throw FormError.invalid("Drawing ‘\(view.title)’ misses all active material; choose another section offset or piece scope.")}
    let x=worldBounds.map(\.x),y=worldBounds.map(\.y),z=worldBounds.map(\.z)
    let size=Vector3((x.max() ?? 0)-(x.min() ?? 0),(y.max() ?? 0)-(y.min() ?? 0),(z.max() ?? 0)-(z.min() ?? 0))
    return .init(view:view,shapes:shapes,bounds:.init(x:box.x,y:box.y,width:box.width,height:box.height),assembledDimensionsMM:size,
      representation:"Nominal centered-stock panels, declared ply calipers and actual rectangular installed wire sections; separate native view verifies curved bends, relief and material response. Diagram is not a machine tool path.")
  }
  private static func sectionLoops(lower:[[Vector3]],upper:[[Vector3]],axis:ConstructionDrawingView.SectionAxis,offset:Double)->[[Vector3]] {
    let epsilon=1e-7
    func distance(_ p:Vector3)->Double {(axis == .x ? p.x:p.z)-offset}
    func length(_ a:Vector3,_ b:Vector3)->Double {sqrt(pow(a.x-b.x,2)+pow(a.y-b.y,2)+pow(a.z-b.z,2))}
    var segments=[(Vector3,Vector3)]()
    func intersections(_ rings:[[Vector3]]) {
      var points=[Vector3]()
      for ring in rings {for i in ring.indices {
        let a=ring[i],b=ring[(i+1)%ring.count],da=distance(a),db=distance(b)
        if abs(da)<epsilon,abs(db)<epsilon {segments.append((a,b));continue}
        if abs(da)<epsilon {points.append(a)}
        if da*db < -epsilon*epsilon {let t=da/(da-db);points.append(.init(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t))}
      }}
      var unique=[Vector3]();for p in points where !unique.contains(where:{length($0,p)<epsilon}) {unique.append(p)}
      guard unique.count>=2 else{return}
      let spreadX=(unique.map(\.x).max() ?? 0)-(unique.map(\.x).min() ?? 0),spreadY=(unique.map(\.y).max() ?? 0)-(unique.map(\.y).min() ?? 0),spreadZ=(unique.map(\.z).max() ?? 0)-(unique.map(\.z).min() ?? 0)
      unique.sort {a,b in spreadX>=spreadY && spreadX>=spreadZ ? a.x<b.x:(spreadY>=spreadZ ? a.y<b.y:a.z<b.z)}
      for i in stride(from:0,to:unique.count-1,by:2) {if length(unique[i],unique[i+1])>epsilon {segments.append((unique[i],unique[i+1]))}}
    }
    intersections(lower);intersections(upper)
    for i in lower.indices {for j in lower[i].indices {let k=(j+1)%lower[i].count;intersections([[lower[i][j],lower[i][k],upper[i][k],upper[i][j]]])}}
    var loops=[[Vector3]]()
    while !segments.isEmpty {
      let first=segments.removeLast();var ring=[first.0,first.1]
      for _ in 0...segments.count {
        guard let last=ring.last else{break}
        if ring.count>2,length(last,ring[0])<epsilon {ring.removeLast();break}
        guard let i=segments.firstIndex(where:{length($0.0,last)<epsilon || length($0.1,last)<epsilon}) else{break}
        let segment=segments.remove(at:i);ring.append(length(segment.0,last)<epsilon ? segment.1:segment.0)
      }
      loops.append(ring)
    }
    return loops
  }
}
