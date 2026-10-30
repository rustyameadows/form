import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct ArtworkWorkspace: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    Group {
      if store.environment != .form,let object=store.primary,let project=store.project,
        FabricEnvironmentContext(object:object,project:project)?.sourceID != nil {
        FabricPatternWorkspace(object:object)
      } else { ArtworkStudio(session:store.artworkSession) }
    }.environmentObject(store).focusedValue(\.designSurface,.artwork)
  }
}

struct NewArtworkFrame: View {
  @ObservedObject var session: ArtworkSession
  @Environment(\.dismiss) var dismiss
  @State private var width = 203.2
  @State private var height = 254.0
  @State private var unit: PhysicalUnit = .inches
  @State private var name = "Untitled frame"
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionLabel("NEW ARTWORK FRAME")
      TextField("Frame name", text: $name).textFieldStyle(.roundedBorder)
      Menu("Physical presets") {
        Button("8 × 10 inches") {
          width = 203.2
          height = 254
          unit = .inches
        }
        Button("11 × 17 inches") {
          width = 279.4
          height = 431.8
          unit = .inches
        }
        Button("A4 · 210 × 297 mm") {
          width = 210
          height = 297
          unit = .mm
        }
        Button("US Letter") {
          width = 215.9
          height = 279.4
          unit = .inches
        }
        Button("100 mm dial") {
          width = 100
          height = 100
          unit = .mm
        }
      }
      Picker("Units", selection: $unit) {
        ForEach(PhysicalUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      ArtworkUnitField("Width", value: width, unit: unit) { width = $0 }
      ArtworkUnitField("Height", value: height, unit: unit) { height = $0 }
      Button("Create frame") {
        session.createFrame(
          width: width, height: height, name: name.isEmpty ? "Untitled frame" : name)
        session.mutate { $0.unit = unit }
        dismiss()
      }.buttonStyle(.borderedProminent).tint(Palette.ink).disabled(
        width < 1 || width > 1000 || height < 1 || height > 1000)
    }.padding(23).frame(width: 290)
  }
}

