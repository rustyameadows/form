import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

struct EmbroideryEditor:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) var dismiss
  let objectID:UUID
  @State private var draft:EmbroideryDesign
  @State private var program:EmbroideryProgram?
  @State private var error=""
  @State private var dirty=true
  @State private var showJumps=true
  @State private var through=0.0
  init(object:ProductObject,project:Project) {
    objectID=object.id
    _draft=State(initialValue:object.textile?.embroidery ?? (try? EmbroideryDigitizer.defaultDesign(object:object,project:project)) ?? .init(threads:[.init(name:"Thread 1",color:"#E8E1CD")],regions:[]))
  }
  private var object:ProductObject? {store.project?.objects.first {$0.id==objectID}}
  private var sources:[ArtworkElement] {
    guard let object,let project=store.project,let art=project.surfaceArtwork(object) else {return []}
    let masks=Set(art.elements.compactMap(\.clipID))
    return art.elements.filter {!masks.contains($0.id) && $0.kind != "image"}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      HStack {
        VStack(alignment:.leading,spacing:3) {
          Text("Embroidery").font(.system(size: 25, weight: .semibold))
          Text(object?.name ?? "Decoration").font(.system(size:11)).foregroundStyle(Palette.secondary)
        }
        Spacer();AppCloseButton("Close", keyEquivalent: "\u{1b}") {dismiss()}.keyboardShortcut(.cancelAction)
      }
      HStack(alignment:.top,spacing:22) {
        VStack(alignment:.leading,spacing:10) {
          EmbroideryPreview(program:program,showJumps:showJumps,through:Int(through))
            .background(.white,in:RoundedRectangle(cornerRadius:9)).frame(maxWidth:.infinity,maxHeight:.infinity)
          if let program {
            Text("\(program.stitchCount.formatted()) stitches · \(program.commands.filter {$0.action == .jump}.count) travels · \(program.threadOrder.count) thread passes")
              .font(.system(size:11,design:.monospaced)).foregroundStyle(Palette.secondary)
            InspectorSlider(value:$through,in:0...Double(max(1,program.commands.count)),step:1).accessibilityLabel("Stitch playback")
          }
          HStack {
            Toggle("Show travel + trims",isOn:$showJumps).toggleStyle(.checkbox)
            Spacer();Button(dirty ? "Rebuild preview":"Regenerate") {rebuild()}
          }.font(.system(size:11))
          Text(dirty ? "Settings changed. Rebuild to inspect the new needle program.":"Solid lines are stitches. Dashed lines are non-needle travel; orange marks indicate trim requests.")
            .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
          Text("Source artwork stays editable. Opt-in underlay and backtracking locks are real stitches. No fabric compensation or machine-specific settings are inferred. Review a sample sew-out before production.")
            .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        }
        ScrollView {
          VStack(alignment:.leading,spacing:13) {
            Text("HOOP · MILLIMETERS").font(.system(size:9,weight:.semibold)).tracking(1)
            number("Width",$draft.hoopWidth);number("Height",$draft.hoopHeight);number("Clearance",$draft.margin)
            number("Trim travel over",$draft.trimJumpThreshold)
            HStack {Text("Stitch limit");Spacer();TextField("Stitch limit",value:$draft.maximumStitches,format:.number)
              .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:110)}.font(.system(size:11))
            Divider()
            processControls
            Divider()
            HStack {Text("THREAD ORDER").font(.system(size:9,weight:.semibold)).tracking(1);Spacer();Button {draft.threads.append(.init(name:"Thread \(draft.threads.count+1)",color:"#D98045"))} label:{Image(systemName:"plus")}.disabled(draft.threads.count>=32)}
            ForEach(draft.threads.indices,id:\.self) {index in
              VStack(alignment:.leading,spacing:5) {
                HStack {
                  Text("\(index+1)").foregroundStyle(Palette.secondary)
                  TextField("Thread name",text:$draft.threads[index].name).textFieldStyle(.roundedBorder)
                  Button {removeThread(index)} label:{Image(systemName:"minus.circle")}.disabled(draft.threads.count<=1)
                }
                Menu(draft.threads[index].stock.map {"Stock snapshot · "+$0.name} ?? "Assign library thread…") {
                  ForEach(store.library.textileProduction?.threads ?? []) {stock in Button(stock.name+" / "+(stock.sku ?? stock.color)) {draft.threads[index] = .init(stock:stock)}}
                  if draft.threads[index].stock != nil {Divider();Button("Unlink stock snapshot") {draft.threads[index].stock=nil}}
                }
                InspectorColorPicker("Color",selection:Binding(get:{Color(nsColor:NSColor(hex:draft.threads[index].color))},set:{draft.threads[index].color=NSColor($0).hexString}),supportsOpacity:false).disabled(draft.threads[index].stock != nil)
                HStack {
                  TextField("Brand",text:Binding(get:{draft.threads[index].brand ?? ""},set:{draft.threads[index].brand=$0.isEmpty ? nil:$0}))
                  TextField("Catalog",text:Binding(get:{draft.threads[index].catalog ?? ""},set:{draft.threads[index].catalog=$0.isEmpty ? nil:$0}))
                }.textFieldStyle(.roundedBorder)
              }.font(.system(size:10))
            }
            Divider()
            HStack {Text("DIGITIZING REGIONS").font(.system(size:9,weight:.semibold)).tracking(1);Spacer();Button {addRegion()} label:{Image(systemName:"plus")}.disabled(sources.isEmpty || draft.regions.count>=128)}
            ForEach(draft.regions.indices,id:\.self) {index in
              region(index).padding(10).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:6))
            }
            Button("Build regions from artwork") {defaults()}.font(.system(size:10))
            Divider()
            HStack {ForEach(["dst","svg","json"],id:\.self) {format in Button(format.uppercased()) {export(format)}}}
            Text("DST uses a conventional three-jump trim request. An adjacent ordered thread JSON preserves colors; DST itself has no RGB palette. The SVG shows actual needle paths at physical hoop size.")
              .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
          }.padding(.trailing,8)
        }.frame(width:325)
      }
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
      HStack {
        Button("Remove digitizing settings") {remove()}.disabled(object?.textile?.embroidery==nil)
        Spacer();Button("Save embroidery") {_ = apply()}.buttonStyle(.borderedProminent).tint(Palette.ink).keyboardShortcut(.defaultAction)
      }
    }.padding(26).frame(width:1080,height:780).background(Palette.paper)
      .onAppear {rebuild()}.onChange(of:draft) {_,value in dirty=program?.design != value}
  }
  private func number(_ label:String,_ binding:Binding<Double>)->some View {
    HStack {Text(label);Spacer();TextField(label,value:binding,format:.number.precision(.fractionLength(0...2)))
      .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:82);Text("mm").foregroundStyle(Palette.secondary)}.font(.system(size:11))
  }
  @ViewBuilder private func region(_ index:Int)->some View {
    let current=draft.regions[index]
    VStack(alignment:.leading,spacing:8) {
      HStack {
        Text("Region \(index+1)").fontWeight(.medium);Spacer()
        Button {draft.regions.swapAt(index,index-1)} label:{Image(systemName:"arrow.up")}.disabled(index==0)
        Button {draft.regions.swapAt(index,index+1)} label:{Image(systemName:"arrow.down")}.disabled(index+1>=draft.regions.count)
        Button {draft.regions.remove(at:index)} label:{Image(systemName:"trash")}
      }
      Menu("Sources · \(current.elementIDs.count)") {
        ForEach(sources) {element in
          Toggle(element.title,isOn:Binding(get:{draft.regions[index].elementIDs.contains(element.id)},set:{on in
            if on {draft.regions[index].elementIDs.append(element.id)} else {draft.regions[index].elementIDs.removeAll {$0==element.id}}
          }))
        }
      }
      Picker("Method",selection:Binding(get:{draft.regions[index].method},set:{draft.regions[index].method=$0;draft.regions[index].underlay=nil})) {ForEach(EmbroideryRegion.Method.allCases,id:\.self) {Text($0.rawValue.capitalized).tag($0)}}
      Picker("Thread",selection:$draft.regions[index].threadIndex) {ForEach(draft.threads.indices,id:\.self) {Text("\($0+1) · \(draft.threads[$0].name)").tag($0)}}
      number("Max stitch",$draft.regions[index].stitchLength)
      if current.method != .running {number(current.method == .fill ? "Row spacing":"Step along rail",$draft.regions[index].spacing)}
      if current.method == .satin {number("Satin width",$draft.regions[index].satinWidth)}
      if current.method == .fill {
        HStack {Text("Fill angle");Spacer();TextField("Angle",value:$draft.regions[index].angle,format:.number).textFieldStyle(.roundedBorder).frame(width:82);Text("°")}
      }
      if current.method != .running {
        Toggle(current.method == .satin ? "Center-walk underlay":"Sparse cross-fill underlay",isOn:Binding(get:{draft.regions[index].underlay != nil},set:{on in
          if on {var value=EmbroideryUnderlay(method:current.method == .satin ? .centerWalk:.sparseFill);value.spacing=max(2,current.spacing*2);draft.regions[index].underlay=value}
          else {draft.regions[index].underlay=nil}
        }))
        if current.underlay != nil {
          number("Underlay stitch",underlayValue(index,\.stitchLength))
          if current.method == .fill {number("Underlay spacing",underlayValue(index,\.spacing));number("Underlay inset",underlayValue(index,\.inset))}
        }
      }
    }.font(.system(size:10))
  }
  private func underlayValue(_ index:Int,_ key:WritableKeyPath<EmbroideryUnderlay,Double>)->Binding<Double> {
    Binding(get:{draft.regions[index].underlay?[keyPath:key] ?? 0},set:{draft.regions[index].underlay?[keyPath:key]=$0})
  }
  private func processValue(_ key:WritableKeyPath<EmbroideryProcess,Double>)->Binding<Double> {
    Binding(get:{draft.process?[keyPath:key] ?? EmbroideryProcess()[keyPath:key]},set:{draft.process?[keyPath:key]=$0})
  }
  private var processControls:some View {
    VStack(alignment:.leading,spacing:8) {
      Text("PROCESS · EXPLICIT SETTINGS").font(.system(size:9,weight:.semibold)).tracking(1)
      Toggle("Configure thread and locks",isOn:Binding(get:{draft.process != nil},set:{draft.process=$0 ? EmbroideryProcess():nil}))
      if draft.process != nil {
        number("Thread diameter",processValue(\.threadDiameter))
        Toggle("Tie in after thread start",isOn:Binding(get:{draft.process?.tieIn ?? false},set:{draft.process?.tieIn=$0}))
        Toggle("Tie off before trim/end",isOn:Binding(get:{draft.process?.tieOff ?? false},set:{draft.process?.tieOff=$0}))
        if draft.process?.tieIn == true || draft.process?.tieOff == true {
          number("Backtrack length",processValue(\.tieLength))
          Stepper("Repeats · \(draft.process?.tieRepeats ?? 2)",value:Binding(get:{draft.process?.tieRepeats ?? 2},set:{draft.process?.tieRepeats=$0}),in:1...3)
        }
      }
      Text("Locks follow an existing stitch segment. Center-walk satin and inset sparse-fill underlay are configured per region below.")
        .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
    }.font(.system(size:11))
  }
  private func addRegion() {if let source=sources.first {draft.regions.append(.init(elementIDs:[source.id],method:.running))}}
  private func removeThread(_ index:Int) {
    guard !draft.regions.contains(where:{$0.threadIndex==index}) else {error="Reassign this thread's regions before removing it.";return}
    draft.threads.remove(at:index)
    for i in draft.regions.indices where draft.regions[i].threadIndex>index {draft.regions[i].threadIndex-=1}
  }
  private func defaults() {
    guard let object,let project=store.project else {return}
    do {draft=try EmbroideryDigitizer.defaultDesign(object:object,project:project);rebuild()}
    catch {self.error=error.localizedDescription}
  }
  @discardableResult private func rebuild()->Bool {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard let object,let project=store.project else {error="The decoration is no longer in this project.";return false}
    do {program=try EmbroideryDigitizer.generate(object:object,project:project,design:draft);through=Double(program!.commands.count);dirty=false;error="";return true}
    catch {program=nil;through=0;self.error=error.localizedDescription;return false}
  }
  @discardableResult private func apply()->Bool {
    guard rebuild() else {return false}
    do {_ = try store.engine.call("form_update_object",arguments:["object_id":objectID.uuidString,"embroidery":try jsonObject(draft)],source:"Studio");store.changed();store.toast("Embroidery source saved");return true}
    catch {self.error=error.localizedDescription;return false}
  }
  private func remove() {
    do {_ = try store.engine.call("form_update_object",arguments:["object_id":objectID.uuidString,"embroidery":NSNull()],source:"Studio");store.changed();dismiss()}
    catch {self.error=error.localizedDescription}
  }
  private func export(_ format:String) {
    let panel=NSSavePanel();panel.nameFieldStringValue=(object?.name ?? "Embroidery")+"-stitches."+format
    panel.allowedContentTypes=[format == "svg" ? .svg:format == "json" ? .json:UTType(filenameExtension:"dst") ?? .data]
    guard panel.runModal() == .OK,let url=panel.url,apply(),let object else {return}
    do {_ = try store.exportEmbroidery(object:object,arguments:["format":format,"embroidery_format":format,"path":url.path,"show_jumps":showJumps]);store.toast("Embroidery exported");error=""}
    catch {self.error=error.localizedDescription}
  }
}

