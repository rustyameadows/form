import CoreGraphics
import Foundation
import simd

/// Derived texture processing never rewrites imported source bytes. Normal maps
/// are linear data: their embedded display profile must not gamma-correct XYZ.
public enum SceneTextureProcessing {
  public static func normalMap(_ source:CGImage,strength:Float)throws->CGImage {
    guard strength.isFinite,abs(strength)<=1000,source.width<=8192,source.height<=8192,source.width*source.height<=16_000_000 else{throw SceneRendererError.invalidTexture("Normal-map strength must be finite and within ±1000, with at most 16 MP / 8192 pixels per edge.")}
    let space=CGColorSpace(name:CGColorSpace.linearSRGB)!
    guard let raw=source.copy(colorSpace:space) else{throw SceneRendererError.invalidTexture("Normal-map strength needs a readable RGB data image.")}
    var pixels=[UInt8](repeating:0,count:source.width*source.height*4)
    let decoded=pixels.withUnsafeMutableBytes{buffer->Bool in
      guard let context=CGContext(data:buffer.baseAddress,width:source.width,height:source.height,bitsPerComponent:8,bytesPerRow:source.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
      context.setBlendMode(.copy);context.draw(raw,in:.init(x:0,y:0,width:source.width,height:source.height));return true
    }
    guard decoded else{throw SceneRendererError.invalidTexture("Could not read normal-map components.")}
    for i in stride(from:0,to:pixels.count,by:4){
      guard pixels[i+3]==255 else{throw SceneRendererError.invalidTexture("Normal-map strength currently requires opaque RGB data; preserve or explicitly convert this source's alpha channel first.")}
      var normal=SIMD3(Float(pixels[i])/255*2-1,Float(pixels[i+1])/255*2-1,Float(pixels[i+2])/255*2-1)
      normal.x *= strength;normal.y *= strength
      guard simd_length_squared(normal)>1e-20 else{throw SceneRendererError.invalidTexture("A zero normal cannot be renormalized at this strength.")}
      normal=simd_normalize(normal)
      for channel in 0..<3{pixels[i+channel]=UInt8(min(255,max(0,Int(((normal[channel]+1)*127.5).rounded()))))}
    }
    guard let provider=CGDataProvider(data:Data(pixels) as CFData),let image=CGImage(width:source.width,height:source.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:source.width*4,space:space,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw SceneRendererError.invalidTexture("Could not publish the derived normal map.")}
    return image
  }
}
