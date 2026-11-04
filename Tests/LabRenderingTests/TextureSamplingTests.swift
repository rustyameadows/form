import AppKit
import Metal
import RealityKit
import XCTest
@testable import LabRendering

@MainActor final class TextureSamplingTests:XCTestCase {
  func testActualTextureResourcesAndSamplerHonorMipFiltersAndAnisotropyWithoutChangingPixels()throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared
    let renderer=try RealityKitSceneRenderer();defer{renderer.reset()}
    var pixels=[UInt8](repeating:255,count:64*32*4)
    for y in 0..<32 {for x in 0..<64 {let value:UInt8=(x+y)%2==0 ? 255:0;for c in 0..<3 {pixels[(y*64+x)*4+c]=value}}}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData))
    let image=try XCTUnwrap(CGImage(width:64,height:32,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:64*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
    var source=SceneTexturePayload(image:image,revision:"same-immutable-checker",wrapS:.mirror,wrapT:.clamp,sampling:.init(minification:.linear,magnification:.nearest,mip:.linear,maximumAnisotropy:8))
    let filtered=try renderer.texture(source,semantic:.color)
    XCTAssertEqual(filtered.resource.mipmapLevelCount,7,"Minified physical surfaces require the actual generated pyramid.")
    filtered.sampler.access {descriptor in
      XCTAssertEqual(descriptor.minFilter,.linear);XCTAssertEqual(descriptor.magFilter,.nearest);XCTAssertEqual(descriptor.mipFilter,.linear)
      XCTAssertEqual(descriptor.maxAnisotropy,8);XCTAssertEqual(descriptor.sAddressMode,.mirrorRepeat);XCTAssertEqual(descriptor.tAddressMode,.clampToEdge)
    }
    source.sampling = .init(minification:.nearest,magnification:.linear,mip:.nearest,maximumAnisotropy:4)
    let alternate=try renderer.texture(source,semantic:.color)
    XCTAssertTrue(filtered.resource === alternate.resource,"Changing only the sampler reuses immutable source pixels and mip buffers.")
    alternate.sampler.access {descriptor in XCTAssertEqual(descriptor.minFilter,.nearest);XCTAssertEqual(descriptor.magFilter,.linear);XCTAssertEqual(descriptor.mipFilter,.nearest);XCTAssertEqual(descriptor.maxAnisotropy,4)}
    source.sampling.mip = .none
    let unfiltered=try renderer.texture(source,semantic:.color)
    XCTAssertEqual(unfiltered.resource.mipmapLevelCount,1,"An explicit no-mip choice must not alias the filtered cache entry.")
    unfiltered.sampler.access {XCTAssertEqual($0.mipFilter,.notMipmapped)}
    XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data,Data(pixels),"GPU sampling never rewrites the physical source texture.")
    source.sampling.maximumAnisotropy = .nan;XCTAssertThrowsError(try renderer.texture(source,semantic:.normal))
    source.sampling.maximumAnisotropy=17;XCTAssertThrowsError(try renderer.texture(source,semantic:.color))
  }
}
