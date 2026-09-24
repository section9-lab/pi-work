import SwiftUI

struct ScheduleView: View {
    @ObservedObject var store: ScheduleStore
    let runner: ScheduleRunner
    let projects: [PiProject]

    @AppStorage(SchedulePreferences.keepAwakeKey) private var keepMacAwake = false
    @Environment(\.locale) private var locale
    @State private var selectedSection = ScheduleSection.tasks
    @State private var editor: ScheduleEditorPresentation?
    @State private var deletedTask: ScheduledTask?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 24)

                    wakeNotice
                        .padding(.bottom, 30)

                    sectionToolbar
                        .padding(.bottom, 16)

                    content
                }
                .frame(maxWidth: 1_220, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 76)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)

            if let deletedTask {
                undoToast(for: deletedTask)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: deletedTask?.id)
        .sheet(item: $editor) { presentation in
            ScheduleEditorView(
                task: presentation.task,
                projects: projects
            ) { draft in
                do {
                    try store.save(draft)
                    return true
                } catch {
                    return false
                }
            }
        }
        .onAppear {
            runner.setKeepAwake(keepMacAwake)
        }
        .onChange(of: keepMacAwake) { isEnabled in
            runner.setKeepAwake(isEnabled)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("schedule.title"))
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)

                Text(L10n.string("schedule.subtitle"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button {
                editor = ScheduleEditorPresentation(task: nil)
            } label: {
                Label(L10n.string("schedule.new"), systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.raisedSurface)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
            }
            .buttonStyle(
                RoundedInteractionButtonStyle(
                    cornerRadius: 11,
                    baseFill: Color.primary.opacity(0.88)
                )
            )
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    private var wakeNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.86))

            Text(L10n.string("schedule.notice"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))

            Spacer(minLength: 16)

            Toggle(L10n.string("schedule.keep_awake"), isOn: $keepMacAwake)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(
            adaptiveRoundedShape(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.085))
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.11), lineWidth: 1)
        )
    }

    private var sectionToolbar: some View {
        HStack(alignment: .bottom, spacing: 20) {
            HStack(spacing: 22) {
                sectionButton(.tasks, title: L10n.string("schedule.my_schedules"))
                sectionButton(.history, title: L10n.string("schedule.history"))
            }
        }
    }

    private func sectionButton(_ section: ScheduleSection, title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedSection = section
            }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        Color.primary.opacity(selectedSection == section ? 0.88 : 0.42)
                    )

                Capsule()
                    .fill(selectedSection == section ? Color.primary.opacity(0.76) : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .tasks:
            if store.tasks.isEmpty {
                taskEmptyState
            } else {
                taskGrid
            }
        case .history:
            if store.records.isEmpty {
                historyEmptyState
            } else {
                historyList
            }
        }
    }

    private var taskGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)
            ],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(store.tasks) { task in
                ScheduleCard(
                    task: task,
                    locale: locale,
                    projectName: projectName(for: task.projectPath),
                    onEdit: { editor = ScheduleEditorPresentation(task: task) },
                    onSetEnabled: { store.setEnabled($0, for: task.id) },
                    onRun: {
                        runner.runNow(task.id)
                        selectedSection = .history
                    },
                    onDelete: {
                        deletedTask = store.delete(task.id)
                    }
                )
            }
        }
    }

    private var taskEmptyState: some View {
        ScheduleEmptyState(
            icon: "calendar.badge.plus",
            title: L10n.string("schedule.empty.title"),
            message: L10n.string("schedule.empty.message"),
            actionTitle: L10n.string("schedule.empty.action")
        ) {
            editor = ScheduleEditorPresentation(task: nil)
        }
    }

    private var historyEmptyState: some View {
        ScheduleEmptyState(
            icon: "clock.arrow.circlepath",
            title: L10n.string("schedule.history.empty_title"),
            message: L10n.string("schedule.history.empty_message")
        )
    }

    private var historyList: some View {
        VStack(spacing: 10) {
            ForEach(store.records) { record in
                ScheduleHistoryRow(
                    record: record,
                    dateText: historyDate(record.startedAt)
                )
            }
        }
    }

    private func undoToast(for task: ScheduledTask) -> some View {
        HStack(spacing: 12) {
            Text(L10n.format("schedule.deleted", task.name))
                .font(.system(size: 13, weight: .medium))

            Button(L10n.string("schedule.undo")) {
                store.restore(task)
                deletedTask = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)

            Button {
                deletedTask = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.46))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("common.done"))
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(
            adaptiveRoundedShape(cornerRadius: 13)
                .fill(AppPalette.raisedSurface)
                .shadow(color: AppPalette.raisedShadow, radius: 12, y: 4)
        )
    }

    private func projectName(for path: String?) -> String? {
        guard let path else { return nil }
        return projects.first(where: { $0.path == path })?.name
            ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private func historyDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(locale)
        )
    }
}

