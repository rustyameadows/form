import AppKit
import FormCore
import SwiftUI

struct ObjectInspector: View {
  static let width: CGFloat = 286
  @EnvironmentObject var store: StudioStore
  @State private var showPlacement = false
  var body: some View {
    if let object = store.primary, let project = store.project,
      let recipe = project.recipe(object.recipeID)
    {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label(
              store.selected.count > 1 ? "\(store.selected.count) OBJECTS" : "PARAMETRIC OBJECT",
              systemImage: recipe.symbol
            ).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(
              Palette.secondary)
            Spacer()
            Button {
              store.select(nil)
            } label: {
              Image(systemName: "xmark").font(.system(size: 10))
            }.buttonStyle(.plain).help("Deselect")
          }
          TextField(
            "Object name",
            text: Binding(get: { object.name }, set: { store.update(object, ["name": $0]) })
          ).textFieldStyle(.plain).font(.system(size: 19, weight: .medium, design: .serif))
            .lineLimit(2)
          HStack(spacing: 6) {
            Text(recipe.name).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            if object.relationship == "variant" {
              Label("Linked variant", systemImage: "link").font(.system(size: 9)).foregroundStyle(
                Palette.accent)
            }
            Spacer()
            if object.locked {
              Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(
                Palette.secondary)
            }
          }
          HStack(spacing: 7) {
            SmallAction("Focus", symbol: "viewfinder") { store.scene?.focusSelection() }
            SmallAction(store.isolated.isEmpty ? "Isolate" : "Show all", symbol: "cube") {
              store.isolate()
            }
            Menu {
              Button("New iteration") { store.duplicate("iteration") }
              Button("Linked material variant") { store.duplicate("variant") }
              Divider()
              Button(object.locked ? "Unlock placement" : "Lock placement") {
                store.update(object, ["locked": !object.locked])
              }
              Button("Delete", role: .destructive) { store.deleteSelection() }
            } label: {
              Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 29, height: 27)
                .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }.menuStyle(.borderlessButton).fixedSize()
          }
        }.padding(18)
        Divider().overlay(Palette.line)
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if object.patternAssembly != nil {PatternAssemblyInspector(object:object);Divider()}
            if object.isFlexibleSurface {ClothInspector(controller:store.cloth.preview,object:object);Divider()}
            if object.patternAssembly==nil {
            VStack(alignment: .leading, spacing: 14) {
              SectionLabel("FORM & DIMENSIONS")
              ForEach(recipe.parameters) { parameter in
                ParameterControl(parameter: parameter, object: object)
              }
            }
            Divider()
            VStack(alignment: .leading, spacing: 11) {
              HStack {
                SectionLabel("MATERIAL")
                Spacer()
                Button {
                  store.showingLibrary = true
                } label: {
                  Image(systemName: "arrow.up.right").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
              }
              Text(project.material(object.materialID).name).font(
                .system(size: 12, weight: .medium))
              LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 6), spacing: 8
              ) {
                ForEach(store.materials.prefix(12)) { material in
                  Button {
                    store.update(object, ["material_id": material.id])
                  } label: {
                    Circle().fill(Color(nsColor: NSColor(hex: material.color))).frame(
                      width: 27, height: 27
                    ).overlay(Circle().strokeBorder(.black.opacity(0.1))).padding(3).overlay(
                      Circle().strokeBorder(
                        object.materialID == material.id ? Palette.accent : .clear, lineWidth: 1.5))
                  }.buttonStyle(.plain).help(material.name)
                }
              }
              ColorPicker(
                "Custom finish",
                selection: Binding(
                  get: {
                    Color(
                      nsColor: NSColor(
                        hex: object.color ?? project.material(object.materialID).color))
                  }, set: { color in store.update(object, ["color": NSColor(color).hexString]) }),
                supportsOpacity: false
              ).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Divider()
            }
            if !object.isFlexibleSurface {ClothAttachmentInspector(object:object,project:project)}
            if object.textile != nil || TextileDesign.recipeIDs.contains(object.recipeID) {
              TextileInspector(object: object, project: project)
              Divider()
            }
            if object.textile?.attachment == nil && !object.isClothAttached {
            DisclosureGroup(isExpanded: $showPlacement) {
              VStack(spacing: 10) {
                HStack(spacing: 8) {
                  PlacementField("X", value: object.position.x) {
                    store.update(object, ["position": [$0, object.position.y, object.position.z]])
                  }
                  PlacementField("Y", value: object.position.y) {
                    store.update(object, ["position": [object.position.x, $0, object.position.z]])
                  }
                  PlacementField("Z", value: object.position.z) {
                    store.update(object, ["position": [object.position.x, object.position.y, $0]])
                  }
                }
                HStack {
                  Text("Rotation")
                  Spacer()
                  TextField(
                    "Degrees",
                    value: Binding<Double>(
                      get: { object.rotation }, set: { store.update(object, ["rotation": $0]) }),
                    format: .number.precision(.fractionLength(0...1))
                  ).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(
                    .roundedBorder)
                  Text("°").foregroundStyle(Palette.secondary)
                }.font(.system(size: 11))
              }.padding(.top, 10)
            } label: {
              SectionLabel("PLACEMENT")
            }.tint(Palette.secondary)
            }
            if object.relationship == "variant" {
              Label(
                "Geometry and artwork stay linked.\nMaterials and placement are your own.",
                systemImage: "link"
              ).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(
                horizontal: false, vertical: true)
            }
            if object.supportsArtworkFace { ArtworkSourcePanel(object: object, project: project) }
          }.padding(18)
        }.scrollIndicators(.hidden)
        Divider()
        HStack {
          if object.supportsArtworkFace {
            Button {
              if project.editableArtwork(object) == nil {
                store.saveArtwork(
                  .init(background: project.material(object.materialID).color), for: object)
              }
              store.mode = .artwork
            } label: {
              Label("Edit artwork", systemImage: "square.and.pencil").font(
                .system(size: 11, weight: .medium))
            }.buttonStyle(.plain)
          } else {
            Text("Editable, by design.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
          }
          Spacer()
          Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(
            Palette.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 14)
      }.frame(width: Self.width).frame(maxHeight: 590)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(
          RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.9))
        )
        .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 9)
    }
  }
}

