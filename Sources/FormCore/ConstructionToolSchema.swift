import Foundation

/// Strict public input for the saved construction model. Project decoding stays
/// forward compatible; authoring commands reject ignored fields before editing.
public enum ConstructionToolSchema {
  private static let string:[String:Any] = ["type":"string"]
  private static let number:[String:Any] = ["type":"number"]
  private static let boolean:[String:Any] = ["type":"boolean"]
  private static let scalar:[String:Any] = ["type":["number","string"],"maxLength":256]
  private static let uuid:[String:Any] = ["type":"string","format":"uuid"]
  private static func object(_ fields:[String:Any],required:[String]=[])->[String:Any] {
    var value:[String:Any] = ["type":"object","additionalProperties":false,"properties":fields]
    if !required.isEmpty {value["required"]=required};return value
  }
  private static func optional(_ schema:[String:Any])->[String:Any] {
    var value=schema;value["type"]=(schema["type"] as? [String] ?? [schema["type"] as? String ?? "object"])+["null"];return value
  }
  private static func array(_ item:[String:Any],_ limit:Int=256,nullable:Bool=false)->[String:Any] {
    ["type":nullable ? ["array","null"]: ["array"],"maxItems":limit,"items":item]
  }
  private static var point:[String:Any] {object(["x":scalar,"y":scalar],required:["x","y"])}
  private static var vector:[String:Any] {object(["x":scalar,"y":scalar,"z":scalar],required:["x","y","z"])}
  private static var strings:[String:Any] {array(string)}
  private static var face:[String:Any] {object(["sourceObjectID":uuid,"sourceSide":string,"sourceOriginMM":optional(point)],required:["sourceObjectID","sourceSide"])}
  private static var installation:[String:Any] {object(["order":["type":"integer"],"stage":string,"presentComponentIDs":strings,"coveredByComponentIDs":optional(strings)],required:["order","stage","presentComponentIDs"])}
  private static var region:[String:Any] {object(["polygon":array(point,128),"side":string,"edgeIndex":optional(["type":"integer"])],required:["polygon","side"])}
  private static var attachment:[String:Any] {
    let adhesive=object(["identity":string,"thicknessMM":scalar,"coverage":scalar,"firstRegion":region,"secondRegion":region,
      "firstExclusions":array(array(point,128),64,nullable:true),"secondExclusions":array(array(point,128),64,nullable:true)],required:["identity","thicknessMM","coverage","firstRegion","secondRegion"])
    let tape=object(["componentID":string,"firstRegion":region,"secondRegion":region,"lengthAxis":string,"widthMM":scalar,"lengthMM":scalar,
      "overlapMM":scalar,"endOffsetStartMM":scalar,"endOffsetEndMM":scalar,"side":string,"bondThicknessMM":scalar,"installation":installation],
      required:["componentID","firstRegion","secondRegion","lengthAxis","widthMM","lengthMM","overlapMM","endOffsetStartMM","endOffsetEndMM","side","installation"])
    let staple=object(["id":string,"entryPanelID":string,"receivingPanelID":string,"anchor":point,"entrySide":string,"crownDirection":point,
      "driveDirection":optional(vector),"crownWidthMM":scalar,"wireWidthMM":scalar,"wireDepthMM":scalar,"legLengthMM":scalar,"count":scalar,
      "spacingMM":scalar,"spacingDirection":optional(point),"endMarginMM":scalar,"minimumReceivingDepthMM":scalar,"minimumEdgeDistanceMM":scalar,
      "maximumJointGapMM":scalar,"termination":string,"clinchLengthMM":optional(scalar),"tool":string,"toolAccessMM":scalar,"toolClearanceMM":scalar,
      "clincherAccessMM":optional(scalar),"installation":installation,"layerComponentIDs":optional(strings)],required:["id","entryPanelID","receivingPanelID","anchor","entrySide","crownDirection","crownWidthMM","wireWidthMM","wireDepthMM","legLengthMM","count","spacingMM","endMarginMM","minimumReceivingDepthMM","minimumEdgeDistanceMM","maximumJointGapMM","termination","tool","toolAccessMM","toolClearanceMM","installation"])
    return object(["id":string,"joinID":string,"enabled":optional(scalar),"adhesive":optional(adhesive),"tape":optional(tape),"staples":array(staple,128,nullable:true)],required:["id","joinID"])
  }
  public static var controls:[String:Any] {
    let choice=object(["label":string,"value":number],required:["label","value"])
    let parameter=object(["parameter":string,"label":string,"group":optional(string),"help":optional(string),"choices":array(choice,64,nullable:true),"step":optional(number),"visibleWhen":optional(scalar)],required:["parameter","label"])
    let measurement=object(["id":string,"label":string,"expression":scalar,"unit":optional(string),"group":optional(string),"visibleWhen":optional(scalar)],required:["id","label","expression"])
    let pose=object(["id":string,"name":string,"openingPercent":number,"explosionPercent":number],required:["id","name","openingPercent","explosionPercent"])
    return object(["groups":array(object(["id":string,"title":string],required:["id","title"]),32),"parameters":array(parameter,128),"measurements":array(measurement,128),"dimensionReferenceParameter":optional(string),"poses":array(pose,32)])
  }
  public static var production:[String:Any] {
    let format=object(["id":string,"name":string,"componentIDs":strings,"surface":string,"widthMM":number,"lengthMM":number,"marginMM":number,"spacingMM":number,"grain":string,"allowRotation":boolean,"wasteAllowanceFraction":number],required:["id","name","componentIDs","surface","widthMM","lengthMM","marginMM","spacingMM","grain","allowRotation","wasteAllowanceFraction"])
    let step=object(["id":string,"title":string,"componentIDs":strings,"jointIDs":strings,"after":strings,"instructions":string],required:["id","title","componentIDs","jointIDs","after","instructions"])
    let guide=object(["id":string,"componentID":string,"role":string,"points":array(point,128),"closed":boolean,"label":string],required:["id","componentID","role","points","closed","label"])
    let view=object(["id":string,"title":string,"projection":string,"openingPercent":number,"explosionPercent":number,"componentIDs":optional(strings),"sectionAxis":optional(string),"sectionOffsetMM":optional(scalar)],required:["id","title","projection","openingPercent","explosionPercent"])
    return object(["version":["type":"integer","enum":[1]],"materials":array(format,64),"steps":array(step,128),"assumptions":array(string,64),"guides":array(guide,256),"views":array(view,32),"foldRoles":["type":"object","additionalProperties":string],"quantity":["type":"integer"],"labels":boolean,"registrationMarks":boolean,"bleedMM":number,"declaredKerfMM":optional(number),"processNotes":string])
  }
  public static var definition:[String:Any] {
    let cutout=object(["id":string,"polygon":array(point,128),"kind":string],required:["id","polygon","kind"])
    let panel=object(["id":string,"name":string,"role":string,"polygon":array(point,128),"artworkRotationDegrees":optional(scalar),"cutouts":array(cutout,64,nullable:true),"features":optional(PublicationPhysicalToolSchema.panelFeatures)],required:["id","name","role","polygon"])
    let parameter=object(["name":string,"value":number,"minimum":number,"maximum":number,"unit":string],required:["name","value","minimum","maximum","unit"])
    let hinge=object(["id":string,"parentPanelID":string,"childPanelID":string,"start":point,"end":point,"angleDegrees":scalar,"layerOffsetMM":optional(scalar),"opensWithTop":optional(boolean)],required:["id","parentPanelID","childPanelID","start","end","angleDegrees"])
    let join=object(["id":string,"name":string,"firstPanelID":string,"secondPanelID":string,"kind":string,"overlapMM":scalar,"notes":string,"enabled":optional(scalar)],required:["id","name","firstPanelID","secondPanelID","kind","overlapMM","notes"])
    let requirement=object(["id":string,"lhs":scalar,"relation":string,"rhs":scalar,"message":string,"tolerance":number],required:["id","lhs","relation","rhs","message"])
    let connection=object(["id":string,"firstPanelID":string,"secondPanelID":string,"firstPoint":point,"secondPoint":point,"maximumGapMM":scalar],required:["id","firstPanelID","secondPanelID","firstPoint","secondPoint","maximumGapMM"])
    let solid=object(["id":string,"firstPanelID":string,"secondPanelID":string,"metric":string,"relation":string,"value":scalar,"message":string,"tolerance":number],required:["id","firstPanelID","secondPanelID","metric","relation","value","message"])
    let component=object(["id":string,"name":string,"rootPanelID":string,"anchor":point,"position":vector,"rotationDegrees":vector,"groupID":optional(string),"stock":optional(PublicationPhysicalToolSchema.stock),"stockThickness":optional(scalar),"quantity":optional(["type":"integer"]),"purpose":optional(string),"front":optional(face),"back":optional(face),"enabled":optional(scalar),"finishes":array(PaperAppearanceCommands.finishSchema,128,nullable:true)],required:["id","name","rootPanelID","anchor","position","rotationDegrees"])
    let group=object(["id":string,"name":string,"parentID":optional(string),"position":vector,"rotationDegrees":vector],required:["id","name","position","rotationDegrees"])
    let opening=object(["axis":string,"width":scalar,"height":scalar,"origin":optional(point)],required:["axis","width","height"])
    let interior=object(["id":string,"name":string,"componentID":string,"origin":vector,"size":vector,"rotationDegrees":optional(vector),"opening":optional(opening)],required:["id","name","componentID","origin","size"])
    return object(["version":["type":"integer","enum":[1,2,3,4]],"name":string,"parameters":array(parameter,128),"derived":["type":["object","null"],"maxProperties":256,"additionalProperties":scalar],"size":point,"stockThickness":scalar,"panels":array(panel,256),"hinges":array(hinge,256),"joins":array(join,256),"rootPanelID":string,"requirements":array(requirement,256,nullable:true),"connections":array(connection,256,nullable:true),"solidChecks":array(solid,128,nullable:true),"components":array(component,128,nullable:true),"interiors":array(interior,64,nullable:true),"groups":array(group,128,nullable:true),"jointAttachments":array(attachment,256,nullable:true),"controls":optional(controls),"production":optional(production)],required:["version","name","parameters","size","stockThickness","panels","hinges","joins","rootPanelID"])
  }
  public static var starter:[String:Any] {
    // Artwork is the existing complete Artwork Codable vocabulary, validated
    // recursively against that same decoded value rather than a second model.
    let artwork:[String:Any] = ["type":"object","description":"Complete canonical Artwork, including vector layers, text and physical registration. Unknown fields are rejected recursively."]
    let source=object(["id":uuid,"name":string,"width":scalar,"height":scalar,"artwork":artwork,"artworkRegions":optional(PhysicalDimensionToolSchema.regions)],required:["id","name","width","height","artwork"])
    return object(["kind":["type":"string","enum":["constructionStarter"]],"version":["type":"integer","enum":[1]],"id":string,"name":string,"summary":string,"symbol":string,"ownerID":optional(uuid),"definition":definition,"stock":PublicationPhysicalToolSchema.stock,"materialID":optional(string),"artwork":optional(artwork),"artworkSources":array(source,128)],required:["kind","version","id","name","definition","stock"])
  }
  public static func validateDefinition(_ raw:Any)throws {
    var schema=definition
    if let source=raw as? [String:Any],let version=source["version"] as? NSNumber,version.intValue<4 {
      var fields=schema["properties"] as! [String:Any]
      for key in ["groups","jointAttachments","controls","production"] {fields.removeValue(forKey:key)}
      var components=fields["components"] as! [String:Any],component=components["items"] as! [String:Any],partFields=component["properties"] as! [String:Any]
      for key in ["groupID","stock","stockThickness","quantity","purpose","front","back","enabled","finishes"] {partFields.removeValue(forKey:key)}
      component["properties"]=partFields;components["items"]=component;fields["components"]=components
      var joins=fields["joins"] as! [String:Any],join=joins["items"] as! [String:Any],joinFields=join["properties"] as! [String:Any]
      joinFields.removeValue(forKey:"enabled");join["properties"]=joinFields;joins["items"]=join;fields["joins"]=joins
      schema["properties"]=fields
    }
    try PublicationPhysicalToolSchema.validateFields(raw,schema:schema,path:"construction definition")
  }
  static func validateStarter(_ raw:[String:Any],decoded:ConstructionStarter)throws {
    if let source=raw["definition"] {try validateDefinition(source)}
    // Skip only canonical artwork subtrees in the ordinary schema walker; they
    // receive the exact Codable field check below, including optional values.
    var shape=starter,properties=shape["properties"] as! [String:Any]
    properties.removeValue(forKey:"artwork")
    var filtered=raw;filtered.removeValue(forKey:"artwork")
    if let sources=raw["artworkSources"] as? [[String:Any]] {
      filtered["artworkSources"]=sources.map {value -> [String:Any] in var value=value;value.removeValue(forKey:"artwork");return value}
      var source=(properties["artworkSources"] as! [String:Any]),item=source["items"] as! [String:Any],fields=item["properties"] as! [String:Any]
      fields.removeValue(forKey:"artwork");item["properties"]=fields;item["required"]=["id","name","width","height"];source["items"]=item;properties["artworkSources"]=source
    }
    shape["properties"]=properties
    try PublicationPhysicalToolSchema.validateFields(filtered,schema:shape,path:"construction starter")
    if let value=raw["artwork"],!(value is NSNull),let artwork=decoded.artwork {try validateArtworkFields(value,artwork,path:"starter.artwork")}
    if let sources=raw["artworkSources"] as? [[String:Any]] {
      for (index,source) in sources.enumerated() where index<decoded.artworkSources.count {
        if let artwork=source["artwork"] {try validateArtworkFields(artwork,decoded.artworkSources[index].artwork,path:"starter.artworkSources[\(index)].artwork")}
      }
    }
  }
  private static func validateArtworkFields(_ raw:Any,_ artwork:Artwork,path:String)throws {
    let canonical=try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(artwork))
    func unwrapped(_ value:Any?)->Any? {guard let value else{return nil};let mirror=Mirror(reflecting:value);return mirror.displayStyle == .optional ? mirror.children.first.flatMap{unwrapped($0.value)}:value}
    func fields(_ value:Any?)->[String:Any] {
      guard let value=unwrapped(value) else{return [:]};let mirror=Mirror(reflecting:value)
      if mirror.displayStyle == .dictionary {
        let pairs:[(String,Any)] = mirror.children.compactMap {child -> (String,Any)? in
          let pair=Array(Mirror(reflecting:child.value).children)
          guard pair.count==2,let key=pair[0].value as? String else{return nil};return (key,pair[1].value)
        }
        return Dictionary(pairs,uniquingKeysWith:{$1})
      }
      return Dictionary(mirror.children.compactMap{child in child.label.map{($0,child.value)}},uniquingKeysWith:{$1})
    }
    func check(_ raw:Any,_ encoded:Any?,_ value:Any?,_ path:String)throws {
      if let raw=raw as? [String:Any] {
        let encoded=encoded as? [String:Any] ?? [:],members=fields(value)
        for (key,child) in raw {
          // requiresInkOutput is an ephemeral render guard, never source data.
          guard (encoded[key] != nil || members[key] != nil),key != "requiresInkOutput" else{throw FormError.invalid("Unknown \(path) field: \(key).")}
          if !(child is NSNull) {try check(child,encoded[key],members[key],path+"."+key)}
        }
      } else if let raw=raw as? [Any] {
        let encoded=encoded as? [Any] ?? [],members=unwrapped(value).map{Array(Mirror(reflecting:$0).children.map(\.value))} ?? []
        for (index,child) in raw.enumerated() {try check(child,index<encoded.count ? encoded[index]:nil,index<members.count ? members[index]:nil,path+"[]")}
      }
    }
    try check(raw,canonical,artwork,path)
  }
}
