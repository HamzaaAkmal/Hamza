import SwiftUI

struct PipelineProgressSheet: View {
    @EnvironmentObject private var app: AppModel
    @State private var heartbeatCount = 0
    @State private var restartAttempted = false
    let signalId: UUID
    let isProcessing: Bool
    let response: [String: JSONValue]?
    let error: String?
    let onDismiss: () -> Void

    private let expectedAgents = [
        "Signal Normalizer Agent",
        "Geo Resolver Agent",
        "Evidence Agent",
        "Crisis Detector Agent",
        "Severity Agent",
        "Response Planner Agent",
        "Simulation Agent",
        "Trace Agent",
    ]

    private var signal: Signal? {
        app.repository.signal(id: signalId)
    }

    private var run: AgentRun? {
        app.repository.run(for: signalId)
    }

    private var logs: [AgentLog] {
        guard let run else { return [] }
        return app.repository.logs(for: run)
    }

    private var toolCalls: [ToolCallRecord] {
        guard let run else { return [] }
        return app.repository.toolCalls(for: run)
    }

    private var incident: Incident? {
        if let id = response?["incident_id"]?.uuidValue {
            return app.repository.incident(id: id)
        }
        return app.repository.incident(for: run)
    }

    private var acceptedRunId: UUID? {
        response?["run_id"]?.uuidValue
    }

    private var hasFinalResponse: Bool {
        response?["status"]?.stringValue == "completed" || response?["incident_id"]?.uuidValue != nil
    }

    private var isFinished: Bool {
        run?.status == "completed" || run?.status == "failed" || hasFinalResponse || error != nil
    }

