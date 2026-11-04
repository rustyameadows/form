import Foundation

extension Material {
  public static func toolSchema(create:Bool)->[String:Any] {
    var properties:[String:Any]=[
      "name":["type":"string","maxLength":256],"category":["type":"string","maxLength":128],
      "color":["type":"string","description":"sRGB #RRGGBB color."],
      "roughness":["type":"number","minimum":0,"maximum":1],"metallic":["type":"number","minimum":0,"maximum":1],
      "thickness":["type":"number","minimum":0,"maximum":10000,"description":"Physical caliper in millimeters."],
      "appearance":PhysicalAppearance.toolSchema,"backSurface":MaterialSurfaceResponse.toolSchema,
      "references":["type":["array","null"],"maxItems":64,"items":["type":"object","additionalProperties":false,"required":["title"],"properties":[
        "title":["type":"string"],"url":["type":["string","null"],"description":"Public HTTP(S) source URL; manufacturer photos should be linked unless redistribution is permitted."],
        "asset":["type":["string","null"]],"license":["type":["string","null"]],
        "evidence":["type":"string","enum":["photograph","manufacturerSpecification","measured","estimated"]],"notes":["type":"string"]]]]]
    if create {properties["id"]=["type":"string","maxLength":200];properties["fabric"]=["type":["object","null"]];properties["paperStock"]=PaperAppearanceCommands.stockSchema}
    var result:[String:Any]=["type":"object","additionalProperties":false,"properties":properties]
    if create {result["required"]=["name","color"]}else {result["minProperties"]=1}
    return result
  }
}
