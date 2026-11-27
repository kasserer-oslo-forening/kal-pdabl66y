import SwiftUI

private let accent = Color(red: 0.12, green: 0.42, blue: 0.33)

struct LoginView: View {
    @EnvironmentObject var store: Store
    @State private var email = UserDefaults.standard.string(forKey: "email") ?? ""
    @State private var password = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("Gjøreliste").font(.largeTitle.bold())
                Text("Logg inn med e-posten og passordet du laget på nettsiden (knappen «Lag passord» nederst i lista).")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("E-post", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Passord", text: $password)
                    .textContentType(.password)
            }
            Section {
                Button(busy ? "Logger inn …" : "Logg inn") { Task { await login() } }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                if !message.isEmpty {
                    Text(message).foregroundStyle(.red).font(.footnote)
                }
            }
        }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            try await API.shared.signIn(email: mail, password: password)
            UserDefaults.standard.set(mail, forKey: "email")
            password = ""
            store.loggedIn = true
            await store.load()
        } catch {
            message = "Kunne ikke logge inn: \(error.localizedDescription)"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var newText = ""
    @State private var selected: TaskRow?
    @State private var showRest = false

    var body: some View {
        NavigationStack {
            List {
                Section { HeroView() }
                let open = store.openList()
                let n = store.topCount(open)
                Section(store.urgentCount(open) > 0 ? "Gjør disse først" : "Neste") {
                    if open.isEmpty {
                        Text("Alt er gjort. Ta fri.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(open.prefix(n))) { t in
                        TaskRowView(task: t, lead: t.id == open.first?.id) { selected = t }
                    }
                }
                if open.count > n {
                    Section {
                        DisclosureGroup("Vis resten (\(open.count - n))", isExpanded: $showRest) {
                            ForEach(Array(open.dropFirst(n))) { t in
                                TaskRowView(task: t, lead: false) { selected = t }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Noe du må huske?", text: $newText)
                            .onSubmit(add)
                        Button("Legg til", action: add)
                            .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Det du skriver inn her eller i Påminnelser-listen «Gjøreliste», sorterer Claude inn med dag og prioritet.")
                }
                if let e = store.error {
                    Section { Text(e).foregroundStyle(.red).font(.footnote) }
                }
            }
            .refreshable { await store.load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Synk med Påminnelser", isOn: $store.syncReminders)
                        Button("Logg ut", role: .destructive) { store.logout() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $selected) { t in
                DetailView(taskId: t.id).environmentObject(store)
            }
            .overlay(alignment: .bottom) {
                if let u = store.undoItem { UndoBanner(item: u) }
            }
        }
        .tint(accent)
    }

    private func add() {
        let v = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        newText = ""
        Task { await store.add(v) }
    }
}

struct HeroView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let st = store.todayStats()
        let reached = st.p >= store.goal
        HStack(spacing: 16) {
            VStack(spacing: 0) {
                Text("\(st.p)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(reached ? Color.white : accent)
                    .contentTransition(.numericText())
                Text("poeng i dag")
                    .font(.caption2.monospaced())
                    .foregroundStyle(reached ? Color.white : Color.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(reached ? accent : accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                Text("\(st.n) gjort · " + (reached ? "dagsmålet nådd!" : "\(store.goal - st.p) til dagsmålet"))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(min(st.p, store.goal)), total: Double(store.goal))
                    .tint(accent)
            }
        }
        .animation(.default, value: st.p)
    }
}

struct TaskRowView: View {
    @EnvironmentObject var store: Store
    let task: TaskRow
    let lead: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await store.complete(task) }
            } label: {
                Image(systemName: "circle").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Merk som gjort")

            VStack(alignment: .leading, spacing: 3) {
                if lead {
                    Text("START HER").font(.caption2.bold().monospaced()).foregroundStyle(accent)
                }
                Text(task.t).font(lead ? .headline : .body)
                meta
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            Spacer(minLength: 0)
        }
        .swipeActions(edge: .trailing) {
            Button("Stryk", role: .destructive) { Task { await store.drop(task) } }
            Button("I morgen") { Task { await store.snooze(task, to: Day.add(store.today, 1)) } }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button("Gjort") { Task { await store.complete(task) } }
                .tint(accent)
        }
    }

    private var meta: some View {
        let due = store.dueOf(task)
        let k = Day.diff(due, store.today)
        let dueColor: Color = k <= 0 ? .red : (k <= 2 ? .orange : .secondary)
        return HStack(spacing: 8) {
            if task.star == 1 { Text("★ viktig").foregroundStyle(.orange) }
            Text(Day.label(due, today: store.today)).foregroundStyle(dueColor)
            if let m = task.m, m > 0 { Text(minutes(m)) }
            if let c = task.c, !c.isEmpty { Text(c) }
            if let p = task.p, let name = store.projects[p], p != "inn" {
                Text(name).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        if m % 60 == 0 { return "\(m / 60) t" }
        return String(format: "%.1f t", Double(m) / 60).replacingOccurrences(of: ".", with: ",")
    }
}

struct DetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let taskId: String
    @State private var date = Date().addingTimeInterval(86_400)

    var body: some View {
        NavigationStack {
            Group {
                if let t = store.tasks.first(where: { $0.id == taskId }) {
                    form(t)
                } else {
                    Text("Oppgaven finnes ikke lenger.").foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Ferdig") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func form(_ t: TaskRow) -> some View {
        let sources = t.src ?? []
        let docs: [(String, URL)] = (t.docs ?? []).compactMap { d in
            guard let u = d.url, let url = URL(string: u) else { return nil }
            return (d.t ?? "Åpne", url)
        }
        Form {
            Section {
                Text(t.t).font(.headline)
                if let w = t.w, !w.isEmpty {
                    Text(w).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !sources.isEmpty {
                Section("Hvor kommer dette fra") {
                    ForEach(sources, id: \.self) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            let metaText = [s.at, s.who, s.k].compactMap { $0 }.joined(separator: " · ")
                            if !metaText.isEmpty {
                                Text(metaText).font(.caption).foregroundStyle(.secondary)
                            }
                            if let q = s.q { Text("«\(q)»").italic() }
                            if let u = s.url, let url = URL(string: u) {
                                Link(s.t ?? "Åpne", destination: url).font(.footnote)
                            } else if let tt = s.t {
                                Text(tt).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !docs.isEmpty {
                Section("Dokumenter") {
                    ForEach(docs.indices, id: \.self) { i in
                        Link(docs[i].0, destination: docs[i].1)
                    }
                }
            }
            Section {
                Button(t.star == 1 ? "★ Viktig" : "☆ Viktig for meg") { Task { await store.star(t, 1) } }
                Button(t.star == -1 ? "↓ Kan vente (valgt)" : "↓ Kan vente") { Task { await store.star(t, -1) } }
            }
            Section("Utsett til") {
                Button("I morgen") { snooze(Day.add(store.today, 1)) }
                Button("Mandag") { snooze(Day.nextMonday(store.today)) }
                Button("Om en uke") { snooze(Day.add(store.today, 7)) }
                DatePicker("Annen dag", selection: $date, in: Date()..., displayedComponents: .date)
                Button("Utsett til valgt dag") { snooze(Day.iso(date)) }
            }
            Section {
                Button("Ikke aktuelt – stryk", role: .destructive) {
                    Task { await store.drop(t); dismiss() }
                }
            }
        }
    }

    private func snooze(_ to: String) {
        guard let t = store.tasks.first(where: { $0.id == taskId }) else { return }
        Task {
            await store.snooze(t, to: to)
            dismiss()
        }
    }
}

struct UndoBanner: View {
    @EnvironmentObject var store: Store
    let item: UndoItem

    var body: some View {
        HStack {
            Text(item.text).bold()
            Spacer()
            Button("Angre") { Task { await store.undo(item) } }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
