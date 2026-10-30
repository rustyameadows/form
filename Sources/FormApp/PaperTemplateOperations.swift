import AppKit
import CoreFoundation
import CryptoKit
import FormCore
import FormGraphics

@MainActor enum PaperTemplateOperations {
  static func original(_ reference:PaperTemplateReference, assets:URL) throws -> Data {
    try reference.validate()
    let data=try Data(contentsOf:assets.appendingPathComponent(reference.originalAsset))
    guard digest(data)==reference.originalSHA256 else {throw FormError.invalid("The retained manufacturer template changed; restore or explicitly reattach its source.")}
    return data
  }
  static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  static func inspect(object:ProductObject,assets:URL)throws->[String:Any] {
    guard let ref=object.paperTemplateReference else{return ["object_id":object.id.uuidString,"template":NSNull(),"supported_source":"SVG; arbitrary PDF/Illustrator structure is not supported."]}
    _=try original(ref,assets:assets)
    let definition=try PaperConstruction.definition(for:object)
    return ["object_id":object.id.uuidString,"template":try jsonObject(ref),"original_verified":true,
      "geometry_review_required":try ref.requiresGeometryReview(definition),
      "supported_handoffs":["artwork_only","separate","registered_original"],
      "interpretation_is_supplier_approved":false,
      "limitations":["Only an explicitly mapped SVG is supported. Fold interpretation is agent-authored, not inferred or supplier-approved.","Review instructions and exported layers with the supplier; production certification is not inferred."]]
  }
  static func viewBox(_ source:String,width:Double,height:Double)->PaperBounds {
    let pattern="<svg\\b[^>]*\\bviewBox\\s*=\\s*[\"']([^\"']+)[\"']"
    if let regex=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]),let match=regex.firstMatch(in:source,range:NSRange(source.startIndex...,in:source)),let range=Range(match.range(at:1),in:source) {
      let v=source[range].split(whereSeparator:{$0.isWhitespace || $0==","}).compactMap{Double($0)}
      if v.count==4,v.allSatisfy(\.isFinite),v[2]>0,v[3]>0{return .init(x:v[0],y:v[1],width:v[2],height:v[3])}
    }
    return .init(x:0,y:0,width:width,height:height)
  }
  static func appendArtwork(_ fragment:String,to original:Data,reference:PaperTemplateReference)throws->String {
    guard var source=String(data:original,encoding:.utf8),let end=source.range(of:"</svg\\s*>",options:[.regularExpression,.backwards,.caseInsensitive]) else{throw FormError.invalid("Template needs one supported SVG root.")}
    let m=reference.canonicalToTemplate
    let addition="\n<g id=\"lab-registered-artwork\" transform=\"matrix(\(m.a) \(m.b) \(m.c) \(m.d) \(m.tx) \(m.ty))\">\(fragment)</g>\n"
    source.insert(contentsOf:addition,at:end.lowerBound);return source
  }
}

