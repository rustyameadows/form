import AppKit
import FormCore

extension StudioStore {
  func exportSavedStudioShot(format:String,arguments:[String:Any])throws->Any {
    guard Set(arguments.keys).isSubset(of:["format","shot_id","path","width","height","object_id"]),arguments["path"] == nil || arguments["path"] is String else{throw FormError.invalid("Unknown saved-shot export argument or invalid path.")}
    guard format=="png",arguments["object_id"]==nil,let project else{throw FormError.invalid("Saved shot export requires PNG and shot_id, without object_id.")}
    var shot=try StudioShotCommands.shot(in:project,id:arguments["shot_id"])
    if arguments["width"] != nil || arguments["height"] != nil {shot.pixels=try StudioPixels(width:StudioPixels.integer(arguments["width"],name:"width"),height:StudioPixels.integer(arguments["height"],name:"height"))}
    let output:URL
    if let raw=arguments["path"] as? String {guard raw.hasPrefix("/") else{throw FormError.invalid("Shot folder path must be absolute.")};output=URL(fileURLWithPath:raw,isDirectory:true)}
    else {let folder=repository.url(for:project.id).appendingPathComponent("Exports");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);output=folder.appendingPathComponent("Shot-\(shot.id.uuidString)-\(UUID().uuidString).render",isDirectory:true)}
    let image=try studioShots.export(shot,to:output)
    return ["path":image.path,"folder":output.path,"record":output.appendingPathComponent("render.json").path,"format":"png","width":shot.pixels.width,"height":shot.pixels.height,"source_archived":false]
  }
}
