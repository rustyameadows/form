import AppKit
import FormCore

public struct InkPrintPage {
  public var id:UUID?,name:String,artwork:Artwork,width:Double,height:Double
  public init(id:UUID?=nil,name:String,artwork:Artwork,width:Double,height:Double) {self.id=id;self.name=name;self.artwork=artwork;self.width=width;self.height=height}
}
public enum InkOutputMode:String {case preview,composite,plates,preflight}

struct InkClip {var path:CGPath,evenOdd:Bool}
enum InkPaint {case process([Double]);case spot(ProductionInk)}
struct InkPrimitive {var path:CGPath,evenOdd:Bool,paint:InkPaint,clips:[InkClip]}
struct InkPlannedPage {var source:InkPrintPage,primitives:[InkPrimitive]}

@MainActor final class ProductionInkPlan {
  var pages:[InkPlannedPage]=[]
  var spots:[String:ProductionInk]=[:]
  var profile:ICCOutputProfile?
  var issues:[[String:Any]]=[]
  var primitiveCount=0
  let project:Project,assets:URL
  init(project:Project,pages:[InkPrintPage],assets:URL) {
    self.project=project;self.assets=assets
    guard !pages.isEmpty,pages.count<=200 else{issues=[["severity":"error","message":"Choose 1–200 physical pages for production inks."]];return}
    do {try project.validateArtworkLinks()}catch{issue(error.localizedDescription);return}
    for page in pages {
      guard [page.width,page.height].allSatisfy({$0.isFinite && $0>0 && $0<=100000}) else{issue("A physical ink page has invalid dimensions.",page:page);continue}
      guard let reference=page.artwork.outputColorProfile,reference.model=="CMYK" else{issue("Assign the intended portable CMYK output profile before exporting production inks.",page:page);continue}
      if let profile,profile.reference.sha256 != reference.sha256 {issue("All production pages require the same output profile identity; choose one explicitly.",page:page);continue}
      do {if profile==nil {profile=try ICCOutputProfile(reference:reference,assets:assets)}
        else {_ = try ICCOutputProfile(reference:reference,assets:assets)}
      }catch{issue(error.localizedDescription,page:page);continue}
      do {try prepare(page)}catch{issue(error.localizedDescription,page:page)}
    }
  }
  func issue(_ text:String,page:InkPrintPage?=nil,element:ArtworkElement?=nil,severity:String="error") {
    var value:[String:Any]=["severity":severity,"message":text]
    if let page {value["page"]=page.name;if let id=page.id {value["object_id"]=id.uuidString}}
    if let element {value["element_id"]=element.id.uuidString;value["element"]=element.title}
    issues.append(value)
  }
  private func paint(_ color:String,swatchID:UUID?,page:InkPrintPage) throws -> InkPaint {
    guard let profile else{throw FormError.invalid("Production output has no verified CMYK profile.")}
    if let ink=project.productionInk(swatchID) {
      guard ink.profile.sha256==profile.reference.sha256 else{throw FormError.invalid("An assigned ink uses a different profile identity on \(page.name). Choose matching ink/output profiles explicitly.")}
      if ink.kind == .spot {spots[ink.spotName!]=ink;return .spot(ink)}
      return .process(ink.components.values)
    }
    return .process(try profile.processComponents(color))
  }
  private func prepare(_ page:InkPrintPage) throws {
    var art=try BooleanGeometry.materialized(page.artwork).withInheritedLanguage
    art=try ArtworkProduction.filtered(art,roles:[.print]).artwork
    let tree=ArtworkRenderTree(art,assets:assets,production:true,excluding:[])
    var primitives:[InkPrimitive]=[]
    func world(_ path:CGPath,_ transform:Affine2)->CGPath {var t=transform.cg;return path.copy(using:&t) ?? path}
    var boundary:[InkClip]=[]
    if let value=art.boundary {
      var element=ArtworkElement(kind:"path",x:0,y:0,width:value.width,height:value.height);element.path=value
      boundary=[.init(path:VectorGeometry.path(element),evenOdd:value.evenOdd)]
    }
    func append(_ path:CGPath,evenOdd:Bool=false,paint:InkPaint,clips:[InkClip]) throws {
      guard !path.isEmpty else{return}
      primitiveCount+=1;guard primitiveCount<=100000 else{throw FormError.invalid("Production ink output supports at most 100,000 vector paints per export.")}
      primitives.append(.init(path:path,evenOdd:evenOdd,paint:paint,clips:clips))
    }
    let background=art.backgroundOpacity ?? 1
    if background>0 {
      if background != 1 {issue("Partial background opacity is not supported in opaque production ink output.",page:page)}
      else {try append(CGPath(rect:.init(x: -art.bleed,y: -art.bleed,width:page.width+art.bleed*2,height:page.height+art.bleed*2),transform:nil),paint:paint(art.background,swatchID:art.backgroundSwatchID,page:page),clips:boundary)}
    }
    for name in FontCatalog.missing(in:art) {issue("Install or intentionally replace missing font \(name) before outlining production ink text.",page:page)}
    func visit(_ parent:UUID?,clips:[InkClip]) throws {
      for e in tree.children[parent] ?? [] where tree.visible(e) {
        if e.hasActiveEffects || (e.blendMode ?? "normal") != "normal" || (e.opacity ?? 1) != 1 {
          issue("Production inks currently require opaque, normal-blend artwork without blur or shadow effects.",page:page,element:e);continue
        }
        var masks=clips
        if let id=e.clipID,let mask=tree.byID[id] {
          guard ["rectangle","ellipse","polygon","star","path"].contains(mask.kind) else{issue("Production inks support geometric vector masks; convert this mask to a path first.",page:page,element:mask);continue}
          masks.append(.init(path:world(VectorGeometry.path(mask),art.worldTransform(mask)),evenOdd:mask.path?.evenOdd==true))
        }
        if e.kind=="group" {try visit(e.id,clips:masks);continue}
        guard e.kind != "image" else{issue("Images require a broader production ink pipeline and are not silently flattened into spot output.",page:page,element:e);continue}
        if e.gradient != nil,e.fillEnabled != false,(e.fillOpacity ?? 1)>0 {issue("Gradient paints are not supported in this flat production ink output.",page:page,element:e);continue}
        let fill=e.fillOpacity ?? 1
        if fill>0,fill != 1,e.fillEnabled != false {issue("Partial fill opacity is not an ink tint. Use an explicit named-ink tint swatch.",page:page,element:e);continue}
        let transform=art.worldTransform(e)
        if e.kind=="text" {
          guard e.fillEnabled != false,fill>0 else{continue}
          if TypographyEngine.overflows(e) {issue("Text is overset or wider than its frame. Add capacity before production ink export.",page:page,element:e);continue}
          do {
            if let context=e.storyFrame?.resolved {try GlyphEngine.validateOutput(context.story.sourceElement.inheritingLanguage(context.language),outlines:true)}
            else {try GlyphEngine.validateOutput(e,outlines:true)}
            for run in try TypographyEngine.outlinePaintRuns(e) {try append(world(run.path,transform),paint:paint(run.color,swatchID:run.swatchID,page:page),clips:masks)}
          }catch{issue(error.localizedDescription,page:page,element:e)}
          continue
        }
        guard ["rectangle","ellipse","line","polygon","star","path"].contains(e.kind) else{issue("Convert this artwork to supported vector paths before production ink output.",page:page,element:e);continue}
        if e.fillEnabled != false,e.kind != "line",fill>0 {try append(world(VectorGeometry.path(e),transform),evenOdd:e.path?.evenOdd==true,paint:paint(e.color,swatchID:e.fillSwatchID,page:page),clips:masks)}
        if let stroke=e.visibleStroke {
          guard (stroke.opacity ?? 1)==1 else{issue("Partial stroke opacity is not supported; use an explicit ink tint.",page:page,element:e);continue}
          do {try append(world(StrokeGeometry.path(e),transform),paint:paint(stroke.color,swatchID:stroke.swatchID,page:page),clips:masks)}
          catch {issue(error.localizedDescription,page:page,element:e)}
        }
      }
    }
    try visit(nil,clips:boundary);pages.append(.init(source:page,primitives:primitives))
  }
  var colorants:[String] {["Cyan","Magenta","Yellow","Black"]+spots.keys.sorted()}
  var canExport:Bool {!pages.isEmpty && !issues.contains{$0["severity"] as? String=="error"}}
  var report:[String:Any] {
    var value:[String:Any]=["can_export":canExport,"can_export_composite":canExport,"can_export_plates":canExport && pages.count*colorants.count<=1000,
      "issues":issues,"physical_pages":pages.count,"plate_pages":pages.count*colorants.count,"colorants":colorants,"vector_paints":primitiveCount,
      "source_color_space":"sRGB preview plus declared profile-pinned inks","text_output":"shared shaped outlines","overprint":false,"plates":"positive unscreened digital ink maps; no physical coverage, screening, trapping or PDF/X certification"]
    if let profile {value["output_profile"]=(try? jsonObject(profile.reference)) ?? NSNull()}
    return value
  }
}
