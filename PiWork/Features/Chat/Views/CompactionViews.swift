import AppKit
import MarkdownUI
import SwiftUI

/// Transient operation state lives by the composer, not in an assistant bubble.
struct CompactionActivityView: View {
    let compaction: AgentHostCompaction
    let onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(L10n.string(CompactionPresentation.activityKey(compaction.reason)))
                .lineLimit(2)
            Spacer(minLength: 8)
            if let startedAt = ISO8601DateFormatter().date(from: compaction.timestamp)
                ?? Self.fractionalFormatter.date(from: compaction.timestamp) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
            }
            if let onCancel {
                Button(L10n.string("chat.compaction.cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compaction-cancel")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compaction-activity")
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// A durable timeline event. Its identity is the persisted compaction entry ID.
struct CompactionRecordView: View {
    let compaction: AgentHostCompaction
    var onRetry: (() -> Void)? = nil
    @State private var isExpanded = false
    @State private var isCopied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canExpand: Bool {
        compaction.summary?.isEmpty == false || compaction.errorMessage?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    guard canExpand else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded
                              ? "arrow.up.left.and.arrow.down.right"
                              : "arrow.down.right.and.arrow.up.left")
                        Text(L10n.string(CompactionPresentation.titleKey(compaction.status)))
                        Spacer(minLength: 8)
                        if let tokens = CompactionPresentation.tokenText(compaction) {
                            Text(tokens).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .disabled(!canExpand)
                .accessibilityValue(canExpand ? L10n.string(isExpanded
                    ? "chat.compaction.expanded" : "chat.compaction.collapsed") : "")
                .accessibilityIdentifier("compaction-record-toggle")
                if compaction.status == .failed, let onRetry {
                    Button(L10n.string("chat.compaction.retry"), action: onRetry)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("compaction-retry")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        if let reason = compaction.reason {
                            Text(L10n.string(CompactionPresentation.reasonKey(reason)))
                        }
                        if let cost = compaction.cost {
                            Text(L10n.format(cost.source == "provider"
                                ? "chat.compaction.cost.billed" : "chat.compaction.cost.estimated",
                                String(format: "%.4f %@", cost.amount, cost.currency.uppercased())))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    if let summary = compaction.summary, !summary.isEmpty {
                        AssistantMarkdownView(text: summary, isStreaming: false)
                            .markdownTheme(Theme.gitHub.text {
                                FontSize(12)
                                ForegroundColor(.secondary)
                                BackgroundColor(nil)
                            })
                            .textSelection(.enabled)
                        HStack(alignment: .top, spacing: 16) {
                            Text(L10n.string("chat.compaction.explanation"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Button {
                                NSPasteboard.general.clearContents()
                                isCopied = NSPasteboard.general.setString(summary, forType: .string)
                            } label: {
                                Label(L10n.string(isCopied ? "chat.compaction.copied" : "chat.compaction.copy"),
                                      systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("compaction-copy")
                        }
                    }
                    if let error = compaction.errorMessage {
                        Text(error).font(.system(size: 11)).textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    if compaction.willRetry == true {
                        Text(L10n.string("chat.compaction.will_retry"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, 16)
            }
            Divider()
        }
        .accessibilityIdentifier("compaction-record")
    }
}
