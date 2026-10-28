import FormCore
import SwiftUI

struct StudioCompositionWorkspace:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var controller:StudioCompositionController
  @State private var inspector="Camera"
  @State private var guides=false
  var body:some View {
    VStack(spacing:0) {
      if store.studioShowingShots {
        HStack {Button("Back to scenes"){store.studioShowingShots=false};Spacer();Text("Saved shots · existing project-camera workflow").font(.system(size:11)).foregroundStyle(Palette.secondary)}.padding(12)
        TableWorkspace()
      }else {
        HStack(spacing:0) {
          sceneList.frame(width:230)
          Divider()
          VStack(spacing:0) {
            HStack(alignment:.top) {
              EnvironmentPageHeading(eyebrow:"Studio · composition stage",title:controller.draft?.name ?? "Compose a scene.",detail:"Arrange linked products for an image or camera motion. Your design objects stay in place.")
              Spacer(minLength:0)
              Toggle("Guides",isOn:$guides).toggleStyle(.checkbox).font(.system(size:10))
            }.padding(20)
            stage.frame(minHeight:260,maxHeight:.infinity)
            timeline
          }.frame(minWidth:350,maxWidth:.infinity,maxHeight:.infinity)
          Divider()
          inspectorPanel.frame(width:290)
        }
        if let error=controller.error {HStack {Image(systemName:"exclamationmark.circle");Text(error).font(.system(size:11));Spacer();if controller.dirty {Button("Discard draft"){controller.discard()}}}.foregroundStyle(Palette.accent).padding(12).background(Color.white.opacity(0.7))}
        if controller.busy {HStack{ProgressView(value:controller.progress);Text("\(Int(controller.progress*100))%").font(.system(size:10,design:.monospaced));Button("Cancel export"){controller.cancelExport()}}.padding(12)}
      }
    }.onAppear{controller.reconcile()}.onChange(of:store.project?.id){_,_ in controller.reconcile()}.onChange(of:store.revision){_,_ in controller.reconcile()}.onChange(of:store.environment){_,value in if value != .studio {controller.stop()}}
      .focusedValue(\.designSurface,.studio)
  }
  private var sceneList:some View {
    VStack(alignment:.leading,spacing:14) {
      HStack{SectionLabel("SCENES");Spacer();Button{controller.newScene()}label:{Image(systemName:"plus")}.buttonStyle(.plain).accessibilityLabel("New Studio scene")}
      Menu(controller.draft?.name ?? "Choose a scene") {
        ForEach(controller.scenes){scene in Button(scene.name){controller.load(scene.id)}}
      }.accessibilityLabel("Saved Studio scenes")
      HStack {Button("Save scene"){controller.save()}.buttonStyle(.borderedProminent).tint(Palette.ink);Menu{Button("Duplicate saved scene"){controller.duplicateScene()};Button("Delete saved scene",role:.destructive){controller.deleteScene()};Button("Discard draft"){controller.discard()}}label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize()}
      if controller.dirty {Text("Unsaved scene draft").font(.system(size:10)).foregroundStyle(Palette.accent)}
      Divider()
      Menu {
        ForEach(controller.products){object in Button(object.name){controller.add(object)}}
        Divider();Button("Shelf / riser prop"){controller.addShelf()}
      } label:{Label("Add to scene",systemImage:"plus")}.accessibilityLabel("Add presentation instance")
      ScrollView {
        VStack(spacing:6) {
          ForEach(controller.draft?.instances ?? []) {instance in
            Button {controller.selectedInstanceID=instance.id;inspector="Instance";controller.sync()}label:{
              HStack(alignment:.top,spacing:9) {
                Image(systemName:instance.prop != nil ? "rectangle.3.group":"cube.transparent").frame(width:22)
                VStack(alignment:.leading,spacing:4) {Text(instance.name).font(.system(size:11,weight:.medium));Text(instance.prop != nil ? "Presentation prop":"Linked product instance").font(.system(size:9)).foregroundStyle(Palette.secondary)}
                Spacer(minLength:0)
                Image(systemName:instance.visible ? "eye":"eye.slash").font(.system(size:10)).foregroundStyle(Palette.secondary)
              }.padding(10).background(controller.selectedInstanceID==instance.id ? Color.white:Color.clear,in:RoundedRectangle(cornerRadius:7))
            }.buttonStyle(.plain).accessibilityLabel("Scene instance "+instance.name)
          }
        }
      }
      HStack {Button{controller.duplicateInstance()}label:{Image(systemName:"plus.square.on.square")}.help("Duplicate selected instance").accessibilityLabel("Duplicate Studio instance");Button{controller.removeInstance()}label:{Image(systemName:"minus")}.help("Remove from scene").accessibilityLabel("Remove Studio instance")}.disabled(controller.selected==nil)
      Divider()
      Button("Existing saved shots…"){store.studioShowingShots=true}.font(.system(size:10)).buttonStyle(.plain)
      Text("Instances stay linked to their design. Replacing a source selects another product or variant; it does not edit that design.").font(.system(size:10)).foregroundStyle(Palette.secondary)
    }.padding(18).disabled(controller.busy)
  }
  private var stage:some View {
    GeometryReader {g in
      let raw=controller.draft?.pixels.aspect ?? 1.5,aspect=raw.isFinite && raw>0 ? min(8,max(0.125,raw)):1.5,w=min(max(1,g.size.width-32),max(1,g.size.height-52)*aspect),h=w/aspect
      ZStack {
        Color(nsColor:.windowBackgroundColor)
        StudioCompositionViewport(controller:controller).frame(width:w,height:h).overlay {
          if guides {Canvas{context,size in var path=Path();for f in [1.0/3,2.0/3]{path.move(to:.init(x:size.width*f,y:0));path.addLine(to:.init(x:size.width*f,y:size.height));path.move(to:.init(x:0,y:size.height*f));path.addLine(to:.init(x:size.width,y:size.height*f))};context.stroke(path,with:.color(.white.opacity(0.4)),lineWidth:0.7)}.allowsHitTesting(false)}
        }.overlay(Rectangle().stroke(Palette.line)).position(x:g.size.width/2,y:g.size.height/2-8)
        VStack{Spacer();HStack{Button("Frame scene"){controller.frameScene()};Spacer();Text("Drag to orbit · Shift-drag to pan · Scroll to zoom").foregroundStyle(Palette.secondary)}.font(.system(size:10)).padding(12)}
      }
    }
  }
  private var inspectorPanel:some View {
    ScrollView {
      VStack(alignment:.leading,spacing:18) {
        Picker("Studio inspector",selection:$inspector){Text("Camera").tag("Camera");Text("Instance").tag("Instance");Text("Light").tag("Light")}.pickerStyle(.segmented).labelsHidden()
        if let scene=controller.draft {
          if inspector=="Camera" {camera(scene)}
          else if inspector=="Instance" {instanceEditor}
          else {lighting(scene)}
          Divider();SectionLabel("IMAGE OUTPUT")
          TextField("Scene name",text:Binding(get:{controller.draft?.name ?? ""},set:{value in controller.change{$0.name=value}})).textFieldStyle(.roundedBorder).accessibilityLabel("Studio scene name")
          HStack {TextField("Width",value:Binding(get:{scene.pixels.width},set:{value in controller.change{$0.pixels.width=value}}),format:.number.grouping(.never));Text("×");TextField("Height",value:Binding(get:{scene.pixels.height},set:{value in controller.change{$0.pixels.height=value}}),format:.number.grouping(.never));Text("px")}.textFieldStyle(.roundedBorder).font(.system(size:11))
          Button("Export image…"){controller.exportDialog(video:false)}.frame(maxWidth:.infinity).accessibilityLabel("Export Studio composition image")
          let pixels=StudioSceneMedia.videoPixels(scene.pixels)
          Text("Video: \(pixels.width) × \(pixels.height) · H.264 · camera motion").font(.system(size:10)).foregroundStyle(Palette.secondary)
          Button("Export video…"){controller.exportDialog(video:true)}.buttonStyle(.borderedProminent).tint(Palette.ink).frame(maxWidth:.infinity).accessibilityLabel("Export Studio camera video")
          if let output=controller.lastOutput {Button("Show "+output.lastPathComponent){NSWorkspace.shared.activateFileViewerSelecting([output])}.font(.system(size:10))}
        }
      }.font(.system(size:11)).padding(18)
    }.disabled(controller.busy)
  }
  private func camera(_ scene:StudioComposition)->some View {
    VStack(alignment:.leading,spacing:14) {
      SectionLabel("CAMERA & FRAMING")
      Picker("Projection",selection:Binding(get:{scene.camera.projection},set:{value in controller.change{$0.camera.projection=value}})){Text("Perspective").tag("perspective");Text("Orthographic").tag("orthographic")}
      field("Yaw",value:scene.camera.azimuth*180 / .pi,unit:"°"){value in controller.change{$0.camera.azimuth=value * .pi/180;$0.camera.orientation=nil}}
      field("Elevation",value:scene.camera.elevation*180 / .pi,unit:"°"){value in controller.change{$0.camera.elevation=value * .pi/180;$0.camera.orientation=nil}}
      field("Distance",value:scene.camera.distance*100,unit:"mm"){value in controller.change{$0.camera.distance=value/100}}
      Divider();SectionLabel("TARGET · MILLIMETERS")
      field("X",value:scene.camera.target.x*100,unit:"mm"){value in controller.change{$0.camera.target.x=value/100}}
      field("Y",value:scene.camera.target.y*100,unit:"mm"){value in controller.change{$0.camera.target.y=value/100}}
      field("Z",value:scene.camera.target.z*100,unit:"mm"){value in controller.change{$0.camera.target.z=value/100}}
      Button("Frame all scene instances"){controller.frameScene()}
      Text("The Studio camera belongs to this presentation. It leaves the design camera unchanged. Perspective uses LAB's 39° vertical field of view.").font(.system(size:10)).foregroundStyle(Palette.secondary)
    }
  }
  @ViewBuilder private var instanceEditor:some View {
    if let instance=controller.selected {
      SectionLabel("PRESENTATION INSTANCE")
      TextField("Instance name",text:Binding(get:{instance.name},set:{value in controller.changeInstance{$0.name=value}})).textFieldStyle(.roundedBorder)
      Toggle("Visible",isOn:Binding(get:{instance.visible},set:{value in controller.changeInstance{$0.visible=value}}))
      if instance.prop==nil {
        Picker("Product / variant",selection:Binding<UUID?>(get:{instance.sourceObjectID},set:{value in controller.changeInstance{$0.sourceObjectID=value;$0.materialID=nil}})){
          if !controller.products.contains(where:{$0.id==instance.sourceObjectID}) {Text("Missing source · replace").tag(instance.sourceObjectID)}
          ForEach(controller.products){object in Text(object.name).tag(Optional(object.id))}
        }.accessibilityLabel("Studio instance product variant")
        if controller.products.first(where:{$0.id==instance.sourceObjectID})?.meshAsset != nil {
          Text("Material slots come from the authored source. Choose a source colorway to change them.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }else {Picker("Appearance",selection:Binding<String?>(get:{instance.materialID},set:{value in controller.changeInstance{$0.materialID=value}})){Text("From source design").tag(String?.none);ForEach(store.materials){material in Text(material.name).tag(Optional(material.id))}}}
      }else if let prop=instance.prop {
        field("Prop width",value:prop.widthMM,unit:"mm"){value in controller.changeInstance{$0.prop?.widthMM=value}}
        field("Prop height",value:prop.heightMM,unit:"mm"){value in controller.changeInstance{$0.prop?.heightMM=value}}
        field("Prop depth",value:prop.depthMM,unit:"mm"){value in controller.changeInstance{$0.prop?.depthMM=value}}
        TextField("Prop color #RRGGBB",text:Binding(get:{prop.color},set:{value in controller.changeInstance{$0.prop?.color=value}})).textFieldStyle(.roundedBorder)
      }
      Divider();SectionLabel("PLACEMENT · MILLIMETERS")
      field("X",value:instance.positionMM.x,unit:"mm"){value in controller.changeInstance{$0.positionMM.x=value}}
      field("Y",value:instance.positionMM.y,unit:"mm"){value in controller.changeInstance{$0.positionMM.y=value}}
      field("Z",value:instance.positionMM.z,unit:"mm"){value in controller.changeInstance{$0.positionMM.z=value}}
      field("Rotation",value:instance.rotationDegrees,unit:"°"){value in controller.changeInstance{$0.rotationDegrees=value}}
      Button("Duplicate instance"){controller.duplicateInstance()}
      Text("Placement affects this scene instance only.").font(.system(size:10)).foregroundStyle(Palette.secondary)
    }else {Text("Choose a scene instance to position it or replace its product source.").foregroundStyle(Palette.secondary)}
  }
  private func lighting(_ scene:StudioComposition)->some View {
    VStack(alignment:.leading,spacing:16) {
      SectionLabel("LIGHTING")
      Picker("Setup",selection:Binding(get:{scene.lighting},set:{value in controller.change{$0.lighting=value}})){Text("Classic").tag("classic-v1");Text("Soft side").tag("soft-side-v1");Text("Rim").tag("rim-v1")}
      SectionLabel("BACKDROP")
      ForEach(StudioShot.surfaces,id:\.self){surface in Button{controller.change{$0.surface=surface}}label:{HStack{Circle().fill(surface=="Graphite" ? Color.gray:surface=="Warm paper" ? Color(nsColor:NSColor(hex:"#D9C6A0")):.white).frame(width:26,height:26).overlay(Circle().stroke(Palette.line));Text(surface);Spacer();if scene.surface==surface {Image(systemName:"checkmark").foregroundStyle(Palette.accent)}}.padding(9).background(Color.white.opacity(0.5),in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)}
    }
  }
  private var timeline:some View {
    VStack(alignment:.leading,spacing:12) {
      HStack {SectionLabel("CAMERA MOTION");Spacer();Button("Capture start"){controller.captureStart()};Button("Capture end"){controller.captureEnd()}}
      if let scene=controller.draft {
        HStack(spacing:14) {
          Button{controller.playing ? controller.stop():controller.play()}label:{Image(systemName:controller.playing ? "pause.fill":"play.fill").frame(width:28,height:28)}.accessibilityLabel("Play Studio camera motion")
          Slider(value:Binding(get:{controller.time},set:{controller.scrub($0)}),in:0...1).accessibilityLabel("Studio camera motion time")
          Text(String(format:"%.1f / %.1f s",controller.time*scene.motion.seconds,scene.motion.seconds)).font(.system(size:10,design:.monospaced)).frame(width:90)
        }
        ViewThatFits(in:.horizontal) {
          HStack {motionKind(scene);motionDuration(scene);motionOrbit(scene);motionFPS(scene)}
          VStack(alignment:.leading,spacing:10) {HStack{motionKind(scene);motionFPS(scene);Spacer(minLength:0)};HStack{motionDuration(scene);motionOrbit(scene);Spacer(minLength:0)}}
        }.font(.system(size:10))
      }
    }.padding(18).background(Palette.paper).overlay(alignment:.top){Divider()}.disabled(controller.busy)
  }
  private func motionKind(_ scene:StudioComposition)->some View {Picker("Motion",selection:Binding(get:{scene.motion.mode},set:{value in controller.change{$0.motion.mode=value}})){Text("Orbit").tag(StudioMotion.Mode.orbit);Text("Start → end").tag(StudioMotion.Mode.between)}.frame(width:180)}
  private func motionDuration(_ scene:StudioComposition)->some View {field("Duration",value:scene.motion.seconds,unit:"s"){value in controller.change{$0.motion.seconds=value}}.frame(width:160)}
  @ViewBuilder private func motionOrbit(_ scene:StudioComposition)->some View {if scene.motion.mode == .orbit {field("Orbit",value:scene.motion.orbitDegrees,unit:"°"){value in controller.change{$0.motion.orbitDegrees=value}}.frame(width:150)}}
  private func motionFPS(_ scene:StudioComposition)->some View {Picker("FPS",selection:Binding(get:{scene.motion.fps},set:{value in controller.change{$0.motion.fps=value}})){ForEach([12,24,30],id:\.self){Text(String($0)).tag($0)}}.frame(width:85)}
  private func field(_ title:String,value:Double,unit:String,set:@escaping(Double)->Void)->some View {
    HStack{Text(title);Spacer(minLength:4);TextField(title,value:Binding(get:{value},set:set),format:.number.grouping(.never).precision(.fractionLength(0...2))).font(Palette.numericFont).textFieldStyle(.roundedBorder).frame(width:72).accessibilityLabel("Studio "+title);Text(unit).foregroundStyle(Palette.secondary).frame(width:22,alignment:.leading)}.font(.system(size:11))
  }
}
