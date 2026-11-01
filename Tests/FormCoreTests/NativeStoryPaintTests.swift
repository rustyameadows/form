import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class NativeStoryPaintTests:XCTestCase {
  private func paint(_ color:String)->[ArtworkPaintLayer] {[.init(.init(color:color))]}
  private func pixels(_ project:Project,index:Int)throws->[(CGFloat,CGFloat,CGFloat)] {
    let object=project.objects[index],art=project.resolvingTextStories(in:try XCTUnwrap(object.artwork),objectID:object.id)
    let rep=try XCTUnwrap(ArtworkRenderer.image(art,width:80,height:50,assets:FileManager.default.temporaryDirectory,pixelsPerMM:3).representations.first as? NSBitmapImageRep)
    var result:[(CGFloat,CGFloat,CGFloat)]=[]
    for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {
      if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.alphaComponent>0.9 {result.append((c.redComponent,c.greenComponent,c.blueComponent))}
    }}
    return result
  }
  func testSharedStoryPaintEditsAndNewMixedRangesRenderAcrossFramesAfterReflow()throws {
    var project=Project(name:"Painted story"),frames:[StoryFrameID]=[]
    for index in 0..<2 {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":80,"depth":50])
      var text=ArtworkElement(kind:"text",x:3,y:3,width:60,height:25,text:index==0 ? String(repeating:"MMMM ",count:40):"",fontSize:20)
      text.typography = .init();text.typography!.fontName="Helvetica"
      if index==0 {text.paintStack=paint("#FF0000")}
      var art=Artwork(elements:[text],bleed:0);art.backgroundOpacity=0;page.artwork=art
      project.objects.append(page);frames.append(.init(objectID:page.id,elementID:text.id))
    }
    let storyID=try PublicationCommands.createStory(in:&project,frames:frames),storedFrames=project.objects
    var source=try XCTUnwrap(project.textStories?.first?.sourceElement)
    source.paintStack=paint("#00FF00");source.textRuns=nil
    try PublicationCommands.setSource(in:&project,storyID:storyID,source:source)
    XCTAssertEqual(project.objects,storedFrames,"Shared paint edits must not rewrite stored frame content")
    for index in 0..<2 {
      let ink=try pixels(project,index:index);XCTAssertGreaterThan(ink.count,100)
      XCTAssertTrue(ink.allSatisfy{$0.1>0.95 && $0.0<0.05 && $0.2<0.05})
    }
    source.textRuns=[]
    for location in stride(from:0,to:source.text.utf16.count,by:10) {
      var span=TextSpan(location:location,length:4,typography:source.typography ?? .init(),fontSize:20,color:"#0000FF")
      span.paintStack=paint("#0000FF");source.textRuns!.append(span)
    }
    try PublicationCommands.setSource(in:&project,storyID:storyID,source:source)
    for index in 0..<2 {
      let ink=try pixels(project,index:index)
      XCTAssertGreaterThan(ink.filter{$0.1>0.9}.count,30);XCTAssertGreaterThan(ink.filter{$0.2>0.9}.count,30)
      let object=project.objects[index],art=project.resolvingTextStories(in:object.artwork!,objectID:object.id)
      let layers=try TextPaintRenderer.vectorLayers(art.elements[0])
      XCTAssertEqual(Set(layers.filter{!$0.0.isEmpty}.map{$0.1.color}),["#00FF00","#0000FF"])
    }
    project.objects[0].artwork!.elements[0].width=35;project.objects[0].artwork!.elements[0].height=12
    try project.validatePublications()
    let flowed=try pixels(project,index:1)
    XCTAssertGreaterThan(flowed.filter{$0.1>0.9}.count,30);XCTAssertGreaterThan(flowed.filter{$0.2>0.9}.count,30)
    XCTAssertEqual(project.textStories?.first?.sourceElement.paintStack,paint("#00FF00"))
    XCTAssertEqual(project.objects[0].artwork?.elements[0].paintStack,paint("#FF0000"),"Only the transient renderer uses the shared source")
  }
}
