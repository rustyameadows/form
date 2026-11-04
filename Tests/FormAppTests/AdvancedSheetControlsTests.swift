import AppKit
import FormCADModel
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class AdvancedSheetControlsTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID) {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var project=Project(name:"Native physical control sources")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
    page.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:10,y:12,width:60,height:20,text:"Canonical printed source",color:"#173A52")],bleed:0);page.artwork?.backgroundOpacity=0
    project.objects.append(page)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Native document",pages:[page.id])
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:[.init(id:"panel",name:"Generic panel",size:.init(100,140))]))
    store.engine.project=project;store.showingHome=false
    addTeardownBlock{@MainActor in store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    return(store,assembly)
  }
  private func descendants<T:NSView>(_ root:NSView,_ type:T.Type)->[T] {
    ((root as? T).map{[$0]} ?? [])+root.subviews.flatMap{descendants($0,type)}
  }
  private func settle(_ root:NSView){root.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05));root.layoutSubtreeIfNeeded()}
  func testCreatingLinkedPhysicalFaceCreatesOneTransparentCanonicalSourceWithOneUndoAndReopen()throws {
    let(store,id)=try fixture(),before=try XCTUnwrap(store.project)
    let created=try XCTUnwrap(SheetAssemblySourceEditing.create(session:store.artworkSession,projectID:before.id,objectID:id,name:"Front physical artwork",size:.init(100,140)){definition,face in definition.enclosure![0].front=face})
    let after=try XCTUnwrap(store.project),source=try XCTUnwrap(after.objects.first{$0.id==created})
    XCTAssertEqual(source.recipeID,"artboard");XCTAssertEqual(source.artworkSize,.init(100,140));XCTAssertEqual(source.artwork?.backgroundOpacity,0);XCTAssertTrue(source.canvasSourceOnly==true)
    XCTAssertEqual(after.objects.first{$0.id==id}?.sheetAssembly?.enclosure?.first?.front?.sourceObjectID,created)
    XCTAssertEqual(after.objects.filter{$0.id != id && $0.id != created},before.objects.filter{$0.id != id});XCTAssertEqual(after.publications,before.publications)
    XCTAssertEqual(store.engine.undoStack.count,1)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(after))
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.publications,after.publications);XCTAssertEqual(reopened.camera,after.camera);XCTAssertEqual(try JSONEncoder.form.encode(reopened),try JSONEncoder.form.encode(after))
    store.engine.undo();XCTAssertEqual(store.project,before);store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testRemovedSurfaceAndImportedProjectRejectSourceCreationWithoutOrphanOrHistory()throws {
    let(store,id)=try fixture(),before=try XCTUnwrap(store.project)
    let missing=SheetAssemblySourceEditing.create(session:store.artworkSession,projectID:before.id,objectID:id,name:"No orphan",size:.init(100,140)){_,_ in throw FormError.missing("Surface no longer exists.")}
    XCTAssertNil(missing);XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    var imported=before;imported.id=UUID();store.engine.project=imported
    var called=false
    XCTAssertNil(SheetAssemblySourceEditing.create(session:store.artworkSession,projectID:before.id,objectID:id,name:"Wrong project",size:.init(100,140)){_,_ in called=true})
    XCTAssertFalse(called);XCTAssertEqual(store.project,imported);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testPaleYellowStockAndDuplexCaliperPreservePrintedInkAndPlyProportions()throws {
    let(store,id)=try fixture(),before=try XCTUnwrap(store.project)
    try store.engine.edit("Updated material stock"){project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==id})
      var stock=PaperStock(thicknessMM:0.3,plies:[.init(name:"Face",color:"#FFFFFF",thicknessMM:0.1),.init(name:"Back",color:"#EEEEEE",thicknessMM:0.2)])
      SheetStockControlEditing.setCaliper(0.6,in:&stock)
      SheetStockControlEditing.setColor("#F3E6A4",in:&stock)
      SheetParentStockEditing.setColor("#F3E6A4",plyID:stock.plies![0].id,in:&stock)
      project.objects[index].sheetAssembly!.stock=stock
    }
    let after=try XCTUnwrap(store.project),stock=try XCTUnwrap(after.objects.first{$0.id==id}?.sheetAssembly?.stock)
    XCTAssertEqual(stock.resolvedThicknessMM,0.6,accuracy:1e-10);XCTAssertEqual(stock.plies![0].thicknessMM,0.2,accuracy:1e-10);XCTAssertEqual(stock.plies![1].thicknessMM,0.4,accuracy:1e-10)
    XCTAssertEqual(stock.profile?.color,"#F3E6A4");XCTAssertEqual(SheetParentStockEditing.color(of:stock.plies![0]),"#F3E6A4")
    XCTAssertEqual(after.objects.first?.artwork,before.objects.first?.artwork);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testDimensionRelationshipReplacementIsSourcePreservingAtomicAndUndoable()throws {
    let(store,_)=try fixture(),before=try XCTUnwrap(store.project),target=before.objects[0]
    var project=before
    let source=try project.makeObject(recipeID:"artboard",name:"Dimension authority",parameters:["width":75,"depth":140]);project.objects.append(source);store.engine.project=project
    let binding=PhysicalDimensionBinding(parameter:"width",expression:"sourceWidth+5",inputs:["sourceWidth":.init(sourceObjectID:source.id,measurement:.width)])
    XCTAssertTrue(SheetDimensionRelationshipEditing.replace(session:store.artworkSession,projectID:project.id,objectID:target.id,bindings:[binding]))
    let after=try XCTUnwrap(store.project)
    XCTAssertEqual(after.objects[0].parameters["width"],80);XCTAssertEqual(after.objects[0].artwork,target.artwork)
    XCTAssertEqual(after.objects.last,source);XCTAssertEqual(store.engine.undoStack.count,1)
    var invalid=binding;invalid.expression="missing+5"
    XCTAssertFalse(SheetDimensionRelationshipEditing.replace(session:store.artworkSession,projectID:project.id,objectID:target.id,bindings:[invalid]))
    XCTAssertEqual(store.project,after);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project,project);store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testMountedExpressionInputRetainsAuthoredParameterInsteadOfSamplingNumber()throws {
    var value=CADScalar(100)
    let host=NSHostingView(rootView:SheetExpressionField(title:"Physical width",value:Binding(get:{value},set:{value=$0}),parameters:["trimWidth","spineThickness"]).padding(12))
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:360,height:120),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);settle(host)
    defer{window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    let field=try XCTUnwrap(descendants(host,NSTextField.self).first{$0.isEditable && $0.placeholderString=="Physical width"})
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor=try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil);editor.insertText("trimWidth + spineThickness",replacementRange:.init(location:NSNotFound,length:0));editor.doCommand(by:#selector(NSResponder.insertNewline(_:)));settle(host)
    XCTAssertEqual(value.expression,"trimWidth + spineThickness")
  }
  func testMountedProjectAuthoredAssemblyParameterUsesNativeControlAndSingleUndo()throws {
    let(store,id)=try fixture(),original=try XCTUnwrap(store.project)
    let publication=try XCTUnwrap(original.objects.first{$0.id==id}?.sheetAssembly?.publicationID)
    let recipe=Recipe("nativeLayerControls","Native layer controls","slider.horizontal.3","Project-owned physical dimensions",[.init("boardMM","Authored board caliper",2,0.5...4,step:0.1)])
    _=try store.engine.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe)])
    let definition=SheetAssemblyDefinition(publicationID:publication,enclosure:[.init(id:"core",name:"Physical core",size:.init(100,140),features:.init(stockThickness:"boardMM"))])
    let created=try XCTUnwrap(store.engine.call("form_publication",arguments:["command":"sheet_assembly_create","recipe_id":recipe.id,"definition":try jsonObject(definition)]) as? [String:Any])
    let identifier=try XCTUnwrap(created["object_id"] as? String),before=try XCTUnwrap(store.project)
    let object=try XCTUnwrap(before.objects.first{$0.id.uuidString==identifier}),history=store.engine.undoStack.count
    let host=NSHostingView(rootView:ParameterControl(parameter:recipe.parameters[0],object:object).environmentObject(store).labInterface().padding(12))
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:320,height:150),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.orderBack(nil);settle(host)
    defer{window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    let field=try XCTUnwrap(descendants(host,NSTextField.self).first{$0.isEditable && $0.placeholderString=="Authored board caliper"})
    XCTAssertTrue(window.makeFirstResponder(field));let editor=try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil);editor.insertText("2.4 mm",replacementRange:.init(location:NSNotFound,length:0));editor.doCommand(by:#selector(NSResponder.insertNewline(_:)));settle(host)
    let changed=try XCTUnwrap(store.project),updated=try XCTUnwrap(changed.objects.first{$0.id==object.id})
    XCTAssertEqual(updated.parameters["boardMM"],2.4);XCTAssertEqual(try changed.resolvedSheetAssembly(updated).enclosure[0].stock.resolvedThicknessMM,2.4)
    XCTAssertEqual(changed.objects.filter{$0.id != object.id},before.objects.filter{$0.id != object.id});XCTAssertEqual(store.engine.undoStack.count,history+1)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }

  func testSharedSurfaceDetailChangesEffectiveExplicitAndInheritedProfilesOneChannelAtATime()throws {
    let back=PaperPly(name:"Colored back",color:"#D8C7A4",thicknessMM:0.1,profile:.init(texture:.laid,color:"#BBAA88",roughness:0.7,textureScaleMM:0.6,textureDepthMM:0.01,opacity:0.9))
    let middle=PaperPly(name:"Inherited core",color:"#AABBCC",thicknessMM:0.1)
    let front=PaperPly(name:"Linen face",color:"#224433",thicknessMM:0.1,profile:.init(texture:.linen,color:"#335544",roughness:0.94,textureScaleMM:0.8,textureDepthMM:0.02,opacity:1))
    var stock=PaperStock(name:"Shared material detail",thicknessMM:0.3,profile:.init(texture:.cotton,color:"#EEEEEE",roughness:0.8),plies:[back,middle,front])
    let before=stock
    SheetStockControlEditing.setSurface(in:&stock){$0.roughness=0.45}
    let object=ProductObject(name:"Generic substrate",recipeID:"artboard",parameters:["width":100,"depth":140]),project=Project(name:"Effective material channels")
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:false).profile.roughness,0.45)
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:true).profile.roughness,0.45)
    XCTAssertEqual(stock.profile?.roughness,0.45);XCTAssertNil(stock.plies![1].profile)
    XCTAssertEqual(stock.plies![0].profile?.color,back.profile?.color);XCTAssertEqual(stock.plies![2].profile?.color,front.profile?.color)
    XCTAssertEqual(stock.plies!.map(\.thicknessMM),before.plies!.map(\.thicknessMM));XCTAssertEqual(stock.plies!.map(\.id),before.plies!.map(\.id))
    XCTAssertEqual(stock.plies![0].profile?.texture,.laid);XCTAssertEqual(stock.plies![2].profile?.texture,.linen)
    XCTAssertEqual(stock.plies![0].profile?.textureDepthMM,0.01);XCTAssertEqual(stock.plies![2].profile?.textureDepthMM,0.02)
    SheetStockControlEditing.setSurface(in:&stock){$0.opacity=0.8}
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:false).profile.opacity,0.8)
    XCTAssertEqual(PaperGeometry.faceAppearance(for:object,stock:stock,project:project,inside:true).profile.opacity,0.8)
    XCTAssertEqual(stock.plies![0].profile?.roughness,0.45);XCTAssertEqual(stock.plies![2].profile?.roughness,0.45)
    try stock.validate()
  }

}
