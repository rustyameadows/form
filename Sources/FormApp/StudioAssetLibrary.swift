import AppKit
import Combine
import CryptoKit
import FormCore
import ImageIO

enum StudioAssetKind:String,Codable,CaseIterable,Sendable {
  case image,vector,pdf,video,model,file
  var title:String {switch self {case .image:return "Image";case .vector:return "Vector";case .pdf:return "PDF";case .video:return "Video";case .model:return "3D model";case .file:return "File"}}
  var symbol:String {switch self {case .image:return "photo";case .vector:return "square.on.circle";case .pdf:return "doc.richtext";case .video:return "film";case .model:return "cube";case .file:return "doc"}}
  static func infer(_ filename:String)->Self {
    switch URL(fileURLWithPath:filename).pathExtension.lowercased() {
    case "png","jpg","jpeg","tif","tiff","heic","heif","gif","bmp","webp":return .image
    case "svg":return .vector
    case "pdf":return .pdf
    case "mp4","mov","m4v","webm":return .video
    case "glb","gltf","obj","stl","usdz","step","stp","brep":return .model
    default:return .file
    }
  }
}
enum StudioAssetOrigin:String,Codable,CaseIterable,Sendable {case uploaded,generated,exported
  var title:String {rawValue.capitalized}
}
struct StudioAssetMetadata:Codable,Equatable,Sendable {
  var kind:StudioAssetKind
  var origin:StudioAssetOrigin
  var projectID:UUID?,projectName:String?,sceneID:UUID?,generationID:UUID?
  var isMock:Bool
  var sourceAssetIDs:[UUID]
  var prompt:String?,provider:String?,options:[String:String]?
  init(kind:StudioAssetKind,origin:StudioAssetOrigin,projectID:UUID?=nil,projectName:String?=nil,
       sceneID:UUID?=nil,generationID:UUID?=nil,isMock:Bool=false,sourceAssetIDs:[UUID]=[],
       prompt:String?=nil,provider:String?=nil,options:[String:String]?=nil) {
    self.kind=kind;self.origin=origin;self.projectID=projectID;self.projectName=projectName
    self.sceneID=sceneID;self.generationID=generationID;self.isMock=isMock;self.sourceAssetIDs=sourceAssetIDs
    self.prompt=prompt;self.provider=provider;self.options=options
  }
  func validate()throws {
    guard (projectName?.count ?? 0)<=500,(prompt?.count ?? 0)<=20_000,(provider?.count ?? 0)<=200,
      sourceAssetIDs.count<=256,Set(sourceAssetIDs).count==sourceAssetIDs.count,
      (options?.count ?? 0)<=64,options?.allSatisfy({$0.key.count<=128 && $0.value.count<=4000}) != false else {
      throw FormError.invalid("Keep asset provenance bounded, with unique source IDs and no more than 64 options.")
    }
  }
}
struct StudioAsset:Codable,Equatable,Identifiable,Sendable {
  enum Storage:String,Codable,Sendable {case owned,projectReference}
  var id:UUID,name:String,filename:String,relativePath:String,storage:Storage
  var metadata:StudioAssetMetadata
  var createdAt:Date,modifiedAt:Date,byteCount:Int64,sha256:String?
  var favorite=false
  var archivedAt:Date?
  var isMissing=false
  var kind:StudioAssetKind {metadata.kind}
  var origin:StudioAssetOrigin {metadata.origin}
  var isMock:Bool {metadata.isMock}
}
struct StudioAssetScanLimits:Sendable {
  var projects=200,files=4000,hashBytes:Int64=256*1024*1024,manifestBytes:Int64=8*1024*1024
}
struct StudioAssetRegistration:Sendable {
  let data:Data,filename:String,name:String?,metadata:StudioAssetMetadata
  init(data:Data,filename:String,name:String?=nil,metadata:StudioAssetMetadata) {
    self.data=data;self.filename=filename;self.name=name;self.metadata=metadata
  }
}

