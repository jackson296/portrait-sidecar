import Foundation

struct WorkspacePreset: Equatable {
    let title: String
    let width: Int
    let height: Int
}

enum WorkspaceOptions {
    static func presets(nativeWidth: Int, nativeHeight: Int) -> [WorkspacePreset] {
        let nativeW = min(nativeWidth,nativeHeight)
        let nativeH = max(nativeWidth,nativeHeight)
        guard nativeW > 0 else { return [] }
        return [("Larger text",0.8),("Comfortable",1.0),("More space",1.2),("Most space",1.5)].map { name, factor in
            let width = max(320,Int((Double(nativeW) * factor / 2).rounded()))
            let height = Int((Double(width) * Double(nativeH) / Double(nativeW)).rounded())
            return WorkspacePreset(title: "\(name) — \(width) × \(height)",width:width,height:height)
        }
    }
}
