import AppKit
import FormCore
import SwiftUI

enum Palette {
  static let ink = Color(nsColor: NSColor(hex: "#292D2B"))
  static let secondary = Color(nsColor: NSColor(hex: "#7C8078"))
  static let accent = Color(nsColor: NSColor(hex: "#C96543"))
  static let paper = Color(nsColor: NSColor(hex: "#F7F6F2"))
  static let line = Color.black.opacity(0.08)
}

struct RootView: View {
  @EnvironmentObject var store: StudioStore
  @FocusedValue(\.designSurface) private var focusedDesignSurface: WorkspaceMode?
  var body: some View {
    VStack(spacing: 0) {
      StudioTopBar()
      Rectangle().fill(Palette.line).frame(height: 1)
      if store.showingHome { HomeView() } else { WorkspaceView() }
    }
    .background(Palette.paper).foregroundStyle(Palette.ink)
    .ignoresSafeArea(.container, edges: .top)
    .overlay(alignment: .bottom) {
      if let notice = store.notice {
        Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 17).padding(.vertical, 11).background(
            .regularMaterial, in: Capsule()
          ).overlay(Capsule().strokeBorder(.white.opacity(0.8)))
          .shadow(color: .black.opacity(0.08), radius: 16, y: 5).padding(.bottom, 54).transition(
            .move(edge: .bottom).combined(with: .opacity)
          ).allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.18), value: store.notice)
    .onChange(of:focusedDesignSurface) { _,surface in
      if let surface { store.activateDesignSurface(surface) }
    }
    .sheet(isPresented:$store.showingDocumentFonts) {DocumentFontsPanel(session:store.artworkSession)}
    .sheet(isPresented: $store.showingLibrary) { LibraryView().environmentObject(store) }
    .sheet(isPresented: $store.showingBridge) { BridgeView().environmentObject(store) }
    .sheet(isPresented: $store.showingProjectInfo) { ProjectInfoView().environmentObject(store) }
    .sheet(item: $store.svgImport) { review in
      SVGImportSheet(review: review).environmentObject(store)
    }
    .sheet(isPresented: $store.showingPrint) {
      PrintWorkspace(printing: store.printing).environmentObject(store)
    }
    .alert(
      "FORM",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("OK") { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
}

struct StudioTopBar: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    HStack(spacing: 14) {
      if store.showingHome {
        Text("FORM").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(4)
        Text("0.1").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
          Palette.secondary
        ).padding(.horizontal, 7).padding(.vertical, 3).background(Palette.line, in: Capsule())
      } else {
        IconButton("Home", symbol: "square.grid.2x2") { store.home() }
        Rectangle().fill(Palette.line).frame(width: 1, height: 20)
        Text(store.project?.name ?? "Untitled study").font(.system(size: 13, weight: .semibold))
          .lineLimit(1).frame(maxWidth: 210, alignment: .leading)
      }
      Spacer()
      if store.showingHome {
        Button {
          store.showingBridge = true
        } label: {
          Label("Codex connection", systemImage: "point.3.connected.trianglepath.dotted").font(
            .system(size: 12)
          ).foregroundStyle(Palette.secondary)
        }.buttonStyle(.plain)
        Rectangle().fill(Palette.line).frame(width: 1, height: 20)
        IconButton("Studio Library", symbol: "square.stack.3d.up") { store.showingLibrary = true }
      } else {
        IconButton("Project notes", symbol: "text.alignleft") { store.showingProjectInfo = true }
        IconButton("Materials & equipment", symbol: "square.stack.3d.up") {
          store.showingLibrary = true
        }
        IconButton("Print preparation · ⌘P", symbol: "printer") { store.printing.open() }
        Menu {
          Button("Studio image · PNG") { store.exportDialog("png") }
          Button("Printable artwork · PDF") { store.exportDialog("pdf") }.disabled(
            store.primary == nil)
          Button("Cut profile · SVG") { store.exportDialog("svg") }.disabled(
            !["sleeve", "clock"].contains(store.primary?.recipeID ?? ""))
          Button("Component summary · JSON") { store.exportDialog("json") }
          Divider()
          Button("Save project copy…") { store.saveCopy() }
        } label: {
          Image(systemName: "square.and.arrow.up").font(.system(size: 14)).frame(
            width: 30, height: 30)
        }.menuStyle(.borderlessButton).fixedSize().help("Export")
        AddObjectMenu()
      }
    }
    .padding(.leading, 92).padding(.trailing, 22).frame(height: 62)
    .overlay {
      if !store.showingHome {
        HStack(spacing: 3) {
          ForEach(WorkspaceMode.allCases, id: \.self) { mode in
            Button {
              store.showSurface(mode)
            } label: {
              Label(
                mode.rawValue,
                systemImage: mode == .table
                  ? "cube.transparent" : mode == .artwork ? "square.and.pencil" : "camera.aperture"
              )
              .font(.system(size: 12, weight: store.mode == mode ? .semibold : .medium))
              .padding(.horizontal, 13).padding(.vertical, 8)
              .background(
                store.mode == mode ? Color.white : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
              )
              .shadow(color: .black.opacity(store.mode == mode ? 0.04 : 0), radius: 2, y: 1)
            }.buttonStyle(.plain).foregroundStyle(
              store.mode == mode ? Palette.ink : Palette.secondary)
          }
          Rectangle().fill(Palette.line).frame(width:1,height:19).padding(.horizontal,3)
          Button { store.showSplit() } label: {
            Image(systemName:"rectangle.split.2x1").frame(width:30,height:30)
              .foregroundStyle(store.surfaceLayout == .split ? Palette.accent : Palette.secondary)
          }.buttonStyle(.plain).help("Canvas and Table side by side").accessibilityLabel("Split Canvas and Table")
          Button { store.detachCanvas() } label: {
            Image(systemName:"arrow.up.forward.square").frame(width:30,height:30)
          }.buttonStyle(.plain).help("Open Canvas in a separate window").accessibilityLabel("Open Canvas window")

        }.padding(4).background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
      }
    }
    .background(Palette.paper)
  }
}

