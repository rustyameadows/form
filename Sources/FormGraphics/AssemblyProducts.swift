import Foundation
import FormCore

/// One bounded derived mesh cache on the native owning actor. It is never an
/// editable document source, and it does no work when the app is idle.
@MainActor public enum AssemblyProducts {
  private static var cache=PatternAssemblyCache()
  public static var builds:Int {cache.builds}
  public static var retainedVertices:Int {cache.retainedVertices}
  public static func clear() {cache.clear()}
  public static func resolve(_ definition:PatternAssemblyDefinition,in project:Project)throws -> PatternAssemblyProduct {try cache.resolve(definition,in:project)}
  public static func product(for object:ProductObject,in project:Project)throws -> PatternAssemblyProduct? {
    guard let definition=object.patternAssembly else {return nil};return try resolve(definition,in:project)
  }
  public static func study(for object:ProductObject,in project:Project)throws -> ClothStudy? {
    if let cloth=object.cloth {return cloth};return try product(for:object,in:project)?.study
  }
}
