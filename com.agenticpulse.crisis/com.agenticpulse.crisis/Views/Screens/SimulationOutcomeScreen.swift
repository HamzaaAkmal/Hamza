import SwiftUI

struct SimulationOutcomeScreen: View {
    @EnvironmentObject private var app: AppModel
    let incidentId: UUID

    private var incident: Incident? {
        app.repository.incidents.first { $0.id == incidentId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Simulation Outcome",
                    subtitle: "Safe mock execution results. No real emergency service or map traffic systems are modified.",
                    icon: "chart.line.uptrend.xyaxis"
                )

                if app.repository.isLoading && !app.repository.hasLoadedOnce {
                    SkeletonCardList(rows: 5)
                } else if let incident {
                    Button {
                        Task { await app.repository.runSimulation(for: incident) }
                    } label: {
                        Label("Run Simulation Again", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(isDisabled: app.repository.hasActiveAgentRuns))
                    .disabled(app.repository.hasActiveAgentRuns)
                    .padding(.horizontal)

                    bookingSection(incident)
                    metricsSection(incident)
                    routeSection(incident)
                    alertsSection(incident)
                    ticketsSection(incident)
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppTheme.surface)
        .navigationTitle("Simulation")
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

    private func bookingSection(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider Booking")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal)

            let bookingTickets = app.repository.tickets(for: incident)
                .filter { $0.payload["booking_confirmation_id"]?.stringValue != nil }
                .sorted { $0.createdAt > $1.createdAt }

            if let ticket = bookingTickets.first {
                ProviderBookingCard(ticket: ticket)
                    .padding(.horizontal)
            } else {
                EmptyState(
                    icon: "person.2.badge.gearshape",
                    title: "Provider booking pending",
                    message: "The Simulation Agent ranks three mock providers and writes a safe dispatch confirmation here."
                )
                .padding(.horizontal)
            }
        }
    }

    private func metricsSection(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before vs After")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal)

            let metrics = app.repository.metrics(for: incident)
            if metrics.isEmpty {
                EmptyState(icon: "chart.bar.doc.horizontal", title: "No metrics yet", message: "The Simulation Agent writes metrics after safe mock execution.")
                    .padding(.horizontal)
            } else {
                ForEach(metrics) { metric in
                    MetricRow(metric: metric)
                        .padding(.horizontal)
                }
            }
        }
    }

    private func routeSection(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Routes and Blocked Segments")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal)

            let routes = app.repository.routes(for: incident)
            let blocks = app.repository.blockedSegments(for: incident)
            if routes.isEmpty && blocks.isEmpty {
                EmptyState(icon: "road.lanes", title: "No route layer changes", message: "Route alternatives and app-owned blocked segments will appear when route tools return data.")
                    .padding(.horizontal)
            } else {
                ForEach(routes) { route in
                    RouteRow(route: route)
                        .padding(.horizontal)
                }
                ForEach(blocks) { block in
                    BlockedSegmentRow(segment: block)
                        .padding(.horizontal)
                }
            }
        }
    }

    private func alertsSection(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mock Alerts")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal)

            let alerts = app.repository.alerts(for: incident)
            if alerts.isEmpty {
                EmptyState(icon: "bell.slash", title: "No mock alerts", message: "Alerts created by the Simulation Agent are stored here as simulated messages.")
                    .padding(.horizontal)
            } else {
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(alert.channel.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "bell.badge.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.blue)
                            Spacer()
                            StatusPill(status: alert.status)
                        }
                        Text(alert.title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        Text(alert.body)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)
                    }
                    .ciroCard()
                    .padding(.horizontal)
                }
            }
        }
    }

    private func ticketsSection(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mock Tickets")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal)

            let tickets = app.repository.tickets(for: incident)
            if tickets.isEmpty {
                EmptyState(icon: "ticket", title: "No mock tickets", message: "The app never contacts real emergency services; mock tickets are stored here.")
                    .padding(.horizontal)
            } else {
                ForEach(tickets) { ticket in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(ticket.externalRef)
                                .font(.caption.bold())
                                .foregroundStyle(AppTheme.blue)
                            Spacer()
                            StatusPill(status: ticket.status)
                        }
                        Text(ticket.summary)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        if let details = ticket.details {
                            Text(details)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.muted)
                        }
                    }
                    .ciroCard()
                    .padding(.horizontal)
                }
            }
        }
    }
}

