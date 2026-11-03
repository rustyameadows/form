import AppKit
import CryptoKit
import FormCore
import SwiftUI

/// Saved compositions render independently of the live stage and its draft.
/// The controller retains completed pixels across workspace transitions; only
/// visible rows request work, and one serial chain bounds native captures.
@MainActor final class StudioSceneThumbnailCache:ObservableObject {
  private struct Source {let project:Project,design:Project,assets:URL,identity:String,fontRevision:Int}
  private struct Key {let scene:StudioComposition,identity:String,value:String}
  @MainActor private final class Request {
    let scene:StudioComposition,task:Task<NSImage,Error>
    var readers=Set<UUID>()
    init(scene:StudioComposition,task:Task<NSImage,Error>){self.scene=scene;self.task=task}
  }
  @Published private(set) var revision=0
  private var source:Source?
  private var keys:[UUID:Key]=[:]
  private var requests:[String:Request]=[:]
  private var tail:Task<Void,Never>?,tailID:UUID?
  private let images=NSCache<NSString,NSImage>()
  private let renderer=StudioShotRenderer()
  var renderCount:Int {renderer.renders}
  private(set) var keyBuildCount=0

  init(){images.countLimit=32;images.totalCostLimit=32*1024*1024}
  func synchronize(project:Project?,assets:URL?) {
    guard let project,let assets else{reset();return}
    let design=StudioPreviewSource.thumbnailDesign(project),fontRevision=GeometryFactory.fontRevision
    let changed=source?.design != design || source?.assets.standardizedFileURL != assets.standardizedFileURL || source?.fontRevision != fontRevision
    let scenesChanged=source?.project.studioPresentation?.scenes != project.studioPresentation?.scenes
    let identity=changed ? UUID().uuidString:source!.identity
    if changed {cancelRequests();images.removeAllObjects();keys=[:]}
    source = .init(project:project,design:design,assets:assets,identity:identity,fontRevision:fontRevision)
    let scenes=Dictionary(uniqueKeysWithValues:(project.studioPresentation?.scenes ?? []).map{($0.id,$0)})
    keys=keys.filter{scenes[$0.key] != nil}
    for key in Array(requests.keys) {
      guard let request=requests[key] else{continue}
      if scenes[request.scene.id].map({self.key(for:$0)==key}) != true {requests.removeValue(forKey:key)?.task.cancel()}
    }
    if changed || scenesChanged {revision &+= 1}
  }
  /// Stop work for vanished rows without throwing away already rendered pixels.
  private func cancelRequests() {
    for request in requests.values {request.task.cancel()}
    requests.removeAll()
  }
  func suspend() {cancelRequests();renderer.clear()}
  func reset() {
    suspend();images.removeAllObjects();keys=[:];source=nil;revision &+= 1
  }
  func key(for scene:StudioComposition)->String {
    let scene=StudioPreviewSource.thumbnail(scene),identity=source?.identity ?? "waiting"
    if let key=keys[scene.id],key.identity==identity,key.scene==scene {return key.value}
    let definition=(try? JSONEncoder.form.encode(scene)) ?? Data(scene.id.uuidString.utf8)
    var data=Data(identity.utf8);data.append(definition)
    let value=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    keys[scene.id] = .init(scene:scene,identity:identity,value:value);keyBuildCount &+= 1
    return value
  }
  static func pixels(for scene:StudioComposition)->StudioPixels {
    let scale=min(1,512/Double(max(scene.pixels.width,scene.pixels.height)))
    return .init(width:max(64,Int((Double(scene.pixels.width)*scale).rounded())),height:max(64,Int((Double(scene.pixels.height)*scale).rounded())))
  }
  func image(for scene:StudioComposition,preflight:@escaping(Project,StudioShot)throws->Void)async throws->NSImage {
    try Task.checkCancellation();try scene.validate()
    guard let source else{throw CancellationError()}
    guard scene.instances.contains(where:{$0.visible}) else{throw FormError.invalid("Empty scene")}
    let key=key(for:scene),reader=UUID()
    var check=scene.shot();check.visibility = .init(mode:.objects,objectIDs:Array(Set(scene.instances.filter(\.visible).compactMap(\.sourceObjectID))))
    if !check.visibility.objectIDs.isEmpty {try preflight(source.project,check)}
    if let image=images.object(forKey:key as NSString){return image}
    let request:Request
    if let existing=requests[key] {request=existing}
    else {
      let previous=tail,identity=source.identity
      let task=Task(priority:.utility) { @MainActor [weak self] in
        if let previous {await previous.value}
        // Give a scene recall/first layout priority over background row captures.
        await Task.yield();try Task.checkCancellation()
        guard let self,self.isCurrent(scene,identity:identity,key:key) else{throw CancellationError()}
        if !check.visibility.objectIDs.isEmpty {try preflight(source.project,check)}
        let resolved=try scene.resolved(in:source.project)
        var shot=scene.shot();shot.pixels=Self.pixels(for:scene)
        shot.visibility = .init(mode:.objects,objectIDs:resolved.visible.sorted{$0.uuidString<$1.uuidString})
        let image=try await self.renderer.render(project:resolved.project,shot:shot,assets:source.assets,preview:true,renderObjectIDs:resolved.visible,textureLimit:512)
        try Task.checkCancellation()
        guard self.isCurrent(scene,identity:identity,key:key) else{throw CancellationError()}
        self.images.setObject(image,forKey:key as NSString,cost:shot.pixels.width*shot.pixels.height*4)
        return image
      }
      request=Request(scene:scene,task:task);requests[key]=request
      let boundaryID=UUID();tailID=boundaryID
      tail=Task { @MainActor [weak self] in
        _ = try? await task.value
        if self?.tailID==boundaryID {self?.tail=nil;self?.tailID=nil}
      }
    }
    request.readers.insert(reader)
    return try await withTaskCancellationHandler(operation:{
      defer{release(key,request:request,reader:reader)}
      let image=try await request.task.value;try Task.checkCancellation();return image
    },onCancel:{Task { @MainActor [weak self] in self?.release(key,request:request,reader:reader)}})
  }
  private func isCurrent(_ scene:StudioComposition,identity:String,key:String)->Bool {
    guard source?.identity==identity,let current=source?.project.studioPresentation?.scenes?.first(where:{$0.id==scene.id}) else{return false}
    return self.key(for:current)==key
  }
  private func release(_ key:String,request:Request,reader:UUID) {
    // A cancelled old task must never release a replacement with the same key.
    guard requests[key] === request else{return}
    request.readers.remove(reader)
    if request.readers.isEmpty {request.task.cancel();requests.removeValue(forKey:key)}
  }
}