struct IconButton: View {
  var title: String
  var symbol: String
  var action: () -> Void
  @State private var hover = false
  init(_ title: String, symbol: String, action: @escaping () -> Void) {
    self.title = title
    self.symbol = symbol
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(
        width: 32, height: 32
      ).background(hover ? Palette.line : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain).onHover { hover = $0 }.help(title).accessibilityLabel(title)
  }
}

struct AddObjectMenu: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    Menu {
      ForEach(Recipe.builtins.filter { $0.id != "reference" && $0.id != "patternAssembly" } + (store.project?.recipes ?? [])) {
        recipe in
        Button {
          store.add(recipe)
        } label: {
          Label(recipe.name, systemImage: recipe.symbol)
        }
      }
      Divider()
      Button {
        store.importReference()
      } label: {
        Label("Import reference…", systemImage: "photo")
      }
    } label: {
      Label("Add object", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(
        .horizontal, 12
      ).padding(.vertical, 8).background(Palette.ink, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
    .menuStyle(.borderlessButton).fixedSize().help("Add a physical object or reference")
  }
}

struct HomeView: View {
  @EnvironmentObject var store: StudioStore
  @State private var search = ""
  var filtered: [ProjectSummary] {
    store.projects.filter {
      search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        || $0.subtitle.localizedCaseInsensitiveContains(search)
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        HStack(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 11) {
            Text("A PLACE TO MAKE THINGS").font(.system(size: 10, weight: .semibold)).tracking(2.3)
              .foregroundStyle(Palette.secondary)
            Text("Your studio.").font(.system(size: 43, weight: .regular, design: .serif)).tracking(
              -1.1)
            Text("Pick up where you left off, or put a new idea on the table.").font(
              .system(size: 14)
            ).foregroundStyle(Palette.secondary)
          }
          Spacer()
          Button {
            store.createProject()
          } label: {
            Label("New project", systemImage: "plus").font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 18).padding(.vertical, 12).foregroundStyle(.white).background(
                Palette.ink, in: RoundedRectangle(cornerRadius: 9))
          }.buttonStyle(.plain)
        }.padding(.top, 48).padding(.bottom, 8)
        HStack {
          Text("PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(1.6)
          Text(String(store.projects.count)).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.secondary)
          Spacer()
          HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
            TextField("Find a project", text: $search).textFieldStyle(.plain)
          }.font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(9).frame(width: 200)
            .background(.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
          Button("Open…") { store.openPackage() }.buttonStyle(.plain).font(.system(size: 12))
            .padding(.leading, 12)
        }
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 310, maximum: 520), spacing: 25)],
          alignment: .leading, spacing: 30
        ) {
          ForEach(filtered) { project in ProjectCard(project: project) }
          if store.projects.isEmpty { NewProjectCard() }
        }
        if search.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              SectionLabel("START WITH A STUDY")
              Spacer()
              Menu("All studies") {
                ForEach(Samples.templates) { template in Button(template.title) { store.createProject(template: template.id) } }
              }.font(.system(size: 11)).fixedSize(horizontal: true, vertical: false).accessibilityLabel("Browse all studies")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 22)], spacing: 22) {
              ForEach(Samples.templates.prefix(3)) { StudyCard(template: $0) }
            }
          }
        }
        HStack(spacing: 10) {
          Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 17))
          Text("A conversation here. An object there.").font(.system(size: 12, weight: .medium))
          Text("Create with Codex, then make it your own in FORM.").font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
          Spacer()
          Button("Connect Codex") { store.showingBridge = true }.buttonStyle(.plain).font(
            .system(size: 12, weight: .medium)
          ).foregroundStyle(Palette.accent)
        }.padding(19).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line)).padding(.top, 12)
        HStack {
          Text("LOCAL FILES. REAL DIMENSIONS. ROOM TO EXPERIMENT.").font(
            .system(size: 9, weight: .medium)
          ).tracking(1.6)
          Spacer()
          Text("FORM  /  STUDIO 0.1").font(.system(size: 9, design: .monospaced))
        }.foregroundStyle(Palette.secondary.opacity(0.75)).padding(.top, 10).padding(.bottom, 24)
      }.padding(.horizontal, 52).frame(maxWidth: 1600)
        .frame(maxWidth: .infinity)
    }.background(Palette.paper)
  }
}

