import SwiftUI

/// Preview-only credential UI. The entered text never leaves this view.
struct OpenAIConnectionPreviewView:View {
  @ObservedObject var controller:OpenAIConnectionPreviewController
  var onClose:()->Void = {}
  @State private var keyDraft=""
  @FocusState private var keyFocused:Bool

  var body:some View {
    VStack(alignment:.leading,spacing:20) {
      HStack {
        Label("OpenAI connection",systemImage:"sparkles").font(.system(size:17,weight:.semibold))
        Spacer()
        AppCloseButton("Close connection preview"){close()}
      }
      ScrollView {
      VStack(alignment:.leading,spacing:20) {
      StudioDemoBadge()
      Text("Try the complete image workflow with a demo connection.").font(.system(size:14,weight:.medium))
      Text("This local preview makes no OpenAI requests and incurs no charges. No credential is stored, tested, or sent anywhere.")
        .font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      Button("Use demo connection"){finishDemoSetup()}.buttonStyle(.borderedProminent).tint(Palette.ink).controlSize(.large)
        .accessibilityIdentifier("studio-use-demo-connection")
      InspectorDivider()
      InspectorSectionHeader("KEY ENTRY PREVIEW",subtitle:"Optional. Typing here only previews a masked key field; it does not connect an account.")
      SecureField("API key · preview only",text:$keyDraft).textFieldStyle(InspectorTextFieldStyle())
        .focused($keyFocused).textContentType(nil).accessibilityLabel("API key preview only").accessibilityIdentifier("studio-preview-key")
      if !keyDraft.isEmpty {
        Label("Preview text only · cleared when this window closes",systemImage:"lock")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      Button("Continue with demo setup"){finishDemoSetup()}
        .disabled(keyDraft.isEmpty).accessibilityIdentifier("studio-preview-key-continue")
      InspectorDivider()
      InspectorSectionHeader("DEMO CONNECTION CHECK")
      InspectorRow("Scenario") {Picker("Scenario",selection:$controller.fixture) {
        ForEach([StudioGenerationFailureFixture.none,.authentication,.rateLimit,.offline],id:\.self) {fixture in
          Text(fixture.title).tag(fixture)
        }
      }.labelsHidden().inspectorPicker().frame(maxWidth:.infinity).accessibilityIdentifier("studio-connection-scenario")}
      HStack {
        Button("Run demo check"){Task{await controller.testPreview()}}
          .disabled(controller.state == .testing).accessibilityIdentifier("studio-test-demo-connection")
        if controller.state == .testing {ProgressView().controlSize(.small)}
        Spacer()
        if controller.state != .disconnected {Button("Reset preview"){keyFocused=false;keyDraft="";controller.reset()}}
      }
      if let detail=controller.detail {
        Text(detail).font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
          .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("studio-connection-detail")
      }
      }.frame(maxWidth:.infinity,alignment:.leading)
      }
    }.padding(24).frame(minWidth:440,idealWidth:480,maxWidth:560)
      .background(Palette.paper).onDisappear{keyFocused=false;keyDraft="";if controller.state == .testing {controller.reset()}}
  }
  private func close(){keyFocused=false;keyDraft="";onClose()}
  private func finishDemoSetup(){keyFocused=false;keyDraft="";controller.useDemoConnection();onClose()}
}

struct StudioDemoBadge:View {
  var body:some View {
    Label("Demo · local preview",systemImage:"sparkles")
      .font(.system(size:10,weight:.semibold)).foregroundStyle(Palette.accent)
      .padding(.horizontal,8).padding(.vertical,5)
      .background(Palette.accent.opacity(0.09),in:Capsule())
      .accessibilityLabel("Demo, local preview. No actual AI generation.")
  }
}