struct StudioSceneThumbnail:View {
  @ObservedObject var cache:StudioSceneThumbnailCache
  let scene:StudioComposition
  let selected:Bool
  let preflight:(Project,StudioShot)throws->Void
  let action:()->Void
  @State private var image:NSImage?
  @State private var issue:String?
  var body:some View {
    StudioSceneThumbnailRow(title:scene.name,subtitle:issue,image:image,
      selected:selected,identifier:"studio-scene-"+scene.id.uuidString,action:action)
      .frame(height:StudioSceneThumbnailRow.height(for:issue))
      .task(id:cache.key(for:scene)) {
        image=nil;issue=nil
        do {image=try await cache.image(for:scene,preflight:preflight)}
        catch is CancellationError {} catch {issue=error.localizedDescription}
      }
  }
}

struct StudioSceneThumbnailRow:NSViewRepresentable {
  var title:String,subtitle:String?=nil,image:NSImage?,selected:Bool,identifier:String
  var action:()->Void
  static func height(for subtitle:String?)->CGFloat {subtitle?.isEmpty==false ? 120:108}
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator()->Coordinator {Coordinator(action)}
  func makeNSView(context:Context)->StudioSceneThumbnailNativeButton {
    let button=StudioSceneThumbnailNativeButton(frame:.zero)
    button.setButtonType(.momentaryChange);button.isBordered=false;button.focusRingType = .exterior
    button.target=context.coordinator;button.action=#selector(Coordinator.press(_:));updateNSView(button,context:context);return button
  }
  func updateNSView(_ button:StudioSceneThumbnailNativeButton,context:Context) {
    context.coordinator.action=action;button.rowTitle=title;button.subtitle=subtitle;button.thumbnail=image;button.selected=selected
    button.isEnabled=enabled;button.toolTip=subtitle.flatMap{$0.isEmpty ? nil:title+" · "+$0} ?? title
    button.setAccessibilityLabel("Open Studio scene "+title);button.setAccessibilityIdentifier(identifier);button.setAccessibilityHelp(subtitle)
    button.invalidateIntrinsicContentSize();button.needsDisplay=true
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:StudioSceneThumbnailNativeButton,context:Context)->CGSize? {.init(width:proposal.width ?? 152,height:Self.height(for:subtitle))}
  static func dismantleNSView(_ button:StudioSceneThumbnailNativeButton,coordinator:Coordinator){button.target=nil;button.action=nil;coordinator.action={}}
  final class Coordinator:NSObject {
    var action:()->Void
    init(_ action:@escaping()->Void){self.action=action}
    @objc func press(_ sender:NSButton){if sender.isEnabled {action()}}
  }
}

