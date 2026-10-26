import Foundation

public enum ArtworkTransferCommands {
  public static let exportName="transfer_export",importName="transfer_import"
  public static var names:[String] {[exportName,importName]}
  public static func recognizes(_ name:String,_ args:[String:Any])->Bool {name=="form_edit_artwork" && names.contains(args["command"] as? String ?? "")}
  public static func rejectsBatch(_ name:String,_ args:[String:Any])->Bool {
    guard name=="form_batch" else{return false}
    var pending=[(args,0)],work=0
    while let (batch,depth)=pending.popLast() {
      guard depth<=16,let operations=batch["operations"] as? [[String:Any]],operations.count<=100 else{return true}
      for op in operations {work+=1;guard work<=1000 else{return true};let n=op["name"] as? String ?? "",a=op["arguments"] as? [String:Any] ?? [:];if recognizes(n,a){return true};if n=="form_batch"{pending.append((a,depth+1))}}
    }
    return false
  }
}
