import AppKit
import Combine
import FormCore
import SwiftUI

extension Notification.Name {
  static let labAppearanceChanged = Notification.Name("lab.interfaceAppearanceChanged")
}

/// App preferences only: never stored in a product, artwork, or material library.
@MainActor final class InterfaceAppearance: ObservableObject {
  static let defaultAccent = "#245BFF"
  static let defaultCanvasBackground = "#F2F2F2"
  static let shared = InterfaceAppearance.environment()
  @Published private(set) var accentHex: String
  @Published private(set) var canvasBackgroundHex: String
  @Published private(set) var frameColors: [String:String]
  private let defaults: UserDefaults?
  private let file: URL?
  private var cachedCanvasControl: (accent: String, background: String, color: NSColor)?
  private var cachedFrames: (background:[Double], colors:[String:NSColor])?
  private struct Saved: Codable {
    var accentHex: String?
    var canvasBackgroundHex: String?
    var frameColors: [String:String]?
    enum CodingKeys:String,CodingKey {case accentHex,canvasBackgroundHex,frameColors}
    init(accentHex:String,canvasBackgroundHex:String?,frameColors:[String:String]?) {
      self.accentHex=accentHex;self.canvasBackgroundHex=canvasBackgroundHex;self.frameColors=frameColors
    }
    init(from decoder:Decoder)throws {
      let c=try decoder.container(keyedBy:CodingKeys.self)
      accentHex=try? c.decode(String.self,forKey:.accentHex)
      canvasBackgroundHex=try? c.decode(String.self,forKey:.canvasBackgroundHex)
      // One malformed optional field must not discard valid legacy preferences.
      if let values=try? c.nestedContainer(keyedBy:FrameKey.self,forKey:.frameColors) {
        var colors=[String:String]()
        for role in CanvasFrameRole.allCases {
          if let key=FrameKey(stringValue:role.rawValue),let value=try? values.decode(String.self,forKey:key) {colors[role.rawValue]=value}
        }
        frameColors=colors
      } else {frameColors=nil}
    }
    private struct FrameKey:CodingKey {
      var stringValue:String
      init?(stringValue:String){self.stringValue=stringValue}
      var intValue:Int?{nil}
      init?(intValue:Int){return nil}
    }
  }
  init(defaults: UserDefaults? = nil, file: URL? = nil) {
    self.defaults = defaults; self.file = file
    let stored: String?, background: String?, frames:[String:Any]?
    if let file, let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) {
      stored = value.accentHex; background = value.canvasBackgroundHex;frames=value.frameColors
    } else {
      stored = defaults?.string(forKey: "LAB.interfaceAccent")
      background = defaults?.string(forKey: "LAB.canvasBackground")
      frames=defaults?.dictionary(forKey:"LAB.canvasFrameColors")
    }
    accentHex = (try? Self.normalized(stored ?? Self.defaultAccent)) ?? Self.defaultAccent
    canvasBackgroundHex = (try? Self.normalized(background ?? Self.defaultCanvasBackground)) ?? Self.defaultCanvasBackground
    var colors=[String:String]()
    for role in CanvasFrameRole.allCases {
      if let raw=frames?[role.rawValue] as? String,let color=try? Self.normalized(raw),color != role.defaultHex {colors[role.rawValue]=color}
    }
    frameColors=colors
  }
  private static func environment() -> InterfaceAppearance {
    if let path = LabIdentity.libraryOverride() { return .init(file: URL(fileURLWithPath: path).appendingPathComponent("Appearance.json")) }
    return .init(defaults: .standard)
  }
  static func normalized(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
      throw FormError.invalid("Enter a six-digit color, such as #245BFF.")
    }
    return "#" + digits.uppercased()
  }
  func setAccent(_ raw: String) throws {
    let value = try Self.normalized(raw)
    guard value != accentHex else { return }
    try persist(accent:value,background:canvasBackgroundHex,frames:frameColors)
    accentHex = value
    NotificationCenter.default.post(name: .labAppearanceChanged, object: self)
  }
  func setAccent(_ color: NSColor) throws {
    guard let c = color.usingColorSpace(.sRGB) else { throw FormError.invalid("Choose an RGB accent color.") }
    try setAccent(String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())))
  }
  func setCanvasBackground(_ raw: String) throws {
    let value = try Self.normalized(raw)
    guard value != canvasBackgroundHex else { return }
    try persist(accent:accentHex,background:value,frames:frameColors)
    canvasBackgroundHex = value
    cachedFrames=nil
    NotificationCenter.default.post(name: .labAppearanceChanged, object: self)
  }
  func setCanvasBackground(_ color: NSColor) throws {
    guard let c = color.usingColorSpace(.sRGB) else { throw FormError.invalid("Choose an RGB Canvas background color.") }
    try setCanvasBackground(String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())))
  }
  private func persist(accent:String,background:String,frames:[String:String])throws {
    if let file {
      try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
      try JSONEncoder().encode(Saved(accentHex:accent,canvasBackgroundHex:background,frameColors:frames.isEmpty ? nil:frames)).write(to:file,options:.atomic)
    }
    defaults?.set(accent,forKey:"LAB.interfaceAccent")
    defaults?.set(background,forKey:"LAB.canvasBackground")
    if frames.isEmpty {defaults?.removeObject(forKey:"LAB.canvasFrameColors")}
    else {defaults?.set(frames,forKey:"LAB.canvasFrameColors")}
  }
  func frameHex(for role:CanvasFrameRole)->String {frameColors[role.rawValue] ?? role.defaultHex}
  func setFrameColor(_ raw:String,for role:CanvasFrameRole)throws {
    let value=try Self.normalized(raw)
    var next=frameColors
    if value==role.defaultHex {next.removeValue(forKey:role.rawValue)} else {next[role.rawValue]=value}
    guard next != frameColors else{return}
    try persist(accent:accentHex,background:canvasBackgroundHex,frames:next)
    frameColors=next;cachedFrames=nil
    NotificationCenter.default.post(name:.labAppearanceChanged,object:self)
  }
  func setFrameColor(_ color:NSColor,for role:CanvasFrameRole)throws {
    guard let c=color.usingColorSpace(.sRGB),[c.redComponent,c.greenComponent,c.blueComponent].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {
      throw FormError.invalid("Choose a finite RGB frame color.")
    }
    try setFrameColor(String(format:"#%02X%02X%02X",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded())),for:role)
  }
  func resetFrameColors()throws {
    guard !frameColors.isEmpty else{return}
    try persist(accent:accentHex,background:canvasBackgroundHex,frames:[:])
    frameColors=[:];cachedFrames=nil
    NotificationCenter.default.post(name:.labAppearanceChanged,object:self)
  }
  func frameColor(for role:CanvasFrameRole,against background:NSColor?=nil)->NSColor {
    let base=(background ?? canvasBackgroundColor).usingColorSpace(.sRGB) ?? canvasBackgroundColor
    let key=[Double(base.redComponent),Double(base.greenComponent),Double(base.blueComponent)]
    if cachedFrames?.background != key {cachedFrames=(key,[:])}
    if let value=cachedFrames?.colors[role.rawValue] {return value}
    let source=NSColor(hex:frameHex(for:role)).usingColorSpace(.sRGB)!
    func contrast(_ color:NSColor)->Double {
      let ratio=Self.whiteContrast(color)/Self.whiteContrast(base)
      return max(ratio,1/ratio)
    }
    let result:NSColor
    if contrast(source)>=4.5 {result=source}
    else {
      // Uniform RGB mixing retains hue. Search only when a role/background
      // changes, then cache at most the three resolved roles for that backdrop.
      let endpoint=contrast(.white)>=contrast(.black) ? 1.0:0.0
      func mixed(_ amount:Double)->NSColor {
        NSColor(srgbRed:source.redComponent+(endpoint-source.redComponent)*amount,
          green:source.greenComponent+(endpoint-source.greenComponent)*amount,
          blue:source.blueComponent+(endpoint-source.blueComponent)*amount,alpha:1)
      }
      var low=0.0,high=1.0
      for _ in 0..<26 {let mid=(low+high)/2;if contrast(mixed(mid))>=4.5+1e-9 {high=mid}else{low=mid}}
      result=mixed(high)
    }
    cachedFrames?.colors[role.rawValue]=result
    return result
  }
  var canvasBackgroundColor: NSColor { NSColor(hex: canvasBackgroundHex) }
  var canvasLabelColor: NSColor {
    Self.whiteContrast(canvasBackgroundColor) >= 4.5 ? NSColor.white : NSColor.black
  }
  /// Lift or darken the same accent hue until thin interface marks can be read
  /// on the chosen workspace. Physical artwork colors never use this tone.
  var canvasControlColor: NSColor {
    if let cached = cachedCanvasControl, cached.accent == accentHex, cached.background == canvasBackgroundHex {
      return cached.color
    }
    let color = readableCanvasControlColor()
    cachedCanvasControl = (accentHex, canvasBackgroundHex, color)
    return color
  }
  private func readableCanvasControlColor() -> NSColor {
    let source = selectedColor.usingColorSpace(.sRGB)!
    let backgroundContrast = Self.whiteContrast(canvasBackgroundColor)
    func contrast(_ color: NSColor) -> Double {
      let ratio = Self.whiteContrast(color) / backgroundContrast
      return max(ratio, 1 / ratio)
    }
    if contrast(source) >= 3 { return source }
    let endpoint = backgroundContrast >= 4.5 ? 1.0 : 0.0
    for step in 1...100 {
      let amount = Double(step) / 100
      let color = NSColor(srgbRed: source.redComponent + (endpoint - source.redComponent) * amount,
        green: source.greenComponent + (endpoint - source.greenComponent) * amount,
        blue: source.blueComponent + (endpoint - source.blueComponent) * amount, alpha: 1)
      if contrast(color) >= 3 { return color }
    }
    return canvasLabelColor
  }
  static func whiteContrast(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB)!
    func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return 1.05 / (0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent) + 0.05)
  }
  var selectedColor: NSColor { NSColor(hex: accentHex) }
  /// One hue, with a readable tone for selections and controls on white.
  var controlColor: NSColor {
    let c = selectedColor.usingColorSpace(.sRGB)!
    var scale = 1.0
    while scale > 0.001 {
      let candidate = NSColor(srgbRed: c.redComponent * scale, green: c.greenComponent * scale, blue: c.blueComponent * scale, alpha: 1)
      if Self.whiteContrast(candidate) >= 4.5 { return candidate }
      scale *= 0.94
    }
    return .black
  }
}

