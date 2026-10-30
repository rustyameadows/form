import FormCore
import SwiftUI

extension StudioStore {
  @discardableResult func useLibraryEntry(_ entry: ObjectLibraryEntry, replacing id: UUID? = nil) -> Bool {
    do {
      if let id {
        _ = try engine.call("form_object_library", arguments: ["command":"replace", "object_id":id.uuidString, "entry_id":entry.id], source:"Studio")
      } else {
        guard let project else { throw FormError.missing("Open a project first.") }
        let preview = try project.makeObject(recipeID:entry.recipeID, parameters:entry.parameters, materialID:entry.materialID)
        let edge = project.objects.filter { $0.hasTablePresentation }.map { $0.position.x + $0.footprintWidth/2 }.max()
        let x = edge.map { $0 + preview.footprintWidth/2 + 70 } ?? 0
        _ = try engine.call("form_object_library", arguments:["command":"add", "entry_id":entry.id, "position":[x,0.0,0.0]], source:"Studio")
      }
      changed(); synchronizeScene(); scene?.focusSelection()
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
}

struct ObjectLibraryView: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var domain = "All domains"
  @State private var category = "All categories"
  @State private var mode = "Starters"
  @State private var selectedID: String?
  private var replacement: ProductObject? { store.project?.objects.first { $0.id == store.libraryReplacementID } }
  private var references: [ObjectLibraryReference] {
    let matching = ObjectLibrary.search(query, domain:domain == "All domains" ? nil : domain, readyOnly:mode == "Starters")
      .filter { category == "All categories" || $0.category == category }
      .filter { r in replacement == nil || ObjectLibrary.starters.contains { $0.referenceID == r.id && $0.recipeID == replacement?.recipeID } }
    guard mode == "Starters" else { return matching }
    let order = Dictionary(ObjectLibrary.starters.enumerated().map { ($0.element.referenceID,$0.offset) },uniquingKeysWith:min)
    return matching.sorted { (order[$0.id] ?? 999) < (order[$1.id] ?? 999) }
  }
  private var selected: ObjectLibraryReference? {
    references.first { $0.id == selectedID } ?? references.first
  }
  var body: some View {
    VStack(spacing:0) {
      HStack {
        VStack(alignment:.leading, spacing:5) {
          Text(replacement == nil ? "Object library" : "Change blank").font(.system(size: 27, weight: .semibold))
          Text("\(ObjectLibrary.starters.count) editable starters · 211 form references").font(.system(size:12)).foregroundStyle(.secondary)
        }
        Spacer()
        AppCloseButton("Close", keyEquivalent: "\u{1b}") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(22)
      HStack {
        Picker("Browse", selection:$mode) { Text("Starters").tag("Starters"); Text("Reference catalog").tag("Reference catalog"); Text("Work examples").tag("Work examples") }.pickerStyle(.segmented).frame(width:420)
        Spacer()
        TextField("Search forms, products, materials…",text:$query).textFieldStyle(.roundedBorder).frame(width:280)
      }.padding(.horizontal,22).padding(.bottom,12)
      if mode == "Work examples" { examples }
      else {
        HStack {
          Picker("Domain",selection:$domain) {
            Text("All domains").tag("All domains")
            ForEach(Array(Set(ObjectLibrary.catalog.references.map(\.domain))).sorted(),id:\.self) { Text($0).tag($0) }
          }.frame(width:250).onChange(of:domain) { _,_ in category="All categories" }
          Picker("Category",selection:$category) {
            Text("All categories").tag("All categories")
            ForEach(Array(Set(ObjectLibrary.catalog.references.filter { domain == "All domains" || $0.domain == domain }.map(\.category))).sorted(),id:\.self) { Text($0).tag($0) }
          }.frame(width:360)
          Spacer(); Text("\(references.count) forms").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal,22).padding(.bottom,12)
        Divider()
        HSplitView {
          List(selection:$selectedID) {
            ForEach(references) { r in
              VStack(alignment:.leading,spacing:5) {
                Text(r.name).font(.system(size:12,weight:.medium))
                Text(r.id + " · " + r.construction).font(.system(size:10)).foregroundStyle(.secondary)
              }.padding(.vertical,5).tag(r.id)
            }
          }.frame(minWidth:290,idealWidth:330,maxWidth:400)
          if let r = selected { detail(r).frame(minWidth:410,maxWidth:.infinity) }
          else { ContentUnavailableView("No matching forms",systemImage:"magnifyingglass",description:Text("Try a different search or category.")).frame(maxWidth:.infinity) }
        }
      }
    }.frame(width:960,height:680).background(Palette.paper)
      .onAppear { if selectedID == nil { selectedID = references.first?.id } }
      .onChange(of: references.map(\.id)) { _,ids in
        if selectedID.map({ !ids.contains($0) }) ?? true { selectedID = ids.first }
      }
  }
  private func detail(_ r: ObjectLibraryReference) -> some View {
    ScrollView {
      VStack(alignment:.leading,spacing:18) {
        Text(r.name).font(.system(size: 24, weight: .semibold))
        Text(r.domain + " / " + r.category).font(.caption).foregroundStyle(.secondary)
        Text(r.distinction)
        Text(r.options).font(.system(size:12)).foregroundStyle(.secondary)
        if let url=URL(string:r.referenceURL) { Link(r.referenceName,destination:url) }
        Text("\(r.referenceType) · workbook reference dated \(ObjectLibrary.catalog.sourceDate)").font(.caption).foregroundStyle(.secondary)
        if !r.notes.isEmpty { Text(r.notes).font(.system(size:12)) }
        let entries = ObjectLibrary.starters.filter { $0.referenceID == r.id && (replacement == nil || $0.recipeID == replacement?.recipeID) }
        ForEach(entries) { entry in
          Divider()
          Text(entry.name).font(.headline)
          Text(entry.reason).font(.system(size:12))
          if let blank=entry.blank {
            Text(blank.manufacturer + " · " + blank.style).font(.system(size:12,weight:.semibold))
            Text(blank.specifications).font(.system(size:12))
            BlankReferenceFacts(blank:blank)
          }
          Text(entry.representation).font(.system(size:11)).foregroundStyle(.secondary)
        }
        if entries.isEmpty { Text("Reference only. This construction does not yet have an editable starter.").font(.system(size:12)).foregroundStyle(.secondary) }
        Divider()
        Text("Materials and options").font(.headline)
        ForEach(ObjectLibrary.catalog.materialOptions.filter { $0.domain == r.domain },id:\.group) { option in
          DisclosureGroup(option.group) {
            VStack(alignment:.leading,spacing:6) {
              Text(option.choices); Text(option.details).foregroundStyle(.secondary)
              if let url=URL(string:option.referenceURL) { Link(option.referenceName,destination:url) }
            }.font(.system(size:11)).padding(.top,5)
          }
        }
      }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
    }.safeAreaInset(edge:.bottom) {
      if let entry=ObjectLibrary.starters.first(where: { $0.referenceID == r.id && (replacement == nil || $0.recipeID == replacement?.recipeID) }) {
        HStack {
          Text(entry.name).font(.system(size:12,weight:.medium))
          Spacer()
          Button(replacement == nil ? (entry.blank == nil ? "Add concept" : "Start with this blank") : "Use this blank") {
            if store.useLibraryEntry(entry,replacing:replacement?.id) { dismiss() }
          }.buttonStyle(.borderedProminent).disabled(store.project == nil)
            .accessibilityIdentifier("object-library-use")
        }.padding(16).background(Palette.paper).overlay(alignment:.top) { Divider() }
      }
    }
  }
  private var examples: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:22) {
        ForEach(ObjectLibrary.catalog.workExamples.filter { query.isEmpty || ($0.name + " " + $0.components).localizedCaseInsensitiveContains(query) },id:\.name) { example in
          VStack(alignment:.leading,spacing:9) {
            Text(example.name).font(.system(size: 20, weight: .semibold))
            Text(example.components)
            Text(example.sizing).foregroundStyle(.secondary)
            Text(example.notes).font(.system(size:12))
            Text("Artwork: " + example.surfaces).font(.system(size:12))
            ForEach(example.referenceIDs,id:\.self) { id in
              if let r=ObjectLibrary.reference(id) {
                Button(r.id + " · " + r.name) { mode="Reference catalog"; domain="All domains"; category="All categories"; query=""; selectedID=id }.buttonStyle(.link)
              }
            }
          }
          Divider()
        }
      }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
    }
  }
}

