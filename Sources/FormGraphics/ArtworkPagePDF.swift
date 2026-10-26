import AppKit
import FormCore

/// Explicit physical-page PDF path. Legacy artwork/publication exports are separate.
@MainActor public enum ArtworkPagePDF {
  public static let maximumAssets=128,maximumAssetBytes=32_000_000,maximumTotalAssetBytes=128_000_000
  public static func pdf(_ artwork:Artwork,geometry g:ArtworkPageGeometry,assets:URL,dpi:Double=300,referenceGuides:Bool=false,outlineText:Bool=false,title:String="Physical artwork page")throws->Data {
    guard dpi.isFinite,(36...1200).contains(dpi),artwork.elements.count<=5000 else{throw FormError.invalid("Choose 36–1200 DPI for bounded PDF appearance effects and at most 5000 source elements.")}
    guard !artwork.requiresInkOutput else{throw FormError.invalid("Declared production inks need an explicit appearance preview; this page workflow does not implement plates or named-ink page output.")}
    _ = try ArtworkPageSetup.sourceWorkload(artwork)
    let tree=ArtworkRenderTree(artwork,assets:assets,production:true,excluding:[])
    let names=Set(artwork.elements.filter{$0.kind=="image" && tree.displayed($0)}.compactMap(\.asset))
    guard names.count<=maximumAssets else{throw FormError.invalid("Physical page PDF supports at most 128 unique image assets.")}
    var total=0
    for name in names {
      guard !name.contains("/"),name != ".",name != ".." else{throw FormError.invalid("Use page image assets from the project Assets folder.")}
      let info=try assets.appendingPathComponent(name).resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
      guard info.isRegularFile==true,info.isSymbolicLink != true,let bytes=info.fileSize,bytes>0,bytes<=maximumAssetBytes,bytes<=maximumTotalAssetBytes-total else{throw FormError.invalid("Physical page image assets must be regular files up to 32 MB each and 128 MB in aggregate.")};total+=bytes
    }
    try ArtworkRenderer.validateAppearanceOutput(artwork,assets:assets,pixelsPerMM:dpi/25.4)
    var art=try BooleanGeometry.materialized(artwork)
    if outlineText {let ids=Set(art.elements.filter{$0.kind=="text" && $0.hidden != true}.map(\.id));if !ids.isEmpty {art=try ArtworkOutlines.convert(art,ids:ids,mode:"text",resolvedPaint:art).artwork}}
    let result=NSMutableData(),factor=ArtworkPageGeometry.pointsPerMM
    func cg(_ r:Rect2)->CGRect {.init(x:r.x*factor,y:r.y*factor,width:r.width*factor,height:r.height*factor)}
    func box(_ r:Rect2)->Data {var r=cg(r);return Data(bytes:&r,count:MemoryLayout<CGRect>.size)}
    var media=cg(g.mediaMm)
    guard let consumer=CGDataConsumer(data:result),let context=CGContext(consumer:consumer,mediaBox:&media,[kCGPDFContextTitle:title] as CFDictionary) else{throw FormError.invalid("Could not create the physical page PDF.")}
    context.beginPDFPage([kCGPDFContextMediaBox:box(g.mediaMm),kCGPDFContextCropBox:box(g.mediaMm),kCGPDFContextTrimBox:box(g.trimMm),kCGPDFContextBleedBox:box(g.bleedMm)] as CFDictionary)
    context.translateBy(x:0,y:media.height);context.scaleBy(x:factor,y:-factor)
    context.saveGState();let bleed=g.bleedMm
    context.clip(to:.init(x:bleed.x,y:bleed.y,width:bleed.width,height:bleed.height))
    context.setFillColor(FormColor.color(art.background).withAlphaComponent(art.backgroundOpacity ?? 1).cgColor)
    context.fill(.init(x:bleed.x,y:bleed.y,width:bleed.width,height:bleed.height))
    context.translateBy(x:g.drawingOriginMm.x,y:g.drawingOriginMm.y)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    ArtworkRenderer.draw(art,width:g.trimMm.width,height:g.trimMm.height,assets:assets,effectScale:dpi/25.4,unbounded:true)
    NSGraphicsContext.restoreGraphicsState();context.restoreGState()
    context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(ArtworkPageGeometry.markStrokeMm);context.setLineCap(.butt)
    for mark in g.marks {context.move(to:.init(x:mark.start.x,y:mark.start.y));context.addLine(to:.init(x:mark.end.x,y:mark.end.y));context.strokePath()}
    if referenceGuides {
      context.setLineWidth(0.12);context.setLineDash(phase:0,lengths:[1,1])
      var guides=[(g.trimMm,"#344F72"),(g.bleedMm,"#C35339")]
      if let safe=g.safeMm {guides.append((safe,"#248568"))}
      for (rect,color) in guides {context.setStrokeColor(FormColor.color(color).cgColor);context.stroke(.init(x:rect.x,y:rect.y,width:rect.width,height:rect.height))}
    }
    context.endPDFPage();context.closePDF()
    if !referenceGuides,let reference=art.outputColorProfile {return try ProfiledPDF.convert(result as Data,profile:ICCOutputProfile(reference:reference,assets:assets),title:title)}
    return result as Data
  }
}
