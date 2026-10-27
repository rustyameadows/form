import AppKit
import SwiftUI
import FormCore
import FormCADModel
import LabRendering
import simd

struct CADModelEditorPresenter:View {
  @ObservedObject var coordinator:CADModelCoordinator
  let store:StudioStore
  init(store:StudioStore){self.store=store;coordinator=store.cad}
  var body:some View {Color.clear.frame(width:0,height:0).sheet(item:Binding(get:{coordinator.review},set:{value in if value==nil,let current=coordinator.review{coordinator.cancel(current)}else{coordinator.review=value}})){job in CADModelEditor(coordinator:coordinator,review:job)}}
}
struct CADModelEditor:View {
  @ObservedObject var coordinator:CADModelCoordinator
  @ObservedObject var review:CADModelReview
  @State private var template="enclosure"
  private var busy:Bool{["preparing","publishing"].contains(review.state)}
  var body:some View {
    VStack(spacing:0){
      HStack(alignment:.firstTextBaseline){
        VStack(alignment:.leading,spacing:4){Text("Exact model").font(.system(size: 27, weight: .semibold));Text("Millimeters · Editable construction").font(.system(size:11)).foregroundStyle(.secondary)}
        Spacer();Button("Cancel"){coordinator.cancel(review)}.keyboardShortcut(.cancelAction)
      }.padding(24)
      Divider()
      HSplitView {
        VStack(alignment:.leading,spacing:12){
          if !review.scene.isEmpty{CADModelPreview(scene:review.scene).frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityLabel("Exact CAD model preview")}
          else{ContentUnavailableView("Preview your construction",systemImage:"cube.transparent",description:Text("Choose a construction and adjust dimensions, then preview the exact solids.")).frame(maxWidth:.infinity,maxHeight:.infinity)}
          Text("Drag to orbit · Shift-drag to pan · Scroll to zoom").font(.system(size:10)).foregroundStyle(.secondary)
          if let representation=review.prepared?.representation{let lo=representation.minimum,hi=representation.maximum;Text(String(format:"%.2f × %.2f × %.2f mm",hi.x-lo.x,hi.y-lo.y,hi.z-lo.z)).font(.system(size:13,design:.monospaced));Text("\(representation.components.count) exact components · \(representation.components.reduce(0){$0+$1.faceCount}) faces · \(representation.components.reduce(0){$0+$1.triangleCount}.formatted()) display triangles").font(.system(size:10)).foregroundStyle(.secondary)}
        }.padding(20).frame(minWidth:420,minHeight:420)
        ScrollView{
          VStack(alignment:.leading,spacing:18){
            TextField("Model name",text:Binding(get:{review.definition.name},set:{review.definition.name=$0;review.definition.revision+=1;review.state="draft"})).textFieldStyle(.roundedBorder)
            if review.targetObjectID==nil{HStack{Picker("Construction",selection:$template){ForEach(CADModelExamples.names,id:\.self){Text($0=="clockEnclosure" ? "Clock enclosure":$0.capitalized).tag($0)}};Button("Use"){do{review.definition=try CADModelExamples.make(template);review.state="draft"}catch{review.issue=error.localizedDescription}}}}
            Picker("Display mesh",selection:Binding(get:{review.quality},set:{review.quality=$0;review.state="draft"})){Text("Fast preview").tag("preview");Text("Inspection").tag("inspection");Text("Fine fabrication").tag("fabrication")}
            if !review.definition.parameters.isEmpty {
              Text("DIMENSIONS").font(.system(size:10,weight:.semibold)).tracking(1)
              ForEach(review.definition.parameters,id:\.name){parameter in
                VStack(alignment:.leading,spacing:5){HStack{Text(CADDisplayLabels.name(parameter.name)).font(.system(size:12));Spacer();TextField(parameter.name,value:Binding(get:{review.definition.parameters.first{$0.name==parameter.name}?.value ?? parameter.value},set:{update(parameter.name,$0)}),format:.number.precision(.fractionLength(0...3))).frame(width:75).multilineTextAlignment(.trailing);Text(parameter.unit).font(.system(size:10)).foregroundStyle(.secondary)};Slider(value:Binding(get:{review.definition.parameters.first{$0.name==parameter.name}?.value ?? parameter.value},set:{update(parameter.name,$0)}),in:parameter.minimum...parameter.maximum)}
              }
            }
            if let assemblies=review.definition.importedAssemblies{ForEach(Array(assemblies.enumerated()),id:\.offset){_,assembly in
              DisclosureGroup("Imported assembly"){VStack(alignment:.leading,spacing:7){ForEach(assembly.nodes,id:\.path){node in
                HStack{Image(systemName:node.assembly ? "folder":"cube");Text(node.name).lineLimit(2);Spacer()}.font(.system(size:11)).padding(.leading,CGFloat(max(0,node.path.split(separator:"/").count-1))*12)
              }}}.font(.system(size:12,weight:.medium))
            }}
            Divider();Text("CONSTRUCTION").font(.system(size:10,weight:.semibold)).tracking(1)
            ForEach(Array(review.definition.features.enumerated()),id:\.element.id){index,feature in
              DisclosureGroup{VStack(alignment:.leading,spacing:8){
                  ForEach(feature.operation.values.keys.sorted(),id:\.self){key in HStack{Text(CADDisplayLabels.name(key)).font(.system(size:10));TextField("Expression",text:Binding(get:{review.definition.features.first{$0.id==feature.id}?.operation.values[key]?.expression ?? ""},set:{value in mutate(feature.id){$0.operation.values[key]=CADScalar(value)}})).font(.system(size:11,design:.monospaced)).textFieldStyle(.roundedBorder)}}
                  if feature.operation.kind.canSuppressToFirstInput{Toggle("Suppress feature",isOn:Binding(get:{review.definition.features.first{$0.id==feature.id}?.suppressed ?? false},set:{value in mutate(feature.id){$0.suppressed=value}})).font(.system(size:10))}
                  if feature.operation.kind == .profile || feature.operation.kind == .curveProfile || feature.operation.kind == .circleProfile{CADSketchPreview(operation:feature.operation,parameters:review.definition.parameterValues).frame(height:150).background(Color.black.opacity(0.025),in:RoundedRectangle(cornerRadius:6))}
                  Text("Inputs: "+feature.operation.inputs.map{id in review.definition.features.first{$0.id==id}?.name ?? "Missing feature"}.joined(separator:", ")).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                }.padding(.vertical,8)
              }label:{HStack(alignment:.top,spacing:8){Text(String(index+1)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).frame(width:20);VStack(alignment:.leading,spacing:3){Text(feature.name).font(.system(size:12,weight:.medium));Text(CADDisplayLabels.name(feature.operation.kind.rawValue)+(feature.suppressed ? " · suppressed":"")).font(.system(size:10)).foregroundStyle(.secondary)};Spacer();if review.definition.outputs.contains(feature.id){Image(systemName:"cube.fill").foregroundStyle(.secondary)}}}
            }
            if !review.definition.assumptions.isEmpty{Divider();Text("MODEL NOTES").font(.system(size:10,weight:.semibold)).tracking(1);ForEach(review.definition.assumptions,id:\.self){Text($0).font(.system(size:11)).foregroundStyle(.secondary)}}
            if !review.definition.unresolvedMeasurements.isEmpty{Text("UNRESOLVED MEASUREMENTS").font(.system(size:10,weight:.semibold)).tracking(1);ForEach(review.definition.unresolvedMeasurements,id:\.self){Text($0).font(.system(size:11)).foregroundStyle(.secondary)}}
          }.padding(20).disabled(busy)
        }.frame(minWidth:300,idealWidth:340,maxWidth:380)
      }
      Divider()
      VStack(alignment:.leading,spacing:10){
        if let issue=review.issue{Text(issue).font(.system(size:12)).foregroundStyle(Palette.ink).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
        HStack{if busy{ProgressView().controlSize(.small);Text(review.state=="publishing" ? "Publishing exact source…":"Evaluating exact features…").font(.system(size:11))}else{Text(review.state=="ready" ? "Preview validated. Apply to the project when ready.":"Dimension changes stay in this review until you apply.").font(.system(size:11)).foregroundStyle(.secondary)};Spacer();Button("Preview"){coordinator.preview(review)}.disabled(busy);Button(review.targetObjectID==nil ? "Add to project":"Apply changes"){do{try coordinator.commit(review)}catch{review.issue=error.localizedDescription}}.buttonStyle(.borderedProminent).tint(Palette.ink).keyboardShortcut(.defaultAction).disabled(review.state != "ready")}
      }.padding(20)
    }.frame(width:1000,height:740).background(Palette.paper)
  }
  private func mutate(_ id:UUID,_ change:(inout CADFeatureNode)->Void){guard let i=review.definition.features.firstIndex(where:{$0.id==id}) else{return};change(&review.definition.features[i]);review.definition.revision+=1;review.state="draft"}
  private func update(_ name:String,_ value:Double){do{try review.definition.setParameter(name,value:value);review.state="draft";review.issue=nil}catch{review.issue=error.localizedDescription}}
}

private struct CADModelPreview:NSViewRepresentable {
  let scene:[SceneRenderablePayload]
  func makeNSView(context:Context)->CADPreviewViewport {CADPreviewViewport(frame:.init(x:0,y:0,width:580,height:480))}
  func updateNSView(_ view:CADPreviewViewport,context:Context){view.install(scene)}
  static func dismantleNSView(_ view:CADPreviewViewport,coordinator:()){view.task?.cancel();view.renderer?.reset()}
}
/// Shares the established Table camera math and the same three gestures.
@MainActor private final class CADPreviewViewport:NSView {
  var renderer:RealityKitSceneRenderer?,task:Task<Void,Never>?
  private var revision="",camera=CameraState(),last:CGPoint?
  override var acceptsFirstResponder:Bool{true}
  override init(frame:NSRect){super.init(frame:frame);do{let r=try RealityKitSceneRenderer(frame:bounds);renderer=r;r.nativeView.frame=bounds;r.nativeView.autoresizingMask=[.width,.height];addSubview(r.nativeView)}catch{let label=NSTextField(wrappingLabelWithString:"3D preview unavailable: "+error.localizedDescription);label.frame=bounds;label.autoresizingMask=[.width,.height];addSubview(label)}}
  required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
  override func hitTest(_ point:NSPoint)->NSView?{bounds.contains(point) ? self:nil}
  func install(_ values:[SceneRenderablePayload]){
    let key=values.map{$0.componentID+$0.mesh.revision}.joined();guard key != revision,let renderer else{return};revision=key;task?.cancel();renderer.reset()
    var lo=SIMD3<Double>(repeating:.infinity),hi=SIMD3<Double>(repeating:-.infinity)
    for value in values{for p in value.mesh.positionsMM{lo=simd_min(lo,p);hi=simd_max(hi,p)}}
    guard lo.x.isFinite,hi.x.isFinite else{return}
    let center=(lo+hi)/2,extent=max(1,simd_length(hi-lo));camera = .init();camera.target = .init(center.x/100,center.y/100,center.z/100);camera.distance=min(CameraNavigation.maximumDistance,max(CameraNavigation.minimumDistance,extent/100*1.8));updateCamera()
    task=Task{do{for value in values{try Task.checkCancellation();try await renderer.upsertAsync(value)}}catch{if !(error is CancellationError){self.toolTip=error.localizedDescription}}}
  }
  private func updateCamera(){guard let renderer else{return};let b=CameraNavigation.basis(camera),t=SIMD3(camera.target.x,camera.target.y,camera.target.z)*100,eye=t+SIMD3(b.outward.x,b.outward.y,b.outward.z)*camera.distance*100;do{try renderer.setCamera(.looking(from:eye,at:t,up:.init(b.up.x,b.up.y,b.up.z)))}catch{toolTip=error.localizedDescription}}
  override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);last=convert(event.locationInWindow,from:nil)}
  override func mouseDragged(with event:NSEvent){let p=convert(event.locationInWindow,from:nil);guard let previous=last else{last=p;return};let dx=Double(p.x-previous.x),dy=Double(p.y-previous.y);last=p
    camera=event.modifierFlags.contains(.shift) ? CameraNavigation.panned(camera,dx:dx,dy:dy,viewportHeight:bounds.height):CameraNavigation.orbited(camera,dx:dx,dy:dy,viewportHeight:bounds.height);updateCamera()}
  override func mouseUp(with event:NSEvent){last=nil}
  override func scrollWheel(with event:NSEvent){let delta=CameraPreferences().scrollZoomDelta(event.scrollingDeltaY,precise:event.hasPreciseScrollingDeltas);camera=CameraNavigation.zoomed(camera,delta:delta);updateCamera()}
}

