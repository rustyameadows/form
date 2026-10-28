import FormCore
import FormGraphics
import SwiftUI

struct ParagraphLanguageControls:View {
  @ObservedObject var session:ArtworkSession
  let type:Typography
  @State private var customLanguage=""
  private let languages=[("en","English"),("en-US","English (US)"),("de","German"),("fr","French"),("es","Spanish"),("tr","Turkish"),("az","Azeri"),("lt","Lithuanian"),("el","Greek"),("ar","Arabic"),("he","Hebrew"),("ja","Japanese")]
  private var effective:String? {type.language ?? session.sourceTextElement?.typography?.language ?? documentLanguage}
  private var documentLanguage:String? {session.selectedTextStory.map{$0.language ?? session.currentPublication?.language} ?? session.art.language}
  private func setDocumentLanguage(_ value:String) {
    if let story=session.selectedTextStory {
      _ = session.publicationEdit("Updated story language") {project in
        guard let i=project.textStories?.firstIndex(where:{$0.id==story.id}) else{return}
        try PublicationCommands.ensureEditable(project.textStories![i],in:project)
        project.textStories![i].language=try value.isEmpty ? nil:ParagraphLanguage.canonical(value)
        try project.validatePublications()
      }
    } else {session.execute("language",["language":value.isEmpty ? NSNull():value as Any])}
  }
  private func override(_ value:String?) {
    do {let canonical=try value.map{try ParagraphLanguage.canonical($0)};session.typography{$0.language=canonical}}
    catch {session.store?.error=error.localizedDescription}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:9) {
      Picker("Text language",selection:Binding(get:{type.language ?? ""},set:{override($0.isEmpty ? nil:$0)})) {
        Text("Inherit document").tag("")
        ForEach(languages,id:\.0) {Text($0.1).tag($0.0)}
        if let current=type.language,!languages.contains(where:{$0.0==current}) {Text(current).tag(current)}
      }.help("Language controls localized font forms, case treatment, and the explicit hyphenation dictionary. Source words stay unchanged.")
      HStack {
        TextField("Custom BCP 47 language",text:$customLanguage).textFieldStyle(.roundedBorder)
          .onSubmit {override(customLanguage.isEmpty ? nil:customLanguage)}
        Button("Set") {override(customLanguage.isEmpty ? nil:customLanguage)}.buttonStyle(.borderless)
      }
      Picker(session.selectedTextStory == nil ? "Document language":"Story language",selection:Binding(get:{documentLanguage ?? ""},set:setDocumentLanguage)) {
        Text("Automatic / system").tag("")
        ForEach(languages,id:\.0) {Text($0.1).tag($0.0)}
        if let current=documentLanguage,!languages.contains(where:{$0.0==current}) {Text(current).tag(current)}
      }.help("Default for this artwork document. Explicit character languages retain their overrides.")
      if let effective,!LanguageHyphenation.dictionaryAvailable(effective) {
        Text("No installed hyphenation dictionary for \(effective). Localized shaping/case still applies; automatic word hyphenation is disabled.")
          .foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
      Toggle("Limit hyphenation",isOn:Binding(get:{type.hyphenationLimits != nil},set:{enabled in
        session.typography{$0.hyphenationLimits=enabled ? .init():nil}
      })).toggleStyle(.checkbox)
      if let limits=type.hyphenationLimits {
        ScalarArtworkField("Minimum word",value:Double(limits.minimumWordLength),unit:"chars") {v in
          session.typography{$0.hyphenationLimits?.minimumWordLength=Int(min(100,max(2,v.rounded())))}
        }
        ScalarArtworkField("Before hyphen",value:Double(limits.minimumPrefix),unit:"chars") {v in
          session.typography{$0.hyphenationLimits?.minimumPrefix=Int(min(30,max(1,v.rounded())))}
        }
        ScalarArtworkField("After hyphen",value:Double(limits.minimumSuffix),unit:"chars") {v in
          session.typography{$0.hyphenationLimits?.minimumSuffix=Int(min(30,max(1,v.rounded())))}
        }
      }
    }.onAppear{customLanguage=type.language ?? ""}
  }
}
