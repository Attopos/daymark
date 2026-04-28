import AuthenticationServices
import Foundation
import Observation

@Observable
final class AuthManager {
    private(set) var isSignedIn = false
    private(set) var userName: String?
    private(set) var userEmail: String?

    private let userIDKey = "appleUserID"
    private let userNameKey = "appleUserName"
    private let userEmailKey = "appleUserEmail"

    init() {
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
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
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
        case .failure:
            break
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
        guard let userID = UserDefaults.standard.string(forKey: userIDKey) else { return }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
            if state != .authorized {
                await MainActor.run { signOut() }
            }
        } catch {
            await MainActor.run { signOut() }
        }
    }

    private func loadStoredCredentials() {
        guard UserDefaults.standard.string(forKey: userIDKey) != nil else { return }
        userName = UserDefaults.standard.string(forKey: userNameKey)
        userEmail = UserDefaults.standard.string(forKey: userEmailKey)
        isSignedIn = true
    }
}
