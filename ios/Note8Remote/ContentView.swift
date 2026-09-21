import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var fullScreen = true
    @State private var picker = false
    @State private var calibrating = false
    @State private var showingText = false
    @State private var remoteText = ""
    @State private var showingPreview = false
    @AppStorage("shutterX") private var shutterX = 0.5
    @AppStorage("shutterY") private var shutterY = 0.8
    @AppStorage("shutterCalibrated") private var calibrated = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    var body: some View {
        ZStack {
            if tab == 0 && fullScreen { immersiveScreen }
            else { tabs }
        }
        .statusBarHidden(tab == 0 && fullScreen)
        .tint(Color.accentColor)
        .environment(\.layoutDirection, .rightToLeft)
        .sheet(isPresented: $picker) { MediaPicker { result in picker = false; switch result { case .success(let file): model.choose(file.0, kind: file.1); case .failure(let error): model.error = error.localizedDescription } } }
        .sheet(isPresented: $showingPreview) { if let url = model.previewURL { NavigationStack { SavedPreview(url: url).navigationTitle("معاينة المقطع المحفوظ").navigationBarTitleDisplayMode(.inline).toolbar { Button("إغلاق") { showingPreview = false } } } } }
        .onChange(of: model.previewURL) { if $0 != nil { showingPreview = true } }
        .sheet(isPresented: $showingText) {
            NavigationStack {
                Form { Section("النص الذي تريد لصقه في الحقل المفتوح على النوت") { TextEditor(text: $remoteText).frame(minHeight: 140) }; Button("لصق على النوت") { model.command(["type": "text", "text": remoteText]); showingText = false }.disabled(remoteText.isEmpty || !model.connected) }
                    .navigationTitle("كتابة نص").toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { showingText = false } } }
            }.environment(\.layoutDirection, .rightToLeft)
        }
        .onOpenURL { url in model.importPairing(url); tab = 2 }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--screen-preview") {
                model.image = SimulatorScreen.image()
                model.connected = true
                model.lastFrame = .distantFuture
                tab = 0
                fullScreen = !ProcessInfo.processInfo.arguments.contains("--show-tools")
                return
            }
            #endif
            if model.host.isEmpty { tab = 2 } else { model.resumeSavedConnection() }
        }
        .onChange(of: scenePhase) { phase in if phase == .background { model.background() } else if phase == .active { model.resumeSavedConnection() } }
        .onChange(of: model.host) { _ in if model.connected { model.disconnect() } }
        .onChange(of: model.token) { _ in if model.connected { model.disconnect() } }
        .onChange(of: tab) { value in
            model.setViewingScreen(value == 0)
            if value == 0 { fullScreen = true }
        }
        .onReceive(clock) { now = $0 }
    }
    var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack { screen.navigationTitle("النوت 8").navigationBarTitleDisplayMode(.inline) }
                .tabItem { Label("التحكم", systemImage: "iphone.gen1") }.tag(0)
            NavigationStack { media.navigationTitle("المقاطع") }
                .tabItem { Label("المقاطع", systemImage: "photo.on.rectangle") }.tag(1)
            NavigationStack { settings.navigationTitle("الاتصال") }
                .tabItem { Label("الاتصال", systemImage: "link") }.tag(2)
        }
    }
    var remoteDisplay: some View {
            GeometryReader { proxy in
                ZStack {
                    TouchScreen(image: model.image, videoPlayer: model.videoPlayer, videoSize: model.videoSize, enabled: !model.stale && !model.recording, calibrating: calibrating, point: { p in shutterX = p.x; shutterY = p.y; calibrated = true; calibrating = false }, touch: { action, p in model.enqueue(["type": "touch", "action": action, "x": p.x, "y": p.y]) })
                    if model.image == nil && model.videoSize == nil {
                        VStack(spacing: 16) {
                            Image(systemName: "iphone.gen1.radiowaves.left.and.right").font(.system(size: 42))
                            Text("ستظهر شاشة النوت هنا").font(.headline)
                            Text("شغّل الخدمة وTailscale على الهاتفين، ثم اتصل.").font(.subheadline).multilineTextAlignment(.center)
                            Button("إعداد الاتصال") { tab = 2 }.buttonStyle(.borderedProminent)
                        }.foregroundStyle(.white).padding(24)
                    } else if model.stale {
                        Text("الصورة متوقفة — جارٍ إعادة الاتصال").font(.callout.weight(.semibold)).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if calibrating { VStack { Text("المس وسط زر التسجيل داخل سناب مرة واحدة لتحديد موضعه.").font(.callout.weight(.medium)).padding().background(.regularMaterial); Spacer() }.allowsHitTesting(false) }
                }.frame(width: proxy.size.width, height: proxy.size.height).background(.black)
            }
    }
    var immersiveScreen: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            // Keep the whole remote display inside the safe area so its Android
            // navigation buttons remain reachable around the iPhone sensor housing.
            remoteDisplay
            Button { fullScreen = false } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.8), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الرجوع إلى أدوات التحكم")
            .padding(8)
        }
        .persistentSystemOverlays(.hidden)
    }
    var status: some View {
        HStack(spacing: 8) {
            Image(systemName: model.stale ? "wifi.exclamationmark" : "checkmark.circle.fill").foregroundStyle(model.stale ? Color.secondary : Color.accentColor)
            Text(model.stale ? "غير متصل بالشاشة" : "متصل بالنوت").font(.subheadline.weight(.medium))
            Spacer()
            if model.videoSize != nil { Text("استقبال \(Int(model.videoFPS.rounded())) إطار/ث").font(.caption.monospacedDigit()) }
            if model.durationMs > 0 { Text(String(format: "%.2f ثانية", Double(model.durationMs) / 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder var errorBanner: some View {
        if !model.error.isEmpty {
            HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(model.error).font(.footnote); Spacer(); Button { model.error = "" } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("إغلاق التنبيه") }
                .foregroundStyle(Color.red).padding(8).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    var screen: some View {
        VStack(spacing: 10) {
            status
            errorBanner
            remoteDisplay.clipShape(RoundedRectangle(cornerRadius: 16))
            Button { fullScreen = true } label: {
                Label("ملء الشاشة", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered)
            HStack(spacing: 8) {
                tool("رجوع", "chevron.backward") { model.command(["type": "key", "key": 4]) }
                tool("الرئيسية", "house") { model.command(["type": "key", "key": 3]) }
                tool("نص", "text.cursor") { showingText = true }
                tool("سناب", "camera") { model.command(["type": "open", "app": "com.snapchat.android"]) }
            }.disabled(!model.connected || model.recording)
            if model.recording {
                Button(role: .destructive) { model.command(["type": "stopRecord"]) } label: { Label("إيقاف التسجيل الآن", systemImage: "stop.circle.fill").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
            } else {
                Button { if calibrated { model.command(["type": "record", "x": shutterX, "y": shutterY]) } else { calibrating = true } } label: {
                    Label(calibrated ? String(format: "تسجيل المقطع · %.2f ث", Double(model.durationMs) / 1000) : "حدد زر تسجيل سناب", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).disabled(calibrated ? !model.canRecord : model.stale)
            }
            if !model.recordingLabel.isEmpty { Text(model.recordingLabel).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
    func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 3) { Image(systemName: symbol); Text(title).font(.caption) }.frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.bordered)
    }
    var media: some View {
        Form {
            Section { errorBanner }
            Section {
                Button { picker = true } label: { Label("اختيار صورة أو فيديو", systemImage: "plus.rectangle.on.rectangle").frame(minHeight: 44) }.disabled(model.uploading)
                if model.selectedFile != nil {
                    Label(model.selectedKind == "video" ? "فيديو جاهز للنقل" : "صورة جاهزة للنقل", systemImage: model.selectedKind == "video" ? "video" : "photo")
                    ProgressView(value: model.progress).accessibilityLabel("تقدم الرفع")
                    Text(model.transferLabel).font(.footnote).foregroundStyle(.secondary)
                    if model.uploading { Button("إيقاف النقل مؤقتاً") { model.cancelUpload() } }
                    else { Button(model.progress > 0 && model.progress < 1 ? "متابعة النقل" : "نقل الأصل إلى النوت") { model.uploadSelected() }.disabled(!model.connected || model.recording) }
                    if !model.uploading && model.progress < 1 { Button("استخدام المقطع السابق") { model.usePreviousMedia() }.disabled(!model.connected) }
                }
            } header: { Text("من استوديو الآيفون") } footer: { Text("ننقل الملف الذي يقدمه تطبيق الصور دون ضغط إضافي، ثم نتحقق من بصمته. يبقى المقطع السابق فعالاً حتى يكتمل النقل. قد يضغط سناب التسجيل النهائي.") }
            Section("المقطع الموجود على النوت") {
                LabeledContent("النوع", value: model.mediaKind == "video" ? "فيديو" : model.mediaKind == "image" ? "صورة" : "غير معروف")
                if model.durationMs > 0 { LabeledContent("المدة", value: String(format: "%.3f ثانية", Double(model.durationMs) / 1000)) }
                Text("التسجيل التلقائي يدعم حالياً المقاطع من 0.5 إلى 60 ثانية. افتح كاميرا سناب، وحدد زر التسجيل، ثم اضغط تسجيل المقطع. يبقى الإرسال بيدك.").font(.footnote).foregroundStyle(.secondary)
                Button("فتح سناب على النوت") { model.command(["type": "open", "app": "com.snapchat.android"]); tab = 0 }.disabled(!model.connected || model.uploading)
            }
            Section {
                Button { model.fetchPreview() } label: { Label(model.downloadingPreview ? "جارٍ جلب المعاينة…" : "معاينة آخر تسجيل بالصوت", systemImage: "play.rectangle") }.disabled(!model.connected || model.recording || model.downloadingPreview || model.uploading)
            } footer: { Text("بعد التسجيل، اضغط زر الحفظ في سناب ليُحفظ المقطع في استوديو النوت، ثم افتحه هنا لمراجعة الصورة والصوت. المعاينة لا ترسل المقطع لأحد.") }
        }
    }
    var settings: some View {
        Form {
            Section { errorBanner }
            Section {
                TextField("عنوان النوت في Tailscale", text: $model.host).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight).accessibilityLabel("عنوان النوت في Tailscale")
                SecureField("رمز الاقتران", text: $model.token).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight)
                Button("لصق رابط الربط") { if let text = UIPasteboard.general.string, let url = URL(string: text) { model.importPairing(url) } }
                Button(model.connected ? "إعادة الاتصال" : "حفظ واتصال") { model.connect(); tab = 0 }.frame(minHeight: 44)
            } header: { Text("ربط الهاتفين") } footer: { Text("ثبّت Tailscale وسجّل الدخول إلى الحساب نفسه على الهاتفين. انسخ العنوان والرمز من تطبيق «التحكم بالنوت». لا يحتاج التشغيل اليومي إلى كمبيوتر.") }
            Section("صوت الهاتف") {
                Toggle("سماع صوت النوت مباشرة", isOn: $model.audioEnabled)
                    .onChange(of: model.audioEnabled) { _ in model.updateAudio() }
                Text("يعمل أثناء فتح التحكم، ويتوقف عند مغادرته. استخدم أزرار صوت الآيفون لضبط المستوى. قد ينتقل صوت النوت إلى الآيفون فقط.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.audioMessage.isEmpty { Text(model.audioMessage).font(.footnote).foregroundStyle(.red) }
            }
            Section("استهلاك الاتصال") {
                Picker("سرعة الرفع القصوى", selection: $model.speed) { Text("هادئ · 0.25 ميغابايت/ث").tag(262_144); Text("متوازن · 1 ميغابايت/ث").tag(1_048_576); Text("سريع · 3 ميغابايت/ث").tag(3_145_728) }
                    .onChange(of: model.speed) { UserDefaults.standard.set($0, forKey: "uploadRate") }
                Text("تُخفّض معاينة الشاشة أثناء الرفع. اختيار سرعة أقل يناسب الاتصالات الضعيفة. جودة الملف الأصلي ثابتة في جميع الخيارات.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("التسجيل") {
                Button("إعادة تحديد موضع زر تسجيل سناب") { calibrated = false; calibrating = true; fullScreen = true; tab = 0 }
                Text("التوقف يُنفّذ على النوت بحسب مدة الملف وبداية التسجيل الفعلية. تغيّر شكل واجهة سناب يستلزم تحديد الزر مجدداً. يمكن تشغيل صوت النوت من قسم صوت الهاتف.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("قطع الاتصال", role: .destructive) { model.disconnect() } }
        }.disabled(model.uploading)
    }
}

@main struct Note8RemoteApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct SavedPreview: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View { VideoPlayer(player: player).onDisappear { player.pause() } }
}