extension StudioStore {
  func paperTemplateCall(_ args:[String:Any])throws->Any {
    guard let project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}),PaperConstruction.isPaper(object) else{throw FormError.missing("Choose a paper construction for its template.")}
    let folder=repository.url(for:project.id).appendingPathComponent("Assets")
    if args["command"] as? String == "template_inspect" {return try PaperTemplateOperations.inspect(object:object,assets:folder)}
    guard args["command"] as? String == "template_attach",!object.locked,
      let path=args["path"] as? String,path.hasPrefix("/"),URL(fileURLWithPath:path).pathExtension.lowercased()=="svg",
      let instructions=args["instructions"] as? String,let mapped=args["technical_mapping"] as? [[String:Any]],!mapped.isEmpty else{throw FormError.invalid("Attach an unlocked construction to an absolute SVG source path, retained instructions and explicit technical_mapping.")}
    let url=URL(fileURLWithPath:path),size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
    guard (1...8_388_608).contains(size) else{throw FormError.invalid("Template source must be1–8MiB.")}
    let data=try Data(contentsOf:url);guard let xml=String(data:data,encoding:.utf8) else{throw FormError.invalid("Use a UTF-8 SVG template.")}
    let lower=xml.lowercased()
    guard !["<!doctype","<!entity","<script","<foreignobject","javascript:","onload="].contains(where:lower.contains) else{throw FormError.invalid("Retained print templates cannot contain executable or external-entity content.")}
    let external=try NSRegularExpression(pattern:"(?:href|xlink:href)\\s*=\\s*[\"'](?!#)[^\"']",options:[.caseInsensitive])
    guard external.firstMatch(in:xml,range:NSRange(xml.startIndex...,in:xml))==nil else{throw FormError.invalid("Template handoff supports self-contained vector SVG references only.")}
    let imported=try SVGImporter.read(data,name:url.lastPathComponent)
    guard imported.assets.isEmpty else{throw FormError.invalid("This bounded template path supports self-contained vector/text SVG, without image assets.")}
    let idsRegex=try NSRegularExpression(pattern:"\\bid\\s*=\\s*[\"']([^\"']+)[\"']")
    let ids=Set(idsRegex.matches(in:xml,range:NSRange(xml.startIndex...,in:xml)).compactMap{Range($0.range(at:1),in:xml).map{String(xml[$0])}})
    let channels=try mapped.map { value -> PaperTemplateChannel in
      guard Set(value.keys).isSubset(of:["elementID","kind"]),let element=value["elementID"] as? String,ids.contains(element),let name=value["kind"] as? String,let kind=PaperTemplateChannel.Kind(rawValue:name) else{throw FormError.invalid("Every technical mapping needs an existing SVG elementID and declared kind.")}
      return .init(elementID:element,kind:kind)
    }
    let bounds=PaperTemplateOperations.viewBox(xml,width:imported.width,height:imported.height)
    let affine:Affine2
    if let raw=args["canonical_to_template"] {
      guard let map=raw as? [String:Any],Set(map.keys).isSubset(of:["a","b","c","d","tx","ty"]) else{throw FormError.invalid("Registration accepts only affine a,b,c,d,tx,ty.")}
      var merged=try jsonObject(Affine2()) as! [String:Any]
      for (key,v) in map {guard let n=v as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("Registration fields must be finite numbers.")};merged[key]=n.doubleValue}
      affine=try JSONDecoder.form.decode(Affine2.self,from:JSONSerialization.data(withJSONObject:merged))
    } else {
      let net=try PaperConstruction.definition(for:object).net()
      guard abs(bounds.x)<1e-9,abs(bounds.y)<1e-9,abs(imported.width-net.size.x)<1e-6,abs(imported.height-net.size.y)<1e-6,abs(bounds.width/imported.width-bounds.height/imported.height)<1e-8 else{throw FormError.invalid("A template with margins, offsets or different dimensions needs an explicit canonical_to_template registration; no supplier alignment is inferred.")}
      affine = .init(a:bounds.width/imported.width,d:bounds.height/imported.height)
    }
    let hash=PaperTemplateOperations.digest(data),asset="paper-template-\(hash).svg"
    let ref=try PaperTemplateReference(originalAsset:asset,originalSHA256:hash,sourceName:url.lastPathComponent,
      vendor:args["vendor"] as? String,revision:args["revision"] as? String,instructions:instructions,
      sizeMM:.init(imported.width,imported.height),viewBox:bounds,canonicalToTemplate:affine,channels:channels,
      interpretedGeometrySHA256:PaperTemplateReference.geometryRevision(PaperConstruction.definition(for:object)),
      importIssues:imported.issues.map(\.summary))
    try ref.validate()
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let target=folder.appendingPathComponent(asset),exists=FileManager.default.fileExists(atPath:target.path)
    if exists {guard try Data(contentsOf:target)==data else{throw FormError.invalid("Retained template asset collision.")}}
    else {try data.write(to:target,options:.atomic)}
    do {
      try engine.edit("Attached manufacturer template",source:"Studio") { p in
        guard let i=p.objects.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Construction changed before attachment.")}
        p.objects[i].paperTemplateReference=ref
      }
    } catch {if !exists {try? FileManager.default.removeItem(at:target)};throw error}
    changed();return try PaperTemplateOperations.inspect(object:engine.project!.objects.first{$0.id==id}!,assets:folder)
  }
}