struct ObjectLibraryInspector: View {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  var body: some View {
    if let s=object.librarySelection {
      VStack(alignment:.leading,spacing:10) {
        SectionLabel("LIBRARY SOURCE")
        Text(s.state.name).font(.system(size:12,weight:.semibold))
        if let blank=s.entry.blank {
          Text(blank.manufacturer + " · " + blank.style).font(.system(size:12))
          Text(blank.productName).font(.system(size:11))
          if let url=URL(string:blank.productURL) { Link("Product reference",destination:url).font(.system(size:11)) }
          Text(blank.specifications).font(.system(size:10)).foregroundStyle(Palette.secondary)
          BlankReferenceFacts(blank:blank)
        }
        Text(s.entry.reason).font(.system(size:11))
        Text(s.entry.representation).font(.system(size:10)).foregroundStyle(Palette.secondary)
        if s.state == .custom { Text("Form or material changed. The source product is retained as a reference.").font(.system(size:10)).foregroundStyle(Palette.secondary) }
        Text("Size and color variants, availability and production route are still to be checked.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        HStack {
          Button("Change…") { store.libraryReplacementID=object.id; store.showingObjectLibrary=true }
          if s.entry.blank != nil && s.state != .custom {
            Button(s.state == .chosenBlank ? "Release choice" : "Choose blank") {
              store.perform("form_object_library",["command":"state","object_id":object.id.uuidString,
                "state":s.state == .chosenBlank ? "proposedBlank":"chosenBlank"])
            }
          }
        }.disabled(object.locked)
        if !s.alternatives.isEmpty {
          DisclosureGroup("Previous starting choices") {
            ForEach(s.alternatives) { entry in
              Button(entry.name) { _ = store.useLibraryEntry(entry,replacing:object.id) }.disabled(object.locked)
            }
          }.font(.system(size:11))
        }
      }
    }
  }
}

private struct BlankReferenceFacts: View {
  let blank: BlankIdentity
  var body: some View {
    VStack(alignment:.leading,spacing:5) {
      if let fabric=blank.fabricComposition { Text("Reference fabric: " + fabric) }
      if let weight=blank.fabricWeight { Text("Reference weight: " + weight) }
      if let fit=blank.fit { Text("Fit: " + fit) }
      if let sizes=blank.referenceSizes { Text("Reference sizes: " + sizes.joined(separator:", ")) }
      if let methods=blank.decorationMethods { Text("Suggested methods: " + methods.joined(separator:", ")) }
      if let reviewed=blank.reviewedOn { Text("Product page reviewed " + reviewed) }
    }.font(.system(size:10)).foregroundStyle(.secondary)
  }
}
