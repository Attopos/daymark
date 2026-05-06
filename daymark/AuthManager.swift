import AuthenticationServices
import Foundation
import Observation

@Observable
@MainActor
final class AuthManager: NSObject {
    private(set) var isSignedIn = false
    private(set) var userName: String?
    private(set) var userEmail: String?

    private let userIDKey = "appleUserID"
    private let userNameKey = "appleUserName"
    private let userEmailKey = "appleUserEmail"

    private var signInContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        loadStoredCredentials()
    }

    var userInitials: String? {
        guard let name = userName else { return nil }
        let components = name.split(separator: " ")
        let initials = components.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? nil : initials
    }

    func handleSignInResult(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            processCredential(authorization)
        case .failure:
            break
        }
    }

    func attemptExistingAccountSignIn() async {
        guard !isSignedIn else { return }

        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let appleIDRequest = appleIDProvider.createRequest()
        appleIDRequest.requestedScopes = [.fullName, .email]

        let passwordProvider = ASAuthorizationPasswordProvider()
        let passwordRequest = passwordProvider.createRequest()

        let controller = ASAuthorizationController(authorizationRequests: [appleIDRequest, passwordRequest])
        controller.delegate = self

        await withCheckedContinuation { continuation in
            signInContinuation = continuation
            controller.performAutoFillAssistedRequests()
        }
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: userNameKey)
        UserDefaults.standard.removeObject(forKey: userEmailKey)
        isSignedIn = false
        userName = nil
        userEmail = nil
    }

    func checkCredentialState() async {
        guard let userID = UserDefaults.standard.string(forKey: userIDKey) else {
            await attemptExistingAccountSignIn()
            return
        }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
            if state != .authorized {
                signOut()
            }
        } catch {
            signOut()
        }
    }

    private func processCredential(_ authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            UserDefaults.standard.set(credential.user, forKey: userIDKey)
            if let fullName = credential.fullName {
                let name = PersonNameComponentsFormatter.localizedString(from: fullName, style: .default)
                if !name.isEmpty {
                    userName = name
                    UserDefaults.standard.set(name, forKey: userNameKey)
                }
            }
            if let email = credential.email {
                userEmail = email
                UserDefaults.standard.set(email, forKey: userEmailKey)
            }
            isSignedIn = true
        } else if let credential = authorization.credential as? ASPasswordCredential {
            userName = credential.user
            UserDefaults.standard.set(credential.user, forKey: userNameKey)
            isSignedIn = true
        }
    }

    private func loadStoredCredentials() {
        guard UserDefaults.standard.string(forKey: userIDKey) != nil else { return }
        userName = UserDefaults.standard.string(forKey: userNameKey)
        userEmail = UserDefaults.standard.string(forKey: userEmailKey)
        isSignedIn = true
    }
}

extension AuthManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            processCredential(authorization)
            signInContinuation?.resume()
            signInContinuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        MainActor.assumeIsolated {
            signInContinuation?.resume()
            signInContinuation = nil
        }
    }
}
