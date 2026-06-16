import AuthenticationServices
import SwiftUI

struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.colorScheme) private var colorScheme

    /// Called when the user has finished onboarding, either by signing in or
    /// choosing to continue without an account.
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "book.closed.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 10) {
                Text("Welcome to Daymark")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Capture one photo a day and build a journal of your year.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 14) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    authManager.handleSignInResult(result)
                    if authManager.isSignedIn {
                        onFinish()
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)

                Button {
                    onFinish()
                } label: {
                    Text("Continue Without Account")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Text("You can sign in later from Settings. Signing in lets you personalize Daymark across your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .interactiveDismissDisabled()
    }
}
