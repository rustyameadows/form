import Foundation

public enum PhysicalDimensionToolSchema {
  private static let scalar:[String:Any] = ["oneOf":[["type":"number"],["type":"string","maxLength":256]]]
  private static let point:[String:Any] = ["type":"object","additionalProperties":false,"required":["x","y"],"properties":["x":scalar,"y":scalar]]
  public static let reference:[String:Any] = ["type":"object","additionalProperties":false,"required":["sourceObjectID","measurement"],"properties":[
    "sourceObjectID":["type":"string"],"measurement":["type":"string","enum":PhysicalDimensionMeasurement.allCases.map(\.rawValue)],"parameter":["type":"string","maxLength":64]]]
  public static let bindings:[String:Any] = ["type":["array","null"],"maxItems":32,
    "description":"Saved physical dependencies. Each target parameter is derived from a <=256-byte CAD expression over local independent parameters and named inputs {sourceObjectID,measurement,parameter?}. Measurements include closed book envelopes, trim, leaf-caliper stack, binding allowance and spine. Source products stay visible. Cycles, missing sources and invalid bounds reject atomically. Change source controls or remove the binding before editing its derived target.",
    "items":["type":"object","additionalProperties":false,"required":["parameter","expression","inputs"],"properties":[
      "parameter":["type":"string","maxLength":64],"expression":["type":"string","maxLength":256],"inputs":["type":"object","maxProperties":64,"additionalProperties":reference]]]]
  public static let regions:[String:Any] = ["type":["array","null"],"maxItems":64,
    "description":"Nonprinting physical-size construction regions on a canonical source: {id,name,origin:{x,y},size:{x,y},anchors?:[{elementIDs,horizontal,vertical}]}. Coordinates accept CAD expressions over resolved parameters. Anchors translate layers by region-position changes (normalized horizontal/vertical0...1); never scale type or artwork. A layer has one position authority. null removes guides/anchors without deleting artwork.",
    "items":["type":"object","additionalProperties":false,"required":["id","name","origin","size"],"properties":[
      "id":["type":"string","maxLength":128],"name":["type":"string","maxLength":256],"origin":point,"size":point,
      "anchors":["type":"array","maxItems":256,"items":["type":"object","additionalProperties":false,"required":["elementIDs","horizontal","vertical"],"properties":[
        "elementIDs":["type":"array","maxItems":256,"items":["type":"string"]],"horizontal":["type":"number","minimum":0,"maximum":1],"vertical":["type":"number","minimum":0,"maximum":1]]]]]]]
  public static func decodeBindings(_ raw:Any)throws->[PhysicalDimensionBinding]? {
    if raw is NSNull{return nil}
    guard let values=raw as? [[String:Any]],values.count<=32 else{throw FormError.invalid("Provide up to32 physical dimension bindings or null.")}
    for value in values {try PublicationPhysicalToolSchema.validateFields(value,schema:bindings["items"] as! [String:Any],path:"dimension_bindings")}
    let result=try JSONDecoder.form.decode([PhysicalDimensionBinding].self,from:JSONSerialization.data(withJSONObject:values))
    return result.isEmpty ? nil:result
  }
  public static func decodeRegions(_ raw:Any)throws->[PhysicalArtworkRegion]? {
    if raw is NSNull{return nil}
    guard let values=raw as? [[String:Any]],values.count<=64 else{throw FormError.invalid("Provide up to64 physical artwork regions or null.")}
    for value in values {try PublicationPhysicalToolSchema.validateFields(value,schema:regions["items"] as! [String:Any],path:"artwork_regions")}
    let result=try JSONDecoder.form.decode([PhysicalArtworkRegion].self,from:JSONSerialization.data(withJSONObject:values))
    return result.isEmpty ? nil:result
  }
}
