import AppKit
import CoreGraphics
import FormCore
import ImageIO

/// Bounded decoder exposure for portable assets, before an editor handoff.
@MainActor public enum ArtworkTransferPreflight {
  public struct Report:Sendable {public var rasterPixels=0,vectorElements=0,opaqueProvenance=[String]();public init(){}}
  public static func validate(_ bundle:ArtworkTransferBundle)throws->Report {
    try bundle.validate()
    let arts=[bundle.metadata.artwork]+bundle.metadata.components.map(\.artwork)
    let rendered=Set(arts.flatMap{$0.elements.filter{$0.kind=="image"}.compactMap(\.asset)})
    var report=Report()
    for asset in bundle.metadata.assets {
      let data=bundle.blobs[asset.sourceName]!,ext=URL(fileURLWithPath:asset.sourceName).pathExtension.lowercased()
      if ext=="icc" {guard !rendered.contains(asset.sourceName) else{throw FormError.invalid("An ICC profile cannot be used as an image asset.")};continue}
      if !rendered.contains(asset.sourceName) {report.opaqueProvenance.append(asset.sourceName);continue}
      if ext=="svg" {try svg(data,&report)}
      else if ext=="pdf" {try pdf(data,&report)}
      else {try raster(data,&report)}
    }
    return report
  }
  private static func raster(_ data:Data,_ report:inout Report)throws {
    guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary) else{throw FormError.invalid("A portable raster asset is unreadable.")}
    let frames=CGImageSourceGetCount(source)
    guard (1...32).contains(frames) else{throw FormError.invalid("Portable raster assets support 1–32 bounded frames.")}
    for index in 0..<frames {
      guard let props=CGImageSourceCopyPropertiesAtIndex(source,index,[kCGImageSourceShouldCache:false] as CFDictionary) as? [CFString:Any],
        let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,
        width>0,height>0,width<=8192,height<=8192,width<=16_000_000/height,
        width*height<=32_000_000-report.rasterPixels else{throw FormError.invalid("Decoded transfer images exceed 8192 pixels/edge, 16 megapixels/frame or 32 megapixels total.")}
      report.rasterPixels+=width*height
      guard CGImageSourceCreateThumbnailAtIndex(source,index,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:128,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) != nil else{throw FormError.invalid("A portable raster frame cannot be decoded.")}
    }
  }
  private static func svg(_ data:Data,_ report:inout Report)throws {
    guard data.count<=2*1024*1024 else{throw FormError.invalid("Direct SVG image references are limited to 2 MiB in the portable decoder profile.")}
    let doc=try SVGDocument.read(data)
    let tags:Set<String>=["svg","g","defs","path","rect","circle","ellipse","line","polygon","polyline","clippath","lineargradient","radialgradient","stop","title","desc"]
    let attrs:Set<String>=["id","xmlns","version","width","height","viewbox","preserveaspectratio","x","y","x1","y1","x2","y2","cx","cy","r","rx","ry","d","points","transform","fill","fill-opacity","fill-rule","stroke","stroke-width","stroke-opacity","stroke-linecap","stroke-linejoin","stroke-miterlimit","stroke-dasharray","stroke-dashoffset","opacity","clip-path","clip-rule","clippathunits","gradientunits","gradienttransform","spreadmethod","offset","stop-color","stop-opacity","style"]
    var pending=[doc.root!],nodes=0,pathBytes=0
    while let node=pending.popLast() {
      nodes+=1;guard nodes<=4096,tags.contains(node.name) else{throw FormError.invalid("Direct portable SVG references support bounded plain paths, shapes, gradients and geometric masks. Text, images, use, filters and active/external content require editable SVG import first.")}
      for (raw,value) in node.attributes {
        let key=raw.lowercased()
        guard attrs.contains(key),value.utf8.count<=200_000 else{throw FormError.invalid("Unsupported portable SVG attribute: \(raw).")}
        if key=="xmlns" {guard value=="http://www.w3.org/2000/svg" else{throw FormError.invalid("Unsupported SVG namespace.")};continue}
        guard value.unicodeScalars.allSatisfy({$0.value<128}),!value.contains("\\"),!value.contains("@"),(key=="style" || !value.contains(":")),!value.contains("&") else{throw FormError.invalid("External/escaped SVG attribute content is outside the portable profile.")}
        if value.lowercased().contains("url(") {
          let pattern="^url\\(#[A-Za-z_][A-Za-z0-9_.-]*\\)$"
          guard ["fill","stroke","clip-path"].contains(key),value.range(of:pattern,options:.regularExpression) != nil else{throw FormError.invalid("Portable SVG URLs must be direct internal paint/mask references.")}
        }
        if key=="style" {
          let declarations=SVGStyleSheet.declarations(value)
          guard !value.lowercased().contains("url"),!declarations.isEmpty,declarations.keys.allSatisfy({attrs.contains($0) && $0 != "style"}) else{throw FormError.invalid("Unsupported portable SVG inline style.")}
        }
        if key=="d" || key=="points" {pathBytes+=value.utf8.count;guard pathBytes<=200_000 else{throw FormError.invalid("SVG geometry exceeds its portable token budget.")}}
      }
      pending+=node.children
    }
    let parsed=try SVGImporter.read(data)
    guard parsed.issues.isEmpty,parsed.assets.isEmpty else{throw FormError.invalid("The SVG reference requires unsupported/reviewed features. Import it as editable artwork instead of silently changing its appearance.")}
    let count=parsed.artwork.elements.count,nodesCount=parsed.artwork.elements.reduce(0){$0+($1.path?.contours.reduce(0){$0+$1.nodes.count} ?? 0)}
    guard count<=4096,nodesCount<=20000,count<=10000-report.vectorElements else{throw FormError.invalid("Portable SVG geometry exceeds its decoded work budget.")}
    let pixels=Int(ceil(parsed.width*96/25.4))*Int(ceil(parsed.height*96/25.4))
    guard pixels<=16_000_000,pixels<=32_000_000-report.rasterPixels else{throw FormError.invalid("SVG intrinsic viewport exceeds its portable display budget.")}
    report.vectorElements+=count;report.rasterPixels+=pixels
  }
  private static func pdf(_ data:Data,_ report:inout Report)throws {
    // CoreGraphics does not expose bounded stream inflation. Refuse compressed,
    // recursive/active/resource-rich PDFs before passing bytes to its parser.
    guard data.count<=256*1024,data.starts(with:Data("%PDF-".utf8)) else{throw FormError.invalid("Direct portable PDF images currently support flat uncompressed vector pages up to 256 KiB. Preserve complex originals as provenance or use editable SVG/raster artwork.")}
    let bytes=[UInt8](data),delimiters:Set<UInt8>=[0,9,10,12,13,32,40,41,60,62,91,93,123,125,47,37]
    let rejected:Set<String>=["filter","f","encrypt","xobject","objstm","xref","xrefstm","font","pattern","shading","smask","javascript","js","aa","openaction","uri","ef","filespec","launch","richmedia","acroform"]
    var index=0
    while index<bytes.count {
      if bytes[index] != 47 {index+=1;continue};index+=1;var name=[UInt8]()
      while index<bytes.count,!delimiters.contains(bytes[index]) {
        if bytes[index]==35,index+2<bytes.count,let value=UInt8(String(decoding:bytes[index+1...index+2],as:UTF8.self),radix:16) {name.append(value);index+=3}else{name.append(bytes[index]);index+=1}
      }
      guard !rejected.contains(String(decoding:name,as:UTF8.self).lowercased()) else{throw FormError.invalid("Compressed/complex PDF references are outside the bounded portable PDF profile; the original is not rasterized or dropped.")}
    }
    let text=String(decoding:data,as:UTF8.self)
    guard text.range(of:"(^|\\s)BI(\\s|$)",options:.regularExpression)==nil,let provider=CGDataProvider(data:data as CFData),let doc=CGPDFDocument(provider),!doc.isEncrypted,doc.numberOfPages==1,let page=doc.page(at:1) else{throw FormError.invalid("Use a single flat vector PDF page without inline images or encryption.")}
    let box=page.getBoxRect(.mediaBox)
    guard [box.width,box.height].allSatisfy({$0.isFinite && $0>0 && $0<=2834.65}) else{throw FormError.invalid("The portable PDF page must have finite dimensions up to 1000 mm per edge.")}
    let pixels=Int(ceil(box.width*96/72))*Int(ceil(box.height*96/72))
    guard pixels<=16_000_000,pixels<=32_000_000-report.rasterPixels else{throw FormError.invalid("PDF intrinsic viewport exceeds its portable display budget.")}
    report.rasterPixels+=pixels;report.vectorElements+=1
  }
}
