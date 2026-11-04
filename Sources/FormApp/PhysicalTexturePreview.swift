import AppKit
import FormCore
import ImageIO
import SwiftUI

/// A bounded source preview helps distinguish a fiber map from a color map.
/// Loading never changes the imported bytes or the material's encoding/mapping.
struct PhysicalTexturePreview:View {
  let texture:PhysicalTextureReference
  let channelName:String
  let assets:URL
  @State private var preview:CGImage?
  @State private var dimensions=""
  @State private var failure:String?
  private var sourceKey:String {assets.path+"/"+texture.asset+":"+texture.sha256}
  var body:some View {
    HStack(alignment:.top,spacing:12) {
      ZStack {
        RoundedRectangle(cornerRadius:6).fill(Palette.surface)
        if let preview {
          Image(decorative:preview,scale:1).resizable().aspectRatio(contentMode:.fit).padding(4)
        }else if failure != nil {
          Image(systemName:"exclamationmark.triangle").foregroundStyle(.secondary)
        }else {ProgressView().controlSize(.small)}
      }.frame(width:120,height:100).accessibilityLabel(channelName+" texture preview")
      VStack(alignment:.leading,spacing:5) {
        Text(channelName).font(.headline)
        Text(texture.asset).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        if !dimensions.isEmpty {Text(dimensions+" · "+encoding).font(.caption).foregroundStyle(Palette.secondary)}
        if let size=texture.scaleMM {
          Text("Repeat: \(size.x,format:.number.precision(.fractionLength(0...3))) × \(size.y,format:.number.precision(.fractionLength(0...3))) mm")
            .font(.caption).foregroundStyle(Palette.secondary)
        }
        Text("Source image · UV \(texture.uvIndex)").font(.caption).foregroundStyle(Palette.secondary)
        if let failure {Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
      }
      Spacer(minLength:0)
    }.task(id:sourceKey) {await load()}
  }
  private var encoding:String {
    switch texture.colorSpace {case .srgb:return "sRGB color";case .linearSRGB:return "Linear sRGB color";case .data:return "Data values"}
  }
  private func load()async {
    preview=nil;dimensions="";failure=nil
    let reference=texture,root=assets
    do {
      let worker=Task.detached(priority:.utility) {
        try Task.checkCancellation()
        let url=try reference.verifiedURL(in:root)
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
          let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
          let width=properties[kCGImagePropertyPixelWidth] as? Int,
          let height=properties[kCGImagePropertyPixelHeight] as? Int,
          width>0,height>0,width<=8192,height<=8192,width*height<=16_777_216 else {
          throw FormError.invalid("Texture dimensions exceed the render image budget.")
        }
        try Task.checkCancellation()
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[
          kCGImageSourceCreateThumbnailFromImageAlways:true,
          kCGImageSourceThumbnailMaxPixelSize:320,
          kCGImageSourceCreateThumbnailWithTransform:true,
          kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
          throw FormError.invalid("This texture cannot be previewed.")
        }
        return (image,"\(width) × \(height) px")
      }
      let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
      try Task.checkCancellation()
      preview=result.0;dimensions=result.1
    }catch is CancellationError {}catch {
      guard !Task.isCancelled else{return}
      failure=error.localizedDescription
    }
  }
}
