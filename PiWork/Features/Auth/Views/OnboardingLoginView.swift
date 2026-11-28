import SwiftUI

/// Full-screen sign-in shown whenever there is no valid session. Mirrors the
/// pre-rewrite flow: a provider picker, then the two email-OTP steps.
///
/// Both providers end up in the same place — `AuthSession` exchanges the
/// authorization code for the same `AuthTokenSet` either way — so this view
/// only drives step transitions and surfaces errors.
struct OnboardingLoginView: View {
    @ObservedObject var authSession: AuthSession

    private enum Step {
        case picker
        case emailInput
        case emailCode
    }

    @State private var step: Step = .picker
    @State private var email = ""
    @State private var code = ""
    @State private var resendCooldown = 0
    @State private var cooldownTask: Task<Void, Never>?

    private let resendCooldownSeconds = 120

    var body: some View {
        ZStack {
            AppBackgroundGradient()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 26) {
                    header

                    switch step {
                    case .picker:
                        pickerStep
                    case .emailInput:
                        emailStep
                    case .emailCode:
                        codeStep
                    }

                    if let error = authSession.lastErrorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    localModeSection
                }
                .frame(width: 360)

                Spacer(minLength: 0)

                Text(L10n.string("onboarding.terms"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.light)
        .onDisappear { cooldownTask?.cancel() }
    }

    // MARK: - Steps

    /// Escape hatch that does not depend on the auth service. Kept on every
    /// step, below the error text, so it is the visible next action when the
    /// issuer is down.
    private var localModeSection: some View {
        VStack(spacing: 6) {
            Button {
                authSession.enterLocalMode()
            } label: {
                Text(L10n.string("onboarding.local_mode"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(authSession.isAuthenticating)
            .accessibilityHint(L10n.string("onboarding.local_hint"))

            Text(L10n.string("onboarding.local_hint"))
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.36, green: 0.60, blue: 0.94),
                                     Color(red: 0.55, green: 0.42, blue: 0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)
                Text("p")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)

            Text(titleText)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.88))

            Text(subtitleText)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: String {
        switch step {
        case .picker: return L10n.string("onboarding.welcome")
        case .emailInput: return L10n.string("onboarding.email_title")
        case .emailCode: return L10n.string("onboarding.code_title")
        }
    }

    private var subtitleText: String {
        switch step {
        case .picker:
            return L10n.string("onboarding.welcome_subtitle")
        case .emailInput:
            return L10n.string("onboarding.email_subtitle")
        case .emailCode:
            return L10n.format("onboarding.code_sent", authSession.pendingEmail ?? email)
        }
    }

    private var pickerStep: some View {
        VStack(spacing: 12) {
            Button(action: { Task { await authSession.signInWithGoogle() } }) {
                HStack(spacing: 9) {
                    GoogleGlyph()
                    Text(L10n.string("onboarding.google"))
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white)
                .adaptiveCornerRadius(12)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(authSession.isAuthenticating)

            HStack(spacing: 10) {
                line
                Text(L10n.string("common.or"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.35))
                line
            }
            .padding(.vertical, 2)

            Button(action: {
                authSession.clearLastError()
                step = .emailInput
            }) {
                HStack(spacing: 9) {
                    Image(systemName: "envelope")
                        .font(.system(size: 13))
                    Text(L10n.string("onboarding.email"))
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.55))
                .adaptiveCornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(authSession.isAuthenticating)

            if authSession.isAuthenticating {
                progressHint(L10n.string("onboarding.waiting_browser"))
            }
        }
    }

    private var emailStep: some View {
        VStack(spacing: 12) {
            EmailInputField(text: $email, onSubmit: sendCode)

            primaryButton(
                title: L10n.string("onboarding.send_code"),
                enabled: !email.trimmingCharacters(in: .whitespaces).isEmpty,
                action: sendCode
            )

            backButton {
                authSession.clearLastError()
                step = .picker
            }

            if authSession.isAuthenticating {
                progressHint(L10n.string("onboarding.sending_code"))
            }
        }
    }

    private var codeStep: some View {
        VStack(spacing: 14) {
            OTPInputView(code: $code, length: 6) { _ in verifyCode() }

            primaryButton(
                title: L10n.string("onboarding.verify"),
                enabled: code.count == 6,
                action: verifyCode
            )

            Button(action: resend) {
                Text(resendCooldown > 0
                    ? L10n.format("onboarding.resend_countdown", resendCooldown)
                    : L10n.string("onboarding.resend"))
                    .font(.system(size: 12))
                    .foregroundStyle(resendCooldown > 0
                                     ? Color.primary.opacity(0.3)
                                     : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(resendCooldown > 0 || authSession.isAuthenticating)

            backButton {
                code = ""
                authSession.cancelEmailLogin()
                authSession.clearLastError()
                step = .emailInput
            }

            if authSession.isAuthenticating {
                progressHint(L10n.string("onboarding.verifying"))
            }
        }
    }

    // MARK: - Pieces

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }

    private func progressHint(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.45))
        }
    }

    private func primaryButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(enabled ? Color.accentColor : Color.accentColor.opacity(0.35))
                .adaptiveCornerRadius(12)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || authSession.isAuthenticating)
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.string("common.back"))
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.45))
        }
        .buttonStyle(.plain)
        .disabled(authSession.isAuthenticating)
    }

    // MARK: - Actions

    private func sendCode() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await authSession.requestEmailCode(trimmed)
                code = ""
                step = .emailCode
                startCooldown()
            } catch {
                // AuthSession already surfaced the message via lastErrorMessage.
            }
        }
    }

    private func resend() {
        Task {
            do {
                try await authSession.resendEmailCode()
                startCooldown()
            } catch {
                // Surfaced through lastErrorMessage.
            }
        }
    }

    private func verifyCode() {
        guard code.count == 6 else { return }
        Task {
            do {
                try await authSession.verifyEmailCode(code)
                cooldownTask?.cancel()
            } catch {
                code = ""
            }
        }
    }

    private func startCooldown() {
        cooldownTask?.cancel()
        resendCooldown = resendCooldownSeconds
        cooldownTask = Task {
            while resendCooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                resendCooldown -= 1
            }
        }
    }
}

/// LobeHub's Google.Color brand mark.
private struct GoogleGlyph: View {
    var body: some View {
        Image("ModelIconGoogle")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}
