import SwiftUI

enum Route: Hashable {
    case record(auto: Bool)
    case session(String)
}

// MARK: - Start: innlogging eller listen

struct RootView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("skipLogin") private var skipLogin = false

    var body: some View {
        if store.loggedIn || skipLogin {
            ContentView()
        } else {
            LoginView(onSkip: { skipLogin = true })
        }
    }
}

struct LoginView: View {
    @Environment(SessionStore.self) private var store
    var onSkip: (() -> Void)?
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Logg inn med samme e-post og passord som gjørelista. Da synkes opptakene mellom iPhone, PC og nettleser, og Gemini-nøkkelen hentes automatisk.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    TextField("E-post", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passord", text: $password).textContentType(.password)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(busy ? "Logger inn …" : "Logg inn") {
                        Task {
                            busy = true; error = nil
                            do { try await store.signIn(email: email, password: password) }
                            catch { self.error = "Feil e-post eller passord." }
                            busy = false
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                    if let onSkip { Button("Fortsett uten synk", action: onSkip).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Referat")
        }
    }
}

// MARK: - Liste over opptak

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var search = ""
    @State private var showSettings = false
    @State private var path: [Route] = []
    private let launch = LaunchAction.shared

    private var filtered: [RecSession] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = store.sessions.filter(\.hasContent).sorted { $0.date > $1.date }
        guard !q.isEmpty else { return list }
        return list.filter { s in
            (s.title + " " + s.segments.map(\.text).joined(separator: " ") + " " + s.notes.map { $0.text + " " + ($0.answer ?? "") }.joined(separator: " "))
                .lowercased().contains(q)
        }
    }

    private func handleLaunch() {
        guard launch.startRequested else { return }
        launch.startRequested = false
        path = [.record(auto: true)]
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Route.record(auto: false)) {
                        Label("Nytt opptak", systemImage: "record.circle")
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "Ingen opptak ennå" : "Ingen treff").foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { s in
                        NavigationLink(value: Route.session(s.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title.isEmpty ? "Uten tittel" : s.title).font(.headline)
                                Text("\(s.date.formatted(date: .abbreviated, time: .shortened)) · \(stamp(s.dur))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in store.delete(ids: offsets.map { filtered[$0].id }) }
                } header: {
                    HStack {
                        Text("Tidligere opptak")
                        Spacer()
                        if store.loggedIn { Text(store.syncStatus).font(.caption2) }
                    }
                }
            }
            .searchable(text: $search, prompt: "Søk i opptak og notater")
            .refreshable { await store.pull() }
            .navigationTitle("Referat")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .record(let auto): RecordView(autostart: auto)
                case .session(let id): SessionDetail(id: id)
                }
            }
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { handleLaunch() }
            .onChange(of: launch.startRequested) { _, _ in handleLaunch() }
            .task {
                await store.pullSettings()
                // Hent endringer fra de andre enhetene jevnlig mens appen er åpen
                while !Task.isCancelled {
                    if phase == .active { await store.pull() }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
}

// MARK: - Opptak

struct RecordView: View {
    var autostart = false
    @Environment(SessionStore.self) private var store
    @AppStorage("chunkSeconds") private var chunkSeconds = 60.0
    @State private var rec = Recorder()
    @State private var noteText = ""
    @State private var anchor: Int?
    @State private var needsSummary = false
    @State private var summarizing = false
    @State private var summaryError: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Tittel (lages automatisk)", text: $rec.session.title)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 18) {
                            Button {
                                Task {
                                    if rec.isRecording {
                                        rec.stop()
                                        needsSummary = true
                                        trySummary()
                                    } else {
                                        rec.chunkSeconds = chunkSeconds
                                        store.activeRecordingId = rec.session.id
                                        await rec.start()
                                    }
                                }
                            } label: {
                                Text(rec.isRecording ? "Stopp" : "Start")
                                    .font(.headline).foregroundStyle(.white)
                                    .frame(width: 82, height: 82)
                                    .background(Circle().fill(Color.red))
                            }
                            VStack(alignment: .leading) {
                                Text(stamp(rec.elapsed)).font(.largeTitle.monospacedDigit().bold())
                                Text(rec.statusText).foregroundStyle(.secondary)
                            }
                        }
                        if let e = rec.lastError { Text(e).foregroundStyle(.red).font(.callout) }

                        Text("Transkripsjon").font(.headline)
                        TranscriptView(session: $rec.session, live: rec.liveMinute, anchor: $anchor,
                                       placeholder: "Teksten kommer omtrent hvert \(Int(chunkSeconds)). sekund. Du kan låse skjermen.")

                        SummaryView(session: rec.session, busy: summarizing, error: summaryError) { Task { await summarize() } }
                            .id("bottom")
                    }
                    .padding()
                }
                .onChange(of: rec.session.segments.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            NoteComposer(text: $noteText, anchor: $anchor, focused: $noteFocused, isLive: rec.isRecording) {
                rec.addNote(noteText, minute: anchor)
                noteText = ""; anchor = nil
            }
        }
        .onChange(of: rec.session) { _, s in if s.hasContent { store.upsert(s) } }
        .onChange(of: rec.pending) { _, _ in trySummary() }
        .navigationTitle("Opptak")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(rec.isRecording)
        .task {
            if autostart && !rec.isRecording {
                rec.chunkSeconds = chunkSeconds
                store.activeRecordingId = rec.session.id
                await rec.start()
            }
        }
        .onDisappear { if !rec.isRecording { store.activeRecordingId = nil } }
    }

    /// Oppsummer automatisk når opptaket er stoppet og siste bit er transkribert.
    private func trySummary() {
        guard needsSummary, !rec.isRecording, rec.pending == 0 else { return }
        needsSummary = false
        store.activeRecordingId = nil
        Task { await summarize() }
    }

    private func summarize() async {
        guard rec.session.hasContent else { return }
        summarizing = true; summaryError = nil
        do {
            let m = try await Gemini.summarize(rec.session)
            rec.session.summary = m
            if rec.session.title.isEmpty, let t = m.title { rec.session.title = t }
        } catch { summaryError = error.localizedDescription }
        summarizing = false
    }
}

