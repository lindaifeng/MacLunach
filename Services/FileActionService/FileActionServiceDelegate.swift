import FileActionServiceProtocol
import Foundation
import Security
import Darwin

final class FileActionServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard TrustedXPCClientValidator.accepts(newConnection) else {
            return false
        }
        newConnection.exportedInterface = FileActionServiceXPCInterface.make()
        newConnection.exportedObject = FileActionServiceEndpoint()
        newConnection.resume()
        return true
    }
}

private enum TrustedXPCClientValidator {
    static func accepts(_ connection: NSXPCConnection) -> Bool {
        guard let expectedBundleIdentifier = hostBundleIdentifier,
              connection.effectiveUserIdentifier == getuid(),
              let clientCode = code(for: connection.processIdentifier),
              let serviceCode = currentCode,
              let serviceTeamIdentifier = teamIdentifier(for: serviceCode),
              let requirement = requirement(
                for: expectedBundleIdentifier,
                teamIdentifier: serviceTeamIdentifier
              ) else {
            return false
        }

        return SecCodeCheckValidity(clientCode, SecCSFlags(), requirement) == errSecSuccess
    }

    private static var hostBundleIdentifier: String? {
        guard let serviceIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let components = serviceIdentifier.split(separator: ".")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: ".")
    }

    private static var currentCode: SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess else { return nil }
        return code
    }

    private static func code(for processIdentifier: pid_t) -> SecCode? {
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: processIdentifier] as CFDictionary,
            SecCSFlags(),
            &code
        )
        guard status == errSecSuccess else { return nil }
        return code
    }

    private static func teamIdentifier(for code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
              ) == errSecSuccess,
              let values = information as? [CFString: Any] else {
            return nil
        }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func requirement(
        for bundleIdentifier: String,
        teamIdentifier: String
    ) -> SecRequirement? {
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }
}
