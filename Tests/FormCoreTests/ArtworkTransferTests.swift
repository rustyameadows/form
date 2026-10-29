import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import FormCore
@testable import FormGraphics

final class ArtworkTransferTests:XCTestCase {
  private func project(_ name:String="Source")throws->(Project,UUID) {var p=Project(name:name);let o=try p.ensureCanvasWorkspace();return(p,o.id)}
  private func capture(_ p:Project,_ owner:UUID,_ ids:Set<UUID>,blobs:[String:Data]=[:],limits:ArtworkTransferLimits = .init())throws->ArtworkTransferBundle {
    try ArtworkTransferGraph.capture(project:p,objectID:owner,ids:ids,readAsset:{name,cap in guard let data=blobs[name],data.count<=cap else{throw FormError.invalid("Missing/oversize test asset")};return data},limits:limits)
  }
  private func install(_ art:Artwork,in p:inout Project,_ owner:UUID)throws {try p.setArtwork(art,for:owner,recordingStyleOverrides:false)}
  private func roundtrip(_ b:ArtworkTransferBundle)throws->ArtworkTransferBundle {try .decode(b.encoded())}
  func testParentShellSiblingMaskAndScopedPasteKeepWorldGeometryAndLiteralUUID()throws {
    var(p,id)=try project();var group=ArtworkElement(kind:"group",x:12,y:21,width:150,height:80);group.contentSize = .init(100,100);group.rotation=33
    var mask=ArtworkElement(kind:"ellipse",x:2,y:3,width:80,height:60);mask.parentID=group.id
    var leaf=ArtworkElement(kind:"rectangle",x:5,y:6,width:20,height:30);leaf.parentID=group.id;leaf.clipID=mask.id;leaf.name=group.id.uuidString;leaf.text=group.id.uuidString
    var unrelated=ArtworkElement(kind:"image",x:400,y:400,asset:"not-copied.png");unrelated.hidden=true
    let art=Artwork(elements:[group,mask,leaf,unrelated]);try install(art,in:&p,id)
    let original=try JSONEncoder.form.encode(p),bundle=try roundtrip(capture(p,id,[leaf.id]))
    XCTAssertEqual(bundle.metadata.artwork.elements.count,3);XCTAssertEqual(try JSONEncoder.form.encode(p),original)
    var(dest,target)=try project("Destination");var scope=ArtworkElement(kind:"group",x:20,y:30,width:200,height:100);scope.rotation = -17;scope.contentSize = .init(100,100);try install(Artwork(elements:[scope]),in:&dest,target)
    let plan=try ArtworkTransferGraph.plan(bundle,into:dest,objectID:target,scopeID:scope.id),result=plan.project.canvasWorkspace!.artwork!,copied=try XCTUnwrap(result.elements.first{$0.id==plan.elementMaps[id]![leaf.id]})
    var navigation=dest;navigation.camera.azimuth+=0.4;XCTAssertEqual(try plan.applying(to:navigation).camera,navigation.camera);var edited=dest;edited.name="Concurrent edit";XCTAssertThrowsError(try plan.applying(to:edited))
    XCTAssertEqual(copied.text,group.id.uuidString);XCTAssertEqual(copied.name,group.id.uuidString);XCTAssertNotEqual(copied.id,leaf.id);XCTAssertNotNil(copied.clipID)
    for point in [Point2(),Point2(20,30),Point2(9,8)] {let a=art.worldTransform(leaf).apply(point),b=result.worldTransform(copied).apply(point);XCTAssertEqual(b.x,a.x+10,accuracy:1e-8);XCTAssertEqual(b.y,a.y+10,accuracy:1e-8)}
  }
  func testContinuedListsStayEditableAndPartialListRejectsWithoutBaking()throws {
    var(p,id)=try project();let list=UUID();var a=ArtworkElement(kind:"text",x:0,y:0,text:"First"),b=ArtworkElement(kind:"text",x:0,y:50,text:"Second")
    a.listItems=[.init(location:0,listID:list,marker:.decimal)];b.listItems=[.init(location:0,listID:list,marker:.decimal)];try install(Artwork(elements:[a,b]),in:&p,id)
    XCTAssertThrowsError(try capture(p,id,[b.id]));let bundle=try roundtrip(capture(p,id,[a.id,b.id]));let(dest,target)=try project("Dest"),plan=try ArtworkTransferGraph.plan(bundle,into:dest,objectID:target),items=plan.project.canvasWorkspace!.artwork!.elements.flatMap{$0.listItems ?? []}
    XCTAssertEqual(Set(items.map(\.listID)).count,1);XCTAssertNotEqual(items[0].listID,list);XCTAssertTrue(items.allSatisfy{$0.restart==nil && $0.resolvedNumber==nil});XCTAssertEqual(items.map(\.marker),[.decimal,.decimal])
  }
  func testRichGlyphStylesSwatchesAndOpticalSourceHaveTypedIndependentIdentities()throws {
    var(p,id)=try project();var typography=Typography();typography.features=[3:3];typography.variations=[123:615];typography.opticalSizing = .init(.automatic)
    let style=ArtworkTextStyle(name:"Display",typography:typography,fontSize:18),swatch=ArtworkSwatch(name:"Flight ink",color:"#226699");p.textStyles=[style];p.swatches=[swatch]
    var e=ArtworkElement(kind:"text",x:0,y:0,text:"A",color:swatch.color,fontSize:18);e.typography=typography;e.textStyle = .init(styleID:style.id);e.fillSwatchID=swatch.id;e.glyphOverrides=[.init(location:0,sourceText:"A",glyph:.init(fontName:"Helvetica",glyphID:36,glyphName:"A",fontSignature:String(repeating:"a",count:64)))];e.name=swatch.id.uuidString
    try install(Artwork(elements:[e]),in:&p,id);let bundle=try roundtrip(capture(p,id,[e.id]));let(dest,target)=try project("Dest"),plan=try ArtworkTransferGraph.plan(bundle,into:dest,objectID:target),copy=plan.project.canvasWorkspace!.artwork!.elements[0]
    XCTAssertEqual(copy.typography,typography);XCTAssertEqual(copy.fontSize,e.fontSize);XCTAssertEqual(copy.glyphOverrides?.first?.glyph,e.glyphOverrides?.first?.glyph);XCTAssertNotEqual(copy.glyphOverrides?.first?.id,e.glyphOverrides?.first?.id);XCTAssertNotEqual(copy.textStyle?.styleID,style.id);XCTAssertNotEqual(copy.fillSwatchID,swatch.id);XCTAssertEqual(copy.name,e.name)
    let same=try ArtworkTransferGraph.plan(bundle,into:p,objectID:id);XCTAssertEqual(same.project.textStyles,p.textStyles);XCTAssertEqual(same.project.swatches,p.swatches)
    var conflict=dest;conflict.textStyles=[style];XCTAssertThrowsError(try ArtworkTransferGraph.plan(bundle,into:conflict,objectID:target));XCTAssertEqual(conflict.textStyles,[style])
  }
  func testNestedComponentsWithCollidingLocalIDsRemapOverrideWithinOwner()throws {
    var(p,id)=try project();let sharedID=UUID();var sources=[ProductObject]()
    for name in ["One","Two"] {var e=ArtworkElement(kind:"text",x:0,y:0,text:name);e.id=sharedID;var object=try p.makeObject(recipeID:"artboard",name:name,parameters:["width":80,"depth":60]);object.componentDefinition=true;object.artwork=Artwork(elements:[e]);sources.append(object)}
    p.objects += sources
    var first=ArtworkElement(kind:"group",x:0,y:0,width:80,height:60),second=first;second.id=UUID();second.x=100
    first.contentSize = .init(80,60);second.contentSize = .init(80,60);first.component = .init(sourceObjectID:sources[0].id);first.component!.overrides=[.init(elementID:sharedID,text:"Edited one")];second.component = .init(sourceObjectID:sources[1].id);second.component!.overrides=[.init(elementID:sharedID,text:"Edited two")]
    try install(Artwork(elements:[first,second]),in:&p,id);let bundle=try roundtrip(capture(p,id,[first.id,second.id]));let(dest,target)=try project("Dest"),plan=try ArtworkTransferGraph.plan(bundle,into:dest,objectID:target)
    XCTAssertEqual(plan.addedComponentIDs.count,2)
    let values=plan.project.canvasWorkspace!.artwork!.elements
    XCTAssertNotEqual(values[0].component!.overrides![0].elementID,values[1].component!.overrides![0].elementID)
    let rendered=try plan.project.resolvingComponents(in:plan.project.canvasWorkspace!.artwork!);XCTAssertEqual(Set(rendered.elements.filter{$0.kind=="text"}.map(\.text)),["Edited one","Edited two"])
    let same=try ArtworkTransferGraph.plan(bundle,into:p,objectID:id);XCTAssertTrue(same.addedComponentIDs.isEmpty)
    var corrupt=bundle;corrupt.metadata.components[0].artwork.elements[0].component = .init(sourceObjectID:corrupt.metadata.components[0].id);XCTAssertThrowsError(try corrupt.encoded())
  }
  func testExactImageAndICCBytesRemainPortableAfterSourceDeletionAndOneUndoReopen()throws {
    var(p,id)=try project();let image=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!,profile=CGColorSpace(name:CGColorSpace.sRGB)!.copyICCData()! as Data,digest=ArtworkTransferBundle.digest(profile),icc="icc-"+digest+".icc"
    var art=Artwork(elements:[.init(kind:"image",x:2,y:3,asset:"original.png")]);art.outputColorProfile = .init(name:"sRGB source",asset:icc,sha256:digest,model:"RGB");try install(art,in:&p,id)
    let bundle=try roundtrip(capture(p,id,Set(art.elements.map(\.id)),blobs:["original.png":image,icc:profile]));p.objects=[]
    let(dest,target)=try project("Dest"),plan=try ArtworkTransferGraph.plan(bundle,into:dest,objectID:target)
    XCTAssertEqual(plan.assetWrites[icc],profile);let name=plan.project.canvasWorkspace!.artwork!.elements[0].asset!;XCTAssertEqual(plan.assetWrites[name],image);XCTAssertEqual(plan.project.canvasWorkspace!.artwork!.outputColorProfile,art.outputColorProfile)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)};let repo=try ProjectRepository(root:root);try repo.save(dest);let engine=OperationEngine(repository:repo);try engine.open(dest.id);let prior=engine.project;let committed=try ArtworkTransferGraph.plan(bundle,into:XCTUnwrap(prior),objectID:target)
    try engine.edit("Paste portable artwork"){$0=try committed.applying(to:$0)};XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,prior);engine.redo();try engine.flush();let saved=try repo.load(dest.id);XCTAssertEqual(saved.canvasWorkspace!.artwork,committed.project.canvasWorkspace!.artwork)
    var modelConflict=bundle;modelConflict.metadata.artwork.outputColorProfile!.model="CMYK";XCTAssertThrowsError(try modelConflict.encoded())
    var conflict=bundle;conflict.blobs["original.png"]=Data([0]);XCTAssertThrowsError(try conflict.encoded())
    XCTAssertThrowsError(try ArtworkTransferGraph.plan(bundle,into:dest,objectID:target,existingAsset:{_,_ in Data([9])}))
  }
  func testLegacyHiddenSourceRequiresCompleteScopeButUnrelatedHiddenImageDoesNot()throws {
    var(p,id)=try project();var path=ArtworkElement(kind:"path",x:0,y:0);path.path = .init(width:60,height:30,contours:[.init([.init(.init(0,0)),.init(.init(60,0)),.init(.init(60,30)),.init(.init(0,30))])]);var hidden=ArtworkElement(kind:"text",x:0,y:0,text:"Original source");hidden.hidden=true
    try install(Artwork(elements:[hidden,path]),in:&p,id);XCTAssertThrowsError(try capture(p,id,[path.id]));let all=try roundtrip(capture(p,id,[path.id,hidden.id]));XCTAssertEqual(all.metadata.artwork.elements.count,2);XCTAssertEqual(all.metadata.artwork.elements.first?.text,"Original source")
    let ordinary=ArtworkElement(kind:"ellipse",x:0,y:0);try install(Artwork(elements:[hidden,ordinary]),in:&p,id);XCTAssertEqual(try capture(p,id,[ordinary.id]).metadata.artwork.elements.count,1)
  }
  func testEnvelopeTruncationDigestPathsMetadataCountsAndWorkRejectBeforeMutation()throws {
    var(p,id)=try project();let e=ArtworkElement(kind:"rectangle",x:0,y:0);try install(Artwork(elements:[e]),in:&p,id);let b=try capture(p,id,[e.id]),data=try b.encoded(),before=p
    let padded=Data(repeating:0,count:17)+data;XCTAssertEqual(try ArtworkTransferBundle.decode(padded.dropFirst(17)).metadata,b.metadata)
    for value in [Data(),Data(data.prefix(11)),data+Data([0]),Data("PKZIP".utf8)+data] {XCTAssertThrowsError(try ArtworkTransferBundle.decode(value))}
    var bad=data;bad[8]=255;XCTAssertThrowsError(try ArtworkTransferBundle.decode(bad))
    var limits=ArtworkTransferLimits();limits.metadataBytes=16;XCTAssertThrowsError(try ArtworkTransferBundle.decode(data,limits:limits));limits = .init();limits.work=1;XCTAssertThrowsError(try ArtworkTransferBundle.decode(data,limits:limits));limits = .init();limits.elements=0;XCTAssertThrowsError(try b.encoded(limits:limits))
    var duplicate=b;duplicate.metadata.artwork.elements.append(e);XCTAssertThrowsError(try duplicate.encoded());XCTAssertEqual(p,before)
  }
  func testResourceCountsAggregateAssetBudgetsAndNewerSchemaFailClosed()throws {
    var(p,id)=try project();let e=ArtworkElement(kind:"rectangle",x:0,y:0);try install(Artwork(elements:[e]),in:&p,id);var bundle=try capture(p,id,[e.id]);bundle.metadata.sourceSchema=Project.maximumSchemaVersion+1;XCTAssertThrowsError(try bundle.encoded())
    var images=(0..<33).map{ArtworkElement(kind:"image",x:0,y:0,asset:"\($0).png")};try install(Artwork(elements:images),in:&p,id);var reads=0
    XCTAssertThrowsError(try ArtworkTransferGraph.capture(project:p,objectID:id,ids:Set(images.map(\.id)),readAsset:{_,_ in reads+=1;return Data([1])}));XCTAssertEqual(reads,0)
    images=Array(images.prefix(2));try install(Artwork(elements:images),in:&p,id);var limits=ArtworkTransferLimits();limits.individualAssetBytes=16;limits.totalAssetBytes=24
    var caps=[Int]();XCTAssertThrowsError(try ArtworkTransferGraph.capture(project:p,objectID:id,ids:Set(images.map(\.id)),readAsset:{_,cap in caps.append(cap);return Data(repeating:1,count:16)},limits:limits));XCTAssertEqual(caps,[16,8])
    let before=p;var wrong=bundle;wrong.metadata.sourceSchema=43;wrong.metadata.assets=[.init(sourceName:"../image.png",portableName:"image-x.png",sha256:String(repeating:"a",count:64),length:1)];wrong.blobs=["../image.png":Data([1])];XCTAssertThrowsError(try wrong.encoded());XCTAssertEqual(p,before)
    var cyclic=p;cyclic.objects[0].artworkSourceID=cyclic.objects[0].id;XCTAssertThrowsError(try capture(cyclic,id,Set(images.map(\.id))))
  }
  func testStoryAndPartialSeamScopesRejectButCompleteUnboundSeamRemaps()throws {
    var(p,id)=try project();var text=ArtworkElement(kind:"text",x:0,y:0,text:"Story");text.storyFrame = .init(storyID:UUID());p.objects[0].artwork=Artwork(elements:[text]);var reads=0
    XCTAssertThrowsError(try ArtworkTransferGraph.capture(project:p,objectID:id,ids:[text.id],readAsset:{_,_ in reads+=1;return Data([1])}));XCTAssertEqual(reads,0)
    var a=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100),b=ArtworkElement(kind:"rectangle",x:140,y:0,width:100,height:100);a.sewingPiece = .init(name:"Front");b.sewingPiece = .init(name:"Back")
    var art=Artwork(elements:[a,b]);let seam=SewingSeam(name:"Side",first:.init(elementID:a.id,edge:0),second:.init(elementID:b.id,edge:0));art.sewingSeams=[seam];p.objects[0].artwork=art
    XCTAssertThrowsError(try capture(p,id,[a.id]));let bundle=try roundtrip(capture(p,id,[a.id,b.id])),(destination,target)=try project("Dest"),plan=try ArtworkTransferGraph.plan(bundle,into:destination,objectID:target),copy=try XCTUnwrap(plan.project.canvasWorkspace?.artwork?.sewingSeams?.first)
    XCTAssertNotEqual(copy.id,seam.id);XCTAssertEqual(copy.first.elementID,plan.elementMaps[id]![a.id]);XCTAssertEqual(copy.second.elementID,plan.elementMaps[id]![b.id]);XCTAssertEqual(copy.first.edge,0)
    a.sewingPiece!.materialID="untracked-cotton";p.objects[0].artwork=Artwork(elements:[a]);XCTAssertThrowsError(try capture(p,id,[a.id]))
  }

  func testActualNestedComponentClosureAndNestedOverridesStayLinkedToNewSources()throws {
    var(p,id)=try project();let leaf=ArtworkElement(kind:"text",x:0,y:0,text:"Grandchild")
    var child=try p.makeObject(recipeID:"artboard",name:"Child",parameters:["width":80,"depth":60]);child.componentDefinition=true;child.artwork=Artwork(elements:[leaf]);p.objects.append(child)
    var nested=ArtworkElement(kind:"group",x:0,y:0,width:80,height:60);nested.contentSize = .init(80,60);nested.component = .init(sourceObjectID:child.id);nested.component!.overrides=[.init(elementID:leaf.id,text:"Nested edit")]
    var parent=try p.makeObject(recipeID:"artboard",name:"Parent",parameters:["width":80,"depth":60]);parent.componentDefinition=true;parent.artwork=Artwork(elements:[nested]);p.objects.append(parent)
    var instance=ArtworkElement(kind:"group",x:0,y:0,width:80,height:60);instance.contentSize = .init(80,60);instance.component = .init(sourceObjectID:parent.id);try install(Artwork(elements:[instance]),in:&p,id)
    let bundle=try roundtrip(capture(p,id,[instance.id]));XCTAssertEqual(bundle.metadata.components.count,2)
    let(destination,target)=try project("Dest"),plan=try ArtworkTransferGraph.plan(bundle,into:destination,objectID:target)
    XCTAssertEqual(plan.addedComponentIDs.count,2);let resolved=try plan.project.resolvingComponents(in:plan.project.canvasWorkspace!.artwork!)
    XCTAssertEqual(resolved.elements.filter{$0.kind=="text"}.map(\.text),["Nested edit"])
    let importedParent=try XCTUnwrap(plan.project.objects.first{$0.name=="Parent"}),importedChild=try XCTUnwrap(plan.project.objects.first{$0.name=="Child"})
    XCTAssertEqual(importedParent.artwork!.elements[0].component!.sourceObjectID,importedChild.id);XCTAssertNotEqual(importedChild.id,child.id)
  }

  func testPartialNestedBooleanCannotSilentlyDropAnOperandGrandchild()throws {
    var(p,id)=try project();var boolean=ArtworkElement(kind:"group",x:0,y:0,width:200,height:200);boolean.contentSize = .init(200,200);boolean.booleanOperation="union"
    var operand=ArtworkElement(kind:"group",x:0,y:0,width:100,height:100);operand.contentSize = .init(100,100);operand.parentID=boolean.id
    var a=ArtworkElement(kind:"rectangle",x:0,y:0),b=ArtworkElement(kind:"ellipse",x:15,y:15),c=ArtworkElement(kind:"rectangle",x:70,y:20);a.parentID=operand.id;b.parentID=operand.id;c.parentID=boolean.id
    try install(Artwork(elements:[boolean,operand,a,b,c]),in:&p,id)
    XCTAssertThrowsError(try capture(p,id,[a.id,c.id]));XCTAssertEqual(try capture(p,id,[boolean.id]).metadata.artwork.elements.count,5)
  }

}
