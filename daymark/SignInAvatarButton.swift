import AuthenticationServices
import SwiftUI

struct SignInAvatarButton: View {
    @Environment(AuthManager.self) private var authManager
    @State private var showingSignIn = false

    var body: some View {
        if authManager.isSignedIn {
            Menu {
                if let name = authManager.userName {
                    Text(name)
                }
                if let email = authManager.userEmail {
                    Text(email)
                }
                Divider()
                Button("Sign Out", role: .destructive) {
                    authManager.signOut()
                }
            } label: {
                avatarLabel
            }
        } else {
            Button { showingSignIn = true } label: {
                avatarLabel
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingSignIn) {
                SignInSheet()
            }
        }
    }

    private var avatarLabel: some View {
        Group {
            if let initials = authManager.userInitials {
                Text(initials)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.blue.gradient, in: Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }
}

private struct SignInSheet: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Sign in to Daymark")
                .font(.title2.weight(.bold))

            Text("Sign in with your Apple account to personalize your experience.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                authManager.handleSignInResult(result)
                if authManager.isSignedIn {
                    dismiss()
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .padding(.horizontal, 40)

            Spacer()

            Button("Not Now") { dismiss() }
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
    }
}
