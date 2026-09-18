import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authSession: AuthSession

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
                VStack(alignment: .leading, spacing: 24) {
                    header

                    Picker("登录方式", selection: $mode) {
                        ForEach(LoginMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

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

                    if let message = authSession.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }
                }
                .padding(24)
            }
            .navigationTitle("登录")
            .animation(.easeInOut(duration: 0.2), value: mode)
            .onReceive(timer) { _ in
                if loginCodeCooldown > 0 { loginCodeCooldown -= 1 }
                if registerCodeCooldown > 0 { registerCodeCooldown -= 1 }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
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
                .modifier(AuthTextFieldStyle())

            SecureField("密码", text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await signInWithPassword() } }
                .modifier(AuthTextFieldStyle())

            primaryButton(title: "登录", loadingTitle: "登录中...") {
                await signInWithPassword()
            }

            Button("还没有账号？立即注册") {
                mode = .register
                focusedField = .registerPhone
            }
            .font(.footnote.weight(.medium))
        }
    }

    private var smsLoginForm: some View {
        VStack(spacing: 14) {
            TextField("手机号", text: $phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($focusedField, equals: .phone)
                .modifier(AuthTextFieldStyle())

            HStack(spacing: 10) {
                TextField("短信验证码", text: $smsCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .smsCode)
                    .modifier(AuthTextFieldStyle())

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
        }
    }

    private var registerForm: some View {
        VStack(spacing: 14) {
            TextField("手机号（可选）", text: $registerPhone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($focusedField, equals: .registerPhone)
                .modifier(AuthTextFieldStyle())

            HStack(spacing: 10) {
                TextField("短信验证码（填写手机号时使用）", text: $registerCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .registerCode)
                    .modifier(AuthTextFieldStyle())

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
                .modifier(AuthTextFieldStyle())

            TextField("昵称（可选）", text: $registerNickname)
                .textContentType(.nickname)
                .focused($focusedField, equals: .registerNickname)
                .modifier(AuthTextFieldStyle())

            SecureField("设置密码", text: $registerPassword)
                .textContentType(.newPassword)
                .focused($focusedField, equals: .registerPassword)
                .submitLabel(.go)
                .onSubmit { Task { await register() } }
                .modifier(AuthTextFieldStyle())

            primaryButton(title: "注册并登录", loadingTitle: "注册中...") {
                await register()
            }

            Button("已有账号？返回登录") {
                mode = .password
                focusedField = .account
            }
            .font(.footnote.weight(.medium))
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
            HStack {
                if authSession.isLoading {
                    ProgressView()
                        .tint(.white)
                }
                Text(authSession.isLoading ? loadingTitle : title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(authSession.isLoading)
    }

    private func codeButton(cooldown: Int, title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(cooldown > 0 ? "\(cooldown)s" : title)
                .font(.footnote.weight(.semibold))
                .frame(width: 96)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .disabled(authSession.isLoading || cooldown > 0)
    }
}

private struct AuthTextFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
