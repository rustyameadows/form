import AppKit
import CryptoKit
import Darwin
import ImageIO
import FormCore

/// An exclusive atomic directory commit exposes the verified image/record together.
/// fsync requests persistence; no claim is made about hardware power-loss durability.
enum StudioRenderFolder {
  enum Phase {case pngWritten,recordWritten,beforeRename}
  static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  static func write(png:Data,record:[String:Any],to destination:URL,hook:((Phase)throws->Void)?=nil)throws->URL {
    guard destination.pathExtension=="render",destination.isFileURL else{throw FormError.invalid("Choose a new .render folder for PNG + record.")}
    let fm=FileManager.default,parent=destination.deletingLastPathComponent()
    guard fm.fileExists(atPath:parent.path),!fm.fileExists(atPath:destination.path) else{throw FormError.invalid("The shot folder already exists or its parent is unavailable. Choose a new name.")}
    guard let source=CGImageSourceCreateWithData(png as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,record["png_sha256"] as? String==hash(png),record["width"] as? Int==width,record["height"] as? Int==height else {throw FormError.invalid("Rendered pixels and provenance do not agree.")}
    let data=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]),stage=parent.appendingPathComponent(".form-shot-\(UUID().uuidString).stage",isDirectory:true)
    try fm.createDirectory(at:stage,withIntermediateDirectories:false)
    defer {try? fm.removeItem(at:stage)}
    let name=destination.deletingPathExtension().lastPathComponent+".png",imageURL=stage.appendingPathComponent(name),recordURL=stage.appendingPathComponent("render.json")
    try png.write(to:imageURL);try hook?(.pngWritten)
    try data.write(to:recordURL);try hook?(.recordWritten)
    guard try Data(contentsOf:imageURL)==png,try Data(contentsOf:recordURL)==data else{throw FormError.invalid("Shot verification failed before delivery.")}
    try sync(imageURL,directory:false);try sync(recordURL,directory:false);try sync(stage,directory:true)
    try hook?(.beforeRename)
    let result=renameatx_np(AT_FDCWD,stage.path,AT_FDCWD,destination.path,UInt32(RENAME_EXCL))
    guard result==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSLocalizedDescriptionKey:"Could not exclusively deliver the shot folder; the destination was left unchanged."])}
    try? sync(parent,directory:true)
    return destination.appendingPathComponent(name)
  }
  private static func sync(_ url:URL,directory:Bool)throws {
    let fd=open(url.path,O_RDONLY);guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))};defer{close(fd)}
    if fsync(fd) != 0 && !(directory && [EINVAL,ENOTSUP].contains(errno)) {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
  }
}