struct ProjectCard: View {
  @EnvironmentObject var store: StudioStore
  let project: ProjectSummary
  @State private var hover = false
  @State private var preview: NSImage?
  var body: some View {
    Button {
      store.openProject(project.id)
    } label: {
      VStack(alignment: .leading, spacing: 13) {
        ZStack(alignment: .bottomLeading) {
          RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: NSColor(hex: "#ECEBE5")))
          if let preview {
            GeometryReader { geometry in
              Image(nsImage: preview).resizable().scaledToFill().frame(
                width: geometry.size.width, height: geometry.size.height
              ).clipped()
            }
          } else {
            Image(systemName: "cube.transparent").font(.system(size: 35, weight: .ultraLight))
              .foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          Text(project.contentDescription.uppercased()).font(
            .system(size: 8, weight: .semibold, design: .monospaced)
          ).tracking(1).padding(.horizontal, 9).padding(.vertical, 6).background(
            .regularMaterial, in: Capsule()
          ).padding(14)
          if hover {
            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).padding(9)
              .background(.white, in: Circle()).frame(
                maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing
              ).padding(13)
          }
        }
        .frame(height: 225).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(
          RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(hover ? 0.15 : 0.055)))
        VStack(alignment: .leading, spacing: 5) {
          HStack {
            Text(project.name).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(
              project.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
          }
          Text(project.subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            .lineLimit(1)
        }
      }
    }.buttonStyle(.plain).onHover { hover = $0 }
      .task(id: store.previewVersion) {
        preview = NSImage(contentsOf: store.previewURL(project.id))
      }
      .accessibilityLabel("Open \(project.name), \(project.contentDescription)")
  }
}

