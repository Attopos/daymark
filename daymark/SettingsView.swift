import SwiftUI

struct SettingsView: View {
    @Binding var prefersDarkMode: Bool
    @State private var showingLoginMessage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    appearanceCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLoginMessage = true
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .alert("Log In", isPresented: $showingLoginMessage) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Login flow is not connected yet.")
            }
        }
    }

    private var appearanceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: prefersDarkMode ? "moon.stars.fill" : "sun.max.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)

            Text("Dark Mode")
                .font(.headline)

            Spacer()

            Toggle("", isOn: $prefersDarkMode)
                .labelsHidden()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }
}

#Preview {
    SettingsView(prefersDarkMode: .constant(false))
}
