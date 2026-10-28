import XCTest
@testable import FormCore

final class SewingConstructionGuideTests: XCTestCase {
  private func source() -> Artwork {
    let nodes = [BezierNode(.init(0,0)),.init(.init(550,0)),.init(.init(550,718)),.init(.init(0,718))]
    var e=ArtworkElement(kind:"path",x:30,y:40,width:550,height:718)
    e.path = .init(width:550,height:718,contours:[.init(nodes,closed:true)])
    var piece=SewingPatternPiece(name:"Full-height physical panel")
    piece.edgeAllowances=[0:0,2:0]
    func edge(_ i:Int)->SewingConstructionEdge { .init(edge:i,edgeID:nodes[i].id,endID:nodes[(i+1)%4].id) }
    piece.unstitchedEdges=[edge(0),edge(2)]
    piece.constructionGuides=[.init(edge:edge(0),offset:8,kind:.fold,label:"Top underturn"),
      .init(edge:edge(0),offset:38,kind:.fold,label:"Nominal waist fold"),
      .init(edge:edge(0),offset:688,kind:.fold,label:"Nominal hem fold"),
      .init(edge:edge(0),offset:703,kind:.fold,label:"First 15 mm hem turn")]
    var casing=SewingConstructionGuide(edge:edge(0),offset:68,kind:.stitch,label:"Casing stitching")
    casing.opening=25;piece.constructionGuides!.append(casing)
    e.sewingPiece=piece
    return .init(background:"#FFFFFF",elements:[e],bleed:0)
  }
  func testPhysicalRawHeightCutExtentsAndNominalFoldPositionsAreDistinct() throws {
    let art=source(),g=try SewingPatterns.geometry(art.elements[0],in:art)
    XCTAssertFalse(g.usesGeneralGeometry)
    XCTAssertEqual(g.edgeLengths,[550,718,550,718])
    XCTAssertEqual(g.bounds.width,570,accuracy:1e-9);XCTAssertEqual(g.bounds.height,718,accuracy:1e-9)
    let guides=try SewingConstructionGuides.resolve(g)
    XCTAssertEqual(guides.map{$0.first.y},[48,78,728,743,108])
    XCTAssertTrue(guides.allSatisfy{abs($0.first.x-20)<1e-8 && abs($0.last.x-590)<1e-8})
    XCTAssertEqual(guides[2].first.y-guides[1].first.y,650)
    XCTAssertEqual(guides[3].first.y-guides[2].first.y,15)
    let opening=try XCTUnwrap(guides.last!.opening)
    XCTAssertEqual(hypot(opening[1].x-opening[0].x,opening[1].y-opening[0].y),25,accuracy:1e-9)
    let drawing=try SewingPatternDrawing.plan(art)
    XCTAssertFalse(drawing.artwork.elements.contains{$0.name == "Stitch outline"})
    XCTAssertEqual(drawing.artwork.elements.filter{$0.name?.hasPrefix("Stitch edge") == true}.count,2)
  }
  func testUnstitchedRawBoundariesCannotBePairedWhileFullSideEdgesCan() throws {
    var art=source();var copy=art.elements[0];copy.id=UUID();copy.x+=650
    _=PathCommands.refreshNodeIDs(in:&copy);art.elements.append(copy)
    func seam(_ edge:Int)->SewingSeam {
      let first=art.elements[0],second=art.elements[1]
      var a=SewingSeamEnd(elementID:first.id,edge:edge),b=SewingSeamEnd(elementID:second.id,edge:edge)
      a.edgeID=first.path!.contours[0].nodes[edge].id;a.endID=first.path!.contours[0].nodes[(edge+1)%4].id
      b.edgeID=second.path!.contours[0].nodes[edge].id;b.endID=second.path!.contours[0].nodes[(edge+1)%4].id
      return .init(name:"Physical side",first:a,second:b)
    }
    art.sewingSeams=[seam(0)];XCTAssertThrowsError(try SewingPatterns.validate(art))
    art.sewingSeams=[seam(1)];let report=try SewingPatterns.diagnostics(art)
    XCTAssertEqual(report[0].firstLength,718);XCTAssertTrue(report[0].matches)
  }
  func testGuideOffsetsAndOpeningRemainPhysicalUnderMirroredRotatedNonuniformSource() throws {
    var art=source();let angle=0.63
    art.elements[0].affine = .init(a:-2*cos(angle),b:-2*sin(angle),c:-1.3*sin(angle),d:1.3*cos(angle),tx:320,ty:-100)
    let g=try SewingPatterns.geometry(art.elements[0],in:art),resolved=try SewingConstructionGuides.resolve(g)
    let start=g.stitch[0],normal=g.normals[0]
    for line in resolved {
      XCTAssertEqual((line.first.x-start.x)*normal.x+(line.first.y-start.y)*normal.y,-line.guide.offset,accuracy:1e-8)
      XCTAssertEqual((line.last.x-start.x)*normal.x+(line.last.y-start.y)*normal.y,-line.guide.offset,accuracy:1e-8)
    }
    let opening=try XCTUnwrap(resolved.last!.opening)
    XCTAssertEqual(hypot(opening[1].x-opening[0].x,opening[1].y-opening[0].y),25,accuracy:1e-8)
  }
  func testInvalidGuideReferencesTopologyNumbersAndCutIntersectionsRejectExplicitly() throws {
    let original=source()
    for value in [Double.nan,.infinity,-1,0,2001] {
      var art=original;art.elements[0].sewingPiece!.constructionGuides![0].offset=value
      XCTAssertThrowsError(try SewingPatterns.geometry(art.elements[0],in:art))
    }
    var art=original;art.elements[0].sewingPiece!.constructionGuides![0].offset=718
    XCTAssertThrowsError(try SewingPatterns.geometry(art.elements[0],in:art))
    art=original;art.elements[0].path!.contours[0].nodes.reverse()
    XCTAssertThrowsError(try SewingPatterns.geometry(art.elements[0],in:art))
    art=original;art.elements[0].path!.contours[0].nodes[0].outgoing = .init(50,-20)
    XCTAssertThrowsError(try SewingPatterns.geometry(art.elements[0],in:art))
    art=original;art.elements[0].sewingPiece!.constructionGuides![4].opening=600
    XCTAssertThrowsError(try SewingPatterns.geometry(art.elements[0],in:art))
    art=original;art.elements[0].sewingPiece!.edgeAllowances[0]=5
    XCTAssertThrowsError(try SewingPatterns.geometry(art.elements[0],in:art))
  }
  func testLegacyRectangleGuideDuplicationGetsIndependentIDsAndScopedTechnicalPaths() throws {
    var art=source()
    art.elements[0].kind="rectangle";art.elements[0].path=nil
    var piece=art.elements[0].sewingPiece!
    for i in piece.unstitchedEdges!.indices {piece.unstitchedEdges![i].edgeID=nil;piece.unstitchedEdges![i].endID=nil}
    for i in piece.constructionGuides!.indices {piece.constructionGuides![i].edge.edgeID=nil;piece.constructionGuides![i].edge.endID=nil}
    art.elements[0].sewingPiece=piece
    let original=art.elements[0],ids=Set(piece.constructionGuides!.map(\.id))
    let copies=try ArtworkCommands.apply("duplicate",to:&art,ids:[original.id])
    let clone=art.elements.first{copies.contains($0.id)}!
    XCTAssertTrue(ids.isDisjoint(with:Set(clone.sewingPiece!.constructionGuides!.map(\.id))))
    let plan=try SewingPatternDrawing.plan(art)
    XCTAssertEqual(Set(plan.artwork.elements.map(\.id)).count,plan.artwork.elements.count)
    // Guide UUIDs are scoped to the owning piece even for manually authored inputs.
    let index=art.elements.firstIndex{$0.id==clone.id}!
    art.elements[index].sewingPiece!.constructionGuides=piece.constructionGuides
    XCTAssertNoThrow(try SewingPatternDrawing.plan(art))
  }
  func testLegacyMetadataIsAbsentAndExistingPieceGeometryIsIdentical() throws {
    let old=try SewingPatternTemplates.tote().artwork
    XCTAssertTrue(old.elements.allSatisfy{$0.sewingPiece?.hasConstructionMetadata != true})
    let data=try JSONEncoder.form.encode(old)
    XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("unstitchedEdges"))
    XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("constructionGuides"))
    let loaded=try JSONDecoder.form.decode(Artwork.self,from:data)
    XCTAssertEqual(try SewingPatternDrawing.plan(old).artwork,try SewingPatternDrawing.plan(loaded).artwork)
  }
}
