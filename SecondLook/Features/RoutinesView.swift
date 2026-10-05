import SwiftUI
import SecondLookCore

struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: RoutineEditorRequest?
    @State private var destination: UUID?
    @State private var routineToDelete: Routine?
    @State private var startChoice: Routine?

    var body: some View {
        List {
            Section {
                Button { editor = .init(routine: nil, oneOff: false) } label: {
                    Label("Create routine", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("createRoutine")
                Button { editor = .init(routine: nil, oneOff: true) } label: {
                    Label("Create one-off checklist", systemImage: "plus.rectangle.on.folder")
                }
            }
            if !model.openRuns.isEmpty {
                Section("Open checklists") {
                    ForEach(model.openRuns) { run in
                        NavigationLink(value: run.id) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(run.title).font(.headline)
                                Text("\(run.items.filter(\.isSatisfied).count) of \(run.items.count) ready · \(model.personName(run.performerID))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(run.startedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("Resume").font(.caption.weight(.semibold))
                            }
                        }
                        .accessibilityIdentifier("resume-\(run.title)")
                    }
                }
            }
            Section("Saved routines") {
                if model.state.routines.isEmpty {
                    Text("Make a routine for the things you want to double-check regularly.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.state.routines) { routine in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(routine.title).font(.headline)
                        Text("\(routine.items.count) steps · \(routine.items.filter { $0.priority == .high }.count) need a second look")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.hasOpenRun(routine.id) ? "Resume or start" : "Start") {
                                if model.hasOpenRun(routine.id) { startChoice = routine }
                                else { destination = model.start(routine) }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("startRoutine-\(routine.title)")
                            Spacer()
                            Button("Edit") { editor = .init(routine: routine, oneOff: false) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Edit \(routine.title)")
                            Button(role: .destructive) { routineToDelete = routine } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(routine.title)")
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Routines")
        .navigationDestination(for: UUID.self) { ChecklistView(runID: $0) }
        .navigationDestination(item: $destination) { ChecklistView(runID: $0) }
        .sheet(item: $editor) { request in
            RoutineEditorView(request: request) { routine, oneOff in
                if oneOff {
                    destination = model.startOneOff(routine)
                    return destination != nil
                } else { return model.save(routine) }
            }
            .sheetErrorAlert()
        }
        .confirmationDialog("A checklist is already open", isPresented: Binding(
            get: { startChoice != nil }, set: { if !$0 { startChoice = nil } }
        ), titleVisibility: .visible) {
            if let routine = startChoice {
                Button("Resume most recent") { destination = model.latestOpenRun(routine.id)?.id }
                Button("Start another run") { destination = model.start(routine) }
            }
        } message: { Text("Starting another keeps every existing checklist and its progress.") }
        .confirmationDialog("Delete this routine?", isPresented: Binding(
            get: { routineToDelete != nil }, set: { if !$0 { routineToDelete = nil } }
        ), titleVisibility: .visible) {
            if let routine = routineToDelete {
                Button("Delete routine", role: .destructive) { model.deleteRoutine(routine.id) }
            }
        } message: { Text("Existing checklists and history keep their original steps.") }
    }
}

struct RoutineEditorRequest: Identifiable {
    let id = UUID()
    let routine: Routine?
    let oneOff: Bool
}

struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let request: RoutineEditorRequest
    let onSave: (Routine, Bool) -> Bool
    @State private var title: String
    @State private var items: [RoutineItem]
    @State private var settings: RunSettings

    init(request: RoutineEditorRequest, onSave: @escaping (Routine, Bool) -> Bool) {
        self.request = request
        self.onSave = onSave
        _title = State(initialValue: request.routine?.title ?? "")
        _items = State(initialValue: request.routine?.items ?? [RoutineItem(title: "")])
        _settings = State(initialValue: request.routine?.settings ?? RunSettings())
    }

    var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty &&
        items.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Checklist name", text: $title)
                        .accessibilityIdentifier("routineTitle")
                }
                Section {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Step description", text: $item.title, axis: .vertical)
                                .accessibilityIdentifier("stepTitle-\(items.firstIndex(where: { $0.id == item.id }) ?? 0)")
                            Toggle("High priority · photo and review", isOn: Binding(
                                get: { item.priority == .high },
                                set: { item.priority = $0 ? .high : .standard }
                            ))
                            if item.priority == .high {
                                TextField("What should the photo show?", text: $item.photoInstructions, axis: .vertical)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add step", systemImage: "plus") { items.append(RoutineItem(title: "")) }
                } header: { Text("Ordered steps") } footer: {
                    Text("Use Edit to reorder or remove steps. Running checklists keep a snapshot; later edits apply only to new runs.")
                }
                PreferencesFields(settings: $settings)
            }
            .navigationTitle(request.oneOff ? "One-off checklist" : (request.routine == nil ? "New routine" : "Edit routine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(request.oneOff ? "Start" : "Save") {
                        let routine = Routine(id: request.routine?.id ?? UUID(), title: title, items: items, settings: settings)
                        if onSave(routine, request.oneOff) { dismiss() }
                    }
                    .disabled(!valid)
                    .accessibilityIdentifier("saveRoutine")
                }
                ToolbarItem(placement: .bottomBar) { EditButton() }
            }
        }
    }
}
