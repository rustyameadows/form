import Foundation
import simd

/// Adds a viewing caliper to an indexed center surface. Topology is taken only
/// from shared source indices: coincident garment panels are never welded.
public enum SceneSurfaceShell {
  public struct Surface:Sendable {
    public var thicknessMM:Double
    public var backMaterialIndex:Int
    public var edgeMaterialIndex:Int
    public init(thicknessMM:Double,backMaterialIndex:Int,edgeMaterialIndex:Int) {
      self.thicknessMM=thicknessMM;self.backMaterialIndex=backMaterialIndex;self.edgeMaterialIndex=edgeMaterialIndex
    }
  }
  private struct Edge {
    var a:UInt32,b:UInt32,part:Int,count:Int=1
  }
  public static func build(_ source:SceneMeshPayload,surfaces:[Int:Surface],materialCount:Int)throws->SceneMeshPayload {
    try source.validate(materialCount:materialCount)
    guard !surfaces.isEmpty else{return source}
    for (front,surface) in surfaces {
      guard front>=0,front<materialCount,surface.thicknessMM.isFinite,(0.000001...1000).contains(surface.thicknessMM),
        (0..<materialCount).contains(surface.backMaterialIndex),(0..<materialCount).contains(surface.edgeMaterialIndex) else {
        throw CyclesRenderError.invalidScene("Surface caliper and front, back and edge material slots must be valid.")
      }
    }
    let count=source.positionsMM.count
    guard count<=1_000_000 else{throw CyclesRenderError.invalidScene("The physical surface shell exceeds the two-million-vertex budget.")}
    var normals=Array(repeating:SIMD3<Double>.zero,count:count),weightedThickness=Array(repeating:0.0,count:count),weights=Array(repeating:0.0,count:count)
    var edges:[UInt64:Edge]=[:],shellTriangles=0
    for (partIndex,part) in source.parts.enumerated() {
      for start in stride(from:0,to:part.triangleIndices.count,by:3) {
        let triangle=Array(part.triangleIndices[start..<start+3]),a=Int(triangle[0]),b=Int(triangle[1]),c=Int(triangle[2])
        let normal=simd_cross(source.positionsMM[b]-source.positionsMM[a],source.positionsMM[c]-source.positionsMM[a])
        let area=simd_length(normal)
        for vertex in [a,b,c] {normals[vertex]+=normal}
        guard let surface=surfaces[part.materialIndex] else{continue}
        guard area>1e-16,Set(triangle).count==3 else{throw CyclesRenderError.invalidScene("A physical surface shell contains a degenerate triangle.")}
        shellTriangles+=1
        for vertex in [a,b,c] {weightedThickness[vertex]+=surface.thicknessMM*area;weights[vertex]+=area}
        for i in 0..<3 {
          let a=triangle[i],b=triangle[(i+1)%3],key=UInt64(min(a,b))<<32 | UInt64(max(a,b))
          if var edge=edges[key] {
            guard edge.count==1,edge.a==b,edge.b==a else {throw CyclesRenderError.invalidScene("Physical surface shells require consistently oriented manifold source edges.")}
            edge.count+=1;edges[key]=edge
          }else{edges[key] = .init(a:a,b:b,part:partIndex)}
        }
      }
    }
    guard shellTriangles>0 else{return source}
    let boundaries=edges.keys.sorted().compactMap{key->Edge? in guard let edge=edges[key],edge.count==1 else{return nil};return edge}
    let hasUnchangedParts=source.parts.contains{surfaces[$0.materialIndex]==nil}
    guard count*(hasUnchangedParts ? 3:2)+boundaries.count*4<=2_000_000,source.triangleCount+shellTriangles+boundaries.count*2<=2_000_000 else {
      throw CyclesRenderError.invalidScene("The physical surface shell exceeds the two-million-vertex/triangle budget.")
    }
    for i in normals.indices {
      let normal=source.normals.isEmpty ? normals[i]:SIMD3<Double>(source.normals[i])
      normals[i]=simd_length_squared(normal)>1e-20 ? simd_normalize(normal):.init(0,0,1)
    }
    var positions=source.positionsMM+source.positionsMM
    var outputNormals=normals.map{SIMD3<Float>($0)}+normals.map{-SIMD3<Float>($0)}
    var uvs=source.uvs+source.uvs,uvs1=source.uvs1+source.uvs1,colors=source.colors+source.colors
    var tangents=source.tangents+source.tangents.map{SIMD4<Float>($0.x,$0.y,$0.z,-$0.w)}
    for i in 0..<count where weights[i]>0 {
      let delta=normals[i]*(weightedThickness[i]/weights[i]*0.5)
      positions[i]+=delta;positions[count+i]-=delta
    }
    if hasUnchangedParts {
      positions += source.positionsMM;outputNormals += normals.map{SIMD3<Float>($0)}
      uvs += source.uvs;uvs1 += source.uvs1;colors += source.colors;tangents += source.tangents
    }
    var parts=[SceneMeshPart]()
    for part in source.parts {
      if surfaces[part.materialIndex]==nil {
        parts.append(.init(materialIndex:part.materialIndex,triangleIndices:part.triangleIndices.map{$0+UInt32(count*2)},semanticID:part.semanticID))
      }else {parts.append(part)}
      if let surface=surfaces[part.materialIndex] {
        var indices=[UInt32]();indices.reserveCapacity(part.triangleIndices.count)
        for start in stride(from:0,to:part.triangleIndices.count,by:3) {
          indices += [part.triangleIndices[start+2],part.triangleIndices[start+1],part.triangleIndices[start]].map{$0+UInt32(count)}
        }
        parts.append(.init(materialIndex:surface.backMaterialIndex,triangleIndices:indices,semanticID:part.semanticID.map{$0+":back"}))
      }
    }
    var edgeIndices:[Int:[UInt32]]=[:]
    for edge in boundaries {
      let a=Int(edge.a),b=Int(edge.b),base=UInt32(positions.count)
      let vertices=[positions[a],positions[count+a],positions[count+b],positions[b]]
      let normal=simd_normalize(simd_cross(vertices[1]-vertices[0],vertices[2]-vertices[0]))
      positions += vertices;outputNormals += Array(repeating:SIMD3<Float>(normal),count:4)
      let length=Float(simd_distance(source.positionsMM[a],source.positionsMM[b]))
      let thicknessA=Float(weightedThickness[a]/weights[a]),thicknessB=Float(weightedThickness[b]/weights[b])
      let edgeUV:[SIMD2<Float>]=[.init(0,0),.init(0,thicknessA),.init(length,thicknessB),.init(length,0)]
      if !source.uvs.isEmpty {uvs += edgeUV};if !source.uvs1.isEmpty {uvs1 += edgeUV}
      if !source.colors.isEmpty {colors += [source.colors[a],source.colors[a],source.colors[b],source.colors[b]]}
      if !source.tangents.isEmpty {let tangent=SIMD3<Float>(simd_normalize(vertices[3]-vertices[0]));tangents += Array(repeating:.init(tangent.x,tangent.y,tangent.z,1),count:4)}
      let slot=surfaces[source.parts[edge.part].materialIndex]!.edgeMaterialIndex
      edgeIndices[slot,default:[]] += [base,base+1,base+2,base,base+2,base+3]
    }
    for slot in edgeIndices.keys.sorted() {parts.append(.init(materialIndex:slot,triangleIndices:edgeIndices[slot]!,semanticID:"physical-cut-edge"))}
    let signature=surfaces.keys.sorted().map{key in let value=surfaces[key]!;return "\(key):\(value.thicknessMM):\(value.backMaterialIndex):\(value.edgeMaterialIndex)"}.joined(separator:";")
    let output=SceneMeshPayload(id:source.id+":physical-shell",revision:source.revision+":"+signature,positionsMM:positions,normals:outputNormals,uvs:uvs,uvs1:uvs1,tangents:tangents,colors:colors,parts:parts)
    try output.validate(materialCount:materialCount)
    return output
  }
}
