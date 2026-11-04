import AppKit
import FormCore
import FormGeometry
import LabRendering
import simd

/// Transient sheet state makes an editable/preset round trip reversible without
/// adding provenance fields to the saved render-settings schema.
@MainActor struct CyclesLightingConversionDraft {
  private var originalAmbient:(color:String,strength:Double)?
  mutating func makeEditable(_ settings:CyclesRenderSettings,using preset:CyclesLightingPreset,addingLight:Bool=false)throws->CyclesRenderSettings {
    let converted=try preset.makeEditable(settings,addingLight:addingLight)
    if settings.areaLights==nil {originalAmbient=(settings.environmentColor,settings.environmentStrength)}
    return converted
  }
  mutating func usePreset(_ settings:CyclesRenderSettings)->CyclesRenderSettings {
    var copy=settings;copy.areaLights=nil
    if let originalAmbient {copy.environmentColor=originalAmbient.color;copy.environmentStrength=originalAmbient.strength}
    originalAmbient=nil
    return copy
  }
}

/// The current scene's physical interpretation of its legacy lighting preset.
/// Both rendering and native preset conversion use this frozen value.
@MainActor struct CyclesLightingPreset {
  var lights:[SceneAreaLight]
  var ambientColor:SIMD3<Float>
  var ambientStrength:Double

  func resolve(_ settings:CyclesRenderSettings)->(lights:[SceneAreaLight],environment:SceneRenderEnvironment) {
    var environment=SceneRenderEnvironment(color:LabCyclesRuntime.color(settings.environmentColor),
      strength:settings.environmentStrength,rotationDegrees:settings.environmentRotationDegrees)
    if let authored=settings.areaLights {return(authored.map(Self.light),environment)}
    environment.color *= ambientColor;environment.strength *= ambientStrength
    return(lights,environment)
  }

  /// Freeze the current lights and ambient response into ordinary authored
  /// settings. Colors round to the nearest existing 8-bit sRGB authoring value;
  /// strength, power and emitter sizes are not clamped or recalibrated.
  func makeEditable(_ settings:CyclesRenderSettings,addingLight:Bool=false)throws->CyclesRenderSettings {
    try settings.validate()
    if settings.areaLights != nil {
      var copy=settings
      if addingLight {copy.areaLights?.append(.init())}
      try copy.validate();return copy
    }
    let resolved=resolve(settings)
    var copy=settings
    copy.areaLights=try resolved.lights.map { light in
      var value=PhysicalAreaLight()
      let p=light.transform.columns.3,z=light.transform.columns.2
      value.positionMM = .init(p.x,p.y,p.z)
      value.targetMM = .init(p.x-z.x*100,p.y-z.y*100,p.z-z.z*100)
      value.sizeMM = .init(light.sizeMM.x,light.sizeMM.y)
      value.powerWatts=light.power;value.color=try Self.hex(light.color)
      value.shape=light.shape == .disk ? .disk:.rectangle
      // Target controls cannot express emitter roll or scale. Reject such a
      // future preset rather than silently changing its physical emitter.
      let reconstructed=Self.light(value).transform
      for column in 0..<3 where simd_length(reconstructed[column]-light.transform[column])>1e-8 {
        throw FormError.invalid("This scene light has an orientation or scale that editable target controls cannot preserve.")
      }
      return value
    }
    copy.environmentColor=try Self.hex(resolved.environment.color)
    copy.environmentStrength=resolved.environment.strength
    if addingLight {copy.areaLights?.append(.init())}
    guard copy.environmentStrength.isFinite,(0...1000).contains(copy.environmentStrength) else {
      throw FormError.invalid("The current preset exceeds the editable environment strength range (0–1000). Lower environment strength before making its lights editable.")
    }
    do {try copy.validate()}catch {throw FormError.invalid("Cannot make the current lighting editable: \(error.localizedDescription)")}
    return copy
  }

  static func light(_ value:PhysicalAreaLight)->SceneAreaLight {
    let position=SIMD3(value.positionMM.x,value.positionMM.y,value.positionMM.z)
    let target=SIMD3(value.targetMM.x,value.targetMM.y,value.targetMM.z)
    let direction=simd_normalize(position-target),up:SIMD3<Double>=abs(direction.y)>0.999 ? .init(0,0,1):.init(0,1,0)
    return .init(shape:value.shape == .disk ? .disk:.rectangle,
      transform:SceneCameraPayload.looking(from:position,at:target,up:up).worldFromCameraMM,
      color:LabCyclesRuntime.color(value.color),power:value.powerWatts,sizeMM:.init(value.sizeMM.x,value.sizeMM.y))
  }
  private static func hex(_ linear:SIMD3<Float>)throws->String {
    var bytes=[Int]()
    for value in [linear.x,linear.y,linear.z] {
      guard value.isFinite,(0...1).contains(value) else {throw FormError.invalid("The current light color is outside the editable sRGB range.")}
      let v=Double(value),encoded=v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055
      bytes.append(Int((encoded*255).rounded()))
    }
    return String(format:"#%02X%02X%02X",bytes[0],bytes[1],bytes[2])
  }
}

extension TableSceneController {
  func cyclesLightingPreset()->CyclesLightingPreset {
    var lights=[SceneAreaLight]()
    if !keyLight.isHidden,let source=keyLight.light {
      var transform=keyLight.worldTransform.raw
      transform.columns.3.x*=100;transform.columns.3.y*=100;transform.columns.3.z*=100
      let color=GeometryPayloadAdapter.color(source.color)
      lights.append(.init(transform:transform,color:LabCyclesRuntime.linear(.init(color.x,color.y,color.z)),
        power:max(0,source.intensity)*8.25/850,sizeMM:.init(500,500)))
    }
    if let fill=scene.rootNode.childNodes.first(where:{$0.light?.type == .omni}),!fill.isHidden,let source=fill.light {
      let p=fill.worldTransform.raw.columns.3,color=GeometryPayloadAdapter.color(source.color)
      let position=SIMD3(p.x*100,p.y*100,p.z*100),direction=simd_normalize(position)
      let up:SIMD3<Double>=abs(direction.y)>0.999 ? .init(0,0,1):.init(0,1,0)
      lights.append(.init(transform:SceneCameraPayload.looking(from:position,at:.zero,up:up).worldFromCameraMM,
        color:LabCyclesRuntime.linear(.init(color.x,color.y,color.z)),power:max(0,source.intensity)*2.75/100,sizeMM:.init(700,700)))
    }
    var ambientColor=SIMD3<Float>(repeating:1),ambientStrength=1.0
    if let ambient=scene.rootNode.childNodes.first(where:{$0.light?.type == .ambient}),let source=ambient.light {
      let color=GeometryPayloadAdapter.color(source.color)
      ambientColor=LabCyclesRuntime.linear(.init(color.x,color.y,color.z))
      ambientStrength=ambient.isHidden ? 0:max(0,source.intensity)/400
    }
    return .init(lights:lights,ambientColor:ambientColor,ambientStrength:ambientStrength)
  }
}
