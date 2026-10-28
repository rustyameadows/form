import AppKit
import CryptoKit
import FormCore
import FormGraphics
import SwiftUI

/// A Home-only, disposable diagram style. Never used for editor/physical output.
@MainActor enum HomeTechnicalInk {
  nonisolated static let version=1
  static let size=CGSize(width:1000,height:650)
  struct Limits {var maximumElements=256,maximumOutlines=128,maximumNodes=128,maximumDepth=16,maximumWork=50_000}
  struct Result {var composition:ProjectPreview.CanvasComposition?;var work:Int;var reason:String}
  private enum Declined:Error {case unsupported,budget}
  private final class Work {
    var used=0;let limit:Int
    init(_ limit:Int){self.limit=max(0,limit)}
    func spend(_ n:Int=1)throws {guard n>=0,n<=limit-used else{throw Declined.budget};used+=n}
  }
  static func evaluate(_ source:Artwork,limits:Limits = .init())->Result {
    let work=Work(limits.maximumWork)
    do {
      guard !source.elements.isEmpty,source.elements.count<=limits.maximumElements,source.boundary==nil else{throw Declined.unsupported}
      try work.spend(source.elements.count)
      guard Set(source.elements.map(\.id)).count==source.elements.count else{throw Declined.unsupported}
      let byID=Dictionary(uniqueKeysWithValues:source.elements.map{($0.id,$0)}),children=Dictionary(grouping:source.elements,by:\.parentID)
      var worlds=[UUID:Affine2](),visiting=Set<UUID>(),leaves=[ArtworkElement](),scales=[UUID:Double](),boxes=[UUID:Rect2](),minimumEdges=[UUID:Double]()
      func world(_ id:UUID,_ depth:Int=0)throws->Affine2 {
        try work.spend();guard depth<=limits.maximumDepth else{throw Declined.unsupported}
        if let value=worlds[id] {return value}
        guard let e=byID[id],visiting.insert(id).inserted else{throw Declined.unsupported};defer{visiting.remove(id)}
        var value=e.localTransform
        if let parent=e.parentID {value=try world(parent,depth+1).followed(by:value)}
        guard [value.a,value.b,value.c,value.d,value.tx,value.ty].allSatisfy(\.isFinite) else{throw Declined.unsupported}
        worlds[id]=value;return value
      }
      for e in source.elements {
        try work.spend()
        guard [e.x,e.y,e.width,e.height].allSatisfy(\.isFinite),e.width>0,e.height>0,
          e.hidden != true,(e.opacity ?? 1)==1,(e.blendMode ?? "normal")=="normal",e.isolatedBlending != true,
          !e.hasActiveEffects,e.clipID==nil,e.booleanOperation==nil,e.component==nil,e.gradient==nil,
          e.fillSwatchID==nil,e.typography==nil,e.textRuns==nil,e.textStyle==nil,e.paragraphStyle==nil,
          e.productionRole==nil || e.productionRole=="print" else{throw Declined.unsupported}
        let m=try world(e.id),sx=hypot(m.a,m.b),sy=hypot(m.c,m.d)
        guard (1e-6...1e6).contains(sx),abs(sx-sy)<=1e-8*max(sx,sy),abs(m.a*m.c+m.b*m.d)<=1e-8*sx*sy else{throw Declined.unsupported}
        if e.kind=="group" {guard !(children[e.id] ?? []).isEmpty else{throw Declined.unsupported};continue}
        guard e.kind=="path",e.sewingPiece != nil,e.fillEnabled==false,let stroke=e.visibleStroke,
          stroke.width.isFinite,stroke.width>0,(stroke.opacity ?? 1)==1,(stroke.alignment ?? "center")=="center",
          stroke.swatchID==nil,stroke.dash?.isEmpty != false,
          let path=e.path,path.width.isFinite,path.height.isFinite,path.width>0,path.height>0,
          path.contours.count==1,let contour=path.contours.first,contour.closed,
          (3...limits.maximumNodes).contains(contour.nodes.count),leaves.count<limits.maximumOutlines else{throw Declined.unsupported}
        try work.spend(contour.nodes.count)
        var points=[Point2]()
        for node in contour.nodes {
          guard node.incoming==nil,node.outgoing==nil,node.anchor.x.isFinite,node.anchor.y.isFinite else{throw Declined.unsupported}
          let p=m.apply(.init(node.anchor.x*e.width/path.width,node.anchor.y*e.height/path.height))
          guard p.x.isFinite,p.y.isFinite,abs(p.x)<=10_000_000,abs(p.y)<=10_000_000 else{throw Declined.unsupported};points.append(p)
        }
        var sign=0.0,turn=0.0,minimumEdge=Double.infinity
        for i in points.indices {
          try work.spend()
          let p=points[(i+points.count-1)%points.count],q=points[i],r=points[(i+1)%points.count]
          let ax=q.x-p.x,ay=q.y-p.y,bx=r.x-q.x,by=r.y-q.y
          let edgeLength=hypot(ax,ay);guard edgeLength>1e-8,hypot(bx,by)>1e-8 else{throw Declined.unsupported}
          minimumEdge=min(minimumEdge,edgeLength)
          let angle=atan2(ax*by-ay*bx,ax*bx+ay*by)
          guard abs(angle)>1e-7,abs(angle)<=3*Double.pi/4+1e-8 else{throw Declined.unsupported}
          if sign==0 {sign=angle>0 ? 1:-1};guard angle*sign>0 else{throw Declined.unsupported};turn+=angle
        }
        guard abs(abs(turn)-2*Double.pi)<1e-6 else{throw Declined.unsupported}
        let xs=points.map(\.x),ys=points.map(\.y)
        boxes[e.id] = .init(xs.min()!,ys.min()!,xs.max()!-xs.min()!,ys.max()!-ys.min()!)
        scales[e.id]=sx;minimumEdges[e.id]=minimumEdge;leaves.append(e)
      }
      guard !leaves.isEmpty else{throw Declined.unsupported}
      // Framing is calculated with original physical widths before any display ink.
      var composition=ProjectPreview.canvasComposition(artwork:source,size:size)
      guard composition.density.isFinite,composition.density>0 else{throw Declined.unsupported}
      let floor=1.0/composition.density
      var expanded=[Rect2](),widths=[UUID:Double](),changed=false
      for e in leaves {
        try work.spend();let b=boxes[e.id]!,s=scales[e.id]!,stroke=e.visibleStroke!
        guard min(b.width,b.height,minimumEdges[e.id]!)*composition.density>=3 else{throw Declined.unsupported}
        let target=max(stroke.width,floor/s)
        guard target.isFinite,target<=10_000 else{throw Declined.unsupported}
        changed = changed || target>stroke.width
        widths[e.id]=target
        // At >=45-degree interior corners, twice the stroke covers miter overflow.
        let pad=2*target*s;expanded.append(.init(b.x-pad,b.y-pad,b.width+2*pad,b.height+2*pad))
      }
      guard changed else{return .init(composition:nil,work:work.used,reason:"already-legible")}
      for i in expanded.indices {for j in expanded.indices where j>i {
        try work.spend();let a=expanded[i],b=expanded[j]
        guard min(a.maxX,b.maxX)<=max(a.x,b.x) || min(a.maxY,b.maxY)<=max(a.y,b.y) else{throw Declined.unsupported}
      }}
      for i in composition.artwork.elements.indices {
        try work.spend();if let width=widths[composition.artwork.elements[i].id] {composition.artwork.elements[i].stroke?.width=width}
      }
      return .init(composition:composition,work:work.used,reason:"enhanced")
    }catch Declined.budget{return .init(composition:nil,work:work.used,reason:"work-budget")}
    catch{return .init(composition:nil,work:work.used,reason:"unsupported")}
  }
}

