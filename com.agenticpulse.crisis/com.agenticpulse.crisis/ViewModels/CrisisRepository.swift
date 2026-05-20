import Foundation
import Combine

@MainActor
final class CrisisRepository: ObservableObject {
    @Published var signals: [Signal] = []
    @Published var normalizedSignals: [NormalizedSignal] = []
    @Published var incidents: [Incident] = []
    @Published var evidence: [IncidentEvidence] = []
    @Published var agentRuns: [AgentRun] = []
    @Published var agentLogs: [AgentLog] = []
    @Published var toolCalls: [ToolCallRecord] = []
    @Published var actions: [ResponseAction] = []
    @Published var simulationRuns: [SimulationRun] = []
    @Published var simulationMetrics: [SimulationMetric] = []
    @Published var alerts: [MockAlert] = []
    @Published var tickets: [EmergencyTicket] = []
    @Published var resources: [ResourceItem] = []
    @Published var blockedSegments: [BlockedSegment] = []
    @Published var routeOptions: [RouteOption] = []
    @Published var systemStatus: [SystemStatus] = []
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var hasLoadedOnce = false
    @Published var isRunningAgent = false
    @Published var isShowingCachedData = false
    @Published var lastCacheSavedAt: Date?
    @Published var lastError: String?

    private let api: SupabaseService
    private let realtime: SupabaseRealtimeService
    private var reloadTask: Task<Void, Never>?
    private var isReloadInFlight = false
    private var hasAttemptedCacheRestore = false

    init(api: SupabaseService, realtime: SupabaseRealtimeService) {
        self.api = api
        self.realtime = realtime
    }

    func start() async {
        restoreCachedSnapshotIfNeeded()
        await loadAll()
        realtime.connect(tables: realtimeTables, accessToken: api.accessToken) { [weak self] _ in
            self?.scheduleReload()
        }
    }

    func reset() {
        reloadTask?.cancel()
        signals = []
        normalizedSignals = []
        incidents = []
        evidence = []
        agentRuns = []
        agentLogs = []
        toolCalls = []
        actions = []
        simulationRuns = []
        simulationMetrics = []
        alerts = []
        tickets = []
        resources = []
        blockedSegments = []
        routeOptions = []
        systemStatus = []
        isLoading = false
        isRefreshing = false
        hasLoadedOnce = false
        isShowingCachedData = false
        lastCacheSavedAt = nil
        isReloadInFlight = false
        hasAttemptedCacheRestore = false
        lastError = nil
        clearCachedSnapshot()
    }

