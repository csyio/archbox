import SwiftUI

/// First-launch window: asks for the Linux account, then shows install progress.
struct SetupView: View {
    @ObservedObject var installer: Installer

    @State private var username = NSUserName()
    @State private var fullName = NSFullUserName()
    @State private var password = ""
    @State private var passwordAgain = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Arch Linux kurulumu").font(.title2.bold())
                Text("KDE Plasma masaüstüyle, tek seferlik. Yaklaşık 15–30 dakika sürer (internet hızına bağlı).")
                    .foregroundStyle(.secondary)
            }

            switch installer.phase {
            case .form:
                form
            case .running:
                progress
            case .failed(let message):
                progress
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                Button("Tekrar dene") { installer.phase = .form }
            case .finished:
                Label("Kurulum tamamlandı, Arch Linux açılıyor…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var usernameIsValid: Bool {
        username.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
            && !["root", "alarm"].contains(username)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Ad Soyad", text: $fullName)
                TextField("Kullanıcı adı", text: $username)
                SecureField("Parola", text: $password)
                SecureField("Parola (tekrar)", text: $passwordAgain)
            }
            if !usernameIsValid {
                Text("Kullanıcı adı küçük harf, rakam, - ve _ içerebilir.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !password.isEmpty && password != passwordAgain {
                Text("Parolalar eşleşmiyor.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Bu parola Arch'ta `sudo` için kullanılır. Açılışta otomatik giriş yapılır.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Kur") {
                    installer.start(account: .init(username: username, fullName: fullName, password: password))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!usernameIsValid || password.isEmpty || password != passwordAgain)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Installer.stepTitles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Group {
                        if index < installer.step {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if index == installer.step, installer.phase == .running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16)
                    Text(title).foregroundStyle(index <= installer.step ? .primary : .secondary)
                }
            }
            if let fraction = installer.downloadProgress {
                ProgressView(value: fraction)
            }
            if !installer.logTail.isEmpty {
                ScrollView {
                    Text(installer.logTail)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 150)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if installer.phase == .running {
                HStack {
                    Spacer()
                    Button("İptal") { installer.cancel() }
                }
            }
        }
    }
}
