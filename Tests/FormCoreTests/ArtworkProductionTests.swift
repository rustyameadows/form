import AppKit
import PDFKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkProductionTests:XCTestCase {
  private func fixture() -> (Artwork,UUID,UUID,UUID,UUID) {
    var group = ArtworkElement(kind:"group",x:12,y:18,width:120,height:90)
    group.name = "Manufacturing layers"; group.contentSize = .init(120,90); group.rotation = 12
    var print = ArtworkElement(kind:"rectangle",x:10,y:10,width:30,height:25,color:"#D84330")
    print.parentID = group.id; print.productionRole = "artwork"
    var cut = ArtworkElement(kind:"rectangle",x:50,y:10,width:30,height:25,color:"#285B8A")
    cut.parentID = group.id; cut.productionRole = "cut"; cut.fillEnabled = false
    cut.stroke = .init(color:"#285B8A",width:0.25)
    var mask = ArtworkElement(kind:"path",x:0,y:0,width:100,height:80)
    mask.parentID = group.id; mask.productionRole = "guide"
    func contour(_ x:Double,_ y:Double,_ size:Double) -> VectorContour {
      VectorContour([BezierNode(.init(x,y)),BezierNode(.init(x+size,y)),BezierNode(.init(x+size,y+size)),BezierNode(.init(x,y+size))],closed:true)
    }
    mask.path = VectorPath(width:100,height:80,contours:[contour(0,0,80),contour(20,20,10)],evenOdd:true)
    print.clipID = mask.id; cut.clipID = mask.id
    return (Artwork(background:"#FAF7EE",elements:[group,mask,print,cut],bleed:0),group.id,print.id,cut.id,mask.id)
  }
  func testEffectiveRolesPreserveLegacyAncestorExclusionAndDefaultPrint() throws {
    var (art,group,print,cut,_) = fixture()
    XCTAssertEqual(ArtworkProduction.effectiveRoles(in:art)[print],.print)
    XCTAssertEqual(ArtworkProduction.effectiveRoles(in:art)[cut],.cut)
    art.elements[0].productionRole = "score"
    XCTAssertEqual(ArtworkProduction.effectiveRoles(in:art)[print],.score)
    XCTAssertEqual(ArtworkProduction.effectiveRoles(in:art)[cut],.score)
    XCTAssertEqual(ArtworkProduction.controllingGroup(for:art.elements.first {$0.id == print}!,in:art)?.id,group)
    XCTAssertTrue(try ArtworkProduction.filtered(art,roles:[.print]).contentIDs.isEmpty)
    XCTAssertEqual(try ArtworkProduction.filtered(art,roles:[.score]).contentIDs,[print,cut])
    XCTAssertFalse(art.renderDefinition.elements.contains {$0.id == print})
  }
  func testGroupRoleAssignmentInheritsRecursivelyAndBlockedChildChangeIsAtomic() throws {
    var (art,group,print,cut,_) = fixture()
    try ArtworkCommands.apply("production",to:&art,ids:[group],arguments:["role":"engrave"])
    XCTAssertEqual(art.elements.first {$0.id == group}?.productionRole,"engrave")
    XCTAssertNil(art.elements.first {$0.id == print}?.productionRole)
    XCTAssertNil(art.elements.first {$0.id == cut}?.productionRole)
    let before = art
    XCTAssertThrowsError(try ArtworkCommands.apply("production",to:&art,ids:[print],arguments:["role":"print"]))
    XCTAssertEqual(art,before)
    try ArtworkCommands.apply("production",to:&art,ids:[group],arguments:["role":"print"])
    XCTAssertTrue(art.requiresSchemaTwentyTwo)
    XCTAssertEqual(ArtworkProduction.effectiveRoles(in:art)[cut],.print)
    try ArtworkCommands.apply("production",to:&art,ids:[group],arguments:["role":NSNull()])
    XCTAssertNil(art.elements.first {$0.id == group}?.productionRole)
    XCTAssertFalse(art.requiresSchemaTwentyTwo)
    XCTAssertEqual(ArtworkProduction.effectiveRoles(in:art)[cut],.print)
  }
  func testLockedDescendantAndInvalidRoleRejectTheWholeAssignment() throws {
    var (art,group,print,_,_) = fixture()
    art.elements[art.elements.firstIndex {$0.id == print}!].locked = true
    let before = art
    XCTAssertThrowsError(try ArtworkProduction.assign(&art,ids:[group],arguments:["role":"cut"]))
    XCTAssertEqual(art,before)
    XCTAssertThrowsError(try ArtworkProduction.assign(&art,ids:[group],arguments:["role":"laser-speed"]))
    XCTAssertEqual(art,before)
    XCTAssertThrowsError(try ArtworkProduction.parseRoles(["cut","cut"]))
    XCTAssertThrowsError(try ArtworkProduction.parseRoles([]))
    XCTAssertThrowsError(try ArtworkProduction.parseRoles([true]))
    XCTAssertThrowsError(try ArtworkProductionOutput(source:art,width:150,height:120,roles:[.print,.print]))
    XCTAssertEqual(try ArtworkProduction.parseRoles(["engrave","artwork","cut"]),[.print,.cut,.engrave])
  }
  func testRoleFilterKeepsTransformedAncestorAndSharedCompoundMaskWithoutGuideOutput() throws {
    let (art,group,print,cut,mask) = fixture()
    let result = try ArtworkProduction.filtered(art,roles:[.cut])
    XCTAssertEqual(result.contentIDs,[cut])
    XCTAssertEqual(Set(result.artwork.elements.map(\.id)),[group,cut,mask])
    XCTAssertNil(result.artwork.elements.first {$0.id == cut}?.productionRole)
    XCTAssertEqual(result.artwork.worldTransform(result.artwork.elements.first {$0.id == cut}!),art.worldTransform(art.elements.first {$0.id == cut}!))
    XCTAssertEqual(result.artwork.elements.first {$0.id == mask}?.path,art.elements.first {$0.id == mask}?.path)
    XCTAssertEqual(result.artwork.backgroundOpacity,0)
    XCTAssertFalse(result.artwork.elements.contains {$0.id == print})
    XCTAssertEqual(ArtworkProduction.hiddenIDs(in:art,roles:[.cut]),[cut])
  }
  func testLegacyPrintAndNewPrintAliasRenderByteIdentically() throws {
    var art = Artwork(background:"#FFFFFF",elements:[ArtworkElement(kind:"rectangle",x:2,y:3,width:30,height:20,color:"#C8432E")])
    let url = FileManager.default.temporaryDirectory
    let plain = try SVGRenderer.document(art,width:50,height:40,assets:url)
    art.elements[0].productionRole = "artwork"
    XCTAssertEqual(try SVGRenderer.document(art,width:50,height:40,assets:url),plain)
    art.elements[0].productionRole = "print"
    XCTAssertEqual(try SVGRenderer.document(art,width:50,height:40,assets:url),plain)
    XCTAssertEqual(art.renderDefinition.elements.count,1)
    var project = Project(name:"Production format")
    var object = try project.makeObject(recipeID:"artboard"); object.artwork = art; project.objects = [object]
    XCTAssertEqual(project.minimumSchemaVersion,22)
    let root = url.appendingPathComponent(UUID().uuidString); defer {try? FileManager.default.removeItem(at:root)}
    let repository = try ProjectRepository(root:root); try repository.save(project)
    let loaded = try repository.load(project.id)
    XCTAssertEqual(loaded.schemaVersion,22)
    XCTAssertEqual(loaded.objects[0].artwork,art)
  }
  func testSVGRoleLayersHaveUniqueIDsAndValidCompoundClipReferences() throws {
    let (art,_,print,cut,_) = fixture()
    let output = try ArtworkProductionOutput(source:art,width:150,height:120,roles:[.print,.cut,.guide])
    XCTAssertEqual(output.pages.map(\.role),[.print,.cut]) // A dependency mask is not a guide drawing.
    XCTAssertEqual(output.pages[0].contentIDs,[print]); XCTAssertEqual(output.pages[1].contentIDs,[cut])
    let svg = try output.svg(assets:FileManager.default.temporaryDirectory)
    let parser = XMLParser(data:Data(svg.utf8))
    XCTAssertTrue(parser.parse(),parser.parserError?.localizedDescription ?? "")
    XCTAssertTrue(svg.contains("width=\"150.0mm\"")); XCTAssertTrue(svg.contains("height=\"120.0mm\""))
    XCTAssertTrue(svg.contains("data-form-role=\"print\"")); XCTAssertTrue(svg.contains("data-form-role=\"cut\""))
    XCTAssertFalse(svg.contains("data-form-role=\"guide\""))
    XCTAssertTrue(svg.contains("clip-rule=\"evenodd\""))
    let regex = try NSRegularExpression(pattern:#"\bid="([^"]+)"#)
    let text = svg as NSString
    let ids = regex.matches(in:svg,range:NSRange(location:0,length:text.length)).map {text.substring(with:$0.range(at:1))}
    XCTAssertEqual(Set(ids).count,ids.count)
    let urls = try NSRegularExpression(pattern:#"url\(#([^\)]+)\)"#)
    for match in urls.matches(in:svg,range:NSRange(location:0,length:text.length)) {XCTAssertTrue(ids.contains(text.substring(with:match.range(at:1))))}
  }
  func testPDFSeparatesRolesIntoActualSizePagesAndRecordsTheirOrder() throws {
    let (art,_,_,_,_) = fixture()
    let output = try ArtworkProductionOutput(source:art,width:150,height:120,roles:[.print,.cut])
    let data = try output.pdf(assets:FileManager.default.temporaryDirectory)
    if let path = ProcessInfo.processInfo.environment["FORM_PRODUCTION_PROOF_PATH"] {
      try data.write(to:URL(fileURLWithPath:path))
      try output.svg(assets:FileManager.default.temporaryDirectory).write(to:URL(fileURLWithPath:path).deletingPathExtension().appendingPathExtension("svg"),atomically:true,encoding:.utf8)
    }
    let pdf = try XCTUnwrap(PDFDocument(data:data))
    XCTAssertEqual(pdf.pageCount,2)
    for index in 0..<pdf.pageCount {
      let size = try XCTUnwrap(pdf.page(at:index)).bounds(for:.mediaBox).size
      XCTAssertEqual(size.width,150*72/25.4,accuracy:0.001)
      XCTAssertEqual(size.height,120*72/25.4,accuracy:0.001)
    }
    let subject = pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String
    XCTAssertTrue(subject?.contains("1:print, 2:cut") == true)
  }
  func testSelectedRoleOutputCropsToChosenVisibleGeometryAndKeepsItsPhysicalScale() throws {
    let print = ArtworkElement(kind:"rectangle",x:10,y:20,width:30,height:15)
    var guide = ArtworkElement(kind:"rectangle",x:600,y:900,width:200,height:300); guide.productionRole = "guide"
    let art = Artwork(elements:[print,guide])
    let output = try ArtworkProductionOutput(source:art,width:1000,height:1300,roles:[.print],selection:[print.id,guide.id])
    XCTAssertEqual(output.width,30,accuracy:1e-9); XCTAssertEqual(output.height,15,accuracy:1e-9)
    let element = try XCTUnwrap(output.pages[0].artwork.elements.first {$0.id == print.id})
    XCTAssertEqual(output.pages[0].artwork.bounds(of:element),Rect2(0,0,30,15))
  }
}