enum Palette {
  static let ink = Color.black
  static let secondary = Color(nsColor: secondaryNS)
  static let paper = Color.white
  static let surface = Color(nsColor: surfaceNS)
  static let line = Color(nsColor: NSColor(hex: "#DCDCDC"))
  static let secondaryNS = NSColor(hex: "#666666")
  static let surfaceNS = NSColor(hex: "#F2F2F2")
  @MainActor static var accentNS: NSColor { InterfaceAppearance.shared.controlColor }
  @MainActor static var accent: Color { Color(nsColor: accentNS) }
  @MainActor static var canvasBackgroundNS: NSColor { InterfaceAppearance.shared.canvasBackgroundColor }
  @MainActor static var canvasLabelNS: NSColor { InterfaceAppearance.shared.canvasLabelColor }
  @MainActor static var canvasAccentNS: NSColor { InterfaceAppearance.shared.canvasControlColor }
  @MainActor static var canvasGridNS: NSColor { canvasLabelNS.withAlphaComponent(0.16) }
  @MainActor static var canvasGuideNS: NSColor { canvasLabelNS.withAlphaComponent(0.65) }
  static let numericFont = Font.system(size: 11, design: .monospaced)
}

private struct InterfaceStyle: ViewModifier {
  @ObservedObject private var appearance = InterfaceAppearance.shared
  func body(content: Content) -> some View {
    content.font(.system(size: 12)).foregroundStyle(Palette.ink)
      .tint(Color(nsColor: appearance.controlColor)).accentColor(Color(nsColor: appearance.controlColor))
      .preferredColorScheme(.light)
  }
}
extension View { func labInterface() -> some View { modifier(InterfaceStyle()) } }

