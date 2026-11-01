import Foundation

extension ArtworkTransferBundle {
  /// Convert a fully normalized external graph into the shared resource/Undo
  /// transaction without inventing a source project or inheriting its settings.
  public static func external(artwork:Artwork,selection:Set<UUID>,assets:[String:Data],
    components:[ArtworkTransferComponent]=[],application:String)throws->Self {
    guard !application.isEmpty else{throw FormError.invalid("An external import needs its source application.")}
    let refs=assets.keys.sorted().map{name -> ArtworkTransferAsset in
      let data=assets[name]!,digest=Self.digest(data),ext=URL(fileURLWithPath:name).pathExtension.lowercased()
      return .init(sourceName:name,portableName:Self.portableName(digest:digest,extension:ext),sha256:digest,length:data.count)
    }
    let metadata=ArtworkTransferMetadata(sourceSchema:Project.maximumSchemaVersion,projectID:UUID(),ownerID:UUID(),
      selection:selection.sorted{$0.uuidString<$1.uuidString},artwork:artwork,components:components,styles:[],swatches:[],assets:refs,sourceApplication:application)
    let bundle=Self(metadata:metadata,blobs:assets)
    try bundle.validate()
    return bundle
  }
}