struct SectionLabel: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(
      Palette.secondary)
  }
}
struct SmallAction: View {
  let title: String
  let symbol: String
  let action: () -> Void
  init(_ title: String, symbol: String, action: @escaping () -> Void) {
    self.title = title
    self.symbol = symbol
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).frame(
        maxWidth: .infinity
      ).padding(.vertical, 7).background(
        .black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain)
  }
}
struct ParameterControl: View {
  @EnvironmentObject var store: StudioStore
  let parameter: Parameter
  let object: ProductObject
  var displayedUnit: String {
    parameter.unit == "mm" && store.project?.unit == "in" ? "in" : parameter.unit
  }
  var factor: Double { displayedUnit == "in" ? 25.4 : 1 }
  var range: ClosedRange<Double> {
    var low = parameter.minimum
    var high = parameter.maximum
    if object.recipeID == "lamp" {
      if parameter.id == "height" { low = max(low, object["shadeHeight"] + 30) }
      if parameter.id == "shadeHeight" { high = min(high, object["height"] - 30) }
      if parameter.id == "topDiameter" { low = max(low, object["wall"] * 2 + 1) }
    }
    return low...max(low, high)
  }
  var binding: Binding<Double> {
    Binding(
      get: { object[parameter.id] },
      set: { store.update(object, ["parameters": [parameter.id: $0]]) })
  }
  var body: some View {
    VStack(spacing: 7) {
      HStack {
        Text(parameter.name).font(.system(size: 11, weight: .medium))
        Spacer()
        TextField(
          parameter.name,
          value: Binding(
            get: { binding.wrappedValue / factor }, set: { binding.wrappedValue = $0 * factor }),
          format: .number.precision(.fractionLength(0...2))
        )
        .font(.system(size: 11, weight: .medium, design: .monospaced)).multilineTextAlignment(
          .trailing
        ).textFieldStyle(.plain).frame(width: 57)
        Text(displayedUnit).font(.system(size: 9)).foregroundStyle(Palette.secondary).frame(
          minWidth: 17, alignment: .trailing)
      }
      Slider(
        value: Binding(
          get: { binding.wrappedValue },
          set: {
            binding.wrappedValue = min(
              range.upperBound,
              max(range.lowerBound, ($0 / parameter.step).rounded() * parameter.step))
          }), in: range
      ).controlSize(.small).tint(Palette.accent).accessibilityLabel(parameter.name)
    }
  }
}
struct PlacementField: View {
  let title: String
  let value: Double
  let onChange: (Double) -> Void
  init(_ title: String, value: Double, onChange: @escaping (Double) -> Void) {
    self.title = title
    self.value = value
    self.onChange = onChange
  }
  var body: some View {
    HStack(spacing: 4) {
      Text(title).foregroundStyle(Palette.secondary)
      TextField(
        title, value: Binding(get: { value }, set: onChange),
        format: .number.precision(.fractionLength(0...1))
      ).textFieldStyle(.plain).multilineTextAlignment(.trailing)
    }.font(.system(size: 10, design: .monospaced)).padding(7).background(
      .black.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
  }
}

struct StudioPanel: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SectionLabel("LIGHT, SURFACE & CAMERA")
      Text("A different light.").font(.system(size: 22, weight: .regular, design: .serif))
      Text("Find the right setting for what you've made.").font(.system(size: 12)).foregroundStyle(
        Palette.secondary)
      Divider()
      ForEach(["Daylight", "Warm paper", "Graphite"], id: \.self) { preset in
        Button {
          store.studioPreset = preset
        } label: {
          HStack {
            Circle().fill(
              Color(
                nsColor: NSColor(
                  hex: preset == "Daylight"
                    ? "#E9E9E5" : preset == "Warm paper" ? "#D9C6A0" : "#3E4345"))
            ).frame(width: 30, height: 30).overlay(Circle().strokeBorder(Palette.line))
            Text(preset).font(.system(size: 12))
            Spacer()
            if store.studioPreset == preset {
              Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(Palette.accent)
            }
          }.padding(9).background(
            store.studioPreset == preset ? Color.white.opacity(0.7) : .clear,
            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
      }
      Divider()
      HStack {
        SectionLabel("COMPOSITION")
        Spacer()
        Button("Fit all") { store.scene?.fitAll() }.font(.system(size: 11)).buttonStyle(.plain)
          .foregroundStyle(Palette.accent)
      }
      Text(
        "Orbit, pan, and zoom on the canvas to frame your shot. The camera preserves physical scale."
      ).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
      Button {
        store.exportDialog("png")
      } label: {
        Label("Export image · 3000 × 2000", systemImage: "arrow.down.to.line").font(
          .system(size: 12, weight: .semibold)
        ).frame(maxWidth: .infinity).padding(.vertical, 12).background(
          Palette.ink, in: RoundedRectangle(cornerRadius: 8)
        ).foregroundStyle(.white)
      }.buttonStyle(.plain)
    }.padding(20).frame(width: 264).background(
      .regularMaterial, in: RoundedRectangle(cornerRadius: 16)
    ).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.9))).shadow(
      color: .black.opacity(0.08), radius: 24, y: 9)
  }
}

