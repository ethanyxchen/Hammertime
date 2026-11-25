import Foundation
import Testing

@testable import GitHubMaxxer

struct GitHubCLITests {
  @Test func findsGitHubCLIOnTheLoginShellPath() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gh = directory.appending(path: "gh")
    let shell = directory.appending(path: "shell")
    try "#!/bin/sh\n".write(to: gh, atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho 'Welcome back'\necho '\(gh.path)'\n"
      .write(to: shell, atomically: true, encoding: .utf8)
    for file in [gh, shell] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    #expect(await GitHubCLI.executable(shell: shell.path) == gh)
  }

  @Test func signsInThroughGitHubCLIAndShowsTheOneTimeCode() async throws {
    let gh = try script(
      """
      if [ "$1 $2" = "auth refresh" ]; then
        printf '! One-time code (0D78-B0CF) copied to clipboard\\n' >&2
        sleep 0.2
        printf 'Authentication complete.\\n' >&2
        sleep 0.2
        exit 0
      fi
      echo fresh-credential
      """)
    defer { try? FileManager.default.removeItem(at: gh.deletingLastPathComponent()) }
    let codes = LockedValues<String>()
    let token = try await GitHubCLI.signIn(with: gh) { codes.append($0) }
    #expect(token == "fresh-credential")
    #expect(codes.values == ["0D78-B0CF"])
  }

  @Test func reportsWhyGitHubCLICouldNotSignIn() async throws {
    let gh = try script(
      """
      printf "failed to authenticate via web browser: This 'device_code' has expired.\\n" >&2
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: gh.deletingLastPathComponent()) }
    await #expect {
      try await GitHubCLI.signIn(with: gh) { _ in }
    } throws: { error in
      error.localizedDescription.contains("device_code' has expired")
    }
  }

  private func script(_ body: String) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let gh = directory.appending(path: "gh")
    try "#!/bin/sh\n\(body)\n".write(to: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    return gh
  }
}