struct NewProjectCard: View {
  @EnvironmentObject var store: StudioStore
  @State private var hover = false
  var body: some View {
    Button {
      store.createProject()
    } label: {
      VStack(alignment: .leading, spacing: 13) {
        VStack(spacing: 12) {
          Image(systemName: "plus").font(.system(size: 23, weight: .ultraLight)).frame(
            width: 49, height: 49
          ).background(.white.opacity(0.8), in: Circle())
          Text("Room for a new idea").font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 225).background(
          .black.opacity(hover ? 0.035 : 0.012), in: RoundedRectangle(cornerRadius: 11)
        ).overlay(
          RoundedRectangle(cornerRadius: 11).strokeBorder(
            Palette.ink.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 5])))
        VStack(alignment: .leading, spacing: 5) {
          Text("Start a new project").font(.system(size: 15, weight: .semibold))
          Text("An open Canvas. All the possibilities.").font(.system(size: 12)).foregroundStyle(
            Palette.secondary)
        }
      }
    }.buttonStyle(.plain).onHover { hover = $0 }
  }
}

struct WorkspaceView: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    Group {
      if store.surfaceLayout == .split {
        HSplitView {
          ArtworkWorkspace().frame(minWidth: 440)
          TableWorkspace().frame(minWidth: 360)
        }
      } else if store.surfaceLayout == .detached || store.mode != .artwork {
        TableWorkspace()
      } else {
        ArtworkWorkspace()
      }
    }.safeAreaInset(edge: .bottom, spacing: 0) { WorkspaceStatus() }
  }
}

struct TableWorkspace: View {
  @EnvironmentObject var store: StudioStore
  @State private var showingObjectControls = false
  var body: some View {
    ZStack {
      TableCanvas()
      VStack {
        HStack(alignment: .top) {
          TableHeading()
          Spacer()
          if store.mode == .studio {
            StudioPanel()
          } else if store.primary != nil {
            if store.surfaceLayout == .split {
              Button { showingObjectControls.toggle() } label: {
                Label(store.primary?.name ?? "Object controls", systemImage: "slider.horizontal.3")
                  .font(.system(size: 11,weight:.medium)).lineLimit(1)
                  .padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:9))
              }.buttonStyle(.plain).popover(isPresented:$showingObjectControls) {
                ObjectInspector().frame(maxHeight:650).environmentObject(store)
              }
            } else { ObjectInspector().id(store.primary?.id) }
          }
        }.padding(24)
        Spacer(minLength: 0)
        HStack(alignment: .bottom) {
          CameraControls()
          Spacer()
          if store.project?.objects.isEmpty == false && store.surfaceLayout != .split {
            Text(store.mode == .studio ? "A different light. The same objects." : store.tableTool.hint)
              .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.bottom,14)
          }
        }.padding(.horizontal,24).padding(.bottom,18)
      }
      if store.project?.objects.filter({ !$0.isCanvasWorkspace }).isEmpty == true { EmptyTableView() }
    }.focusedValue(\.designSurface,store.mode == .studio ? .studio : .table)
  }
}

struct TableHeading: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 9) {
        Text(store.mode == .studio ? "RENDERING STUDIO" : "THE TABLE").font(
          .system(size: 10, weight: .semibold)
        ).tracking(1.7)
        if !store.isolated.isEmpty {
          Text("ISOLATED").font(.system(size: 8, weight: .semibold)).tracking(0.7).foregroundStyle(
            Palette.accent
          ).padding(.horizontal, 7).padding(.vertical, 4).background(
            Palette.accent.opacity(0.09), in: Capsule())
        }
      }
      Text(store.isolated.isEmpty ? store.project?.subtitle ?? "" : "A little space to focus.")
        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
      if !store.isolated.isEmpty {
        Button {
          store.isolate()
        } label: {
          Label("Back to all objects", systemImage: "arrow.uturn.backward").font(.system(size: 11))
        }.buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 4)
      }
    }.padding(.top, 5).allowsHitTesting(!store.isolated.isEmpty)
  }
}

