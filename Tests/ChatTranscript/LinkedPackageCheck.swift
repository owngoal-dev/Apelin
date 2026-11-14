import Foundation

/// Model Providers names the kwwk this build links, read from the list the
/// Collect Licenses build phase writes (`LinkedPackage`): a version the
/// checkout stated, never the revision a pin carries instead.
func checkLinkedPackage() {
    let list = Data(#"""
    [
      {"id": "app/Apelin", "name": "Apelin", "license": "MIT", "url": "", "text": "", "version": "0.4.7"},
      {"id": "kwwk/LICENSE", "name": "kwwk", "license": "MIT", "url": "", "text": "", "version": "0.1.121"},
      {"id": "kwwk/Sources/x/LICENSE", "name": "kwwk / Sources/x", "license": "MIT", "url": "", "text": ""},
      {"id": "dog/LICENSE", "name": "Dog", "license": "MIT", "url": "", "text": "",
       "version": "997b8c58047c9bda25f95dce55390d5439bb02bd"},
      {"id": "then/LICENSE", "name": "Then", "license": "MIT", "url": "", "text": ""}
    ]
    """#.utf8)
    precondition(LinkedPackage.version(of: "kwwk", in: list) == "0.1.121")
    precondition(LinkedPackage.version(of: "Apelin", in: list) == "0.4.7")
    precondition(LinkedPackage.version(of: "Dog", in: list) == nil, "a revision is no version to show")
    precondition(LinkedPackage.version(of: "Then", in: list) == nil, "none stated")
    precondition(LinkedPackage.version(of: "Missing", in: list) == nil)
    precondition(LinkedPackage.version(of: "kwwk", in: Data("not json".utf8)) == nil)
    print("ok: a linked package's version is the one its checkout stated, and a revision is none")
}
