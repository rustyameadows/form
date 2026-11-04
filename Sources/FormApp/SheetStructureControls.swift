import AppKit
import FormCADModel
import FormCore
import SwiftUI

/// Shared stock edits keep the face profile and the physical cut-edge plies in
/// agreement. None of these controls writes artwork background or printing ink.
enum SheetStockControlEditing {
  static func setCaliper(_ amount:Double,in stock:inout PaperStock) {
    let old=stock.resolvedThicknessMM
    if stock.plies != nil,old>0 {for index in stock.plies!.indices {stock.plies![index].thicknessMM *= amount/old}}
    stock.thicknessMM=amount
  }
  static func setColor(_ color:String,in stock:inout PaperStock) {
    var profile=stock.profile ?? .init();profile.color=color;stock.profile=profile
  }
  static func setSurface(in stock:inout PaperStock,_ change:(inout PaperSurfaceProfile)->Void) {
    var profile=stock.profile ?? .init();change(&profile);stock.profile=profile
    for index in stock.plies?.indices ?? 0..<0 {
      if var explicit=stock.plies![index].profile {change(&explicit);stock.plies![index].profile=explicit}
    }
  }
}

struct SheetStockControls:View {
  @EnvironmentObject private var store:StudioStore
  @Binding var stock:PaperStock
  let targetID:String
  var caliperIsDerived=false
  var onEditingChanged:(Bool)->Void = {_ in}
  private func update(_ edit:(inout PaperStock)->Void) {
    var value=stock;edit(&value)
    if value.plies != nil {value.thicknessMM=value.resolvedThicknessMM}
    stock=value
  }
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      PublicationCommittedField(title:"Stock name",value:stock.name,allowsEmpty:false){name in update{$0.name=name}}
        .textFieldStyle(InspectorTextFieldStyle())
      Menu("Choose material stock") {
        ForEach(Array(PaperAppearanceCommands.presets.enumerated()),id:\.offset){_,preset in Button(preset.name){stock=preset}}
        if store.library.materials.contains(where:{$0.paperStock != nil}) {
          Divider()
          ForEach(store.library.materials.filter{$0.paperStock != nil}){material in
            Button(material.name){if let saved=material.paperStock {stock=saved}}
          }
        }
      }.menuStyle(.borderlessButton).font(InspectorStyle.labelFont)
      ArtworkUnitField(caliperIsDerived ? "Base caliper":"Caliper",value:stock.resolvedThicknessMM,unit:.mm,accessibilityName:"Material stock caliper"){amount in
        update{SheetStockControlEditing.setCaliper(amount,in:&$0)}
      }.disabled(caliperIsDerived)
      if caliperIsDerived {Text("Physical caliper follows the expression below; the base stock retains its material properties.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      if let plies=stock.plies {
        ForEach(plies){ply in
          InspectorColorPicker(ply.name,selection:Binding(get:{Color(nsColor:NSColor(hex:SheetParentStockEditing.color(of:ply)))},set:{color in
            update{SheetParentStockEditing.setColor(NSColor(color).hexString,plyID:ply.id,in:&$0)}
          }),supportsOpacity:false,targetID:targetID+ply.id.uuidString,onEditingChanged:onEditingChanged)
        }
      }else{
        InspectorColorPicker("Stock color",selection:Binding(get:{Color(nsColor:NSColor(hex:stock.profile?.color ?? "#F7F5EF"))},set:{color in
          update{SheetStockControlEditing.setColor(NSColor(color).hexString,in:&$0)}
        }),supportsOpacity:false,targetID:targetID+"-color",onEditingChanged:onEditingChanged)
        Menu("Stock color shortcuts") {
          Button("Paper white"){update{SheetStockControlEditing.setColor("#F7F5EF",in:&$0)}}
          Button("Pale yellow"){update{SheetStockControlEditing.setColor("#F3E6A4",in:&$0)}}
          Button("Natural kraft"){update{SheetStockControlEditing.setColor("#C7AE83",in:&$0)}}
        }.menuStyle(.borderlessButton).font(InspectorStyle.captionFont)
      }
      Picker("Grain",selection:Binding(get:{stock.grain},set:{value in update{$0.grain=value}})) {
        Text("Unspecified").tag(PaperStock.Grain.unknown)
        Text("Along height").tag(PaperStock.Grain.parallelHeight)
        Text("Along width").tag(PaperStock.Grain.parallelWidth)
      }.inspectorPicker()
      Picker("Texture",selection:Binding<PaperSurfaceProfile.Texture?>(get:{SheetParentStockEditing.texture(in:stock)},set:{value in
        if let value {update{SheetParentStockEditing.setTexture(value,in:&$0)}}
      })) {
        Text("Mixed").tag(PaperSurfaceProfile.Texture?.none)
        ForEach(PaperSurfaceProfile.Texture.allCases,id:\.self){Text($0.rawValue.capitalized).tag(Optional($0))}
      }.inspectorPicker()
      DisclosureGroup("Surface detail") {
        let profile=stock.profile ?? PaperSurfaceProfile()
        VStack(spacing:8) {
          ScalarArtworkField("Opacity",value:profile.opacity,unit:""){amount in update{SheetStockControlEditing.setSurface(in:&$0){$0.opacity=amount}}}
          ScalarArtworkField("Roughness",value:profile.roughness,unit:""){amount in update{SheetStockControlEditing.setSurface(in:&$0){$0.roughness=amount}}}
          ArtworkUnitField("Texture scale",value:profile.textureScaleMM,unit:.mm){amount in update{SheetStockControlEditing.setSurface(in:&$0){$0.textureScaleMM=amount}}}
          ArtworkUnitField("Texture depth",value:profile.textureDepthMM,unit:.mm){amount in update{SheetStockControlEditing.setSurface(in:&$0){$0.textureDepthMM=amount}}}
        }.padding(.top,8)
      }.font(InspectorStyle.labelFont)
      Text("Material color, not printed ink.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
    }.accessibilityElement(children:.contain).accessibilityLabel("Material stock")
  }
}

