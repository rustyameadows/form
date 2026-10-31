import CoreGraphics
import FormCore
import Foundation

public enum FigmaColor {
  public static func convert(_ value: FigmaValue?, profile: String = "SRGB") throws -> (hex: String, alpha: Double) {
    func channel(_ key: String, _ fallback: Double) throws -> Double {
      guard let raw=value?[key] else {return fallback}
      guard let number=raw.numberValue,number.isFinite,(0...1).contains(number) else {
        throw FigmaClipboardError.invalid("Invalid color channel.")
      }
      return number
    }
    var channels=try [channel("r",0),channel("g",0),channel("b",0)]
    let alpha=try channel("a",1)
    if profile == "DISPLAY_P3" || profile == "DISPLAY_P3_V4" {
      let cgComponents:[CGFloat]=channels.map{CGFloat($0)}+[CGFloat(alpha)]
      guard let source=CGColorSpace(name:CGColorSpace.displayP3),let target=CGColorSpace(name:CGColorSpace.sRGB),
        let original=CGColor(colorSpace:source,components:cgComponents),
        let color=original.converted(to:target,intent:.relativeColorimetric,options:nil),
        let components=color.components,components.count>=3 else {throw FigmaClipboardError.invalid("Could not convert Display P3 color.")}
      channels=Array(components.prefix(3)).map{max(0,min(1,Double($0)))}
    } else if !["SRGB","LEGACY"].contains(profile) {
      throw FigmaClipboardError.unsupported("Source color profile \(profile).")
    }
    return (String(format:"#%02X%02X%02X",Int((channels[0]*255).rounded()),Int((channels[1]*255).rounded()),Int((channels[2]*255).rounded())),alpha)
  }
}
