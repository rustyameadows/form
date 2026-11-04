import Accelerate
import Foundation
import ImageIO

/// Opt-in texture resizing works on decoded channel values, never through a
/// display-color drawing context. In particular a data-map midpoint remains a
/// midpoint and 16-bit maps are not silently reduced to 8 bits.
enum MaterialTextureResampler {
  static let maximumWorkingBytes=1_073_741_824
  struct Result {
    var bytes:Data
    var fileExtension:String
    var width:Int
    var height:Int
    var bitsPerComponent:Int
    var floatingPoint:Bool
  }

  static func dimensions(width:Int,height:Int,maximum:Int)throws->(Int,Int) {
    guard width>0,height>0,width<=8192,height<=8192,width*height<=33_554_432,(1...4096).contains(maximum) else {
      throw FormError.invalid("Resized material maps require a source at most 8192 pixels per edge and 32 megapixels, and max_dimension from 1 to 4096.")
    }
    let ratio=min(1,Double(maximum)/Double(max(width,height)))
    let result=(max(1,Int((Double(width)*ratio).rounded(.down))),max(1,Int((Double(height)*ratio).rounded(.down))))
    guard result.0*result.1<=16_777_216 else {throw FormError.invalid("A resized material map exceeds the 16 megapixel output budget.")}
    return result
  }

