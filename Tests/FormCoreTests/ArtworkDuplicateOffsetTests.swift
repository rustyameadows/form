import Foundation
import XCTest
@testable import FormCore

final class ArtworkDuplicateOffsetTests:XCTestCase {
  private func fixture() -> Artwork {
    var outer=ArtworkElement(kind:"group",x:12,y:18,width:140,height:80)
    outer.name="Outer";outer.contentSize = .init(140,80);outer.affine = .translation(4,6).followed(by:.rotation(17))
    var inner=ArtworkElement(kind:"group",x:10,y:10,width:60,height:30)
    inner.name="Inner";inner.contentSize = .init(60,30);inner.parentID=outer.id
    var mask=ArtworkElement(kind:"ellipse",x:0,y:0,width:40,height:30)
    mask.name="Mask";mask.parentID=inner.id
    func path(_ name:String,_ x:Double,_ y:Double,parent:UUID)->ArtworkElement {
      var element=ArtworkElement(kind:"path",x:x,y:y,width:40,height:30)
      element.name=name;element.parentID=parent
      element.path = .init(width:40,height:30,contours:[.init([.init(.init(0,0)),.init(.init(40,0)),.init(.init(40,30)),.init(.init(0,30))])])
      element.path!.contours[0].id=UUID()
      return element
    }
    var decoration=path("Clipped path",0,0,parent:inner.id);decoration.clipID=mask.id
    var first=path("Sewing A",80,5,parent:outer.id),second=path("Sewing B",80,40,parent:outer.id)
    for element in [first,second] {
      var copy=element,piece=SewingPatternPiece(name:element.name!)
      let nodes=element.path!.contours[0].nodes
      piece.seamAllowance=2;piece.onFoldEdge=2;piece.onFoldEdgeID=nodes[2].id;piece.onFoldEndID=nodes[3].id
      var notch=SewingNotch(edge:0,position:0.5)
      notch.width=1;notch.depth=1;notch.edgeID=nodes[0].id;notch.endID=nodes[1].id;piece.notches=[notch]
      copy.sewingPiece=piece
      if copy.id==first.id {first=copy} else {second=copy}
    }
    var component=ArtworkElement(kind:"group",x:60,y:60,width:10,height:10)
    component.name="Linked component";component.parentID=outer.id;component.contentSize = .init(10,10)
    component.component = .init(sourceObjectID:UUID())
    var a=SewingSeamEnd(elementID:first.id,edge:1),b=SewingSeamEnd(elementID:second.id,edge:3)
    a.edgeID=first.path!.contours[0].nodes[1].id;a.endID=first.path!.contours[0].nodes[2].id
    b.edgeID=second.path!.contours[0].nodes[3].id;b.endID=second.path!.contours[0].nodes[0].id
    var artwork=Artwork(elements:[outer,inner,mask,decoration,first,second,component])
    artwork.sewingSeams=[.init(name:"Paired side",first:a,second:b)]
    return artwork
  }

  func testZeroOffsetClonesOneHierarchyWithoutMovingOriginalsAndRemapsPhysicalReferences()throws {
    let original=fixture();try validateArtwork(original)
    var artwork=original
    let selected=try ArtworkCommands.apply("duplicate",to:&artwork,ids:[original.elements[0].id],duplicateOffset:.init())
    let oldIDs=Set(original.elements.map(\.id)),clones=artwork.elements.filter{!oldIDs.contains($0.id)}
    XCTAssertEqual(clones.count,original.elements.count);XCTAssertEqual(selected.count,1)
    XCTAssertEqual(artwork.elements.filter{oldIDs.contains($0.id)},original.elements)
    let byName=Dictionary(uniqueKeysWithValues:clones.map{($0.name!,$0)})
    let mapping=Dictionary(uniqueKeysWithValues:original.elements.map{($0.id,byName[$0.name!]!.id)})
    XCTAssertEqual(selected,[byName["Outer"]!.id])
    for source in original.elements {
      let clone=try XCTUnwrap(byName[source.name!])
      XCTAssertEqual(clone.x,source.x);XCTAssertEqual(clone.y,source.y);XCTAssertEqual(clone.affine,source.affine)
      XCTAssertEqual(clone.parentID,source.parentID.map{mapping[$0]!})
      XCTAssertEqual(clone.clipID,source.clipID.map{mapping[$0]!})
      XCTAssertEqual(clone.component,source.component,"Component definitions and override targets stay canonically linked.")
      if let oldPath=source.path,let newPath=clone.path {
        let oldNodes=oldPath.contours.flatMap(\.nodes),newNodes=newPath.contours.flatMap(\.nodes)
        XCTAssertTrue(Set(oldNodes.map(\.id)).isDisjoint(with:Set(newNodes.map(\.id))))
        XCTAssertNotEqual(oldPath.contours[0].id,newPath.contours[0].id)
        XCTAssertEqual(newNodes.map(\.anchor),oldNodes.map(\.anchor))
        if let piece=clone.sewingPiece {
          let nodeIDs=Set(newNodes.map(\.id))
          XCTAssertTrue(nodeIDs.contains(try XCTUnwrap(piece.onFoldEdgeID)))
          XCTAssertTrue(nodeIDs.contains(try XCTUnwrap(piece.onFoldEndID)))
          XCTAssertTrue(nodeIDs.contains(try XCTUnwrap(piece.notches[0].edgeID)))
          XCTAssertTrue(nodeIDs.contains(try XCTUnwrap(piece.notches[0].endID)))
        }
      }
    }
    XCTAssertEqual(artwork.sewingSeams?.count,2);XCTAssertEqual(artwork.sewingSeams?.first,original.sewingSeams?.first)
    let seam=try XCTUnwrap(artwork.sewingSeams?.last)
    XCTAssertNotEqual(seam.id,original.sewingSeams?.first?.id)
    for end in [seam.first,seam.second] {
      let piece=try XCTUnwrap(clones.first{$0.id==end.elementID}),nodes=Set(piece.path!.contours.flatMap(\.nodes).map(\.id))
      XCTAssertTrue(nodes.contains(try XCTUnwrap(end.edgeID)));XCTAssertTrue(nodes.contains(try XCTUnwrap(end.endID)))
    }
    try validateArtwork(artwork)
  }

  func testDefaultDuplicateNudgeRemainsTenAndInvalidOffsetsFailAtomically()throws {
    let original=fixture();var artwork=original
    let selected=try ArtworkCommands.apply("duplicate",to:&artwork,ids:[original.elements[0].id])
    let clone=try XCTUnwrap(artwork.elements.first{selected.contains($0.id)})
    XCTAssertEqual(clone.x,original.elements[0].x+10);XCTAssertEqual(clone.y,original.elements[0].y+10)
    XCTAssertEqual(clone.affine,original.elements[0].affine)
    for offset in [Point2(.nan,0),.init(0,.infinity),.init(100001,0)] {
      var unchanged=original
      XCTAssertThrowsError(try ArtworkCommands.apply("duplicate",to:&unchanged,ids:[original.elements[0].id],duplicateOffset:offset))
      XCTAssertEqual(unchanged,original)
    }
  }
}
