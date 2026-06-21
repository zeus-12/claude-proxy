import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var controller: ProxyController
    @State private var editing: ProxyInstance?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !controller.claudeAvailable {
                warningBanner
            }

            if controller.instances.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(controller.instances) { instance in
                            InstanceRow(
                                instance: instance,
                                status: controller.status(for: instance.id),
                                onToggle: { controller.toggle(instance.id) },
                                onEdit: { editing = instance },
                                onDelete: { controller.remove(instance.id) }
                            )
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            footer
        }
        .frame(width: 360, height: 460)
        .sheet(item: $editing) { instance in
            InstanceEditView(instance: instance) { updated in
                controller.update(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text("Claude Proxy").font(.headline)
            Spacer()
            Button {
                controller.addInstance()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a new proxy instance")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("\(runningCount) running")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(12)
    }

    private var warningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("`claude` CLI not found on your login PATH. Install Claude Code and log in.")
                .font(.caption)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("No proxy instances yet").foregroundStyle(.secondary)
            Button("Add Instance") { controller.addInstance() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var runningCount: Int {
        controller.instances.filter { controller.status(for: $0.id).isActive }.count
    }
}

private struct InstanceRow: View {
    let instance: ProxyInstance
    let status: InstanceStatus
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusDot
                Text(instance.name).font(.system(.body, design: .rounded)).bold()
                Spacer()
                Text(instance.model)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }

            HStack(spacing: 6) {
                Text(instance.baseURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instance.baseURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy base URL")
            }

            if case .failed(let message) = status {
                Text(message).font(.caption2).foregroundStyle(.red)
            }

            HStack {
                Button(status.isActive ? "Stop" : "Start", action: onToggle)
                    .controlSize(.small)
                Button("Edit", action: onEdit)
                    .controlSize(.small)
                    .disabled(status.isActive)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: Color {
        switch status {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}