/// Read-only active-source loading and a small image-only LRU. Disk previews stay intact.
@MainActor final class HomeTechnicalPreview {
  static let shared=HomeTechnicalPreview()
  nonisolated static let maximumSourceBytes=2*1024*1024
  struct Snapshot:Sendable {var id:UUID;var data:Data;var key:String;var bytes:Int}
  private struct CanvasSource:Decodable {var id:UUID;var recipeID:String;var canvasWorkspace:Bool?;var artworkSourceID:UUID?;var artwork:Artwork?}
  private struct Entry {var projectID:UUID;var image:NSImage?;var cost:Int}
  private struct Pending {var requests=Set<UUID>();var newestCompleted=0}
  private var entries=[String:Entry](),order=[String](),pending=[UUID:Pending](),sequence=0
  private let readSnapshot:@Sendable (ProjectSummary) async throws -> Snapshot
  init(readSnapshot:@escaping @Sendable (ProjectSummary) async throws -> Snapshot = {summary in try await HomeTechnicalSourceReader.shared.snapshot(summary)}) {self.readSnapshot=readSnapshot}
  private(set) var hits=0,renders=0,lastWork=0,lastSourceBytes=0,lastReason="",maximumColdMs=0.0,maximumWarmMs=0.0,maximumMainMs=0.0
  var retainedBytes:Int {entries.values.reduce(0){$0+$1.cost}}
  var count:Int {entries.count}
  func clear(){entries=[:];order=[];pending=[:]}
  func retain(projectIDs:Set<UUID>){pending=pending.filter{projectIDs.contains($0.key)};for key in order where entries[key].map({!projectIDs.contains($0.projectID)}) ?? true {entries.removeValue(forKey:key)};order.removeAll{entries[$0]==nil}}
  private func removeCached(_ id:UUID){for key in order where entries[key]?.projectID==id {entries.removeValue(forKey:key)};order.removeAll{entries[$0]==nil}}
  func discard(_ id:UUID){pending.removeValue(forKey:id);removeCached(id)}
  nonisolated private static func bounded(_ url:URL,limit:Int)throws->Data {
    guard limit>=0 else{throw CocoaError(.fileReadTooLarge)}
    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
    guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=limit else{throw CocoaError(.fileReadTooLarge)}
    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
    let data=try file.read(upToCount:limit+1) ?? Data();guard data.count<=limit else{throw CocoaError(.fileReadTooLarge)};return data
  }
  nonisolated static func snapshot(_ summary:ProjectSummary,afterActiveRead:(()throws->Void)?=nil)throws->Snapshot {
    let url=summary.url,manifestURL=url.appendingPathComponent("Manifest.json")
    // The small manifest is bounded before its minimal reference parse. Aggregate
    // active bytes are then bounded before object/Artwork decoding.
    let manifest=try bounded(manifestURL,limit:maximumSourceBytes)
    guard let raw=try JSONSerialization.jsonObject(with:manifest) as? [String:Any],let project=raw["project"] as? [String:Any],let id=project["id"] as? String,UUID(uuidString:id)==summary.id,
      (project["publications"] as? [Any] ?? []).isEmpty,
      let refs=raw["objects"] as? [[String:Any]],refs.count==1,let ref=refs.first,ref["canvasWorkspace"] as? Bool==true,
      let name=ref["file"] as? String,!name.contains("/"),name.hasSuffix(".json"),let objectID=ref["id"] as? String,UUID(uuidString:objectID) != nil else{throw CocoaError(.fileReadCorruptFile)}
    let objects=url.appendingPathComponent("Objects",isDirectory:true)
    guard objects.resolvingSymlinksInPath().deletingLastPathComponent()==url.resolvingSymlinksInPath() else{throw CocoaError(.fileReadCorruptFile)}
    let data=try bounded(objects.appendingPathComponent(name),limit:maximumSourceBytes-manifest.count)
    try afterActiveRead?()
    guard try bounded(manifestURL,limit:maximumSourceBytes)==manifest else{throw CocoaError(.fileReadUnknown)}
    var digest=SHA256();digest.update(data:manifest);digest.update(data:data)
    let key=summary.id.uuidString+"/v\(HomeTechnicalInk.version)/"+digest.finalize().map{String(format:"%02x",$0)}.joined()
    return .init(id:UUID(uuidString:objectID)!,data:data,key:key,bytes:manifest.count+data.count)
  }
  func image(for summary:ProjectSummary)async->NSImage? {
    guard !Task.isCancelled,summary.objectCount==0,(summary.canvasItemCount ?? 0)>0 else{return nil}
    let request=UUID();sequence+=1;let serial=sequence
    pending[summary.id,default:Pending()].requests.insert(request)
    defer{pending[summary.id]?.requests.remove(request);if pending[summary.id]?.requests.isEmpty==true {pending.removeValue(forKey:summary.id)}}
    let began=Date()
    let snapshot:Snapshot
    do {snapshot=try await readSnapshot(summary)}
    catch{lastReason="source-budget-or-format";return nil}
    guard !Task.isCancelled,pending[summary.id]?.requests.contains(request)==true else{return nil}
    let mainBegan=Date();defer{maximumMainMs=max(maximumMainMs,Date().timeIntervalSince(mainBegan)*1000)}
    lastSourceBytes=snapshot.bytes
    // A late older revision cannot replace a completed newer revision. Identical
    // concurrent cards may share the newer cached image instead of going blank.
    if serial<(pending[summary.id]?.newestCompleted ?? 0),entries[snapshot.key]==nil {return nil}
    let completed=max(serial,pending[summary.id]?.newestCompleted ?? 0);pending[summary.id]?.newestCompleted=completed
    if let entry=entries[snapshot.key] {hits+=1;order.removeAll{$0==snapshot.key};order.append(snapshot.key);maximumWarmMs=max(maximumWarmMs,Date().timeIntervalSince(began)*1000);return entry.image}
    do {
      let source=try JSONDecoder.form.decode(CanvasSource.self,from:snapshot.data)
      guard source.id==snapshot.id,source.recipeID=="artboard",source.canvasWorkspace==true,source.artworkSourceID==nil,let art=source.artwork else{return nil}
      let result=HomeTechnicalInk.evaluate(art);lastWork=result.work;lastReason=result.reason
      let image:NSImage?
      if let c=result.composition {image=ArtworkRenderer.image(c.artwork,width:c.width,height:c.height,assets:summary.url.appendingPathComponent("Assets"),pixelsPerMM:c.density,opaqueBackground:true);renders+=1}else{image=nil}
      guard !Task.isCancelled,pending[summary.id]?.requests.contains(request)==true else{return nil}
      // Keep only the current revision of each project; no Project or source data retained.
      removeCached(summary.id);entries[snapshot.key] = .init(projectID:summary.id,image:image,cost:image == nil ? 0:1000*650*4);order.append(snapshot.key)
      while order.count>8 || retainedBytes>32*1024*1024 {entries.removeValue(forKey:order.removeFirst())}
      maximumColdMs=max(maximumColdMs,Date().timeIntervalSince(began)*1000)
      return image
    }catch{lastReason="source-format";return nil}
  }
}

/// Disk snapshots are serialized off the main actor; drawing has one MainActor owner.
private actor HomeTechnicalSourceReader {
  static let shared=HomeTechnicalSourceReader()
  func snapshot(_ summary:ProjectSummary)async throws->HomeTechnicalPreview.Snapshot {try HomeTechnicalPreview.snapshot(summary)}
}

private struct HomeTechnicalImageKey:EnvironmentKey {
  static let defaultValue:@MainActor (ProjectSummary) async -> NSImage? = {summary in await HomeTechnicalPreview.shared.image(for:summary)}
}
extension EnvironmentValues {
  /// Display service injection for native Home probes; never a user preference.
  var homeTechnicalImage:@MainActor (ProjectSummary) async -> NSImage? {
    get{self[HomeTechnicalImageKey.self]}
    set{self[HomeTechnicalImageKey.self]=newValue}
  }
}