struct AppearanceSettingsView: View {
  @ObservedObject var appearance: InterfaceAppearance
  @ObservedObject var store: StudioStore
  @State private var hex = ""
  @State private var issue: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Settings").font(.system(size: 24, weight: .semibold))
        Text("SF for the interface. SF Mono for values and technical details.").foregroundStyle(Palette.secondary)
        Divider()
        InspectorColorPicker("Accent color", selection: Binding(get: { Color(nsColor: appearance.selectedColor) }, set: { color in apply { try appearance.setAccent(NSColor(color)) } }), supportsOpacity: false)
          .accessibilityLabel("App accent color")
        HStack {
          TextField("#RRGGBB", text: $hex).font(Palette.numericFont).textFieldStyle(InspectorTextFieldStyle()).frame(width: 120).accessibilityLabel("Accent hex color").onSubmit(applyHex)
          Button("Apply", action: applyHex).accessibilityLabel("Apply app accent")
          Spacer()
          Button("Reset to blue") { apply { try appearance.setAccent(InterfaceAppearance.defaultAccent) } }
        }
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
          Text("Selected control").font(.system(size: 12, weight: .medium))
          Spacer()
          Text("125.00 mm").font(Palette.numericFont).foregroundStyle(Palette.secondary)
        }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
        Text("Applies throughout LAB. Pale colors use a darker tone for readable controls on white.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        Divider()
        VStack(alignment:.leading,spacing:12) {
          Text("OpenAI").font(.system(size:13,weight:.semibold))
          Text("Studio stills · local preview").font(.system(size:11)).foregroundStyle(Palette.secondary)
          Button("Open connection setup…") {store.showingOpenAISetup=true}
            .accessibilityLabel("Open OpenAI connection setup")
          Text("Preview provider setup and the image workflow without an API call.")
            .font(.system(size:11)).foregroundStyle(Palette.secondary)
        }
        Divider()
        CanvasBackgroundControls(appearance: appearance)
        Divider()
        VStack(alignment:.leading,spacing:14) {
          Text("Canvas frame colors").font(.system(size:13,weight:.semibold))
          ForEach(CanvasFrameRole.allCases,id:\.rawValue) { role in
            HStack(spacing:10) {
              Image(systemName:role.symbolName).frame(width:18).foregroundStyle(Palette.secondary)
              InspectorColorPicker(role.title,selection:Binding(
                get:{Color(nsColor:NSColor(hex:appearance.frameHex(for:role)))},
                set:{color in apply {try appearance.setFrameColor(NSColor(color),for:role)}}),supportsOpacity:false,
                targetID:"canvas-frame-color-\(role.rawValue)")
                .accessibilityLabel(role.title+" frame color")
            }
          }
          Button("Reset frame colors") {apply {try appearance.resetFrameColors()}}
          Text("Outlines retain the chosen hue with a readable tone against the Canvas. Artwork colors stay unchanged.")
            .font(.system(size:11)).foregroundStyle(Palette.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 14) {
          Text("Units").font(.system(size: 13, weight: .semibold))
          HStack {
            Text("Project dimensions")
            Spacer()
            Picker("Project dimensions", selection: Binding(
            get: { store.project?.unit ?? "mm" },
            set: { unit in store.edit("Changed units") { $0.unit = unit } }
          )) {
            Text("Millimeters").tag("mm")
            Text("Inches").tag("in")
            }.labelsHidden().pickerStyle(.menu).frame(width: 150)
              .disabled(store.showingHome || store.project == nil)
          }
          HStack {
            Text("Canvas units")
            Spacer()
            Picker("Canvas units", selection: Binding(
            get: { store.artworkSession.unit },
            set: { unit in
              NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
              store.artworkSession.mutate { $0.unit = unit }
            }
          )) {
            Text("Millimeters").tag(PhysicalUnit.mm)
            Text("Centimeters").tag(PhysicalUnit.cm)
            Text("Inches").tag(PhysicalUnit.inches)
            Text("Points").tag(PhysicalUnit.points)
            }.labelsHidden().pickerStyle(.menu).frame(width: 150)
              .disabled(store.showingHome || store.artworkSession.object == nil)
          }
        }
      }.padding(28)
    }.frame(width: 460, height: 680).background(Palette.paper).labInterface()
      .onAppear { hex = appearance.accentHex }
      .onChange(of: appearance.accentHex) { _, value in hex = value; issue = nil }
  }
  private func apply(_ body: () throws -> Void) { do { try body(); hex = appearance.accentHex; issue = nil } catch { issue = error.localizedDescription } }
  private func applyHex() { apply { try appearance.setAccent(hex) } }
}

extension StudioStore {
  func refreshInterfaceAppearance(accent: NSColor? = nil) {
    objectWillChange.send()
    artworkSession.objectWillChange.send()
    let color = accent ?? Palette.accentNS
    scene?.refreshInterfaceAccent(color)
    studioComposition.stage.refreshInterfaceAccent(color)
    artworkSession.canvas?.refreshInterfaceAccent(color)
    artworkSession.canvas?.enclosingScrollView?.backgroundColor = Palette.canvasBackgroundNS
    func redraw(_ view: NSView) { view.needsDisplay = true; for child in view.subviews { redraw(child) } }
    for window in NSApp.windows { if let view = window.contentView { redraw(view) } }
  }
}