    func loadAll() async {
        restoreCachedSnapshotIfNeeded()
        guard !isReloadInFlight else { return }
        isReloadInFlight = true
        let isInitialLoad = !hasLoadedOnce
        if isInitialLoad {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            isReloadInFlight = false
            isLoading = false
            isRefreshing = false
            hasLoadedOnce = true
        }

        var refreshErrors: [String] = []

        func refresh<T: Decodable>(
            _ label: String,
            operation: () async throws -> [T],
            assign: ([T]) -> Void
        ) async {
            do {
                assign(try await operation())
            } catch {
                refreshErrors.append("\(label): \(error.localizedDescription)")
            }
        }

        await refresh("signals", operation: {
            try await api.fetch(table: "signals", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "80"),
            ])
        }, assign: { (items: [Signal]) in signals = items })

        await refresh("incidents", operation: {
            try await api.fetch(table: "incidents", queryItems: [
                URLQueryItem(name: "order", value: "updated_at.desc"),
                URLQueryItem(name: "limit", value: "80"),
            ])
        }, assign: { (items: [Incident]) in incidents = items })

        await refresh("response actions", operation: {
            try await api.fetch(table: "response_actions", queryItems: [
                URLQueryItem(name: "order", value: "updated_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [ResponseAction]) in actions = items })

        await refresh("agent runs", operation: {
            try await api.fetch(table: "agent_runs", queryItems: [
                URLQueryItem(name: "order", value: "started_at.desc"),
                URLQueryItem(name: "limit", value: "60"),
            ])
        }, assign: { (items: [AgentRun]) in agentRuns = items })

        await refresh("agent logs", operation: {
            try await api.fetch(table: "agent_logs", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "180"),
            ])
        }, assign: { (items: [AgentLog]) in agentLogs = items })

        await refresh("tool calls", operation: {
            try await api.fetch(table: "tool_calls", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "180"),
            ])
        }, assign: { (items: [ToolCallRecord]) in toolCalls = items })

        await refresh("system status", operation: {
            try await api.fetch(table: "system_status", queryItems: [
                URLQueryItem(name: "order", value: "updated_at.desc"),
            ])
        }, assign: { (items: [SystemStatus]) in systemStatus = items })

        await refresh("normalized signals", operation: {
            try await api.fetch(table: "normalized_signals", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "80"),
            ])
        }, assign: { (items: [NormalizedSignal]) in normalizedSignals = items })

        await refresh("evidence", operation: {
            try await api.fetch(table: "incident_evidence", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [IncidentEvidence]) in evidence = items })

        await refresh("route options", operation: {
            try await api.fetch(table: "route_options", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [RouteOption]) in routeOptions = items })

        await refresh("blocked segments", operation: {
            try await api.fetch(table: "blocked_segments", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [BlockedSegment]) in blockedSegments = items })

        await refresh("simulation runs", operation: {
            try await api.fetch(table: "simulation_runs", queryItems: [
                URLQueryItem(name: "order", value: "started_at.desc"),
                URLQueryItem(name: "limit", value: "80"),
            ])
        }, assign: { (items: [SimulationRun]) in simulationRuns = items })

        await refresh("simulation metrics", operation: {
            try await api.fetch(table: "simulation_metrics", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [SimulationMetric]) in simulationMetrics = items })

        await refresh("mock alerts", operation: {
            try await api.fetch(table: "mock_alerts", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [MockAlert]) in alerts = items })

        await refresh("emergency tickets", operation: {
            try await api.fetch(table: "emergency_tickets", queryItems: [
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [EmergencyTicket]) in tickets = items })

        await refresh("resources", operation: {
            try await api.fetch(table: "resources", queryItems: [
                URLQueryItem(name: "order", value: "updated_at.desc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
        }, assign: { (items: [ResourceItem]) in resources = items })

        if refreshErrors.isEmpty {
            lastError = nil
            isShowingCachedData = false
            persistCachedSnapshot()
        } else {
            let summary = refreshErrors.prefix(2).joined(separator: "; ")
            if hasRenderableData || lastCacheSavedAt != nil {
                isShowingCachedData = true
                lastError = nil
            } else {
                lastError = "Some data could not refresh: \(summary)"
            }
        }
    }

    func createReportSignal(text: String, locationText: String, category: String, urgency: Int) async throws -> Signal {
        guard let userId = api.session?.user.id else {
            lastError = "Sign in before submitting reports."
            throw APIError.server(status: 401, message: "Sign in before submitting reports.")
        }

        lastError = nil
        let signal: Signal = try await api.insertReturning(table: "signals", values: [
            "submitted_by": userId.uuidString,
            "source_type": "user_report",
            "report_text": text,
            "category": category,
            "urgency": urgency,
            "location_text": locationText,
            "raw_payload": [
                "client": "CrisisX iOS",
                "submitted_at": ISO8601DateFormatter.standard.string(from: Date()),
            ],
        ])
        await loadAll()
        return signal
    }

    @discardableResult
    func processSignal(_ signalId: UUID, retryCount: Int = 0) async throws -> [String: JSONValue] {
        isRunningAgent = true
        lastError = nil
        defer { isRunningAgent = false }

        do {
            let output = try await api.invokeFunction("ciro-agent", body: [
                "action": "start_processing",
                "signal_id": signalId.uuidString,
            ])
            await loadPipelineState(for: signalId, acceptedRunId: output["run_id"]?.uuidValue)
            return output
        } catch let error as APIError {
            // If timeout and haven't retried yet, try once more
            if case .server(let status, let message) = error, status == -1, message.contains("timed out"), retryCount < 1 {
                lastError = "Agent orchestrator timed out, retrying..."
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2 seconds
                return try await processSignal(signalId, retryCount: retryCount + 1)
            }
            throw error
        }
    }

    func ensureProcessingStarted(for signalId: UUID, acceptedRunId: UUID? = nil, force: Bool = false) async {
        guard force || run(for: signalId)?.status != "running" else {
            await loadPipelineState(for: signalId, acceptedRunId: acceptedRunId)
            return
        }

        do {
            let output = try await api.invokeFunction("ciro-agent", body: [
                "action": "start_processing",
                "signal_id": signalId.uuidString,
            ])
            await loadPipelineState(for: signalId, acceptedRunId: output["run_id"]?.uuidValue ?? acceptedRunId)
        } catch {
            lastError = "Could not start orchestrator: \(error.localizedDescription)"
        }
    }

    func loadPipelineState(for signalId: UUID, acceptedRunId: UUID? = nil) async {
        do {
            let matchingSignals: [Signal] = try await api.fetch(table: "signals", queryItems: [
                URLQueryItem(name: "id", value: "eq.\(signalId.uuidString)"),
                URLQueryItem(name: "limit", value: "1"),
            ])
            merge(matchingSignals, into: &signals)

            let matchingNormalized: [NormalizedSignal] = try await api.fetch(table: "normalized_signals", queryItems: [
                URLQueryItem(name: "signal_id", value: "eq.\(signalId.uuidString)"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "3"),
            ])
            merge(matchingNormalized, into: &normalizedSignals)

            let matchingRuns: [AgentRun] = try await api.fetch(table: "agent_runs", queryItems: [
                URLQueryItem(name: "trigger_type", value: "eq.signal"),
                URLQueryItem(name: "trigger_id", value: "eq.\(signalId.uuidString)"),
                URLQueryItem(name: "order", value: "started_at.desc"),
                URLQueryItem(name: "limit", value: "3"),
            ])
            merge(matchingRuns, into: &agentRuns)

            if let acceptedRunId {
                let directRuns: [AgentRun] = try await api.fetch(table: "agent_runs", queryItems: [
                    URLQueryItem(name: "id", value: "eq.\(acceptedRunId.uuidString)"),
                    URLQueryItem(name: "limit", value: "1"),
                ])
                merge(directRuns, into: &agentRuns)
            }

            guard let run = matchingRuns.first ?? run(for: signalId) ?? acceptedRunId.flatMap({ id in agentRuns.first { $0.id == id } }) else {
                lastError = nil
                return
            }

            let matchingLogs: [AgentLog] = try await api.fetch(table: "agent_logs", queryItems: [
                URLQueryItem(name: "agent_run_id", value: "eq.\(run.id.uuidString)"),
                URLQueryItem(name: "order", value: "created_at.asc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
            merge(matchingLogs, into: &agentLogs)

            let matchingTools: [ToolCallRecord] = try await api.fetch(table: "tool_calls", queryItems: [
                URLQueryItem(name: "agent_run_id", value: "eq.\(run.id.uuidString)"),
                URLQueryItem(name: "order", value: "created_at.asc"),
                URLQueryItem(name: "limit", value: "120"),
            ])
            merge(matchingTools, into: &toolCalls)

            if let incidentId = run.outputPayload["incident_id"]?.uuidValue {
                let matchingIncidents: [Incident] = try await api.fetch(table: "incidents", queryItems: [
                    URLQueryItem(name: "id", value: "eq.\(incidentId.uuidString)"),
                    URLQueryItem(name: "limit", value: "1"),
                ])
                merge(matchingIncidents, into: &incidents)
            }
            lastError = nil
        } catch {
            lastError = "Pipeline heartbeat could not refresh: \(error.localizedDescription)"
        }
    }

    func submitReport(text: String, locationText: String, category: String, urgency: Int) async {
        do {
            let signal = try await createReportSignal(text: text, locationText: locationText, category: category, urgency: urgency)
            try await processSignal(signal.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func runSimulation(for incident: Incident) async {
        isRunningAgent = true
        lastError = nil
        defer { isRunningAgent = false }

        do {
            _ = try await api.invokeFunction("ciro-agent", body: [
                "action": "run_simulation",
                "incident_id": incident.id.uuidString,
                "scenario": "manual_safe_response_execution",
            ])
            await loadAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func generateBackendSignal(location: String, category: String, urgency: Int) async {
        isRunningAgent = true
        lastError = nil
        defer { isRunningAgent = false }

        do {
            _ = try await api.invokeFunction("ciro-agent", body: [
                "action": "generate_api_signal",
                "location_text": location,
                "category": category,
                "urgency": urgency,
                "region_bias": "PK",
            ])
            await loadAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateAction(_ action: ResponseAction, status: String) async {
        do {
            let updated: ResponseAction = try await api.updateReturning(table: "response_actions", id: action.id, values: ["status": status])
            if let index = actions.firstIndex(where: { $0.id == updated.id }) {
                actions[index] = updated
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func evidence(for incident: Incident) -> [IncidentEvidence] {
        evidence.filter { $0.incidentId == incident.id }
    }

    func actions(for incident: Incident) -> [ResponseAction] {
        actions.filter { $0.incidentId == incident.id }.sorted { $0.priority > $1.priority }
    }

    func logs(for run: AgentRun) -> [AgentLog] {
        agentLogs.filter { $0.agentRunId == run.id }.sorted { $0.createdAt < $1.createdAt }
    }

    func toolCalls(for run: AgentRun) -> [ToolCallRecord] {
        toolCalls.filter { $0.agentRunId == run.id }.sorted { $0.createdAt < $1.createdAt }
    }

    func run(for signalId: UUID) -> AgentRun? {
        agentRuns.first { $0.triggerId == signalId && $0.triggerType == "signal" }
    }

    var hasActiveAgentRuns: Bool {
        let recentCutoff = Date().addingTimeInterval(-10 * 60)
        return isRunningAgent || agentRuns.contains {
            ($0.status == "queued" || $0.status == "running") &&
            $0.endedAt == nil &&
            $0.startedAt > recentCutoff
        }
    }

    func isRunActive(for signalId: UUID?) -> Bool {
        guard let signalId else { return false }
        let recentCutoff = Date().addingTimeInterval(-10 * 60)
        return agentRuns.contains {
            $0.triggerId == signalId &&
            $0.triggerType == "signal" &&
            ($0.status == "queued" || $0.status == "running") &&
            $0.endedAt == nil &&
            $0.startedAt > recentCutoff
        }
    }

    func signal(id: UUID) -> Signal? {
        signals.first { $0.id == id }
    }

    func normalizedSignal(for signalId: UUID) -> NormalizedSignal? {
        normalizedSignals.first { $0.signalId == signalId }
    }

    func incident(id: UUID?) -> Incident? {
        guard let id else { return nil }
        return incidents.first { $0.id == id }
    }

    func incident(for run: AgentRun?) -> Incident? {
        guard let run else { return nil }
        return incident(id: run.outputPayload["incident_id"]?.uuidValue)
    }

    func logs(for incident: Incident) -> [AgentLog] {
        let runIds = Set(agentRuns.filter { $0.outputPayload["incident_id"]?.stringValue == incident.id.uuidString || $0.triggerId == incident.id }.map(\.id))
        return agentLogs.filter { runIds.contains($0.agentRunId) }.sorted { $0.createdAt < $1.createdAt }
    }

    func simulations(for incident: Incident) -> [SimulationRun] {
        simulationRuns.filter { $0.incidentId == incident.id }.sorted { $0.startedAt > $1.startedAt }
    }

    func metrics(for incident: Incident) -> [SimulationMetric] {
        simulationMetrics.filter { $0.incidentId == incident.id }
    }

    func alerts(for incident: Incident) -> [MockAlert] {
        alerts.filter { $0.incidentId == incident.id }
    }

    func tickets(for incident: Incident) -> [EmergencyTicket] {
        tickets.filter { $0.incidentId == incident.id }
    }

    func routes(for incident: Incident) -> [RouteOption] {
        routeOptions.filter { $0.incidentId == incident.id }
    }

    func blockedSegments(for incident: Incident) -> [BlockedSegment] {
        blockedSegments.filter { $0.incidentId == incident.id }
    }
    
    var isAgentOrchestratorHealthy: Bool {
        guard let orchestratorStatus = systemStatus.first(where: { $0.statusKey == "agent_orchestrator" }) else {
            return true // Assume healthy if no status yet
        }
        return orchestratorStatus.status == "healthy"
    }
    
    var agentOrchestratorMessage: String? {
        systemStatus.first(where: { $0.statusKey == "agent_orchestrator" })?.message
    }

    private var hasRenderableData: Bool {
        !signals.isEmpty ||
        !incidents.isEmpty ||
        !actions.isEmpty ||
        !agentLogs.isEmpty ||
        !tickets.isEmpty ||
        !resources.isEmpty ||
        !systemStatus.isEmpty
    }

    private func restoreCachedSnapshotIfNeeded() {
        guard !hasAttemptedCacheRestore else { return }
        hasAttemptedCacheRestore = true

        do {
            let data = try Data(contentsOf: cacheFileURL())
            let snapshot = try JSONDecoder.supabase.decode(RepositorySnapshot.self, from: data)
            apply(snapshot)
            hasLoadedOnce = true
            isShowingCachedData = true
            lastCacheSavedAt = snapshot.savedAt
            lastError = nil
        } catch {
            apply(.demoFallback)
            hasLoadedOnce = true
            isShowingCachedData = true
            lastCacheSavedAt = nil
            lastError = nil
        }
    }

    private func persistCachedSnapshot() {
        guard hasRenderableData else { return }

        do {
            let savedAt = Date()
            let data = try JSONEncoder.supabase.encode(RepositorySnapshot(
                savedAt: savedAt,
                signals: signals,
                normalizedSignals: normalizedSignals,
                incidents: incidents,
                evidence: evidence,
                agentRuns: agentRuns,
                agentLogs: agentLogs,
                toolCalls: toolCalls,
                actions: actions,
                simulationRuns: simulationRuns,
                simulationMetrics: simulationMetrics,
                alerts: alerts,
                tickets: tickets,
                resources: resources,
                blockedSegments: blockedSegments,
                routeOptions: routeOptions,
                systemStatus: systemStatus
            ))
            try data.write(to: cacheFileURL(), options: [.atomic])
            lastCacheSavedAt = savedAt
        } catch {
            lastError = "Live data loaded, but local cache could not be updated: \(error.localizedDescription)"
        }
    }

    private func clearCachedSnapshot() {
        guard let url = try? cacheFileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func apply(_ snapshot: RepositorySnapshot) {
        signals = snapshot.signals
        normalizedSignals = snapshot.normalizedSignals
        incidents = snapshot.incidents
        evidence = snapshot.evidence
        agentRuns = snapshot.agentRuns
        agentLogs = snapshot.agentLogs
        toolCalls = snapshot.toolCalls
        actions = snapshot.actions
        simulationRuns = snapshot.simulationRuns
        simulationMetrics = snapshot.simulationMetrics
        alerts = snapshot.alerts
        tickets = snapshot.tickets
        resources = snapshot.resources
        blockedSegments = snapshot.blockedSegments
        routeOptions = snapshot.routeOptions
        systemStatus = snapshot.systemStatus
    }

    private func cacheFileURL() throws -> URL {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw APIError.invalidResponse
        }
        let directory = baseURL.appendingPathComponent("CrisisX", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("repository-cache.json")
    }

    private func merge<T: Identifiable>(_ incoming: [T], into current: inout [T]) where T.ID == UUID {
        for item in incoming {
            if let index = current.firstIndex(where: { $0.id == item.id }) {
                current[index] = item
            } else {
                current.append(item)
            }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await self?.loadAll()
        }
    }

    private var realtimeTables: [String] {
        [
            "signals",
            "normalized_signals",
            "incidents",
            "incident_evidence",
            "agent_runs",
            "agent_logs",
            "tool_calls",
            "response_actions",
            "simulation_runs",
            "simulation_metrics",
            "mock_alerts",
            "emergency_tickets",
            "resources",
            "blocked_segments",
            "route_options",
            "system_status",
        ]
    }
}

private struct RepositorySnapshot: Codable {
    var savedAt: Date
    var signals: [Signal]
    var normalizedSignals: [NormalizedSignal]
    var incidents: [Incident]
    var evidence: [IncidentEvidence]
    var agentRuns: [AgentRun]
    var agentLogs: [AgentLog]
    var toolCalls: [ToolCallRecord]
    var actions: [ResponseAction]
    var simulationRuns: [SimulationRun]
    var simulationMetrics: [SimulationMetric]
    var alerts: [MockAlert]
    var tickets: [EmergencyTicket]
    var resources: [ResourceItem]
    var blockedSegments: [BlockedSegment]
    var routeOptions: [RouteOption]
    var systemStatus: [SystemStatus]
}

private extension RepositorySnapshot {
    static var demoFallback: RepositorySnapshot {
        let now = Date()
        let seedIncidents: [(String, String, String, Int, Double, Double, Double)] = [
            (
                "Stranded due to heavy snowfall and traffic congestion in Murree",
                "Family stranded during heavy snowfall; nearby road capacity is dropping and response access is constrained.",
                "weather",
                4,
                33.9070,
                73.3943,
                0.80
            ),
            (
                "Murree expressway traffic pileup near Mall Road",
                "Multiple reports mention blocked traffic, low visibility, and urgent mobility support needs.",
                "traffic",
                5,
                33.9058,
                73.3908,
                0.95
            ),
            (
                "Emergency shelter power instability",
                "Shelter operators report intermittent power and capacity pressure during severe weather response.",
                "infrastructure",
                3,
                33.9121,
                73.4015,
                0.74
            ),
        ]

        var incidents = seedIncidents.enumerated().map { index, item in
            Incident(
                id: UUID(),
                title: item.0,
                description: item.1,
                category: item.2,
                status: "active",
                severity: item.3,
                confidence: item.6,
                centroidLat: item.4,
                centroidLng: item.5,
                radiusMeters: 850 + (index * 140),
                startedAt: now.addingTimeInterval(-Double((index + 3) * 1_800)),
                lastSignalAt: now.addingTimeInterval(-Double((index + 1) * 900)),
                summary: [
                    "source": .string("local_demo_cache"),
                    "requires_safe_refresh": .bool(true),
                ],
                evidenceSummary: [
                    "signals": .number(Double(5 + index)),
                    "confidence": .number(item.6),
                ],
                assignedOwner: nil,
                createdAt: now.addingTimeInterval(-Double((index + 4) * 1_800)),
                updatedAt: now.addingTimeInterval(-Double((index + 1) * 900))
            )
        }

        let categories = ["weather", "traffic", "infrastructure", "medical"]
        for index in incidents.count..<16 {
            let category = categories[index % categories.count]
            incidents.append(Incident(
                id: UUID(),
                title: "\(category.capitalized) hotspot requiring triage \(index + 1)",
                description: "Locally cached demo incident shown instantly while CrisisX verifies Supabase data.",
                category: category,
                status: index.isMultiple(of: 5) ? "monitoring" : "active",
                severity: max(2, min(5, 2 + (index % 4))),
                confidence: 0.68 + (Double(index % 4) * 0.06),
                centroidLat: 33.88 + (Double(index % 6) * 0.008),
                centroidLng: 73.36 + (Double(index % 5) * 0.01),
                radiusMeters: 700 + (index * 35),
                startedAt: now.addingTimeInterval(-Double((index + 2) * 720)),
                lastSignalAt: now.addingTimeInterval(-Double((index + 1) * 300)),
                summary: ["source": .string("local_demo_cache")],
                evidenceSummary: ["signals": .number(Double(2 + (index % 5)))],
                assignedOwner: nil,
                createdAt: now.addingTimeInterval(-Double((index + 3) * 720)),
                updatedAt: now.addingTimeInterval(-Double((index + 1) * 300))
            ))
        }

        var signals: [Signal] = []
        for index in 0..<39 {
            let category = categories[index % categories.count]
            let reportText = index < seedIncidents.count
                ? seedIncidents[index].1
                : "Cached crisis signal \(index + 1) ready for safe Supabase reconciliation."

            signals.append(Signal(
                id: UUID(),
                submittedBy: nil,
                sourceType: index.isMultiple(of: 3) ? "backend_api" : "user_report",
                reportText: reportText,
                languageHint: "en",
                category: category,
                urgency: 2 + (index % 4),
                locationText: index.isMultiple(of: 2) ? "Murree, Pakistan" : "Nearby response zone",
                latitude: 33.88 + (Double(index % 7) * 0.007),
                longitude: 73.36 + (Double(index % 6) * 0.009),
                status: "processed",
                confidence: 0.64 + (Double(index % 5) * 0.05),
                rawPayload: [
                    "source": .string("local_demo_cache"),
                    "safe_to_replace": .bool(true),
                ],
                normalizedSignalId: nil,
                createdAt: now.addingTimeInterval(-Double((index + 1) * 180)),
                updatedAt: now.addingTimeInterval(-Double((index + 1) * 160))
            ))
        }

        let actionTypes = ["assign_resource", "reroute", "alert", "field_check"]
        var actions: [ResponseAction] = []
        for index in 0..<38 {
            let incident = incidents[index % incidents.count]
            let actionType = actionTypes[index % actionTypes.count]
            actions.append(ResponseAction(
                id: UUID(),
                incidentId: incident.id,
                actionType: actionType,
                title: "\(actionType.replacingOccurrences(of: "_", with: " ").capitalized) for \(incident.category.capitalized)",
                description: "Cached action placeholder; live planner output replaces this when Supabase refresh completes.",
                priority: max(1, min(5, incident.severity)),
                status: index.isMultiple(of: 4) ? "ready" : "queued",
                assignedTo: index.isMultiple(of: 4) ? "CrisisX Mock Dispatch" : nil,
                dueAt: nil,
                payload: [
                    "source": .string("local_demo_cache"),
                    "safe_to_replace": .bool(true),
                ],
                createdBy: nil,
                createdAt: now.addingTimeInterval(-Double((index + 2) * 240)),
                updatedAt: now.addingTimeInterval(-Double((index + 1) * 200))
            ))
        }

        return RepositorySnapshot(
            savedAt: now,
            signals: signals,
            normalizedSignals: [],
            incidents: incidents,
            evidence: [],
            agentRuns: [],
            agentLogs: [],
            toolCalls: [],
            actions: actions,
            simulationRuns: [],
            simulationMetrics: [],
            alerts: [],
            tickets: [],
            resources: [],
            blockedSegments: [],
            routeOptions: [],
            systemStatus: [
                SystemStatus(
                    statusKey: "local_cache",
                    status: "healthy",
                    message: "Instant local dashboard is active while Supabase refreshes.",
                    payload: ["source": .string("local_demo_cache")],
                    updatedAt: now
                )
            ]
        )
    }
}
