import AppKit
import AVFoundation
import CoreVideo
import Darwin
import FormCore

/// Streaming camera-only media output. Frames are not accumulated in memory.
@MainActor enum StudioSceneMedia {
  static func videoPixels(_ pixels:StudioPixels)->StudioPixels {
    guard pixels.width>0,pixels.height>0 else{return .init(width:320,height:240)}
    let scale=min(1,1920/Double(max(pixels.width,pixels.height)))
    return .init(width:max(64,Int(Double(pixels.width)*scale)/2*2),height:max(64,Int(Double(pixels.height)*scale)/2*2))
  }
  static func export(project:Project,scene:StudioComposition,assets:URL,renderer:StudioShotRenderer,to destination:URL,video:Bool,isCurrent:()->Bool,progress:(Double)->Void)async throws->URL {
    try scene.validate();let resolved=try scene.resolved(in:project),digest=try project.studioDesignDigest()
    let dependencies=try StudioShotRenderer.resources(project:project,assets:assets)
    var shot=scene.shot();shot.visibility = .init(mode:.objects,objectIDs:resolved.visible.sorted{$0.uuidString<$1.uuidString})
    let recordBase:[String:Any] = ["record_version":1,"application":"LAB","source_project_id":project.id.uuidString,"source_design_sha256":digest,"scene":try jsonObject(scene),"resources":dependencies,"renderer":"RealityKit","animation":"camera only; committed source objects","source_archived":false]
    func check()throws {try Task.checkCancellation();guard isCurrent() else{throw FormError.invalid("The source project changed during capture. No output was delivered.")}}
    try check()
    if !video {
      let result=try await renderer.renderResult(project:resolved.project,shot:shot,assets:assets,preview:false,renderObjectIDs:resolved.visible);try check()
      let png=try StudioPNG.encode(result.image,designDigest:digest)
      var record=recordBase;record["width"]=shot.pixels.width;record["height"]=shot.pixels.height;record["png_sha256"]=StudioRenderFolder.hash(png);record["framing_warnings"]=result.framingWarnings
      let url=try StudioRenderFolder.write(png:png,record:record,to:destination);progress(1);return url
    }
    let fm=FileManager.default,parent=destination.deletingLastPathComponent()
    guard destination.isFileURL,destination.pathExtension=="motion",fm.fileExists(atPath:parent.path),!fm.fileExists(atPath:destination.path) else{throw FormError.invalid("Choose a new .motion folder in an existing parent for MP4 + record.")}
    let stage=parent.appendingPathComponent(".lab-motion-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
    let url=stage.appendingPathComponent("Video.mp4"),pixels=videoPixels(scene.pixels),count=scene.motion.frameCount,fps=scene.motion.fps
    let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
    let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:pixels.width,AVVideoHeightKey:pixels.height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:8_000_000,AVVideoExpectedSourceFrameRateKey:fps]])
    input.expectsMediaDataInRealTime=false
    guard writer.canAdd(input) else{throw FormError.invalid("The local H.264 writer rejected these output settings.")}
    writer.add(input)
    let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:pixels.width,kCVPixelBufferHeightKey as String:pixels.height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
    guard writer.startWriting() else{throw writer.error ?? FormError.invalid("Could not start video encoding.")}
    writer.startSession(atSourceTime:.zero)
    var finished=false;defer{if !finished{writer.cancelWriting()}}
    shot.pixels=pixels
    for index in 0..<count {
      try check();shot.camera=try scene.motion.camera(start:scene.camera,fraction:Double(index)/Double(count-1))
      let image=try await renderer.render(project:resolved.project,shot:shot,assets:assets,preview:false,renderObjectIDs:resolved.visible)
      try check()
      let readyDeadline=Date().addingTimeInterval(30)
      while !input.isReadyForMoreMediaData {
        try check();guard writer.status == .writing,Date()<readyDeadline else{throw writer.error ?? FormError.invalid("Video encoding stopped accepting frames.")};try await Task.sleep(nanoseconds:2_000_000)
      }
      let buffer=try pixelBuffer(image,width:pixels.width,height:pixels.height,pool:adaptor.pixelBufferPool)
      guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(index),timescale:Int32(fps))) else{throw writer.error ?? FormError.invalid("Could not append a video frame.")}
      progress(Double(index+1)/Double(count));await Task.yield()
    }
    input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:Int64(count),timescale:Int32(fps)))
    await withCheckedContinuation{continuation in writer.finishWriting{continuation.resume()}}
    try check();guard writer.status == .completed else{throw writer.error ?? FormError.invalid("Could not finish video encoding.")};finished=true
    let asset=AVURLAsset(url:url),tracks=try await asset.loadTracks(withMediaType:.video),duration=try await asset.load(.duration)
    guard tracks.count==1,abs(CMTimeGetSeconds(duration)-Double(count)/Double(fps))<0.05 else{throw FormError.invalid("The encoded video failed duration/track verification.")}
    let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
    var record=recordBase;record["width"]=pixels.width;record["height"]=pixels.height;record["fps"]=fps;record["frames"]=count;record["seconds"]=Double(count)/Double(fps);record["mp4_sha256"]=StudioRenderFolder.hash(bytes);record["codec"]="H.264";record["audio"]=false
    try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:stage.appendingPathComponent("render.json"))
    try check()
    guard renameatx_np(AT_FDCWD,stage.path,AT_FDCWD,destination.path,UInt32(RENAME_EXCL))==0 else{throw FormError.invalid("The destination changed during export; it was left untouched.")}
    return destination.appendingPathComponent("Video.mp4")
  }
  static func pixelBuffer(_ image:NSImage,width:Int,height:Int,pool:CVPixelBufferPool?)throws->CVPixelBuffer {
    var value:CVPixelBuffer?
    let result:CVReturn
    if let pool {result=CVPixelBufferPoolCreatePixelBuffer(nil,pool,&value)}
    else {result=CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&value)}
    guard result==kCVReturnSuccess,let buffer=value else{throw FormError.invalid("Could not allocate a video frame buffer.")}
    CVPixelBufferLockBaseAddress(buffer,[]);defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
    guard let bitmap=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue) else{throw FormError.invalid("Could not paint a video frame.")}
    context.draw(bitmap,in:.init(x:0,y:0,width:width,height:height));return buffer
  }
}
