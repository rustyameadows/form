import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// An immutable decoded image paired with the digest of the bytes actually
/// decoded. Authored revision strings cannot stand in for this proof of content.
public final class SceneTextureSource: @unchecked Sendable {
  public let image:CGImage
  public let sha256:String
  /// Conservative encoded storage plus decoded RGBA working memory.
  public let memoryCost:Int
  public init(data:Data,expectedSHA256:String)throws {
    guard data.count<=268_435_456 else {throw CyclesRenderError.invalidScene("A physical texture exceeds the 256 MiB source budget.")}
    let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    guard digest==expectedSHA256 else {throw CyclesRenderError.invalidScene("A physical texture's bytes no longer match its saved SHA256.")}
    guard let source=CGImageSourceCreateWithData(data as CFData,nil),
      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
      width>0,height>0,width<=8192,height<=8192,width*height<=16_777_216,
      let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {
      throw CyclesRenderError.invalidScene("A physical texture cannot be decoded within the 16 MP / 8192-pixel image budget.")
    }
    self.image=image;sha256=digest
    memoryCost=data.count+width*height*((image.bitsPerComponent>8 || image.bitmapInfo.contains(.floatComponents)) ? 16:4)
  }
}
