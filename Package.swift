// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Hammertime",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "Hammertime", targets: ["GitHubMaxxer"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
  ],
  targets: [
    .target(name: "GitHubMaxxerCore"),
    .executableTarget(
      name: "GitHubMaxxer",
      dependencies: ["GitHubMaxxerCore", .product(name: "Sparkle", package: "Sparkle")],
      exclude: ["Resources"]),
    .testTarget(name: "GitHubMaxxerTests", dependencies: ["GitHubMaxxerCore", "GitHubMaxxer"]),
  ]
)