struct BridgeView: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  var command: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/form-mcp").path
  }
  var config: String { "[mcp_servers.form]\ncommand = \"\(command)\"" }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Image(systemName: "point.3.connected.trianglepath.dotted").font(
          .system(size: 29, weight: .light)
        ).foregroundStyle(Palette.accent)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      VStack(alignment: .leading, spacing: 9) {
        Text("A conversation here.\nAn object on the Table.").font(
          .system(size: 30, weight: .regular, design: .serif))
        Text(
          "Describe what you want to make in Codex. FORM exposes the same editable objects and controls through a local MCP connection."
        ).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(4)
      }
      HStack {
        Circle().fill(store.bridgeReady ? .green : .orange).frame(width: 7, height: 7)
        Text(store.bridgeReady ? "Local bridge is ready" : "Local bridge is unavailable").font(
          .system(size: 12, weight: .medium))
        Spacer()
        Text("No external model calls").font(.system(size: 10)).foregroundStyle(Palette.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        Text("Add FORM to your Codex MCP configuration:").font(.system(size: 12, weight: .medium))
        Text(config).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(
          14
        ).frame(maxWidth: .infinity, alignment: .leading).background(
          .black.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(config, forType: .string)
          store.toast("Configuration copied")
        } label: {
          Label("Copy configuration", systemImage: "doc.on.doc").font(.system(size: 12))
        }.buttonStyle(.plain).foregroundStyle(Palette.accent)
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text("Try a starting point").font(.system(size: 12, weight: .semibold))
        Text(
          "“Create a warm orange table lamp, about 350 mm tall. Let me adjust the shade diameter, stem height, and base width.”"
        ).font(.system(size: 13, design: .serif)).lineSpacing(4).foregroundStyle(Palette.secondary)
      }
      Text(
        "Keep FORM open while connected. Changes appear live, save locally, and can be undone in the app. Custom recipes become native parameter controls."
      ).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
    }.padding(32).frame(width: 510).background(Palette.paper)
  }
}

