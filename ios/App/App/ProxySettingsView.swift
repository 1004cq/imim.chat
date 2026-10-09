import SwiftUI

enum ProxyCopy {
    static func text(_ chinese: String, _ english: String) -> String {
        AppLanguage.current.resolvedIdentifier.hasPrefix("zh") ? chinese : english
    }
}

struct ProxyStatusLabel: View {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @ObservedObject private var store = ProxyStore.shared
    var compact = false
    private var color: Color {
        guard let active = store.active else { return .gray }
        return active.lastStatus == .connected ? .green : active.lastStatus == .failed ? .red : .gray
    }
    private var status: String {
        guard let active = store.active else { return ProxyCopy.text("代理已关闭", "Proxy off") }
        switch active.lastStatus {
        case .connected: return "\(active.latencyMs ?? 0) ms"
        case .failed: return ProxyCopy.text("连接失败", "Connection failed")
        default: return ProxyCopy.text("连接中", "Connecting")
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: compact && store.active == nil ? ProxyCopy.text("代理", "Proxy") : status)
                .font(.caption.weight(.medium)).lineLimit(1)
        }
        .accessibilityLabel(ProxyCopy.text("代理服务器", "Proxy") + ": " + status)
        .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }
}

struct ProxySettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @ObservedObject private var store = ProxyStore.shared
    @State private var sheet: Sheet?
    enum Sheet: String, Identifiable { case add, link; var id: String { rawValue } }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { store.active != nil }, set: { on in
                    Task { await store.enable(on ? store.configs.first?.id : nil) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: ProxyCopy.text("使用代理服务器", "Use Proxy"))
                        ProxyStatusLabel()
                    }
                }
                .disabled(store.isChanging || store.configs.isEmpty)
            } footer: {
                Text(verbatim: ProxyCopy.text("仅用于本 App 的接口和消息连接，通话连接保持不变。",
                    "Used for this app’s API and message connections only. Calls keep their existing connection."))
            }
            Section(ProxyCopy.text("代理服务器", "Proxy servers")) {
                if store.configs.isEmpty {
                    Text(verbatim: ProxyCopy.text("尚未添加代理服务器", "No Proxy servers yet"))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.configs) { config in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: config.title).font(.headline).lineLimit(1)
                                Text(verbatim: "\(config.host):\(config.port)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(ProxyCopy.text("启用", "Enable"), isOn: Binding(
                                get: { store.active?.id == config.id },
                                set: { on in Task { await store.enable(on ? config.id : nil) } }))
                                .labelsHidden().disabled(store.isChanging)
                                .accessibilityLabel(config.title + " " + ProxyCopy.text("启用", "Enable"))
                        }
                        HStack {
                            Text(verbatim: status(config)).font(.caption).foregroundStyle(config.lastStatus == .failed ? .red : .secondary)
                            Spacer()
                            Button(ProxyCopy.text("测速", "Test")) { Task { await store.measure(config.id) } }
                                .disabled(config.lastStatus == .checking || store.isChanging)
                        }
                    }
                    .padding(.vertical, 5)
                    .swipeActions {
                        Button(role: .destructive) { Task { await store.delete(config.id) } } label: {
                            Text(verbatim: ProxyCopy.text("删除", "Delete"))
                        }.disabled(store.isChanging)
                    }
                }
            }
            Section {
                Button { sheet = .add } label: {
                    Label(ProxyCopy.text("添加代理服务器", "Add Proxy"), systemImage: "plus")
                }
                Button { sheet = .link } label: {
                    Label(ProxyCopy.text("从链接导入", "Import from link"), systemImage: "link")
                }
            }
        }
        .navigationTitle(ProxyCopy.text("代理服务器", "Proxy"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .add: ProxyEditorView()
                case .link: ProxyLinkImportView()
                }
            }
        }
        .alert(ProxyCopy.text("代理服务器", "Proxy"), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(ProxyCopy.text("确定", "OK"), role: .cancel) {}
        } message: { Text(verbatim: store.errorMessage ?? "") }
        .task { store.testOnLaunch() }
        .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }
    private func status(_ config: ProxyConfig) -> String {
        switch config.lastStatus {
        case .idle: return ProxyCopy.text("未测速", "Not tested")
        case .checking: return ProxyCopy.text("正在测速", "Testing")
        case .connected: return "\(config.latencyMs ?? 0) ms"
        case .failed: return ProxyCopy.text("连接失败", "Connection failed")
        }
    }
}