/// Expression values remain authored source. Choosing a parameter writes its
/// identifier, not a sampled number that would sever the dimension dependency.
struct SheetExpressionField:View {
  let title:String
  @Binding var value:CADScalar
  var parameters:[String]=[]
  var unit="mm"
  @State private var draft=""
  @FocusState private var focused:Bool
  private func commit() {
    let source=draft.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !source.isEmpty,source.utf8.count<=256 else{draft=value.expression;return}
    if source != value.expression {value=CADScalar(source)}
  }
  var body:some View {
    InspectorRow(title) {
      TextField(title,text:$draft).textFieldStyle(InspectorTextFieldStyle(numeric:true)).focused($focused)
        .onAppear{draft=value.expression}.onChange(of:value.expression){_,source in if !focused {draft=source}}
        .onSubmit{commit()}.onChange(of:focused){_,active in if !active {commit()}}
        .accessibilityLabel(title).accessibilityIdentifier("sheet-expression-"+title)
      if !unit.isEmpty {Text(unit).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      if !parameters.isEmpty {
        Menu {ForEach(parameters,id:\.self){name in Button(name){draft=name;commit()}}}label:{Image(systemName:"function")}
          .menuStyle(.borderlessButton).fixedSize().help("Use an authored parameter")
      }
    }
  }
}

struct SheetSourceFaceControls:View {
  @ObservedObject var session:ArtworkSession
  @Binding var face:SheetAssemblyFace?
  let title:String
  var parameters:[String]=[]
  var onCreateArtwork:(()->Void)?=nil
  private var sources:[ProductObject] {
    guard let project=session.store?.project else{return []}
    return project.objects.filter{project.isIndependentFlatArtworkSource($0) || (!$0.isCanvasWorkspace && PaperConstruction.isPaper($0))}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:7) {
      Picker(title,selection:Binding<UUID?>(get:{face?.sourceObjectID},set:{id in face=id.map{SheetAssemblyFace(sourceObjectID:$0)}})) {
        Text("Unprinted").tag(UUID?.none)
        ForEach(sources){source in Text(source.name).tag(Optional(source.id))}
        if let id=face?.sourceObjectID,!sources.contains(where:{$0.id==id}) {Text("Missing source").tag(Optional(id))}
      }.inspectorPicker()
      if face==nil,let onCreateArtwork {Button("Create artwork source",action:onCreateArtwork).buttonStyle(InspectorActionStyle())}
      if let current=face {
        HStack {
          Button("Edit artwork on Canvas") {
            guard let store=session.store,store.project?.objects.contains(where:{$0.id==current.sourceObjectID})==true else{return}
            store.showSurface(.artwork,ensureCanvasIfNeeded:false);session.activate(current.sourceObjectID)
            session.canvas?.synchronize();_=session.canvas?.fit(frameIDs:[current.sourceObjectID])
          }.buttonStyle(InspectorActionStyle())
        }
        if let source=sources.first(where:{$0.id==current.sourceObjectID}),PaperConstruction.isPaper(source) {
          Picker("Source side",selection:Binding(get:{current.sourceSide},set:{side in var changed=current;changed.sourceSide=side;face=changed})) {
            Text("Outside").tag(PaperFinishAssignment.Side.outside);Text("Inside").tag(PaperFinishAssignment.Side.inside)
          }.inspectorPicker()
        }
        DisclosureGroup("Artwork registration") {
          VStack(spacing:8) {
            SheetExpressionField(title:"Origin X",value:Binding(get:{current.sourceOriginMM?.x ?? 0},set:{v in var f=current;if f.sourceOriginMM==nil {f.sourceOriginMM = .init(0,0)};f.sourceOriginMM!.x=v;face=f}),parameters:parameters)
            SheetExpressionField(title:"Origin Y",value:Binding(get:{current.sourceOriginMM?.y ?? 0},set:{v in var f=current;if f.sourceOriginMM==nil {f.sourceOriginMM = .init(0,0)};f.sourceOriginMM!.y=v;face=f}),parameters:parameters)
          }.padding(.top,8)
        }.font(InspectorStyle.labelFont)
      }
    }
  }
}