struct ProjectInfoView: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @State private var note = ""
  @State private var kind = "decision"
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("Project notebook").font(.system(size: 26, weight: .regular, design: .serif))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      if let project = store.project {
        TextField(
          "Project name",
          text: Binding(
            get: { project.name },
            set: { value in store.edit("Renamed project") { $0.name = value } })
        ).font(.system(size: 16, weight: .medium)).textFieldStyle(.plain)
        TextField(
          "A short description",
          text: Binding(
            get: { project.subtitle },
            set: { value in store.edit("Updated project description") { $0.subtitle = value } })
        ).font(.system(size: 12)).textFieldStyle(.plain).foregroundStyle(Palette.secondary)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ForEach(["decision", "question"], id: \.self) { section in
              SectionLabel(section == "decision" ? "DESIGN DECISIONS" : "OPEN QUESTIONS")
              ForEach(project.notes.filter { $0.kind == section }) { item in
                HStack(alignment: .top, spacing: 10) {
                  Button {
                    store.edit("Updated project note") { p in
                      if let i = p.notes.firstIndex(where: { $0.id == item.id }) {
                        p.notes[i].resolved.toggle()
                      }
                    }
                  } label: {
                    Image(
                      systemName: item.resolved
                        ? "checkmark.circle.fill"
                        : section == "decision" ? "circle" : "questionmark.circle"
                    ).foregroundStyle(item.resolved ? Palette.accent : Palette.secondary)
                  }.buttonStyle(.plain)
                  TextField(
                    "Note",
                    text: Binding(
                      get: { item.text },
                      set: { value in
                        store.edit("Edited project note", coalescing: "note-\(item.id)") { p in
                          if let i = p.notes.firstIndex(where: { $0.id == item.id }) {
                            p.notes[i].text = value
                          }
                        }
                      }), axis: .vertical
                  ).textFieldStyle(.plain).font(.system(size: 12)).strikethrough(item.resolved)
                    .foregroundStyle(item.resolved ? Palette.secondary : Palette.ink)
                  Button {
                    store.edit("Removed note") { $0.notes.removeAll { $0.id == item.id } }
                  } label: {
                    Image(systemName: "minus.circle").foregroundStyle(Palette.secondary)
                  }.buttonStyle(.plain)
                }
              }
            }
            Divider()
            SectionLabel("RECENT ACTIVITY")
            ForEach(project.history.suffix(12).reversed()) { event in
              HStack {
                Text(event.text).font(.system(size: 11))
                Spacer()
                Text(event.source).font(.system(size: 9)).foregroundStyle(Palette.secondary)
              }
            }
          }.padding(.vertical, 5)
        }.frame(maxHeight: 290)
        HStack {
          Picker("Type", selection: $kind) {
            Text("Decision").tag("decision")
            Text("Question").tag("question")
          }.labelsHidden().frame(width: 115)
          TextField("Add a thought…", text: $note).textFieldStyle(.roundedBorder).onSubmit(add)
          Button(action: add) { Image(systemName: "plus") }.disabled(note.isEmpty)
        }
        if let reference = project.conversationReference {
          Text("Conversation: \(reference)").font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled).foregroundStyle(Palette.secondary)
        }
      }
    }.padding(28).frame(width: 590).background(Palette.paper)
  }
  func add() {
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    store.perform("form_add_note", ["text": note, "kind": kind])
    note = ""
  }
}

