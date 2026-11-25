import Foundation
import Security
import os

@MainActor
protocol CredentialStorage {
  func save(_ token: String, for id: UUID) throws
  func read(for id: UUID) throws -> String
  func delete(for id: UUID) throws
}

@MainActor
struct CredentialStore: CredentialStorage {
  private let service = Bundle.main.bundleIdentifier ?? ""

  func save(_ token: String, for id: UUID) throws {
    let attributes: [CFString: Any] = [
      kSecValueData: Data(token.utf8), kSecAttrLabel: "Hammertime",
    ]
    let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
    guard status == errSecItemNotFound else { return try check(status) }
    try check(SecItemAdd(query(id).merging(attributes) { _, value in value } as CFDictionary, nil))
  }

  func read(for id: UUID) throws -> String {
    var item = query(id)
    item[kSecReturnData] = true
    item[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    try check(SecItemCopyMatching(item as CFDictionary, &result))
    guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
      throw CredentialError.invalidData
    }
    return token
  }

  func delete(for id: UUID) throws {
    let status = SecItemDelete(query(id) as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }

  private func query(_ id: UUID) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw CredentialError.keychain(status) }
  }
}

enum CredentialError: LocalizedError {
  case keychain(OSStatus)
  case invalidData, cliUnavailable, cliNotAuthenticated
  case signInFailed(String)

  var errorDescription: String? {
    switch self {
    case .keychain(errSecInteractionNotAllowed), .keychain(errSecAuthFailed):
      "Keychain access was denied. Click Refresh and allow Hammertime to use this connection."
    case .keychain(let status):
      "Keychain could not access this connection (\(status)). Unlock your Mac or reconnect the account."
    case .invalidData: "This connection's saved sign-in could not be read."
    case .cliUnavailable:
      "GitHub CLI was not found. Install it with brew install gh, then run gh auth login."
    case .cliNotAuthenticated:
      "GitHub CLI is not signed in to github.com. Run gh auth login, then try again."
    case .signInFailed(let reason): "GitHub CLI could not sign in. \(reason)"
    }
  }
}

enum GitHubCLI {
  static func executable(
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  ) async -> URL? {
    await Task.detached {
      let onShellPath = try? run(URL(filePath: shell), ["-ilc", "command -v gh"]).output
        .split(whereSeparator: \.isNewline).last.map(String.init)
      let candidates =
        [onShellPath].compactMap(\.self) + [
          "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
        ]
      return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(filePath: $0) }
    }.value
  }

  static let deviceURL = URL(string: "https://github.com/login/device")!

  static func token() async throws -> String {
    guard let executable = await executable() else { throw CredentialError.cliUnavailable }
    return try await token(from: executable)
  }

  static func signIn(showing code: @escaping @MainActor (String) -> Void) async throws -> String {
    guard let executable = await executable() else { throw CredentialError.cliUnavailable }
    return try await signIn(with: executable, showing: code)
  }

  static func signIn(with executable: URL, showing code: @escaping @MainActor (String) -> Void)
    async throws -> String
  {
    let process = Process()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = ["auth", "refresh", "--hostname", "github.com", "--scopes", "gist"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    let log = OSAllocatedUnfairLock(initialState: "")
    errors.fileHandleForReading.readabilityHandler = { handle in
      let chunk = String(decoding: handle.availableData, as: UTF8.self)
      let (before, text) = log.withLock {
        let before = $0
        $0 += chunk
        return (before, $0)
      }
      guard before.firstMatch(of: /[A-Z0-9]{4}-[A-Z0-9]{4}/) == nil,
        let match = text.firstMatch(of: /[A-Z0-9]{4}-[A-Z0-9]{4}/)
      else { return }
      let shown = String(match.output)
      Task { @MainActor in code(shown) }
    }
    defer { errors.fileHandleForReading.readabilityHandler = nil }
    let status = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
      }
    } onCancel: {
      if process.isRunning { process.terminate() }
    }
    try Task.checkCancellation()
    guard status == 0 else {
      let reason = log.withLock { $0 }.split(whereSeparator: \.isNewline).last
      throw CredentialError.signInFailed(reason.map(String.init) ?? "Try again.")
    }
    return try await token(from: executable)
  }

  private static func token(from executable: URL) async throws -> String {
    try await Task.detached {
      let result = try run(executable, ["auth", "token", "--hostname", "github.com"])
      let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard result.status == 0, !token.isEmpty else { throw CredentialError.cliNotAuthenticated }
      return token
    }.value
  }

  private static func run(_ executable: URL, _ arguments: [String]) throws -> (
    status: Int32, output: String
  ) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
