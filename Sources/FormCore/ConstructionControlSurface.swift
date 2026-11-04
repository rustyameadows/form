import Foundation
import FormCADModel

/// Labels, option values and review poses travel with an authored construction.
/// Native editors interpret this data without recognizing a product family.
public struct ConstructionControlGroup:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var title:String
  public init(id:String,title:String){self.id=id;self.title=title}
}
public struct ConstructionControlChoice:Codable,Equatable,Sendable {
  public var label:String
  public var value:Double
  public init(label:String,value:Double){self.label=label;self.value=value}
}
public struct ConstructionParameterControl:Codable,Equatable,Identifiable,Sendable {
  public var parameter:String
  public var label:String
  public var group:String?
  public var help:String?
  public var choices:[ConstructionControlChoice]?
  public var step:Double?
  public var visibleWhen:CADScalar?
  public var id:String{parameter}
  public init(parameter:String,label:String,group:String?=nil,help:String?=nil,choices:[ConstructionControlChoice]?=nil,step:Double?=nil,visibleWhen:CADScalar?=nil) {
    self.parameter=parameter;self.label=label;self.group=group;self.help=help;self.choices=choices;self.step=step;self.visibleWhen=visibleWhen
  }
}
public struct ConstructionMeasurementControl:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var label:String
  public var expression:CADScalar
  public var unit:String?
  public var group:String?
  public var visibleWhen:CADScalar?
  public init(id:String,label:String,expression:CADScalar,unit:String?="mm",group:String?=nil,visibleWhen:CADScalar?=nil) {
    self.id=id;self.label=label;self.expression=expression;self.unit=unit;self.group=group;self.visibleWhen=visibleWhen
  }
}
public struct ConstructionNamedPose:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var openingPercent:Double
  public var explosionPercent:Double
  public init(id:String,name:String,openingPercent:Double=0,explosionPercent:Double=0) {
    self.id=id;self.name=name;self.openingPercent=openingPercent;self.explosionPercent=explosionPercent
  }
}
public struct ConstructionControlSurface:Codable,Equatable,Sendable {
  public var groups:[ConstructionControlGroup]
  public var parameters:[ConstructionParameterControl]
  public var measurements:[ConstructionMeasurementControl]
  public var dimensionReferenceParameter:String?
  public var poses:[ConstructionNamedPose]
  public init(groups:[ConstructionControlGroup]=[],parameters:[ConstructionParameterControl]=[],measurements:[ConstructionMeasurementControl]=[],dimensionReferenceParameter:String?=nil,poses:[ConstructionNamedPose]=[]) {
    self.groups=groups;self.parameters=parameters;self.measurements=measurements
    self.dimensionReferenceParameter=dimensionReferenceParameter;self.poses=poses
  }
  private enum CodingKeys:String,CodingKey{case groups,parameters,measurements,dimensionReferenceParameter,poses}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    groups=try c.decodeIfPresent([ConstructionControlGroup].self,forKey:.groups) ?? []
    parameters=try c.decodeIfPresent([ConstructionParameterControl].self,forKey:.parameters) ?? []
    measurements=try c.decodeIfPresent([ConstructionMeasurementControl].self,forKey:.measurements) ?? []
    dimensionReferenceParameter=try c.decodeIfPresent(String.self,forKey:.dimensionReferenceParameter)
    poses=try c.decodeIfPresent([ConstructionNamedPose].self,forKey:.poses) ?? []
  }
  public func validate(parameters declared:[CADModelParameter],derived:[String:CADScalar]?)throws {
    func text(_ value:String,_ maximum:Int=160)->Bool{!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count<=maximum}
    let parameterMap=Dictionary(declared.map{($0.name,$0)},uniquingKeysWith:{$1}),groupIDs=Set(groups.map(\.id))
    guard groups.count<=32,parameters.count<=128,measurements.count<=128,poses.count<=32,
      groupIDs.count==groups.count,Set(parameters.map(\.parameter)).count==parameters.count,
      Set(measurements.map(\.id)).count==measurements.count,Set(poses.map(\.id)).count==poses.count,
      groups.allSatisfy({text($0.id,128) && text($0.title)}) else {
      throw FormError.invalid("Construction controls require bounded unique groups, parameters, measurements and poses.")
    }
    for control in parameters {
      guard let parameter=parameterMap[control.parameter],text(control.label),
        control.group.map({groupIDs.contains($0)}) ?? true,
        control.help.map({$0.utf8.count<=2048}) ?? true,
        control.step.map({$0.isFinite && $0>0 && $0<=100000}) ?? true else {
        throw FormError.invalid("A construction control must target an existing parameter and declared group.")
      }
      if let choices=control.choices {
        guard (1...32).contains(choices.count),Set(choices.map(\.value)).count==choices.count,
          choices.allSatisfy({text($0.label) && $0.value.isFinite && $0.value>=parameter.minimum && $0.value<=parameter.maximum}),
          choices.contains(where:{abs($0.value-parameter.value)<1e-9}) else {
          throw FormError.invalid("Construction choices must be distinct in-range values and include the current parameter value.")
        }
      }
    }
    if let reference=dimensionReferenceParameter {
      guard let control=parameters.first(where:{$0.parameter==reference}),(control.choices?.count ?? 0)>=2 else {
        throw FormError.invalid("The visible dimension reference must identify a declared choice control.")
      }
    }
    let inputs=Dictionary(declared.map{($0.name,$0.value)},uniquingKeysWith:{$1}).merging(["fold":100,"opening":0,"explosion":0]){_,new in new}
    let values=try CADDerivedExpressions.resolve(derived ?? [:],variables:inputs)
    for condition in parameters.compactMap(\.visibleWhen)+measurements.compactMap(\.visibleWhen) {
      let amount=try CADExpression.evaluate(condition.expression,variables:values)
      guard condition.expression.utf8.count<=256,amount.isFinite,abs(amount)<1e-9 || abs(amount-1)<1e-9 else{throw FormError.invalid("A control visibility condition must resolve to zero or one.")}
    }
    for measurement in measurements {
      guard text(measurement.id,128),text(measurement.label),measurement.expression.expression.utf8.count<=256,
        measurement.group.map({groupIDs.contains($0)}) ?? true,(measurement.unit?.utf8.count ?? 0)<=32 else {
        throw FormError.invalid("A construction measurement needs a bounded label, expression and declared group.")
      }
      let value=try CADExpression.evaluate(measurement.expression.expression,variables:values)
      guard value.isFinite else{throw FormError.invalid("A construction measurement must resolve to a finite value.")}
    }
    for pose in poses {
      guard text(pose.id,128),text(pose.name),pose.openingPercent.isFinite,pose.explosionPercent.isFinite,
        (0...100).contains(pose.openingPercent),(0...100).contains(pose.explosionPercent) else {
        throw FormError.invalid("Construction review poses require bounded opening and explosion percentages.")
      }
    }
  }
}
