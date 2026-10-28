import Foundation

extension Samples {
  public static func clothLab()throws -> Project {
    var p=Project(name:"NASA / Flexible materials",subtitle:"A supported fabric drape and two physically seamed panels.")
    var drape=try p.makeObject(recipeID:"clothPanel",name:"01 / Supported fabric",materialID:"linen",position:.init(-220,0,0))
    drape.color="#BEA16E"
    var artwork=Artwork(background:"#BEA16E",elements:[],bleed:0)
    for i in 1..<16 {artwork.elements.append(.init(kind:"line",x:Double(i)*20,y:0,width:0.1,height:300,color:"#DCC99E"));artwork.elements.append(.init(kind:"line",x:0,y:Double(i)*20,width:320,height:0.1,color:"#DCC99E"))}
    artwork.elements += [.init(kind:"rectangle",x:22,y:0,width:45,height:300,color:"#19374C"),.init(kind:"text",x:92,y:54,width:195,height:64,text:"NASA",color:"#19374C",fontSize:64),.init(kind:"text",x:92,y:128,width:190,height:50,text:"FLEXIBLE MATERIALS\nGRAVITY / STATIC CONTACT",color:"#19374C",fontSize:11)]
    drape.artwork=artwork
    var tote=try p.makeObject(recipeID:"clothTote",name:"02 / Paired seam panels",materialID:"flight-sage",position:.init(220,0,0))
    tote.artwork = .init(background:"#7B846F",elements:[.init(kind:"text",x:23,y:80,width:175,height:50,text:"NASA",color:"#E5DEC6",fontSize:48),.init(kind:"text",x:23,y:150,width:175,height:40,text:"MATERIALS LAB\nTWO-PANEL PROTOTYPE",color:"#E5DEC6",fontSize:10)],bleed:0)
    var tag=try p.makeObject(recipeID:"textileLabel",name:"Material-point label",parameters:["width":52,"depth":24,"corner":1],materialID:"label-ecru")
    tag.artwork = .init(background:"#E5DEC6",elements:[.init(kind:"text",x:4,y:5,width:44,height:15,text:"NASA / 31",color:"#19374C",fontSize:10)],bleed:0)
    tag.clothAttachment = .init(surfaceObjectID:tote.id,anchor:try tote.cloth!.mesh.anchor(at:.init(0.71,0.25),panel:0,normalOffsetMm:2))
    p.objects=[drape,tote,tag]
    p.notes=[.init("Run each cloth study separately. Motion is transient; the initial mesh, pins, seams, contacts and declared settings are saved."),.init("The distance-bending proxy is uncalibrated. This two-panel seam demonstration has no self-collision or predictive garment fitting.")]
    p.history=[.init("Created the flexible-materials study.")]
    p.camera.target = .init(0,1.05,0);p.camera.distance=12;p.camera.azimuth=0.28;p.camera.elevation=0.65
    p.schemaVersion=31;try p.validateArtworkLinks();return p
  }
}