private enum ScheduleSection {
    case tasks
    case history
}

private struct ScheduleEditorPresentation: Identifiable {
    let id: UUID
    let task: ScheduledTask?

    init(task: ScheduledTask?) {
        id = task?.id ?? UUID()
        self.task = task
    }
}

private struct ScheduleCard: View {
    let task: ScheduledTask
    let locale: Locale
    let projectName: String?
    let onEdit: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onRun: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Button(action: onEdit) {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.name)
            .accessibilityHint(L10n.string("schedule.card.edit_hint"))

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { task.isEnabled },
                            set: onSetEnabled
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.format("schedule.task.toggle", task.name))

                    Spacer(minLength: 0)

                    Menu {
                        Button(action: onRun) {
                            Label(
                                L10n.string("schedule.menu.run_now"),
                                systemImage: "play.fill"
                            )
                        }

                        Divider()

                        Button(role: .destructive, action: onDelete) {
                            Label(
                                L10n.string("schedule.menu.delete"),
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(0.50))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Text(task.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(task.isEnabled ? 0.88 : 0.58))
                    .lineLimit(1)
                    .padding(.top, 14)

                Text(task.instruction)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(task.isEnabled ? 0.52 : 0.36))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                    .padding(.top, 7)

                Divider()
                    .overlay(Color.primary.opacity(0.055))
                    .padding(.vertical, 14)

                HStack(spacing: 8) {
                    Label(
                        "\(recurrenceText)  \(timeText)",
                        systemImage: "clock"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.64))
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(AppPalette.selectedRowFill, in: Capsule())

                    if let projectName {
                        Label(projectName, systemImage: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.46))
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(true)
            .padding(18)
        }
        .frame(minHeight: 206)
        .containerShape(
            RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous)
        )
        .background(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .fill(AppPalette.translucentSurface)
                .shadow(
                    color: AppPalette.subtleShadow.opacity(isHovering ? 0.82 : 0.42),
                    radius: isHovering ? 8 : 4,
                    y: isHovering ? 3 : 1
                )
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .stroke(
                    Color.primary.opacity(isHovering ? 0.14 : 0.075),
                    lineWidth: 1
                )
        )
        .contentShape(adaptiveRoundedShape(cornerRadius: AppCornerRadius.card))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
    }

    private var timeText: String {
        task.time.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(locale)
        )
    }

    private var recurrenceText: String {
        guard task.recurrence == .weekly else {
            return L10n.string(task.recurrence.localizationKey)
        }
        let weekday = task.weekday ?? Calendar.current.component(.weekday, from: task.time)
        return L10n.format(
            "schedule.recurrence.weekly_on",
            L10n.string(ScheduleWeekday.localizationKey(for: weekday))
        )
    }
}

