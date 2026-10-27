import Foundation

public enum MeshAssetImporter {
  public static func importFile(_ url:URL,options:MeshImportOptions = .init())throws->MeshAssetDocument {
    switch url.pathExtension.lowercased() {
    case "glb","gltf":return try GLTFImporter.importFile(url,options:options)
    case "stl":return try STLImporter.importFile(url,options:options)
    default:throw MeshAssetError.unsupported("Choose GLB/glTF or STL. OBJ and USD/USDZ are not admitted by this bounded importer yet.")
    }
  }
}

public enum STLImporter {
  public static func importFile(_ url:URL,options:MeshImportOptions = .init())throws->MeshAssetDocument {
    let meta=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
    guard meta.isRegularFile==true,let n=meta.fileSize,n>0,n<=options.limits.sourceBytes else{throw MeshAssetError.limit("STL needs a regular file within the source byte budget.")}
    return try importData(Data(contentsOf:url),fileName:url.lastPathComponent,options:options)
  }
  public static func importData(_ data:Data,fileName:String="Imported.stl",options:MeshImportOptions = .init())throws->MeshAssetDocument {
    guard let unit=options.sourceUnit else{throw MeshAssetError.unitRequired("STL has no reliable unit declaration. Select millimeters, centimeters, meters or inches.")}
    guard data.count>0,data.count<=options.limits.sourceBytes else{throw MeshAssetError.limit("STL exceeds the source byte budget.")}
    var positions:[MeshPoint3]=[],normals:[MeshVector3]=[],indices:[UInt32]=[],warnings:[String]=[]
    func append(_ points:[MeshPoint3],normal:MeshVector3)throws {
      guard positions.count<=options.limits.vertices-3,indices.count/3<options.limits.triangles else{throw MeshAssetError.limit("STL exceeds the triangle/vertex budget.")}
      let points=points.map{MeshPoint3($0.x*unit.millimeters,$0.y*unit.millimeters,$0.z*unit.millimeters)}
      guard points.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy{$0.isFinite && abs($0)<=options.limits.coordinateMM}}) else{throw MeshAssetError.invalid("STL contains non-finite or excessive coordinates.")}
      let generated=MeshAssetGeometry.vertexNormals(points:points,indices:[0,1,2]),length=sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
      let n=length.isFinite && length>1e-20 ? MeshVector3(normal.x/length,normal.y/length,normal.z/length):generated[0]
      let start=UInt32(positions.count);positions+=points;normals += [n,n,n];indices += [start,start+1,start+2]
    }
    var binary=false
    if data.count>=84 {
      let count=data.withUnsafeBytes{Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:80,as:UInt32.self)))}
      if count>0,count<=(Int.max-84)/50,84+count*50==data.count {
        binary=true
        guard count<=options.limits.triangles,count<=options.limits.vertices/3 else{throw MeshAssetError.limit("Binary STL exceeds the triangle/vertex budget.")}
        positions.reserveCapacity(count*3);normals.reserveCapacity(count*3);indices.reserveCapacity(count*3)
        try data.withUnsafeBytes {raw in
          for i in 0..<count {
            if i%8192==0,Task.isCancelled {throw CancellationError()}
            let offset=84+i*50
            func value(_ j:Int)throws->Double {let n=Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:offset+j*4,as:UInt32.self))));guard n.isFinite else{throw MeshAssetError.invalid("Binary STL contains a non-finite float.")};return n}
            let n=try MeshVector3(Float(value(0)),Float(value(1)),Float(value(2)))
            let points=try (0..<3).map {j in MeshPoint3(try value(3+j*3),try value(4+j*3),try value(5+j*3))}
            try append(points,normal:n)
            if raw.loadUnaligned(fromByteOffset:offset+48,as:UInt16.self) != 0 {warnings=["Nonstandard STL facet attributes/colors remain in original source; no color convention is assumed."]}
          }
        }
      }
    }
    if !binary {
      guard data.count<=32*1024*1024,let string=String(data:data,encoding:.utf8),string.hasPrefix("solid") else{throw MeshAssetError.invalid("STL is neither an exact-length binary triangle file nor supported ASCII STL.")}
      var state=0,normal=MeshVector3(),points:[MeshPoint3]=[],error:Error?,seenEnd=false,lines=0
      string.enumerateLines {line,stop in
        do {
          lines+=1;if lines%8192==0,Task.isCancelled {throw CancellationError()}
          guard line.utf8.count<=4096 else{throw MeshAssetError.limit("ASCII STL line exceeds 4096 bytes.")}
          let tokens=line.split(whereSeparator:{$0.isWhitespace});if tokens.isEmpty{return}
          func number(_ i:Int)throws->Double {guard i<tokens.count,let n=Double(tokens[i]),n.isFinite else{throw MeshAssetError.invalid("ASCII STL requires finite numeric coordinates.")};return n}
          switch state {
          case 0:guard tokens[0]=="solid" else{throw MeshAssetError.invalid("ASCII STL requires a solid header.")};state=1
          case 1:
            if tokens[0]=="endsolid" {seenEnd=true;state=8}
            else {guard tokens.count==5,tokens[0]=="facet",tokens[1]=="normal" else{throw MeshAssetError.invalid("Expected an ASCII STL facet normal.")};normal=try .init(Float(number(2)),Float(number(3)),Float(number(4)));points=[];state=2}
          case 2:guard tokens.count==2,tokens[0]=="outer",tokens[1]=="loop" else{throw MeshAssetError.invalid("Expected STL outer loop.")};state=3
          case 3,4,5:guard tokens.count==4,tokens[0]=="vertex" else{throw MeshAssetError.invalid("Each STL facet needs exactly three vertices.")};points.append(try .init(number(1),number(2),number(3)));state+=1
          case 6:guard tokens.count==1,tokens[0]=="endloop" else{throw MeshAssetError.invalid("Expected STL endloop.")};state=7
          case 7:guard tokens.count==1,tokens[0]=="endfacet" else{throw MeshAssetError.invalid("Expected STL endfacet.")};try append(points,normal:normal);state=1
          default:throw MeshAssetError.invalid("ASCII STL contains data after endsolid.")
          }
        }catch let caught {error=caught;stop=true}
      }
      if let error {throw error}
      guard seenEnd,state==8,!positions.isEmpty else{throw MeshAssetError.invalid("ASCII STL is incomplete or empty.")}
      warnings.append("ASCII STL is admitted up to 32 MiB; binary STL is preferable for larger meshes.")
    }
    guard !positions.isEmpty else{throw MeshAssetError.invalid("STL has no facets.")}
    var lo=positions[0],hi=positions[0]
    for p in positions {lo.x=min(lo.x,p.x);lo.y=min(lo.y,p.y);lo.z=min(lo.z,p.z);hi.x=max(hi.x,p.x);hi.y=max(hi.y,p.y);hi.z=max(hi.z,p.z)}
    warnings.append("STL carries no UVs, material hierarchy or reliable up-axis. Coordinates are retained as selected; inspect orientation before fabrication.")
    var provenance=MeshAssetProvenance(format:binary ? "stl-binary":"stl-ascii",fileName:fileName,sourceSHA256:MeshAssetHash.sha256(data),sourceByteCount:data.count,unit:unit,unitDeclaration:"Explicit user choice for a unitless STL",warnings:warnings)
    provenance.coordinateConvention="Source XYZ retained without axis rotation; assumed +Y up is unverified. Document coordinates use millimeters."
    let primitive=MeshAssetPrimitive(id:"mesh-0-primitive-0",positionsMM:positions,normals:normals,indices:indices,materialIndex:0)
    return .init(provenance:provenance,sourceData:data,meshes:[.init(id:"mesh-0",name:fileName,primitives:[primitive])],nodes:[.init(id:"node-0",name:fileName,meshIndex:0,children:[],localTransform:.identity,worldTransform:.identity,inSelectedScene:true)],sceneRoots:[0],materials:[.init(id:"material-default",name:"Neutral STL display material",baseColor:[0.8,0.8,0.8,1],metallic:0,roughness:0.8)],boundsMM:.init(minimum:lo,maximum:hi))
  }
}