  static func resize(_ image:CGImage,width:Int,height:Int,encoding:PhysicalTextureReference.ColorSpace = .data)throws->Result {
    _ = try dimensions(width:image.width,height:image.height,maximum:4096)
    guard width>0,height>0,width<=min(4096,image.width),height<=min(4096,image.height),width*height<=16_777_216 else {
      throw FormError.invalid("Texture resizing requires bounded positive output dimensions and never upscales.")
    }
    guard image.bitsPerPixel<=128,image.bytesPerRow<=image.width*16+256 else {throw FormError.invalid("The material texture row layout exceeds the resizing memory budget.")}
    let sourcePixels=image.width*image.height,targetPixels=width*height
    let outputBytes=targetPixels*((image.bitsPerPixel+7)/8)
    // Includes encoded source bytes (256 MiB), decoded source, lossless output
    // and verification copies, planar scratch, alpha planes and ImageIO slack.
    let alphaBytes=encoding != .data && ![CGImageAlphaInfo.none,.noneSkipFirst,.noneSkipLast].contains(image.alphaInfo) ? (sourcePixels+targetPixels)*4:0
    let workingBytes=268_435_456+image.bytesPerRow*image.height+outputBytes*3+(sourcePixels+targetPixels)*8+alphaBytes+67_108_864
    guard workingBytes<=maximumWorkingBytes else {throw FormError.invalid("Texture resizing exceeds the conservative 1 GiB working-memory budget; choose a smaller source image or max_dimension.")}
    let source=try Pixels(image)
    let rowBytes=width*source.components*source.componentBytes
    var destination=Data(count:rowBytes*height)
    let colorAware=encoding != .data
    let maximum:Float=source.floatingPoint ? 1:(source.componentBytes==1 ? 255:65535)
    let premultiplied=[CGImageAlphaInfo.premultipliedFirst,.premultipliedLast].contains(image.alphaInfo)
    var sourceAlpha:[Float]?,targetAlpha:[Float]?
    if colorAware,let alpha=source.alphaIndex {
      var values=[Float](repeating:0,count:image.width*image.height)
      source.bytes.withUnsafeBytes { raw in
        for y in 0..<image.height {for x in 0..<image.width {
          values[y*image.width+x]=min(1,max(0,source.value(raw,offset:y*image.bytesPerRow+(x*source.components+alpha)*source.componentBytes)/maximum))
        }}
      }
      sourceAlpha=values
      targetAlpha=try scale(values,sourceWidth:image.width,sourceHeight:image.height,width:width,height:height).map{min(1,max(0,$0))}
    }
    // One plane at a time bounds scratch memory independently of channel count.
    // Float represents every 8/16-bit unsigned integer exactly. Floating point
    // sources retain their range; the lossless destination is checked below.
    for component in source.channelIndices {
      var input=[Float](repeating:0,count:image.width*image.height)
      source.bytes.withUnsafeBytes { raw in
        for y in 0..<image.height {for x in 0..<image.width {
          let index=y*image.width+x
          var value=source.value(raw,offset:y*image.bytesPerRow+(x*source.components+component)*source.componentBytes)
          if colorAware,component != source.alphaIndex {
            value /= maximum
            let alpha=sourceAlpha?[index] ?? 1
            if premultiplied {value=alpha>0 ? value/alpha:0}
            if encoding == .srgb {value=linear(value)}
            value *= alpha
          }
          input[index]=value
        }}
      }
      let output=try scale(input,sourceWidth:image.width,sourceHeight:image.height,width:width,height:height)
      destination.withUnsafeMutableBytes { raw in
        for y in 0..<height {for x in 0..<width {
          let index=y*width+x
          var value=output[index]
          if colorAware {
            let alpha=targetAlpha?[index] ?? 1
            if component==source.alphaIndex {value=alpha*maximum}
            else {
              value=alpha>0 ? value/alpha:0
              if encoding == .srgb {value=srgb(value)}
              if premultiplied {value *= alpha}
              value *= maximum
            }
          }
          source.store(value,raw,offset:y*rowBytes+(x*source.components+component)*source.componentBytes)
        }}
      }
    }
    guard let provider=CGDataProvider(data:destination as CFData),let resized=CGImage(width:width,height:height,bitsPerComponent:image.bitsPerComponent,bitsPerPixel:image.bitsPerPixel,bytesPerRow:rowBytes,space:source.colorSpace,bitmapInfo:image.bitmapInfo,provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {
      throw FormError.invalid("The resized material component layout is unsupported.")
    }
    let data=NSMutableData(),fileExtension=source.floatingPoint ? "tiff":"png"
    let type=(source.floatingPoint ? "public.tiff":"public.png") as CFString
    guard let writer=CGImageDestinationCreateWithData(data,type,1,nil) else {throw FormError.invalid("A lossless texture encoder is unavailable.")}
    CGImageDestinationAddImage(writer,resized,[kCGImageDestinationEmbedThumbnail:false] as CFDictionary)
    guard CGImageDestinationFinalize(writer),data.length<=268_435_456,
      let encoded=CGImageSourceCreateWithData(data,nil),let decoded=CGImageSourceCreateImageAtIndex(encoded,0,[kCGImageSourceShouldCache:false] as CFDictionary) else {
      throw FormError.invalid("The resized texture could not be encoded losslessly within 256 MiB.")
    }
    // ImageIO may reject or change an exotic format. Verify its decoded numeric
    // values before publishing an asset instead of silently clipping HDR or
    // reducing a 16-bit data map. Padding components are not material channels.
    try verify(expected:resized,actual:decoded)
    return .init(bytes:data as Data,fileExtension:fileExtension,width:width,height:height,bitsPerComponent:image.bitsPerComponent,floatingPoint:source.floatingPoint)
  }

  private static func linear(_ value:Float)->Float {value<=0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)}
  private static func srgb(_ value:Float)->Float {value<=0.0031308 ? value*12.92:1.055*pow(value,1/2.4)-0.055}
  private static func scale(_ values:[Float],sourceWidth:Int,sourceHeight:Int,width:Int,height:Int)throws->[Float] {
    guard values.allSatisfy(\.isFinite) else {throw FormError.invalid("Texture resampling does not support nonfinite pixel values.")}
    var output=[Float](repeating:0,count:width*height)
    let status=values.withUnsafeBytes { src in output.withUnsafeMutableBytes { dst in
      // vImageScale treats the source as const; do not copy an entire plane just
      // to satisfy the untyped vImage_Buffer data pointer.
      var source=vImage_Buffer(data:UnsafeMutableRawPointer(mutating:src.baseAddress!),height:vImagePixelCount(sourceHeight),width:vImagePixelCount(sourceWidth),rowBytes:sourceWidth*MemoryLayout<Float>.size)
      var target=vImage_Buffer(data:dst.baseAddress!,height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width*MemoryLayout<Float>.size)
      return vImageScale_PlanarF(&source,&target,nil,vImage_Flags(kvImageHighQualityResampling|kvImageEdgeExtend))
    }}
    guard status==kvImageNoError,output.allSatisfy(\.isFinite) else {throw FormError.invalid("The material texture could not be resampled at its original component precision.")}
    return output
  }

