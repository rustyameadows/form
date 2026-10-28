import Foundation
import FormCADModel

/// Ordinary authored examples and explicit compatibility conversion. Product
/// names select example data here; the authored evaluator has no product switch.
public enum ConstructionExamples {
  public static func legacyDefinition(_ source:PaperConstruction)throws->PlanarConstructionDefinition {
    try PaperConstructionEngine.validate(source)
    guard source.kind != .authored else{throw FormError.invalid("This construction already has authored source.")}
    var builder=Builder(source:source)
    return try builder.definition()
  }
  private struct Builder {
    var source:PaperConstruction
    var derived:[String:CADScalar]=[:]
    var panels:[PlanarPanelDefinition]=[]
    var hinges:[PlanarHingeDefinition]=[]
    var counter=0
    mutating func variable(_ expression:String)->String {
      let name="_v\(counter)";counter+=1;derived[name]=CADScalar(stringLiteral:expression);return name
    }
    func scalar(_ expression:String)->CADScalar{CADScalar(stringLiteral:expression)}
    func point(_ x:String,_ y:String)->CADExpressionPoint2{.init(scalar(x),scalar(y))}
    func rectangle(_ x:String,_ y:String,_ width:String,_ height:String)->[CADExpressionPoint2] {
      [point(x,y),point("\(x)+\(width)",y),point("\(x)+\(width)","\(y)+\(height)"),point(x,"\(y)+\(height)")]
    }
    mutating func add(_ id:String,_ name:String,_ role:PaperPanel.Role,_ polygon:[CADExpressionPoint2],parent:String?=nil,
      start:CADExpressionPoint2?=nil,end:CADExpressionPoint2?=nil,angle:Double=0) {
      panels.append(.init(id:id,name:name,role:role,polygon:polygon))
      if let parent,let start,let end {
        let layer=id=="glue" ? 1:id=="bottom-tuck" || id=="top-tuck" ? 2:role == .dust ? 1:0
        hinges.append(.init(id:"fold.\(parent).\(id)",parentPanelID:parent,childPanelID:id,start:start,end:end,
          angleDegrees:CADScalar(angle),layerOffsetMM:scalar("stock*\(layer)"),
          opensWithTop:id.hasPrefix("top-") || id.hasPrefix("dust-top-")))
      }
    }
    /// Symbolic equivalent of the retained rounded-trapezoid compatibility recipe.
    /// Fixed samples collapse naturally when radius=0, without freezing a shape.
    mutating func flap(x:String,y:String,width:String,length:String,direction:Double,radius:String,inset:String)->[CADExpressionPoint2] {
      let x=variable(x),y=variable(y),w=variable(width),l=variable(length),r=variable(radius),i=variable(inset)
      let slope=variable("hypot(\(i),\(l))"),angle=variable("acos(clamp(-\(i)/\(slope),-1,1))")
      let t=variable("min(\(r)/tan(\(angle)/2),min(\(slope)*0.28,(\(w)-2*\(i))*0.28))")
      let rr=variable("\(t)*tan(\(angle)/2)"),bis=variable("hypot(\(i)/\(slope)-1,\(l)/\(slope))")
      let scale=variable("\(rr)/(\(bis)*sin(\(angle)/2))")
      let sign=direction>0 ? "1":"-1",tipY=variable("\(y)+\(sign)*\(l)"),cy=variable("\(tipY)-\(sign)*\(l)/\(slope)*\(scale)")
      func literal(_ v:Double)->String{String(v)}
      var result:[CADExpressionPoint2]=[]
      // Match the original winding and vertex order, including all corner samples.
      let vertices=direction>0 ? [0,1,2,3]:[3,2,1,0]
      for vertex in vertices {
        if vertex==0{result.append(point(x,y));continue}
        if vertex==1{result.append(point("\(x)+\(w)",y));continue}
        let right=vertex==2
        let tipX=variable(right ? "\(x)+\(w)-\(i)":"\(x)+\(i)")
        let cx=variable(right ? "\(tipX)+(\(i)/\(slope)-1)*\(scale)":"\(tipX)+(1-\(i)/\(slope))*\(scale)")
        let towardBaseX=right ? "\(i)/\(slope)":"-\(i)/\(slope)"
        let towardTipX=right ? "-1":"1"
        let baseAngle="atan2(\(tipY)-\(sign)*\(l)/\(slope)*\(t)-\(cy),\(tipX)+(\(towardBaseX))*\(t)-\(cx))"
        let tipAngle="atan2(\(tipY)-\(cy),\(tipX)+(\(towardTipX))*\(t)-\(cx))"
        let baseFirst=(direction>0 && right) || (direction<0 && !right)
        let start=variable(baseFirst ? baseAngle:tipAngle),end=variable(baseFirst ? tipAngle:baseAngle)
        let sweep=variable("atan2(sin(\(end)-\(start)),cos(\(end)-\(start)))")
        for step in 0...12 {
          let a="\(start)+\(sweep)*\(literal(Double(step)/12))"
          result.append(point("\(cx)+\(rr)*cos(\(a))","\(cy)+\(rr)*sin(\(a))"))
        }
      }
      return result
    }
    mutating func definition()throws->PlanarConstructionDefinition {
      derived=["_w":"width+stock","_h":"height+stock","_d":"depth+stock","_g":"glueTab",
        "_top":"_d+topFlap","_bottom":"_top+_h","_netW":"2*(_w+_d)+_g","_netH":"_top+_h+_d+bottomFlap","_backX":"_w+_d"]
      add("front","Front",.body,rectangle("0","_top","_w","_h"))
      add("side-right","Right side",.side,rectangle("_w","_top","_d","_h"),parent:"front",start:point("_w","_top"),end:point("_w","_bottom"),angle:-90)
      add("back","Back",.body,rectangle("_backX","_top","_w","_h"),parent:"side-right",start:point("_backX","_top"),end:point("_backX","_bottom"),angle:-90)
      add("side-left","Left side",.side,rectangle("2*_w+_d","_top","_d","_h"),parent:"back",start:point("2*_w+_d","_top"),end:point("2*_w+_d","_bottom"),angle:-90)
      add("glue","Side glue seam",.glue,[point("2*(_w+_d)","_top"),point("_netW-2","_top+min(8,_h/8)"),point("_netW-2","_bottom-min(8,_h/8)"),point("2*(_w+_d)","_bottom")],parent:"side-left",start:point("2*(_w+_d)","_top"),end:point("2*(_w+_d)","_bottom"),angle:-90)
      add("top-bridge","Top closure",.tuck,rectangle("_backX","_top-_d","_w","_d"),parent:"back",start:point("_backX","_top"),end:point("_backX+_w","_top"),angle:-90)
      let topFlap=flap(x:"_backX",y:"_top-_d",width:"_w",length:"topFlap",direction:-1,radius:"cornerRadius",inset:"min(_w*0.1,12)")
      add("top-tuck",source.kind == .envelope ? "Envelope closing flap":"Top tuck tab",.tuck,topFlap,parent:"top-bridge",start:point("_backX","_top-_d"),end:point("_backX+_w","_top-_d"),angle:-90)
      add("bottom-bridge","Bottom closure",.bottomClosure,rectangle("_backX","_bottom","_w","_d"),parent:"back",start:point("_backX","_bottom"),end:point("_backX+_w","_bottom"),angle:90)
      let bottomFlap=flap(x:"_backX",y:"_bottom+_d",width:"_w",length:"bottomFlap",direction:1,radius:"cornerRadius",inset:"min(_w*0.1,12)")
      add("bottom-tuck",source.kind == .envelope ? "Bottom glue flap":"Bottom tuck tab",source.kind == .envelope ? .glue:.tuck,bottomFlap,parent:"bottom-bridge",start:point("_backX","_bottom+_d"),end:point("_backX+_w","_bottom+_d"),angle:90)
      if source.kind == .straightTuckCarton {
        derived["_dust"]="min(_w*0.42,_d*1.15)";derived["_inset"]="min(4,_d*0.12)";derived["_clearance"]="min(0.6,_d*0.03)"
        for (id,x) in [("right","_w"),("left","2*_w+_d")] {
          let top=flap(x:"\(x)+_clearance",y:"_top",width:"_d-2*_clearance",length:"_dust",direction:-1,radius:"min(cornerRadius,2)",inset:"_inset")
          add("dust-top-"+id,"Top "+id+" dust flap",.dust,top,parent:"side-"+id,start:point("\(x)+_clearance","_top"),end:point("\(x)+_d-_clearance","_top"),angle:-90)
          let bottom=flap(x:"\(x)+_clearance",y:"_bottom",width:"_d-2*_clearance",length:"_dust",direction:1,radius:"min(cornerRadius,2)",inset:"_inset")
          add("dust-bottom-"+id,"Bottom "+id+" dust flap",.dust,bottom,parent:"side-"+id,start:point("\(x)+_clearance","_bottom"),end:point("\(x)+_d-_clearance","_bottom"),angle:90)
        }
      }
      let p=source
      let parameters:[CADModelParameter]=[.init("width",p.dimensions.width,30...1200),.init("height",p.dimensions.height,40...1600),.init("depth",p.dimensions.depth,1...600),
        .init("stock",p.stock.thicknessMM,0.08...2),.init("clearance",p.clearanceMM,0...20),.init("glueTab",p.glueTabMM,6...60),
        .init("topFlap",p.topFlapMM,8...150),.init("bottomFlap",p.bottomFlapMM,8...150),.init("cornerRadius",p.cornerRadiusMM,0...20)]
      let requirements:[CADModelRequirement]=[
        .init(id:"depth-width",lhs:"depth",relation:.lessThanOrEqual,rhs:"width",message:"Depth cannot exceed width."),
        .init(id:"depth-height",lhs:"depth",relation:.lessThanOrEqual,rhs:"height*0.8",message:"Depth cannot exceed 80% of height."),
        .init(id:"glue-fit",lhs:"glueTab",relation:.lessThan,rhs:"width/2",message:"Glue tab must fit the body width."),
        .init(id:"top-fit",lhs:"topFlap",relation:.lessThan,rhs:"height/2",message:"Top flap must fit the body height."),
        .init(id:"bottom-fit",lhs:"bottomFlap",relation:.lessThan,rhs:"height/2",message:"Bottom flap must fit the body height.")]
      let net=try p.net()
      let result=PlanarConstructionDefinition(name:p.kind == .envelope ? "Constructed envelope":"Straight tuck carton",parameters:parameters,
        size:point("_netW","_netH"),stockThickness:"stock",panels:panels,hinges:hinges,joins:net.joins,rootPanelID:net.rootPanelID,
        requirements:requirements,derived:derived)
      _ = try result.net();return result
    }
  }
}