// MARK: - Et lagret opptak (oppdateres når det endres på en annen enhet)

struct SessionDetail: View {
    let id: String
    @Environment(SessionStore.self) private var store
    @State private var anchor: Int?
    @State private var noteText = ""
    @State private var summarizing = false
    @State private var summaryError: String?
    @FocusState private var noteFocused: Bool

    private var binding: Binding<RecSession> {
        Binding(get: { store.session(id) ?? RecSession() }, set: { store.upsert($0) })
    }

    var body: some View {
        let s = binding.wrappedValue
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Tittel", text: binding.title).font(.title2.bold())
                    Text("\(s.date.formatted(date: .long, time: .shortened)) · \(stamp(s.dur))").foregroundStyle(.secondary)
                    SummaryView(session: s, busy: summarizing, error: summaryError) { Task { await summarize() } }
                    Text("Transkripsjon").font(.headline)
                    TranscriptView(session: binding, live: nil, anchor: $anchor, placeholder: "Ingen tekst.")
                }
                .padding()
            }
            NoteComposer(text: $noteText, anchor: $anchor, focused: $noteFocused, isLive: false) { addNote() }
        }
        .toolbar { ShareLink(item: s.exportText) }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addNote() {
        var text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var x = binding.wrappedValue
        let kind = text.hasPrefix("?") ? "q" : "note"
        if kind == "q" { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let t = anchor.map { Double($0 * 60) + 30 } ?? x.dur
        x.notes.append(Note(id: newId(), t: t, text: text, kind: kind, answer: ""))
        binding.wrappedValue = x
        noteText = ""; anchor = nil
    }

    private func summarize() async {
        summarizing = true; summaryError = nil
        do {
            var x = binding.wrappedValue
            let m = try await Gemini.summarize(x)
            x.summary = m
            if x.title.isEmpty, let t = m.title { x.title = t }
            binding.wrappedValue = x
        } catch { summaryError = error.localizedDescription }
        summarizing = false
    }
}

// MARK: - Transkripsjon per minutt, med notater og spørsmål

struct TranscriptView: View {
    @Binding var session: RecSession
    var live: Int?
    @Binding var anchor: Int?
    var placeholder: String

