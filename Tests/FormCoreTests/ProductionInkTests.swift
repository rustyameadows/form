import XCTest
@testable import FormCore

final class ProductionInkTests:XCTestCase {
  private var profile:ArtworkOutputProfile {.init(name:"Print condition",asset:"icc-"+String(repeating:"a",count:64)+".icc",sha256:String(repeating:"a",count:64),model:"CMYK")}
  private func ink(_ tint:Double=1,name:String="FORM Orange")->ProductionInk {.init(kind:.spot,components:.init(0,0.65,1,0.05),profile:profile,spotName:name,tint:tint)}
  func testSourceDeclarationsValidateAndOldSwatchesRemainReadable() throws {
    let old=try JSONDecoder.form.decode(ArtworkSwatch.self,from:Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Legacy\",\"color\":\"#123456\"}".utf8))
    XCTAssertNil(old.printInk)
    var raw=try jsonObject(ink()) as! [String:Any];raw.removeValue(forKey:"tint")
    let defaultTint=try JSONDecoder.form.decode(ProductionInk.self,from:JSONSerialization.data(withJSONObject:raw))
    XCTAssertEqual(defaultTint.tint,1)
    try ink().validate();try ProductionInk(kind:.processCMYK,components:.init(0.1,0.2,0.3,0.4),profile:profile).validate()
    for name in ["All","None","Cyan","MAGENTA","Yellow","Black"," bad "] {XCTAssertThrowsError(try ink(name:name).validate())}
    var invalid=ink();invalid.components.cyan = .nan;XCTAssertThrowsError(try invalid.validate())
    invalid=ink();invalid.tint=1.1;XCTAssertThrowsError(try invalid.validate())
    invalid=ink();invalid.profile.model="RGB";XCTAssertThrowsError(try invalid.validate())
  }
  func testOneSpotIdentityAllowsDifferentTintsButRejectsConflictingAlternatesAtomically() throws {
    var p=Project(name:"Print inks")
    _ = try SwatchCommands.save(in:&p,name:"Orange100",color:"#DA6B29",printInk:ink())
    _ = try SwatchCommands.save(in:&p,name:"Orange25",color:"#F5D3B0",printInk:ink(0.25))
    let before=p;var conflicting=ink();conflicting.components.black=0.2
    XCTAssertThrowsError(try SwatchCommands.save(in:&p,name:"Conflicting Orange",color:"#CD5412",printInk:conflicting));XCTAssertEqual(p,before)
    XCTAssertEqual(p.minimumSchemaVersion,35)
  }
  func testInkDeletionAndStructuralDetachRequireExplicitPreviewConversion() throws {
    var p=Project(name:"Ink intent"),o=try p.makeObject(recipeID:"artboard")
    let id=try SwatchCommands.save(in:&p,name:"Orange",color:"#DA6B29",printInk:ink())
    var e=ArtworkElement(kind:"text",x:10,y:10,width:100,height:30,text:"Editable source",fontSize:14);e.fillSwatchID=id
    o.artwork=Artwork(elements:[e]);p.objects=[o];let before=p
    XCTAssertThrowsError(try SwatchCommands.delete(in:&p,id:id));XCTAssertEqual(p,before)
    XCTAssertThrowsError(try SwatchCommands.assign(in:&p,objectID:o.id,ids:[e.id],swatchID:nil));XCTAssertEqual(p,before)
    _ = try SwatchCommands.save(in:&p,id:id,name:"Orange preview",color:"#DA6B29",printInk:nil,replacingInk:true)
    try SwatchCommands.delete(in:&p,id:id);XCTAssertEqual(p.objects[0].artwork?.elements[0].text,e.text)
    XCTAssertNil(p.objects[0].artwork?.elements[0].fillSwatchID);XCTAssertEqual(p.objects[0].artwork?.elements[0].color,"#DA6B29")
  }
  func testSharedStoryInkAndSchema35ReopenPreserveEverySourceWordIdentityAndUndo() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root),engine=OperationEngine(repository:repository)
    let p=try Samples.fieldGuide();engine.project=p;let story=p.textStories![0],frame=story.frames[0]
    let raw=try jsonObject(ink())
    let result=try engine.call("form_swatch",arguments:["command":"create","name":"Print orange","color":"#DA6B29","print_ink":raw]) as! [String:Any]
    let id=(result["swatch"] as! [String:Any])["id"] as! String
    _ = try engine.call("form_swatch",arguments:["command":"assign","swatch_id":id,"object_id":frame.objectID.uuidString,"element_ids":[frame.elementID.uuidString]])
    let changed=engine.project!
    XCTAssertEqual(changed.textStories![0].text,story.text);XCTAssertEqual(changed.textStories![0].frames,story.frames)
    XCTAssertEqual(changed.textStories![0].listItems,story.listItems);XCTAssertEqual(changed.objects,p.objects)
    try repository.save(changed);let reopened=try repository.load(p.id)
    XCTAssertEqual(reopened.schemaVersion,35);XCTAssertEqual(reopened.swatches,changed.swatches);XCTAssertEqual(reopened.textStories,changed.textStories)
    engine.undo();engine.undo();XCTAssertEqual(engine.project,p)
  }
  func testDerivedInkGuardTracksVisibleBooleanPaintButIgnoresUnusedGroupsMasksAndHiddenLeaves() throws {
    var p=Project(name:"Ink guard")
    let id=try SwatchCommands.save(in:&p,name:"Orange",color:"#DA6B29",printInk:ink())
    var group=ArtworkElement(kind:"group",x:0,y:0,width:80,height:50);group.fillSwatchID=id
    var leaf=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:20);leaf.parentID=group.id
    var art=Artwork(elements:[group,leaf]);art.backgroundOpacity=0
    XCTAssertFalse(p.hasUsedProductionInks(in:art))
    art.elements[0].booleanOperation="union";XCTAssertTrue(p.hasUsedProductionInks(in:art))
    art.elements[0].booleanOperation=nil;art.elements[1].fillSwatchID=id;XCTAssertTrue(p.hasUsedProductionInks(in:art))
    art.elements[0].hidden=true;XCTAssertFalse(p.hasUsedProductionInks(in:art))
    art.elements[0].hidden=false;art.elements[0].clipID=leaf.id;XCTAssertFalse(p.hasUsedProductionInks(in:art))
    var empty=Artwork();empty.backgroundOpacity=0;XCTAssertFalse(p.hasUsedProductionInks(in:empty))
  }

}
