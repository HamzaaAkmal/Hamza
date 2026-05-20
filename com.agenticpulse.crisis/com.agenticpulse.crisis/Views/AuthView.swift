import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var app: AppModel
    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.surface, .white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 28)
                        header

                        VStack(alignment: .leading, spacing: 18) {
                            Picker("Mode", selection: $mode) {
                                Text("Login").tag(AuthMode.signIn)
                                Text("Signup").tag(AuthMode.signUp)
                            }
                            .pickerStyle(.segmented)

                            VStack(spacing: 12) {
                                if mode == .signUp {
                                    TextField("Full name", text: $fullName)
                                        .textContentType(.name)
                                        .textInputAutocapitalization(.words)
                                        .autocorrectionDisabled()
                                        .textFieldStyle(.roundedBorder)
                                }

                                TextField("Email", text: $email)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)

                                SecureField("Password", text: $password)
                                    .textContentType(mode == .signIn ? .password : .newPassword)
                                    .textFieldStyle(.roundedBorder)
                            }

                            if !AppConfig.shared.isSupabaseConfigured {
                                Label("Set SUPABASE_ANON_KEY before signing in.", systemImage: "key.slash")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AppTheme.warning)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppTheme.warning.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }

                            if let notice = app.authNotice {
                                Label(notice, systemImage: "envelope.badge")
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.blue)
                            }

                            if let error = app.authError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.danger)
                            }

                            Button {
                                Task { await submit() }
                            } label: {
                                HStack {
                                    if app.isAuthenticating {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                    Text(mode == .signIn ? "Login" : "Create account")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle(isDisabled: !canSubmit))
                            .disabled(!canSubmit || app.isAuthenticating)
                        }
                        .padding(20)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        )
                        .shadow(color: AppTheme.ink.opacity(0.08), radius: 18, x: 0, y: 10)

                        Text("Mock-safe crisis orchestration powered by AgenticPulse")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 22)
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("CrisisXLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white, lineWidth: 3)
                )
                .shadow(color: AppTheme.success.opacity(0.28), radius: 18, x: 0, y: 10)

            VStack(spacing: 5) {
                Text("CrisisX")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text("Emergency response command")
                    .font(.headline)
                    .foregroundStyle(AppTheme.blue)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var canSubmit: Bool {
        AppConfig.shared.isSupabaseConfigured &&
        email.contains("@") &&
        password.count >= 6 &&
        (mode == .signIn || !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func submit() async {
        switch mode {
        case .signIn:
            await app.signIn(email: email, password: password)
        case .signUp:
            await app.signUp(email: email, password: password, fullName: fullName)
        }
    }
}

private enum AuthMode {
    case signIn
    case signUp
}
