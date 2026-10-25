import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

struct ProductionRoleControls:View {
  @ObservedObject var session:ArtworkSession
  private var value:String {
    let values = Set(session.art.selectionRoots(session.selection).map {$0.productionRole.flatMap {ArtworkProductionRole.resolve($0)?.rawValue} ?? "inherit"})
    return values.count == 1 ? values.first!:"mixed"
  }
  var body:some View {
    DisclosureGroup("Production role") {
      let gate = session.primary.flatMap {ArtworkProduction.controllingGroup(for:$0,in:session.art)}
      Picker("Role",selection:Binding(get:{value},set:{role in
        session.execute("production",["role":role == "inherit" ? NSNull():role as Any])
      })) {
        if value == "mixed" {Text("Mixed roles").tag("mixed")}
        Text("Inherit").tag("inherit")
        ForEach(ArtworkProductionRole.allCases,id:\.self) {Text($0.title).tag($0.rawValue)}
      }.disabled(gate != nil).labelsHidden().accessibilityLabel("Production role")
      if let gate {
        Text("Controlled by \(gate.title). Change the group's role to change this layer's output.")
          .font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        Button("Select controlling group") {session.choose([gate.id])}.font(.system(size:10))
      } else {
        Text("Group roles apply to every descendant. Print output excludes construction layers and guides.")
          .font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
    }.font(.system(size:10))
  }
}

struct ProductionOverlayControls:View {
  @ObservedObject var session:ArtworkSession
  var body:some View {
    DisclosureGroup("Production overlays") {
      ForEach(ArtworkProductionRole.allCases.filter {$0 != .print},id:\.self) {role in
        Toggle(role.title,isOn:Binding(get:{!session.hiddenProductionRoles.contains(role)},set:{visible in
          session.setProductionOverlay(role,visible:visible)
        })).font(.system(size:10))
      }
      Text("Visibility is a local preview choice. Exports use the chosen output roles.")
        .font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
    }.font(.system(size:10))
  }
}

struct ProductionExportPicker:View {
  @Binding var output:String
  let format:String
  var body:some View {
    Picker("Output",selection:$output) {
      ForEach(ArtworkProductionRole.allCases,id:\.self) {role in
        Text(role == .guide ? "Guide reference":role.title).tag(role.rawValue)
      }
      if format == "svg" || format == "pdf" {Text("Separate production roles").tag("all")}
    }.onChange(of:format) {_,format in
      if !["svg","pdf"].contains(format),output == "all" {output = "print"}
    }
    if output == "all" {
      Text(format == "pdf" ? "One actual-size page per role. Guides are excluded.":"Separate named SVG layers for print, cut, score, stitch, and engrave. Guides are excluded.")
        .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
    }
  }
}

extension ArtworkSession {
  func setProductionOverlay(_ role:ArtworkProductionRole,visible:Bool) {
    canvas?.finishText()
    if visible {hiddenProductionRoles.remove(role)} else {hiddenProductionRoles.insert(role)}
    choose(selection.subtracting(ArtworkProduction.hiddenIDs(in:art,roles:hiddenProductionRoles)))
    canvas?.needsDisplay = true
  }
  func exportProduction(_ format:String,output:String) {
    guard let store,let object else {return}
    let roles = output == "all" ? ArtworkProductionRole.manufacturing.map(\.rawValue):[output]
    store.exportArtworkDialog(format,object:object,dpi:exportDPI,outlineText:exportOutline,
      elementIDs:object.isCanvasWorkspace ? selection:[],roles:roles)
  }
}

extension StudioStore {
  func exportProductionArtwork(object:ProductObject,arguments:[String:Any]) throws -> Any {
    guard let project else {throw FormError.missing("Open a project first.")}
    let roles = try ArtworkProduction.parseRoles(arguments["roles"])
    let format = arguments["format"] as? String ?? "svg"
    let dimensions = ArtworkDrawing.dimensions(object)
    let source = (object.isCanvasWorkspace ? project.editableArtwork(object):project.surfaceArtwork(object)) ?? Artwork(background:"#FFFFFF")
    var selection:Set<UUID> = []
    if let value = arguments["element_ids"] {
      guard let raw = value as? [String] else {throw FormError.invalid("element_ids must be an array of artwork UUIDs.")}
      selection = Set(raw.compactMap(UUID.init(uuidString:)))
      guard selection.count == raw.count else {throw FormError.invalid("Choose distinct, valid artwork element IDs.")}
    }
    if object.isCanvasWorkspace,selection.isEmpty {throw FormError.invalid("Select Canvas artwork to export, or place it on a physical frame.")}
    let output = try ArtworkProductionOutput(source:source,width:dimensions.width,height:dimensions.height,roles:roles,selection:selection)
    let assets = repository.url(for:project.id).appendingPathComponent("Assets")
    let data:Data
    switch format {
    case "svg": data = Data(try output.svg(assets:assets,outlineText:arguments["outline_text"] as? Bool ?? true).utf8)
    case "pdf": data = try profiledArtworkPDF(output.pdf(assets:assets,dpi:arguments["dpi"] as? Double ?? 300,title:object.name),
      artwork: source, assets: assets, title: object.name)
    case "png","jpeg":
      guard output.pages.count == 1 else {throw FormError.invalid("Choose one role for raster export; SVG/PDF preserve separate roles.")}
      let dpi = arguments["dpi"] as? Double ?? 300
      guard dpi.isFinite,(36...1200).contains(dpi),output.width*dpi/25.4 <= 16000,
        output.height*dpi/25.4 <= 16000,output.width*output.height*pow(dpi/25.4,2) <= 100_000_000 else {
        throw FormError.invalid("Choose 36–1200 DPI with at most 100 megapixels or 16000 pixels per edge.")
      }
      let art = output.pages[0].artwork
      try ArtworkRenderer.validateAppearanceOutput(art,assets:assets,pixelsPerMM:dpi/25.4)
      let image = ArtworkRenderer.image(art,width:output.width,height:output.height,assets:assets,pixelsPerMM:dpi/25.4,opaqueBackground:format == "jpeg")
      guard let bitmap = image.representations.first as? NSBitmapImageRep else {throw FormError.invalid("Production raster rendering failed.")}
      bitmap.size = .init(width:output.width*TypographyEngine.pointsPerMM,height:output.height*TypographyEngine.pointsPerMM)
      guard let encoded = bitmap.representation(using:format == "jpeg" ? .jpeg:.png,properties:[.compressionFactor:0.94]) else {throw FormError.invalid("Production raster encoding failed.")}
      data = encoded
    default: throw FormError.invalid("Production artwork format must be svg, pdf, png, or jpeg.")
    }
    let url:URL
    if let path = arguments["path"] as? String {
      guard path.hasPrefix("/") else {throw FormError.invalid("Export path must be absolute.")}
      url = URL(fileURLWithPath:path)
    } else {
      let directory = repository.url(for:project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      let title = object.name.replacingOccurrences(of:"/",with:"-")
      url = directory.appendingPathComponent(title+"-"+output.pages.map {$0.role.rawValue}.joined(separator:"-")+"."+format)
    }
    try data.write(to:url,options:.atomic)
    var result = output.metadata
    result["path"] = url.path; result["format"] = format; result["bytes"] = data.count
    result["color_space"] = format == "pdf" ? source.outputColorProfile?.model ?? "sRGB" : "sRGB"
    if format == "pdf", let profile = source.outputColorProfile { result["pdf_output_profile"] = try jsonObject(profile) }
    result["composed_text_outlined"] = format == "svg" && arguments["outline_text"] as? Bool == false
      ? output.pages.filter {$0.role == .print}.reduce(0) {$0+$1.artwork.elements.filter {$0.kind == "text" && TypographyEngine.requiresComposedOutlines($0)}.count}:0
    return result
  }
}
