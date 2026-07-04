import Foundation
import LocalAuthentication
import SwiftUI

/// Biometric app lock (Face ID / Touch ID) for protecting sensitive transcriptions.
/// F7 security fix: medium priority - transcriptions can contain very sensitive info.
@MainActor
enum BiometricLock {
    
    /// Check if biometric authentication is available and enrolled.
    static var isEnabled: Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return true
    }
    
    /// Authenticate the user with biometrics.
    /// - Parameter reason: Message shown to the user in the authentication dialog.
    /// - Returns: true if authentication succeeded, false otherwise.
    static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw BiometricError.biometricsNotAvailable(error?.localizedDescription ?? "Biometría no disponible")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
                if success {
                    continuation.resume(returning: true)
                } else {
                    if let err = evalError as? LAError, err.code == .userCancel {
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(throwing: BiometricError.authenticationFailed(
                            evalError?.localizedDescription ?? "Autenticación fallida"
                        ))
                    }
                }
            }
        }
    }
}

enum BiometricError: LocalizedError {
    case biometricsNotAvailable(String)
    case authenticationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .biometricsNotAvailable(let msg):
            return "Biometría no disponible: \(msg)"
        case .authenticationFailed(let msg):
            return "Autenticación fallida: \(msg)"
        }
    }
}
