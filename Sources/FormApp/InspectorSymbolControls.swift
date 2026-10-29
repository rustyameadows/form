import SwiftUI

struct InspectorSymbolChoice: View {
  let title: String
  @Binding var selection: String
  let choices: [(value: String, title: String, symbol: String)]
  var body: some View {
    HStack(spacing: 2) {
      ForEach(choices, id: \.value) { choice in
        Button { selection = choice.value } label: {
          Image(systemName: choice.symbol).font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: InspectorStyle.controlHeight)
            .foregroundStyle(selection == choice.value ? Palette.accent : Palette.secondary)
            .background(selection == choice.value ? Palette.accent.opacity(0.10) : .clear,
              in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius - 2))
        }.buttonStyle(.plain).help(choice.title).accessibilityLabel(choice.title)
          .accessibilityValue(selection == choice.value ? "Selected" : "")
      }
    }.padding(2).background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius))
      .accessibilityElement(children: .contain).accessibilityLabel(title)
  }
}

struct InspectorSymbolToggle: View {
  let title: String
  let symbol: String
  @Binding var isOn: Bool
  var body: some View {
    Button { isOn.toggle() } label: {
      Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity).frame(height: InspectorStyle.controlHeight)
        .foregroundStyle(isOn ? Palette.accent : Palette.secondary)
        .background(isOn ? Palette.accent.opacity(0.10) : Palette.surface,
          in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius))
    }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityValue(isOn ? "On" : "Off")
  }
}

extension View {
  func inspectorSurface() -> some View {
    font(InspectorStyle.labelFont).controlSize(.small)
      .pickerStyle(.menu).toggleStyle(.switch)
      .textFieldStyle(InspectorTextFieldStyle())
      .buttonStyle(InspectorActionStyle()).tint(Palette.accent)
  }
}
