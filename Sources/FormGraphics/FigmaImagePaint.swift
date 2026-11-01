import CoreGraphics
import FormCore
import Foundation
import ImageIO

extension FigmaSceneBuilder {
  /// The asset is unchanged. The transform maps normalized image coordinates
  /// into normalized element coordinates, shared by vector and live text fills.
  func imagePaintSource(paint:FigmaValue,width:Double,height:Double,id:String)throws->ArtworkPaint? {
    guard let reference=paint["image"],reference["dataBlob"] != nil else {
      issue(id,"image","Image bytes are absent from this clipboard. No network image was fetched.",severity:"error");return nil
    }
    let bytes=try blob(reference["dataBlob"])
    guard bytes.count<=16*1024*1024,
      let source=CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
      let type=CGImageSourceGetType(source) as String?,
      let ext=["public.png":"png","public.jpeg":"jpg","public.tiff":"tiff","org.webmproject.webp":"webp","public.heic":"heic"][type],
      let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let rawW=props[kCGImagePropertyPixelWidth] as? Int,let rawH=props[kCGImagePropertyPixelHeight] as? Int,
      rawW>0,rawH>0,rawW<=8192,rawH<=8192,rawW<=16_000_000/rawH else {
      throw FigmaClipboardError.invalid("Unsupported, malformed or excessive embedded image.")
    }
    let orientation=props[kCGImagePropertyOrientation] as? Int ?? 1,swap=(5...8).contains(orientation)
    let pw=Double(swap ? rawH:rawW),ph=Double(swap ? rawW:rawH)
    let name="image-"+ArtworkTransferBundle.digest(bytes)+"."+ext
    if assets[name] == nil {
      guard assets.count<128,rasterPixels<=32_000_000-rawW*rawH,
        bytes.count<=64*1024*1024-assets.values.reduce(0,{$0+$1.count}) else{throw FigmaClipboardError.limit("embedded image resources")}
      rasterPixels += rawW*rawH;assets[name]=bytes
    }
    let opacity=try number(paint["opacity"],1)
    guard (0...1).contains(opacity) else{throw FigmaClipboardError.invalid("Image opacity is outside 0–1.")}
    let mode=paint["imageScaleMode"]?.stringValue ?? "FILL"
    guard paint["imageScaleMode"] == nil || paint["imageScaleMode"]?.stringValue != nil,
      ["FILL","FIT","STRETCH","TILE"].contains(mode) else{
      issue(id,"image","Unsupported image scale mode.",severity:"error");return nil
    }
    var mapping:Affine2
    if mode == "STRETCH" {
      guard let inverse=try matrix(paint["transform"]).inverse else{throw FigmaClipboardError.invalid("Image crop transform is singular.")}
      mapping=inverse
    }else {
      let angle=try number(paint["rotation"]),radians=angle * .pi/180
      let rw=abs(cos(radians))*pw+abs(sin(radians))*ph,rh=abs(sin(radians))*pw+abs(cos(radians))*ph
      let turned=Affine2.translation(rw/2,rh/2).followed(by:.rotation(angle)).followed(by:.translation(-pw/2,-ph/2)).followed(by:.scale(pw,ph))
      if mode == "TILE" {
        let tile=try number(paint["scale"],1)
        guard tile>0,tile<=100000 else{throw FigmaClipboardError.invalid("Image tile scale must be positive and bounded.")}
        mapping=Affine2.scale(1/width,1/height).followed(by:.scale(tile*scale,tile*scale)).followed(by:turned)
      }else{
        let fit=mode == "FIT" ? min(width/rw,height/rh):max(width/rw,height/rh)
        mapping=Affine2.scale(1/width,1/height).followed(by:.translation((width-rw*fit)/2,(height-rh*fit)/2)).followed(by:.scale(fit,fit)).followed(by:turned)
      }
    }
    for key in ["paintFilter","filterColorAdjust"] {
      if let filter=paint[key]?.objectValue {
        var active=false
        for value in filter.values {if try number(value) != 0 {active=true}}
        if active{issue(id,"image","Nonzero Figma image adjustments need calibrated filter mapping; original settings and image bytes are retained.",severity:"error")}
      }
    }
    return .init(kind:"image",opacity:opacity,blendMode:blend(paint["blendMode"],id:id),asset:name,imageTransform:mapping,imageRepeat:mode == "TILE" ? true:nil)
  }

  func imagePaint(_ paint:FigmaValue,geometry:ArtworkElement,id:String)throws->[ArtworkElement] {
    guard let source=try imagePaintSource(paint:paint,width:geometry.width,height:geometry.height,id:id) else{return []}
    if source.imageRepeat == true {
      var shape=geometry;shape.id=UUID();shape.paintStack=[.init(source)];shape.fillOpacity=nil;shape.blendMode=nil
      return [shape]
    }
    var image=ArtworkElement(kind:"image",x:0,y:0,width:geometry.width,height:geometry.height,asset:source.asset)
    image.opacity=source.opacity;image.blendMode=source.blendMode;image.imageAdjustments=source.imageAdjustments
    image.affine=Affine2.scale(geometry.width,geometry.height).followed(by:source.imageTransform ?? .init()).followed(by:.scale(1/geometry.width,1/geometry.height))
    var mask=geometry;mask.id=UUID();mask.hidden=true;mask.name="Image fill boundary"
    mask.stroke=nil;mask.gradient=nil;mask.fillOpacity=1;mask.fillEnabled=true;mask.blendMode=nil;mask.paintStack=nil
    image.clipID=mask.id
    return [mask,image]
  }
}
