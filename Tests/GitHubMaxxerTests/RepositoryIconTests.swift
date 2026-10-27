import Testing

@testable import GitHubMaxxerCore

struct RepositoryIconTests {
  @Test func prefersTheDesktopIconSet() {
    let files = [
      "fastlane/metadata/android/en-US/images/icon.png",
      "packages/app/assets/images/icon.png",
      "packages/app/public/apple-touch-icon.png",
      "packages/desktop/assets/icon-dev.png",
      "packages/desktop/assets/icon.icns",
      "packages/desktop/assets/icon.png",
    ].map { RepositoryFile(path: $0) }
    #expect(RepositoryIcon.best(among: files)?.path == "packages/desktop/assets/icon.icns")
  }

  @Test func fallsBackToTheShallowestIconImage() {
    let files = [
      "apps/marketing/public/apple-touch-icon.png",
      "apps/marketing/src/assets/icon-nightly.webp",
      "apps/marketing/src/assets/icon.webp",
      "apps/web/public/apple-touch-icon.png",
    ].map { RepositoryFile(path: $0) }
    #expect(RepositoryIcon.best(among: files)?.path == "apps/marketing/src/assets/icon.webp")
  }

  @Test func picksTheLargestImageOfAnXcodeIconSet() {
    let files = [
      RepositoryFile(path: "App/Assets.xcassets/AppIcon.appiconset/icon_16x16.png", size: 600),
      RepositoryFile(
        path: "App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png", size: 90_000),
      RepositoryFile(path: "App/Assets.xcassets/AppIcon.appiconset/Contents.json", size: 900_000),
    ]
    #expect(
      RepositoryIcon.best(among: files)?.path
        == "App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
  }

  @Test func ignoresIconsOfDependenciesAndExamples() {
    let files = [
      "node_modules/electron/dist/Electron.app/Contents/Resources/electron.icns",
      "packages/audio/examples/basic-usage/assets/icon.png",
      "Tests/Fixtures/Sample.icns",
      "Pods/SomeSDK/Resources/sdk.icns",
      "dist/Martin.app/Contents/Resources/AppIcon.icns",
    ].map { RepositoryFile(path: $0) }
    #expect(RepositoryIcon.best(among: files) == nil)
  }

  @Test func prefersTheElectronIconInItsBuildResources() {
    let files = [
      "apps/desktop/build/icon.icns",
      "apps/installer/src-tauri/icons/icon.icns",
      "apps/installer/src-tauri/icons/icon.png",
    ].map { RepositoryFile(path: $0) }
    #expect(RepositoryIcon.best(among: files)?.path == "apps/desktop/build/icon.icns")
  }
}