struct ProxyEditorView: View {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProxyStore.shared
    private let imported: ProxyImport?
    @State private var title: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var enableNow = false
    @State private var saving = false
    @State private var error: String?

    init(imported: ProxyImport? = nil) {
        self.imported = imported
        _title = State(initialValue: imported?.config.title ?? "")
        _host = State(initialValue: imported?.config.host ?? "")
        _port = State(initialValue: imported.map { String($0.config.port) } ?? "1080")
        _username = State(initialValue: imported?.config.username ?? "")
        _password = State(initialValue: imported?.password ?? "")
    }
    var body: some View {
        Form {
            if imported != nil {
                Section {
                    Text(verbatim: ProxyCopy.text("请核对服务器。确认保存前不会改变连接。",
                        "Review the server. Your connection won’t change until you confirm."))
                }
            }
            Section(ProxyCopy.text("代理服务器", "Proxy")) {
                TextField(ProxyCopy.text("名称（可选）", "Name (optional)"), text: $title)
                TextField(ProxyCopy.text("服务器", "Server"), text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField(ProxyCopy.text("端口", "Port"), text: $port).keyboardType(.numberPad)
            }
            Section {
                TextField(ProxyCopy.text("用户名（可选）", "Username (optional)"), text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(ProxyCopy.text("密码（可选）", "Password (optional)"), text: $password)
            } footer: {
                Text(verbatim: ProxyCopy.text("账号和密码仅保存在本机 Keychain。", "Credentials are stored only in this device’s Keychain."))
            }
            Section { Toggle(ProxyCopy.text("保存后立即启用", "Enable after saving"), isOn: $enableNow) }
            if let error { Section { Text(verbatim: error).foregroundStyle(.red) } }
        }
        .navigationTitle(ProxyCopy.text(imported == nil ? "添加代理服务器" : "确认导入", imported == nil ? "Add Proxy" : "Confirm import"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(ProxyCopy.text("取消", "Cancel")) { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(ProxyCopy.text("保存", "Save")) { Task { await save() } }.disabled(saving || store.isChanging)
            }
        }
        .interactiveDismissDisabled(saving)
        .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }
    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            guard let numericPort = Int(port.trimmingCharacters(in: .whitespaces)) else { throw ProxyError.invalidConfig }
            let config = ProxyConfig(title: title, host: host, port: numericPort, username: username)
            let id = try store.add(config, password: password)
            if enableNow { await store.enable(id) }
            password = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ProxyLinkImportView: View {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var parsed: ProxyImport?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                SecureField(ProxyCopy.text("粘贴代理链接", "Paste Proxy link"), text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(ProxyCopy.text("检查链接", "Review link")) {
                    do {
                        guard link.utf8.count <= 8192, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ProxyError.invalidLink }
                        parsed = try ProxyImport.parse(url)
                        link = ""
                        error = nil
                    } catch { self.error = ProxyError.invalidLink.localizedDescription }
                }
            } footer: { Text(verbatim: "imim://proxy · app.imim.chat/proxy · t.me/socks · tg://socks") }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
        .navigationTitle(ProxyCopy.text("导入代理服务器", "Import Proxy"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ProxyCopy.text("关闭", "Close")) { dismiss() } } }
        .sheet(item: $parsed, onDismiss: { dismiss() }) { item in
            ProxyImportPreview(imported: item)
        }
        .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }
}

struct ProxyImportPreview: View {
    let imported: ProxyImport
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var store = ProxyStore.shared
    @State private var testRequest = 0
    @State private var isTesting = false
    @State private var previewStatus: ProxyConfig.Status = .idle
    @State private var previewLatency: Int?
    @State private var isConnecting = false
    @State private var connectedID: UUID?
    @State private var error: String?

