import Foundation

/// Authored native feature graphs. These are editable construction starting
/// points, not measured supplier assemblies or manufacturing certifications.
public enum CADModelExamples {
  public static let names=["clockEnclosure","vase","lamp","enclosure"]
  public static func make(_ name:String)throws->CADModelDefinition{switch name{case "clockEnclosure":return clockEnclosure();case "vase":return vase();case "lamp":return lamp();case "enclosure":return enclosure();default:throw CADModelError("Unknown CAD construction example.")}}
  private static func translation(_ x:CADScalar=0,_ y:CADScalar=0,_ z:CADScalar=0)->[CADScalar]{[1,0,0,x,0,1,0,y,0,0,1,z,0,0,0,1]}
  public static func clockEnclosure()->CADModelDefinition {
    var features:[CADFeatureNode]=[]
    func add(_ name:String,_ op:CADFeatureOperation)->UUID{let f=CADFeatureNode(name:name,operation:op);features.append(f);return f.id}
    let outer=add("Analytic case blank",.init(.cylinder,values:["radius":"diameter/2","height":"depth"]))
    let rolled=add("Rolled outer edges",.init(.fillet,inputs:[outer],values:["radius":"edgeRadius"],selection:.allEdges))
    let cavity=add("Rear cavity tool",.init(.cylinder,values:["radius":"diameter/2-wall","height":"depth-wall+1"]))
    let cavityPlaced=add("Rear cavity position",.init(.transform,inputs:[cavity],matrix:translation(0,"wall",0)))
    let hollow=add("Open rear and retained front wall",.init(.subtract,inputs:[rolled,cavityPlaced]))
    let recess=add("Dial recess tool",.init(.cylinder,values:["radius":"diameter/2-bezelWidth","height":"wall/2+1"]))
    let recessPlaced=add("Dial recess position",.init(.transform,inputs:[recess],matrix:translation(0,-1,0)))
    let dial=add("Recessed dial seat",.init(.subtract,inputs:[hollow,recessPlaced]))
    let boss=add("Movement mount boss",.init(.cylinder,values:["radius":"mountBore/2+3.5","height":"wall*2"]))
    let bossPlaced=add("Mount position",.init(.transform,inputs:[boss],matrix:translation("mountSpacing/2","wall","mountSpacing/2")))
    let bosses=add("Four mounting bosses",.init(.circularPattern,inputs:[bossPlaced],values:["count":4,"angleStepDegrees":90]))
    let mounts=add("Connected movement mounts",.init(.union,inputs:[dial,bosses]))
    let bore=add("Mount pilot tool",.init(.cylinder,values:["radius":"mountBore/2","height":"wall*2+1"]))
    let borePlaced=add("Blind pilot position",.init(.transform,inputs:[bore],matrix:translation("mountSpacing/2","wall+1.5","mountSpacing/2")))
    let bores=add("Four blind pilots",.init(.circularPattern,inputs:[borePlaced],values:["count":4,"angleStepDegrees":90]))
    let drilled=add("Mount pilot holes",.init(.subtract,inputs:[mounts,bores]))
    let shaft=add("Dial shaft tool",.init(.cylinder,values:["radius":"shaftDiameter/2","height":"wall+3"]))
    let shaftPlaced=add("Shaft position",.init(.transform,inputs:[shaft],matrix:translation(0,-1,0)))
    let finished=add("Shaft clearance",.init(.subtract,inputs:[drilled,shaftPlaced]))
    let standing=add("Upright clock orientation",.init(.transform,inputs:[finished],matrix:[1,0,0,0,0,0,-1,"diameter/2",0,1,0,0,0,0,0,1]))
    return .init(name:"Seven-inch clock enclosure",parameters:[.init("diameter",177.8,140...240),.init("depth",50.8,35...80),.init("wall",3,2.5...5),.init("bezelWidth",7,5...14),.init("edgeRadius",1.2,0.3...2),.init("shaftDiameter",8.2,5...12),.init("mountSpacing",36,26...52),.init("mountBore",3.2,2...4.5)],features:features,outputs:[standing],assumptions:["Geometry uses document millimeters. Mount locations and bore sizes are authored placeholders."],unresolvedMeasurements:["Verify actual clock movement footprint, depth, shaft length and mounting pattern.","Specify dial retention, lens, rear cover, fasteners and physical fit before production."])
  }
  public static func vase()->CADModelDefinition {
    let sketch=CADFeatureNode(name:"Bezier vessel silhouette",operation:.init(.curveProfile,curves:[
      .init(.cubicBezier,start:.init("baseRadius",0),control1:.init("bulgeRadius","height*0.15"),control2:.init("bulgeRadius","height*0.70"),end:.init("rimRadius","height")),
      .init(.line,start:.init("rimRadius","height"),end:.init(0,"height")),.init(.line,start:.init(0,"height"),end:.init(0,0)),.init(.line,start:.init(0,0),end:.init("baseRadius",0))],plane:.xy))
    let revolved=CADFeatureNode(name:"Exact revolved vessel",operation:.init(.revolve,inputs:[sketch.id]))
    let hollow=CADFeatureNode(name:"Normal wall and open rim",operation:.init(.shell,inputs:[revolved.id],values:["thickness":"wall"],selection:.faceAtMaximum(axis:"y")))
    return .init(name:"Sculptural vessel",parameters:[.init("height",180,90...280),.init("baseRadius",28,22...45),.init("rimRadius",40,28...65),.init("bulgeRadius",65,45...95),.init("wall",3,1.5...5)],features:[sketch,revolved,hollow],outputs:[hollow.id],assumptions:["Wall is an inward exact-kernel offset; it is not a texture or open visual shell."],unresolvedMeasurements:["Validate chosen material, print orientation and process settings for a physical sample."])
  }
  public static func lamp()->CADModelDefinition {
    var features:[CADFeatureNode]=[]
    func add(_ name:String,_ op:CADFeatureOperation)->UUID{let f=CADFeatureNode(name:name,operation:op);features.append(f);return f.id}
    let base=add("Base blank",.init(.cylinder,values:["radius":"baseRadius","height":"baseThickness"]))
    let baseRoll=add("Soft base edge",.init(.fillet,inputs:[base],values:["radius":"edgeRadius"],selection:.allEdges))
    let wire=add("Base wire clearance",.init(.cylinder,values:["radius":"wireRadius","height":"baseThickness+2"]))
    let wirePose=add("Base bore position",.init(.transform,inputs:[wire],matrix:translation(0,-1,0)))
    let baseDone=add("Bored base",.init(.subtract,inputs:[baseRoll,wirePose]))
    let armProfile=add("Analytic support profile",.init(.circleProfile,values:["radius":"armRadius"],plane:.init(origin:.init(0,"baseThickness-1",0),u:.xAxis,v:.init(0,0,-1))))
    let arm=add("Swept support",.init(.sweep,inputs:[armProfile],path:[.init(0,"baseThickness-1",0),.init(0,"height-shadeHeight/2",0)]))
    let armWire=add("Support wire tool",.init(.cylinder,values:["radius":"wireRadius","height":"height-shadeHeight/2-baseThickness+3"]))
    let armWirePose=add("Support bore position",.init(.transform,inputs:[armWire],matrix:translation(0,"baseThickness-2",0)))
    let armDone=add("Hollow support",.init(.subtract,inputs:[arm,armWirePose]))
    let shade=add("Analytic tapered shade",.init(.cone,values:["bottomRadius":"shadeBottomRadius","topRadius":"shadeTopRadius","height":"shadeHeight"]))
    let shadeHollow=add("Open shade with true normal wall",.init(.shell,inputs:[shade],values:["thickness":"wall"],selection:.facesAtExtrema(axis:"y")))
    let shadeDone=add("Shade occurrence placement",.init(.transform,inputs:[shadeHollow],matrix:translation(0,"height-shadeHeight",0)))
    return .init(name:"Featured lamp assembly",parameters:[.init("height",350,240...500),.init("baseRadius",80,60...120),.init("baseThickness",14,10...24),.init("armRadius",6,5...10),.init("wireRadius",2.5,1.5...3.5),.init("shadeBottomRadius",90,70...130),.init("shadeTopRadius",45,30...60),.init("shadeHeight",100,70...160),.init("wall",3,2...5),.init("edgeRadius",1.5,0.5...3)],features:features,outputs:[baseDone,armDone,shadeDone],assumptions:["The base, swept hollow support and offset shade remain separate exact output components."],unresolvedMeasurements:["Specify electrical components, socket, strain relief, shade connection and verified fasteners before physical fabrication."])
  }
  public static func enclosure()->CADModelDefinition {
    let sketch=CADFeatureNode(name:"Dimensioned enclosure profile",operation:.init(.profile,points:[.init(0,0),.init("width",0),.init("width","depth"),.init(0,"depth")]))
    let extruded=CADFeatureNode(name:"Extruded enclosure",operation:.init(.extrude,inputs:[sketch.id],values:["distance":"height"]))
    let shell=CADFeatureNode(name:"Rear opening and normal wall",operation:.init(.shell,inputs:[extruded.id],values:["thickness":"wall"],selection:.faceAtMaximum(axis:"y")))
    let rounded=CADFeatureNode(name:"Soft enclosure edges",operation:.init(.fillet,inputs:[shell.id],values:["radius":"edgeRadius"],selection:.allEdges))
    return .init(name:"Structured enclosure",parameters:[.init("width",120,80...200),.init("depth",80,50...140),.init("height",45,25...90),.init("edgeRadius",0.7,0.3...0.7),.init("wall",2.5,1.5...4)],features:[sketch,extruded,shell,rounded],outputs:[rounded.id],unresolvedMeasurements:["Verify closure, component clearances, mounting features and process tolerances."])
  }
}
