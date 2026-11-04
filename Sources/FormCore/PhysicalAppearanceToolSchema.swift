import Foundation

extension PhysicalAppearance {
  /// One discoverable contract for material, stock-face, thread and masked
  /// finish appearance. Missing scalars take the persisted optical defaults.
  public static var toolSchema:[String:Any] {
    let unit:[String:Any]=["type":"number","minimum":0,"maximum":1]
    let vector:[String:Any]=["type":"object","additionalProperties":false,"required":["x","y"],"properties":["x":["type":"number"],"y":["type":"number"]]]
    let texture:[String:Any]=["type":"object","additionalProperties":false,"required":["asset","sha256"],"properties":[
      "asset":["type":"string","maxLength":240,"description":"Content-addressed image filename already imported into this project's Assets."],
      "sha256":["type":"string","pattern":"^[0-9a-f]{64}$"],
      "colorSpace":["type":"string","enum":["srgb","linearSRGB","data"],"default":"data"],
      "uvIndex":["type":"integer","minimum":0,"maximum":1,"default":0],
      "wrapS":["type":"string","enum":["repeat","clamp","mirror"],"default":"repeat"],
      "wrapT":["type":"string","enum":["repeat","clamp","mirror"],"default":"repeat"],
      "scale":vector,"offset":vector,"rotationDegrees":["type":"number","minimum":-1000000,"maximum":1000000],
      "scaleMM":vector.merging(["type":["object","null"],"description":"Physical millimeters covered by one repeat; positive x/y in 0.001–100000. Null retains mesh UV dimensions."]){_,new in new}]]
    var properties=Dictionary(uniqueKeysWithValues:["diffuseTransmission","transmission","subsurface","sheen","sheenRoughness","anisotropy","anisotropyRotation","coat","coatRoughness","displacementMidlevel"].map{($0,unit)})
    properties["ior"]=["type":"number","minimum":1,"maximum":4,"default":1.5]
    properties["subsurfaceRadiusMM"]=["type":"object","additionalProperties":false,"required":["x","y","z"],"properties":Dictionary(uniqueKeysWithValues:["x","y","z"].map{($0,["type":"number","minimum":0.001,"maximum":1000] as [String:Any])})]
    properties["sheenTint"]=["type":"string","description":"sRGB #RRGGBB color."]
    properties["bumpStrength"]=["type":"number","minimum":0,"maximum":10,"default":1]
    properties["normalStrength"]=["type":"number","minimum":0,"maximum":10,"default":1]
    properties["displacementScaleMM"]=["type":"number","minimum":-100,"maximum":100,"default":0]
    // Every channel has the same portable image contract. Express it once as
    // a bounded dictionary instead of copying the descriptor into every key;
    // nested stock/finish schemas must fit the legacy discovery reply budget.
    properties["textures"]=["type":"object","propertyNames":["enum":PhysicalTextureChannel.allCases.map(\.rawValue)],"maxProperties":PhysicalTextureChannel.allCases.count,"additionalProperties":texture]
    return ["type":["object","null"],"additionalProperties":false,"description":"Complete optional PhysicalAppearance replacement. Optical defaults are assumptions, not measurements. Local stock/finish records replace the inherited appearance. Color channels accept srgb/linearSRGB; scalar, normal and height maps require data. Independent mapping per channel. Null clears the local override.","properties":properties]
  }
}