private struct CADSketchPreview:View {
  let operation:CADFeatureOperation,parameters:[String:Double]
  var body:some View {Canvas{context,size in
    func scalar(_ s:CADScalar)->Double{(try? CADExpression.evaluate(s.expression,variables:parameters)) ?? 0}
    func point(_ p:CADExpressionPoint2)->CGPoint{.init(x:scalar(p.x),y:scalar(p.y))}
    let points=(operation.points ?? [])+(operation.curves ?? []).flatMap{[$0.start,$0.end]+[$0.control1,$0.control2].compactMap{$0}}
    let raw=points.map(point),radius=CGFloat(operation.values["radius"].map(scalar) ?? 1)
    let loX=raw.map(\.x).min() ?? -radius,hiX=raw.map(\.x).max() ?? radius,loY=raw.map(\.y).min() ?? -radius,hiY=raw.map(\.y).max() ?? radius
    let scale=min((size.width-24)/max(1,hiX-loX),(size.height-24)/max(1,hiY-loY))
    func p(_ value:CADExpressionPoint2)->CGPoint{let v=point(value);return .init(x:(v.x-(loX+hiX)/2)*scale+size.width/2,y:size.height/2-(v.y-(loY+hiY)/2)*scale)}
    var path=Path()
    if operation.kind == .circleProfile{path.addEllipse(in:.init(x:size.width/2-radius*scale,y:size.height/2-radius*scale,width:radius*2*scale,height:radius*2*scale))}
    else if let curves=operation.curves{for (i,c) in curves.enumerated(){if i==0{path.move(to:p(c.start))};switch c.kind{case .line:path.addLine(to:p(c.end));case .quadraticBezier:path.addQuadCurve(to:p(c.end),control:p(c.control1 ?? c.start));case .cubicBezier:path.addCurve(to:p(c.end),control1:p(c.control1 ?? c.start),control2:p(c.control2 ?? c.end));case .circularArc:
        let a=p(c.start),b=p(c.control1 ?? c.start),d=p(c.end),det=2*(a.x*(b.y-d.y)+b.x*(d.y-a.y)+d.x*(a.y-b.y))
        if abs(det)<1e-10{path.addLine(to:d)}else{let aa=a.x*a.x+a.y*a.y,bb=b.x*b.x+b.y*b.y,dd=d.x*d.x+d.y*d.y,cx=(aa*(b.y-d.y)+bb*(d.y-a.y)+dd*(a.y-b.y))/det,cy=(aa*(d.x-b.x)+bb*(a.x-d.x)+dd*(b.x-a.x))/det,r=hypot(a.x-cx,a.y-cy),start=atan2(a.y-cy,a.x-cx),middle=atan2(b.y-cy,b.x-cx),end=atan2(d.y-cy,d.x-cx)
          func positive(_ v:CGFloat)->CGFloat{let result=v.truncatingRemainder(dividingBy:2 * .pi);return result<0 ? result+2 * .pi:result}
          let ccw=positive(end-start),span=positive(middle-start)<=ccw ? ccw:ccw-2 * .pi
          for i in 1...48{let angle=start+span*CGFloat(i)/48;path.addLine(to:.init(x:cx+r*cos(angle),y:cy+r*sin(angle)))}}
}};path.closeSubpath()}
    else if let first=operation.points?.first{path.move(to:p(first));for value in operation.points!.dropFirst(){path.addLine(to:p(value))};path.closeSubpath()}
    context.stroke(path,with:.color(.primary.opacity(0.8)),lineWidth:1.2)
  }.overlay(alignment:.bottomLeading){Text("CAD profile plane · mm").font(.system(size:9)).foregroundStyle(.secondary).padding(7)}}
}

private enum CADDisplayLabels {
  static func name(_ id:String)->String {
    if let label=["wall":"Wall thickness","edgeRadius":"Edge radius","mountBore":"Mount bore diameter","shaftDiameter":"Shaft diameter","importedSTEP":"Imported STEP body","importedBRep":"Imported BRep body"][id]{return label}
    let words=id.replacingOccurrences(of:"([a-z0-9])([A-Z])",with:"$1 $2",options:.regularExpression).lowercased()
    return words.prefix(1).uppercased()+words.dropFirst()
  }
}
