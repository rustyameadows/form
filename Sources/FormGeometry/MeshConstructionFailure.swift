import Foundation

/// A construction failure belongs to the CPU graph, independently of display
/// names. Cloning or assigning a viewport object name must preserve it.
public struct MeshConstructionFailure:Error,LocalizedError,Equatable,Sendable {
  public var objectID:UUID
  public var message:String
  public init(objectID:UUID,message:String){self.objectID=objectID;self.message=message}
  public var errorDescription:String?{message}
}