struct EmptyTableView: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    VStack(spacing: 17) {
      Image(systemName: "cube.transparent").font(.system(size: 44, weight: .ultraLight))
        .foregroundStyle(Palette.secondary.opacity(0.6))
      Text("Something starts here.").font(.system(size: 28, weight: .regular, design: .serif))
      Text("Place an object, bring in a reference, or make something with Codex.").font(
        .system(size: 13)
      ).foregroundStyle(Palette.secondary)
      HStack(spacing: 14) {
        AddObjectMenu()
        Button("Connect Codex") { store.showingBridge = true }.buttonStyle(.plain).font(
          .system(size: 12, weight: .medium))
      }.padding(.top, 6)
    }.padding(35).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
  }
}

struct CameraControls: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    HStack(spacing: 3) {
      ForEach(TableTool.allCases, id: \.self) { tool in
        Button {
          store.setTableTool(tool)
        } label: {
          Label(tool.rawValue, systemImage: tool.symbol)
            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).frame(height: 32)
            .foregroundStyle(store.tableTool == tool ? Palette.ink : Palette.secondary)
            .background(
              store.tableTool == tool ? Color.white.opacity(0.9) : .clear,
              in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help("\(tool.rawValue) · \(tool.shortcut)")
          .accessibilityLabel("\(tool.rawValue) tool · \(tool.shortcut)")
          .accessibilityValue(store.tableTool == tool ? "Selected" : "")
      }
      Rectangle().fill(Palette.line).frame(width: 1, height: 20).padding(.horizontal, 5)
      ForEach([("Perspective", "perspective", "1"), ("Top", "overhead", "2"), ("Front", "front", "3")], id: \.0) { title, view, shortcut in
        Button(title) { store.scene?.preset(view) }
          .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
          .padding(.horizontal, 7).frame(height: 32)
          .help("\(title) · \(shortcut) · Frame the whole project")
          .accessibilityLabel("\(title) view · \(shortcut)")
      }
      Rectangle().fill(Palette.line).frame(width: 1, height: 20).padding(.horizontal, 5)
      IconButton("Zoom out", symbol: "minus") { store.scene?.zoom(18) }
      IconButton("Zoom in", symbol: "plus") { store.scene?.zoom(-18) }
      IconButton("Fit all · ⌘0", symbol: "arrow.up.left.and.arrow.down.right") {
        store.scene?.fitAll()
      }
      IconButton("Focus selection · F", symbol: "viewfinder") {
        store.scene?.focusSelection()
      }.disabled(store.selected.isEmpty)
      IconButton("Toggle 100 mm grid", symbol: "grid") { store.showGrid.toggle() }

    }.padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13)).overlay(
      RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.75))
    ).shadow(color: .black.opacity(0.06), radius: 14, y: 5)
  }
}

struct WorkspaceStatus: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(Color(nsColor: NSColor(hex: "#7C9278"))).frame(width: 5, height: 5)
      Text(store.saving ? "Saving…" : "Saved locally").font(.system(size: 10))
      Text("/").foregroundStyle(.black.opacity(0.15))
      Text(store.project?.contentDescription ?? "0 objects").font(.system(size: 10))
      if !store.selected.isEmpty {
        Text("·  \(store.selected.count) selected").font(.system(size: 10))
      }
      Spacer()
      Menu {
        Button("Millimeters") { store.edit("Changed units") { $0.unit = "mm" } }
        Button("Inches") { store.edit("Changed units") { $0.unit = "in" } }
      } label: {
        Text(store.project?.unit == "in" ? "INCHES" : "MILLIMETERS").font(
          .system(size: 8, weight: .semibold, design: .monospaced)
        ).tracking(1)
      }.menuStyle(.borderlessButton).fixedSize()
      Rectangle().fill(Palette.line).frame(width: 1, height: 12)
      Button {
        store.showingBridge = true
      } label: {
        HStack(spacing: 5) {
          Circle().fill(store.bridgeReady ? Color.green.opacity(0.65) : .gray).frame(
            width: 4, height: 4)
          Text("Codex bridge").font(.system(size: 10))
        }
      }.buttonStyle(.plain)
    }.foregroundStyle(Palette.secondary).padding(.horizontal, 24).frame(height: 31).background(
      Palette.paper
    ).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
  }
}
