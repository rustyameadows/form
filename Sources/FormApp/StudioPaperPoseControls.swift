import FormCore
import SwiftUI

struct StudioPaperPoseControls:View {
  @ObservedObject var controller:StudioCompositionController
  let instance:StudioInstance
  let source:ProductObject
  private var definition:PaperConstruction? {try? PaperGeometry.renderDefinition(for:source)}
  private func update(_ change:(inout StudioPaperPose)->Void) {
    controller.changeInstance(id:instance.id){value in
      var pose=value.paperPose ?? .init();change(&pose)
      value.paperPose=pose.isEmpty ? nil:pose
    }
  }
  var body:some View {
    if let definition {
      InspectorDivider()
      InspectorSectionHeader("ASSEMBLY POSE")
      let opening=Binding(get:{instance.paperPose?.openingPercent ?? definition.openingPercent},set:{value in update{$0.openingPercent=value}})
      ScalarArtworkField("Opening",value:opening.wrappedValue,unit:"%",accessibilityName:"Instance assembly opening"){opening.wrappedValue=$0}
      InspectorSlider(value:opening,in:0...100,label:"Instance assembly opening",onEditingChanged:controller.inspectorEditing)
      if (definition.authored?.version ?? 0)>=4 {
        let explosion=Binding(get:{instance.paperPose?.explosionPercent ?? definition.explosionPercent ?? 0},set:{value in update{$0.explosionPercent=value}})
        ScalarArtworkField("Explode",value:explosion.wrappedValue,unit:"%",accessibilityName:"Instance assembly explosion"){explosion.wrappedValue=$0}
        InspectorSlider(value:explosion,in:0...100,label:"Instance assembly explosion",onEditingChanged:controller.inspectorEditing)
        ForEach(definition.authored?.controls?.poses ?? []) {pose in
          Button(pose.name){update{$0.foldPercent=100;$0.openingPercent=pose.openingPercent;$0.explosionPercent=pose.explosionPercent}}
            .buttonStyle(InspectorActionStyle()).accessibilityIdentifier("studio-assembly-pose-"+pose.id)
        }
      }
      if instance.paperPose != nil {
        Button("Use source pose"){controller.changeInstance(id:instance.id){$0.paperPose=nil}}.buttonStyle(InspectorActionStyle())
      }
    }
  }
}