/// This index contains references and owned copies, never mutable project data.
private struct StudioAssetDisk:Sendable {
  struct Index:Codable {var version=1;var items:[StudioAsset]}
  struct Scan:Sendable {var found:[StudioAsset];var missing:[UUID:Bool];var notice:String?}
  let root:URL
  var index:URL {root.appendingPathComponent("StudioAssets/Index.json")}
  static let maximumOwnedBytes=64*1024*1024
  static func referenceProjectID(_ relativePath:String)->UUID? {
    guard let package=relativePath.split(separator:"/").first,package.hasSuffix(".form") else{return nil}
    return UUID(uuidString:String(package.dropLast(5)))
  }
  private func validateIndexLocation()throws {
    let base=root.standardizedFileURL.resolvingSymlinksInPath()
    guard index.resolvingSymlinksInPath().path.hasPrefix(base.path+"/") else{throw FormError.invalid("The asset index must remain inside this Library.")}
    do {
      let attributes=try FileManager.default.attributesOfItem(atPath:index.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {throw FormError.invalid("The asset index must be a regular file. The existing item was kept.")}
    }catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {}
  }
  func resolve(_ asset:StudioAsset)throws->URL {
    let parts=asset.relativePath.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
    guard !parts.isEmpty,parts.count<=14,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && $0.utf8.count<=255}) else {throw FormError.invalid("Invalid asset path in Library index.")}
    switch asset.storage {
    case .owned:
      guard parts.count==4,parts[0]=="StudioAssets",parts[1]=="Files",parts[2]==asset.id.uuidString,parts[3]==asset.filename else {throw FormError.invalid("Owned assets must remain in their own Library folder.")}
    case .projectReference:
      guard parts.count>=3,Self.referenceProjectID(asset.relativePath) != nil,["Assets","Exports"].contains(parts[1]) else {throw FormError.invalid("Project asset references must stay inside Assets or Exports.")}
    }
    let base=root.standardizedFileURL.resolvingSymlinksInPath(),url=base.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(base.path+"/") else {throw FormError.invalid("Asset reference escapes this Library.")}
    return url
  }
  func load()throws->[StudioAsset] {
    guard FileManager.default.fileExists(atPath:index.path) else{return []}
    try validateIndexLocation()
    let size=(try FileManager.default.attributesOfItem(atPath:index.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size<=16*1024*1024 else{throw FormError.invalid("Asset index exceeds its 16 MiB limit.")}
    let value=try JSONDecoder().decode(Index.self,from:Data(contentsOf:index))
    guard value.version==1 else{throw FormError.invalid("Unsupported asset Library index.")}
    try validateRecords(value.items)
    return value.items
  }
  private func validateRecords(_ items:[StudioAsset])throws {
    guard items.count<=6000,Set(items.map(\.id)).count==items.count else{throw FormError.invalid("The Library supports up to 6000 uniquely identified assets.")}
    for item in items {
      try item.metadata.validate();_ = try resolve(item)
      guard !item.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,item.name.count<=240,item.byteCount>=0,
        item.relativePath.split(separator:"/").last.map(String.init)==item.filename,
        item.sha256.map({$0.count==64 && $0.allSatisfy{$0.isHexDigit}}) ?? true else {throw FormError.invalid("Invalid asset metadata in Library index.")}
    }
  }
  func save(_ items:[StudioAsset])throws {
    try validateRecords(items)
    try validateIndexLocation()
    let estimated=items.reduce(0){total,item in
      return total+1024+item.name.utf8.count+item.relativePath.utf8.count+(item.metadata.prompt?.utf8.count ?? 0) +
        (item.metadata.options?.reduce(0){$0+$1.key.utf8.count+$1.value.utf8.count} ?? 0)
    }
    guard estimated<=12*1024*1024 else{throw FormError.invalid("The asset index is full. Keep long generation records in generation history.")}
    try FileManager.default.createDirectory(at:index.deletingLastPathComponent(),withIntermediateDirectories:true)
    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    let data=try encoder.encode(Index(items:items))
    guard data.count<=16*1024*1024 else{throw FormError.invalid("The asset index exceeds its 16 MiB limit.")}
    try data.write(to:index,options:.atomic)
  }
  static func fileHash(_ url:URL)throws->String {
    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
    var hash=SHA256()
    while let chunk=try file.read(upToCount:1024*1024),!chunk.isEmpty {try Task.checkCancellation();hash.update(data:chunk)}
    return hash.finalize().map{String(format:"%02x",$0)}.joined()
  }
  static func referenceID(_ path:String)->UUID {
    let b=Array(SHA256.hash(data:Data(path.utf8)).prefix(16))
    return .init(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
  }
  func scan(previous:[StudioAsset],limits:StudioAssetScanLimits,projectID requestedProjectID:UUID?=nil)throws->Scan {
    let fm=FileManager.default,base=root.standardizedFileURL.resolvingSymlinksInPath()
    let known=Dictionary(uniqueKeysWithValues:previous.map{($0.id,$0)})
    var missing=[UUID:Bool](),found=[StudioAsset](),scanned=0,hashed:Int64=0,limited=false
    for item in previous {try Task.checkCancellation();missing[item.id]=(try? resolve(item)).map{!fm.fileExists(atPath:$0.path)} ?? true}
    let projects:[URL]
    if let requestedProjectID {
      let target=base.appendingPathComponent(requestedProjectID.uuidString+".form",isDirectory:true)
      projects=fm.fileExists(atPath:target.path) ? [target]:[]
    }else {
      projects=try fm.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isDirectoryKey],options:.skipsHiddenFiles)
        .filter{$0.pathExtension=="form"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
    }
    if projects.count>limits.projects {limited=true}
    projectLoop:for project in projects.prefix(max(0,limits.projects)) {
      try Task.checkCancellation()
      let manifest=project.appendingPathComponent("Manifest.json")
      guard project.resolvingSymlinksInPath().path.hasPrefix(base.path+"/"),manifest.resolvingSymlinksInPath().path.hasPrefix(base.path+"/") else{continue}
      let dataSize=(try? fm.attributesOfItem(atPath:manifest.path)[.size] as? NSNumber)?.int64Value ?? 0
      guard dataSize<=limits.manifestBytes,let data=try? Data(contentsOf:manifest),
        let raw=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let metadata=raw["project"] as? [String:Any],
        let textID=metadata["id"] as? String,let projectID=UUID(uuidString:textID) else{continue}
      guard requestedProjectID==nil || requestedProjectID==projectID else{continue}
      let name=String((metadata["name"] as? String ?? "Untitled project").prefix(500))
      for folder in ["Assets","Exports"] {
        let directory=project.appendingPathComponent(folder)
        guard let enumerator=fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.creationDateKey],options:.skipsHiddenFiles) else{continue}
        for case let file as URL in enumerator {
          try Task.checkCancellation();scanned+=1
          if scanned>limits.files {limited=true;break projectLoop}
          // Foundation can enumerate /private/tmp while resolving the same root to /tmp.
          // Derive both sides of the relative path from the same canonical coordinates.
          let canonical=file.standardizedFileURL.resolvingSymlinksInPath()
          guard canonical.path.hasPrefix(base.path+"/") else{enumerator.skipDescendants();continue}
          let relative=String(canonical.path.dropFirst(base.path.count+1))
          guard requestedProjectID==nil || Self.referenceProjectID(relative)==requestedProjectID else{enumerator.skipDescendants();continue}
          if relative.split(separator:"/").count>12 || ["cache","caches","thumbnails","tmp","temp","staging"].contains(file.lastPathComponent.lowercased()) {enumerator.skipDescendants();continue}
          guard !["json","plist","lock","tmp"].contains(file.pathExtension.lowercased()),let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.creationDateKey]),values.isRegularFile==true,values.isSymbolicLink != true else{continue}
          let id=Self.referenceID(relative),date=values.contentModificationDate ?? Date.distantPast,size=Int64(values.fileSize ?? 0)
          let title=String(file.deletingPathExtension().lastPathComponent.trimmingCharacters(in:.whitespacesAndNewlines).prefix(240))
          var item=StudioAsset(id:id,name:title.isEmpty ? StudioAssetKind.infer(file.lastPathComponent).title:title,filename:file.lastPathComponent,relativePath:relative,storage:.projectReference,
            metadata:.init(kind:.infer(file.lastPathComponent),origin:folder=="Exports" ? .exported:.uploaded,projectID:projectID,projectName:name),
            createdAt:values.creationDate ?? date,modifiedAt:date,byteCount:size,sha256:nil)
          guard (try? resolve(item)) != nil else{continue}
          if let old=known[id],old.byteCount==size,old.modifiedAt==date {item.sha256=old.sha256}
          if item.sha256==nil,size<=StudioAssetDisk.maximumOwnedBytes,hashed+size<=limits.hashBytes {
            item.sha256=try? Self.fileHash(file);hashed+=size
          }
          if folder=="Exports" {
            let record=file.deletingLastPathComponent().appendingPathComponent("render.json")
            if record.resolvingSymlinksInPath().path.hasPrefix(base.path+"/"),let attributes=try? fm.attributesOfItem(atPath:record.path),((attributes[.size] as? NSNumber)?.intValue ?? Int.max)<=2*1024*1024,
              let bytes=try? Data(contentsOf:record),let proof=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] {
              var provenance=item.metadata
              provenance.sceneID=((proof["scene"] as? [String:Any])?["id"] as? String).flatMap(UUID.init(uuidString:))
              provenance.provider=proof["application"] as? String
              provenance.isMock=proof["isMock"] as? Bool ?? false
              if let renderer=proof["renderer"] as? String {provenance.options=["renderer":renderer]}
              // An optional record must not poison an otherwise valid media reference.
              if (try? provenance.validate()) != nil {item.metadata=provenance}
            }
          }
          found.append(item);missing[id]=false
        }
      }
    }
    return .init(found:found,missing:missing,notice:limited ? "Showing a bounded Library scan. Narrow the project library or refresh after moving older files out of it.":nil)
  }
}

