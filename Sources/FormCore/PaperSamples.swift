import Foundation

public enum PaperSamples {
  private static func text(_ text:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double,_ size:Double,_ color:String)->ArtworkElement{.init(kind:"text",x:x,y:y,width:width,height:height,text:text,color:color,fontSize:size)}
  public static func sunStudies()throws->Project {
    var project=Project(name:"Sun studies",subtitle:"Twenty sensitized sheets, an original folded envelope, and a little light.")
    var envelope=try project.makeObject(recipeID:"paperEnvelope",name:"Sun studies · constructed envelope",materialID:"paper-superfine",position:.init(-130,0,0))
    let source=try PaperConstruction.definition(for:envelope),net=try source.net(),front=net.panels.first{$0.id=="front"}!.bounds,back=net.panels.first{$0.id=="back"}!.bounds,blue="#254F91"
    var art=Artwork(background:"#F7F5EF",elements:[
      text("EXPERIMENTS IN LIGHT  /  NO. 01",front.x+20,front.y+22,front.width-40,12,9,blue),
      text("Sun\nstudies.",front.x+18,front.y+49,front.width-36,76,64,blue),
      text("A little light. Endless possibility.",front.x+20,front.y+133,front.width-40,20,12,blue),
      .init(kind:"ellipse",x:front.x+99,y:front.y+163,width:69,height:69,color:"#D7E4EE"),
      text("CYANOTYPE KIT  /  20 SHEETS",front.x+20,front.y+246,front.width-40,12,9,blue),
      text("Chasing\nthe sun.",back.x+20,back.y+25,back.width-40,42,28,blue),
      text("01  ARRANGE",back.x+20,back.y+91,back.width-40,12,9,blue),
      text("Work away from direct sunlight.\nPlace leaves or found forms on a sheet.",back.x+20,back.y+108,back.width-40,30,10,blue),
      text("02  EXPOSE",back.x+20,back.y+149,back.width-40,12,9,blue),
      text("Let daylight draw the silhouette.\nWatch the surface change with the light.",back.x+20,back.y+166,back.width-40,30,10,blue),
      text("03  RINSE & DRY",back.x+20,back.y+207,back.width-40,12,9,blue),
      text("Rinse in water, then let the print dry.\nKeep unexposed sheets in this envelope.",back.x+20,back.y+224,back.width-40,30,10,blue),
    ])
    var leaf=ArtworkElement(kind:"path",x:front.x+121,y:front.y+156,width:39,height:82,color:blue)
    leaf.path = .init(width:60,height:100,contours:[.init([.init(.init(30,0),incoming:.init(-9,25),outgoing:.init(73,27)),.init(.init(30,100),incoming:.init(72,72),outgoing:.init(-10,73))])]);leaf.rotation = -19;leaf.name="Original cyanotype leaf silhouette";art.elements.append(leaf)
    var stem=ArtworkElement(kind:"rectangle",x:front.x+137,y:front.y+201,width:1.1,height:40,color:blue);stem.rotation = -19;art.elements.append(stem)
    let top=net.panels.first{$0.id=="top-tuck"}!.bounds
    art.elements.append(text("A LITTLE LIGHT GOES A LONG WAY",top.x+20,top.y+12,top.width-40,10,8,blue));art.backgroundOpacity=0;envelope.artwork=art;envelope.rotation = -8
    var paper=try project.makeObject(recipeID:"paperStack",name:"Sensitized paper · 20 × 8 × 10 in",parameters:["width":203.2,"depth":254,"sheets":20,"thickness":0.28],materialID:"paper-superfine",position:.init(145,0,-25));paper.rotation=4
    var booklet=try project.makeObject(recipeID:"booklet",name:"Field notes & instructions",materialID:"kraft",position:.init(120,8,150));booklet.rotation=12
    booklet.artwork = .init(background:"#F7F5EF",elements:[text("Chasing\nthe sun.",12,20,85,40,23,blue),text("A FIELD GUIDE",12,124,85,12,8,blue)])
    project.objects=[envelope,paper,booklet]
    project.notes=[.init("The kit contains twenty 8 × 10 inch sheets. The envelope is an original finite-depth paper construction with one side seam, a bonded bottom and a top closing flap."),.init("Stock caliper, grain, adhesive and crease tooling are prototype assumptions. Prove fit and closure on the actual material.",kind:"question")]
    project.history=[.init("Created the registered Sun studies envelope and its paper kit.")];project.camera.distance=9;project.camera.elevation=0.81;project.schemaVersion=53;return project
  }
  public static func cosmetics()throws->Project {
    var project=Project(name:"STILL / Daily ritual",subtitle:"An original straight tuck carton, registered artwork and a quiet daily object.")
    var carton=try project.makeObject(recipeID:"tuckCarton",name:"STILL · botanical serum carton",materialID:"paper-superfine",position:.init(-90,0,0))
    var definition=try PaperConstruction.definition(for:carton);let net=try definition.net(),front=net.panels.first{$0.id=="front"}!.bounds,back=net.panels.first{$0.id=="back"}!.bounds,ink="#303B32",accent="#9CAFA1"
    carton.artwork = .init(background:"#F7F5EF",elements:[text("STILL",front.x+9,front.y+18,front.width-18,19,34,ink),text("DAILY RITUAL",front.x+9,front.y+43,front.width-18,10,8,ink),.init(kind:"rectangle",x:front.x+9,y:front.y+63,width:front.width-18,height:1.1,color:accent),text("Botanical\nserum",front.x+9,front.y+76,front.width-18,27,16,ink),text("30 mL",front.x+9,front.y+117,front.width-18,10,9,ink),text("THE DAILY RITUAL",back.x+8,back.y+18,back.width-16,12,9,ink),text("Warm a few drops between\nyour palms. Smooth gently\nover face and neck.\n\nTake a quiet moment.",back.x+8,back.y+40,back.width-16,56,8.5,ink),text("For external use only.\nAvoid contact with eyes.\n\n30 mL  /  FORMULA 01",back.x+8,back.y+106,back.width-16,24,7,ink)])
    carton.artwork?.backgroundOpacity=0
    let side=net.panels.first{$0.id=="side-right"}!.bounds
    var sideTitle=text("STILL / DAILY RITUAL",side.x+6,side.y+26,side.width-12,70,8,ink);sideTitle.rotation=0;carton.artwork!.elements.append(sideTitle)
    var inside=try project.makeObject(recipeID:"artboard",name:"STILL · Inside registered",parameters:["width":net.size.x,"depth":net.size.y],materialID:"paper-superfine",position:.init(255,0,50))
    let insideFrame=try PhysicalArtworkFrame.paper(net:net,panelID:"top-tuck",inside:true)
    var registered=Artwork(background:"#F7F5EF");registered.backgroundOpacity=0;registered.canvasPosition = .init(440,40)
    var faceArtwork=registered
    faceArtwork.elements=[text("A small moment,\njust for you.",10,5,insideFrame.size.x-20,max(14,insideFrame.size.y-8),8,ink)]
    inside.artwork=try insideFrame.source(from:faceArtwork,original:registered)
    definition.insideArtworkSourceID=inside.id;carton.paperConstruction=definition;carton.rotation = -12
    var bottle=try project.makeObject(recipeID:"cylinder",name:"Serum bottle · scale study",parameters:["diameter":30,"height":106],materialID:"petg",position:.init(60,0,-15));bottle.color="#B07C43"
    project.objects=[carton,bottle,inside];project.notes=[.init("Original STILL graphics are registered to the carton net. The inside message has its own editable registered source."),.init("Carton retention, actual contents, stock caliper, grain and duplex feed remain prototype assumptions.",kind:"question")];project.history=[.init("Created the STILL straight tuck carton study.")];project.camera.distance=7;project.camera.elevation=0.68;project.schemaVersion=53;return project
  }
}
