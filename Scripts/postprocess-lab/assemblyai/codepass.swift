import Foundation
// Applies the code passes after the model (A2's clean() tail) to texts from stdin.
struct Item: Codable { let text: String; let styles: [String] }
let items = try! JSONDecoder().decode([Item].self, from: FileHandle.standardInput.readDataToEndOfFile())
let out = items.map { item -> String in
    let styles = Set(item.styles.compactMap(WritingStyle.init(rawValue:)))
    var t = LocalCleanup.run(item.text)
    t = WritingStyle.apply(styles, to: t)
    t = Digits.unitFigures(t)
    t = ModelText.currencySymbols(t)
    return ModelText.stripTrailingFullStop(t)
}
print(String(data: try! JSONEncoder().encode(out), encoding: .utf8)!)
