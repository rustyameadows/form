import Foundation

extension Samples {
  /// Authored artwork and concept dimensions; no supplier geometry or verified stitch file is implied.
  public static func flightJacket()->Project {
    var p=Project(name:"ORBITAL / Flight systems",subtitle:"A NASA-inspired flight bomber, independent mission patches, and sewn labels.")
    var jacket=try! p.makeObject(recipeID:"bomberJacket",name:"01 / ORBITAL flight bomber",materialID:"flight-nylon",position:.init(-520,0,0))
    jacket.textile?.notes="Generic M-size concept blank. Dimensions and fabric declarations are estimates; verify a physical blank before production. Patches are editable artwork studies, not digitized stitch programs."
    let badgeArt=missionBadge(),labelArt=flightLabel(),nameArt=nameTape()
    func source(_ name:String,_ width:Double,_ height:Double,_ art:Artwork,_ position:Vector3)->ProductObject {
      var o=try! p.makeObject(recipeID:"artboard",name:name,parameters:["width":width,"depth":height],position:position);o.artwork=art;return o
    }
    let badge=source("Artwork / ORBITAL mission",90,90,badgeArt,.init(560,0,-250))
    let label=source("Artwork / sewn flight label",90,32,labelArt,.init(560,0,-80))
    let tape=source("Artwork / NASA flight research",118,34,nameArt,.init(560,0,40))
    var patch=try! p.makeObject(recipeID:"textilePatch",name:"Mission patch / left chest",parameters:["width":90,"depth":90,"corner":45],materialID:"patch-twill")
    patch.artworkSourceID=badge.id;patch.artworkFit="actual";patch.textile?.threadColors=["#D7CAB0","#CD593D","#E9E2D2"]
    patch.textile?.attachment = .init(garmentID:jacket.id,zone:.leftChest)
    var independent=patch;independent.id=UUID();independent.designID=UUID();independent.name="Mission patch / standalone";independent.position = .init(370,0,-250);independent.textile?.attachment=nil
    var tag=try! p.makeObject(recipeID:"textileLabel",name:"Sewn-in label / collar",materialID:"label-ecru")
    tag.artworkSourceID=label.id;tag.artworkFit="actual";tag.textile?.attachment = .init(garmentID:jacket.id,zone:.collar,clearance:2)
    var looseTag=tag;looseTag.id=UUID();looseTag.designID=UUID();looseTag.name="Woven label / standalone";looseTag.position = .init(370,0,-80);looseTag.textile?.attachment=nil
    var name=try! p.makeObject(recipeID:"textilePatch",name:"NASA / flight-research tape",parameters:["width":118,"depth":34,"height":1.7,"corner":5,"borderWidth":1.5],materialID:"patch-twill")
    name.artworkSourceID=tape.id;name.artworkFit="actual";name.textile?.process = .wovenPatch;name.textile?.threadColors=["#E7DDC7"]
    name.textile?.attachment = .init(garmentID:jacket.id,zone:.rightChest,offset:.init(0,-8))
    var arm=patch;arm.id=UUID();arm.designID=UUID();arm.name="Mission patch / left sleeve";arm.parameters["width"]=74;arm.parameters["depth"]=74;arm.parameters["corner"]=37;arm.artworkFit="fit";arm.textile?.attachment = .init(garmentID:jacket.id,zone:.leftSleeve,rotation:-26)
    var sage=jacket;sage.id=UUID();sage.name="02 / Sage colorway";sage.materialID="flight-sage";sage.position = .init(1200,0,650);sage.relationship="variant"
    p.objects=[jacket,patch,tag,name,arm,independent,looseTag,badge,label,tape,sage]
    // A colorway shares geometry and artwork definitions; decoration placements remain independent objects.
    for original in [patch,tag,name,arm] {
      var copy=original;copy.id=UUID();copy.name=original.name+" / sage";copy.textile?.attachment?.garmentID=sage.id;p.objects.append(copy)
    }
    p.notes=[.init("NASA-inspired original artwork; no endorsement or flight-certified product is implied."),
      .init("The blank and fabric specifications are generic concept assumptions, not manufacturer measurements."),
      .init("The jacket is a shaped presentation blank. Cutting patterns, physical fit/drape, stitch digitization, machine files, and hardware operation are not implemented in this milestone.",kind:"question"),
      .init("Edit the independent mission artwork or sewn label to update every linked physical placement.")]
    p.camera.distance=42;p.camera.elevation=1.0;p.camera.azimuth=0.12;p.camera.target = .init(3,0.2,1.4)
    p.history=[.init("Created the ORBITAL flight-bomber textile study.")]
    p.schemaVersion=17
    return p
  }
  private static func type(_ text:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double,_ size:Double,_ color:String="#E9E2D2",alignment:String="center")->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:x,y:y,width:width,height:height,text:text,color:color,fontSize:size)
    var t=Typography();t.fontName="Menlo-Bold";t.alignment=alignment;t.kerningMode="metrics";e.typography=t;return e
  }
  private static func missionBadge()->Artwork {
    var art=Artwork(background:"#142B44",elements:[],bleed:0)
    art.boundary = VectorPath(width:90,height:90,contours:[VectorContour((0..<64).map { i in let a=Double(i)/64*2 * Double.pi;return BezierNode(.init(45+44*cos(a),45+44*sin(a))) },closed:true)])
    var ring=ArtworkElement(kind:"ellipse",x:5,y:5,width:80,height:80,color:"#142B44");ring.fillEnabled=false;ring.stroke = .init(color:"#DACDB3",width:0.7)
    var orbit=ArtworkElement(kind:"ellipse",x:12,y:31,width:66,height:23,color:"#142B44");orbit.fillEnabled=false;orbit.stroke = .init(color:"#E4DCC8",width:0.65);orbit.rotation = -29
    var slash=ArtworkElement(kind:"line",x:13,y:57,width:65,height:0.1,color:"#CD593D");slash.stroke = .init(color:"#CD593D",width:2.2);slash.rotation = -25
    art.elements=[ring,orbit,slash,type("NASA",11,22,68,28,57),type("ORBITAL LAB",9,58,72,8,8),type("FLIGHT SYSTEMS / 01",10,69,70,7,5.5)]
    for (x,y,r) in [(20.0,21.0,1.2),(68,24,1.0),(60,18,0.8),(25,61,0.8),(74,53,0.9),(17,46,0.7)] {
      art.elements.append(.init(kind:"ellipse",x:x-r,y:y-r,width:r*2,height:r*2,color:"#E9E2D2"))
    }
    return art
  }
  private static func flightLabel()->Artwork {
    Artwork(background:"#E5DEC8",elements:[type("FORM / FLIGHT SYSTEMS",6,5,78,7,8,"#26323C"),type("ORBITAL PROGRAM  ·  M",6,14,78,5,5.5,"#26323C"),type("CONCEPT SAMPLE / 001",6,22,78,4,4.7,"#6D7067")],bleed:0)
  }
  private static func nameTape()->Artwork {
    Artwork(background:"#142B44",elements:[type("NASA",5,5,108,14,22),type("FLIGHT RESEARCH",5,22,108,6,6.5)],bleed:0)
  }
}
