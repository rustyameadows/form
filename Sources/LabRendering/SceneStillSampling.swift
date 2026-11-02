import CoreGraphics
import Foundation
import simd

/// Rendering quality changes sampling only; authored pixels, geometry and camera
/// remain the same. Interactive drawing and motion use the native path.
public enum SceneCaptureSampling:Sendable {case native,still}

struct SceneCaptureImage:@unchecked Sendable {let image:CGImage}

enum SceneStillSampling {
  static let sampleCount=16,maximumPixels=32_000_000,maximumEdge=8192
  static func pixelCount(width:Int,height:Int)throws->Int {
    guard width>0,height>0,width<=maximumEdge,height<=maximumEdge,Double(width)*Double(height)<=Double(maximumPixels) else{throw SceneRendererError.invalidCapture}
    return width*height
  }
  static func accumulatorBytes(width:Int,height:Int)throws->Int {
    try pixelCount(width:width,height:height)*4*MemoryLayout<UInt32>.stride
  }
  static let offsets:[SIMD2<Float>] = (0..<sampleCount).map { sample in
    var bits=sample,radical:Float=0,weight:Float=0.5
    while bits>0{radical+=Float(bits&1)*weight;bits>>=1;weight*=0.5}
    return .init((Float(sample)+0.5)/Float(sampleCount)-0.5,radical+0.5/Float(sampleCount)-0.5)
  }
  /// RealityKit's public custom camera requires reverse depth. No world-space
  /// camera transform changes are involved in the centered subpixel offsets.
  static func projection(camera:SceneCameraPayload,width:Int,height:Int,offset:SIMD2<Float>)throws->simd_float4x4 {
    try camera.validate();_ = try pixelCount(width:width,height:height)
    let near=Float(camera.nearMM/1000),far=Float(camera.farMM/1000),aspect=Float(width)/Float(height)
    guard near>0,far>near,near.isFinite,far.isFinite else{throw SceneRendererError.invalidCamera}
    switch camera.projection {
    case .perspective(let degrees):
      let y=1/tan(Float(degrees) * .pi/360),x=y/aspect
      return .init(SIMD4(x,0,0,0),SIMD4(0,y,0,0),SIMD4(2*offset.x/Float(width),2*offset.y/Float(height),near/(far-near),-1),SIMD4(0,0,near*far/(far-near),0))
    case .orthographic(let spanMM):
      let heightM=Float(spanMM/1000)
      guard heightM>0,heightM.isFinite else{throw SceneRendererError.invalidCamera}
      return .init(SIMD4(2/(heightM*aspect),0,0,0),SIMD4(0,2/heightM,0,0),SIMD4(0,0,1/(far-near),0),SIMD4(-2*offset.x/Float(width),-2*offset.y/Float(height),far/(far-near),1))
    }
  }
}

/// One serial accumulator, independent of the UI actor. At the existing32MP
/// output limit this holds512MB, never16 frame-sized images. A source frame is
/// immutable, consumed before the reusable capture target is rendered again.
actor SceneStillPixelAccumulator {
  nonisolated let byteCount:Int
  private let width:Int,height:Int
  private var values:[UInt32],samples=0
  private static let decode:[UInt32] = (0..<256).flatMap { alpha in
    (0..<256).map { channel in
      guard alpha>0 else{return UInt32(0)}
      let encoded=min(1,Double(channel)/Double(alpha)),linear=encoded<=0.04045 ? encoded/12.92:pow((encoded+0.055)/1.055,2.4)
      return UInt32((linear*Double(alpha)/255*65535).rounded())
    }
  }
  private static let encode:[UInt8] = (0..<65536).map { value in
    let linear=Double(value)/65535,encoded=linear<=0.0031308 ? 12.92*linear:1.055*pow(linear,1/2.4)-0.055
    return UInt8((max(0,min(1,encoded))*255).rounded())
  }
  init(width:Int,height:Int)throws {
    self.width=width;self.height=height
    byteCount=try SceneStillSampling.accumulatorBytes(width:width,height:height)
    values=Array(repeating:0,count:byteCount/MemoryLayout<UInt32>.stride)
  }
  func append(_ frame:SceneCaptureImage)throws {
    try Task.checkCancellation()
    let image=frame.image
    guard samples<SceneStillSampling.sampleCount,image.width==width,image.height==height,image.bitsPerPixel==32,image.bitsPerComponent==8,image.alphaInfo == .premultipliedLast,
      let data=image.dataProvider?.data,let source=CFDataGetBytePtr(data) else{throw SceneRendererError.invalidCapture}
    let decode=Self.decode,w=width,h=height,stride=image.bytesPerRow
    try values.withUnsafeMutableBufferPointer { output in
      for y in 0..<h {
        if y%32==0{try Task.checkCancellation()}
        for x in 0..<w {
          let src=y*stride+x*4,dst=(y*w+x)*4,alpha=Int(source[src+3]),base=alpha*256
          output[dst]+=decode[base+Int(source[src])];output[dst+1]+=decode[base+Int(source[src+1])];output[dst+2]+=decode[base+Int(source[src+2])];output[dst+3]+=UInt32(alpha)*257
        }
      }
    }
    samples+=1
  }
  func image()throws->SceneCaptureImage {
    try Task.checkCancellation();guard samples>0 else{throw SceneRendererError.invalidCapture}
    let count=width*height,denominator=UInt64(samples)*65535,encode=Self.encode
    var bytes=[UInt8](repeating:0,count:count*4)
    try bytes.withUnsafeMutableBufferPointer { output in
      for index in 0..<count {
        if index%65536==0{try Task.checkCancellation()}
        let i=index*4,alphaSum=UInt64(values[i+3])
        guard alphaSum>0 else{continue}
        let alpha=min(255,(alphaSum*255+denominator/2)/denominator)
        output[i+3]=UInt8(alpha)
        for channel in 0..<3 {
          let linear=min(65535,(UInt64(values[i+channel])*65535+alphaSum/2)/alphaSum)
          output[i+channel]=UInt8((UInt64(encode[Int(linear)])*alpha+127)/255)
        }
      }
    }
    guard let provider=CGDataProvider(data:Data(bytes) as CFData),let space=CGColorSpace(name:CGColorSpace.sRGB),
      let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw SceneRendererError.invalidCapture}
    return .init(image:image)
  }
}
