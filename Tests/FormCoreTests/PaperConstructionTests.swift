import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PaperConstructionTests:XCTestCase {
  private func fixture(_ recipe:String="paperEnvelope")throws->OperationEngine {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("paper-core-"+UUID().uuidString),repository=try ProjectRepository(root:folder),engine=OperationEngine(repository:repository)
    addTeardownBlock{try? FileManager.default.removeItem(at:folder)};var p=Project(name:"Paper source test");p.objects=[try p.makeObject(recipeID:recipe)];engine.project=p;return engine
  }
  private func transformed(_ m:[Double],_ p:Point2,z:Double=0)->Vector3{.init(m[0]*p.x-m[1]*p.y+m[2]*z+m[3],m[4]*p.x-m[5]*p.y+m[6]*z+m[7],m[8]*p.x-m[9]*p.y+m[10]*z+m[11])}
  func testDeterministicNetsHaveStableSemanticIDsAndNoCutThroughAnyCreaseInterior()throws {
    for recipe in ["paperEnvelope","tuckCarton"]{
      let source=PaperConstructionEngine.defaults(recipeID:recipe),net=try source.net(),again=try source.net();XCTAssertEqual(net,again);XCTAssertEqual(net.panels.count,recipe=="paperEnvelope" ? 9:13);XCTAssertEqual(net.folds.count,net.panels.count-1)
      XCTAssertEqual(net.joins.filter{$0.kind=="glue"}.count,recipe=="paperEnvelope" ? 2:1)
      var changed=source;changed.dimensions.width+=10;let resized=try changed.net();XCTAssertEqual(net.panels.map(\.id),resized.panels.map(\.id));XCTAssertEqual(net.folds.map(\.id),resized.folds.map(\.id));XCTAssertEqual(net.cutEdges.map(\.id),resized.cutEdges.map(\.id))
      for fold in net.folds{for cut in net.cutEdges{
        let dx=fold.end.x-fold.start.x,dy=fold.end.y-fold.start.y,length=hypot(dx,dy),a=abs(dx*(cut.start.y-fold.start.y)-dy*(cut.start.x-fold.start.x))/length,b=abs(dx*(cut.end.y-fold.start.y)-dy*(cut.end.x-fold.start.x))/length
        if a<1e-7&&b<1e-7{let u=((cut.start.x-fold.start.x)*dx+(cut.start.y-fold.start.y)*dy)/(length*length),v=((cut.end.x-fold.start.x)*dx+(cut.end.y-fold.start.y)*dy)/(length*length);XCTAssertLessThanOrEqual(min(1,max(u,v))-max(0,min(u,v)),1e-7,"Cut \(cut.id) overlaps crease \(fold.id)")}
      }}
      // Independent separating-axis check of positive-area overlap for convex panels.
      for i in net.panels.indices{for j in net.panels.indices where j>i{let a=net.panels[i].polygon,b=net.panels[j].polygon;var separated=false
        for polygon in [a,b]{for k in polygon.indices{let p=polygon[k],q=polygon[(k+1)%polygon.count],nx=q.y-p.y,ny=p.x-q.x,pa=a.map{$0.x*nx+$0.y*ny},pb=b.map{$0.x*nx+$0.y*ny};if min(pa.max()!,pb.max()!)-max(pa.min()!,pb.min()!)<=1e-6{separated=true}}}
        XCTAssertTrue(separated,"Flat panels overlap: \(net.panels[i].id), \(net.panels[j].id)")
      }}
    }
  }
  func testFoldTransformsAreRigidGroundedUprightAndOutsideOrientationIsConsistent()throws {
    for recipe in ["paperEnvelope","tuckCarton"]{let source=PaperConstructionEngine.defaults(recipeID:recipe),net=try source.net()
      for amount in [0.0,25,60,100]{let poses=try source.resolvedPanels(foldPercent:amount);XCTAssertEqual(poses.count,net.panels.count);var minY=Double.infinity
        for pose in poses{let m=pose.flatToWorld;XCTAssertEqual(m.count,16);XCTAssertTrue(m.allSatisfy(\.isFinite));let determinant=m[0]*(m[5]*m[10]-m[6]*m[9])-m[1]*(m[4]*m[10]-m[6]*m[8])+m[2]*(m[4]*m[9]-m[5]*m[8]);XCTAssertEqual(determinant,1,accuracy:1e-10)
          let panel=net.panels.first{$0.id==pose.panelID}!;for point in panel.polygon{minY=min(minY,transformed(m,point,z:-source.stock.thicknessMM/2).y,transformed(m,point,z:source.stock.thicknessMM/2).y)}
          if amount==0{XCTAssertEqual(m[6],1,accuracy:1e-10)}
        };XCTAssertEqual(minY,0,accuracy:1e-8)
      }
      let poses=try source.resolvedPanels(),front=poses.first{$0.panelID=="front"}!.flatToWorld,back=poses.first{$0.panelID=="back"}!.flatToWorld,right=poses.first{$0.panelID=="side-right"}!.flatToWorld,left=poses.first{$0.panelID=="side-left"}!.flatToWorld
      XCTAssertEqual(front[10],1,accuracy:1e-10);XCTAssertEqual(back[10],-1,accuracy:1e-10);XCTAssertEqual(right[2],1,accuracy:1e-10);XCTAssertEqual(left[2],-1,accuracy:1e-10)
    }
  }
  func testLayoutNeverScalesBlanksAndReportsStockFitContentsAndPrototypeAssumptions()throws {
    let source=PaperConstructionEngine.defaults(recipeID:"paperEnvelope"),net=try source.net(),layout=try net.layout(sheetSize:.init(700,1000),count:3,allowRotation:false)
    XCTAssertEqual(layout.sheetCount,2);XCTAssertEqual(layout.placements.count,3);XCTAssertFalse(layout.hasErrors)
    for placement in layout.placements{XCTAssertEqual(placement.bounds.width,net.size.x);XCTAssertEqual(placement.bounds.height,net.size.y);XCTAssertGreaterThanOrEqual(placement.origin.x,10);XCTAssertGreaterThanOrEqual(placement.origin.y,10);XCTAssertLessThanOrEqual(placement.bounds.x+placement.bounds.width,690);XCTAssertLessThanOrEqual(placement.bounds.y+placement.bounds.height,990)}
    XCTAssertTrue(try net.layout(sheetSize:.init(210,297)).hasErrors)
    XCTAssertFalse(try source.preflight(contents:.init(width:203.2,height:254,depth:5.6)).hasErrors);XCTAssertTrue(try source.preflight(contents:.init(width:300,height:254,depth:5.6)).hasErrors)
    XCTAssertTrue(try source.preflight().issues.contains{$0.code=="unverified-stock"});XCTAssertThrowsError(try net.layout(sheetSize:.init(.nan,1000)))
  }
  func testParameterChangesPreserveArtworkCoordinatesAndInsideSourceWhileFlaggingReviewAndUndo()throws {
    let engine=try fixture(),id=engine.project!.objects[0].id;let art=Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:20,y:80,text:"Physical type",fontSize:12)])
    try engine.edit("Artwork"){p in p.objects[0].artwork=art}
    _ = try engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString]);let sourceID=engine.project!.objects[0].paperConstruction!.insideArtworkSourceID!,inside=engine.project!.objects.first{$0.id==sourceID}!,before=engine.project!
    _ = try engine.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":["width":232]])
    let changed=engine.project!.objects[0];XCTAssertEqual(changed.paperConstruction!.dimensions.width,232);XCTAssertEqual(changed.artwork,art);XCTAssertTrue(changed.paperConstruction!.artworkReviewRequired);XCTAssertEqual(engine.project!.objects.first{$0.id==sourceID},inside)
    engine.undo();XCTAssertEqual(engine.project,before)
    _ = try engine.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":["fold":35]])
    XCTAssertFalse(engine.project!.objects[0].paperConstruction!.artworkReviewRequired)
  }
  func testInsideArtworkCreationIsOneUndoIdempotentLinkedAndResolvesSharedSwatches()throws {
    let engine=try fixture(),id=engine.project!.objects[0].id,before=engine.project!,undo=engine.undoStack.count
    _ = try engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString]);XCTAssertEqual(engine.undoStack.count,undo+1)
    let sourceID=engine.project!.objects[0].paperConstruction!.insideArtworkSourceID!;_ = try engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString]);XCTAssertEqual(engine.undoStack.count,undo+1)
    var p=engine.project!,swatch=ArtworkSwatch(name:"Shared ink",color:"#123456"),element=ArtworkElement(kind:"rectangle",x:10,y:20,color:"#FFFFFF");element.fillSwatchID=swatch.id;p.swatches=[swatch];let i=p.objects.firstIndex{$0.id==sourceID}!;p.objects[i].artwork!.elements=[element]
    XCTAssertEqual(p.paperArtwork(for:p.objects[0],inside:true)?.elements[0].color,"#123456");swatch.color="#654321";p.swatches=[swatch];XCTAssertEqual(p.paperArtwork(for:p.objects[0],inside:true)?.elements[0].color,"#654321");XCTAssertEqual(p.objects[i].artwork!.elements[0].color,"#FFFFFF")
    engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testExplicitLegacyConversionTranslatesFrontArtWithoutTouchingLinkedSourceAndUndoRestores()throws {
    let engine=try fixture();var p=Project(name:"Legacy source"),sleeve=try p.makeObject(recipeID:"sleeve"),source=try p.makeObject(recipeID:"artboard",parameters:["width":216,"depth":275]);source.artwork = .cyanotype;sleeve.artworkSourceID=source.id;sleeve.artworkFit="actual";p.objects=[sleeve,source];engine.project=p;let before=p,oldArt=p.surfaceArtwork(sleeve,keepingSwatchReferences:true)!
    _ = try engine.call("form_paper",arguments:["command":"convert","object_id":sleeve.id.uuidString]);let converted=engine.project!.objects[0],front=try converted.paperConstruction!.net().panels.first{$0.id=="front"}!.bounds
    XCTAssertEqual(converted.recipeID,"paperEnvelope");XCTAssertNil(converted.artworkSourceID);XCTAssertEqual(engine.project!.objects[1],source);XCTAssertEqual(converted.artwork!.elements.filter{oldArt.elements.map(\.id).contains($0.id)}.map(\.fontSize),oldArt.elements.map(\.fontSize));let migrated=try XCTUnwrap(converted.artwork!.elements.first{$0.id==oldArt.elements[0].id});XCTAssertEqual(migrated.affine!.ty,front.y,accuracy:1e-8);XCTAssertEqual(migrated.affine!.a,1);XCTAssertEqual(converted.artwork!.backgroundOpacity,0);XCTAssertEqual(converted.artwork!.elements.first?.width,216);XCTAssertTrue(converted.paperConstruction!.artworkReviewRequired)
    engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testSourcePersistenceSchema53AndHistoricalSleeveRemainIndependent()throws {
    let engine=try fixture("tuckCarton");try engine.flush();let restored=try engine.repository.load(engine.project!.id)
    XCTAssertEqual(restored.schemaVersion,53);XCTAssertEqual(restored.objects,engine.project!.objects)
    let old=Samples.legacyCyanotype();XCTAssertEqual(old.objects[0].recipeID,"sleeve");XCTAssertNil(old.objects[0].paperConstruction);XCTAssertLessThan(old.minimumSchemaVersion,53)
    let sun=Samples.cyanotype();XCTAssertEqual(sun.objects[0].recipeID,"paperEnvelope");XCTAssertEqual(sun.objects[0].artwork?.backgroundOpacity,0);try sun.validateArtworkLinks()
    let cosmetic=try PaperSamples.cosmetics();XCTAssertEqual(cosmetic.objects[0].recipeID,"tuckCarton");try cosmetic.validateArtworkLinks()
  }
  func testAnnotationsAndInvalidInputsAreAtomicAndReadOnlyCommandsDoNotAddHistory()throws {
    let engine=try fixture(),id=engine.project!.objects[0].id,original=engine.project!,undo=engine.undoStack.count
    for command in ["inspect","preflight","layout"]{_ = try engine.call("form_paper",arguments:["command":command,"object_id":id.uuidString]);XCTAssertTrue(PaperCommands.isReadOnly(["command":command]))};XCTAssertEqual(engine.project,original);XCTAssertEqual(engine.undoStack.count,undo)
    let annotation=PaperAnnotation(text:"Score before gluing",panelID:"front",view:"dieline");_ = try engine.call("form_paper",arguments:["command":"annotations","object_id":id.uuidString,"annotation":try jsonObject(annotation)]);XCTAssertEqual(engine.project!.objects[0].paperConstruction!.annotations,[annotation])
    let orphan=PaperAnnotation(text:"Prior panel note",panelID:"old-panel",edgeID:"old-fold",view:"assembled");_ = try engine.call("form_paper",arguments:["command":"annotations","object_id":id.uuidString,"annotation":try jsonObject(orphan)])
    let annotated=try PaperConstruction.definition(for:engine.project!.objects[0]);XCTAssertTrue(annotated.annotations.contains(orphan));XCTAssertTrue(try annotated.preflight().issues.contains{$0.code=="orphan-panel-annotation"});XCTAssertTrue(try annotated.preflight().issues.contains{$0.code=="orphan-edge-annotation"})
    let valid=engine.project!;for args:[String:Any] in [["parameters":["width":true]],["annotation":["id":UUID().uuidString,"kind":"note","text":"Bad","view":"unknown"]],["stock":["thicknessMM":Double.nan]]]{XCTAssertThrowsError(try engine.call("form_paper",arguments:args.merging(["command":"configure","object_id":id.uuidString]){_,new in new}))};XCTAssertEqual(engine.project,valid)
  }
  func testTopOpeningKeepsBodyAndBottomFixedAndUsesDistinctClosureLayers()throws {
    for recipe in ["paperEnvelope","tuckCarton"]{
      var source=PaperConstructionEngine.defaults(recipeID:recipe);let closed=try source.resolvedPanels();source.openingPercent=100;let open=try source.resolvedPanels()
      for panel in closed{let current=try XCTUnwrap(open.first{$0.panelID==panel.panelID});if panel.panelID.hasPrefix("top-") || panel.panelID.hasPrefix("dust-top-"){XCTAssertNotEqual(panel.flatToWorld,current.flatToWorld)}else{XCTAssertEqual(panel.flatToWorld,current.flatToWorld,"Opening moved fixed panel \(panel.panelID)")}}
      let glue=closed.first{$0.panelID=="glue"}!.flatToWorld,top=closed.first{$0.panelID=="top-tuck"}!.flatToWorld,bottom=closed.first{$0.panelID=="bottom-tuck"}!.flatToWorld
      XCTAssertEqual(abs(top[11]-glue[11]),source.stock.thicknessMM,accuracy:1e-8);XCTAssertEqual(abs(bottom[11]-glue[11]),source.stock.thicknessMM,accuracy:1e-8)
      if recipe=="tuckCarton"{let bridge=closed.first{$0.panelID=="top-bridge"}!.flatToWorld,dust=closed.first{$0.panelID=="dust-top-right"}!.flatToWorld;XCTAssertEqual(abs(bridge[7]-dust[7]),source.stock.thicknessMM,accuracy:1e-8)}
      let openFlat=try source.resolvedPanels(foldPercent:0);source.openingPercent=0;XCTAssertEqual(openFlat,try source.resolvedPanels(foldPercent:0))
      var raw=try XCTUnwrap(jsonObject(source) as? [String:Any]);raw.removeValue(forKey:"openingPercent");let legacy=try JSONDecoder.form.decode(PaperConstruction.self,from:JSONSerialization.data(withJSONObject:raw));XCTAssertEqual(legacy.openingPercent,0)
    }
  }

  func testExistingStudioLibraryGainsPaperPresetWithoutOverwritingCustomMaterials()throws {
    var original=StudioLibrary();original.materials.removeAll{$0.id=="paper-superfine"};original.equipment=[.init("Existing cutter",width:420,height:600,format:"SVG")]
    let migrated=try JSONDecoder.form.decode(StudioLibrary.self,from:JSONEncoder.form.encode(original))
    XCTAssertEqual(migrated.materials.filter{$0.id != "paper-superfine"},original.materials);XCTAssertEqual(migrated.materials.filter{$0.id=="paper-superfine"}.count,1)
    XCTAssertEqual(migrated.equipment,original.equipment);XCTAssertEqual(migrated.printers,original.printers);XCTAssertEqual(migrated.filaments,original.filaments)
    let custom=Material("paper-superfine","Measured custom white","Paper","#EEE8E0",roughness:0.72,thickness:0.61);original.materials.append(custom)
    let preserved=try JSONDecoder.form.decode(StudioLibrary.self,from:JSONEncoder.form.encode(original))
    XCTAssertEqual(preserved,original);XCTAssertEqual(preserved.materials.first{$0.id=="paper-superfine"},custom)
  }

  func testLoadedPaperSourceRejectsMixedRepresentationsAndMismatchedRecipeOrKind()throws {
    let engine=try fixture(),project=engine.project!;try engine.flush()
    let package=engine.repository.url(for:project.id),manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:package.appendingPathComponent("Manifest.json"))) as? [String:Any]),references=try XCTUnwrap(manifest["objects"] as? [[String:Any]]),file=try XCTUnwrap(references.first?["file"] as? String),objectURL=package.appendingPathComponent("Objects").appendingPathComponent(file),original=try XCTUnwrap(jsonObject(project.objects[0]) as? [String:Any])
    var mismatched=original;mismatched["recipeID"]="box"
    var wrongKind=original,definition=try XCTUnwrap(wrongKind["paperConstruction"] as? [String:Any]);definition["kind"]="straightTuckCarton";wrongKind["paperConstruction"]=definition
    var mixedCAD=original;mixedCAD["cadModel"]=try jsonObject(CADModelExamples.enclosure())
    var mixedTextile=original;let textile=try XCTUnwrap(Samples.flightJacket().objects.first?.textile);mixedTextile["textile"]=try jsonObject(textile)
    var p=Project(name:"Cloth declaration"),cloth=try p.makeObject(recipeID:"clothPanel"),mixedCloth=original;mixedCloth["cloth"]=try jsonObject(try XCTUnwrap(cloth.cloth))
    for invalid in [mismatched,wrongKind,mixedCAD,mixedTextile,mixedCloth]{try JSONSerialization.data(withJSONObject:invalid).write(to:objectURL);XCTAssertThrowsError(try engine.repository.load(project.id)){error in XCTAssertTrue(error.localizedDescription.contains("Paper construction"))}}
    try JSONSerialization.data(withJSONObject:original).write(to:objectURL);XCTAssertEqual(try engine.repository.load(project.id).objects,project.objects)
  }

}
