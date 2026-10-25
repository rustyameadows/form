import AppKit
import FormCore
import ImageIO
import UniformTypeIdentifiers

public struct DecorationOutputFile {
  public var name:String,role:String,mediaType:String,data:Data
  public init(name:String,role:String,mediaType:String,data:Data) {self.name=name;self.role=role;self.mediaType=mediaType;self.data=data}
}
public struct DecorationOutputBundle {
  public var files:[DecorationOutputFile]
  public var report:[String:Any]
}

@MainActor public enum DecorationOutput {
  public static func generate(_ plan:DecorationGeometry,project:Project,assets:URL,specification:DecorationReviewSpecification?=nil) throws -> DecorationOutputBundle {
    guard plan.canExport else{throw FormError.invalid(plan.issues.filter{$0.severity=="error"}.map(\.message).joined(separator:"\n"))}
    var files:[DecorationOutputFile]=[],report=plan.report
    if plan.options.process == .htv {
      for (index,region) in plan.regions.enumerated() {
        let name=String(format:"Cut-%02d.svg",index+1)
        files.append(.init(name:name,role:"delivery",mediaType:"image/svg+xml",data:Data(try cutSVG(plan,region:region).utf8)))
      }
    } else {
      let image=try rgba(plan),png=try encodePNG(image,width:plan.width,height:plan.height)
      files.append(.init(name:plan.options.colorDelivery == .sRGBRaster ? "Color.png":"Reference-color.png",role:plan.options.colorDelivery == .sRGBRaster ? "delivery":"reference",mediaType:"image/png",data:png))
      report["pixel_width"]=image.width;report["pixel_height"]=image.height
      report["encoded_dpi_x"]=Double(image.width)*25.4/plan.width;report["encoded_dpi_y"]=Double(image.height)*25.4/plan.height
      report["rgba_handoff_scope"]="sRGB appearance for a vendor/RIP; original process/spot declarations remain in the source packet, not the PNG."
      if plan.options.colorDelivery == .profiledProcess {
        var delivery=project
        if plan.options.convertSpotAlternates {
          for i in delivery.swatches?.indices ?? 0..<0 {
            if let ink=delivery.swatches![i].printInk,ink.kind == .spot {
              let v=ink.previewComponents
              delivery.swatches![i].printInk = .init(kind:.processCMYK,components:.init(v[0],v[1],v[2],v[3]),profile:ink.profile)
            }
          }
        }
        var art=Artwork();art.backgroundOpacity=0;art.bleed=0;art.outputColorProfile=plan.source.artwork.outputColorProfile
        for region in plan.regions {
          var element=try VectorGeometry.element(from:plan.deliveryPath(region.path),color:region.color)
          if region.paintKey.hasPrefix("swatch:") {element.fillSwatchID=UUID(uuidString:String(region.paintKey.dropFirst(7)))}
          art.elements.append(element)
        }
        let result=try ProductionInkPDF.export(project:delivery,pages:[.init(name:"DTF process-color handoff",artwork:art,width:plan.width,height:plan.height)],assets:assets,mode:.composite,title:"FORM · DTF process-color handoff")
        files.append(.init(name:"Color-Process.pdf",role:"delivery",mediaType:"application/pdf",data:result.data))
        report["process_pdf_profile"]=result.report["output_profile"]
        report["process_pdf_scope"]="Actual ICCBased process colors; white application and underbase remain vendor/RIP decisions. No named spot/device compatibility claim."
      }
      if plan.options.includeUnderbaseReference {
        files.append(.init(name:"Reference-underbase.svg",role:"reference",mediaType:"image/svg+xml",data:Data(try underbaseSVG(plan).utf8)))
        files.append(.init(name:"Reference-underbase.png",role:"reference",mediaType:"image/png",data:try encodePNG(rgba(plan,referenceMask:true),width:plan.width,height:plan.height)))
      }
    }
    files.append(.init(name:"Review.pdf",role:"reference",mediaType:"application/pdf",data:try DecorationReviewPDF.make(plan,specification:specification)))
    report["files"]=files.map{["name":$0.name,"role":$0.role,"media_type":$0.mediaType,"bytes":$0.data.count]}
    report["file_listing_scope"]="Generated physical/reference files before this report and immutable source assets. Manifest.json contains the complete packet."
    files.append(.init(name:"Report.json",role:"reference",mediaType:"application/json",data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])))
    guard files.count<=128,files.allSatisfy({$0.data.count<=64_000_000}),files.reduce(0,{$0+$1.data.count})<=128_000_000 else{throw FormError.invalid("Split this preparation above 64 MB per file or 128 MB combined output.")}
    return .init(files:files,report:report)
  }
  private static func metadata(_ plan:DecorationGeometry)->String {
    let data=(try? JSONSerialization.data(withJSONObject:plan.report,options:.sortedKeys)) ?? Data()
    return "<metadata id=\"form-decoration\">"+SVGRenderer.xml(String(decoding:data,as:UTF8.self))+"</metadata>"
  }
  public static func cutSVG(_ plan:DecorationGeometry,region:DecorationMaterialRegion) throws -> String {
    guard plan.options.process == .htv,plan.canExport else{throw FormError.invalid("Choose a valid solid-vector HTV preparation.")}
    let path=SVGRenderer.data(plan.deliveryPath(region.path)),name=SVGRenderer.xml(region.material?.name ?? region.name)
    let weed=plan.options.weedMargin>0 ? "<rect id=\"weed-border\" data-form-role=\"weed\" x=\"0\" y=\"0\" width=\"\(plan.pageWidth)\" height=\"\(plan.pageHeight)\" fill=\"none\" stroke=\"#000000\" stroke-width=\"0.05\"/>":""
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(plan.pageWidth)mm" height="\(plan.pageHeight)mm" viewBox="0 0 \(plan.pageWidth) \(plan.pageHeight)">
    <title>\(name) / HTV cut geometry</title><desc>Actual-size knockout material region. Mirrored: \(plan.options.mirror). No blade/pressure/thermal recipe or automatic material compatibility.</desc>
    \(metadata(plan))<path id="cut-region" data-form-role="cut" fill="#000000" fill-rule="nonzero" stroke="none" d="\(path)"/>\(weed)
    </svg>
    """
  }
  public static func underbaseSVG(_ plan:DecorationGeometry) throws -> String {
    guard plan.options.process == .dtf,plan.canExport else{throw FormError.invalid("Choose a valid DTF preparation for the reference mask.")}
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(plan.width)mm" height="\(plan.height)mm" viewBox="0 0 \(plan.width) \(plan.height)">
    <title>DTF underbase reference only</title><desc>Visible silhouette after masks and white/show-through choices. Not a RIP white channel, choke, density or screening instruction.</desc>
    \(metadata(plan))<path id="underbase-reference" data-form-role="guide" fill="#000000" fill-rule="nonzero" stroke="none" d="\(SVGRenderer.data(plan.deliveryPath(plan.silhouette)))"/>
    </svg>
    """
  }
  public static func rgba(_ plan:DecorationGeometry,referenceMask:Bool=false,dpi:Double?=nil) throws -> CGImage {
    let density=dpi ?? plan.options.dpi
    guard density.isFinite,(36...600).contains(density) else{throw FormError.invalid("Choose finite 36–600 DPI for the decoration raster.")}
    let w=Int(ceil(plan.pageWidth*density/25.4)),h=Int(ceil(plan.pageHeight*density/25.4))
    guard density.isFinite,(36...600).contains(density),w>0,h>0,w<=10000,h<=10000,w*h<=64_000_000 else{throw FormError.invalid("Raster decoration output supports 36–600 DPI, 64 megapixels and 10,000 pixels per edge. Reduce size or DPI.")}
    guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw FormError.invalid("Could not allocate the bounded decoration raster.")}
    context.translateBy(x:0,y:Double(h));context.scaleBy(x:Double(w)/plan.pageWidth,y:-Double(h)/plan.pageHeight)
    if referenceMask {
      context.addPath(plan.deliveryPath(plan.silhouette));context.setFillColor(NSColor.black.cgColor);context.fillPath()
    } else {
      for paint in plan.paints {
        context.setBlendMode(paint.excluded ? .clear:.normal)
        context.addPath(plan.deliveryPath(paint.shape));context.setFillColor(FormColor.color(paint.color).cgColor);context.fillPath()
      }
    }
    guard let image=context.makeImage() else{throw FormError.invalid("Could not encode decoration pixels.")};return image
  }
  private static func encodePNG(_ image:CGImage,width:Double,height:Double) throws -> Data {
    let data=NSMutableData()
    guard let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else{throw FormError.invalid("Could not create the RGBA handoff.")}
    CGImageDestinationAddImage(destination,image,[kCGImagePropertyDPIWidth:Double(image.width)*25.4/width,kCGImagePropertyDPIHeight:Double(image.height)*25.4/height] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else{throw FormError.invalid("Could not finalize RGBA handoff metadata.")};return data as Data
  }
}
