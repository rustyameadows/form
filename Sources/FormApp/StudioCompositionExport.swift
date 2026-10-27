import Foundation
import FormCore

extension StudioStore {
  func exportStudioComposition(format:String,arguments:[String:Any])async throws->Any {
    guard Set(arguments.keys).isSubset(of:["format","scene_id","path"]),["png","mp4"].contains(format),let project,
      let raw=arguments["scene_id"] as? String,let id=UUID(uuidString:raw),let scene=project.studioPresentation?.scenes?.first(where:{$0.id==id}) else{throw FormError.invalid("Scene export needs a saved scene_id, png or mp4 format and an optional new absolute output-folder path.")}
    let destination:URL
    if let raw=arguments["path"] {guard let path=raw as? String,path.hasPrefix("/") else{throw FormError.invalid("Scene output path must be absolute.")};destination=URL(fileURLWithPath:path,isDirectory:true)}
    else {let parent=repository.url(for:project.id).appendingPathComponent("Exports");try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true);destination=parent.appendingPathComponent("Scene-"+UUID().uuidString+(format=="mp4" ? ".motion":".render"))}
    let url=try await studioComposition.export(scene,to:destination,video:format=="mp4")
    return ["path":url.path,"folder":destination.path,"record":destination.appendingPathComponent("render.json").path,"format":format,"scene_id":id.uuidString]
  }
}
