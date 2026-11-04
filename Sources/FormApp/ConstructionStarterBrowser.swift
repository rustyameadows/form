import FormCore
import SwiftUI

struct ConstructionStarterBrowser:View {
  @EnvironmentObject var store:StudioStore
  let query:String
  let onAdded:()->Void
  @State private var starters:[ConstructionStarter]=[]
  @State private var error:String?
  @State private var projectID:UUID?
  private var matching:[ConstructionStarter]{starters.filter{query.isEmpty || ($0.name+" "+$0.summary).localizedCaseInsensitiveContains(query)}}
  var body:some View {
    ScrollView {
      LazyVStack(alignment:.leading,spacing:14) {
        if let error{Text(error).font(InspectorStyle.labelFont).foregroundStyle(.orange)}
        if matching.isEmpty,error==nil {ContentUnavailableView("No construction starters",systemImage:"square.3.layers.3d",description:Text("Import an authored construction source or try another search."))}
        ForEach(matching){starter in
          HStack(alignment:.top,spacing:14) {
            Image(systemName:starter.symbol).font(.system(size:24)).frame(width:40,height:40)
            VStack(alignment:.leading,spacing:7) {
              Text(starter.name).font(.headline)
              Text(starter.summary).font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
              Text("\(starter.definition.components?.count ?? 1) independent cut pieces · editable construction and canonical artwork").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength:8)
            Button("Add construction") {
              guard let projectID else{return}
              if PartAssemblyNativeEditing.importStarter(store:store,projectID:projectID,starter:starter) != nil{onAdded()}
            }.buttonStyle(InspectorActionStyle()).disabled(store.project?.id != projectID).accessibilityIdentifier("construction-starter-add-"+starter.id)
          }.padding(16).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
        }
      }.padding(22)
    }.onAppear {
      projectID=store.project?.id
      do{starters=try ConstructionStarterCatalog.bundled().starters;error=nil}catch{self.error=error.localizedDescription}
    }
  }
}
