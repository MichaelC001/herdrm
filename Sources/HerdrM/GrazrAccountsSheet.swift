import HerdrKit
import SwiftUI

/// Every Claude account grazr rotates through on one device, with what each
/// has left in its 5-hour, weekly and per-model windows.
struct GrazrAccountsSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var report: GrazrReport?
    @State private var failure: String?
    @State private var loading = false
    @State private var swapping = false

    private var swapAction: PluginAction? {
        model.session(device.id).pluginActions
            .first { $0.pluginID == Grazr.pluginID }?
            .actions.first { $0.actionID == Grazr.swapActionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "person.2",
                title: String(localized: "Claude Accounts"),
                subtitle: subtitle
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            content
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 520)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                if loading || swapping {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let swapAction {
                    Button("Swap to Next Account") {
                        swapping = true
                        model.runPluginAction(swapAction, on: device, target: nil) {
                            swapping = false
                            Task { await load() }
                        }
                    }
                    .disabled(swapping)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .task { await load() }
    }

    private var subtitle: String {
        guard let report else { return device.name }
        var parts = [
            device.name,
            String(localized: "swaps below \(report.sessionThreshold)% 5h · \(report.weeklyThreshold)% week"),
        ]
        if !report.enabled { parts.append(String(localized: "automatic swaps off")) }
        if report.dryRun { parts.append(String(localized: "dry run")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            message(failure, systemImage: "exclamationmark.triangle")
        } else if let report {
            if !report.installed {
                message(String(localized: "grazr is not installed on \(device.name)."), systemImage: "person.crop.circle.badge.questionmark")
            } else if report.accounts.isEmpty {
                message(String(localized: "No accounts enrolled yet."), systemImage: "person.crop.circle.badge.plus")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(report.sortedAccounts) { account in
                            GrazrAccountCard(
                                report: report,
                                account: account,
                                now: Date(),
                                switching: swapping,
                                onSwitch: { switchTo(account) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func switchTo(_ account: GrazrAccount) {
        swapping = true
        model.switchGrazrAccount(account, on: device) {
            swapping = false
            Task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let output = try await DeviceFileService(device: device).run(Grazr.readerCommand)
            report = try JSONDecoder().decode(GrazrReport.self, from: output)
            failure = nil
        } catch {
            failure = String(localized: "Could not read grazr's accounts on \(device.name): \(error.localizedDescription)")
        }
    }
}

private struct GrazrAccountCard: View {
    let report: GrazrReport
    let account: GrazrAccount
    let now: Date
    let switching: Bool
    let onSwitch: () -> Void

    private var isActive: Bool { account.id == report.active }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.statsAccount : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isActive { badge(String(localized: "Active"), color: Theme.success) }
                if let block = report.block(for: account, now: now) {
                    badge(String(localized: "Blocked: \(block.reason)"), color: Theme.danger)
                }
                if !report.isListed(account) {
                    badge(String(localized: "Not in ACCOUNTS"), color: Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if report.canSwitch(to: account, now: now) {
                    Button("Switch", action: onSwitch)
                        .controlSize(.small)
                        .disabled(switching)
                }
            }
            if let organization = account.organization, organization != "\(account.name)'s Organization" {
                Text(organization)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 5) {
                ForEach(Array(account.sortedWindows.enumerated()), id: \.offset) { _, window in
                    windowRow(window)
                }
            }

            if let updated = account.updated {
                Text("Reading from \(Self.relative(Date(timeIntervalSince1970: updated), now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Theme.itemWashSelected : Theme.itemWash)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Theme.statsAccount.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    private func windowRow(_ window: GrazrWindow) -> some View {
        let left = window.left(now: now)
        let color = tint(left: left, threshold: report.threshold(for: window))
        return HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            ProgressView(value: Double(left), total: 100)
                .progressViewStyle(.linear)
                .tint(color)
            Text("\(left)% left")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 62, alignment: .trailing)
            Text(resetText(window))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private func tint(left: Int, threshold: Int?) -> Color {
        if left <= 2 { return Theme.danger }
        if let threshold, left < threshold { return Theme.warning }
        return Theme.success
    }

    private func resetText(_ window: GrazrWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "" }
        guard window.isOpen(now: now) else { return String(localized: "reset since") }
        let format = Calendar.current.isDate(resetsAt, inSameDayAs: now)
            ? Date.FormatStyle().hour().minute()
            : Date.FormatStyle().weekday(.abbreviated).hour().minute()
        return String(localized: "resets \(resetsAt.formatted(format))")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
