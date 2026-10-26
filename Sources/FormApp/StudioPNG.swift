import AppKit
import FormCore
import ImageIO
import UniformTypeIdentifiers

@MainActor enum StudioPNG {
  static func encode(_ image:NSImage,designDigest:String)throws->Data {
    guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw FormError.invalid("Could not read rendered pixels.")}
    let output=NSMutableData()
    guard let destination=CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil) else{throw FormError.invalid("Could not create PNG output.")}
    CGImageDestinationAddImage(destination,cg,[kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGSoftware:"LAB / SceneKit",kCGImagePropertyPNGDescription:"Committed design SHA256: "+designDigest+". Full provenance is in render.json; source is not archived."]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else{throw FormError.invalid("PNG encoding failed.")};return output as Data
  }
}
