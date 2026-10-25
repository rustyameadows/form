import AppKit
import FormCore

public extension ICCOutputProfile {
  func processColor(_ values:[Double])->CGColor? {
    guard reference.model=="CMYK",values.count==4,values.allSatisfy({$0.isFinite && (0...1).contains($0)}) else{return nil}
    var components:[CGFloat]=values.map{CGFloat($0)};components.append(1)
    return components.withUnsafeBufferPointer {buffer in CGColor(colorSpace:space,components:buffer.baseAddress!)}
  }
  func inkPreview(_ ink:ProductionInk) throws -> String {
    guard reference.sha256==ink.profile.sha256,let color=processColor(ink.previewComponents),let srgb=CGColorSpace(name:CGColorSpace.sRGB),
      let converted=color.converted(to:srgb,intent:.relativeColorimetric,options:nil) else{throw FormError.invalid("ColorSync could not derive this ink's sRGB alternate preview.")}
    return FormColor.hex(NSColor(cgColor:converted) ?? .clear)
  }
  func processComponents(_ source:String) throws -> [Double] {
    let color=try convert(FormColor.color(source).cgColor)
    guard let values=color.components,values.count==5 else{throw FormError.invalid("The selected output profile did not produce four CMYK components.")}
    return values.prefix(4).map(Double.init)
  }
}
