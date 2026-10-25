import AppKit
import FormCore

public struct DecorationMaterialRegion {
  public var paintKey:String,name:String,color:String
  public var material:DecorationLayerMaterial?
  public var path:CGPath
}
struct DecorationPreparedPaint {
  var shape:CGPath,color:String,key:String,name:String,excluded:Bool
  var source:PhysicalVectorPaint
}

/// Physical trim coordinates are the only preparation coordinates. Displaying a
/// curved garment does not introduce unmeasured compensation into delivery files.
@MainActor public struct DecorationGeometry {
  public var source:DecorationSourceSnapshot
  public var options:DecorationPreparationOptions
  public var regions:[DecorationMaterialRegion]=[]
  public var silhouette:CGPath=CGMutablePath()
  public var issues:[DecorationPreflightIssue]=[]
  var paints:[DecorationPreparedPaint]=[]
  public var canExport:Bool {!paints.isEmpty && !issues.contains{$0.severity=="error"}}
  public var width:Double {source.width}
  public var height:Double {source.height}
  public var pageWidth:Double {width+(options.process == .htv ? options.weedMargin*2:0)}
  public var pageHeight:Double {height+(options.process == .htv ? options.weedMargin*2:0)}
  public var deliveryTransform:CGAffineTransform {
    let padding=options.process == .htv ? options.weedMargin:0
    return options.mirror ? .init(a:-1,b:0,c:0,d:1,tx:width+padding,ty:padding):.init(translationX:padding,y:padding)
  }
  public func deliveryPath(_ path:CGPath)->CGPath {var t=deliveryTransform;return path.copy(using:&t) ?? path}
  public init(project:Project,objectID:UUID,options:DecorationPreparationOptions,assets:URL) throws {
    try options.validate();let source=try project.decorationSourceSnapshot(objectID:objectID)
    self.source=source;self.options=options
    var art=source.artwork;art.bleed=0
    if !options.includeBackground {art.backgroundOpacity=0}
    let collected=try PhysicalVectorPlan(artwork:art,width:source.width,height:source.height,assets:assets,clipToFrame:true)
    issues=collected.issues.map{.init(severity:"error",message:$0.message,elementID:$0.elementID)}
    guard collected.paints.count<=4096 else{issues.append(.init(severity:"error",message:"Split decoration artwork above 4,096 vector paints.",elementID:nil));return}
    var profiles:[String:ICCOutputProfile]=[:]
    func profile(_ ref:ArtworkOutputProfile)throws->ICCOutputProfile {
      if let value=profiles[ref.sha256] {return value}
      let value=try ICCOutputProfile(reference:ref,assets:assets);profiles[ref.sha256]=value;return value
    }
    var keys:[String]=[],segments=0
    for paint in collected.paints {
      var count=0;paint.path.applyWithBlock{_ in count+=1};for clip in paint.clips {clip.path.applyWithBlock{_ in count+=1}}
      segments+=count
      guard segments<=250000 else{issues.append(.init(severity:"error",message:"Split decoration artwork above 250,000 source/clip path segments.",elementID:paint.elementID));return}
      let ink=project.productionInk(paint.swatchID),swatch=project.swatches?.first{$0.id==paint.swatchID}
      let key=paint.swatchID.map{"swatch:"+$0.uuidString} ?? "rgb:"+paint.color.uppercased()
      if !keys.contains(key) {keys.append(key)}
      var color=paint.color,isWhite=color.uppercased()=="#FFFFFF",excluded=false
      do {
        if let ink {
          color=try profile(ink.profile).inkPreview(ink)
          isWhite=ink.components.values.allSatisfy{$0==0}
          excluded=(ink.kind == .spot && ink.tint==0) || (options.process == .dtf && options.whitePolicy == .showThrough && isWhite)
          if options.process == .htv,ink.kind == .spot,ink.tint>0,ink.tint<1 {
            issues.append(.init(severity:"error",message:"HTV cuts solid materials; fractional named-ink tints require an intentional solid source/material decision.",elementID:paint.elementID))
          }
          if options.process == .dtf,ink.kind == .spot,!excluded,!options.convertSpotAlternates {
            issues.append(.init(severity:"error",message:"DTF cannot retain this named spot as a physical device colorant. Choose explicit process-alternate delivery or revise the source intentionally.",elementID:paint.elementID))
          }
        }
      }catch {issues.append(.init(severity:"error",message:error.localizedDescription,elementID:paint.elementID))}
      if options.process == .dtf,options.whitePolicy == .showThrough,isWhite {excluded=true}
      let shape=paint.filledRegion()
      guard !shape.isEmpty else{continue}
      paints.append(.init(shape:shape,color:color,key:key,name:swatch?.name ?? paint.color.uppercased(),excluded:excluded,source:paint))
    }
    if options.process == .dtf,options.colorDelivery == .profiledProcess {
      do {
        guard let reference=art.outputColorProfile,reference.model=="CMYK" else{throw FormError.invalid("Assign the intended CMYK output profile before selecting process-PDF delivery.")}
        _ = try profile(reference)
        for paint in paints {
          if let ink=project.productionInk(paint.source.swatchID),ink.profile.sha256 != reference.sha256 {throw FormError.invalid("Delivery and declared inks require matching profile identities. Choose them explicitly.")}
        }
      }catch {issues.append(.init(severity:"error",message:error.localizedDescription,elementID:nil))}
    }
    // Even excluded paint covers what was below: a zero-tint or show-through
    // shape clears previous material, rather than merely disappearing from its own layer.
    var covered:CGPath=CGMutablePath(),regions:[String:CGPath]=[:]
    for paint in paints.reversed() {
      let visible=paint.shape.subtracting(covered);covered=covered.union(paint.shape)
      if !paint.excluded,!visible.isEmpty {regions[paint.key]=regions[paint.key].map{$0.union(visible)} ?? visible}
    }
    for key in keys {
      guard let path=regions[key],!path.isEmpty,let first=paints.first(where:{$0.key==key && !$0.excluded}) else{continue}
      let material=options.layerMaterials.first{$0.paintKey==key}
      self.regions.append(.init(paintKey:key,name:first.name,color:first.color,material:material,path:path))
      silhouette=silhouette.union(path)
    }
    if options.process == .htv,self.regions.count>64 {issues.append(.init(severity:"error",message:"Use at most 64 visible HTV material layers per preparation.",elementID:nil))}
    if silhouette.isEmpty {issues.append(.init(severity:"error",message:"The preparation contains no visible printable/cut material after clips and exclusion choices.",elementID:nil))}
    if options.process == .htv,regions.keys.contains(where:{key in !options.layerMaterials.contains{$0.paintKey==key}}) {
      issues.append(.init(severity:"warning",message:"Some cut layers have no material declaration. Paint colors do not establish a matching vinyl or application recipe.",elementID:nil))
    }
    if options.process == .dtf,options.convertSpotAlternates,paints.contains(where:{project.productionInk($0.source.swatchID)?.kind == .spot && !$0.excluded}) {
      issues.append(.init(severity:"warning",message:"Named spots are intentionally approximated for DTF delivery. Original names/components/profiles remain in the source packet; no physical ink match is asserted.",elementID:nil))
    }
    if let target=source.target,target.surface != .planar {
      issues.append(.init(severity:"warning",message:target.surface == .cylindricalBand ? "This is the current arc-length decoration on a curved concept zone. No press-contact or material compensation is measured.":"This host's printable envelope is unverified. The flat decoration dimensions are exact; physical application remains unverified.",elementID:nil))
    }
  }
  public var report:[String:Any] {
    var value:[String:Any]=["can_export":canExport,"process":options.process.rawValue,"width_mm":width,"height_mm":height,"page_width_mm":pageWidth,"page_height_mm":pageHeight,
      "mirrored":options.mirror,"include_background":options.includeBackground,"weed_margin_mm":options.weedMargin,"requested_dpi":options.dpi,
      "white_policy":options.whitePolicy.rawValue,"color_delivery":options.colorDelivery.rawValue,"spot_alternate_conversion":options.convertSpotAlternates,
      "vector_paints":paints.count,"material_regions":regions.map{["paint_key":$0.paintKey,"name":$0.name,"preview_color":$0.color,"material_name":$0.material?.name ?? "Unassigned material"]},
      "issues":issues.map{["severity":$0.severity,"message":$0.message,"element_id":$0.elementID?.uuidString ?? ""]},
      "underbase":"Reference silhouette only; no RIP white channel, choke, screening or calibrated press claim.","machine_contacted":false,"inventory_deducted":false]
    if let target=source.target {
      value["target"]=["garment_id":target.garment.id.uuidString,"garment":target.garment.name,"zone":target.attachment.zone.rawValue,"zone_name":target.zoneName,
        "zone_width_mm":target.zoneWidth.map{$0 as Any} ?? NSNull(),"zone_height_mm":target.zoneHeight.map{$0 as Any} ?? NSNull(),"surface":target.surface.rawValue,
        "offset_mm":[target.attachment.offset.x,target.attachment.offset.y],"placement_rotation_degrees":target.attachment.rotation,"measured_application_compensation":false]
    }
    return value
  }
}
