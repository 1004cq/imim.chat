import Combine
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @State private var showProxy = false

    @State private var mode: LoginMode = .password
    @State private var account = ""
    @State private var password = ""
    @State private var phone = ""
    @State private var smsCode = ""
    @State private var registerUsername = ""
    @State private var registerNickname = ""
    @State private var registerPhone = ""
    @State private var registerCode = ""
    @State private var registerPassword = ""
    @State private var loginCodeCooldown = 0
    @State private var registerCodeCooldown = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @FocusState private var focusedField: Field?

    private enum LoginMode: String, CaseIterable, Identifiable {
        case password = "密码登录"
        case sms = "验证码登录"
        case register = "注册"

        var id: String { rawValue }
    }

    private enum Field {
        case account
        case password
        case phone
        case smsCode
        case registerUsername
        case registerNickname
        case registerPhone
        case registerCode
        case registerPassword
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header

                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 7) {
                            AppLocalizedText(title).font(.title3.weight(.semibold))
                            AppLocalizedText(subtitle)
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if mode != .register {
                            Picker("登录方式", selection: $mode) {
                                ForEach([LoginMode.password, .sms]) { mode in
                                    AppLocalizedText(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(spacing: 16) {
                            switch mode {
                            case .password:
                                passwordLoginForm
                            case .sms:
                                smsLoginForm
                            case .register:
                                registerForm
                            }
                        }
                    }

                    if let message = authSession.errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                            AppLocalizedText(message).fixedSize(horizontal: false, vertical: true)
                        }
                            .font(.footnote).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            .transition(.opacity)
                    }

                    Label(ProxyCopy.text("私聊默认端到端加密", "Private chats are end-to-end encrypted"), systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .background {
                ZStack {
                    Color(.systemBackground)
                    LinearGradient(colors: [AuthAppearance.accent.opacity(0.035), Color(.systemBackground)],
                        startPoint: .top, endPoint: .center)
                }.ignoresSafeArea()
            }
            .tint(AuthAppearance.accent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("简体中文") { languagePreference = AppLanguage.simplifiedChinese.rawValue }
                        Button("English") { languagePreference = AppLanguage.english.rawValue }
                        Button(ProxyCopy.text("跟随系统", "System language")) { languagePreference = AppLanguage.system.rawValue }
                    } label: {
                        Label(languageLabel, systemImage: "globe")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { focusedField = nil; showProxy = true } label: {
                        ProxyStatusLabel(compact: true)
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                        .accessibilityIdentifier("login.proxy")
                }
            }
            .sheet(isPresented: $showProxy) {
                NavigationStack {
                    ProxySettingsView().toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(ProxyCopy.text("关闭", "Close")) { showProxy = false }
                        }
                    }
                }
            }
            .task { ProxyStore.shared.testOnLaunch() }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
            .onReceive(timer) { _ in
                if loginCodeCooldown > 0 { loginCodeCooldown -= 1 }
                if registerCodeCooldown > 0 { registerCodeCooldown -= 1 }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("ImimOfficialAvatar").resizable().scaledToFit()
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: AuthAppearance.accent.opacity(0.12), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text(verbatim: "imim").font(.system(.title, design: .rounded, weight: .semibold))
            Text(verbatim: ProxyCopy.text("保持联系，安心沟通", "Stay close. Chat securely."))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    private var languageLabel: String {
        switch AppLanguage(rawValue: languagePreference) ?? .system {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .system: return ProxyCopy.text("语言", "Language")
        }
    }

    private var passwordLoginForm: some View {
        VStack(spacing: 14) {
            TextField("用户 ID、邮箱或手机号", text: $account)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .account)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .modifier(AuthTextFieldStyle(icon: "person", isFocused: focusedField == .account))

            SecureField("密码", text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await signInWithPassword() } }
                .modifier(AuthTextFieldStyle(icon: "lock", isFocused: focusedField == .password))

            primaryButton(title: "登录", loadingTitle: "登录中...") {
                await signInWithPassword()
            }

            Button("还没有账号？立即注册") {
                mode = .register
                focusedField = .registerPhone
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain).frame(minHeight: 44)
            .foregroundStyle(AuthAppearance.accent)
        }
    }

    private var smsLoginForm: some View {
        VStack(spacing: 14) {
            TextField("手机号", text: $phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($focusedField, equals: .phone)
                .modifier(AuthTextFieldStyle(icon: "iphone", isFocused: focusedField == .phone))

            HStack(spacing: 10) {
                TextField("短信验证码", text: $smsCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .smsCode)
                    .modifier(AuthTextFieldStyle(icon: "number", isFocused: focusedField == .smsCode))

                codeButton(cooldown: loginCodeCooldown, title: "获取验证码") {
                    if await authSession.sendSMSCode(phone: phone, type: .login) {
                        loginCodeCooldown = 60
                        focusedField = .smsCode
                    }
                }
            }

            primaryButton(title: "验证码登录", loadingTitle: "登录中...") {
                await authSession.signInWithSMS(phone: phone, code: smsCode)
            }

            Button("使用密码登录") {
                mode = .password
                focusedField = .account
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain).frame(minHeight: 44)
            .foregroundStyle(AuthAppearance.accent)
        }
    }

    private var registerForm: some View {
        VStack(spacing: 14) {
            TextField("手机号", text: $registerPhone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($focusedField, equals: .registerPhone)
                .modifier(AuthTextFieldStyle(icon: "iphone", isFocused: focusedField == .registerPhone))

            HStack(spacing: 10) {
                TextField("短信验证码", text: $registerCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .registerCode)
                    .modifier(AuthTextFieldStyle(icon: "number", isFocused: focusedField == .registerCode))

                codeButton(cooldown: registerCodeCooldown, title: "获取验证码") {
                    if await authSession.sendSMSCode(phone: registerPhone, type: .register) {
                        registerCodeCooldown = 60
                        focusedField = .registerCode
                    }
                }
            }

            TextField("用户名", text: $registerUsername)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .registerUsername)
                .modifier(AuthTextFieldStyle(icon: "person", isFocused: focusedField == .registerUsername))

            TextField("昵称（可选）", text: $registerNickname)
                .textContentType(.nickname)
                .focused($focusedField, equals: .registerNickname)
                .modifier(AuthTextFieldStyle(icon: "person.crop.circle", isFocused: focusedField == .registerNickname))

            SecureField("设置密码", text: $registerPassword)
                .textContentType(.newPassword)
                .focused($focusedField, equals: .registerPassword)
                .submitLabel(.go)
                .onSubmit { Task { await register() } }
                .modifier(AuthTextFieldStyle(icon: "lock", isFocused: focusedField == .registerPassword))

            primaryButton(title: "注册并登录", loadingTitle: "注册中...") {
                await register()
            }

            Button("已有账号？返回登录") {
                mode = .password
                focusedField = .account
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain).frame(minHeight: 44)
            .foregroundStyle(AuthAppearance.accent)
        }
    }

    private var title: String {
        switch mode {
        case .password, .sms:
            return "欢迎回来"
        case .register:
            return "创建账号"
        }
    }

    private var subtitle: String {
        switch mode {
        case .password:
            return "使用用户 ID、手机号或邮箱登录 IMIM Chat。"
        case .sms:
            return "输入手机号获取验证码，快速登录。"
        case .register:
            return "使用手机号验证码注册，注册成功后自动登录。"
        }
    }

    private func signInWithPassword() async {
        guard !authSession.isLoading else { return }
        await authSession.signIn(account: account, password: password)
    }

    private func register() async {
        await authSession.register(
            username: registerUsername,
            password: registerPassword,
            nickname: registerNickname,
            phone: registerPhone,
            phoneCode: registerCode
        )
    }

    private func primaryButton(title: String, loadingTitle: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 8) {
                if authSession.isLoading {
                    ProgressView()
                        .tint(.white)
                }
                AppLocalizedText(authSession.isLoading ? loadingTitle : title)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .padding(.vertical, 4)
            .background(AuthAppearance.accent.opacity(authSession.isLoading ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(authSession.isLoading)
    }

    private func codeButton(cooldown: Int, title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            AppLocalizedText(cooldown > 0 ? "\(cooldown)s" : title)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .frame(width: 94).frame(minHeight: 54)
                .foregroundStyle(AuthAppearance.accent)
                .background(AuthAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(authSession.isLoading || cooldown > 0)
    }
}

private struct AuthTextFieldStyle: ViewModifier {
    let icon: String
    let isFocused: Bool
    func body(content: Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(isFocused ? AuthAppearance.accent : Color.secondary)
                .frame(width: 20).accessibilityHidden(true)
            content.font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(isFocused ? AuthAppearance.accent.opacity(0.55) : Color.primary.opacity(0.055), lineWidth: 1))
    }
}

private enum AuthAppearance {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.28, green: 0.43, blue: 0.79, alpha: 1)
            : UIColor(red: 0.16, green: 0.27, blue: 0.57, alpha: 1)
    })
}
