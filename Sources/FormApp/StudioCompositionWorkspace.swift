import FormCore
import SwiftUI

struct StudioCompositionWorkspace:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var controller:StudioCompositionController
  @State private var guides=false
  private var thumbnails:StudioSceneThumbnailCache {controller.thumbnails}
  var body:some View {
    VStack(spacing:0) {
      if store.studioShowingImages {
        StudioImageWorkspace(controller:store.studioImages,library:store.studioAssets,
          onBack:{store.studioShowingImages=false;if store.project == nil {store.home()}},
          onConnection:{store.showingOpenAISetup=true},
          onUseInCanvas:{id in if let asset=store.studioAssets.asset(id:id){store.placeLibraryAssetOnCanvas(asset)}})
      }else if store.studioShowingShots {
        HStack {Button("Back to scenes"){store.studioShowingShots=false};Spacer();Text("Saved shots · existing project-camera workflow").font(.system(size:11)).foregroundStyle(Palette.secondary)}.padding(12)
        TableWorkspace()
      }else {
        HStack(spacing:0) {
          sceneList.frame(width:176)
          Divider()
          VStack(spacing:0) {
            HStack(alignment:.top) {
              Text(controller.draft?.name ?? "Studio").font(.system(size:16,weight:.semibold)).lineLimit(1).truncationMode(.tail)
              Spacer(minLength:0)
              Toggle("Guides",isOn:$guides).inspectorToggle().font(.system(size:10))
            }.padding(.horizontal,18).padding(.vertical,12)
            stage.frame(minHeight:260,maxHeight:.infinity)
          }.frame(minWidth:350,maxWidth:.infinity,maxHeight:.infinity)
          Divider()
          inspectorPanel.frame(width:290)
        }
        if let error=controller.error {HStack {Image(systemName:"exclamationmark.circle");Text(error).font(.system(size:11));Spacer();if controller.dirty {Button("Discard draft"){controller.discard()}}}.foregroundStyle(Palette.accent).padding(12).background(Color.white.opacity(0.7))}
        if controller.busy {HStack{ProgressView(value:controller.progress);Text("\(Int(controller.progress*100))%").font(.system(size:10,design:.monospaced));Button("Cancel export"){controller.cancelExport()}}.padding(12)}
      }
    }.task(id:"\(store.project?.id.uuidString ?? "none"):\(store.revision):\(GeometryFactory.fontRevision)") {
      let project=store.project
      thumbnails.synchronize(project:project,assets:project.map{store.repository.url(for:$0.id).appendingPathComponent("Assets")})
    }.onDisappear{thumbnails.suspend()}.onAppear{controller.reconcile()}.onChange(of:store.project?.id){_,_ in controller.reconcile()}.onChange(of:store.revision){_,_ in controller.reconcile()}.onChange(of:store.environment){_,value in if value != .studio {controller.stop()}}
      .confirmationDialog("Save changes to \(controller.draft?.name ?? "this scene")?",isPresented:Binding(
        get:{controller.pendingSceneID != nil},set:{if !$0 {controller.cancelSceneSelection()}})) {
          if let id=controller.pendingSceneID {
            Button("Save and switch"){controller.saveAndLoadScene(id)}
            Button("Discard and switch",role:.destructive){controller.discardAndLoadScene(id)}
          }
          Button("Cancel",role:.cancel){controller.cancelSceneSelection()}
        } message:{Text("Choosing another saved scene replaces the current scene draft, including its camera and instance placement.")}
      .focusedValue(\.designSurface,.studio)
  }
  private var sceneList:some View {
    VStack(alignment:.leading,spacing:10) {
      HStack {
        SectionLabel("SCENES");Spacer(minLength:0)
        Menu {
          Button("Empty scene"){controller.newEmptyScene()}
          Button("From Table objects"){controller.newScene()}
        }label:{WorkspaceToolbarMenuLabel(symbol:"plus")}.menuStyle(.borderlessButton).fixedSize()
          .help("Create an empty scene or start with Table objects").accessibilityLabel("New Studio scene")
          .accessibilityIdentifier("studio-new-scene")
      }
      ScrollView {
        LazyVStack(spacing:10) {
          if controller.scenes.isEmpty {
            Text("Save a scene to keep its view here.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).padding(.vertical,20)
          }
          ForEach(controller.scenes){scene in
            StudioSceneThumbnail(cache:thumbnails,scene:scene,selected:controller.draft?.id==scene.id,
              preflight:{project,shot in try store.studioShots.runtimePreflight(project,shot)}){controller.requestScene(scene.id)}
              .contextMenu {
                SelectionReferenceMenuActions(store: store, reference: store.studioSelectionReference(sceneID: scene.id))
              }
          }
        }
      }.accessibilityLabel("Saved Studio scenes")
      if controller.dirty {Text("Unsaved scene draft").font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)}
      HStack(spacing:4) {
        WorkspaceToolbarButton("Save scene",symbol:"square.and.arrow.down",help:"Save this scene's camera and instance placement",showsTitle:true,identifier:"studio-save-scene"){controller.save()}
        Spacer(minLength:0)
        Menu {
          SelectionReferenceMenuActions(store: store,
            reference: controller.draft.flatMap { store.studioSelectionReference(sceneID: $0.id) })
          Divider()
          Button("Duplicate saved scene"){controller.duplicateScene()}
          Button("Delete saved scene",role:.destructive){controller.deleteScene()}
          Divider();Button("Discard draft"){controller.discard()}
          Divider();Button("Existing saved shots…"){store.studioShowingShots=true}
        }label:{WorkspaceToolbarMenuLabel(symbol:"ellipsis")}.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Studio scene actions")
      }
    }.padding(12).disabled(controller.busy)
  }
  private var stage:some View {
    GeometryReader {g in
      let raw=controller.draft?.pixels.aspect ?? 1.5,aspect=raw.isFinite && raw>0 ? min(8,max(0.125,raw)):1.5,w=min(max(1,g.size.width-32),max(1,g.size.height-16)*aspect),h=w/aspect
      ZStack {
        Color(nsColor:.windowBackgroundColor)
        StudioCompositionViewport(controller:controller).frame(width:w,height:h).overlay {
          if guides {Canvas{context,size in var path=Path();for f in [1.0/3,2.0/3]{path.move(to:.init(x:size.width*f,y:0));path.addLine(to:.init(x:size.width*f,y:size.height));path.move(to:.init(x:0,y:size.height*f));path.addLine(to:.init(x:size.width,y:size.height*f))};context.stroke(path,with:.color(.white.opacity(0.4)),lineWidth:0.7)}.allowsHitTesting(false)}
        }.overlay {
          if controller.draft?.instances.isEmpty == true {Text("Add a product or prop to start composing.").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary).allowsHitTesting(false)}
        }.overlay(Rectangle().stroke(Palette.line)).position(x:g.size.width/2,y:g.size.height/2)
        VStack {
          Spacer()
          WorkspaceToolbarSurface(maxWidth:max(1,g.size.width-24)) {
            Menu {
              ForEach(controller.products){object in Button(object.name){controller.add(object)}}
              Divider();Button("Shelf / riser prop"){controller.addShelf()}
            }label:{WorkspaceToolbarMenuLabel(symbol:"plus",value:"Add instance")}
              .menuStyle(.borderlessButton).fixedSize().help("Add a linked product, design alternative, or presentation prop")
              .accessibilityLabel("Add presentation instance").accessibilityIdentifier("studio-add-instance")
            WorkspaceToolbarDivider()
            WorkspaceToolbarButton("Studio transform handles",symbol:"move.3d",isSelected:controller.gizmoVisible,
              help:"Show XYZ move handles and a vertical rotation ring on the selected instance",value:controller.gizmoVisible ? "Shown":"Hidden",
              identifier:"studio-transform-handles"){controller.gizmoVisible.toggle()}
            WorkspaceToolbarDivider()
            WorkspaceToolbarButton("Orbit Studio camera",symbol:TableTool.orbit.symbol,isSelected:controller.tool == .orbit,
              help:"Orbit · O: drag the camera; Shift-drag pans; scroll zooms",identifier:"studio-tool-orbit"){controller.tool = .orbit}
            WorkspaceToolbarButton("Move Studio instance",symbol:TableTool.move.symbol,isSelected:controller.tool == .move,
              help:"Move · V: drag an instance along the table",identifier:"studio-tool-move"){controller.tool = .move}
            WorkspaceToolbarDivider()
            WorkspaceToolbarButton("Focus Studio selection",symbol:"viewfinder",help:"Focus · F: frame the selected scene instance",identifier:"studio-focus-selection"){controller.focusSelected()}
              .disabled(controller.selected==nil)
            WorkspaceToolbarButton("Frame Studio scene",symbol:"arrow.up.left.and.arrow.down.right",help:"Frame all visible scene instances",identifier:"studio-frame-scene"){controller.frameScene()}
          }.disabled(controller.busy || controller.playing).padding(.bottom,8)
        }
      }
    }
  }
  private var inspectorPanel:some View {
    VStack(spacing:0) {
      ScrollView {
        VStack(alignment:.leading,spacing:14) {
          if let scene=controller.draft {
            camera(scene)
            InspectorDivider()
            lighting(scene)
            InspectorDivider()
            VStack(alignment:.leading,spacing:8) {
              InspectorSectionHeader("INSTANCE")
              Picker("Studio instance",selection:Binding<UUID?>(get:{controller.selectedInstanceID},set:{controller.selectInstance($0)})) {
                Text("Choose an instance").tag(UUID?.none)
                ForEach(scene.instances){instance in Text(instance.name).tag(Optional(instance.id))}
              }.labelsHidden().inspectorPicker().accessibilityLabel("Studio instance")
                .disabled(scene.instances.isEmpty)
              instanceEditor
            }
          }
        }.font(InspectorStyle.labelFont).padding(18)
      }.accessibilityLabel("Studio scene controls")
      Divider()
      VStack(alignment:.leading,spacing:10) {
        if let scene=controller.draft {
          InspectorSectionHeader("IMAGE OUTPUT")
          TextField("Studio scene name",text:Binding(get:{controller.draft?.name ?? ""},set:{value in controller.change{$0.name=value}}))
            .textFieldStyle(InspectorTextFieldStyle()).accessibilityLabel("Studio scene name")
          HStack(spacing:8) {
            outputDimension("Width",scene:scene,width:true)
            Text("×").foregroundStyle(Palette.secondary)
            outputDimension("Height",scene:scene,width:false)
            Text("px").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          }.textFieldStyle(InspectorTextFieldStyle(numeric:true))
        }
        VStack(spacing:8) {
          StudioOutputAction("Save still…",symbol:"square.and.arrow.down",help:"Export the current composition as a native PNG with its render record",identifier:"studio-save-still"){controller.exportDialog(video:false)}
          StudioOutputAction("Generate image",symbol:"sparkles",primary:true,help:"Use a frozen image of this composition in the image workflow",identifier:"studio-generate-image"){store.createStudioStill()}
        }.disabled(controller.draft?.instances.contains(where:{$0.visible}) != true)
        if let output=controller.lastOutput {
          Button("Show "+output.lastPathComponent){NSWorkspace.shared.activateFileViewerSelecting([output])}.font(InspectorStyle.captionFont).lineLimit(1).truncationMode(.middle)
        }
      }.padding(18).accessibilityLabel("Studio image output")
    }.disabled(controller.busy)
  }
  private func outputDimension(_ title:String,scene:StudioComposition,width:Bool)->some View {
    let projectID=store.project?.id,sceneID=scene.id
    return ScalarArtworkField(title,value:Double(width ? scene.pixels.width:scene.pixels.height),
      layout:.stacked,accessibilityName:"Output "+title.lowercased()) { value in
      guard store.project?.id==projectID,controller.draft?.id==sceneID else{return}
      let integer=try StudioPixels.integer(NSNumber(value:value),name:"Output "+title.lowercased())
      controller.change { if width {$0.pixels.width=integer} else {$0.pixels.height=integer} }
    }
  }
  private func camera(_ scene:StudioComposition)->some View {
    VStack(alignment:.leading,spacing:8) {
      InspectorSectionHeader("CAMERA")
        .help("The Studio camera belongs to this scene. Perspective uses a 39° vertical field of view.")
      HStack(alignment:.top,spacing:8) {
        VStack(alignment:.leading,spacing:4) {
          Text("Projection").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          Picker("Camera projection",selection:Binding(get:{scene.camera.projection},set:{value in controller.change{$0.camera.projection=value}})) {
            Text("Perspective").tag("perspective");Text("Orthographic").tag("orthographic")
          }.labelsHidden().inspectorPicker().frame(maxWidth:.infinity,minHeight:InspectorStyle.controlHeight,alignment:.leading)
        }.frame(maxWidth:.infinity)
        field("Distance",value:scene.camera.distance*100,unit:"mm",stacked:true,accessibilityName:"Camera distance"){value in controller.change{$0.camera.distance=value/100}}
      }
      HStack(spacing:8) {
        field("Yaw",value:scene.camera.azimuth*180 / .pi,unit:"°",stacked:true,accessibilityName:"Camera yaw"){value in controller.change{$0.camera.azimuth=value * .pi/180;$0.camera.orientation=nil}}
        field("Elevation",value:scene.camera.elevation*180 / .pi,unit:"°",stacked:true,accessibilityName:"Camera elevation"){value in controller.change{$0.camera.elevation=value * .pi/180;$0.camera.orientation=nil}}
      }
      HStack(spacing:8) {
        field("Target X",value:scene.camera.target.x*100,unit:"mm",stacked:true,accessibilityName:"Camera target X"){value in controller.change{$0.camera.target.x=value/100}}
        field("Y",value:scene.camera.target.y*100,unit:"mm",stacked:true,accessibilityName:"Camera target Y"){value in controller.change{$0.camera.target.y=value/100}}
        field("Z",value:scene.camera.target.z*100,unit:"mm",stacked:true,accessibilityName:"Camera target Z"){value in controller.change{$0.camera.target.z=value/100}}
      }
    }
  }
  @ViewBuilder private var instanceEditor:some View {
    if let instance=controller.selected {
      TextField("Instance name",text:Binding(get:{instance.name},set:{value in controller.changeInstance(id:instance.id){$0.name=value}})).textFieldStyle(InspectorTextFieldStyle())
      Toggle("Visible",isOn:Binding(get:{instance.visible},set:{value in controller.changeInstance(id:instance.id){$0.visible=value}})).inspectorToggle()
      if instance.prop==nil {
        Picker("Product / variant",selection:Binding<UUID?>(get:{instance.sourceObjectID},set:{value in controller.changeInstance(id:instance.id){$0.sourceObjectID=value;$0.materialID=nil}})){
          if !controller.products.contains(where:{$0.id==instance.sourceObjectID}) {Text("Missing source · replace").tag(instance.sourceObjectID)}
          ForEach(controller.products){object in Text(object.name).tag(Optional(object.id))}
        }.inspectorPicker().accessibilityLabel("Studio instance product variant")
        if controller.products.first(where:{$0.id==instance.sourceObjectID})?.meshAsset != nil {
          Text("Material slots come from the authored source. Choose a source colorway to change them.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }else {Picker("Appearance",selection:Binding<String?>(get:{instance.materialID},set:{value in controller.changeInstance(id:instance.id){$0.materialID=value}})){Text("From source design").tag(String?.none);ForEach(store.materials){material in Text(material.name).tag(Optional(material.id))}}.inspectorPicker()}
      }else if let prop=instance.prop {
        field("Prop width",value:prop.widthMM,unit:"mm"){value in controller.changeInstance(id:instance.id){$0.prop?.widthMM=value}}
        field("Prop height",value:prop.heightMM,unit:"mm"){value in controller.changeInstance(id:instance.id){$0.prop?.heightMM=value}}
        field("Prop depth",value:prop.depthMM,unit:"mm"){value in controller.changeInstance(id:instance.id){$0.prop?.depthMM=value}}
        TextField("Prop color #RRGGBB",text:Binding(get:{prop.color},set:{value in controller.changeInstance(id:instance.id){$0.prop?.color=value}})).textFieldStyle(InspectorTextFieldStyle())
      }
      Text("Position").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      HStack(spacing:8) {
        field("X",value:instance.positionMM.x,unit:"mm",stacked:true){value in controller.changeInstance(id:instance.id){$0.positionMM.x=value}}
        field("Height (Y)",value:instance.positionMM.y,unit:"mm",stacked:true){value in controller.changeInstance(id:instance.id){$0.positionMM.y=value}}
        field("Z",value:instance.positionMM.z,unit:"mm",stacked:true){value in controller.changeInstance(id:instance.id){$0.positionMM.z=value}}
      }
      field("Rotation",value:instance.rotationDegrees,unit:"°"){value in controller.changeInstance(id:instance.id){$0.rotationDegrees=value}}
        .help("Yaw around the vertical Y axis")
      HStack(spacing:6) {
        WorkspaceToolbarButton("Duplicate selected",symbol:"plus.square.on.square",help:"Add another linked instance of this product",showsTitle:true,identifier:"studio-duplicate-instance"){controller.duplicateInstance()}
        WorkspaceToolbarButton("Remove Studio instance",symbol:"trash",help:"Remove the selected instance from this scene",identifier:"studio-remove-instance"){controller.removeInstance()}
        Menu {
          SelectionReferenceMenuActions(store: store,
            reference: store.studioSelectionReference(sceneID: controller.draft?.id, instanceID: instance.id))
        } label: { WorkspaceToolbarMenuLabel(symbol: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Studio instance actions").accessibilityIdentifier("studio-instance-actions")
      }
    }else {Text("Select an object in the scene or choose one above to edit its placement.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
  }
  private func lighting(_ scene:StudioComposition)->some View {
    VStack(alignment:.leading,spacing:8) {
      InspectorSectionHeader("LIGHTING")
      Picker("Setup",selection:Binding(get:{scene.lighting},set:{value in controller.change{$0.lighting=value}})) {
        Text("Classic").tag("classic-v1");Text("Soft side").tag("soft-side-v1");Text("Rim").tag("rim-v1")
      }.inspectorPicker().accessibilityLabel("Studio lighting setup")
      Picker("Backdrop",selection:Binding(get:{scene.surface},set:{value in controller.change{$0.surface=value}})) {
        ForEach(StudioShot.surfaces,id:\.self){surface in Text(surface).tag(surface)}
      }.inspectorPicker().accessibilityLabel("Studio backdrop")
    }
  }
  @ViewBuilder private func field(_ title:String,value:Double,unit:String,stacked:Bool=false,accessibilityName:String?=nil,set:@escaping(Double)->Void)->some View {
    if unit == "mm" {
      ArtworkUnitField(title,value:value,unit:store.project?.unit == "in" ? .inches:.mm,layout:stacked ? .stacked:.row,accessibilityName:accessibilityName,set)
    }else {ScalarArtworkField(title,value:value,unit:unit,layout:stacked ? .stacked:.row,accessibilityName:accessibilityName,set)}
  }
}

/// Full-width inspector actions retain native keyboard and accessibility behavior.
private struct StudioOutputAction:NSViewRepresentable {
  let title:String,symbol:String,primary:Bool,help:String,identifier:String,action:()->Void
  @Environment(\.isEnabled) private var enabled
  init(_ title:String,symbol:String,primary:Bool=false,help:String,identifier:String,action:@escaping()->Void) {
    self.title=title;self.symbol=symbol;self.primary=primary;self.help=help;self.identifier=identifier;self.action=action
  }
  func makeCoordinator()->Coordinator {Coordinator(action)}
  func makeNSView(context:Context)->StudioOutputNativeButton {
    let button=StudioOutputNativeButton(frame:.zero);button.setButtonType(.momentaryPushIn);button.isBordered=false;button.focusRingType = .exterior
    button.target=context.coordinator;button.action=#selector(Coordinator.press(_:));updateNSView(button,context:context);return button
  }
  func updateNSView(_ button:StudioOutputNativeButton,context:Context) {
    context.coordinator.action=action;button.title=title;button.symbol=symbol;button.primary=primary;button.isEnabled=enabled;button.toolTip=help
    button.setAccessibilityLabel(title);button.setAccessibilityIdentifier(identifier);button.needsDisplay=true
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:StudioOutputNativeButton,context:Context)->CGSize? {.init(width:proposal.width ?? 254,height:WorkspaceToolbarMetrics.controlSize)}
  static func dismantleNSView(_ button:StudioOutputNativeButton,coordinator:Coordinator){button.target=nil;button.action=nil;coordinator.action={}}
  final class Coordinator:NSObject {
    var action:()->Void
    init(_ action:@escaping()->Void){self.action=action}
    @objc func press(_ sender:NSButton){if sender.isEnabled {action()}}
  }
}

private final class StudioOutputNativeButton:NSButton {
  var symbol="",primary=false
  override var alignmentRectInsets:NSEdgeInsets {.init(top:0,left:0,bottom:0,right:0)}
  override var intrinsicContentSize:NSSize {.init(width:NSView.noIntrinsicMetric,height:WorkspaceToolbarMetrics.controlSize)}
  override var acceptsFirstResponder:Bool {isEnabled}
  override func isAccessibilityElement()->Bool {true}
  override func accessibilityRole()->NSAccessibility.Role? {.button}
  override func accessibilityPerformPress()->Bool {guard isEnabled,action != nil,target != nil else{return false};performClick(nil);return true}
  override func hitTest(_ point:NSPoint)->NSView? {isHiddenOrHasHiddenAncestor || alphaValue<=0 || !bounds.contains(convert(point,from:superview)) ? nil:self}
  override func draw(_ dirtyRect:NSRect) {
    NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
    if !isEnabled {NSGraphicsContext.current?.cgContext.setAlpha(0.4)}
    let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:InspectorStyle.controlRadius,yRadius:InspectorStyle.controlRadius)
    NSColor(primary ? Palette.ink:isHighlighted ? Palette.line:Palette.surface).setFill();path.fill()
    if !primary {NSColor(Palette.line).setStroke();path.lineWidth=0.75;path.stroke()}
    let foreground=primary ? NSColor.white:NSColor(Palette.ink),font=NSFont.systemFont(ofSize:11,weight:.medium)
    let label=NSAttributedString(string:title,attributes:[.font:font,.foregroundColor:foreground]),text=label.size(),total=text.width+20
    let original=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:WorkspaceToolbarMetrics.symbolSize,weight:.medium))
    let image=original.map { original in
      NSImage(size:.init(width:14,height:14),flipped:false){rect in original.draw(in:rect);foreground.setFill();rect.fill(using:.sourceIn);return true}
    }
    image?.draw(in:CGRect(x:bounds.midX-total/2,y:bounds.midY-7,width:14,height:14),from:.zero,operation:.sourceOver,fraction:1)
    label.draw(at:CGPoint(x:bounds.midX-total/2+20,y:bounds.midY-text.height/2))
    if window?.firstResponder === self {NSColor.keyboardFocusIndicatorColor.setStroke();path.lineWidth=2;path.stroke()}
  }
}