@MainActor enum SheetAssemblySourceEditing {
  /// Creating the ordinary source and assigning its physical consumer are one
  /// validated document edit. Failed proposals leave any native draft intact.
  @discardableResult static func create(session:ArtworkSession,projectID:UUID,objectID:UUID,name:String,size:Point2,
    assign:(inout SheetAssemblyDefinition,SheetAssemblyFace)throws->Void)->UUID? {
    guard let store=session.store,let source=store.project,source.id==projectID,
      source.objects.contains(where:{$0.id==objectID && !$0.locked}) else{return nil}
    do {
      guard session.canvas?.activeTextView?.hasMarkedText() != true,
        session.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true else{throw FormError.invalid("Finish the current text input before creating surface artwork.")}
      func apply(_ project:inout Project)throws->UUID {
        guard var definition=project.objects.first(where:{$0.id==objectID})?.sheetAssembly else{throw FormError.missing("Physical assembly not found.")}
        let id=try SheetAssemblyCommands.createArtworkSource(in:&project,name:name,size:size)
        try assign(&definition,.init(sourceObjectID:id))
        try SheetAssemblyCommands.configure(in:&project,objectID:objectID,definition:definition)
        return id
      }
      var proposal=source;_=try apply(&proposal)
      session.canvas?.finishText();var id:UUID?
      try store.engine.edit("Created linked surface artwork",source:"Studio"){id=try apply(&$0)}
      store.changed()
      if let id {store.showSurface(.artwork,ensureCanvasIfNeeded:false);session.activate(id);session.choose([]);session.canvas?.synchronize();_=session.canvas?.fit(frameIDs:[id])}
      return id
    }catch{store.error=error.localizedDescription;return nil}
  }
}

