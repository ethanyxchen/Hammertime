import Foundation

public struct RepositoryFile: Decodable, Sendable, Equatable {
  public let path: String
  public let type: String
  public let size: Int?

  public init(path: String, type: String = "blob", size: Int? = nil) {
    self.path = path
    self.type = type
    self.size = size
  }
}

public enum RepositoryIcon {
  private static let excluded: Set<Substring> = [
    "node_modules", "vendor", "third_party", "pods", "carthage", ".build", "dist",
    "deriveddata", "test", "tests", "fixtures", "example", "examples",
  ]
  private static let icons: Set<Substring> = ["icon.png", "icon.webp", "appicon.png"]

  public static func best(among files: [RepositoryFile]) -> RepositoryFile? {
    files.compactMap { file in
      rank(file.path).map { (rank: $0, depth: file.path.count { $0 == "/" }, file: file) }
    }
    .min { ($0.rank, $0.depth, -($0.file.size ?? 0)) < ($1.rank, $1.depth, -($1.file.size ?? 0)) }?
    .file
  }

  private static func rank(_ path: String) -> Int? {
    let components = path.lowercased().split(separator: "/")
    guard let file = components.last, !components.contains(where: excluded.contains) else {
      return nil
    }
    if file.hasSuffix(".icns") { return 0 }
    if components.dropLast().last?.hasSuffix(".appiconset") == true, file.hasSuffix(".png") {
      return 1
    }
    if icons.contains(file) { return 2 }
    if file == "apple-touch-icon.png" { return 3 }
    return nil
  }
}
