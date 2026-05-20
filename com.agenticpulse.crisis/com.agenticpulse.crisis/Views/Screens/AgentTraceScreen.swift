import SwiftUI

struct AgentTraceScreen: View {
    @EnvironmentObject private var app: AppModel
    let incidentId: UUID

    private var incident: Incident? {
        app.repository.incidents.first { $0.id == incidentId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Agent Trace",
                    subtitle: "Every agent decision and structured tool call written to Supabase.",
                    icon: "point.3.connected.trianglepath.dotted"
                )

                if app.repository.isLoading && !app.repository.hasLoadedOnce {
                    SkeletonCardList(rows: 5)
                } else if let incident {
                    let logs = app.repository.logs(for: incident)
                    let runIds = Set(logs.map(\.agentRunId))
                    let calls = app.repository.toolCalls.filter { runIds.contains($0.agentRunId) }.sorted { $0.createdAt < $1.createdAt }

                    if logs.isEmpty {
                        EmptyState(
                            icon: "waveform.path",
                            title: "Trace pending",
                            message: "Agent logs will stream here as soon as the backend pipeline starts."
                        )
                        .padding(.horizontal)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Agent Decisions")
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                                .padding(.horizontal)
                            ForEach(logs) { log in
                                AgentLogRow(log: log)
                                    .padding(.horizontal)
                            }
                        }
                    }

                    if !calls.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tool Calls")
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                                .padding(.horizontal)
                            ForEach(calls) { call in
                                ToolCallRow(call: call)
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppTheme.surface)
        .navigationTitle("Trace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await app.repository.loadAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

private struct AgentLogRow: View {
    let log: AgentLog

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(log.agentName)
                        .font(.subheadline.bold())
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    StatusPill(status: log.status)
                }
                Text(log.step.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.blue)
                if let message = log.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let confirmationId {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Confirmation \(confirmationId)", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.success)
                        if let selectedName {
                            Label(selectedName, systemImage: "person.2.badge.gearshape.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.blue)
                        }
                        if let selectionReason {
                            Text(selectionReason)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
                if let error = log.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .ciroCard()
    }

    private var confirmationId: String? {
        log.outputPayload["booking_confirmation_id"]?.stringValue
    }

    private var selectedName: String? {
        log.outputPayload["selected_provider"]?.objectValue?["name"]?.stringValue
    }

    private var selectionReason: String? {
        log.outputPayload["selection_reason"]?.stringValue
    }

    private var color: Color {
        switch log.status {
        case "completed": return AppTheme.success
        case "failed": return AppTheme.danger
        case "running": return AppTheme.warning
        default: return AppTheme.blue
        }
    }

    private var icon: String {
        switch log.agentName {
        case let name where name.contains("Geo"): return "mappin.and.ellipse"
        case let name where name.contains("Evidence"): return "magnifyingglass"
        case let name where name.contains("Severity"): return "gauge.with.dots.needle.67percent"
        case let name where name.contains("Booking"): return "checkmark.seal.fill"
        case let name where name.contains("Simulation"): return "play.rectangle.fill"
        case let name where name.contains("Trace"): return "list.clipboard.fill"
        default: return "cpu.fill"
        }
    }
}

private struct ToolCallRow: View {
    let call: ToolCallRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(AppTheme.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(call.toolName.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.ink)
                HStack {
                    StatusPill(status: call.status)
                    if let latency = call.latencyMs {
                        Text("\(latency) ms")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                    }
                    Spacer()
                    Text(call.createdAt.compactTime)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .ciroCard()
    }
}