private struct ScheduleHistoryRow: View {
    let record: ScheduleRunRecord
    let dateText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(statusColor.opacity(0.13))
                        Image(systemName: statusIcon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(statusColor.opacity(0.86))
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.taskName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.84))

                        Text(summaryText)
                            .font(.system(size: 12))
                            .foregroundStyle(
                                record.status == .failed
                                    ? Color.red.opacity(0.72)
                                    : Color.primary.opacity(0.46)
                            )
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(L10n.string(statusKey))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor.opacity(0.82))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(statusColor.opacity(0.10), in: Capsule())

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.34))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text(detailTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.46))

                    Text(verbatim: detailText)
                        .font(.system(size: 13))
                        .foregroundStyle(
                            record.status == .failed
                                ? Color.red.opacity(0.78)
                                : Color.primary.opacity(0.68)
                        )
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .background(
            adaptiveRoundedShape(cornerRadius: 14)
                .fill(AppPalette.translucentSurface)
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private var summaryText: String {
        record.errorMessage ?? record.resultText ?? dateText
    }

    private var detailTitle: String {
        record.status == .failed
            ? L10n.string("schedule.run.error_title")
            : L10n.string("schedule.run.result_title")
    }

    private var detailText: String {
        switch record.status {
        case .running:
            return L10n.string("schedule.run.running")
        case .completed:
            return record.resultText ?? L10n.string("schedule.run.result_unavailable")
        case .failed:
            return record.errorMessage ?? L10n.string("schedule.run.error_unavailable")
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .running: return .accentColor
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var statusIcon: String {
        switch record.status {
        case .running: return "ellipsis"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var statusKey: String {
        switch record.status {
        case .running: return "schedule.run.running"
        case .completed: return "schedule.run.completed"
        case .failed: return "schedule.run.failed"
        }
    }
}

private enum ScheduleWeekday {
    static let values = Array(1...7)

    static func localizationKey(for weekday: Int) -> String {
        switch weekday {
        case 1: return "schedule.weekday.sunday"
        case 2: return "schedule.weekday.monday"
        case 3: return "schedule.weekday.tuesday"
        case 4: return "schedule.weekday.wednesday"
        case 5: return "schedule.weekday.thursday"
        case 6: return "schedule.weekday.friday"
        default: return "schedule.weekday.saturday"
        }
    }
}

private struct ScheduleEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppPalette.selectedRowFill)
                    .frame(width: 58, height: 58)
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.56))
            }

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 16)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.48))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 6)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 286)
        .background(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .fill(AppPalette.translucentSurface.opacity(0.62))
        )
        .overlay(
            adaptiveRoundedShape(cornerRadius: AppCornerRadius.card)
                .stroke(Color.primary.opacity(0.065), lineWidth: 1)
        )
    }
}

private struct ScheduleEditorView: View {
    let projects: [PiProject]
    let onSave: (ScheduleDraft) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleDraft
    @State private var nameError = false
    @State private var instructionError = false

    private let isEditing: Bool

    init(
        task: ScheduledTask?,
        projects: [PiProject],
        onSave: @escaping (ScheduleDraft) -> Bool
    ) {
        self.projects = projects
        self.onSave = onSave
        isEditing = task != nil
        _draft = State(
            initialValue: task.map(ScheduleDraft.init(task:))
                ?? ScheduleDraft(time: Self.defaultTime())
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        L10n.string(
                            isEditing
                                ? "schedule.editor.edit_title"
                                : "schedule.editor.new_title"
                        )
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.25)

                    Text(L10n.string("schedule.editor.subtitle"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.52))
                }

