import Foundation

public struct CADImportedFaceColor:Codable,Equatable,Sendable {
  public var faceIndex:UInt32,linearRGBA:[Double]
  public init(faceIndex:UInt32,linearRGBA:[Double]){self.faceIndex=faceIndex;self.linearRGBA=linearRGBA}
}
public struct CADImportedAssemblyNode:Codable,Equatable,Sendable {
  public var path:String,parentPath:String?,definitionKey:String,name:String,assembly:Bool
  public var localTransformMM:[Double],worldTransformMM:[Double],linearRGBA:[Double]?,faceColors:[CADImportedFaceColor]
  public var outputFeatureID:UUID?,outputFingerprint:String?
  public init(path:String,parentPath:String?,definitionKey:String,name:String,assembly:Bool,localTransformMM:[Double],worldTransformMM:[Double],linearRGBA:[Double]?=nil,faceColors:[CADImportedFaceColor]=[],outputFeatureID:UUID?=nil,outputFingerprint:String?=nil){self.path=path;self.parentPath=parentPath;self.definitionKey=definitionKey;self.name=name;self.assembly=assembly;self.localTransformMM=localTransformMM;self.worldTransformMM=worldTransformMM;self.linearRGBA=linearRGBA;self.faceColors=faceColors;self.outputFeatureID=outputFeatureID;self.outputFingerprint=outputFingerprint}
}
public struct CADImportedAssembly:Codable,Equatable,Sendable {
  public var source:CADSourceReference,kernelVersion:String,sourceUpAxis:String,nodes:[CADImportedAssemblyNode]
  public init(source:CADSourceReference,kernelVersion:String,sourceUpAxis:String,nodes:[CADImportedAssemblyNode]){self.source=source;self.kernelVersion=kernelVersion;self.sourceUpAxis=sourceUpAxis;self.nodes=nodes}
}
extension CADModelDefinition {
  public func validateImportedAssemblies()throws {
    guard let assemblies=importedAssemblies else{return}
    guard assemblies.count<=32 else{throw CADModelError("Imported assembly metadata exceeds 32 source documents.")}
    var colorCount=0,allOutputs=Set<UUID>()
    func hash(_ v:String)->Bool{v.count==64&&v.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    func rgba(_ v:[Double])->Bool{v.count==4&&v.allSatisfy{$0.isFinite&&$0>=0&&$0<=1}}
    func matrix(_ v:[Double])->Bool{v.count==16&&v.allSatisfy{$0.isFinite&&abs($0)<=1e7}&&abs(v[12])+abs(v[13])+abs(v[14])+abs(v[15]-1)<1e-12}
    for assembly in assemblies {
      guard assembly.source.partPath==nil,hash(assembly.source.sha256),!assembly.source.path.isEmpty,!assembly.source.path.hasPrefix("/"),!assembly.source.path.contains("\\"),!assembly.source.path.split(separator:"/").contains(".."),assembly.source.path.utf8.count<=512,["y","z"].contains(assembly.sourceUpAxis),assembly.kernelVersion.utf8.count<=64,!assembly.nodes.isEmpty,assembly.nodes.count<=4096 else{throw CADModelError("Imported STEP assembly metadata has invalid provenance or bounded size.")}
      var seen=Set<String>()
      for node in assembly.nodes {
        guard !node.path.isEmpty,!node.path.hasPrefix("/"),!node.path.hasSuffix("/"),!node.path.contains("//"),node.path.utf8.count<=511,node.path.split(separator:"/").count<=65,node.path.utf8.allSatisfy({(48...57).contains($0)||$0==47}),seen.insert(node.path).inserted,node.name.utf8.count<=1023,node.definitionKey.utf8.count<=255,matrix(node.localTransformMM),matrix(node.worldTransformMM) else{throw CADModelError("Imported STEP occurrence has invalid identity, transform or hierarchy size.")}
        if let parent=node.parentPath{guard seen.contains(parent),node.path.hasPrefix(parent+"/") else{throw CADModelError("STEP occurrence parents must precede their children in the source tree.")}}
        if let color=node.linearRGBA{guard rgba(color) else{throw CADModelError("STEP colors require bounded linear-sRGB RGBA values.")}}
        colorCount+=node.faceColors.count
        guard colorCount<=100000,Set(node.faceColors.map(\.faceIndex)).count==node.faceColors.count,node.faceColors.allSatisfy({$0.faceIndex>0&&rgba($0.linearRGBA)}) else{throw CADModelError("STEP face colors exceed bounded unique revision-scoped face indices.")}
        if let fingerprint=node.outputFingerprint{guard hash(fingerprint) else{throw CADModelError("STEP appearance requires an exact output feature fingerprint.")}}
        if let output=node.outputFeatureID{guard !node.assembly,allOutputs.insert(output).inserted,features.contains(where:{$0.id==output}) else{throw CADModelError("STEP occurrence output does not reference a unique model feature.")}}
        if node.assembly{guard node.faceColors.isEmpty,node.outputFeatureID==nil else{throw CADModelError("STEP assembly containers cannot masquerade as leaf output geometry.")}}
      }
    }
  }
}
