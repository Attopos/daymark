import AuthenticationServices
import SwiftData
import SwiftUI

struct SignInAvatarButton: View {
    @Environment(AuthManager.self) private var authManager
    @State private var showingProfile = false
    @State private var showingSignIn = false

    var body: some View {
        Button {
            if authManager.isSignedIn {
                showingProfile = true
            } else {
                showingSignIn = true
            }
        } label: {
            avatarLabel
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showingSignIn) {
            SignInSheet()
        }
    }

    private var avatarLabel: some View {
        Group {
            if authManager.isSignedIn, let initials = authManager.userInitials {
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

private struct ProfileView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AuthManager.hasCompletedWelcomeKey) private var hasCompletedWelcome = false

    private let photoStore = PhotoStore()

    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    avatar
                        .padding(.top, 24)

                    VStack(spacing: 4) {
                        Text(authManager.displayName)
                            .font(.title2.weight(.bold))

                        if let email = authManager.userEmail {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        authManager.signOut()
                        dismiss()
                    } label: {
                        Text("Sign Out")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                            }
                            Text("Delete Account")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeleting)

                    Text("Deleting your account signs you out and permanently removes all of your journal photos and data from this device and iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .confirmationDialog(
                "Delete Account?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes your account and all journal photos and data. This cannot be undone.")
            }
            .alert("Delete Failed", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "Could not delete your account data.")
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private var avatar: some View {
        Group {
            if let initials = authManager.userInitials {
                Text(initials)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(.blue.gradient, in: Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func deleteAccount() {
        isDeleting = true
        errorMessage = nil

        Task {
            do {
                try photoStore.deleteAllEntries(in: modelContext)
                isDeleting = false
                dismiss()
                await Task.yield()
                hasCompletedWelcome = false
                authManager.clearStoredAccount()
            } catch {
                errorMessage = error.localizedDescription
                isDeleting = false
            }
        }
    }
}

struct SignInSheet: View {
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