@MainActor final class StudioAssetLibrary:ObservableObject {
  let root:URL
  /// Immutable for the lifetime of an instance. Production always supplies the
  /// current project; nil retains the low-level unscoped index API.
  let projectID:UUID?
  @Published private(set) var items=[StudioAsset]()
  @Published private(set) var isLoading=false
  @Published private(set) var issue:String?
  private let disk:StudioAssetDisk,limits:StudioAssetScanLimits
  private var corruptIndex=false,refreshGeneration=UUID()
  private let thumbnails=NSCache<NSString,NSImage>()
  init(root:URL,projectID:UUID?=nil,limits:StudioAssetScanLimits = .init()) {
    self.root=root.standardizedFileURL;self.projectID=projectID;disk = .init(root:root);self.limits=limits
    thumbnails.countLimit=80;thumbnails.totalCostLimit=48*1024*1024
    do {items=try disk.load().filter(includes)}catch {corruptIndex=true;issue="Library index could not be read: "+error.localizedDescription}
  }
  private func includes(_ asset:StudioAsset)->Bool {
    guard let projectID else{return true}
    guard asset.metadata.projectID==projectID else{return false}
    if asset.storage == .projectReference {
      return StudioAssetDisk.referenceProjectID(asset.relativePath)==projectID
    }
    return true
  }
  private func scopedMetadata(_ value:StudioAssetMetadata)throws->StudioAssetMetadata {
    guard let projectID else{return value}
    guard value.projectID==nil || value.projectID==projectID else{throw FormError.invalid("This asset belongs to another project's Library.")}
    guard value.sourceAssetIDs.allSatisfy({asset(id:$0) != nil}) else{throw FormError.invalid("Use references from the current project's Library.")}
    var result=value;result.projectID=projectID;return result
  }
  var visibleItems:[StudioAsset] {items.filter{$0.archivedAt==nil}.sorted{$0.createdAt>$1.createdAt}}
  func asset(id:UUID)->StudioAsset? {items.first{$0.id==id}}
  func fileURL(for asset:StudioAsset)throws->URL {
    if projectID != nil {
      guard includes(asset),let accepted=self.asset(id:asset.id),accepted.relativePath==asset.relativePath,
        accepted.storage==asset.storage,accepted.filename==asset.filename else{throw FormError.missing("This asset is not in the current project's Library.")}
    }
    let url=try disk.resolve(asset)
    if let projectID {
      let base=root.standardizedFileURL.resolvingSymlinksInPath()
      if asset.storage == .projectReference {
        let relative=String(url.path.dropFirst(base.path.count+1))
        guard StudioAssetDisk.referenceProjectID(relative)==projectID else{throw FormError.invalid("This reference resolves to another project's package.")}
      }else {
        guard url.path==base.appendingPathComponent(asset.relativePath).path else{throw FormError.invalid("Owned Library files must remain in their own asset folder.")}
      }
    }
    guard FileManager.default.fileExists(atPath:url.path) else{throw FormError.missing("This asset's original file is missing. Its Library metadata was kept.")}
    return url
  }
  private func write(_ values:[StudioAsset])throws {
    guard !corruptIndex else{throw FormError.invalid("Repair or restore the existing Library index before changing assets. Its original bytes were kept.")}
    guard values.allSatisfy(includes) else{throw FormError.invalid("Only the current project's Library can be changed.")}
    // Read the accepted shared index at the commit boundary: an older scoped
    // instance must never erase another project's newer imports or metadata.
    let latest=try disk.load(),before=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
    let latestByID=Dictionary(uniqueKeysWithValues:latest.map{($0.id,$0)})
    var merged=latestByID
    var order=latest.map(\.id)
    for value in values where before[value.id] != value || merged[value.id]==nil {
      if let existing=merged[value.id],!includes(existing) {throw FormError.invalid("An asset identifier belongs to another project's Library.")}
      if merged[value.id]==nil {order.append(value.id)}
      merged[value.id]=value
    }
    guard merged != latestByID else{items=latest.filter(includes);return}
    let accepted=order.compactMap{merged[$0]}
    try disk.save(accepted);items=accepted.filter(includes)
  }
  func refresh()async {
    guard !corruptIndex else{return}
    let token=UUID();refreshGeneration=token;isLoading=true
    defer {if refreshGeneration==token {isLoading=false}}
    let disk=self.disk,previous=items,limits=self.limits,projectID=self.projectID
    do {
      let worker=Task.detached(priority:.utility){try disk.scan(previous:previous,limits:limits,projectID:projectID)}
      let scan=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
      guard refreshGeneration==token,!Task.isCancelled else{return}
      var current=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
      for item in scan.found {
        var next=item
        if let old=current[item.id] {next.name=old.name;next.favorite=old.favorite;next.archivedAt=old.archivedAt}
        current[item.id]=next
      }
      for (id,missing) in scan.missing {if current[id] != nil {current[id]!.isMissing=missing}}
      try write(current.values.sorted{$0.id.uuidString<$1.id.uuidString});issue=scan.notice
    }catch is CancellationError {}catch {if refreshGeneration==token {issue=error.localizedDescription}}
  }
  @discardableResult func register(data:Data,filename:String,name:String?=nil,metadata:StudioAssetMetadata)throws->StudioAsset {
    try registerBatch([.init(data:data,filename:filename,name:name,metadata:metadata)])[0]
  }
  @discardableResult func registerBatch(_ values:[StudioAssetRegistration])throws->[StudioAsset] {
    guard !corruptIndex,(1...8).contains(values.count),values.reduce(0,{$0+$1.data.count})<=128*1024*1024 else {
      throw FormError.invalid("Publish 1–8 assets totaling at most 128 MiB, with a readable Library index.")
    }
    var assets=[StudioAsset](),urls=[URL]()
    for value in values {
      let filename=value.filename
      guard !value.data.isEmpty,value.data.count<=StudioAssetDisk.maximumOwnedBytes,
        filename==URL(fileURLWithPath:filename).lastPathComponent,!filename.isEmpty,filename.utf8.count<=240,
        !filename.contains("\\"),!filename.contains("\0"),filename != ".",filename != ".." else {throw FormError.invalid("Choose a local filename and a nonempty asset no larger than 64 MiB.")}
      let metadata=try scopedMetadata(value.metadata)
      try metadata.validate()
      let title=(value.name ?? URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent).trimmingCharacters(in:.whitespacesAndNewlines)
      guard !title.isEmpty,title.count<=240 else{throw FormError.invalid("Use an asset name of 1–240 characters.")}
      let id=UUID(),date=Date(),hash=SHA256.hash(data:value.data).map{String(format:"%02x",$0)}.joined()
      let asset=StudioAsset(id:id,name:title,filename:filename,relativePath:"StudioAssets/Files/\(id.uuidString)/\(filename)",storage:.owned,metadata:metadata,createdAt:date,modifiedAt:date,byteCount:Int64(value.data.count),sha256:hash)
      assets.append(asset);urls.append(try disk.resolve(asset))
    }
    var created=[URL]()
    do {
      for (value,url) in zip(values,urls) {
        let folder=url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath:folder.path) else{throw FormError.invalid("A new asset destination already exists.")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);created.append(folder)
        try value.data.write(to:url,options:.withoutOverwriting)
      }
      try write(items+assets)
    }catch {for folder in created {try? FileManager.default.removeItem(at:folder)};throw error}
    return assets
  }
  @discardableResult func importFile(_ url:URL,metadata:StudioAssetMetadata?=nil)async throws->StudioAsset {
    let metadata=try scopedMetadata(metadata ?? .init(kind:.infer(url.lastPathComponent),origin:.uploaded))
    let data=try await Task.detached(priority:.utility) {
      let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
      guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=StudioAssetDisk.maximumOwnedBytes else{throw FormError.invalid("Import a regular local file no larger than 64 MiB.")}
      try Task.checkCancellation();return try Data(contentsOf:url)
    }.value
    try Task.checkCancellation()
    return try register(data:data,filename:url.lastPathComponent,metadata:metadata)
  }
  func rename(_ id:UUID,to name:String)throws {
    let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !value.isEmpty,value.count<=240 else{throw FormError.invalid("Use an asset name of 1–240 characters.")}
    var next=items;guard let index=next.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Asset not found.")}
    next[index].name=value;try write(next)
  }
  func setFavorite(_ id:UUID,_ value:Bool)throws {
    var next=items;guard let index=next.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Asset not found.")}
    next[index].favorite=value;try write(next)
  }
  func archive(_ id:UUID)throws {
    var next=items;guard let index=next.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Asset not found.")}
    next[index].archivedAt=Date();try write(next)
  }
  func saveCopy(_ id:UUID,to destination:URL,replaceExisting:Bool=false)throws {
    guard let item=asset(id:id) else{throw FormError.missing("Asset not found.")}
    let source=try fileURL(for:item),fm=FileManager.default
    let sourceIdentity=(try? source.resourceValues(forKeys:[.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject
    let targetIdentity=(try? destination.resourceValues(forKeys:[.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject
    let sameFile:Bool
    if let sourceIdentity,let targetIdentity {sameFile=sourceIdentity.isEqual(targetIdentity)}else{sameFile=false}
    guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath(),
      !sameFile else {throw FormError.invalid("Choose another location for the copy; the Library original is never replaced.")}
    guard replaceExisting else{try fm.copyItem(at:source,to:destination);return}
    if fm.fileExists(atPath:destination.path) {
      guard (try destination.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true else{throw FormError.invalid("Choose a regular file destination for the copy.")}
      let staged=destination.deletingLastPathComponent().appendingPathComponent(".lab-asset-copy-"+UUID().uuidString)
      defer {try? fm.removeItem(at:staged)}
      try fm.copyItem(at:source,to:staged)
      _ = try fm.replaceItemAt(destination,withItemAt:staged)
    }else {try fm.copyItem(at:source,to:destination)}
  }
  func thumbnail(for asset:StudioAsset,maxPixelSize:Int=240)async->NSImage? {
    guard asset.byteCount<=StudioAssetDisk.maximumOwnedBytes,let url=try? fileURL(for:asset) else{return nil}
    let size=max(32,min(1600,maxPixelSize)),key="\(asset.id)-\(asset.sha256 ?? String(asset.modifiedAt.timeIntervalSince1970))-\(size)" as NSString
    if let cached=thumbnails.object(forKey:key) {return cached}
    let image:CGImage?=await Task.detached(priority:.utility) {
      if asset.kind == .image,let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:size,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) {
        return image
      }
      if asset.kind == .pdf,let document=CGPDFDocument(url as CFURL),let page=document.page(at:1) {
        let bounds=page.getBoxRect(.mediaBox),factor=Double(size)/max(1,max(bounds.width,bounds.height))
        let width=max(1,Int(bounds.width*factor)),height=max(1,Int(bounds.height*factor))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(.init(x:0,y:0,width:width,height:height));context.scaleBy(x:factor,y:factor);context.translateBy(x:-bounds.minX,y:-bounds.minY);context.drawPDFPage(page)
        return context.makeImage()
      }
      return nil
    }.value
    guard !Task.isCancelled,let image else{return nil}
    let result=NSImage(cgImage:image,size:.init(width:image.width,height:image.height))
    thumbnails.setObject(result,forKey:key,cost:image.width*image.height*4);return result
  }
}
