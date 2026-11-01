import FormCore
import SwiftUI

struct TableNavigationItem:Identifiable,Equatable {
  let id:UUID
  let title:String
  let subtitle:String
  let symbol:String
  let groupID:UUID?
  let groupCount:Int
  let isVisible:Bool
  let isLocked:Bool
}

enum TableNavigationInventory {
  static func items(in project:Project?,query:String="",isolated:Set<UUID>=[])->[TableNavigationItem] {
    guard let project else{return []}
    let objects=project.objects.filter(\.hasTablePresentation)
    let groups=Dictionary(grouping:objects.compactMap{object in object.groupID.map{($0,object.id)}},by:{$0.0})
    var ordinals:[UUID:Int]=[:]
    for object in objects {if let id=object.groupID,ordinals[id]==nil {ordinals[id]=ordinals.count+1}}
    return objects.compactMap {object in
      let visible=isolated.isEmpty || isolated.contains(object.id),count=object.groupID.flatMap{groups[$0]?.count} ?? 0
      let type=project.recipe(object.recipeID)?.name ?? "Object"
      var details=[type]
      if let group=object.groupID {details.append("Group \(ordinals[group] ?? 1) · \(count)")}
      if !visible {details.append("Hidden by isolation")}
      if object.locked {details.append("Locked")}
      let subtitle=details.joined(separator:" · ")
      guard WorkspaceFindMatching.matches(query,in:[object.name,subtitle]) else{return nil}
      return .init(id:object.id,title:object.name,subtitle:subtitle,symbol:project.recipe(object.recipeID)?.symbol ?? "cube.transparent",
        groupID:object.groupID,groupCount:count,isVisible:visible,isLocked:object.locked)
    }
  }
}

/// The Table's persistent list and Cmd-F share this one search field and query.
struct TableObjectNavigator:View {
  @EnvironmentObject var store:StudioStore
  var maxHeight:CGFloat=360
  @State private var highlightedID:UUID?
  @FocusState private var searchFocused:Bool
  private var items:[TableNavigationItem] {TableNavigationInventory.items(in:store.project,query:store.tableSearchQuery,isolated:store.isolated)}

  static func height(for objectCount:Int,maxHeight:CGFloat)->CGFloat {
    min(max(0,maxHeight),360,max(174,120+CGFloat(objectCount)*42))
  }
  var body:some View {
    let rows=items
    VStack(spacing:0) {
      FloatingPanelHeader("OBJECTS",closeLabel:"Close Table objects",onClose:close) {
        Text("\(rows.count)").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      TextField("Find an object",text:$store.tableSearchQuery)
        .textFieldStyle(InspectorTextFieldStyle()).focused($searchFocused)
        .accessibilityLabel("Search Table objects").accessibilityIdentifier("table-navigator-search")
        .onSubmit{navigateHighlighted()}
        .onKeyPress(.upArrow,phases:[.down,.repeat]){_ in moveHighlight(-1);return .handled}
        .onKeyPress(.downArrow,phases:[.down,.repeat]){_ in moveHighlight(1);return .handled}
        .padding(.horizontal,12).padding(.top,8).padding(.bottom,6)
      ScrollViewReader {proxy in
        ScrollView {
          LazyVStack(spacing:2) {
            if rows.isEmpty {
              Text(store.tableSearchQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "No objects on the Table":"No matching objects")
                .font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity,minHeight:54)
            }
            ForEach(rows) {item in
              row(item).id(item.id)
            }
          }.padding(.horizontal,6).padding(.vertical,4)
        }
        .onChange(of:highlightedID){_,id in if let id {proxy.scrollTo(id,anchor:.center)}}
      }
      HStack {Text("↑ ↓ choose · Return focus");Spacer(minLength:0)}
        .font(.system(size:9)).foregroundStyle(Palette.secondary).padding(.horizontal,12).padding(.vertical,7)
    }
    .frame(width:220,height:Self.height(for:rows.count,maxHeight:maxHeight))
    .floatingPanelSurface()
    .accessibilityElement(children:.contain).accessibilityLabel("Table objects")
    .onAppear {
      reconcileHighlight(rows)
      if store.tableSearchFocusRequest>0 {searchFocused=true}
    }
    .onChange(of:store.tableSearchFocusRequest){_,_ in searchFocused=true;reconcileHighlight(rows)}
    .onChange(of:store.tableSearchQuery){_,_ in highlightedID=items.first?.id}
    .onChange(of:rows.map(\.id)){_,_ in reconcileHighlight(rows)}
    .onMoveCommand {direction in
      if direction == .up {moveHighlight(-1)}
      if direction == .down {moveHighlight(1)}
    }
    .onExitCommand(perform:escape)
  }
  private func row(_ item:TableNavigationItem)->some View {
    let selected=store.engine.selection.contains(item.id),highlighted=highlightedID==item.id && searchFocused
    return WorkspaceNavigationRow(title:item.title,subtitle:item.subtitle,symbol:item.symbol,selected:selected,highlighted:highlighted,
      statusSymbols:(item.isVisible ? []:["eye.slash"])+(item.isLocked ? ["lock"]:[]),
      accessibilityLabel:"Navigate to "+item.title,identifier:"table-navigator-object-"+item.id.uuidString) {
      highlightedID=item.id
      _ = store.navigateToTableObject(item.id)
    }.contextMenu {
      SelectionReferenceMenuActions(store: store, reference: store.objectSelectionReference([item.id]))
    }
  }
  private func reconcileHighlight(_ rows:[TableNavigationItem]) {
    if let highlightedID,rows.contains(where:{$0.id==highlightedID}) {return}
    highlightedID=rows.first(where:{store.engine.selection.contains($0.id)})?.id ?? rows.first?.id
  }
  private func moveHighlight(_ delta:Int) {
    let rows=items
    guard !rows.isEmpty else{highlightedID=nil;return}
    if let index=rows.firstIndex(where:{$0.id==highlightedID}) {
      highlightedID=rows[min(rows.count-1,max(0,index+delta))].id
    } else {highlightedID=delta<0 ? rows.last?.id:rows.first?.id}
  }
  private func navigateHighlighted() {
    let rows=items
    guard let id=highlightedID,rows.contains(where:{$0.id==id}) else{return}
    _ = store.navigateToTableObject(id)
  }
  private func escape() {
    if !store.tableSearchQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {store.tableSearchQuery=""}
    else {close()}
  }
  private func close() {searchFocused=false;store.tableNavigatorVisible=false}
}