struct ArtworkLayers: View {
  @ObservedObject var session: ArtworkSession
  var onClose: (() -> Void)? = nil
  @State private var renaming: UUID?
  @State private var collapsed = Set<UUID>()
  var rows: [(element: ArtworkElement, depth: Int)] {
    var result: [(ArtworkElement, Int)] = []
    var seen = Set<UUID>()
    let artwork = session.art
    let projection = session.activeProjection
    func children(_ parent: UUID?, _ depth: Int) {
      for e in artwork.elements.reversed() where e.parentID == parent && !seen.contains(e.id)
        && (projection?.intersects(artwork.bounds(of: e)) ?? true) {
        seen.insert(e.id)
        result.append((e, depth))
        if e.kind == "group", !collapsed.contains(e.id) { children(e.id, depth + 1) }
      }
    }
    children(nil, 0)
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FloatingPanelHeader("CANVAS & SURFACES", closeLabel: "Close Canvas layers", onClose: onClose) {
        Text("\(session.frames.filter { !$0.isWorkspace }.count)").foregroundStyle(Palette.secondary).font(.system(size: 9))
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(session.frames) { frame in
            Button {
              session.activate(frame.id)
              session.canvas?.fit(all: false)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: frame.isWorkspace ? "square.dashed" : frame.projection?.isProof == true ? "shippingbox" : frame.projection != nil ? "link" : frame.object.componentDefinition == true ? "diamond.fill" : frame.object.recipeID == "artboard" ? "rectangle" : "link")
                Text(frame.isWorkspace ? "Canvas" : frame.title).lineLimit(1)
                  .truncationMode(.middle).help(frame.isWorkspace ? "Canvas" : frame.title)
                Spacer()
              }.font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 9).background(
                session.activeCanvasFrame?.id == frame.id ? Color.white : .clear)
            }.buttonStyle(.plain)
          }
          InspectorDivider().padding(.top, 12).padding(.horizontal, InspectorStyle.panelPadding)
          HStack {
            SectionLabel("LAYERS")
            Spacer()
            if !session.selection.isEmpty {
              Menu {
                Button("Group") { session.execute("group") }
                Button("Ungroup") { session.execute("ungroup") }
                Button("Bring to front") { session.execute("reorder", ["mode": "front"]) }
                Button("Send to back") { session.execute("reorder", ["mode": "back"]) }
                Button("Duplicate") { session.execute("duplicate") }
                Button("Delete") { session.execute("delete") }
              } label: {
                Image(systemName: "ellipsis")
              }.menuStyle(.borderlessButton).frame(width: 20)
            }
          }.padding(16)
          LazyVStack(spacing: 2) {
            ForEach(rows, id: \.element.id) { row in
              HStack(spacing: 6) {
                if row.element.component != nil {
                  Image(systemName: "diamond").font(.system(size: 10)).frame(width: 10)
                } else if row.element.kind == "group" {
                  Button {
                    if collapsed.contains(row.element.id) {
                      collapsed.remove(row.element.id)
                    } else {
                      collapsed.insert(row.element.id)
                    }
                  } label: {
                    Image(
                      systemName: collapsed.contains(row.element.id)
                        ? "chevron.right" : "chevron.down"
                    ).font(.system(size: 8))
                  }.buttonStyle(.plain).frame(width: 10)
                } else {
                  Image(
                    systemName: row.element.kind == "text"
                      ? "textformat"
                      : row.element.kind == "path"
                        ? "point.topleft.down.to.point.bottomright.curvepath"
                        : row.element.kind == "image" ? "photo" : "square"
                  ).font(.system(size: 10)).frame(width: 10)
                }
                if renaming == row.element.id {
                  TextField(
                    "Layer name",
                    text: Binding(
                      get: { session.art.elements.first { $0.id == row.element.id }?.title ?? "" },
                      set: { value in
                        session.mutate { a in
                          if let i = a.elements.firstIndex(where: { $0.id == row.element.id }) {
                            a.elements[i].name = value
                          }
                        }
                      })
                  ).textFieldStyle(.plain).onSubmit { renaming = nil }
                } else {
                  Text(row.element.title.isEmpty ? "Text" : row.element.title).lineLimit(1).frame(
                    maxWidth: .infinity, alignment: .leading
                  ).onTapGesture(count: 2) { renaming = row.element.id }
                }
                Button {
                  session.canvas?.finishText()
                  session.mutate { a in
                    if let i = a.elements.firstIndex(where: { $0.id == row.element.id }) {
                      a.elements[i].hidden = !(a.elements[i].hidden ?? false)
                    }
                  }
                } label: {
                  Image(systemName: row.element.hidden == true ? "eye.slash" : "eye").font(
                    .system(size: 9))
                }.buttonStyle(.plain).help("Toggle layer visibility")
                Button {
                  session.canvas?.finishText()
                  session.mutate { a in
                    if let i = a.elements.firstIndex(where: { $0.id == row.element.id }) {
                      a.elements[i].locked = !(a.elements[i].locked ?? false)
                    }
                  }
                } label: {
                  Image(systemName: row.element.locked == true ? "lock.fill" : "lock.open").font(
                    .system(size: 9))
                }.buttonStyle(.plain).help("Toggle layer lock")
              }.font(.system(size: 10)).foregroundStyle(
                row.element.hidden == true ? Palette.secondary : Palette.ink
              ).padding(.leading, 12 + CGFloat(min(row.depth, 6)) * 12).padding(.trailing, 9).frame(
                height: 32
              ).background(
                session.selection.contains(row.element.id) ? Color.white : .clear,
                in: RoundedRectangle(cornerRadius: 5)
              ).contentShape(Rectangle()).onTapGesture {
                if NSEvent.modifierFlags.contains(.shift) {
                  if session.selection.contains(row.element.id) {
                    session.selection.remove(row.element.id)
                  } else {
                    session.selection.insert(row.element.id)
                  }
                } else {
                  session.navigateGroup(to: row.element.parentID, selection: [row.element.id])
                }
              }.contextMenu {
                Button("Rename") { renaming = row.element.id }
                Button("Edit inside group") {
                  session.enterGroup(row.element.id)
                }.disabled(row.element.kind != "group" || row.element.component != nil)
                if row.element.component != nil {
                  Button("Edit component source") { session.editComponentSource(row.element) }
                  Button("Detach instance") {
                    session.choose([row.element.id])
                    session.component("detach")
                  }
                }
                Button("Delete") {
                  session.choose([row.element.id])
                  session.execute("delete")
                }
              }
            }
          }.padding(.horizontal, 5)
        }
      }.frame(minHeight: 0, maxHeight: .infinity)
    }.background(Palette.paper)
  }
}
