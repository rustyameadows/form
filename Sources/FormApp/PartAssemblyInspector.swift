import AppKit
import FormCADModel
import FormCore
import SwiftUI

struct PartAssemblyInspector:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  @State private var draft:PlanarConstructionDefinition?
  @State private var base:PlanarConstructionDefinition?
  @State private var projectID:UUID?
  @State private var selectedComponent:String?
  @State private var preview:PartAssemblyPreview?
  @State private var issue:String?
  @State private var adopting=false
  static func applies(to object:ProductObject)->Bool {
    guard let definition=(try? PaperConstruction.definition(for:object))?.authored else{return false}
    return definition.version>=4
  }
  private var current:PlanarConstructionDefinition? {(try? PaperConstruction.definition(for:object))?.authored}
  private var changed:Bool{draft != base}
  private var binding:Binding<PlanarConstructionDefinition> {
    Binding(get:{draft ?? base!},set:{draft=$0;preview=nil;issue=nil})
  }
  var body:some View {
    VStack(spacing:0) {
      ScrollView {
        VStack(alignment:.leading,spacing:InspectorStyle.sectionSpacing) {
          LinkedObjectInspectorModule(object:object,session:store.artworkSession)
          if let draft {
            if draft.version<4 {
              Text("INDEPENDENT CUT PIECES").font(InspectorStyle.headingFont)
              Text("Keep the existing board outlines, artwork, stock and dimensions, then organize these independent roots into editable parts and parent groups.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
              Button("Adopt independent parts") {adopt()}.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("construction-adopt-parts")
            }else{
              PartAssemblyParameterControls(definition:binding,derivedTargets:Set(object.dimensionBindings?.map(\.parameter) ?? []))
              InspectorDivider()
              PartAssemblyPartsControls(definition:binding,componentID:$selectedComponent,object:object,projectID:projectID,canCreateArtwork:!changed,createArtwork:createArtwork)
              InspectorDivider()
              PartAssemblyJointControls(definition:binding,object:object,projectID:projectID)
              InspectorDivider()
              PartAssemblyProductionControls(definition:binding,object:object,projectID:projectID,exportsEnabled:!changed)
              InspectorDivider()
              presentation(draft)
            }
            if let preview {
              InspectorDivider();InspectorSectionHeader("CHANGE PREVIEW")
              LinkedInspectorObjectPreview(object:preview.object,project:preview.project,assets:store.artworkSession.assets,revision:store.revision)
                .frame(height:210).clipShape(RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
              Text("\(preview.activePieces) active pieces · \(preview.tapeCount) tape strips · \(preview.stapleCount) staples").font(InspectorStyle.captionFont)
              if !preview.changedPieceNames.isEmpty {
                let inactive=preview.changedPieceNames.count-preview.changedActivePieceNames.count
                DisclosureGroup("\(preview.changedActivePieceNames.count) active pieces affected"+(inactive>0 ? " · \(inactive) saved alternatives":"")) {
                  VStack(alignment:.leading,spacing:5) {
                    ForEach(Array(preview.changedActivePieceNames.enumerated()),id:\.offset){_,name in Text(name).font(InspectorStyle.captionFont)}
                    if inactive>0 {Text("Saved alternatives retain their sources and update with these parameters.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
                  }.padding(.top,6)
                }
              }
              ForEach(preview.preflight.issues.filter{$0.severity != .info}){item in Text(item.message).font(InspectorStyle.captionFont).foregroundStyle(item.severity == .error ? Color.orange:Palette.secondary)}
              let notes=preview.preflight.issues.filter{$0.severity == .info}
              if !notes.isEmpty {
                DisclosureGroup("Source assumptions & review notes") {
                  VStack(alignment:.leading,spacing:7) {ForEach(notes){item in Text(item.message).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}}.padding(.top,6)
                }
              }
            }
            if let issue {Text(issue).font(InspectorStyle.captionFont).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
          }
        }.padding(InspectorStyle.panelPadding)
      }
      if changed {
        VStack(alignment:.leading,spacing:8) {
          if adopting {Text("Adoption retains saved clearance meanings. Review newly declared material and fastening assumptions before applying.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
          HStack {
            Button("Cancel"){reload()}.buttonStyle(InspectorActionStyle())
            Button("Preview changes"){review()}.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("construction-preview")
            Spacer(minLength:0)
            Button("Apply"){apply()}.buttonStyle(InspectorActionStyle()).disabled(preview==nil).accessibilityIdentifier("construction-apply")
          }
        }.padding(InspectorStyle.panelPadding).background(Palette.surface)
      }
    }.inspectorSurface().onAppear{reload()}
      .onChange(of:object.id){_,_ in reload()}
      .onChange(of:store.project?.id){_,_ in reload()}
      .onChange(of:object.paperConstruction){_,_ in reconcile()}
      .accessibilityElement(children:.contain).accessibilityLabel("Independent part assembly controls")
  }
  private func reload() {
    draft=current;base=current;projectID=store.project?.id;preview=nil;issue=nil;adopting=false
    if store.paperSelectionObjectID==object.id,let panel=store.paperSelectedPanelID,
      let draft,let owners=try? draft.componentPanels(),let selected=owners.first(where:{$0.value.contains(panel)})?.key {selectedComponent=selected}
    else if selectedComponent==nil || draft?.components?.contains(where:{$0.id==selectedComponent}) != true {selectedComponent=draft?.components?.first?.id}
  }
  private func reconcile() {
    if !changed || draft==current {reload()}
    else if base != current {preview=nil;issue="The accepted source changed. Cancel these fields and reload before applying."}
  }
  private func adopt() {
    do {draft=try ConstructionSourceEditing.independentPartsDefinition(object);adopting=true;issue=nil;preview=nil}
    catch{issue=error.localizedDescription}
  }
  private func review() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let draft,let project=store.project,project.id==projectID,current==base else{throw FormError.invalid("The source or project changed. Cancel and reload before previewing.")}
      preview=try PartAssemblyNativeEditing.preview(project:project,objectID:object.id,definition:draft);issue=nil
    }catch{preview=nil;issue=error.localizedDescription}
  }
  private func apply() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard preview != nil,let draft,let base,let projectID,let revision=try? ConstructionSourceEditing.revision(base) else{return}
    if PartAssemblyNativeEditing.apply(store:store,projectID:projectID,objectID:object.id,expectedRevision:revision,definition:draft,adopting:adopting){reload()}
  }
  private func createArtwork(_ componentID:String,_ side:PaperFinishAssignment.Side) {
    guard !changed,let base,let projectID,let revision=try? ConstructionSourceEditing.revision(base) else{return}
    if PartAssemblyNativeEditing.createArtwork(store:store,projectID:projectID,objectID:object.id,componentID:componentID,side:side,expectedRevision:revision) != nil{reload()}
  }
  private func presentation(_ definition:PlanarConstructionDefinition)->some View {
    DisclosureGroup("Presentation") {
      VStack(alignment:.leading,spacing:8) {
        ForEach(definition.controls?.poses ?? []){pose in
          Button(pose.name){updatePose(["opening":pose.openingPercent,"explosion":pose.explosionPercent])}.buttonStyle(InspectorActionStyle())
        }
        ScalarArtworkField("Opening",value:object.paperConstruction?.openingPercent ?? 0,unit:"%",accessibilityName:"Assembly opening"){value in updatePose(["opening":value])}
        ScalarArtworkField("Explosion",value:object.paperConstruction?.explosionPercent ?? 0,unit:"%",accessibilityName:"Assembly explosion"){value in updatePose(["explosion":value])}
        Button("Assembly & sections…") {
          guard store.project?.id==projectID,current==base,!changed else{store.error="The construction project changed. Reload its controls before reviewing sections.";return}
          store.constructionDrawingReview.show(store:store,objectID:object.id)
        }.buttonStyle(InspectorActionStyle())
        Text("Presentation moves the saved parent frames. Part dimensions and canonical artwork remain at their authored size.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }.padding(.top,8)
    }.disabled(changed)
  }
  private func updatePose(_ values:[String:Double]) {
    guard store.project?.id==projectID,current==base,!changed else{store.error="The construction project changed. Reload its controls before changing presentation.";return}
    store.update(object,["parameters":values])
  }
}

/// Legacy independent sources keep their established controls until the user
/// explicitly reviews and applies the new material/group model.
struct PartAssemblyAdoptionControls:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  @State private var projectID:UUID?
  @State private var source:PlanarConstructionDefinition?
  @State private var candidate:PlanarConstructionDefinition?
  @State private var preview:PartAssemblyPreview?
  @State private var issue:String?
  var body:some View {
    DisclosureGroup("Independent part controls") {
      VStack(alignment:.leading,spacing:8) {
        Text("Review the saved cut pieces as independent materials and parent frames. Existing geometry, artwork and dimension meanings are retained.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        if let preview {
          LinkedInspectorObjectPreview(object:preview.object,project:preview.project,assets:store.artworkSession.assets,revision:store.revision).frame(height:180)
          Text("\(preview.declaredPieces) existing pieces · review new material and joint assumptions after adoption.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          HStack {
            Button("Cancel"){reset()}.buttonStyle(InspectorActionStyle())
            Button("Apply adoption"){apply()}.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("construction-apply-adoption")
          }
        }else{
          Button("Preview independent parts"){review()}.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("construction-adopt-parts")
        }
        if let issue{Text(issue).font(InspectorStyle.captionFont).foregroundStyle(.orange)}
      }.padding(.top,8)
    }.onAppear{reset()}.onChange(of:store.project?.id){_,_ in reset()}.onChange(of:object.paperConstruction){_,_ in reset()}
  }
  private func reset() {projectID=store.project?.id;source=object.paperConstruction?.authored;candidate=nil;preview=nil;issue=nil}
  private func review() {
    do {
      guard let project=store.project,project.id==projectID,object.paperConstruction?.authored==source else{throw FormError.invalid("The construction project changed. Reload its controls before adoption.")}
      let definition=try ConstructionSourceEditing.independentPartsDefinition(object)
      preview=try PartAssemblyNativeEditing.preview(project:project,objectID:object.id,definition:definition);candidate=definition;issue=nil
    }catch{issue=error.localizedDescription}
  }
  private func apply() {
    guard let projectID,let source,let candidate,preview != nil,let revision=try? ConstructionSourceEditing.revision(source) else{return}
    if PartAssemblyNativeEditing.apply(store:store,projectID:projectID,objectID:object.id,expectedRevision:revision,definition:candidate,adopting:true){reset()}
  }
}

struct PartAssemblyParameterControls:View {
  @Binding var definition:PlanarConstructionDefinition
  let derivedTargets:Set<String>
  private var surface:ConstructionControlSurface {definition.controls ?? .init(parameters:definition.parameters.map{.init(parameter:$0.name,label:$0.name)})}
  var body:some View {
    let values=(try? definition.resolvedValues()) ?? [:],surface=self.surface
    VStack(alignment:.leading,spacing:InspectorStyle.sectionSpacing) {
      if let id=surface.dimensionReferenceParameter,let reference=surface.parameters.first(where:{$0.parameter==id}) {
        InspectorSectionHeader("DIMENSION REFERENCE");field(reference)
      }
      ForEach(surface.groups.filter{group in surface.parameters.contains{$0.group==group.id && visible($0.visibleWhen,values:values)} || surface.measurements.contains{$0.group==group.id && visible($0.visibleWhen,values:values)}}){group in
        DisclosureGroup(group.title) {rows(group.id,surface:surface,values:values).padding(.top,8)}
      }
      rows(nil,surface:surface,values:values)
    }
  }
  private func rows(_ group:String?,surface:ConstructionControlSurface,values:[String:Double])->some View {
    VStack(alignment:.leading,spacing:9) {
      ForEach(surface.parameters.filter{$0.group==group && $0.parameter != surface.dimensionReferenceParameter && visible($0.visibleWhen,values:values)}){control in field(control)}
      ForEach(surface.measurements.filter{$0.group==group && visible($0.visibleWhen,values:values)}){measurement in
        if let amount=try? CADExpression.evaluate(measurement.expression.expression,variables:values) {
          InspectorRow(measurement.label){Text(String(format:"%.3f",amount)+" "+(measurement.unit ?? "")).font(InspectorStyle.captionFont).monospacedDigit().foregroundStyle(Palette.secondary)}
        }
      }
    }
  }
  private func visible(_ condition:CADScalar?,values:[String:Double])->Bool {
    guard let condition,let amount=try? CADExpression.evaluate(condition.expression,variables:values) else{return true}
    return amount>0.5
  }
  @ViewBuilder private func field(_ control:ConstructionParameterControl)->some View {
    if let index=definition.parameters.firstIndex(where:{$0.name==control.parameter}) {
      let parameter=definition.parameters[index]
      VStack(alignment:.leading,spacing:4) {
        if let choices=control.choices {
          InspectorRow(control.label) {
            Picker(control.label,selection:Binding(get:{definition.parameters[index].value},set:{definition.parameters[index].value=$0})) {
              ForEach(choices.indices,id:\.self){i in Text(choices[i].label).tag(choices[i].value)}
            }.inspectorPicker().labelsHidden()
          }
        }else if parameter.unit=="mm" {
          ArtworkUnitField(control.label,value:parameter.value,unit:.mm,accessibilityName:control.label){definition.parameters[index].value=$0}
        }else{
          ScalarArtworkField(control.label,value:parameter.value,unit:parameter.unit,accessibilityName:control.label){definition.parameters[index].value=$0}
        }
        if let help=control.help,!help.isEmpty {Text(help).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
        if derivedTargets.contains(parameter.name){Label("Linked dimension source",systemImage:"link").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      }.disabled(derivedTargets.contains(parameter.name))
    }
  }
}
