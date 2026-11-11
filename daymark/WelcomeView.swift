import AuthenticationServices
import SwiftUI

struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var hasAppeared = false

    /// Called when the user has finished onboarding, either by signing in or
    /// choosing to continue without an account.
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "book.closed.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(DaymarkPalette.buttonText)
                .frame(width: 112, height: 112)
                .background(DaymarkPalette.bloom, in: RoundedRectangle(cornerRadius: DaymarkRadius.panel, style: .continuous))
                .overlay { DaymarkGlassRim(cornerRadius: DaymarkRadius.panel) }
                .shadow(color: DaymarkSwatch.picoEggplant.opacity(0.35), radius: 24, y: 12)
                .symbolEffect(.bounce, value: hasAppeared)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .opacity(hasAppeared ? 1 : 0)

            VStack(spacing: 10) {
                Text("Welcome to Daymark")
                    .font(DaymarkTypography.pageTitle)
                    .multilineTextAlignment(.center)

                Text("Capture one photo a day and build a journal of your year.")
                    .font(.subheadline)
                    .foregroundStyle(DaymarkPalette.secondaryInk)
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
                .frame(height: 52)
                .clipShape(Capsule())

                Button {
                    onFinish()
                } label: {
                    Text("Continue Without Account")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .foregroundStyle(DaymarkPalette.accent)

                Text("You can sign in later from Settings. Signing in lets you personalize Daymark across your devices.")
                    .font(DaymarkTypography.metadata)
                    .foregroundStyle(DaymarkPalette.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, DaymarkSpacing.xxl)
            .padding(.bottom, DaymarkSpacing.xxl)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 24)
        }
        .daymarkScreen(backdrop: true)
        .onAppear {
            withAnimation(DaymarkMotion.spring.delay(0.1)) {
                hasAppeared = true
            }
        }
        .interactiveDismissDisabled()
    }
}
