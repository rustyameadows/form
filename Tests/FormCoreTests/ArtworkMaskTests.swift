import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkMaskTests: XCTestCase {
  private let assets = FileManager.default.temporaryDirectory
  private func rectangle(_ x:Double=0,_ y:Double=0,_ width:Double=40,_ height:Double=20,color:String="#FFFFFF",parent:UUID?=nil)->ArtworkElement {
    var e=ArtworkElement(kind:"rectangle",x:x,y:y,width:width,height:height,color:color);e.parentID=parent;return e
  }
  private func bitmap(_ elements:[ArtworkElement],width:Double=40,height:Double=20,assets:URL?=nil)->NSBitmapImageRep {
    var art=Artwork(elements:elements,bleed:0);art.backgroundOpacity=0
    return ArtworkRenderer.image(art,width:width,height:height,assets:assets ?? self.assets,pixelsPerMM:4).representations[0] as! NSBitmapImageRep
  }
  private func raster(topOnly:Bool=false)throws->Data {
    var pixels:[UInt8]=[]
    for y in 0..<4 {for _ in 0..<4 {pixels += !topOnly || y<2 ? [255,255,255,255]:[0,0,0,0]}}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData))
    let image=try XCTUnwrap(CGImage(width:4,height:4,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    return try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
  }
  private func alpha(_ rep:NSBitmapImageRep,_ x:Double,_ y:Double)throws->Double {
    Double(try XCTUnwrap(rep.colorAt(x:Int(x*4),y:Int(y*4))).alphaComponent)
  }
  func testQuartzSoftClipWithTransparencyLayerAppliesOnceToOverlappingPaints()throws {
    let data=Data(repeating:128,count:100),provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
    let mask=try XCTUnwrap(CGImage(width:10,height:10,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:10,
      space:CGColorSpaceCreateDeviceGray(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,
      decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    for isolated in [false,true] {
      let c=try XCTUnwrap(CGContext(data:nil,width:10,height:10,bitsPerComponent:8,bytesPerRow:40,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
      c.clip(to:.init(x:0,y:0,width:10,height:10),mask:mask)
      if isolated {c.beginTransparencyLayer(auxiliaryInfo:nil)}
      c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(.init(x:0,y:0,width:7,height:10))
      c.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));c.fill(.init(x:3,y:0,width:7,height:10))
      if isolated {c.endTransparencyLayer()}
      let bytes=try XCTUnwrap(c.data?.assumingMemoryBound(to:UInt8.self))
      XCTAssertEqual(Double(bytes[(5*10+1)*4+3]),128,accuracy:1)
      XCTAssertEqual(Double(bytes[(5*10+5)*4+3]),isolated ? 128:191,accuracy:1)
    }
  }
  func testCoverageModesKeepAlphaAndLuminanceSemanticsAndPixelOrientation()throws {
    for (mode,expected) in [("alpha",0.5),("luminance",0.5),("luminance-alpha",0.25)] {
      let coverage=try XCTUnwrap(ArtworkMaskRenderer.coverage(mode:mode,bounds:.init(x:10,y:20,width:30,height:20),
        signature:Data(UUID().uuidString.utf8),pixelsPerMM:4) { c in
        c.setFillColor(CGColor(red:1,green:1,blue:1,alpha:0.5));c.fill(.init(x:10,y:20,width:30,height:8))
      })
      XCTAssertEqual(coverage.sample(atParentPoint:.init(x:20,y:24)),expected,accuracy:0.01)
      XCTAssertEqual(coverage.sample(atParentPoint:.init(x:20,y:35)),0)
      XCTAssertEqual(coverage.sample(atParentPoint:.init(x:0,y:0)),0)
      let c=try XCTUnwrap(CGContext(data:nil,width:160,height:160,bitsPerComponent:8,bytesPerRow:640,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
      c.translateBy(x:0,y:160);c.scaleBy(x:4,y:-4)
      XCTAssertTrue(ArtworkMaskRenderer.install(coverage,context:c))
      c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(.init(x:0,y:0,width:40,height:40))
      let rep=NSBitmapImageRep(cgImage:try XCTUnwrap(c.makeImage()))
      XCTAssertEqual(try alpha(rep,20,24),expected,accuracy:0.01)
      XCTAssertEqual(try alpha(rep,20,35),0)
    }
    let red=try XCTUnwrap(ArtworkMaskRenderer.coverage(mode:"luminance",bounds:.init(x:0,y:0,width:10,height:10),
      signature:Data("red-luminance".utf8),pixelsPerMM:1) { c in
      c.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[1,0,0,1])!)
      c.fill(.init(x:0,y:0,width:10,height:10))
    })
    XCTAssertEqual(red.sample(atParentPoint:.init(x:5,y:5)),0.2126,accuracy:0.005)
  }
  func testEditableGroupMaskClipsOverlappingChildrenOnceAndRetainsHiddenRootChildren()throws {
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);mask.hidden=true;mask.opacity=0.5
    let source=rectangle(parent:mask.id)
    var content=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);content.clipID=mask.id;content.clipMode="alpha"
    let a=rectangle(0,0,28,20,color:"#FF0000",parent:content.id),b=rectangle(12,0,28,20,color:"#0000FF",parent:content.id)
    let art=Artwork(elements:[mask,source,content,a,b]);try validateArtwork(art)
    XCTAssertTrue(art.renderDefinition.elements.contains{$0.id==source.id})
    let rep=bitmap(art.elements)
    for x in [4.0,20,36] {XCTAssertEqual(try alpha(rep,x,10),0.5,accuracy:0.015)}
    XCTAssertEqual(art.elements.first{$0.id==mask.id}?.kind,"group")
  }
  func testTransformedCoverageMaskPickingTracksActualPaintAndTransparentHoles()throws {
    var parent=ArtworkElement(kind:"group",x:12,y:8,width:40,height:20);parent.affine = .init(a:1,b:0.25,c:0.2,d:1)
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);mask.parentID=parent.id;mask.hidden=true
    let left=rectangle(0,0,12,20,parent:mask.id),right=rectangle(28,0,12,20,parent:mask.id)
    var target=rectangle(color:"#FF0000",parent:parent.id);target.clipID=mask.id;target.clipMode="alpha"
    let art=Artwork(elements:[parent,mask,left,right,target]);try validateArtwork(art)
    let picker=ArtworkHitTesting.Picker(in:art,scope:parent.id,assets:assets)
    func point(_ x:Double)->CGPoint {let p=art.worldTransform(parent).apply(.init(x,10));return .init(x:p.x,y:p.y)}
    XCTAssertEqual(picker.hit(at:point(5))?.id,target.id)
    XCTAssertNil(picker.hit(at:point(20),tolerance:3))
    XCTAssertEqual(picker.hit(at:point(35))?.id,target.id)
    XCTAssertEqual(ArtworkHitTesting.layers(at:point(20),in:art,assets:assets),[])
  }
  func testProximityDoesNotResurrectInkOutsideSoftMaskAndZeroOpacityMaskRejectsHit()throws {
    var mask=rectangle(0,0,10,20);mask.hidden=true
    var invisible=rectangle(10.5,2,10,16,color:"#FF0000");invisible.clipID=mask.id;invisible.clipMode="alpha"
    let art=Artwork(elements:[mask,invisible])
    XCTAssertNil(ArtworkHitTesting.hit(at:.init(x:9,y:10),in:art,tolerance:3,assets:assets))
    mask.opacity=0;invisible.x=0
    XCTAssertNil(ArtworkHitTesting.hit(at:.init(x:5,y:10),in:.init(elements:[mask,invisible]),assets:assets))
    XCTAssertEqual(try alpha(bitmap([mask,invisible]),5,10),0)
  }
  func testMaskValidationRejectsCyclesAndUnknownModesButAllowsNativeTextAndImageCoverage()throws {
    var first=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20),second=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20)
    first.clipID=second.id;first.clipMode="alpha";second.clipID=first.id;second.clipMode="luminance"
    XCTAssertThrowsError(try validateArtwork(.init(elements:[first,second])))
    var text=ArtworkElement(kind:"text",x:0,y:0,width:40,height:20,text:"Editable mask",fontSize:18)
    var target=rectangle();target.clipID=text.id;target.clipMode="alpha"
    XCTAssertNoThrow(try validateArtwork(.init(elements:[text,target])))
    target.clipMode=nil;XCTAssertThrowsError(try validateArtwork(.init(elements:[text,target])))
    target.clipMode="mystery";XCTAssertThrowsError(try validateArtwork(.init(elements:[text,target])))
    target.clipMode="alpha";text.hidden=true
    let textPixels=bitmap([text,target]);var ink=0
    for y in 0..<textPixels.pixelsHigh {for x in 0..<textPixels.pixelsWide {
      if (textPixels.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0.5 {ink+=1}
    }}
    XCTAssertGreaterThan(ink,50);XCTAssertLessThan(ink,textPixels.pixelsWide*textPixels.pixelsHigh/2)
    var image=rectangle();image.kind="image";image.asset="mask.png";target.clipID=image.id
    XCTAssertNoThrow(try validateArtwork(.init(elements:[image,target])))
  }
  func testImageAndGradientMaskCoverageRemainEditableAndPickOnlyVisibleAlpha()throws {
    let directory=assets.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    try raster(topOnly:true).write(to:directory.appendingPathComponent("mask.png"))
    var mask=ArtworkElement(kind:"image",x:0,y:0,width:40,height:20);mask.asset="mask.png";mask.hidden=true
    var target=rectangle(color:"#FF0000");target.clipID=mask.id;target.clipMode="alpha"
    let imageArt=Artwork(elements:[mask,target]),rep=bitmap(imageArt.elements,assets:directory)
    XCTAssertEqual(try alpha(rep,20,3),1,accuracy:0.02);XCTAssertEqual(try alpha(rep,20,17),0,accuracy:0.02)
    XCTAssertEqual(ArtworkHitTesting.hit(at:.init(x:20,y:3),in:imageArt,assets:directory)?.id,target.id)
    XCTAssertNil(ArtworkHitTesting.hit(at:.init(x:20,y:17),in:imageArt,assets:directory))
    var gradient=rectangle();gradient.hidden=true
    var clear=GradientStop(1,"#FFFFFF");clear.opacity=0
    gradient.gradient = .init(kind:"linear",start:.init(0,0),end:.init(1,0),stops:[.init(0,"#FFFFFF"),clear])
    target.clipID=gradient.id
    let gradientPixels=bitmap([gradient,target])
    XCTAssertEqual(try alpha(gradientPixels,10,10),0.75,accuracy:0.03)
    XCTAssertEqual(try alpha(gradientPixels,30,10),0.25,accuracy:0.03)
    XCTAssertEqual(mask.kind,"image");XCTAssertNotNil(gradient.gradient)
  }
  func testNativeUngroupAndBooleanCommandsPreserveCombinedMaskSemantics()throws {
    let mask=rectangle()
    var group=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);group.clipID=mask.id;group.clipMode="alpha"
    let first=rectangle(0,0,28,20,parent:group.id),second=rectangle(12,0,28,20,parent:group.id)
    var art=Artwork(elements:[mask,group,first,second]);let before=art
    XCTAssertThrowsError(try ArtworkCommands.apply("ungroup",to:&art,ids:[group.id]));XCTAssertEqual(art,before)
    var a=first,b=second;a.parentID=nil;b.parentID=nil;a.clipID=mask.id;b.clipID=mask.id;a.clipMode="alpha";b.clipMode="alpha"
    b.paintStack=[.init(.init(color:"#CC0000",opacity:0.8))]
    b.effectStack = .init(effects:[.init(kind:"drop-shadow",blur:1)])
    art = .init(elements:[mask,a,b])
    let combined=try BooleanCommands.create("union",artwork:&art,elements:[a.id,b.id])
    XCTAssertEqual(art.elements.first{$0.id==combined}?.clipMode,"alpha")
    XCTAssertEqual(art.elements.first{$0.id==combined}?.paintStack,b.paintStack)
    XCTAssertEqual(art.elements.first{$0.id==combined}?.effectStack,b.effectStack)
    XCTAssertTrue(art.elements.filter{$0.parentID==combined}.allSatisfy{$0.clipID==nil && $0.clipMode==nil})
    let operands=art.elements.filter{$0.parentID==combined}
    try ArtworkCommands.apply("ungroup",to:&art,ids:[combined])
    XCTAssertNil(art.elements.first{$0.id==combined}?.booleanOperation)
    XCTAssertNil(art.elements.first{$0.id==combined}?.paintStack)
    XCTAssertEqual(art.elements.first{$0.id==combined}?.effectStack,b.effectStack)
    XCTAssertEqual(art.elements.filter{$0.parentID==combined},operands)
    XCTAssertEqual(art.elements.first{$0.id==combined}?.clipMode,"alpha")
    XCTAssertEqual(art.elements.first{$0.id==combined}?.clipID,mask.id)
    XCTAssertNoThrow(try validateArtwork(art))
  }
  func testHiddenMaskDependencyEditsInvalidateCachedCoverageWithUnchangedBounds()throws {
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);mask.hidden=true
    var anchor=rectangle(parent:mask.id);anchor.fillOpacity=0
    var ink=rectangle(0,0,10,20,parent:mask.id)
    var target=rectangle(color:"#FF0000");target.clipID=mask.id;target.clipMode="alpha"
    let before=bitmap([mask,anchor,ink,target])
    XCTAssertEqual(try alpha(before,5,10),1,accuracy:0.01);XCTAssertEqual(try alpha(before,25,10),0)
    ink.x=20
    let after=bitmap([mask,anchor,ink,target])
    XCTAssertEqual(try alpha(after,5,10),0);XCTAssertEqual(try alpha(after,25,10),1,accuracy:0.01)
  }
  func testHiddenBooleanMaskAndBooleanUnderHiddenMaskKeepSubtractedHoleForPixelsAndPicking()throws {
    for nested in [false,true] {
      var mask=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20,color:"#FFFFFF");mask.hidden=true
      var boolean=mask
      if nested {boolean.id=UUID();boolean.parentID=mask.id;boolean.hidden=nil}
      boolean.booleanOperation="subtract";boolean.contentSize = .init(40,20)
      let outside=rectangle(parent:boolean.id),hole=rectangle(10,5,20,10,parent:boolean.id)
      if !nested {mask=boolean}
      var target=rectangle(color:"#FF0000");target.clipID=mask.id;target.clipMode="alpha"
      let art=Artwork(elements:(nested ? [mask,boolean]:[mask])+[outside,hole,target]);try validateArtwork(art)
      let rep=bitmap(art.elements)
      XCTAssertEqual(try alpha(rep,5,10),1,accuracy:0.01);XCTAssertEqual(try alpha(rep,20,10),0)
      let picker=ArtworkHitTesting.Picker(in:art,assets:assets)
      XCTAssertEqual(picker.hit(at:.init(x:5,y:10))?.id,target.id)
      XCTAssertNil(picker.hit(at:.init(x:20,y:10)))
    }
  }
  func testBooleanRejectsSoftMaskedDescendantsAtomicallyInsteadOfGeometricApproximation()throws {
    var group=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20)
    var mask=rectangle(parent:group.id);mask.hidden=true;mask.opacity=0.5
    var child=rectangle(parent:group.id);child.clipID=mask.id;child.clipMode="alpha"
    let sibling=rectangle(20,0)
    var art=Artwork(elements:[group,mask,child,sibling]);let before=art
    XCTAssertFalse(BooleanCommands.compatible(group,in:art))
    XCTAssertThrowsError(try BooleanCommands.create("union",artwork:&art,elements:[group.id,sibling.id]));XCTAssertEqual(art,before)
    group.booleanOperation="union";group.contentSize = .init(40,20)
    art.elements[0]=group
    XCTAssertThrowsError(try validateArtwork(art))
    XCTAssertThrowsError(try BooleanGeometry.materialized(art))
  }
  func testCoverageLimitsFailClosedAndCacheKeysIncludeAuthoredSignature()throws {
    XCTAssertThrowsError(try ArtworkMaskRenderer.validate(bounds:.init(x:0,y:0,width:1e9,height:1e9),pixelsPerMM:4))
    XCTAssertNil(ArtworkMaskRenderer.coverage(mode:"alpha",bounds:.init(x:0,y:0,width:CGFloat.infinity,height:1),signature:Data(),pixelsPerMM:1){_ in XCTFail()})
    var builds=0
    func coverage(_ signature:String)throws->ArtworkMaskRenderer.Coverage {
      try XCTUnwrap(ArtworkMaskRenderer.coverage(mode:"alpha",bounds:.init(x:0,y:0,width:8,height:8),signature:Data(signature.utf8),pixelsPerMM:1){c in
        builds+=1;c.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1));c.fill(.init(x:0,y:0,width:8,height:8))
      })
    }
    let key=UUID().uuidString,a=try coverage(key),b=try coverage(key),c=try coverage(key+"-changed")
    XCTAssertTrue(a===b);XCTAssertFalse(a===c);XCTAssertEqual(builds,2)
  }
  func testTransferIncludesCompleteMaskSubtreeAssetsAndNestedMasksWithoutUnrelatedSiblings()throws {
    let bytes=try raster()
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);mask.hidden=true;mask.name="Mask"
    var image=ArtworkElement(kind:"image",x:0,y:0,width:20,height:20);image.asset="mask.png";image.parentID=mask.id;image.name="Image source"
    var inner=rectangle(20,0,20,20,parent:mask.id);inner.name="Inner mask"
    var text=ArtworkElement(kind:"text",x:20,y:0,width:20,height:20,text:"A",fontSize:20);text.parentID=mask.id;text.name="Live text";text.clipID=inner.id;text.clipMode="luminance"
    var target=rectangle(color:"#FF0000");target.clipID=mask.id;target.clipMode="alpha";target.name="Target"
    var unrelated=rectangle(60,0);unrelated.name="Unrelated"
    let art=Artwork(elements:[mask,image,inner,text,target,unrelated]);try validateArtwork(art)
    var project=Project(name:"Mask transfer");let owner=try project.ensureCanvasWorkspace()
    project.objects[try XCTUnwrap(project.objects.firstIndex{$0.id==owner.id})].artwork=art
    let bundle=try ArtworkTransferGraph.capture(project:project,objectID:owner.id,ids:[target.id],readAsset:{name,_ in XCTAssertEqual(name,"mask.png");return bytes})
    XCTAssertEqual(Set(bundle.metadata.artwork.elements.map(\.id)),[mask.id,image.id,inner.id,text.id,target.id])
    XCTAssertEqual(bundle.blobs["mask.png"],bytes)
    let exported=try art.exporting([target.id]).artwork
    XCTAssertTrue(exported.elements.contains{$0.id==image.id});XCTAssertFalse(exported.elements.contains{$0.id==unrelated.id})
    var destination=Project(name:"Destination");let dest=try destination.ensureCanvasWorkspace()
    let plan=try ArtworkTransferGraph.plan(ArtworkTransferBundle.decode(bundle.encoded()),into:destination,objectID:dest.id)
    let pasted=try XCTUnwrap(plan.project.canvasWorkspace?.artwork)
    let pastedTarget=try XCTUnwrap(pasted.elements.first{$0.name=="Target"}),pastedMask=try XCTUnwrap(pasted.elements.first{$0.name=="Mask"})
    XCTAssertEqual(pastedTarget.clipID,pastedMask.id);XCTAssertEqual(pastedTarget.clipMode,"alpha");XCTAssertNotEqual(pastedMask.id,mask.id)
    XCTAssertEqual(pasted.elements.first{$0.name=="Live text"}?.clipMode,"luminance")
    XCTAssertEqual(pasted.elements.first{$0.name=="Live text"}?.text,"A")
    XCTAssertEqual(plan.assetWrites.values.first,bytes)
    XCTAssertEqual(try JSONDecoder.form.decode(Artwork.self,from:JSONEncoder.form.encode(pasted)),pasted)
  }
}
