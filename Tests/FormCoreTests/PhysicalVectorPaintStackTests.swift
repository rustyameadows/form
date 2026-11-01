import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class PhysicalVectorPaintStackTests:XCTestCase {
  private let assets=URL(fileURLWithPath:"/tmp")
  private func artwork(_ elements:[ArtworkElement])->Artwork {
    var art=Artwork(elements:elements,bleed:0);art.backgroundOpacity=0;return art
  }
  private func plan(_ elements:[ArtworkElement])throws->PhysicalVectorPlan {
    try PhysicalVectorPlan(artwork:artwork(elements),width:100,height:80,assets:assets)
  }
  private func rectangle()->ArtworkElement {
    ArtworkElement(kind:"rectangle",x:12,y:8,width:30,height:20,color:"#112233")
  }
  func testEmptyDisabledAndTransparentStacksNeverEmitLegacyGhostPaint()throws {
    for layers:[ArtworkPaintLayer] in [[],[.init(.init(color:"#FF0000"),enabled:false)],[.init(.init(color:"#FF0000",opacity:0))]] {
      var e=rectangle();e.paintStack=layers;e.fillOpacity=0.25;e.gradient=ArtworkGradient();e.stroke=ArtworkStroke(color:"#00FF00",width:8)
      let source=artwork([e]),result=try PhysicalVectorPlan(artwork:source,width:100,height:80,assets:assets)
      XCTAssertTrue(result.paints.isEmpty);XCTAssertTrue(result.issues.isEmpty)
      XCTAssertEqual(source.elements,[e],"Physical preparation must not rewrite dormant legacy appearance")
    }
  }
  func testOpaqueStacksKeepPaintOrderStrokeCoverageAndInkBindings()throws {
    var e=rectangle(),stroke=ArtworkStroke(color:"#ABCDEF",width:2)
    let fillInk=UUID(),strokeInk=UUID();e.fillSwatchID=fillInk;stroke.swatchID=strokeInk
    e.fillEnabled=false;e.fillOpacity=0.25;e.gradient=ArtworkGradient();e.stroke=ArtworkStroke(color:"#000000",width:20)
    e.paintStack=[.init(.init(color:"#FF0000")),.init(.init(color:"#0000FF")),.init(.init(color:"#00FF00"),stroke:stroke)]
    let result=try plan([e]);XCTAssertTrue(result.issues.isEmpty)
    XCTAssertEqual(result.paints.map(\.color),["#FF0000","#0000FF","#00FF00"])
    XCTAssertEqual(result.paints.map(\.swatchID),[fillInk,fillInk,strokeInk])
    XCTAssertEqual(result.paints[0].filledRegion().boundingBoxOfPath,CGRect(x:12,y:8,width:30,height:20))
    let outline=result.paints[2].filledRegion()
    XCTAssertTrue(outline.contains(.init(x:11.5,y:18)));XCTAssertFalse(outline.contains(.init(x:27,y:18)))
  }
  func testUnsupportedActiveStackPaintsBlockInsteadOfFallingBackToLegacyFill()throws {
    var stroke=ArtworkStroke(color:"#000000",width:2);stroke.opacity=0.5
    let unsupported:[ArtworkPaintLayer]=[
      .init(.init(kind:"gradient",gradient:ArtworkGradient())),
      .init(.init(kind:"image",asset:"reference.png")),
      .init(.init(color:"#FF0000",opacity:0.5)),
      .init(.init(color:"#FF0000",blendMode:"multiply")),
      .init(.init(color:"#FF0000"),stroke:stroke)]
    for layer in unsupported {
      var e=rectangle();e.paintStack=[.init(.init(color:"#00FF00")),layer]
      let result=try plan([e]);XCTAssertFalse(result.issues.isEmpty);XCTAssertTrue(result.paints.isEmpty)
      XCTAssertTrue(result.issues.allSatisfy{$0.elementID==e.id})
    }
    var invisible=rectangle();invisible.paintStack=[.init(.init(kind:"image",asset:"unused.png"),enabled:false)]
    XCTAssertTrue(try plan([invisible]).issues.isEmpty)
  }
  func testNilStackRetainsLegacyFillStrokeAndPartialOpacityRejection()throws {
    var e=rectangle(),stroke=ArtworkStroke(color:"#00FF00",width:2)
    e.fillSwatchID=UUID();stroke.swatchID=UUID();e.stroke=stroke
    let result=try plan([e]);XCTAssertTrue(result.issues.isEmpty)
    XCTAssertEqual(result.paints.map(\.color),[e.color,stroke.color])
    XCTAssertEqual(result.paints.map(\.swatchID),[e.fillSwatchID,stroke.swatchID])
    e.fillOpacity=0.5;XCTAssertFalse(try plan([e]).issues.isEmpty)
  }
  func testRichTextStacksUseShapedRangeColorsAndKeepStrokeAsOutlines()throws {
    var e=ArtworkElement(kind:"text",x:4,y:3,width:75,height:30,text:"MMMM",color:"#000000",fontSize:40)
    var type=Typography();type.fontName="Helvetica";e.typography=type
    e.paintStack=[.init(.init(color:"#FF0000"))]
    var span=TextSpan(location:2,length:2,typography:type,fontSize:40,color:"#112233")
    let spanInk=UUID();span.swatchID=spanInk
    var stroke=ArtworkStroke(color:"#00FF00",width:0.6);let strokeInk=UUID();stroke.swatchID=strokeInk
    span.paintStack=[.init(.init(color:"#0000FF")),.init(.init(color:"#00FF00"),stroke:stroke)];e.textRuns=[span]
    let result=try plan([e]);XCTAssertTrue(result.issues.isEmpty,result.issues.map(\.message).joined(separator:"\n"))
    XCTAssertEqual(Set(result.paints.map(\.color)),Set(["#FF0000","#0000FF","#00FF00"]))
    XCTAssertTrue(result.paints.filter{$0.color=="#0000FF"}.allSatisfy{$0.swatchID==spanInk})
    XCTAssertTrue(result.paints.filter{$0.color=="#00FF00"}.allSatisfy{$0.swatchID==strokeInk})
    XCTAssertTrue(result.paints.allSatisfy{!$0.path.isEmpty})
    e.textRuns![0].paintStack![1].stroke!.swatchID=nil
    XCTAssertTrue(try plan([e]).paints.filter{$0.color=="#00FF00"}.allSatisfy{$0.swatchID==nil},"A stroke must not inherit the fill's declared ink")
    e.paintStack=[];e.textRuns=nil
    XCTAssertTrue(try plan([e]).paints.isEmpty)
  }
  func testUnsupportedTextStackIsReportedWithoutLegacyColoredGlyphs()throws {
    var e=ArtworkElement(kind:"text",x:4,y:3,width:75,height:30,text:"MM",color:"#FF0000",fontSize:30)
    e.typography=Typography();e.typography?.fontName="Helvetica"
    e.paintStack=[.init(.init(kind:"gradient",gradient:ArtworkGradient()))]
    let result=try plan([e]);XCTAssertFalse(result.issues.isEmpty);XCTAssertTrue(result.paints.isEmpty)
  }
  func testCoverageMasksAreExplicitlyRejectedByOpaquePhysicalPreparation()throws {
    var mask=rectangle();mask.hidden=true
    var e=rectangle();e.paintStack=[.init(.init(color:"#FF0000"))];e.clipID=mask.id;e.clipMode="alpha"
    let result=try plan([mask,e]);XCTAssertTrue(result.paints.isEmpty);XCTAssertFalse(result.issues.isEmpty)
    e.clipMode="outline";XCTAssertTrue(try plan([mask,e]).issues.isEmpty)
  }
  func testProductionInkPreflightUsesStackAppearanceAndRejectsUnsupportedPaints()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:root)
    let project=Project(name:"Physical stack output")
    var e=rectangle();e.paintStack=[]
    var art=artwork([e]);art.outputColorProfile=profile.reference
    func report(_ art:Artwork)->[String:Any] {
      ProductionInkPDF.preflight(project:project,pages:[.init(name:"Stack",artwork:art,width:100,height:80)],assets:root)
    }
    XCTAssertEqual(report(art)["vector_paints"] as? Int,0)
    XCTAssertEqual(report(art)["can_export"] as? Bool,true)
    art.elements[0].paintStack=[.init(.init(color:"#FF0000"))]
    XCTAssertEqual(report(art)["vector_paints"] as? Int,1);XCTAssertEqual(report(art)["can_export"] as? Bool,true)
    art.elements[0].paintStack=[.init(.init(kind:"gradient",gradient:ArtworkGradient()))]
    XCTAssertEqual(report(art)["can_export"] as? Bool,false)
    XCTAssertThrowsError(try ProductionInkPDF.export(project:project,pages:[.init(name:"Stack",artwork:art,width:100,height:80)],assets:root,mode:.composite))
  }
}