struct EmbroideryPreview:NSViewRepresentable {
  var program:EmbroideryProgram?
  var showJumps:Bool
  var through:Int
  func makeNSView(context:Context)->EmbroideryPreviewView {EmbroideryPreviewView()}
  func updateNSView(_ view:EmbroideryPreviewView,context:Context) {view.program=program;view.showJumps=showJumps;view.through=through;view.needsDisplay=true}
}
final class EmbroideryPreviewView:NSView {
  var program:EmbroideryProgram?
  var showJumps=true
  var through=Int.max
  override var isFlipped:Bool {true}
  override func draw(_ dirtyRect:NSRect) {
    NSColor(hex:"#F2F2F2").setFill();bounds.fill()
    guard let program,let context=NSGraphicsContext.current?.cgContext else {return}
    let w=program.design.hoopWidth,h=program.design.hoopHeight,scale=min((bounds.width-46)/w,(bounds.height-46)/h)
    guard scale>0 else {return}
    context.saveGState();context.translateBy(x:bounds.midX,y:bounds.midY);context.scaleBy(x:scale,y:scale)
    context.setStrokeColor(NSColor(hex:"#999999").cgColor);context.setLineWidth(0.3)
    context.stroke(.init(x:-w/2,y:-h/2,width:w,height:h))
    let m=program.design.margin
    context.setLineDash(phase:0,lengths:[1,1]);context.setLineWidth(0.15)
    context.stroke(.init(x:-w/2+m,y:-h/2+m,width:w-m*2,height:h-m*2));context.setLineDash(phase:0,lengths:[])
    EmbroideryRenderer.draw(program,context:context,showJumps:showJumps,through:through)
    context.restoreGState()
  }
}