                Spacer(minLength: 12)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(
                    RoundedInteractionButtonStyle(
                        cornerRadius: 9,
                        baseFill: AppPalette.selectedRowFill
                    )
                )
                .accessibilityLabel(L10n.string("common.cancel"))
            }

            editorLabel(L10n.string("schedule.editor.name"))
                .padding(.top, 26)

            TextField(L10n.string("schedule.editor.name_placeholder"), text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(fieldBackground(hasError: nameError))
                .onChange(of: draft.name) { _ in nameError = false }

            if nameError {
                validationMessage(L10n.string("schedule.editor.name_error"))
            }

            editorLabel(L10n.string("schedule.editor.plan"))
                .padding(.top, 20)

            HStack(spacing: 10) {
                Picker("", selection: $draft.recurrence) {
                    ForEach(ScheduleRecurrence.allCases) { recurrence in
                        Text(L10n.string(recurrence.localizationKey))
                            .tag(recurrence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)

                if draft.recurrence == .weekly {
                    Picker("", selection: weekdaySelection) {
                        ForEach(ScheduleWeekday.values, id: \.self) { weekday in
                            Text(L10n.string(ScheduleWeekday.localizationKey(for: weekday)))
                                .tag(weekday)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                DatePicker(
                    "",
                    selection: $draft.time,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 140)

                Spacer(minLength: 0)
            }

            editorLabel(L10n.string("schedule.editor.instruction"))
                .padding(.top, 20)

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if draft.instruction.isEmpty {
                        Text(L10n.string("schedule.editor.instruction_placeholder"))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.primary.opacity(0.30))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $draft.instruction)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .onChange(of: draft.instruction) { _ in instructionError = false }
                }
                .frame(minHeight: 150)

                Divider()
                    .overlay(Color.primary.opacity(0.07))

                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.48))

                    Text(L10n.string("schedule.editor.project"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.60))

                    Spacer(minLength: 12)

                    Picker("", selection: $draft.projectPath) {
                        Text(L10n.string("schedule.editor.no_project"))
                            .tag(String?.none)
                        ForEach(projects) { project in
                            Text(project.name)
                                .tag(Optional(project.path))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)

                Divider()
                    .overlay(Color.primary.opacity(0.07))

                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.48))

                    Text(L10n.string("schedule.editor.access"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.60))

                    Spacer(minLength: 12)

                    Picker("", selection: $draft.accessMode) {
                        Text(L10n.string("schedule.access.read_only"))
                            .tag(AgentHostAccessMode.readOnly)
                        Text(L10n.string("schedule.access.full"))
                            .tag(AgentHostAccessMode.full)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .help(L10n.string("schedule.access.help"))
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
            }
            .background(fieldBackground(hasError: instructionError))

            if instructionError {
                validationMessage(L10n.string("schedule.editor.instruction_error"))
            }

            Spacer(minLength: 24)

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(L10n.string("common.cancel")) {
                    dismiss()
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.64))
                .padding(.horizontal, 12)
                .frame(height: 34)

                Button {
                    save()
                } label: {
                    Text(L10n.string("schedule.editor.save"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.raisedSurface)
                        .padding(.horizontal, 17)
                        .frame(height: 34)
                }
                .buttonStyle(
                    RoundedInteractionButtonStyle(
                        cornerRadius: 10,
                        baseFill: Color.primary.opacity(0.88)
                    )
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 620, height: 670)
        .background(AppPalette.raisedSurface)
    }

    private func editorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.78))
            .padding(.bottom, 8)
    }

    private func fieldBackground(hasError: Bool) -> some View {
        adaptiveRoundedShape(cornerRadius: 11)
            .fill(AppPalette.translucentSurface)
            .overlay(
                adaptiveRoundedShape(cornerRadius: 11)
                    .stroke(
                        hasError ? Color.red.opacity(0.66) : Color.primary.opacity(0.10),
                        lineWidth: 1
                    )
            )
    }

    private func validationMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.red.opacity(0.82))
            .padding(.top, 5)
    }

    private func save() {
        nameError = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        instructionError = draft.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard !nameError, !instructionError else { return }
        if onSave(draft) { dismiss() }
    }

    private var weekdaySelection: Binding<Int> {
        Binding(
            get: {
                draft.weekday ?? Calendar.current.component(.weekday, from: draft.time)
            },
            set: { draft.weekday = $0 }
        )
    }

    private static func defaultTime() -> Date {
        let calendar = Calendar.current
        let now = Date()
        return calendar.date(
            bySettingHour: calendar.component(.hour, from: now) + 1,
            minute: 0,
            second: 0,
            of: now
        ) ?? now
    }
}
