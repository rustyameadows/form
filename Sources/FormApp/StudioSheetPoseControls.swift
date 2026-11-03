import FormCore
import SwiftUI

struct StudioSheetPoseControls:View {
  @ObservedObject var controller:StudioCompositionController
  let instance:StudioInstance
  let source:ProductObject
  let project:Project
  static func effectiveSource(instance:StudioInstance,source:ProductObject,project:Project)->ProductObject {
    (try? (instance.sheetPose ?? .init()).applying(to:source,in:project,clampingSpread:true)) ?? source
  }
  private var posed:ProductObject {Self.effectiveSource(instance:instance,source:source,project:project)}
  private func update(_ body:(inout StudioSheetPose)->Void) {
    controller.changeInstance(id:instance.id){value in
      var pose=(try? value.effectiveSheetPose(in:project)) ?? value.sheetPose ?? .init()
      body(&pose);value.sheetPose=pose.isEmpty ? nil:pose
    }
  }
  var body:some View {
    if let definition=posed.sheetAssembly,let resolved=try? project.resolvedSheetAssembly(posed) {
      InspectorDivider()
      InspectorSectionHeader("PUBLICATION POSE")
      SheetPoseControls(
        openingDegrees:Binding(get:{definition.openingDegrees},set:{value in update{$0.openingDegrees=value}}),
        activeSpread:Binding(get:{definition.activeSpread},set:{value in update{$0.activeSpread=value}}),
        bendMM:Binding(get:{definition.bendMM},set:{value in update{$0.bendMM=value}}),
        document:project.publications?.first{$0.id==definition.publicationID},leaves:resolved.leaves,
        onEditingChanged:controller.inspectorEditing)
      InspectorRow("Binding") {
        Picker("Instance binding",selection:Binding<SheetBindingStyle?>(get:{instance.sheetPose?.bindingStyle},set:{value in update{$0.bindingStyle=value}})) {
          Text("From source").tag(SheetBindingStyle?.none)
          Text("Unbound").tag(Optional(SheetBindingStyle.none))
          Text("Saddle stitch").tag(Optional(SheetBindingStyle.saddleStitch))
          Text("Side staples").tag(Optional(SheetBindingStyle.sideStaple))
        }.labelsHidden().inspectorPicker()
      }
      if instance.sheetPose != nil {
        Button("Use source pose"){controller.changeInstance(id:instance.id){$0.sheetPose=nil}}.buttonStyle(InspectorActionStyle())
      }
    }
  }
}
