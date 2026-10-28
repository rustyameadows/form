import AppKit
import FormCore

public struct ArtworkProductionPage {
  public let role:ArtworkProductionRole
  public let artwork:Artwork
  public let contentIDs:Set<UUID>
}

@MainActor public struct ArtworkProductionOutput {
  public let width:Double
  public let height:Double
  public let pages:[ArtworkProductionPage]

  public init(source:Artwork,width:Double,height:Double,roles:[ArtworkProductionRole],selection:Set<UUID> = []) throws {
    guard !roles.isEmpty,Set(roles).count == roles.count else {throw FormError.invalid("Choose distinct production output roles.")}
    var scoped = source.withInheritedLanguage
    if !selection.isEmpty {scoped = try scoped.exporting(selection).artwork}
    scoped = try BooleanGeometry.materialized(scoped)
    var outputWidth = width,outputHeight = height
    if !selection.isEmpty {
      let union = try ArtworkProduction.filtered(scoped,roles:Set(roles))
      guard !union.contentIDs.isEmpty else {throw FormError.invalid("The selection has no visible content in the requested production roles.")}
      let bounds = try union.artwork.exporting(union.contentIDs).bounds
      for index in scoped.elements.indices where scoped.elements[index].parentID == nil {
        ArtworkCommands.translate(&scoped.elements[index],dx:-bounds.x,dy:-bounds.y)
      }
      if var boundary = scoped.boundary {
        for contour in boundary.contours.indices {
          boundary.contours[contour].nodes = boundary.contours[contour].nodes.map {
            PathCommands.transformed($0,by:.translation(-bounds.x,-bounds.y))
          }
        }
        scoped.boundary = boundary
      }
      outputWidth = max(0.1,bounds.width); outputHeight = max(0.1,bounds.height)
    }
    guard outputWidth.isFinite,outputHeight.isFinite,outputWidth > 0,outputHeight > 0,
      outputWidth <= 100000,outputHeight <= 100000 else {throw FormError.invalid("Choose finite physical output dimensions within 100000 mm.")}
    var outputs:[ArtworkProductionPage] = []
    for role in roles {
      let filtered = try ArtworkProduction.filtered(scoped,roles:[role])
      if filtered.contentIDs.isEmpty && role != .print {continue}
      if [.cut,.score,.stitch].contains(role) {
        guard !filtered.artwork.elements.contains(where:{$0.kind == "image" || $0.hasActiveEffects}) else {
          throw FormError.invalid("\(role.title) output needs vector geometry without images, blur, or shadows. Outline or simplify that layer first.")
        }
      }
      outputs.append(.init(role:role,artwork:filtered.artwork,contentIDs:filtered.contentIDs))
    }
    guard !outputs.isEmpty else {throw FormError.invalid("No visible artwork uses the requested production roles.")}
    self.width = outputWidth; self.height = outputHeight; self.pages = outputs
  }

  public var metadata:[String:Any] {
    ["units":"mm","width_mm":width,"height_mm":height,
      "roles":pages.map { $0.role.rawValue },
      "role_pages":pages.enumerated().map { ["page":$0.offset+1,"role":$0.element.role.rawValue,"elements":$0.element.contentIDs.count] as [String:Any] },
      "stitch_program":false]
  }

  private func namespaced(_ source:String,role:ArtworkProductionRole) throws -> String {
    // Each role retains its full group/clip hierarchy. Prefix their repeated IDs
    // in one pass so references cannot collide between SVG production layers.
    let expression = try NSRegularExpression(pattern:##"(\bid="|url\(#|href="#)([^"\)]+)"##)
    let text = source as NSString
    var result = "",end = 0
    for match in expression.matches(in:source,range:NSRange(location:0,length:text.length)) {
      result += text.substring(with:NSRange(location:end,length:match.range.location-end))
      result += text.substring(with:match.range(at:1))+"form-"+role.rawValue+"-"+text.substring(with:match.range(at:2))
      end = NSMaxRange(match.range)
    }
    result += text.substring(from:end)
    return result
  }

  public func svg(assets:URL,outlineText:Bool = true) throws -> String {
    var layers = ""
    for page in pages {
      let forcedOutlines = [.cut,.score,.stitch,.engrave].contains(page.role)
      let fragment = try SVGRenderer.fragment(page.artwork,width:width,height:height,assets:assets,
        outlineText:forcedOutlines || outlineText)
      layers += "<g id=\"form-role-\(page.role.rawValue)\" data-form-role=\"\(page.role.rawValue)\" inkscape:groupmode=\"layer\" inkscape:label=\"\(page.role.title)\"><title>\(page.role.title)</title>\(try namespaced(fragment,role:page.role))</g>"
    }
    let description = "FORM production layers. Physical units are millimeters. Roles express design intent; stitch paths are not a digitized machine stitch program."
    let json = String(decoding:try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]),as:UTF8.self)
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:inkscape=\"http://www.inkscape.org/namespaces/inkscape\" width=\"\(width)mm\" height=\"\(height)mm\" viewBox=\"0 0 \(width) \(height)\"><desc>\(description)</desc><metadata id=\"form-production\">\(SVGRenderer.xml(json))</metadata>\(layers)</svg>"
  }

  public func pdf(assets:URL,dpi:Double = 300,title:String = "FORM production artwork") throws -> Data {
    guard dpi.isFinite,(36...1200).contains(dpi) else {throw FormError.invalid("Choose 36–1200 DPI for PDF effects.")}
    for page in pages {try ArtworkRenderer.validateAppearanceOutput(page.artwork,assets:assets,pixelsPerMM:dpi/25.4)}
    var box = CGRect(x:0,y:0,width:width*TypographyEngine.pointsPerMM,height:height*TypographyEngine.pointsPerMM)
    let data = NSMutableData()
    let order = pages.enumerated().map {"\($0.offset+1):\($0.element.role.rawValue)"}.joined(separator:", ")
    let info:[String:Any] = [kCGPDFContextCreator as String:"FORM",kCGPDFContextTitle as String:title,
      kCGPDFContextSubject as String:"Manufacturing roles by page: \(order). Physical size \(width) × \(height) mm. Stitch geometry is a reference, not a machine stitch program."]
    guard let consumer = CGDataConsumer(data:data),let context = CGContext(consumer:consumer,mediaBox:&box,info as CFDictionary) else {throw FormError.invalid("Could not create production PDF.")}
    for page in pages {
      context.beginPDFPage([kCGPDFContextTrimBox:Data(bytes:&box,count:MemoryLayout<CGRect>.size)] as CFDictionary)
      context.saveGState()
      context.translateBy(x:0,y:box.height)
      context.scaleBy(x:TypographyEngine.pointsPerMM,y:-TypographyEngine.pointsPerMM)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
      ArtworkRenderer.draw(page.artwork,width:width,height:height,assets:assets,effectScale:dpi/25.4)
      NSGraphicsContext.restoreGraphicsState()
      context.restoreGState()
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }
}