  private static func verify(expected:CGImage,actual:CGImage)throws {
    let lhs=try Pixels(expected),rhs=try Pixels(actual)
    guard expected.width==actual.width,expected.height==actual.height,
      expected.bitsPerComponent==actual.bitsPerComponent,lhs.floatingPoint==rhs.floatingPoint,
      lhs.channelIndices.count==rhs.channelIndices.count,lhs.colorSpace.model==rhs.colorSpace.model,
      (lhs.alphaIndex==nil)==(rhs.alphaIndex==nil) else {
      throw FormError.invalid("Lossless texture encoding did not preserve the source precision, channels or alpha representation; this conversion is unsupported.")
    }
    var valid=true
    lhs.bytes.withUnsafeBytes { a in rhs.bytes.withUnsafeBytes { b in
      for y in 0..<expected.height {for x in 0..<expected.width {for (lc,rc) in zip(lhs.channelIndices,rhs.channelIndices) {
        let one=lhs.value(a,offset:y*expected.bytesPerRow+(x*lhs.components+lc)*lhs.componentBytes)
        let two=rhs.value(b,offset:y*actual.bytesPerRow+(x*rhs.components+rc)*rhs.componentBytes)
        let tolerance:Float=lhs.floatingPoint ? max(0.000001,abs(one)*0.000001):0
        if !two.isFinite || abs(one-two)>tolerance {valid=false;return}
      }}}
    }}
    guard valid else {throw FormError.invalid("Lossless texture encoding altered numeric channel values; this conversion is unsupported.")}
  }

  private struct Pixels {
    var bytes:Data
    var colorSpace:CGColorSpace
    var components:Int
    var componentBytes:Int
    var floatingPoint:Bool
    var bigEndian:Bool
    var channelIndices:[Int]
    var alphaIndex:Int?

    init(_ image:CGImage)throws {
      guard !image.isMask,image.decode==nil,let color=image.colorSpace,[CGColorSpaceModel.monochrome,.rgb].contains(color.model),
        let provider=image.dataProvider,let data=provider.data else {throw FormError.invalid("Texture resizing supports decoded grayscale or RGB pixels without a custom decode array.")}
      floatingPoint=image.bitmapInfo.contains(.floatComponents)
      guard (!floatingPoint && [8,16].contains(image.bitsPerComponent)) || (floatingPoint && image.bitsPerComponent==32),
        image.bitsPerPixel%image.bitsPerComponent==0 else {throw FormError.invalid("Texture resizing supports 8/16-bit integer or 32-bit floating grayscale/RGB pixels; this precision is unsupported.")}
      colorSpace=color;componentBytes=image.bitsPerComponent/8;components=image.bitsPerPixel/image.bitsPerComponent
      let colorCount=color.numberOfComponents
      var indices=Array(0..<colorCount)
      switch image.alphaInfo {
      case .none:alphaIndex=nil
      case .noneSkipFirst:indices=Array(1...colorCount);alphaIndex=nil
      case .noneSkipLast:alphaIndex=nil
      case .first,.premultipliedFirst:indices=Array(1...colorCount);alphaIndex=0
      case .last,.premultipliedLast:alphaIndex=colorCount
      default:throw FormError.invalid("Texture resizing does not support this alpha representation.")
      }
      if let alphaIndex {indices.append(alphaIndex)}
      let componentCount=components
      guard (1...4).contains(components),indices.allSatisfy({$0<componentCount}),image.bytesPerRow>=image.width*components*componentBytes,CFDataGetLength(data)>=image.bytesPerRow*image.height else {throw FormError.invalid("The decoded texture has an unsupported channel layout.")}
      let order=image.bitmapInfo.intersection(.byteOrderMask)
      if componentBytes==1,order == .byteOrder32Little {
        guard components==4 else {throw FormError.invalid("Unsupported byte ordering for material channels.")}
        indices=indices.map{3-$0}
        if let index=alphaIndex {alphaIndex=3-index}
      }
      bigEndian=order == .byteOrder16Big || order == .byteOrder32Big
      channelIndices=indices;bytes=data as Data
    }

    func value(_ raw:UnsafeRawBufferPointer,offset:Int)->Float {
      if componentBytes==1 {return Float(raw[offset])}
      if componentBytes==2 {let word=raw.loadUnaligned(fromByteOffset:offset,as:UInt16.self);return Float(bigEndian ? UInt16(bigEndian:word):UInt16(littleEndian:word))}
      let word=raw.loadUnaligned(fromByteOffset:offset,as:UInt32.self)
      return Float(bitPattern:bigEndian ? UInt32(bigEndian:word):UInt32(littleEndian:word))
    }
    func store(_ value:Float,_ raw:UnsafeMutableRawBufferPointer,offset:Int) {
      if componentBytes==1 {raw[offset]=UInt8(min(255,max(0,value.rounded())));return}
      if componentBytes==2 {let word=UInt16(min(65535,max(0,value.rounded())));raw.storeBytes(of:bigEndian ? word.bigEndian:word.littleEndian,toByteOffset:offset,as:UInt16.self);return}
      let word=value.bitPattern;raw.storeBytes(of:bigEndian ? word.bigEndian:word.littleEndian,toByteOffset:offset,as:UInt32.self)
    }
  }
}