    private var isCurrentRunStale: Bool {
        guard let run, run.status == "running" || run.status == "queued" else { return false }
        let latestActivity = logs.last?.completedAt ?? logs.last?.createdAt ?? run.startedAt
        return Date().timeIntervalSince(latestActivity) > 120
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    signalCard
                    stepTimeline
                    liveTrace
                    finalOutput
                }
                .padding(.horizontal)
                .padding(.bottom, 28)
            }
            .background(AppTheme.surface)
            .navigationTitle("Agent Pipeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isFinished ? "Done" : "Hide") {
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: signalId) {
            await heartbeatReload()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                HeartbeatView(isActive: !isFinished)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(AppTheme.ink)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                StatusPill(status: run?.status ?? (isProcessing ? "running" : "submitted"))
            }

            ProgressView(value: progress)
                .tint(AppTheme.blue)

            HStack {
                Label(app.realtime.isConnected ? "Realtime connected" : "Heartbeat polling", systemImage: app.realtime.isConnected ? "dot.radiowaves.left.and.right" : "heart.fill")
                Spacer()
                Text("\(Int(progress * 100))%")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.blue)
        }
        .padding(.top, 12)
        .ciroCard()
    }

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Submitted Signal", systemImage: "paperplane.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                StatusPill(status: signal?.status ?? "submitted")
            }

            Text(signal?.reportText ?? "Waiting for signal row...")
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let normalized = app.repository.normalizedSignal(for: signalId) {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Normalized")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.blue)
                    Text(normalized.normalizedText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .ciroCard()
    }

    private var stepTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Steps")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            ForEach(expectedAgents, id: \.self) { agent in
                let log = logs.last { $0.agentName == agent }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: stepIcon(for: log))
                        .foregroundStyle(stepColor(for: log))
                        .frame(width: 28, height: 28)
                        .background(stepColor(for: log).opacity(0.12))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(agent)
                                .font(.subheadline.bold())
                                .foregroundStyle(AppTheme.ink)
                            Spacer()
                            StatusPill(status: log?.status ?? "waiting")
                        }
                        Text(log?.message ?? expectedMessage(for: agent))
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .ciroCard()
    }

    private var liveTrace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Live Trace")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(logs.count) logs • \(toolCalls.count) tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.blue)
            }

            if logs.isEmpty && toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(run == nil ? "Waiting for the backend to create the agent run..." : "Run created. Waiting for the first agent log...")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)

                    if restartAttempted && run == nil {
                        Label("Restart requested automatically. If this remains here, deploy the latest ciro-agent function.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.warning)
                        Button {
                            Task {
                                await app.repository.ensureProcessingStarted(for: signalId, acceptedRunId: acceptedRunId, force: true)
                            }
                        } label: {
                            Label("Retry Start Now", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.blue)
                    } else if isCurrentRunStale {
                        Label("This step has not written a heartbeat for more than 2 minutes. CrisisX will start a recovery run.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.warning)
                    } else if run == nil && heartbeatCount >= 3 {
                        Label("No run row yet. CrisisX will retry the orchestrator start.", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.blue)
                    }
                }
            } else {
                ForEach(logs.suffix(6)) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(log.agentName)
                                .font(.caption.bold())
                                .foregroundStyle(AppTheme.blue)
                            Spacer()
                            Text(log.createdAt.compactTime)
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                        }
                        Text(log.message ?? log.step.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption)
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                if !toolCalls.isEmpty {
                    Divider()
                    ForEach(toolCalls.suffix(4)) { call in
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .foregroundStyle(AppTheme.blue)
                            Text(call.toolName.replacingOccurrences(of: "_", with: " "))
                                .font(.caption.bold())
                                .foregroundStyle(AppTheme.ink)
                            Spacer()
                            StatusPill(status: call.status)
                        }
                    }
                }
            }
        }
        .ciroCard()
    }

    @ViewBuilder
    private var finalOutput: some View {
        if let error {
            VStack(alignment: .leading, spacing: 10) {
                Label("Pipeline failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.danger)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .ciroCard()
        } else if run?.status == "failed" {
            VStack(alignment: .leading, spacing: 10) {
                Label("Pipeline stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.danger)
                Text(logs.last(where: { $0.status == "failed" })?.error ?? app.repository.lastError ?? "The backend marked this run as failed.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .ciroCard()
        } else if let incident {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent Output")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SeverityBadge(severity: incident.severity)
                        StatusPill(status: incident.status)
                        Spacer()
                        Text("\(Int(incident.confidence * 100))% confidence")
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.blue)
                    }
                    Text(incident.title)
                        .font(.title3.bold())
                        .foregroundStyle(AppTheme.ink)
                    Text(incident.description ?? incident.category.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                outputCounts(for: incident)

                NavigationLink {
                    IncidentDetailScreen(incidentId: incident.id)
                } label: {
                    Label("Open Full Incident", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .ciroCard()
        } else if isFinished {
            VStack(alignment: .leading, spacing: 10) {
                Label("Pipeline completed", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.success)
                Text("Final incident output is syncing from Supabase. Keep this sheet open for the heartbeat refresh.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
            }
            .ciroCard()
        }
    }

    private func outputCounts(for incident: Incident) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(title: "Evidence", value: "\(app.repository.evidence(for: incident).count)", icon: "doc.text.magnifyingglass")
            StatTile(title: "Actions", value: "\(app.repository.actions(for: incident).count)", icon: "checklist")
            StatTile(title: "Alerts", value: "\(app.repository.alerts(for: incident).count)", icon: "bell.badge.fill")
            StatTile(title: "Tickets", value: "\(app.repository.tickets(for: incident).count)", icon: "ticket.fill")
        }
    }

    private var title: String {
        if error != nil || run?.status == "failed" { return "Pipeline needs attention" }
        if isFinished { return "Agent pipeline complete" }
        return "Agents are working"
    }

    private var subtitle: String {
        if let run {
            return "Run \(run.id.uuidString.prefix(8)) • \(run.startedAt.shortRelative)"
        }
        if let runId = response?["run_id"]?.stringValue {
            return "Start accepted. Waiting for run \(runId.prefix(8)) to sync."
        }
        return "Signal saved. Waiting for orchestrator heartbeat."
    }

    private var progress: Double {
        if error != nil { return min(0.92, Double(completedAgentCount) / Double(expectedAgents.count)) }
        if isFinished { return 1 }
        return max(0.08, Double(completedAgentCount) / Double(expectedAgents.count))
    }

    private var completedAgentCount: Int {
        Set(logs.filter { $0.status == "completed" }.map(\.agentName)).count
    }

    private func heartbeatReload() async {
        while !Task.isCancelled {
            await app.repository.loadPipelineState(for: signalId, acceptedRunId: acceptedRunId)
            if !restartAttempted && (run == nil && heartbeatCount >= 4 || isCurrentRunStale) {
                restartAttempted = true
                await app.repository.ensureProcessingStarted(for: signalId, acceptedRunId: acceptedRunId, force: isCurrentRunStale)
            }
            if isFinished {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await app.repository.loadPipelineState(for: signalId, acceptedRunId: acceptedRunId)
                return
            }
            heartbeatCount += 1
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func stepIcon(for log: AgentLog?) -> String {
        switch log?.status {
        case "completed": return "checkmark"
        case "failed": return "xmark"
        case "running": return "ellipsis"
        default: return "clock"
        }
    }

    private func stepColor(for log: AgentLog?) -> Color {
        switch log?.status {
        case "completed": return AppTheme.success
        case "failed": return AppTheme.danger
        case "running": return AppTheme.warning
        default: return AppTheme.muted
        }
    }

    private func expectedMessage(for agent: String) -> String {
        switch agent {
        case "Signal Normalizer Agent": return "Cleaning noisy English, Urdu, or Roman Urdu report text."
        case "Geo Resolver Agent": return "Resolving landmarks and coordinates."
        case "Evidence Agent": return "Collecting weather, route, and latest web/news context."
        case "Crisis Detector Agent": return "Clustering nearby recent signals into an incident."
        case "Severity Agent": return "Combining rules and AI explanation into severity and confidence."
        case "Response Planner Agent": return "Creating coordinated response actions."
        case "Simulation Agent": return "Executing safe mock response records and metrics."
        case "Trace Agent": return "Writing final audit trace."
        default: return "Waiting for agent log."
        }
    }
}

private struct HeartbeatView: View {
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.blue.opacity(isActive ? 0.16 : 0.10))
                .frame(width: pulse && isActive ? 68 : 48, height: pulse && isActive ? 68 : 48)
            Circle()
                .fill(AppTheme.blue)
                .frame(width: 44, height: 44)
            Image(systemName: isActive ? "heart.fill" : "checkmark.seal.fill")
                .foregroundStyle(.white)
                .font(.title3.bold())
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}