final class StudioSceneThumbnailNativeButton:NSButton {
  var rowTitle="",thumbnail:NSImage?,selected=false
  var subtitle:String?
  override var isFlipped:Bool {true}
  override var intrinsicContentSize:NSSize {.init(width:NSView.noIntrinsicMetric,height:StudioSceneThumbnailRow.height(for:subtitle))}
  override var alignmentRectInsets:NSEdgeInsets {.init(top:0,left:0,bottom:0,right:0)}
  override var acceptsFirstResponder:Bool {isEnabled}
  override func isAccessibilityElement()->Bool {true}
  override func accessibilityRole()->NSAccessibility.Role? {.button}
  override func isAccessibilitySelected()->Bool {selected}
  override func accessibilityValue()->Any? {selected ? "Selected":""}
  override func accessibilityPerformPress()->Bool {guard isEnabled,action != nil,target != nil else{return false};performClick(nil);return true}
  override func hitTest(_ point:NSPoint)->NSView? {
    guard !isHiddenOrHasHiddenAncestor,alphaValue>0,bounds.contains(convert(point,from:superview)) else{return nil};return self
  }
  override func draw(_ dirtyRect:NSRect) {
    let path=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8)
    (selected ? Palette.accentNS.withAlphaComponent(0.10):Palette.surfaceNS).setFill();path.fill()
    if selected || isHighlighted || window?.firstResponder === self {
      (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor:Palette.accentNS).setStroke();path.lineWidth=selected ? 1.5:1;path.stroke()
    }
    let preview=CGRect(x:7,y:7,width:max(1,bounds.width-14),height:78)
    NSColor(Palette.paper).setFill();NSBezierPath(roundedRect:preview,xRadius:4,yRadius:4).fill()
    if let thumbnail,thumbnail.size.width>0,thumbnail.size.height>0 {
      let scale=min(preview.width/thumbnail.size.width,preview.height/thumbnail.size.height)
      let size=CGSize(width:thumbnail.size.width*scale,height:thumbnail.size.height*scale)
      thumbnail.draw(in:CGRect(x:preview.midX-size.width/2,y:preview.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:isEnabled ? 1:0.4,respectFlipped:true,hints:nil)
    }else {NSImage(systemSymbolName:"camera",accessibilityDescription:nil)?.draw(in:CGRect(x:preview.midX-10,y:preview.midY-8,width:20,height:16),from:.zero,operation:.sourceOver,fraction:0.35,respectFlipped:true,hints:nil)}
    let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
    (rowTitle as NSString).draw(in:CGRect(x:8,y:90,width:max(0,bounds.width-16),height:14),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:selected ? .medium:.regular),.foregroundColor:NSColor(Palette.ink),.paragraphStyle:paragraph])
    if let subtitle,!subtitle.isEmpty {
      (subtitle as NSString).draw(in:CGRect(x:8,y:105,width:max(0,bounds.width-16),height:12),withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:Palette.secondaryNS,.paragraphStyle:paragraph])
    }
  }
}
