import Foundation
import Darwin
import ImageIO

public struct SceneRenderCapabilities: Sendable {
  public let protocolVersion:Int
  public let engineVersion:String
  public let devices:[String]
  public let helperURL:URL
}
public struct SceneRenderProgress: Sendable {
  public var jobID:UUID
  public var phase:String
  public var sample:Int
  public var totalSamples:Int
  public var fraction:Double
  public var elapsedSeconds:Double
  public var device:String? = nil
  public var fallbackReason:String? = nil
}
public struct SceneRenderFrame: Sendable {
  public let jobID:UUID
  public let sourceRevision:String
  public let url:URL
  public let sample:Int
}
public struct SceneRenderResult: Sendable {
  public let jobID:UUID
  public let sourceRevision:String
  public let pngURL:URL
  public let exrURL:URL
  public let device:String
  public let engineVersion:String
  public let samples:Int
  public let elapsedSeconds:Double
  public let width:Int
  public let height:Int
  public let fallbackReason:String?
  public let denoiser:String
  public let preparationSeconds:Double?
  public let renderSeconds:Double?
  public let denoiseSeconds:Double?
}
public enum SceneRenderEvent: Sendable {
  case progress(CyclesRenderProgress)
  case frame(CyclesRenderFrame)
  case completed(CyclesRenderResult)
}
public struct SceneRenderJob: Sendable {
  public let id:UUID
  public let directory:URL
  public let events:AsyncThrowingStream<CyclesRenderEvent,Error>
}
public struct SceneRenderStatus: Sendable {
  public enum State:String,Sendable {case preparing,rendering,completed,cancelled,failed}
  public let id:UUID
  public var state:State
  public var progress:CyclesRenderProgress?
  public var result:CyclesRenderResult?
  public var error:String?
}

/// Shared progressive rendering contract. Consumers depend on immutable scene
/// values and events, independently of native view/picking implementations.
public protocol SceneRenderService:Sendable {
  func capabilities()async throws->SceneRenderCapabilities
  func start(snapshot:SceneSnapshot,settings:SceneRenderSettings,outputDirectory:URL)async throws->SceneRenderJob
  func status(jobID:UUID)async->SceneRenderStatus?
  func cancel(jobID:UUID)async
}
public typealias CyclesCapabilities = SceneRenderCapabilities
public typealias CyclesRenderProgress = SceneRenderProgress
public typealias CyclesRenderFrame = SceneRenderFrame
public typealias CyclesRenderResult = SceneRenderResult
public typealias CyclesRenderEvent = SceneRenderEvent
public typealias CyclesRenderJob = SceneRenderJob
public typealias CyclesRenderStatus = SceneRenderStatus

private final class CyclesProcess: @unchecked Sendable {
  let process=Process()
  let id=UUID()
  private let lock=NSLock()
  private var exitCode:Int32?
  private var waiters:[CheckedContinuation<Int32,Never>]=[]
  init() {
    process.terminationHandler = { [weak self] process in self?.didExit(process.terminationStatus) }
  }
  private func didExit(_ code:Int32) {
    lock.lock();exitCode=code;let pending=waiters;waiters=[];lock.unlock()
    for waiter in pending {waiter.resume(returning:code)}
  }
  func waitForExit()async->Int32 {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let code=exitCode {lock.unlock();continuation.resume(returning:code)}
      else {waiters.append(continuation);lock.unlock()}
    }
  }
}

