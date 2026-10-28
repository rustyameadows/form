import Foundation

public enum PatternAssemblySamples {
  /// Explicit prototype arrangement and sewing correspondence for the original
  /// curved pouch. No pattern-to-garment inference or calibrated fit is implied.
  public static func project()throws -> Project {
    let (source,definition)=try roundedPouch();var project=source
    _ = try project.addPatternAssembly(definition,name:"Curved pouch / supported assembly")
    project.objects[0].position = .init(430,0,0)
    project.camera.target = .init(2.4,1.25,0);project.camera.distance=15;project.camera.azimuth=0.25;project.camera.elevation=0.35
    project.schemaVersion=project.minimumSchemaVersion
    return project
  }
  public static func roundedPouch()throws -> (Project,PatternAssemblyDefinition) {
    var project=Project(name:"NASA / Curved pouch assembly",subtitle:"Original curved stitch contours, explicit panel poses and real seam constraints."),source=try project.makeObject(recipeID:"artboard",name:"Editable pouch construction",parameters:["width":380,"depth":420])
    source.artwork=try SewingPatternTemplates.roundedPouch().artwork;project.objects=[source]
    let pieces=Set(source.artwork!.elements.filter{$0.sewingPiece != nil}.map(\.id))
    try PatternAssemblySource.prepare(in:&project,objectID:source.id,elements:pieces)
    var art=project.objects[0].artwork!
    let main=art.elements[0],facing=art.elements[1],nodes=main.path!.contours[0].nodes
    // Copy2 is a reflected rigid panel pose so its printed right side faces
    // outward. Its source left/right counterpart edges are paired explicitly.
    for i in art.sewingSeams!.indices {
      if art.sewingSeams![i].first.elementID==main.id,art.sewingSeams![i].second.elementID==main.id {
        let edge=6-art.sewingSeams![i].first.edge
        art.sewingSeams![i].second.edge=edge;art.sewingSeams![i].second.edgeID=nodes[edge].id;art.sewingSeams![i].second.endID=nodes[(edge+1)%nodes.count].id;art.sewingSeams![i].reversed=true
      } else {art.sewingSeams![i].reversed=false}
    }
    let origin=Point2(main.x,main.y)
    var mark=ArtworkElement(kind:"text",x:origin.x+32,y:origin.y+34,width:190,height:50,text:"NASA",color:"#ECE7D5",fontSize:48);mark.productionRole="print"
    var stripe=ArtworkElement(kind:"rectangle",x:origin.x+32,y:origin.y+96,width:160,height:3,color:"#CB633A");stripe.productionRole="print"
    var label=ArtworkElement(kind:"text",x:origin.x+32,y:origin.y+112,width:190,height:28,text:"MATERIALS LAB / 36\nCURVED PANEL PROTOTYPE",color:"#ECE7D5",fontSize:9);label.productionRole="print"
    art.elements += [mark,stripe,label];project.objects[0].artwork=art
    let fabric=project.material("flight-nylon"),width=main.width
    var panels:[PatternPanelPlacement]=[]
    for copy in 1...2 {
      let front=copy==1,z=front ? 30.0:-30.0,x=front ? -width/2:width/2,u=Vector3(front ? 1:-1,0,0)
      panels.append(.init(panel:.init(elementID:main.id,copy:copy),pose:.init(originMm:.init(x,250,z),uAxis:u),material:fabric,densityGSM:180))
      panels.append(.init(panel:.init(elementID:facing.id,copy:copy),pose:.init(originMm:.init(x,250,z),uAxis:u,vAxis:.init(0,0,front ? -1:1)),material:fabric,densityGSM:180))
    }
    // Four explicit opening supports represent a study fixture, not inferred
    // stiffness or air pressure that would keep an unsupported pouch open.
    let pins=(1...2).flatMap {copy in [0.25,0.75].map {fraction in PatternAssemblyPin(panel:.init(elementID:main.id,copy:copy),edgeID:nodes[0].id,endID:nodes[1].id,fraction:fraction)}}
    var definition=PatternAssemblyDefinition(sourceObjectID:source.id,panels:panels,seamIDs:art.sewingSeams!.map(\.id),pins:pins,maximumEdgeMm:22)
    definition.settings.substeps=6;definition.settings.iterations=24;definition.settings.velocityDampingPerSecond=2;definition.settings.maximumSimulationSeconds=4;definition.colliders=[.plane()]
    project.notes=[.init("Original curved panels and facing strips are explicitly arranged in 3D. Right sides, mirrored edge counterparts and seam directions are source declarations, not inferred construction."),.init("No self-collision, zipper hardware, calibrated fit, seam allowances in the physics mesh, or verified fabrication/sew-out are modeled.")]
    try project.validateArtworkLinks();try definition.validateDeclarations();return(project,definition)
  }
}