    var body: some View {
        let blocks = session.blocks(live: live)
        if blocks.isEmpty {
            Text(placeholder).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(stamp(Double(b.id * 60)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading) {
                                let text = b.segs.map { $0.status == "fail" ? "[en bit kunne ikke transkriberes]" : $0.text }.joined(separator: " ")
                                if !text.isEmpty { Text(text).textSelection(.enabled) }
                                if b.id == live {
                                    Text(b.segs.isEmpty ? "Lytter … teksten kommer snart" : "Lytter …").italic().foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(anchor == b.id ? Color.blue.opacity(0.15) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { anchor = (anchor == b.id || b.id == live) ? nil : b.id }

                        ForEach(b.notes) { n in
                            NoteRow(note: n, answer: answerBinding(n.id)) {
                                session.notes.removeAll { $0.id == n.id }
                            }
                            .padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { session.notes.first { $0.id == id }?.answer ?? "" },
            set: { v in if let i = session.notes.firstIndex(where: { $0.id == id }) { session.notes[i].answer = v } }
        )
    }
}

struct NoteRow: View {
    let note: Note
    @Binding var answer: String
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(note.kind == "q" ? "SPØRSMÅL" : "NOTAT") · \(stamp(note.t))")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Slett", role: .destructive, action: onDelete).font(.caption2)
            }
            Text(note.text)
            if note.kind == "q" {
                TextField("Svar …", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(note.kind == "q" ? Color.yellow.opacity(0.2) : Color.blue.opacity(0.12)))
    }
}

struct NoteComposer: View {
    @Binding var text: String
    @Binding var anchor: Int?
    var focused: FocusState<Bool>.Binding
    var isLive: Bool
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(anchor.map { "Knyttes til minuttet \(stamp(Double($0 * 60)))" } ?? (isLive ? "Notatet havner i minuttet som pågår" : "Notatet havner i siste minutt"))
                    .font(.caption).foregroundStyle(.secondary)
                if anchor != nil { Button("Fjern") { anchor = nil }.font(.caption) }
            }
            HStack {
                TextField("Notat … eller ?spørsmål", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused(focused)
                    .submitLabel(.done)
                    .onSubmit(onAdd)
                Button("Legg til", action: onAdd)
                    .buttonStyle(.bordered)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Oppsummering

struct SummaryView: View {
    let session: RecSession
    var busy: Bool
    var error: String?
    var onSummarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Oppsummering").font(.headline)
                Spacer()
                Button(busy ? "Oppsummerer …" : (session.summary == nil ? "Oppsummer" : "Lag på nytt"), action: onSummarize)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !session.hasContent)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if let m = session.summary {
                VStack(alignment: .leading, spacing: 12) {
                    if let type = m.type, !type.isEmpty {
                        Text(type).font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                    if let s = m.summary {
                        VStack(alignment: .leading, spacing: 4) { Text("Sammendrag").font(.subheadline.bold()); Text(s) }
                    }
                    bullets("Hovedpunkter", m.keyPoints)
                    bullets("Beslutninger", m.decisions)
                    bullets("Oppgaver", m.tasks?.map { t in
                        let who = (t.who ?? "").isEmpty ? "Uavklart hvem" : (t.who ?? "")
                        let due = (t.due ?? "").isEmpty ? "" : " (frist \(t.due ?? ""))"
                        return "\(who): \(t.what)\(due)"
                    })
                    bullets("Spørsmål og svar", m.qa?.map { "\($0.q)\n→ \(($0.a ?? "").isEmpty ? "Ikke besvart" : ($0.a ?? ""))" })
                    bullets("Mine notater", m.notes)
                    bullets("Uavklart / til oppfølging", m.open)
                }
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            } else if !busy {
                Text("Oppsummeringen lages automatisk når du trykker Stopp.").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    @ViewBuilder private func bullets(_ title: String, _ items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                ForEach(Array(items.enumerated()), id: \.offset) { _, x in Text("• " + x) }
            }
        }
    }
}

// MARK: - Innstillinger

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("geminiKey") private var key = ""
    @AppStorage("geminiModel") private var model = "gemini-flash-latest"
    @AppStorage("chunkSeconds") private var chunkSeconds = 60.0
    @AppStorage("vocab") private var vocab = ""
    @AppStorage("skipLogin") private var skipLogin = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.loggedIn {
                        Label("Logget inn – synker", systemImage: "checkmark.icloud")
                        Button("Logg ut", role: .destructive) { store.signOut(); skipLogin = false }
                    } else {
                        Button("Logg inn for synk") { skipLogin = false; dismiss() }
                    }
                } header: { Text("Synk") }
                Section {
                    SecureField("API-nøkkel", text: $key)
                    Link("Hent nøkkelen: aistudio.google.com/apikey (prosjekt Nettsidene)", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.footnote)
                    TextField("Modell", text: $model).autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: { Text("Gemini") } footer: { Text("Nøkkelen deles automatisk mellom enhetene når du er logget inn.") }
                Section {
                    TextField("Ord og navn, komma mellom", text: $vocab, axis: .vertical)
                } header: { Text("Ord og navn") } footer: { Text("Hjelper transkripsjonen å skrive navn og fagord riktig.") }
                Section("Opptak") {
                    Stepper("Sekunder per bit: \(Int(chunkSeconds))", value: $chunkSeconds, in: 10...120, step: 10)
                }
            }
            .navigationTitle("Innstillinger")
            .toolbar { Button("Ferdig") { Task { await store.pushSettings() }; dismiss() } }
        }
    }
}