private struct ProviderBookingCard: View {
    let ticket: EmergencyTicket

    private var confirmationId: String {
        ticket.payload["booking_confirmation_id"]?.stringValue ?? ticket.externalRef
    }

    private var selectedProvider: [String: JSONValue] {
        ticket.payload["selected_provider"]?.objectValue ?? [:]
    }

    private var rankedProviders: [[String: JSONValue]] {
        ticket.payload["ranked_providers"]?.arrayValue?
            .compactMap(\.objectValue)
            .prefix(3)
            .map { $0 } ?? []
    }

    private var selectionReason: String {
        ticket.payload["selection_reason"]?.stringValue ?? ticket.details ?? "Top provider selected from simulated ranking."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.success)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.success.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedProvider["name"]?.stringValue ?? ticket.summary)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text("Confirmation \(confirmationId)")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.blue)
                    Text(selectionReason)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusPill(status: ticket.status)
            }

            VStack(spacing: 8) {
                ForEach(Array(rankedProviders.enumerated()), id: \.offset) { _, provider in
                    ProviderRankRow(provider: provider)
                }
            }
        }
        .ciroCard()
    }
}

private struct ProviderRankRow: View {
    let provider: [String: JSONValue]

    private var rank: Int {
        Int(provider["rank"]?.doubleValue ?? 0)
    }

    private var etaText: String {
        guard let seconds = provider["eta_seconds"]?.doubleValue else { return "ETA n/a" }
        return "\(max(1, Int(seconds / 60))) min"
    }

    private var distanceText: String {
        guard let meters = provider["distance_meters"]?.doubleValue else { return "distance n/a" }
        return String(format: "%.1f km", meters / 1000)
    }

    private var scoreText: String {
        guard let score = provider["total_score"]?.doubleValue else { return "n/a" }
        return String(format: "%.2f", score)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("#\(rank)")
                .font(.caption.bold())
                .foregroundStyle(rank == 1 ? .white : AppTheme.blue)
                .frame(width: 34, height: 26)
                .background(rank == 1 ? AppTheme.blue : AppTheme.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(provider["name"]?.stringValue ?? "Mock provider")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.ink)
                Text([etaText, distanceText, provider["status"]?.stringValue?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                if let rationale = provider["rationale"]?.stringValue {
                    Text(rationale)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(scoreText)
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.blue)
                Text("score")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(10)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MetricRow: View {
    let metric: SimulationMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metric.metricName.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            HStack {
                valueBlock("Before", metric.beforeValue)
                Image(systemName: "arrow.right")
                    .foregroundStyle(AppTheme.blue)
                valueBlock("After", metric.afterValue)
                Spacer()
                if let delta = metric.delta {
                    Text(deltaString(delta))
                        .font(.caption.bold())
                        .foregroundStyle(delta <= 0 ? AppTheme.success : AppTheme.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .ciroCard()
    }

    private func valueBlock(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Text(value.map { format($0) } ?? "n/a")
                .font(.subheadline.bold())
                .foregroundStyle(AppTheme.ink)
        }
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value)) \(metric.unit ?? "")"
        }
        return String(format: "%.2f %@", value, metric.unit ?? "")
    }

    private func deltaString(_ value: Double) -> String {
        if value.rounded() == value {
            return value > 0 ? "+\(Int(value))" : "\(Int(value))"
        }
        return value > 0 ? String(format: "+%.2f", value) : String(format: "%.2f", value)
    }
}

private struct RouteRow: View {
    let route: RouteOption

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .foregroundStyle(AppTheme.blue)
            VStack(alignment: .leading, spacing: 5) {
                Text(route.status.capitalized)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text([route.etaSeconds.map { "\($0 / 60) min" }, route.distanceMeters.map { "\($0 / 1000) km" }].compactMap { $0 }.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            StatusPill(status: route.provider)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .ciroCard()
    }
}

private struct BlockedSegmentRow: View {
    let segment: BlockedSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(AppTheme.danger)
            VStack(alignment: .leading, spacing: 5) {
                Text(segment.reason)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text("Simulated app-owned segment")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            SeverityBadge(severity: segment.severity)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .ciroCard()
    }
}
