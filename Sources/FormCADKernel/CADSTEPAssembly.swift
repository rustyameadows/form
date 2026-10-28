import Foundation

public struct CADSTEPFaceColor:Codable,Equatable,Sendable {
  public var faceIndex:UInt32,rgba:[Double]
  public init(faceIndex:UInt32,rgba:[Double]){self.faceIndex=faceIndex;self.rgba=rgba}
}
/// Paths are occurrence paths within a specific source SHA-256/kernel version.
public struct CADSTEPOccurrence:Codable,Equatable,Sendable {
  public var path:String,definitionKey:String,name:String,parentIndex:Int?
  public var assembly:Bool
  public var localTransformMM:[Double],worldTransformMM:[Double]
  public var linearRGBA:[Double]?,faceColors:[CADSTEPFaceColor]
  public init(path:String,definitionKey:String,name:String,parentIndex:Int?,assembly:Bool,localTransformMM:[Double],worldTransformMM:[Double],linearRGBA:[Double]?,faceColors:[CADSTEPFaceColor]){self.path=path;self.definitionKey=definitionKey;self.name=name;self.parentIndex=parentIndex;self.assembly=assembly;self.localTransformMM=localTransformMM;self.worldTransformMM=worldTransformMM;self.linearRGBA=linearRGBA;self.faceColors=faceColors}
}
public struct CADSTEPAssembly:Sendable {
  public var sourceSHA256:String,kernelVersion:String,nodes:[CADSTEPOccurrence],parts:[String:CADShape]
  public var estimatedBytes:Int{parts.values.reduce(0){$0+$1.info.faces*2048+$1.info.edges*256+$1.info.vertices*128}+nodes.reduce(0){$0+2048+$1.faceColors.count*40}}
}
