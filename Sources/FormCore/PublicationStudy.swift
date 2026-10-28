import Foundation

extension Samples {
  public static func fieldGuide() throws -> Project {
    let paper="#F5F1E6",ink="#243C35",rust="#A55A36"
    var p=Project(name:"ORBITAL / Field notes",subtitle:"An illustrated guide, one editable story, and three physical pages.")
    func text(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ value:String,_ size:Double=11,font:String="Georgia",color:String?=nil)->ArtworkElement {
      var e=ArtworkElement(kind:"text",x:x,y:y,width:w,height:h,text:value,color:color ?? ink,fontSize:size)
      e.typography=Typography();e.typography!.fontName=font;e.typography!.kerningMode="metrics";return e
    }
    func shape(_ kind:String,_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:String)->ArtworkElement {ArtworkElement(kind:kind,x:x,y:y,width:w,height:h,color:color)}
    func line(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:String=ink,_ weight:Double=0.22)->ArtworkElement {
      var e=shape("line",x,y,max(0.001,w),max(0.001,h),color);e.stroke = .init(color:color,width:weight);return e
    }
    var cover=try p.makeObject(recipeID:"artboard",name:"01 / Cover",parameters:["width":160,"depth":210],position:.init(-220,0,0))
    var art=Artwork(background:paper,bleed:3)
    var title=text(14,27,132,39,"LIGHT &\nMATTER",34,font:"Baskerville");title.typography!.leading=36
    art.elements=[text(14,13,132,7,"ORBITAL / OBJECT STUDIES",8,font:"Menlo-Regular",color:rust),title,
      text(14,70,108,14,"A field guide to observing, arranging, and refining a simple object.",11),
      line(14,91,132,0.001,rust,0.25)]
    var shade=shape("path",48,108,63,39,"#C8D4C5")
    shade.path = .init(width:63,height:39,contours:[.init([.init(.init(15,0)),.init(.init(48,0)),.init(.init(63,39)),.init(.init(0,39))])])
    shade.stroke = .init(color:ink,width:0.28)
    var top=shape("ellipse",63,104,33,9,paper);top.stroke = .init(color:ink,width:0.25)
    var lower=shape("ellipse",48,142,63,12,"#A9BBA5");lower.stroke = .init(color:ink,width:0.25)
    var foot=shape("ellipse",66,176,28,7,"#C8D4C5");foot.stroke = .init(color:ink,width:0.25)
    art.elements += [shade,lower,top,line(80,154,0.001,23,ink,0.7),foot,
      line(40,105,0.001,49,rust,0.18),line(38,105,4,0.001,rust,0.18),line(38,154,4,0.001,rust,0.18),
      text(16,125,20,6,"FORM",6,font:"Menlo-Regular",color:rust),
      line(102,108,21,0.001,rust,0.18),text(125,106,22,8,"01\nSHADE",6,font:"Menlo-Regular",color:rust),
      text(14,196,100,5,"FORM / FIELD NOTES",7,font:"Menlo-Regular",color:rust),text(129,196,17,5,"No.01",7,font:"Menlo-Regular",color:rust)]
    art.language="en";art.canvasPosition = .init(0,0);cover.artwork=art;p.objects.append(cover)

    let paragraphs=[
      "PREPARE THE STUDY",
      "Gather a small set of material samples, a ruler, a pencil, and a clear surface. Give each sample a useful name.",
      "Check the intended size against an object already in the room. Record the dimensions that matter to the way it will be used.",
      "Keep the original artwork editable. Place notes beside the design so that each decision has a visible reason.",
      "Compare colors in the same light before selecting a finish. Save the alternatives that help explain the final direction.",
      "ASSEMBLY SEQUENCE",
      "Begin with the largest form. Establish its width and height, then place the smaller parts around a consistent centerline.",
      "Adjust one proportion at a time. A broad shade and a narrow stem make a different silhouette from two evenly weighted parts.",
      "Look at the object from the front and from above. Use these views to check balance, spacing, and the relationship between parts.",
      "Place the decorative artwork at physical size. Keep fine lettering away from edges and seams so the composition has room to breathe.",
      "Make a second arrangement before settling on the first. A small shift in alignment often reveals which relationship is doing the work.",
      "Compare the material surfaces with the drawing. Let texture support the shape rather than compete with every line and label.",
      "Review the complete object with its notes hidden, then return to the details. Both views should describe the same idea clearly.",
      "Save the preferred arrangement and name the changes you would test next. A useful study leaves a clear path for another iteration.",
      "REFINE & RECORD",
      "Print a paper reference at actual size when a physical comparison is useful. Check the stated page dimensions before judging a small detail.",
      "Use a consistent type hierarchy for captions, dimensions, and descriptions. Reuse a style when several pieces of information serve the same purpose.",
      "Keep the final source, material references, and approved dimensions together. Good documentation makes the next conversation more specific.",
      "LANGUAGE NOTES",
      "Türkçe: istanbul, ışık, i and ı retain their original words while their displayed case changes.",
      "Lietuvių: I\u{301} J\u{301} — a small mark can carry part of the meaning.",
      "Ελληνικά: ΟΣ ΟΣΑ — form and language both depend on context."
    ]
    let words=paragraphs.joined(separator:"\n")
    var frames:[StoryFrameID]=[]
    for page in 0..<2 {
      let width=page==0 ? 160.0:210.0,height=page==0 ? 210.0:160.0
      var object=try p.makeObject(recipeID:"artboard",name:page==0 ? "02 / Prepare & assemble":"03 / Refine & record",parameters:["width":width,"depth":height],position:.init(Double(page)*230,0,20))
      var artwork=Artwork(background:paper,bleed:3);artwork.language="en";artwork.canvasPosition = .init(196+Double(page)*232,0)
      artwork.elements=[text(14,12,width-28,7,page==0 ? "01 / PREPARE & ASSEMBLE":"02 / CONTINUE THE STUDY",8,font:"Menlo-Regular",color:rust),line(14,23,width-28,0.001,rust,0.2),
        text(14,height-14,width-40,5,"ORBITAL / FIELD NOTES",7,font:"Menlo-Regular",color:rust),text(width-25,height-14,12,5,page==0 ? "02":"03",7,font:"Menlo-Regular",color:rust)]
      let column=(width-36)/2
      for index in 0..<2 {
        var e=text(14+Double(index)*(column+8),31,column,height-54,page==0 && index==0 ? words:"",11)
        e.name="Body / \(page*2+index+1)";e.typography!.hyphenation=0.8;e.typography!.paragraphAfter=3;e.typography!.alignToBaselineGrid=true
        frames.append(.init(objectID:object.id,elementID:e.id));artwork.elements.append(e)
      }
      object.artwork=artwork;p.objects.append(object)
    }
    let document=try PublicationCommands.createPublication(in:&p,name:"ORBITAL / Light & matter",pages:p.objects.map(\.id),language:"en")
    var settings=p.publications![0];settings.baselineGrid = .init(spacing:15,origin:0)
    try PublicationCommands.setPublication(in:&p,document:settings)
    let storyID=try PublicationCommands.createStory(in:&p,frames:frames,name:"A field guide to useful objects",publicationID:document)
    let storyIndex=p.textStories!.firstIndex{$0.id==storyID}!
    var source=p.textStories![storyIndex].sourceElement,runs:[TextSpan]=[],items:[ParagraphListItem]=[]
    let bulletID=UUID(),numberID=UUID()
    for (index,range) in ParagraphLists.ranges(in:words).enumerated() {
      if [0,5,14,18].contains(index) {
        var type=source.typography!;type.fontName="Menlo-Bold";type.tracking=0.6;type.caseTreatment="uppercase"
        runs.append(.init(location:range.location,length:range.length,typography:type,fontSize:8,color:rust))
      }
      if (1...4).contains(index) {items.append(.init(location:range.location,listID:bulletID,marker:.bullet))}
      if (6...13).contains(index) {items.append(.init(location:range.location,listID:numberID,marker:.decimal))}
      if index>=19 {
        var type=source.typography!;type.language=index==19 ? "tr":index==20 ? "lt":"el"
        type.caseTreatment=index==19 ? "uppercase":"lowercase"
        runs.append(.init(location:range.location,length:range.length,typography:type,fontSize:11,color:ink))
      }
    }
    source.textRuns=runs;source.listItems=items
    try PublicationCommands.setSource(in:&p,storyID:storyID,source:source)
    p.notes=[.init("An original three-page instruction study. Body text flows through four linked columns; the cover and page furniture remain independent artwork.")]
    try p.validateArtworkLinks();return p
  }
}