struct SheetStructureControls:View {
  @ObservedObject var session:ArtworkSession
  @Binding var definition:SheetAssemblyDefinition
  let objectID:UUID
  var parameters:[String]=[]
  var onEditingChanged:(Bool)->Void = {_ in}
  @State private var gatherSize=1
  private var project:Project? {session.store?.project}
  private var object:ProductObject? {project?.objects.first{$0.id==objectID}}
  private var measurements:SheetAssemblyMeasurements? {guard let project,let object else{return nil};return try? project.sheetAssemblyMeasurements(object)}
  private func update(_ edit:(inout SheetAssemblyDefinition)->Void){var value=definition;edit(&value);definition=value}
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      if let values=measurements {
        VStack(alignment:.leading,spacing:5) {
          Text("Text block \(String(format:"%.2f",values.textBlockThickness)) mm · spine \(String(format:"%.2f",values.spineThickness)) mm")
          Text("Closed \(String(format:"%.1f",values.closedWidth)) × \(String(format:"%.1f",values.closedHeight)) × \(String(format:"%.2f",values.closedThickness)) mm")
        }.font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).accessibilityIdentifier("sheet-construction-measurements")
      }
      DisclosureGroup("Interior material stock") {
        SheetStockControls(stock:$definition.stock,targetID:"sheet-interior-"+objectID.uuidString,onEditingChanged:onEditingChanged).padding(.top,8)
        if definition.parentSheets?.isEmpty==false {Text("Declared parent sheets own their individual stocks below.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      }
      expressions
      signatures
      auxiliary
      edgeArtwork
    }.font(InspectorStyle.labelFont)
  }
  private var expressions:some View {
    DisclosureGroup("Derived expressions (\(definition.derived?.count ?? 0))") {
      VStack(alignment:.leading,spacing:8) {
        Text("Shared named arithmetic, resolved from the same construction parameters. Changes validate before replacing accepted geometry.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        ForEach((definition.derived ?? [:]).keys.sorted(),id:\.self){name in
          HStack(spacing:6) {
            SheetExpressionField(title:name,value:Binding(get:{CADScalar(definition.derived?[name] ?? "0")},set:{source in update{$0.derived?[name]=source.expression}}),parameters:parameters,unit:"")
            AppCloseButton("Remove derived expression"){update{$0.derived?.removeValue(forKey:name)}}
          }
        }
        Button("Add derived expression") {
          var ordinal=1
          let occupied=Set(parameters).union(definition.derived?.keys.map{$0} ?? [])
          while occupied.contains("expression\(ordinal)"){ordinal+=1}
          update{if $0.derived==nil {$0.derived=[:]};$0.derived!["expression\(ordinal)"]="0"}
        }.buttonStyle(InspectorActionStyle()).disabled((definition.derived?.count ?? 0)>=256)
      }.padding(.top,8)
    }
  }
  private var signatures:some View {
    DisclosureGroup("Gathered signatures") {
      VStack(alignment:.leading,spacing:8) {
        if let parents=definition.parentSheets,!parents.isEmpty {
          Text("\(parents.count) parent sheets · \(definition.signatures?.count ?? 1) gathers")
            .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          ScalarArtworkField("Sheets per gather",value:Double(gatherSize),unit:""){value in
            guard value.isFinite,value.rounded()==value,(1...51).contains(value) else{throw FormError.invalid("Use one to fifty-one whole parent sheets per gather.")};gatherSize=Int(value)
          }
          Button("Regroup signatures"){regroup(gatherSize)}.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("sheet-regroup-signatures")
          if definition.signatures != nil {Button("Use one nested run"){regroup(0)}.buttonStyle(.borderless)}
          ForEach(Array((definition.signatures ?? []).enumerated()),id:\.element.id){index,signature in
            Text("Gather \(index+1) · \(signature.parentSheetIDs.count) sheets").font(InspectorStyle.captionFont)
          }
        }else{Text("Declare folded parent sheets before grouping gathers. Logical reader spreads remain independent of physical signatures.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      }.padding(.top,8)
    }
  }
  private func regroup(_ count:Int) {
    guard let project else{return}
    do {definition=try SheetAssemblyCommands.reimposingSignatures(in:project,objectID:objectID,parentSheetsPerSignature:count)}
    catch{session.store?.error=error.localizedDescription}
  }
  private var auxiliary:some View {
    DisclosureGroup("Endpapers & inserts (\(definition.auxiliaryLeaves?.count ?? 0))") {
      VStack(alignment:.leading,spacing:10) {
        ForEach(definition.auxiliaryLeaves ?? []){leaf in
          SheetAuxiliaryLeafControls(session:session,leaf:Binding(get:{definition.auxiliaryLeaves?.first{$0.id==leaf.id} ?? leaf},set:{changed in
            update{if let index=$0.auxiliaryLeaves?.firstIndex(where:{$0.id==leaf.id}) {$0.auxiliaryLeaves![index]=changed}}
          }),planes:definition.enclosure ?? [],parameters:parameters,onEditingChanged:onEditingChanged,create:{side in createAuxiliarySource(leaf,side:side)}){
            let count=object.flatMap{object in project.flatMap{try? $0.resolvedSheetAssembly(object).leaves.count}} ?? 1
            update{$0.auxiliaryLeaves?.removeAll{$0.id==leaf.id};$0.activeSpread=min($0.activeSpread,max(0,count-1))}
          }
        }
        Button("Add endpaper / insert") {
          update{let stock=$0.stock;if $0.auxiliaryLeaves==nil {$0.auxiliaryLeaves=[]};$0.auxiliaryLeaves!.append(.init(name:"Auxiliary sheet",stock:stock))}
        }.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("sheet-add-auxiliary-leaf")
      }.padding(.top,8)
    }
  }
  private func createAuxiliarySource(_ leaf:SheetAssemblyAuxiliaryLeaf,side:PaperFinishAssignment.Side) {
    guard let project,let object,let resolved=try? project.resolvedSheetAssembly(object),let target=resolved.leaves.first(where:{$0.auxiliaryID==leaf.id}) else{return}
    _=SheetAssemblySourceEditing.create(session:session,projectID:project.id,objectID:objectID,name:leaf.name+(side == .inside ? " / Back":" / Front"),size:target.size){model,face in
      guard let index=model.auxiliaryLeaves?.firstIndex(where:{$0.id==leaf.id}) else{throw FormError.missing("The auxiliary sheet was removed. Choose a current surface.")}
      if side == .inside {model.auxiliaryLeaves![index].back=face}else{model.auxiliaryLeaves![index].front=face}
    }
  }
  private func edge(_ key:WritableKeyPath<SheetEdgeArtwork,SheetAssemblyFace?>)->Binding<SheetAssemblyFace?> {
    .init(get:{definition.edgeArtwork?[keyPath:key]},set:{face in update{if $0.edgeArtwork==nil {$0.edgeArtwork = .init()};$0.edgeArtwork![keyPath:key]=face}})
  }
  private var edgeArtwork:some View {
    DisclosureGroup("Page-edge artwork") {
      VStack(alignment:.leading,spacing:9) {
        Text("Registered across the closed block, separate from stock and page-face printing.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        SheetSourceFaceControls(session:session,face:edge(\.head),title:"Head",parameters:parameters,onCreateArtwork:{createEdgeSource(\.head,name:"Head edge",foreEdge:false)})
        SheetSourceFaceControls(session:session,face:edge(\.tail),title:"Tail",parameters:parameters,onCreateArtwork:{createEdgeSource(\.tail,name:"Tail edge",foreEdge:false)})
        SheetSourceFaceControls(session:session,face:edge(\.foreEdge),title:"Fore-edge",parameters:parameters,onCreateArtwork:{createEdgeSource(\.foreEdge,name:"Fore-edge",foreEdge:true)})
      }.padding(.top,8)
    }
  }
  private func createEdgeSource(_ key:WritableKeyPath<SheetEdgeArtwork,SheetAssemblyFace?>,name:String,foreEdge:Bool) {
    guard let project,let values=measurements else{return}
    let size=Point2(foreEdge ? values.trimHeight:values.trimWidth,values.textBlockThickness)
    _=SheetAssemblySourceEditing.create(session:session,projectID:project.id,objectID:objectID,name:name,size:size){model,face in
      if model.edgeArtwork==nil {model.edgeArtwork = .init()};model.edgeArtwork![keyPath:key]=face
    }
  }
}

private struct SheetAuxiliaryLeafControls:View {
  @ObservedObject var session:ArtworkSession
  @Binding var leaf:SheetAssemblyAuxiliaryLeaf
  let planes:[SheetAssemblyPlane]
  let parameters:[String]
  var onEditingChanged:(Bool)->Void
  let create:(PaperFinishAssignment.Side)->Void
  let remove:()->Void
  var body:some View {
    VStack(spacing:8) {
      HStack {Text(leaf.name).font(InspectorStyle.headingFont);Spacer();AppCloseButton("Remove auxiliary sheet",action:remove)}
      PublicationCommittedField(title:"Sheet name",value:leaf.name,allowsEmpty:false){leaf.name=$0}.textFieldStyle(InspectorTextFieldStyle())
      Picker("Placement",selection:$leaf.placement){Text("Before pages").tag(SheetAssemblyAuxiliaryLeaf.Placement.front);Text("After pages").tag(SheetAssemblyAuxiliaryLeaf.Placement.back)}.inspectorPicker()
      Toggle("Custom sheet size",isOn:Binding(get:{leaf.size != nil},set:{leaf.size=$0 ? .init("width","height"):nil})).inspectorToggle()
      if let size=leaf.size {
        SheetExpressionField(title:"Sheet width",value:Binding(get:{leaf.size?.x ?? size.x},set:{leaf.size?.x=$0}),parameters:parameters)
        SheetExpressionField(title:"Sheet height",value:Binding(get:{leaf.size?.y ?? size.y},set:{leaf.size?.y=$0}),parameters:parameters)
      }
      DisclosureGroup("Material stock") {SheetStockControls(stock:$leaf.stock,targetID:"sheet-auxiliary-"+leaf.id.uuidString,onEditingChanged:onEditingChanged).padding(.top,8)}
      SheetSourceFaceControls(session:session,face:$leaf.front,title:"Front artwork",parameters:parameters,onCreateArtwork:{create(.outside)})
      SheetSourceFaceControls(session:session,face:$leaf.back,title:"Back artwork",parameters:parameters,onCreateArtwork:{create(.inside)})
      Toggle("Attached edge",isOn:Binding(get:{leaf.attachment != nil},set:{leaf.attachment=$0 ? .init():nil})).inspectorToggle()
      if let attachment=leaf.attachment {
        Picker("Attached panel",selection:Binding<String?>(get:{leaf.attachment?.planeID},set:{leaf.attachment?.planeID=$0})) {
          Text("Text block").tag(String?.none);ForEach(planes){Text($0.name).tag(Optional($0.id))}
        }.inspectorPicker()
        Picker("Attachment edge",selection:Binding(get:{leaf.attachment?.edge ?? attachment.edge},set:{leaf.attachment?.edge=$0})) {
          ForEach(SheetPanelEdge.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}
        }.inspectorPicker()
        ArtworkUnitField("Attachment width",value:attachment.widthMM,unit:.mm){leaf.attachment?.widthMM=$0}
      }
    }.padding(10).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
  }
}

/// Existing relationships are edited as one generic source expression. Derived
/// target numbers remain read-only; navigation changes views only on request.
struct SheetDimensionRelationships:View {
  @ObservedObject var session:ArtworkSession
  let objectID:UUID
  let projectID:UUID
  private var object:ProductObject? {session.store?.project?.objects.first{$0.id==objectID}}
  private func replace(_ binding:PhysicalDimensionBinding,with changed:PhysicalDimensionBinding?) {
    guard let object else{return}
    var values=object.dimensionBindings ?? []
    guard let index=values.firstIndex(where:{$0.parameter==binding.parameter}) else{return}
    if let changed {values[index]=changed}else{values.remove(at:index)}
    _=SheetDimensionRelationshipEditing.replace(session:session,projectID:projectID,objectID:objectID,bindings:values)
  }
  var body:some View {
    if let object,let bindings=object.dimensionBindings,!bindings.isEmpty {
      DisclosureGroup("Dimension relationships (\(bindings.count))") {
        VStack(alignment:.leading,spacing:10) {
          ForEach(bindings,id:\.parameter){binding in
            VStack(alignment:.leading,spacing:7) {
              HStack {
                Text(binding.parameter).font(InspectorStyle.headingFont)
                Spacer()
                Text(String(format:"%.3f",object.parameters[binding.parameter] ?? 0)).monospacedDigit().foregroundStyle(Palette.secondary)
                AppCloseButton("Remove dimension relationship"){replace(binding,with:nil)}
              }
              PublicationCommittedField(title:"Expression",value:binding.expression,allowsEmpty:false){expression in
                var value=binding;value.expression=expression;replace(binding,with:value)
              }.textFieldStyle(InspectorTextFieldStyle())
              ForEach(binding.inputs.keys.sorted(),id:\.self){alias in
                if let reference=binding.inputs[alias] {
                  VStack(alignment:.leading,spacing:5) {
                    Text(alias).font(InspectorStyle.captionFont)
                    Picker("Source",selection:Binding(get:{reference.sourceObjectID},set:{sourceID in
                      var value=binding;value.inputs[alias]?.sourceObjectID=sourceID;replace(binding,with:value)
                    })) {
                      ForEach(session.store?.project?.objects.filter{$0.id != objectID} ?? []){source in Text(source.name).tag(source.id)}
                    }.inspectorPicker()
                    Picker("Measurement",selection:Binding(get:{reference.measurement},set:{measurement in
                      var value=binding;value.inputs[alias]?.measurement=measurement
                      value.inputs[alias]?.parameter=measurement == .parameter ? session.store?.project?.objects.first{$0.id==reference.sourceObjectID}?.parameters.keys.sorted().first:nil
                      replace(binding,with:value)
                    })) {ForEach(PhysicalDimensionMeasurement.allCases,id:\.self){Text($0.rawValue).tag($0)}}.inspectorPicker()
                    if reference.measurement == .parameter {
                      Picker("Source parameter",selection:Binding<String?>(get:{reference.parameter},set:{parameter in
                        var value=binding;value.inputs[alias]?.parameter=parameter;replace(binding,with:value)
                      })) {ForEach(session.store?.project?.objects.first{$0.id==reference.sourceObjectID}?.parameters.keys.sorted() ?? [],id:\.self){Text($0).tag(Optional($0))}}.inspectorPicker()
                    }
                    Button("Edit source") {
                      guard let store=session.store,let source=store.project?.objects.first(where:{$0.id==reference.sourceObjectID}) else{return}
                      if store.project?.isIndependentFlatArtworkSource(source)==true {store.showSurface(.artwork,ensureCanvasIfNeeded:false);session.activate(source.id);session.canvas?.synchronize();_=session.canvas?.fit(frameIDs:[source.id])}
                      else{_=store.findOnTable(source.id)}
                    }.buttonStyle(InspectorActionStyle())
                  }
                }
              }
            }.padding(9).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
          }
          Text("Derived target values follow their source. Removing a relationship retains its current physical dimension.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        }.padding(.top,8)
      }.font(InspectorStyle.labelFont)
    }
  }
}

@MainActor enum SheetDimensionRelationshipEditing {
  @discardableResult static func replace(session:ArtworkSession,projectID:UUID,objectID:UUID,bindings:[PhysicalDimensionBinding])->Bool {
    guard let store=session.store,let current=store.project,current.id==projectID,
      let index=current.objects.firstIndex(where:{$0.id==objectID}),!current.objects[index].locked else{return false}
    do {
      guard session.canvas?.activeTextView?.hasMarkedText() != true,
        session.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true else{throw FormError.invalid("Finish the current text input before changing dimension relationships.")}
      var proposed=current;proposed.objects[index].dimensionBindings=bindings.isEmpty ? nil:bindings
      try proposed.reconcilePhysicalDimensions(previous:current);try proposed.validateArtworkLinks()
      session.canvas?.finishText()
      try store.engine.edit("Updated dimension relationships",source:"Studio"){project in
        guard project.id==projectID,let index=project.objects.firstIndex(where:{$0.id==objectID}),!project.objects[index].locked else{throw FormError.missing("The dimension target changed. Choose the current object.")}
        project.objects[index].dimensionBindings=bindings.isEmpty ? nil:bindings
      };store.changed();return true
    }catch{store.error=error.localizedDescription;return false}
  }
}
