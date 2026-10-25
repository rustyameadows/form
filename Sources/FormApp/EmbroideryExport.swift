import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  /// Always regenerates from the current saved artwork. Preview caches are never production inputs.
  func exportEmbroidery(object:ProductObject,arguments:[String:Any])throws -> Any {
    guard arguments["roles"]==nil,arguments["fabric_pattern_material"]==nil,arguments["pattern_pieces"]==nil,arguments["cut_layout"]==nil,
      arguments["element_ids"]==nil else {throw FormError.invalid("Export embroidery, role layers, pattern pieces, and fabric yardage separately. Embroidery regions define their source selection.")}
    guard let project else {throw FormError.missing("Open a project first.")}
    let format=arguments["embroidery_format"] as? String ?? arguments["format"] as? String ?? "preflight"
    guard ["dst","json","svg","preflight"].contains(format),
      arguments["format"]==nil || arguments["format"] as? String == format else {throw FormError.invalid("Use matching embroidery format dst, json, svg, or preflight.")}
    if let raw=arguments["show_jumps"],!(raw is Bool) {throw FormError.invalid("show_jumps must be a boolean.")}
    let program=try EmbroideryDigitizer.generate(object:object,project:project)
    let bounds=program.bounds
    let sequence:[[String:Any]]=program.threadOrder.enumerated().map {order,index in
      let thread=program.design.threads[index]
      var item:[String:Any]=["order":order,"thread_index":index,"name":thread.name,"color":thread.color]
      if let brand=thread.brand {item["brand"]=brand};if let catalog=thread.catalog {item["catalog"]=catalog}
      return item
    }
    var result:[String:Any]=["format":format,"source_digest":program.sourceDigest,"stitches":program.stitchCount,
      "commands":program.commands.count,"thread_sequence":sequence,"hoop_width_mm":program.design.hoopWidth,
      "hoop_height_mm":program.design.hoopHeight,"margin_mm":program.design.margin,
      "bounds_mm":["x":bounds.x,"y":bounds.y,"width":bounds.width,"height":bounds.height],
      "coordinate_unit_mm":0.1,"verified_sew_out":false,
      "limitations":["Underlay and backtracking ties are applied only when explicitly configured. No fabric compensation or machine-specific tuning is inferred; sample sew-out and production digitizer review are required.","DST trim uses a three-jump convention; device recognition varies. DST does not embed RGB colors; use the ordered thread sidecar."]]
    result["underlay_stitches"]=program.commands.filter {$0.action == .stitch && $0.purpose == .underlay}.count
    result["tie_in_stitches"]=program.commands.filter {$0.action == .stitch && $0.purpose == .tieIn}.count
    result["tie_off_stitches"]=program.commands.filter {$0.action == .stitch && $0.purpose == .tieOff}.count
    result["thread_diameter_mm"]=program.design.process?.threadDiameter ?? 0.22
    if format == "preflight" {return result}
    let data:Data
    switch format {
    case "dst":data=try EmbroideryDST.data(program)
    case "json":data=try JSONEncoder.form.encode(program)
    default:data=Data(try EmbroideryRenderer.svg(program,showJumps:arguments["show_jumps"] as? Bool ?? true).utf8)
    }
    let url:URL
    if let path=arguments["path"] as? String {
      guard path.hasPrefix("/") else {throw FormError.invalid("Export path must be absolute.")};url=URL(fileURLWithPath:path)
    } else {
      let folder=repository.url(for:project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      url=folder.appendingPathComponent(object.name.replacingOccurrences(of:"/",with:"-")+"-stitches."+format)
    }
    var outputs=[(url,data)]
    if format == "dst" {
      let sidecar=url.deletingPathExtension().appendingPathExtension("threads.json")
      var manifest=result;manifest["dst_file"]=url.lastPathComponent;manifest["name"]=program.name
      outputs.append((sidecar,try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])))
      result["thread_sidecar_path"]=sidecar.path
    }
    // Validate all output destinations and stage every file before replacing any existing output.
    let fm=FileManager.default
    for (path,_) in outputs {
      var directory:ObjCBool=false
      if fm.fileExists(atPath:path.path,isDirectory:&directory),directory.boolValue {throw FormError.invalid("An embroidery output path is a directory.")}
    }
    let originals=try outputs.map {url,_ -> Data? in fm.fileExists(atPath:url.path) ? try Data(contentsOf:url):nil}
    var staged:[URL]=[],written=0
    defer {for path in staged {try? fm.removeItem(at:path)}}
    do {
      for (url,bytes) in outputs {
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".form-embroidery-"+UUID().uuidString)
        try bytes.write(to:temporary,options:.atomic);staged.append(temporary)
      }
      for (index,output) in outputs.enumerated() {
        try Data(contentsOf:staged[index]).write(to:output.0,options:.atomic);written+=1
      }
    } catch {
      for index in 0..<written {
        if let original=originals[index] {try? original.write(to:outputs[index].0,options:.atomic)}
        else {try? fm.removeItem(at:outputs[index].0)}
      }
      throw error
    }
    result["path"]=url.path;result["bytes"]=data.count
    return result
  }
}
