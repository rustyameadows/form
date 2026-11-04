import Foundation

/// A complete optical response for an independently finished material side.
/// Caliper and provenance belong to the shared parent material.
public struct MaterialSurfaceResponse:Codable,Equatable,Sendable {
  public var color:String
  public var roughness:Double
  public var metallic:Double
  public var appearance:PhysicalAppearance?
  public init(color:String,roughness:Double,metallic:Double,appearance:PhysicalAppearance?=nil) {
    self.color=color;self.roughness=roughness;self.metallic=metallic;self.appearance=appearance
  }
  public func validate()throws {
    try validateColor(color)
    guard roughness.isFinite,(0...1).contains(roughness),metallic.isFinite,(0...1).contains(metallic) else {throw FormError.invalid("Material sides require finite roughness and metallic values from zero to one.")}
    try appearance?.validate()
  }
  public static var toolSchema:[String:Any] {
    ["type":["object","null"],"additionalProperties":false,"required":["color","roughness","metallic"],"description":"Complete reverse-side optical response; null uses the front response. Physical cloth uses the parent material thickness in millimeters.","properties":[
      "color":["type":"string","description":"sRGB #RRGGBB color."],
      "roughness":["type":"number","minimum":0,"maximum":1],
      "metallic":["type":"number","minimum":0,"maximum":1],
      "appearance":PhysicalAppearance.toolSchema]]
  }
}
