import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class PhysicalAppearanceDraftEditorTests:XCTestCase {
  private func fixture()throws -> StudioStore {
    _ = NSApplication.shared
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("physical-draft-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:folder),seedLibrary:false)
    var project=Project(name:"Physical appearance editing"),object=try project.makeObject(recipeID:"paperEnvelope")
    let text=ArtworkElement(kind:"text",x:20,y:80,width:100,height:20,text:"Editable artwork",color:"#123456")
    object.artwork = .init(elements:[text])
    object.paperConstruction!.stock.profile = .init(texture:.linen,roughness:0.43,textureScaleMM:0.7,textureDepthMM:0.006)
    object.paperConstruction!.stock.plies=[.init(name:"Back",color:"#DDBBAA",thicknessMM:0.2),.init(name:"Face",color:"#FFEECC",thicknessMM:0.15)]
    object.paperConstruction!.finishes=[.init(name:"Ink impression",kind:.letterpress,elementIDs:[text.id],depthMM:0.04,roughness:0.32)]
    project.objects=[object];store.engine.project=project;store.showingHome=false
    addTeardownBlock { @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:folder) }
    return store
  }
  private func settle(_ root:NSView) {
    root.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.07));root.layoutSubtreeIfNeeded()
  }
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func accessible(_ value:Any,where match:(any NSAccessibilityProtocol)->Bool,depth:Int=0)->(any NSAccessibilityProtocol)? {
    guard depth<80,let node=value as? any NSAccessibilityProtocol else{return nil}
    if match(node) {return node}
    for child in node.accessibilityChildren() ?? [] {if let result=accessible(child,where:match,depth:depth+1){return result}}
    return nil
  }
  private func press(_ title:String,in root:NSView)throws {
    // Choose the mounted NSButton itself, before its accessibility cell proxy.
    let native=try XCTUnwrap(descendants(root).compactMap{$0 as? NSButton}.first{
      $0.title==title || $0.accessibilityLabel()==title
    },"Missing native button: "+title)
    native.performClick(nil);settle(root)
  }
  private func host<V:View>(_ view:V,store:StudioStore,width:Double=648,height:Double=788)->(NSWindow,NSView) {
    let root=NSHostingView(rootView:view.environmentObject(store).labInterface())
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:width,height:height),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=root;window.orderBack(nil);settle(root)
    addTeardownBlock { @MainActor in window.makeFirstResponder(nil);window.contentView=nil;window.close() }
    return (window,root)
  }
  private func edit(_ title:String,to value:String,window:NSWindow,root:NSView)throws {
    let field=try XCTUnwrap(descendants(root).compactMap{$0 as? NSTextField}.first{$0.isEditable && $0.placeholderString==title},"Missing field: "+title)
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor=try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil);editor.insertText(value,replacementRange:.init(location:NSNotFound,length:0));settle(root)
    window.makeFirstResponder(nil);settle(root)
  }
  func testPaperScopesApplyOneUndoAndPreserveConstructionArtworkAndFinishRelief()throws {
    let store=try fixture(),original=store.project!,object=original.objects[0],paper=object.paperConstruction!
    let scopes:[PaperPhysicalAppearanceDraft.Scope]=[.stock,.ply(paper.stock.plies![1].id),.finish(paper.finishes![0].id)]
    var optics=PhysicalAppearance();optics.ior=1.46;optics.diffuseTransmission=0.18;optics.normalStrength=0.37;optics.sheen=0.61
    for scope in scopes {
      let target=try PaperPhysicalAppearanceDraft(project:store.project!,object:store.project!.objects[0],scope:scope)
      try target.apply(optics,to:store)
      let changed=store.project!.objects[0],result=changed.paperConstruction!
      XCTAssertEqual(changed.artwork,object.artwork);XCTAssertEqual(changed.parameters,object.parameters)
      var sanitized=result
      switch scope {
      case .stock:
        XCTAssertEqual(result.stock.profile!.appearance,optics);sanitized.stock.profile!.appearance=nil
      case .ply(let id):
        let index=try XCTUnwrap(result.stock.plies!.firstIndex{$0.id==id})
        XCTAssertEqual(result.stock.plies![index].profile!.appearance,optics)
        XCTAssertEqual(result.stock.plies![index].profile!.roughness,paper.stock.profile!.roughness)
        XCTAssertNil(result.stock.plies![index].profile!.color)
        sanitized.stock.plies![index].profile=nil
      case .finish:
        XCTAssertEqual(result.finishes![0].appearance,optics);sanitized.finishes![0].appearance=nil
      case .stockEdge,.plyEdge:XCTFail("This test covers face scopes; edge scopes have separate preservation coverage.")
      }
      XCTAssertEqual(sanitized,paper);XCTAssertEqual(store.engine.undoStack.count,1)
      store.engine.undo();XCTAssertEqual(store.project,original)
    }
  }
  func testApplyPreservesConcurrentManufacturingChangesAndRejectsStaleOptics()throws {
    let store=try fixture(),target=try PaperPhysicalAppearanceDraft(project:store.project!,object:store.project!.objects[0],scope:.stock)
    store.engine.project!.objects[0].paperConstruction!.stock.notes="Measured independently while sheet is open"
    store.engine.project!.objects[0].paperConstruction!.stock.gsm=340
    let before=store.project!;var optics=PhysicalAppearance();optics.coat=0.42
    try target.apply(optics,to:store)
    XCTAssertEqual(store.project!.objects[0].paperConstruction!.stock.notes,before.objects[0].paperConstruction!.stock.notes)
    XCTAssertEqual(store.project!.objects[0].paperConstruction!.stock.gsm,340)
    let accepted=store.project!;XCTAssertThrowsError(try target.apply(.init(),to:store));XCTAssertEqual(store.project,accepted)
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.project!.objects[0].locked=true
    XCTAssertThrowsError(try target.apply(optics,to:store));XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testClearingAnExistingStockOverrideUsesExplicitNullAndOneUndo()throws {
    let store=try fixture();var optics=PhysicalAppearance();optics.sheen=0.73
    store.engine.project!.objects[0].paperConstruction!.stock.profile!.appearance=optics
    let before=store.project!,target=try PaperPhysicalAppearanceDraft(project:before,object:before.objects[0],scope:.stock)
    try target.apply(nil,to:store)
    XCTAssertNil(store.project!.objects[0].paperConstruction!.stock.profile!.appearance)
    XCTAssertEqual(store.project!.objects[0].paperConstruction!.stock.profile!.roughness,before.objects[0].paperConstruction!.stock.profile!.roughness)
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testInheritedOpticalChangeWhileSheetIsOpenRejectsStaleApply()throws {
    let store=try fixture(),target=try PaperPhysicalAppearanceDraft(project:store.project!,object:store.project!.objects[0],scope:.stock)
    var material=store.project!.material(store.project!.objects[0].materialID),optics=PhysicalAppearance()
    optics.sheen=0.28;material.appearance=optics;store.engine.project!.materials=[material]
    let before=store.project!
    XCTAssertThrowsError(try target.apply(.init(),to:store))
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testCutEdgeDraftScopesPreserveFacesAndUndoAndClearToStockFallback()throws {
    let store=try fixture();var face=PhysicalAppearance(),edge=PhysicalAppearance(),override=PhysicalAppearance()
    face.coat=0.64;edge.sheen=0.31;override.sheen=0.77
    store.engine.project!.objects[0].paperConstruction!.stock.profile!.appearance=face
    store.engine.project!.objects[0].paperConstruction!.stock.profile!.edgeAppearance=edge
    let original=store.project!,id=original.objects[0].paperConstruction!.stock.plies![1].id
    for scope:PaperPhysicalAppearanceDraft.Scope in [.stockEdge,.plyEdge(id)] {
      let target=try PaperPhysicalAppearanceDraft(project:store.project!,object:store.project!.objects[0],scope:scope)
      if case .plyEdge=scope {XCTAssertEqual(target.fallback,edge)}
      try target.apply(override,to:store)
      let paper=store.project!.objects[0].paperConstruction!
      XCTAssertEqual(paper.stock.profile!.appearance,face)
      XCTAssertEqual(paper.finishes,original.objects[0].paperConstruction!.finishes)
      XCTAssertEqual(store.project!.objects[0].parameters,original.objects[0].parameters)
      if case .plyEdge=scope {
        XCTAssertEqual(paper.stock.plies![1].profile?.edgeAppearance,override)
        XCTAssertNil(paper.stock.plies![1].profile?.appearance,"Editing an edge must not freeze the inherited face optics.")
      }else{XCTAssertEqual(paper.stock.profile?.edgeAppearance,override)}
      XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,original)
    }
    let clear=try PaperPhysicalAppearanceDraft(project:store.project!,object:store.project!.objects[0],scope:.stockEdge)
    try clear.apply(nil,to:store)
    XCTAssertNil(store.project!.objects[0].paperConstruction!.stock.profile?.edgeAppearance)
    XCTAssertEqual(store.project!.objects[0].paperConstruction!.stock.profile?.appearance,face)
    store.engine.undo();XCTAssertEqual(store.project,original)
  }
  func testTextureReplacementPreservesMappingUntilApplyAndOneUndoRestoresSource()throws {
    let store=try fixture()
    var original=PhysicalTextureReference(asset:"original.png",sha256:String(repeating:"a",count:64),colorSpace:.data)
    original.wrapS = .mirror;original.wrapT = .clamp;original.scale = .init(1.4,0.7)
    original.offset = .init(0.2,-0.3);original.rotationDegrees=37;original.scaleMM = .init(2.3,1.9)
    let other=PhysicalTextureReference(asset:"other.png",sha256:String(repeating:"b",count:64))
    var optics=PhysicalAppearance();optics.textures=["baseColor":original,"roughness":other]
    store.engine.project!.objects[0].paperConstruction!.stock.profile!.appearance=optics
    let before=store.project!,target=try PaperPhysicalAppearanceDraft(project:before,object:before.objects[0],scope:.stock)
    var draft=optics
    let controls=PhysicalAppearanceDraftControls(appearance:Binding(get:{draft},set:{draft=$0}),error:.constant(""))
    let imported=PhysicalTextureReference(asset:"replacement.tiff",sha256:String(repeating:"c",count:64),colorSpace:.linearSRGB)
    controls.replaceTextureSource(imported,for:.baseColor)
    var expected=original;expected.asset=imported.asset;expected.sha256=imported.sha256;expected.colorSpace=imported.colorSpace
    XCTAssertEqual(draft.textures["baseColor"],expected);XCTAssertEqual(draft.textures["roughness"],other)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    try target.apply(draft,to:store)
    XCTAssertEqual(store.project!.objects[0].paperConstruction!.stock.profile!.appearance,draft)
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testTextureReplacementRetainsSecondUVAndNewChannelUsesImportedDefaults()throws {
    var original=PhysicalTextureReference(asset:"existing.png",sha256:String(repeating:"a",count:64),colorSpace:.srgb)
    original.uvIndex=1;original.wrapS = .clamp;original.wrapT = .mirror
    original.scale = .init(0.25,2);original.offset = .init(-0.7,0.3);original.rotationDegrees = -90
    var draft=PhysicalAppearance();draft.textures["baseColor"]=original
    let controls=PhysicalAppearanceDraftControls(appearance:Binding(get:{draft},set:{draft=$0}),error:.constant(""))
    let imported=PhysicalTextureReference(asset:"new.png",sha256:String(repeating:"d",count:64),colorSpace:.linearSRGB)
    controls.replaceTextureSource(imported,for:.baseColor)
    let replacement=try XCTUnwrap(draft.textures["baseColor"])
    XCTAssertEqual(replacement.uvIndex,1);XCTAssertEqual(replacement.wrapS,.clamp);XCTAssertEqual(replacement.wrapT,.mirror)
    XCTAssertEqual(replacement.scale,original.scale);XCTAssertEqual(replacement.offset,original.offset)
    XCTAssertEqual(replacement.rotationDegrees,-90);XCTAssertNil(replacement.scaleMM)
    XCTAssertEqual(replacement.asset,imported.asset);XCTAssertEqual(replacement.sha256,imported.sha256);XCTAssertEqual(replacement.colorSpace,.linearSRGB)
    controls.replaceTextureSource(imported,for:.emission)
    XCTAssertEqual(draft.textures["emission"],imported)
    XCTAssertEqual(draft.textures["baseColor"],replacement)
  }
  func testNativeOpticalFieldStaysLocalUntilApplyThenUndoRestoresProject()throws {
    let store=try fixture(),before=store.project!,target=try PaperPhysicalAppearanceDraft(project:before,object:before.objects[0],scope:.stock)
    let (window,root)=host(PhysicalAppearanceDraftEditor(title:"Stock appearance",subtitle:target.name,appearance:target.appearance,fallback:target.fallback){appearance,_ in try target.apply(appearance,to:store)},store:store)
    try edit("Index of refraction",to:"1.72",window:window,root:root)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    try press("Apply",in:root)
    XCTAssertEqual(try XCTUnwrap(store.project!.objects[0].paperConstruction!.stock.profile!.appearance).ior,1.72,accuracy:0.00001)
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testNativeThreadSheetKeepsRoughnessAndOpticsInParentDraftUntilSave()throws {
    let store=try fixture();var project=store.project!,object=try project.makeObject(recipeID:"textilePatch",parameters:["width":80,"depth":60,"corner":3])
    let line=ArtworkElement(kind:"line",x:8,y:8,width:30,height:0.1,color:"#123456")
    object.artwork = .init(elements:[line]);object.textile!.embroidery = .init(threads:[.init(name:"Test thread",color:line.color)],regions:[.init(elementIDs:[line.id],method:.running)])
    project.objects=[object];store.engine.project=project;let before=project
    let (window,root)=host(EmbroideryEditor(object:object,project:project),store:store,width:1132,height:832)
    try press("Physical thread appearance…",in:root)
    let sheet=try XCTUnwrap(window.attachedSheet),sheetRoot=try XCTUnwrap(sheet.contentView);settle(sheetRoot)
    try edit("Index of refraction",to:"1.62",window:sheet,root:sheetRoot)
    let roughness=try XCTUnwrap(descendants(sheetRoot).compactMap{accessible($0,where:{$0.accessibilityRole() == .slider && $0.accessibilityLabel()=="Thread roughness"})}.first)
    roughness.setAccessibilityValue(NSNumber(value:0.27));settle(sheetRoot)
    try press("Apply",in:sheetRoot);settle(root)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    try press("Save embroidery",in:root)
    let actual=try XCTUnwrap(store.project!.objects[0].textile?.embroidery)
    XCTAssertEqual(try XCTUnwrap(actual.threads[0].appearance).ior,1.62,accuracy:0.00001)
    XCTAssertEqual(try XCTUnwrap(actual.threads[0].roughness),0.27,accuracy:0.00001)
    var restored=actual;restored.threads[0].appearance=nil;restored.threads[0].roughness=nil
    XCTAssertEqual(restored,object.textile!.embroidery);XCTAssertEqual(store.project!.objects[0].artwork,object.artwork)
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,before)
  }
}
