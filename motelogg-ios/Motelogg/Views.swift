import SwiftUI

// MARK: - Liste over møter

struct ContentView: View {
    @Environment(MeetingStore.self) private var store
    @State private var search = ""
    @State private var showSettings = false

    private var filtered: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.meetings }
        return store.meetings.filter {
            ($0.title + " " + $0.transcript + " " + $0.summary).lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RecordView()
                    } label: {
                        Label("Nytt møte", systemImage: "record.circle")
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                }
                Section("Møter") {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "Ingen møter ennå" : "Ingen treff")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { m in
                        NavigationLink {
                            MeetingDetail(meeting: m)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title.isEmpty ? "Uten navn" : m.title).font(.headline)
                                Text(m.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { filtered[$0].id }
                        store.delete(ids: ids)
                    }
                }
            }
            .searchable(text: $search, prompt: "Søk i møter")
            .navigationTitle("Møtelogg")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

// MARK: - Opptak

struct RecordView: View {
    @Environment(MeetingStore.self) private var store
    @AppStorage("chunkSeconds") private var chunkSeconds = 20.0
    @State private var rec = Recorder()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Navn på møtet", text: $rec.meeting.title)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 18) {
                        Button {
                            Task {
                                if rec.isRecording {
                                    rec.stop()
                                } else {
                                    rec.chunkSeconds = chunkSeconds
                                    await rec.start()
                                }
                            }
                        } label: {
                            Text(rec.isRecording ? "Stopp" : "Start")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 86, height: 86)
                                .background(Circle().fill(Color.red))
                        }
                        VStack(alignment: .leading) {
                            Text(Recorder.stamp(rec.elapsed))
                                .font(.largeTitle.monospacedDigit().bold())
                            Text(rec.statusText).foregroundStyle(.secondary)
                        }
                    }

                    if let e = rec.lastError {
                        Text(e).foregroundStyle(.red)
                    }

                    Text("Transkripsjon").font(.headline)
                    Text(rec.meeting.transcript.isEmpty
                         ? "Teksten kommer her, ca. hvert \(Int(chunkSeconds)). sekund. Du kan låse skjermen."
                         : rec.meeting.transcript)
                        .foregroundStyle(rec.meeting.transcript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)

                    SummarySection(meeting: $rec.meeting)
                        .id("bottom")
                }
                .padding()
            }
            .onChange(of: rec.meeting) { _, m in
                if !m.transcript.isEmpty || !m.title.isEmpty { store.upsert(m) }
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .navigationTitle("Opptak")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(rec.isRecording)
    }
}

// MARK: - Et lagret møte

struct MeetingDetail: View {
    @Environment(MeetingStore.self) private var store
    @State var meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Navn på møtet", text: $meeting.title)
                    .font(.title2.bold())
                Text(meeting.date.formatted(date: .long, time: .shortened))
                    .foregroundStyle(.secondary)
                SummarySection(meeting: $meeting)
                Text("Transkripsjon").font(.headline)
                Text(meeting.transcript).textSelection(.enabled)
            }
            .padding()
        }
        .toolbar { ShareLink(item: meeting.exportText) }
        .onChange(of: meeting) { _, m in store.upsert(m) }
    }
}

// MARK: - Oppsummering

struct SummarySection: View {
    @Binding var meeting: Meeting
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Oppsummering").font(.headline)
                Spacer()
                Button(busy ? "Oppsummerer …" : "Oppsummer") {
                    Task { await run() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || meeting.transcript.isEmpty)
            }
            if let errorText { Text(errorText).foregroundStyle(.red) }
            if !meeting.summary.isEmpty {
                Text(meeting.summary).textSelection(.enabled)
            }
        }
    }

    private func run() async {
        busy = true
        errorText = nil
        do {
            meeting.summary = try await Gemini.summarize(meeting.transcript, title: meeting.title)
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - Innstillinger

struct SettingsView: View {
    @AppStorage("geminiKey") private var key = ""
    @AppStorage("geminiModel") private var model = "gemini-flash-latest"
    @AppStorage("chunkSeconds") private var chunkSeconds = 20.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gemini") {
                    SecureField("API-nøkkel", text: $key)
                    TextField("Modell", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Opptak") {
                    Stepper("Sekunder per bit: \(Int(chunkSeconds))", value: $chunkSeconds, in: 10...60, step: 5)
                }
            }
            .navigationTitle("Innstillinger")
            .toolbar { Button("Ferdig") { dismiss() } }
        }
    }
}
