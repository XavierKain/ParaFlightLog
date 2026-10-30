//
//  ReservesView.swift
//  ParaFlightLog
//
//  Reserve parachutes: manufacture date, repack history deadline, and the
//  state of the next repack.
//
//  Target: iOS only
//

import SwiftUI
import SwiftData

// MARK: - ReservesView

struct ReservesView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \Reserve.createdAt, order: .reverse) private var reserves: [Reserve]

    @State private var editing: Reserve?
    @State private var showingAdd = false
    @State private var pendingDelete: Reserve?

    private var active: [Reserve] { reserves.filter { !$0.isArchived } }
    private var archived: [Reserve] { reserves.filter { $0.isArchived } }

    var body: some View {
        List {
            if reserves.isEmpty {
                ContentUnavailableView(
                    "No reserve",
                    systemImage: "lifepreserver.fill",
                    description: Text("Record your reserve to keep track of its repack deadline. You'll get a reminder a month before it's due.")
                )
            } else {
                Section {
                    ForEach(active) { reserve in
                        Button { editing = reserve } label: { ReserveRow(reserve: reserve) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { pendingDelete = reserve }
                            }
                    }
                } footer: {
                    Text("A repack is due every \(active.first?.repackIntervalMonths ?? 12) months by default. The reminder fires one month before the deadline.")
                }

                if !archived.isEmpty {
                    Section("Retired") {
                        ForEach(archived) { reserve in
                            Button { editing = reserve } label: { ReserveRow(reserve: reserve) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { pendingDelete = reserve }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reserve")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) { ReserveEditView(reserve: nil) }
        .sheet(item: $editing) { ReserveEditView(reserve: $0) }
        .alert(
            pendingDelete.map { "Delete \"\($0.name)\"?" } ?? "Delete?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { dataController.deleteReserve(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its repack history goes with it.")
        }
    }
}

// MARK: - Row

private struct ReserveRow: View {
    let reserve: Reserve

    var body: some View {
        let deadline = ReserveMaintenance.deadline(for: reserve)

        return HStack(spacing: 12) {
            Image(systemName: "lifepreserver.fill")
                .font(.title3)
                .foregroundStyle(reserve.isArchived ? Color.secondary : Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(reserve.name.isEmpty ? String(localized: "Reserve") : reserve.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let brand = reserve.brand, !brand.isEmpty { Text(brand) }
                    if let size = reserve.size, !size.isEmpty { Text(verbatim: "• \(size)") }
                    if let years = reserve.ageInYears { Text("^[\(years) year](inflect: true) old") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                RepackBadge(deadline: deadline, archived: reserve.isArchived)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Badge

private struct RepackBadge: View {
    let deadline: RepackDeadline
    let archived: Bool

    var body: some View {
        Group {
            if archived {
                Text("Retired")
            } else {
                switch deadline.status {
                case .unknown:
                    Text("No repack recorded yet")
                case .overdue:
                    Text("Repack overdue")
                case .dueSoon:
                    if let due = deadline.dueDate {
                        Text("Repack due \(due.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text("Repack due soon")
                    }
                case .ok:
                    if let due = deadline.dueDate {
                        Text("Next repack \(due.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text("Up to date")
                    }
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
    }

    private var color: Color {
        if archived { return .secondary }
        switch deadline.status {
        case .overdue: return .red
        case .dueSoon: return .orange
        case .ok: return .green
        case .unknown: return .secondary
        }
    }
}

// MARK: - Edit

/// Add or edit a reserve. Staged until Save, like the flight form, so Cancel
/// genuinely cancels.
struct ReserveEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController
    @Environment(\.modelContext) private var modelContext

    /// Nil when adding.
    let reserve: Reserve?

    @State private var name: String
    @State private var brand: String
    @State private var size: String
    @State private var serialNumber: String
    @State private var notes: String

    @State private var hasManufactureDate: Bool
    @State private var manufactureDate: Date
    @State private var hasRepackDate: Bool
    @State private var lastRepackDate: Date
    @State private var intervalMonths: Int
    @State private var isArchived: Bool

    init(reserve: Reserve?) {
        self.reserve = reserve
        _name = State(initialValue: reserve?.name ?? "")
        _brand = State(initialValue: reserve?.brand ?? "")
        _size = State(initialValue: reserve?.size ?? "")
        _serialNumber = State(initialValue: reserve?.serialNumber ?? "")
        _notes = State(initialValue: reserve?.notes ?? "")
        _hasManufactureDate = State(initialValue: reserve?.manufactureDate != nil)
        _manufactureDate = State(initialValue: reserve?.manufactureDate ?? Date())
        _hasRepackDate = State(initialValue: reserve?.lastRepackDate != nil)
        _lastRepackDate = State(initialValue: reserve?.lastRepackDate ?? Date())
        _intervalMonths = State(initialValue: reserve?.repackIntervalMonths ?? 12)
        _isArchived = State(initialValue: reserve?.isArchived ?? false)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reserve") {
                    TextField("Name (e.g. Companion SQR)", text: $name)
                    TextField("Brand", text: $brand)
                    TextField("Size / model", text: $size)
                    TextField("Serial number", text: $serialNumber)
                }

                Section {
                    Toggle("Manufacture date known", isOn: $hasManufactureDate.animation())
                    if hasManufactureDate {
                        DatePicker("Manufactured", selection: $manufactureDate, displayedComponents: .date)
                    }
                } footer: {
                    Text("Printed on the reserve's label. Used to show its age — it does not drive the repack deadline.")
                }

                Section {
                    Toggle("Repack recorded", isOn: $hasRepackDate.animation())
                    if hasRepackDate {
                        DatePicker("Last repack", selection: $lastRepackDate, displayedComponents: .date)
                        Picker("Repack every", selection: $intervalMonths) {
                            Text("^[\(6) month](inflect: true)").tag(6)
                            Text("^[\(12) month](inflect: true)").tag(12)
                            Text("^[\(24) month](inflect: true)").tag(24)
                        }
                        if let due = Calendar.current.date(byAdding: .month, value: intervalMonths, to: lastRepackDate) {
                            LabeledContent("Next repack") {
                                Text(due.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                    }
                } footer: {
                    Text(hasRepackDate
                         ? "You'll get a reminder a month before the next repack is due."
                         : "Record a repack to start the deadline. Without one there is nothing to remind you about.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if reserve != nil {
                    Section {
                        Toggle("Retired", isOn: $isArchived)
                    } footer: {
                        Text("A retired reserve stays in the list but stops producing reminders.")
                    }
                }
            }
            .navigationTitle(reserve == nil ? "New Reserve" : "Edit Reserve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func save() {
        let cleanedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSize = size.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSerial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let reserve {
            reserve.name = trimmedName
            reserve.brand = cleanedBrand.isEmpty ? nil : cleanedBrand
            reserve.size = cleanedSize.isEmpty ? nil : cleanedSize
            reserve.serialNumber = cleanedSerial.isEmpty ? nil : cleanedSerial
            reserve.notes = cleanedNotes.isEmpty ? nil : cleanedNotes
            reserve.manufactureDate = hasManufactureDate ? manufactureDate : nil
            reserve.lastRepackDate = hasRepackDate ? lastRepackDate : nil
            reserve.repackIntervalMonths = intervalMonths
            reserve.isArchived = isArchived
            dataController.saveContext()
            dataController.refreshRepackReminders()
        } else {
            dataController.addReserve(Reserve(
                name: trimmedName,
                brand: cleanedBrand.isEmpty ? nil : cleanedBrand,
                size: cleanedSize.isEmpty ? nil : cleanedSize,
                serialNumber: cleanedSerial.isEmpty ? nil : cleanedSerial,
                manufactureDate: hasManufactureDate ? manufactureDate : nil,
                lastRepackDate: hasRepackDate ? lastRepackDate : nil,
                repackIntervalMonths: intervalMonths,
                notes: cleanedNotes.isEmpty ? nil : cleanedNotes
            ))
        }
        dismiss()
    }
}
