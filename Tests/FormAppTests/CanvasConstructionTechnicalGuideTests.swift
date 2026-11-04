import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasConstructionTechnicalGuideTests:XCTestCase {
  func testLinkedFramesShowEphemeralTechnicalPathsWithoutChangingInkOrFinalPrint()throws {
    _=NSApplication.shared
    let sourceID=UUID(),ink=Artwork(elements:[.init(kind:"rectangle",x:12,y:16,width:8,height:9,color:"#123456")])
    let definition=PlanarConstructionDefinition(name:"Independent instrument plate",size:.init(100,60),stockThickness:0.5,panels:[
      .init(id:"plate",name:"Plate",polygon:[.init(20,10),.init(80,10),.init(80,40),.init(20,40)])],rootPanelID:"plate",components:[
        .init(id:"plate-piece",name:"Plate material",rootPanelID:"plate",anchor:.init(20,10),stock:.init(thicknessMM:0.5),front:.init(sourceObjectID:sourceID,sourceOriginMM:.init(7,11)))],
      production:.init(guides:[
        .init(id:"nonprinting-seam-sentinel",componentID:"plate-piece",role:.seam,points:[.init(10,0),.init(10,30)]),
        .init(id:"nonprinting-turn-sentinel",componentID:"plate-piece",role:.turnIn,points:[.init(0,8),.init(60,8)])]))
    let starter=ConstructionStarter(id:"instrument-plate",name:"Instrument plate",definition:definition,stock:.init(thicknessMM:0.5),artworkSources:[
      .init(id:sourceID,name:"Original registered plate ink",width:80,height:60,artwork:ink)])
    var project=Project(name:"Technical display isolation")
    let imported=try project.importConstructionStarter(starter),owner=try XCTUnwrap(project.objects.first{$0.id==imported.objectID})
    let before=project,paper=try PaperConstruction.definition(for:owner),net=try paper.net()
    let descriptor=try ConstructionArtworkProjection.resolve(in:project,object:owner,paper:paper,net:net,componentID:"plate-piece")
    let original=try XCTUnwrap(descriptor.artwork(in:project)),displayed=descriptor.frame.display(original)
    let local=PaperNet(size:.init(60,30),panels:[.init(id:"plate",name:"Plate",role:.body,polygon:[.init(0,0),.init(60,0),.init(60,30),.init(0,30)])],folds:[],joins:[],cutEdges:[],rootPanelID:"plate")
    let assets=FileManager.default.temporaryDirectory
    let printBefore=try PaperOutput.svg(local,artwork:displayed,assets:assets,guides:false,title:"Registered ink")
    let frames=CanvasConstructionPieces.frames(object:owner,paper:paper,net:net,project:project,startY:40)
    let proof=try XCTUnwrap(frames.first{$0.projection?.componentID=="plate-piece" && $0.projection?.inside==false && $0.projection?.panelID==nil})
    XCTAssertEqual(proof.constructionTechnicalPaths.count,2)
    XCTAssertEqual(proof.constructionTechnicalPaths.first{$0.role == .seam}?.points,[.init(10,0),.init(10,30)])
    let link=try XCTUnwrap(LinkedInspectorRelationships.table(owner,in:project).first{$0.kind == .constructionPiece("plate-piece",inside:false)})
    let review=try XCTUnwrap(LinkedInspectorArtwork.content(link,in:project,guides:true))
    XCTAssertEqual(review.constructionTechnicalPaths,proof.constructionTechnicalPaths)
    XCTAssertTrue(try XCTUnwrap(LinkedInspectorArtwork.content(link,in:project,guides:false)).constructionTechnicalPaths.isEmpty)
    XCTAssertNil(proof.sourceReview);XCTAssertEqual(project,before)
    XCTAssertEqual(proof.artwork.elements,displayed.elements)
    XCTAssertEqual(proof.artwork.elements.map(\.id),original.elements.map(\.id))
    XCTAssertEqual(try PaperOutput.svg(local,artwork:proof.artwork,assets:assets,guides:false,title:"Registered ink"),printBefore)
    XCTAssertFalse(printBefore.contains("nonprinting-seam-sentinel"));XCTAssertFalse(printBefore.contains("nonprinting-turn-sentinel"))
    XCTAssertTrue(printBefore.contains("#123456"))

    let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    let context=try XCTUnwrap(CGContext(data:nil,width:240,height:120,bitsPerComponent:8,bytesPerRow:240*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor);context.fill(.init(x:0,y:0,width:240,height:120));context.scaleBy(x:4,y:4)
    let bytes=try XCTUnwrap(context.data),count=context.bytesPerRow*context.height
    let hidden=Data(bytes:bytes,count:count)
    // The production draw caller uses the existing structure/guide switch.
    // These real pixels exercise only its separate interface drawing route.
    PaperOutput.drawConstructionReview(proof.constructionTechnicalPaths,context:context,scale:4)
    XCTAssertNotEqual(Data(bytes:bytes,count:count),hidden)
    XCTAssertEqual(try PaperOutput.svg(local,artwork:proof.artwork,assets:assets,guides:false,title:"Registered ink"),printBefore,
      "Drawing review marks must never add them to the canonical source or printed SVG.")
    XCTAssertEqual(project,before)
  }
}
