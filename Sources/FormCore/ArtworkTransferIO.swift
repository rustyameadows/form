import Darwin
import Foundation

public enum ArtworkTransferIO {
  /// Bounded descriptor-based read; neither the directory nor file's last path
  /// component may be a symlink. No image/profile decoding or file write occurs.
  public static func readAsset(directory:URL,name:String,limit:Int)throws->Data? {
    guard ArtworkTransferBundle.safeName(name),limit>=0,limit<=16*1024*1024 else{throw FormError.invalid("Invalid portable asset read budget/path.")}
    let directoryFD=directory.path.withCString{open($0,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)}
    guard directoryFD>=0 else{throw CocoaError(.fileReadUnknown)};defer{close(directoryFD)}
    return try readAsset(directoryDescriptor:directoryFD,name:name,limit:limit)
  }
  static func readAsset(directoryDescriptor directoryFD:Int32,name:String,limit:Int)throws->Data? {
    guard ArtworkTransferBundle.safeName(name),limit>=0,limit<=ArtworkTransferFile.maximumBytes else{throw FormError.invalid("Invalid portable asset read budget/path.")}
    let descriptor=name.withCString{openat(directoryFD,$0,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)}
    if descriptor<0 {if errno==ENOENT {return nil};throw CocoaError(.fileReadUnknown)}
    let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer{try? handle.close()}
    var info=stat();guard fstat(descriptor,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_size>=0,info.st_size<=limit else{throw CocoaError(.fileReadTooLarge)}
    let data=try handle.read(upToCount:limit+1) ?? Data();guard data.count<=limit else{throw CocoaError(.fileReadTooLarge)};return data
  }
}
