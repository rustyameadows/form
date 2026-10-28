import Foundation

/// Product identity is separate from durable compatibility identifiers. Renaming
/// the application must not fork a user's library, defaults, Keychain or clients.
public enum LabIdentity {
  public static let name = "LAB"
  public static let version = "0.5.1"
  public static let bundleIdentifier = "studio.form.mac"
  public static let projectTypeIdentifier = "studio.form.project"
  public static let projectExtension = "form"
  public static let libraryDirectory = "FORM"
  public static func environmentOverride(_ primary:String,legacy:String,environment:[String:String])->String? {
    for key in [primary,legacy] {if let value=environment[key],!value.isEmpty {return value}}
    return nil
  }
  public static func libraryOverride(_ environment:[String:String]=ProcessInfo.processInfo.environment)->String? {
    environmentOverride("LAB_LIBRARY_PATH",legacy:"FORM_LIBRARY_PATH",environment:environment)
  }
  public static func socketOverride(_ environment:[String:String]=ProcessInfo.processInfo.environment)->String? {
    environmentOverride("LAB_SOCKET_PATH",legacy:"FORM_SOCKET_PATH",environment:environment)
  }
}