/// A single helper session owns a render. Preview requests replace previews;
/// final work preempts previews, and can only be interrupted explicitly.
public actor CyclesRenderService:SceneRenderService {
  private struct Active {
    var id:UUID
    var process:CyclesProcess
    var directory:URL
    var revision:String
    var settings:CyclesRenderConfiguration
    var continuation:AsyncThrowingStream<CyclesRenderEvent,Error>.Continuation
    var pendingResult:CyclesRenderResult?
    var renderedSamples=0
    var fallbackReason:String?
    var pendingMetalInitializationFailure:String?
    var started:Date
  }
  private let helperURL:URL
  private var active:Active?
  private var statuses:[UUID:CyclesRenderStatus]=[:]
  private var order:[UUID]=[]
  private var lastPreviewDirectory:URL?
  public init(helperURL:URL? = nil) {
    self.helperURL=helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lab-cycles-render")
  }
  public func capabilities() async throws->CyclesCapabilities {
    try requireHelper()
    let url=helperURL
    return try await Task.detached {
      let handle=CyclesProcess(),pipe=Pipe(),child=handle.process;child.executableURL=url;child.arguments=["--capabilities"];child.standardOutput=pipe;child.standardError=FileHandle.nullDevice
      try child.run();try? pipe.fileHandleForWriting.close()
      let watchdog=Task.detached {
        try? await Task.sleep(nanoseconds:15_000_000_000)
        if !Task.isCancelled,child.isRunning {child.terminate();try? await Task.sleep(nanoseconds:2_000_000_000);if !Task.isCancelled,child.isRunning {kill(child.processIdentifier,SIGKILL)}}
      }
      defer{watchdog.cancel()}
      let data=try pipe.fileHandleForReading.readToEnd() ?? Data();let exitCode=await handle.waitForExit()
      guard data.count<=1_048_576,exitCode==0,let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CyclesRenderError.helperFailed("The bundled Cycles helper could not report its capabilities.")}
      let version=(raw["protocolVersion"] as? Int) ?? (raw["version"] as? Int) ?? 1
      guard version==1 else{throw CyclesRenderError.protocolViolation("The bundled Cycles helper uses an unsupported protocol version.")}
      let devices=(raw["devices"] as? [String]) ?? (raw["devices"] as? [[String:Any]])?.compactMap{$0["type"] as? String ?? $0["id"] as? String} ?? []
      return CyclesCapabilities(protocolVersion:version,engineVersion:raw["engineVersion"] as? String ?? raw["cyclesVersion"] as? String ?? "Cycles",devices:devices,helperURL:url)
    }.value
  }
  public func status(jobID:UUID)->CyclesRenderStatus? {statuses[jobID]}
  public var currentJobID:UUID? {active?.id}
  public func start(snapshot:SceneSnapshot,settings:CyclesRenderConfiguration,outputDirectory:URL) async throws->CyclesRenderJob {
    try Task.checkCancellation();try requireHelper();try settings.validate()
    if let previous=active {
      func priority(_ purpose:CyclesRenderConfiguration.Purpose)->Int {switch purpose {case .preview:return 0;case .review:return 1;case .final:return 2}}
      guard priority(settings.purpose)>=priority(previous.settings.purpose),previous.settings.purpose != .final else{throw CyclesRenderError.busy}
      cancel(jobID:previous.id)
    }
    if let last=lastPreviewDirectory {try? FileManager.default.removeItem(at:last);lastPreviewDirectory=nil}
    let id=UUID(),directory=outputDirectory.appendingPathComponent("cycles-"+id.uuidString,isDirectory:true)
    guard outputDirectory.isFileURL else{throw CyclesRenderError.invalidScene("Render outputs need a local directory.")}
    let manifest:URL
    do {manifest=try CyclesSceneManifest.write(snapshot:snapshot,settings:settings,jobID:id,directory:directory)}
    catch {try? FileManager.default.removeItem(at:directory);throw error}
    do {try Task.checkCancellation()}catch{try? FileManager.default.removeItem(at:directory);throw error}
    var continuation:AsyncThrowingStream<CyclesRenderEvent,Error>.Continuation!
    let stream=AsyncThrowingStream<CyclesRenderEvent,Error>(bufferingPolicy:.bufferingNewest(3)){continuation=$0}
    let child:CyclesProcess
    do {child=try launch(manifest:manifest,directory:directory,jobID:id)}
    catch {continuation.finish(throwing:error);try? FileManager.default.removeItem(at:directory);throw error}
    active=Active(id:id,process:child,directory:directory,revision:snapshot.revision,settings:settings,continuation:continuation,started:Date())
    statuses[id] = .init(id:id,state:.rendering);order.append(id);trimStatuses()
    continuation.yield(.progress(.init(jobID:id,phase:"preparing",sample:0,totalSamples:settings.samples,fraction:0,elapsedSeconds:0)))
    continuation.onTermination = { @Sendable [weak self] reason in
      if case .cancelled=reason {Task{await self?.cancel(jobID:id)}}
    }
    return .init(id:id,directory:directory,events:stream)
  }
  private func launch(manifest:URL,directory:URL,jobID:UUID)throws->CyclesProcess {
    let child=CyclesProcess(),pipe=Pipe(),stderrURL=directory.appendingPathComponent("stderr.log")
    FileManager.default.createFile(atPath:stderrURL.path,contents:nil)
    let stderr=try FileHandle(forWritingTo:stderrURL)
    child.process.executableURL=helperURL;child.process.arguments=["--render",manifest.path]
    child.process.standardOutput=pipe;child.process.standardError=stderr
    child.process.currentDirectoryURL=directory
    do {try child.process.run();try? pipe.fileHandleForWriting.close();try? stderr.close()}
    catch {try? stderr.close();throw CyclesRenderError.unavailable("Could not launch bundled Cycles: \(error.localizedDescription)")}
    Task.detached { [weak self] in
      var pending=Data()
      do {
        // Foundation's length-based FileHandle read can wait for the requested
        // byte count on a pipe. A short flushed progress/frame must reach the UI
        // while the helper is still rendering, rather than at EOF.
        var buffer=[UInt8](repeating:0,count:65536)
        while true {
          let count=buffer.withUnsafeMutableBytes {Darwin.read(pipe.fileHandleForReading.fileDescriptor,$0.baseAddress,$0.count)}
          if count<0 {if errno==EINTR {continue};throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
          if count==0 {break}
          pending.append(contentsOf:buffer.prefix(count))
          guard pending.count<=1_048_576 else{throw CyclesRenderError.protocolViolation("Cycles emitted an oversized protocol message.")}
          while let end=pending.firstIndex(of:10) {
            let line=Data(pending[..<end]);pending.removeSubrange(...end)
            if !line.isEmpty {await self?.receive(line,jobID:jobID,processID:child.id)}
          }
        }
        if !pending.isEmpty {await self?.receive(pending,jobID:jobID,processID:child.id)}
        let exitCode=await child.waitForExit()
        await self?.exited(jobID:jobID,processID:child.id,exitCode:exitCode)
      } catch {await self?.processFailed(jobID:jobID,processID:child.id,error:error)}
      try? pipe.fileHandleForReading.close()
    }
    return child
  }
  private func processFailed(jobID:UUID,processID:UUID,error:Error) {
    guard active?.id==jobID,active?.process.id==processID else{return}
    fail(jobID:jobID,error:error)
  }
  public func cancel(jobID:UUID) {
    guard let current=active,current.id==jobID else{return}
    active=nil;statuses[jobID]?.state = .cancelled;statuses[jobID]?.error=CyclesRenderError.cancelled.localizedDescription
    stop(current.process);current.continuation.finish(throwing:CyclesRenderError.cancelled)
    cleanupPreview(current.directory,after:current.process)
  }
  private func requireHelper()throws {
    guard FileManager.default.isExecutableFile(atPath:helperURL.path) else{throw CyclesRenderError.unavailable("This LAB build does not contain the Cycles renderer. Install the verified app bundle with its rendering components.")}
  }
  private func stop(_ child:CyclesProcess) {
    if child.process.isRunning {child.process.terminate()}
    Task.detached {
      try? await Task.sleep(nanoseconds:2_000_000_000)
      if child.process.isRunning {kill(child.process.processIdentifier,SIGKILL)}
    }
  }
  private func cleanupPreview(_ directory:URL,after child:CyclesProcess) {
    Task.detached {
      for _ in 0..<30 {
        if !child.process.isRunning {try? FileManager.default.removeItem(at:directory);return}
        try? await Task.sleep(nanoseconds:100_000_000)
      }
    }
  }
  private func trimStatuses() {while order.count>32 {let old=order.removeFirst();statuses.removeValue(forKey:old)}}
  private func receive(_ data:Data,jobID:UUID,processID:UUID) {
    guard var current=active,current.id==jobID,current.process.id==processID else{return}
    do {
      guard let message=try JSONSerialization.jsonObject(with:data) as? [String:Any],let type=message["type"] as? String else {throw CyclesRenderError.protocolViolation("Cycles emitted an invalid event.")}
      if let source=message["jobID"] as? String,source.caseInsensitiveCompare(jobID.uuidString) != .orderedSame {throw CyclesRenderError.protocolViolation("Cycles emitted an event for a different render job.")}
      let sample=message["sample"] as? Int ?? message["samples"] as? Int ?? 0
      switch type {
      case "progress":
        let fraction=message["progress"] as? Double ?? Double(sample)/Double(current.settings.samples)
        guard fraction.isFinite,(0...1).contains(fraction),sample>=0 else{throw CyclesRenderError.protocolViolation("Cycles progress values are invalid.")}
        var progress=CyclesRenderProgress(jobID:jobID,phase:message["phase"] as? String ?? message["status"] as? String ?? "rendering",sample:sample,totalSamples:message["totalSamples"] as? Int ?? current.settings.samples,fraction:fraction,elapsedSeconds:Date().timeIntervalSince(current.started))
        progress.device=message["device"] as? String;progress.fallbackReason=current.fallbackReason ?? message["fallbackReason"] as? String
        current.renderedSamples=max(current.renderedSamples,sample);active=current
        statuses[jobID]?.progress=progress;current.continuation.yield(.progress(progress))
      case "frame":
        current.renderedSamples=max(current.renderedSamples,sample);active=current
        let url=try outputURL(message["framePath"],in:current.directory)
        current.continuation.yield(.frame(.init(jobID:jobID,sourceRevision:current.revision,url:url,sample:sample>0 ? sample:statuses[jobID]?.progress?.sample ?? 0)))
      case "completed":
        let png=try outputURL(message["finalPNG"],in:current.directory),exr=try outputURL(message["finalEXR"],in:current.directory)
        guard let source=CGImageSourceCreateWithURL(png as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],properties[kCGImagePropertyPixelWidth] as? Int==current.settings.width,properties[kCGImagePropertyPixelHeight] as? Int==current.settings.height else {throw CyclesRenderError.protocolViolation("Cycles output dimensions differ from the requested render.")}
        let handle=try FileHandle(forReadingFrom:exr);defer{try? handle.close()}
        guard try handle.read(upToCount:4)==Data([0x76,0x2f,0x31,0x01]) else{throw CyclesRenderError.protocolViolation("Cycles did not produce a valid OpenEXR output.")}
        current.pendingResult = .init(jobID:jobID,sourceRevision:current.revision,pngURL:png,exrURL:exr,device:message["device"] as? String ?? "unknown",engineVersion:message["engineVersion"] as? String ?? "Cycles",samples:sample>0 ? sample:current.settings.samples,elapsedSeconds:Date().timeIntervalSince(current.started),width:current.settings.width,height:current.settings.height,fallbackReason:current.fallbackReason ?? message["fallbackReason"] as? String,denoiser:message["denoiser"] as? String ?? "unknown",preparationSeconds:message["preparationSeconds"] as? Double,renderSeconds:message["renderSeconds"] as? Double,denoiseSeconds:message["denoiseSeconds"] as? Double)
        active=current
      case "error":
        let reason=message["message"] as? String ?? "Cycles rendering failed."
        if current.settings.device == .auto,current.fallbackReason==nil,
          message["category"] as? String == "metalInitialization",message["device"] as? String == "metal",
          current.renderedSamples==0,current.pendingResult==nil {
          current.pendingMetalInitializationFailure=reason;active=current
        }else {throw CyclesRenderError.helperFailed(reason)}
      case "cancelled":cancel(jobID:jobID)
      default:throw CyclesRenderError.protocolViolation("Cycles emitted an unsupported event: \(type).")
      }
    }catch{fail(jobID:jobID,error:error)}
  }
  private func outputURL(_ value:Any?,in directory:URL)throws->URL {
    guard let path=value as? String,!path.isEmpty else{throw CyclesRenderError.protocolViolation("Cycles output is missing a file path.")}
    let url=(path.hasPrefix("/") ? URL(fileURLWithPath:path):directory.appendingPathComponent(path)).standardizedFileURL
    let root=directory.resolvingSymlinksInPath().path+"/",resolved=url.resolvingSymlinksInPath()
    guard resolved.path.hasPrefix(root),let values=try? resolved.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),values.isRegularFile==true,(values.fileSize ?? 0)>0,(values.fileSize ?? 0)<=2_147_483_648 else{throw CyclesRenderError.protocolViolation("Cycles output must be a regular file inside its job directory.")}
    return resolved
  }
  private func exited(jobID:UUID,processID:UUID,exitCode:Int32) {
    guard var current=active,current.id==jobID,current.process.id==processID else{return}
    if let reason=current.pendingMetalInitializationFailure {
      do {
        let manifest=current.directory.appendingPathComponent("manifest.json")
        guard var value=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any] else {throw CyclesRenderError.protocolViolation("Missing retry manifest.")}
        value["device"]="cpu"
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:manifest,options:.atomic)
        try? FileManager.default.moveItem(at:current.directory.appendingPathComponent("stderr.log"),to:current.directory.appendingPathComponent("metal-initialization.log"))
        current.fallbackReason="Metal initialization failed; rendering on CPU. "+reason
        current.pendingMetalInitializationFailure=nil
        current.process=try launch(manifest:manifest,directory:current.directory,jobID:jobID)
        active=current
        let progress=CyclesRenderProgress(jobID:jobID,phase:"Preparing CPU after Metal initialization failure",sample:0,totalSamples:current.settings.samples,fraction:0,elapsedSeconds:Date().timeIntervalSince(current.started),device:"cpu",fallbackReason:current.fallbackReason)
        statuses[jobID]?.progress=progress;current.continuation.yield(.progress(progress))
      }catch {fail(jobID:jobID,error:error)}
      return
    }
    guard exitCode==0,let result=current.pendingResult else {
      var message="Cycles stopped before completing its render (exit \(exitCode))."
      if let log=try? String(contentsOf:current.directory.appendingPathComponent("stderr.log"),encoding:.utf8),!log.isEmpty {message += " "+String(log.suffix(4096))}
      fail(jobID:jobID,error:CyclesRenderError.helperFailed(message));return
    }
    active=nil;statuses[jobID]?.state = .completed;statuses[jobID]?.result=result
    if current.settings.purpose != .final {lastPreviewDirectory=current.directory}
    current.continuation.yield(.completed(result));current.continuation.finish()
  }
  private func fail(jobID:UUID,error:Error) {
    guard let current=active,current.id==jobID else{return}
    active=nil;statuses[jobID]?.state = .failed;statuses[jobID]?.error=error.localizedDescription
    stop(current.process);current.continuation.finish(throwing:error)
    cleanupPreview(current.directory,after:current.process)
  }
}