struct LibraryView: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @State private var newName = ""
  @State private var printingSettings = false
  @State private var fabricSettings = false
  @State private var newColor = Color(nsColor: NSColor(hex: "#B7B6A1"))
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text("Studio Library").font(.system(size: 28, weight: .regular, design: .serif))
          Text("Materials and tools that follow you from project to project.").font(
            .system(size: 12)
          ).foregroundStyle(Palette.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      Button {
        printingSettings = true
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "printer").font(.system(size: 21, weight: .light))
          VStack(alignment: .leading, spacing: 4) {
            Text("Filaments & 3D printing").font(.system(size: 12, weight: .semibold))
            Text(
              "\(store.library.filaments.count) filaments · \(store.library.printers.count) printer profiles · OrcaSlicer"
            ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
          }
          Spacer()
          Image(systemName: "arrow.up.right").font(.system(size: 11))
        }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 9))
      }.buttonStyle(.plain)
      Button {
        fabricSettings = true
      } label: {
        Label("Fabrics & textile materials", systemImage: "tshirt").font(.system(size:12,weight:.medium))
      }.buttonStyle(.borderless)
      TextileProductionLibraryButton()
      SectionLabel("MATERIALS")
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 17) {
        ForEach(store.library.materials) { material in
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: NSColor(hex: material.color)))
              .frame(width: 34, height: 40).overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
            VStack(alignment: .leading, spacing: 3) {
              Text(material.name).font(.system(size: 11, weight: .medium))
              Text(material.category).font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            Spacer()
          }
        }
      }
      HStack {
        TextField("Name a new material", text: $newName).textFieldStyle(.roundedBorder)
        ColorPicker("Color", selection: $newColor, supportsOpacity: false).labelsHidden()
        Button("Add material") {
          let id = "custom_" + UUID().uuidString
          store.library.materials.append(.init(id, newName, "Custom", NSColor(newColor).hexString))
          store.saveLibrary()
          newName = ""
        }.disabled(newName.isEmpty)
      }
      Divider()
      SectionLabel("STUDIO EQUIPMENT")
      ScrollView {
        VStack(spacing: 14) {
          ForEach(store.library.equipment) { equipment in
            EquipmentEditor(equipment: equipment) { changed in
              if let index = store.library.equipment.firstIndex(where: { $0.id == equipment.id }) {
                store.library.equipment[index] = changed
                store.saveLibrary()
              }
            } onRemove: {
              store.library.equipment.removeAll { $0.id == equipment.id }
              store.saveLibrary()
            }
          }
        }
      }.frame(height: min(CGFloat(store.library.equipment.count) * 66, 200))
      Button {
        store.library.equipment.append(
          .init("Custom printer", width: 279.4, height: 431.8, format: "PDF"))
        store.saveLibrary()
      } label: {
        Label("Add equipment profile", systemImage: "plus").font(.system(size: 11))
      }.buttonStyle(.plain).foregroundStyle(Palette.accent)
      Text("Equipment profiles guide prototype exports. Direct hardware control comes later.").font(
        .system(size: 10)
      ).foregroundStyle(Palette.secondary)
    }.padding(30).frame(width: 680).background(Palette.paper).sheet(isPresented: $printingSettings)
    { PrintingSettingsView(printing: store.printing).environmentObject(store) }
    .sheet(isPresented: $fabricSettings) { TextileFabricLibrary().environmentObject(store) }
  }
}

struct EquipmentEditor: View {
  let equipment: Equipment
  let onChange: (Equipment) -> Void
  let onRemove: () -> Void
  private func update(_ mutation: (inout Equipment) -> Void) {
    var value = equipment
    mutation(&value)
    onChange(value)
  }
  var body: some View {
    HStack(spacing: 13) {
      Image(systemName: equipment.format == "PDF" ? "printer" : "scissors").frame(width: 25)
      VStack(alignment: .leading, spacing: 8) {
        TextField(
          "Equipment name",
          text: Binding(get: { equipment.name }, set: { name in update { $0.name = name } })
        ).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
        HStack(spacing: 7) {
          TextField(
            "Width",
            value: Binding<Double>(
              get: { equipment.width },
              set: { value in update { $0.width = min(5000, max(5, value)) } }),
            format: .number.precision(.fractionLength(0...1))
          ).frame(width: 65)
          Text("×")
          TextField(
            "Height",
            value: Binding<Double>(
              get: { equipment.height },
              set: { value in update { $0.height = min(5000, max(5, value)) } }),
            format: .number.precision(.fractionLength(0...1))
          ).frame(width: 65)
          Text("mm").foregroundStyle(Palette.secondary)
          Picker(
            "Format",
            selection: Binding(
              get: { equipment.format }, set: { format in update { $0.format = format } })
          ) {
            Text("PDF").tag("PDF")
            Text("SVG").tag("SVG")
          }.labelsHidden().frame(width: 80)
        }.font(.system(size: 10, design: .monospaced)).textFieldStyle(.roundedBorder)
      }
      Spacer()
      Button(action: onRemove) {
        Image(systemName: "minus.circle").foregroundStyle(Palette.secondary)
      }.buttonStyle(.plain)
    }.padding(.vertical, 3)
  }
}

extension NSColor {
  var hexString: String {
    let color = usingColorSpace(.sRGB) ?? self
    return String(
      format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255),
      Int(color.blueComponent * 255))
  }
}