    private var selected: ProxyConfig? {
        store.configs.first { $0.id == connectedID && $0.enabled }
    }
    private var status: ProxyConfig.Status { selected?.lastStatus ?? previewStatus }
    private var latency: Int? { selected?.latencyMs ?? previewLatency }
    private var busy: Bool { isConnecting || isTesting || status == .checking }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Text(verbatim: ProxyCopy.text("代理", "Proxy")).font(.headline)
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                        }
                        .buttonStyle(.plain).disabled(isConnecting)
                        .accessibilityLabel(ProxyCopy.text("关闭", "Close"))
                        Spacer()
                    }
                }
                VStack(spacing: 0) {
                    detailRow(ProxyCopy.text("服务器", "Server")) {
                        Text(verbatim: imported.config.host)
                    }
                    Divider()
                    detailRow(ProxyCopy.text("端口", "Port")) {
                        Text(verbatim: String(imported.config.port))
                    }
                    Divider()
                    detailRow(ProxyCopy.text("用户名", "Username")) {
                        Text(verbatim: imported.config.username.isEmpty ? ProxyCopy.text("无", "None") : imported.config.username)
                    }
                    Divider()
                    detailRow(ProxyCopy.text("密码", "Password")) {
                        // Intentionally no reveal button, copy action or secret accessibility text.
                        Text(verbatim: imported.password.isEmpty ? ProxyCopy.text("无", "None") : "••••••••")
                            .privacySensitive()
                    }
                    Divider()
                    detailRow(ProxyCopy.text("状态", "Status")) { statusView }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.10)))
                Text(verbatim: ProxyCopy.text("请确认你信任此代理服务器。检查状态只访问 app.imim.chat 的健康接口；连接后仅影响本 App 的接口和消息连接，通话保持不变。",
                    "Only connect to a Proxy you trust. The status check uses app.imim.chat’s health endpoint only. Proxy affects this app’s API and message connections; calls are unchanged."))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Button {
                if selected != nil { dismiss() }
                else { Task { await connect() } }
            } label: {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().tint(.white) }
                    Text(verbatim: ProxyCopy.text(isConnecting ? "正在连接…" : selected != nil ? "完成" : "连接代理",
                        isConnecting ? "Connecting…" : selected != nil ? "Done" : "Connect Proxy"))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity).frame(minHeight: 52)
                .foregroundStyle(.white).background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain).disabled(isConnecting || isTesting || store.isChanging)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(550), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .interactiveDismissDisabled(isConnecting)
        .task(id: testRequest) {
            guard testRequest > 0 else { return }
            await checkStatus()
        }
        .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }

    private func detailRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(verbatim: label).foregroundStyle(.secondary)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? 110 : 82, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body).padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .checking:
            HStack { ProgressView(); Text(verbatim: ProxyCopy.text("正在检查…", "Checking…")) }
        case .connected:
            VStack(alignment: .leading, spacing: 5) {
                Label("\(latency ?? 0) ms", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                checkButton(ProxyCopy.text("重新检查", "Check again"))
            }
        case .failed:
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: ProxyCopy.text("连接失败", "Connection failed")).foregroundStyle(.red)
                checkButton(ProxyCopy.text("重试", "Retry"))
            }
        case .idle: checkButton(ProxyCopy.text("检查状态", "Check status"))
        }
    }

    private func checkButton(_ label: String) -> some View {
        Button(label) {
            isTesting = true
            previewStatus = .checking
            previewLatency = nil
            testRequest += 1
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(busy || store.isChanging)
    }

    private func checkStatus() async {
        defer { isTesting = false }
        if let selected { await store.measure(selected.id); return }
        do {
            let value = try await ProxySession.previewLatency(imported)
            guard !Task.isCancelled else { return }
            previewLatency = value
            previewStatus = .connected
        } catch {
            guard !Task.isCancelled else { return }
            previewStatus = .failed
            previewLatency = nil
        }
    }

    private func connect() async {
        guard !isConnecting, !isTesting, !store.isChanging else { return }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do { connectedID = try await store.connect(imported) }
        catch { self.error = ProxyCopy.text("无法启用此代理，请重试或关闭面板。", "Unable to enable this Proxy. Retry or close this sheet.") }
    }
}

struct ProxyImportRouting: ViewModifier {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @State private var pending: ProxyImport?
    @State private var invalidLink = false
    func body(content: Content) -> some View {
        content
            .task { ProxyStore.shared.testOnLaunch() }
            .onOpenURL { url in
                guard ProxyImport.isCandidate(url) else { return }
                review(url)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard ProxyImport.isCandidate(url) else { return .systemAction }
                review(url)
                return .handled
            }
            )
            .sheet(item: $pending) { item in ProxyImportPreview(imported: item) }
            .alert(ProxyCopy.text("代理服务器", "Proxy"), isPresented: $invalidLink) {
                Button(ProxyCopy.text("确定", "OK"), role: .cancel) {}
            } message: { Text(verbatim: ProxyError.invalidLink.localizedDescription) }
            .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }
    private func review(_ url: URL) {
        guard pending == nil else { return }
        do { pending = try ProxyImport.parse(url) }
        catch { invalidLink = true }
    }
}
