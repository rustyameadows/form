import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import XCTest
@testable import FormCore

final class PaperStockTextureAssetsTests:XCTestCase {
  private func fixture()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("portable-stock-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    engine.project=try project("Source");try engine.flush();return engine
  }
  private func project(_ name:String)throws->Project {
    var value=Project(name:name);value.objects=[try value.makeObject(recipeID:"paperEnvelope")];return value
  }
  private func assets(_ engine:OperationEngine)->URL {engine.repository.url(for:engine.project!.id).appendingPathComponent("Assets")}
  private func png(_ red:CGFloat)throws->Data {
    let context=try XCTUnwrap(CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red:red,green:0.4,blue:0.7,alpha:1));context.fill(.init(x:0,y:0,width:2,height:2))
    let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
  }
  private func reference(_ bytes:Data,name:String,engine:OperationEngine)throws->PhysicalTextureReference {
    try bytes.write(to:assets(engine).appendingPathComponent(name))
    var value=PhysicalTextureReference(asset:name,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
    value.scaleMM = .init(3.2,0.65);value.scale = .init(2,3);value.offset = .init(0.2,-0.4)
    value.rotationDegrees=37;value.wrapS = .mirror;value.wrapT = .clamp;return value
  }
  private func configure(_ engine:OperationEngine)throws->PaperStock {
    let a=try reference(png(0.2),name:"face.png",engine:engine),b=try reference(png(0.8),name:"edge.png",engine:engine)
    var face=PhysicalAppearance(),edge=PhysicalAppearance(),plyFace=PhysicalAppearance(),plyEdge=PhysicalAppearance()
    var color=a;color.colorSpace = .srgb
    face.textures["baseColor"]=color;edge.textures["normal"]=b
    plyFace.textures["roughness"]=b;plyEdge.textures["normal"]=a
    var profile=PaperSurfaceProfile();profile.appearance=face;profile.edgeAppearance=edge
    var back=PaperSurfaceProfile();back.appearance=plyFace
    var front=PaperSurfaceProfile();front.edgeAppearance=plyEdge
    let stock=PaperStock(name:"Portable optics",thicknessMM:1,profile:profile,
      plies:[.init(name:"Back",color:"#DDDDDD",thicknessMM:0.6,profile:back),.init(name:"Front",color:"#FFFFFF",thicknessMM:0.4,profile:front)])
    _ = try engine.call("form_paper",arguments:["command":"configure","object_id":engine.project!.objects[0].id.uuidString,"stock":try jsonObject(stock)])
    return stock
  }
  private func save(_ engine:OperationEngine,id:String="portable-stock")throws->Material {
    let result=try engine.call("form_paper",arguments:["command":"save_stock","object_id":engine.project!.objects[0].id.uuidString,"material_id":id])
    let raw=try XCTUnwrap((result as? [String:Any])?["material"])
    return try JSONDecoder.form.decode(Material.self,from:JSONSerialization.data(withJSONObject:raw))
  }
  private func references(_ material:Material)throws->[PhysicalTextureReference] {
    var result=[PhysicalTextureReference]()
    _ = try PaperStockTextureAssets.map(material){result.append($0);return $0};return result
  }
  private func apply(_ engine:OperationEngine,id:String,picker:Bool=false)throws {
    let arguments:[String:Any] = ["object_id":engine.project!.objects[0].id.uuidString,"material_id":id]
    _ = try engine.call(picker ? "form_update_object":"form_paper",
      arguments:picker ? arguments:arguments.merging(["command":"apply_stock"]){_,new in new})
  }
  private func visibleFiles(_ directory:URL)throws->[String] {
    guard FileManager.default.fileExists(atPath:directory.path) else{return []}
    return try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{!$0.hasPrefix(".")}.sorted()
  }

  func testSavedStockOwnsFaceAndEdgeBytesAfterSourceRemovalAndRoundTrip()throws {
    let engine=try fixture(),stock=try configure(engine),source=engine.project!,undo=engine.undoStack.count
    let saved=try save(engine),library=PaperStockTextureAssets.libraryDirectory(in:engine.repository.root)
    XCTAssertEqual(engine.project,source);XCTAssertEqual(engine.undoStack.count,undo)
    let refs=try references(saved)
    XCTAssertEqual(refs.count,4);XCTAssertEqual(Set(refs.map(\.asset)).count,2)
    XCTAssertEqual(try visibleFiles(library),Array(Set(refs.map(\.asset))).sorted())
    var original=Material("source","Source","Paper","#FFFFFF",thickness:1);original.paperStock=stock
    let before=try references(original)
    for (lhs,rhs) in zip(before,refs) {var expected=lhs;expected.asset=rhs.asset;XCTAssertEqual(expected,rhs)}
    XCTAssertEqual(try PaperStockTextureAssets.loadLibrary(from:engine.repository.root).materials.first{$0.id==saved.id},saved)
    try FileManager.default.removeItem(at:engine.repository.url(for:source.id))
    engine.project=try project("Recipient");try engine.flush()
    let target=engine.project!,targetUndo=engine.undoStack.count
    try apply(engine,id:saved.id)
    XCTAssertEqual(engine.project!.objects[0].paperConstruction?.stock,saved.paperStock)
    XCTAssertEqual(engine.undoStack.count,targetUndo+1)
    for ref in refs {
      let url=try ref.verifiedURL(in:assets(engine))
      XCTAssertEqual(try Data(contentsOf:url),try Data(contentsOf:ref.verifiedURL(in:library)))
      XCTAssertNotNil(CGImageSourceCreateWithURL(url as CFURL,nil))
    }
    let applied=engine.project!
    engine.undo();XCTAssertEqual(engine.project,target)
    engine.redo();XCTAssertEqual(engine.project,applied)
    try engine.flush()
    XCTAssertEqual(try engine.repository.load(applied.id).objects[0].paperConstruction?.stock,saved.paperStock)
  }

  func testOrdinaryMaterialPickerCopiesLibraryTexturesIntoAnotherProject()throws {
    let engine=try fixture();_ = try configure(engine);let saved=try save(engine),source=engine.project!.id
    try FileManager.default.removeItem(at:engine.repository.url(for:source))
    engine.project=try project("Picker recipient");try engine.flush();let before=engine.project!
    try apply(engine,id:saved.id,picker:true)
    for ref in try references(saved) {_ = try ref.verifiedURL(in:assets(engine))}
    XCTAssertEqual(engine.project!.objects[0].paperConstruction?.stock,saved.paperStock)
    engine.undo();XCTAssertEqual(engine.project,before)
  }

  func testLocalStockSelectionKeepsItsExistingMaterialIdentityAndFilenames()throws {
    let engine=try fixture(),stock=try configure(engine)
    var material=Material("local-stock","Local stock","Paper","#FFFFFF",thickness:1);material.paperStock=stock
    engine.project!.materials.append(material)
    let files=try visibleFiles(assets(engine)),count=engine.project!.materials.count
    try apply(engine,id:material.id,picker:true)
    XCTAssertEqual(engine.project!.objects[0].materialID,material.id)
    XCTAssertEqual(engine.project!.materials.count,count)
    XCTAssertEqual(engine.project!.materials.first{$0.id==material.id},material)
    XCTAssertEqual(try visibleFiles(assets(engine)),files)
  }

  func testMissingAndCorruptLibraryTexturesLeaveDocumentAndDestinationUntouched()throws {
    for corrupt in [false,true] {
      let engine=try fixture();_ = try configure(engine);let saved=try save(engine)
      let library=PaperStockTextureAssets.libraryDirectory(in:engine.repository.root),ref=try XCTUnwrap(references(saved).last)
      let url=library.appendingPathComponent(ref.asset)
      if corrupt {try Data("corrupt texture".utf8).write(to:url)}else{try FileManager.default.removeItem(at:url)}
      engine.project=try project("Missing source recipient");try engine.flush()
      let before=engine.project!,undo=engine.undoStack.count,files=try visibleFiles(assets(engine))
      XCTAssertThrowsError(try apply(engine,id:saved.id))
      XCTAssertThrowsError(try apply(engine,id:saved.id,picker:true))
      XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
      XCTAssertEqual(try visibleFiles(assets(engine)),files)
    }
  }

  func testDestinationConflictNeverOverwritesExistingFileOrAppliesStock()throws {
    let engine=try fixture();_ = try configure(engine);let saved=try save(engine)
    engine.project=try project("Conflict recipient");try engine.flush()
    let ref=try XCTUnwrap(references(saved).last),url=assets(engine).appendingPathComponent(ref.asset),sentinel=Data("existing unrelated bytes".utf8)
    try sentinel.write(to:url)
    let before=engine.project!,undo=engine.undoStack.count,files=try visibleFiles(assets(engine))
    XCTAssertThrowsError(try apply(engine,id:saved.id))
    XCTAssertEqual(try Data(contentsOf:url),sentinel);XCTAssertEqual(try visibleFiles(assets(engine)),files)
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
  }

  func testFailedSaveDoesNotReplaceLibraryOrPublishPartialTextureClosure()throws {
    let engine=try fixture();_ = try configure(engine)
    try StudioLibrary().save(to:engine.repository.root)
    let url=engine.repository.root.appendingPathComponent("Studio.json"),prior=try Data(contentsOf:url)
    try Data("changed source".utf8).write(to:assets(engine).appendingPathComponent("edge.png"))
    let before=engine.project!,undo=engine.undoStack.count
    XCTAssertThrowsError(try save(engine))
    XCTAssertEqual(try Data(contentsOf:url),prior)
    XCTAssertEqual(try visibleFiles(PaperStockTextureAssets.libraryDirectory(in:engine.repository.root)),[])
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
  }

  func testCorruptLibraryJSONIsNotSilentlyOverwritten()throws {
    let engine=try fixture();_ = try configure(engine)
    let url=engine.repository.root.appendingPathComponent("Studio.json"),corrupt=Data("{broken library".utf8)
    try corrupt.write(to:url);let before=engine.project!,undo=engine.undoStack.count
    XCTAssertThrowsError(try save(engine));XCTAssertThrowsError(try apply(engine,id:"unreadable"))
    XCTAssertEqual(try Data(contentsOf:url),corrupt)
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
  }

  func testBuiltInMaterialPickerDoesNotDependOnSharedLibraryReadability()throws {
    let engine=try fixture();_ = try configure(engine)
    let url=engine.repository.root.appendingPathComponent("Studio.json"),corrupt=Data("{broken library".utf8)
    try corrupt.write(to:url)
    let before=engine.project!,files=try visibleFiles(assets(engine))
    XCTAssertNil(before.materials.first{$0.id=="chalk"})
    try apply(engine,id:"chalk",picker:true)
    XCTAssertEqual(engine.project!.objects[0].materialID,"chalk")
    XCTAssertEqual(engine.project!.objects[0].paperConstruction,before.objects[0].paperConstruction)
    XCTAssertEqual(try Data(contentsOf:url),corrupt)
    XCTAssertEqual(try visibleFiles(assets(engine)),files)
    engine.undo();XCTAssertEqual(engine.project,before)
  }

  func testSameNamedSourcesWithDifferentBytesHaveIndependentImmutableLibraryNames()throws {
    let engine=try fixture();_ = try configure(engine);let first=try save(engine,id:"first-stock")
    let library=PaperStockTextureAssets.libraryDirectory(in:engine.repository.root),firstRef=try XCTUnwrap(references(first).first)
    let retained=try Data(contentsOf:firstRef.verifiedURL(in:library))
    engine.project=try project("Another source");try engine.flush();_ = try configure(engine)
    var stock=engine.project!.objects[0].paperConstruction!.stock
    let replacement=try reference(png(0.6),name:"face.png",engine:engine)
    stock.profile!.appearance!.textures["baseColor"]=replacement
    stock.plies![1].profile!.edgeAppearance!.textures["normal"]=replacement
    _ = try engine.call("form_paper",arguments:["command":"configure","object_id":engine.project!.objects[0].id.uuidString,"stock":try jsonObject(stock)])
    let second=try save(engine,id:"second-stock")
    XCTAssertNotEqual(try references(second).first?.asset,firstRef.asset)
    XCTAssertEqual(try Data(contentsOf:firstRef.verifiedURL(in:library)),retained)
    XCTAssertEqual(try visibleFiles(library).count,3)
  }
}
