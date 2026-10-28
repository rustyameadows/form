import Darwin
import Foundation

public enum ArtworkTransferFile {
  public static let maximumBytes=12+2*1024*1024+32*1024*1024
  public static func read(_ url:URL)throws->Data {
    guard url.isFileURL,url.path.hasPrefix("/") else{throw FormError.invalid("Choose an absolute local transfer file.")}
    let descriptor=url.path.withCString{open($0,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)}
    guard descriptor>=0 else{throw CocoaError(.fileReadUnknown)}
    let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer{try? handle.close()}
    var info=stat();guard fstat(descriptor,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_size>=12,info.st_size<=maximumBytes else{throw FormError.invalid("Choose a regular portable transfer file within the 34 MiB wire budget.")}
    let data=try handle.read(upToCount:maximumBytes+1) ?? Data();guard data.count<=maximumBytes else{throw FormError.invalid("Portable transfer file exceeds its wire budget.")};return data
  }
  public static func writeNew(_ data:Data,to url:URL)throws {
    guard url.isFileURL,url.path.hasPrefix("/"),url.pathExtension.lowercased()=="formart",data.count<=maximumBytes,ArtworkTransferBundle.safeName(url.lastPathComponent) else{throw FormError.invalid("Choose a safe absolute local transfer output path.")}
    var limits=ArtworkTransferLimits();limits.individualAssetBytes=maximumBytes;limits.totalAssetBytes=maximumBytes;limits.assets=1
    let stage=try ArtworkTransferPublication.prepare(directory:url.deletingLastPathComponent(),blobs:[url.lastPathComponent:data],limits:limits,journalPrefix:url.deletingLastPathComponent().path)
    do {try stage.publish([url.lastPathComponent:data],reuseExisting:false);stage.finish("export_committed")}catch{throw stage.failure(error)}
  }
}
