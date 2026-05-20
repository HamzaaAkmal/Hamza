import SwiftUI

struct LiveCrisisMapScreen: View {
    @EnvironmentObject private var app: AppModel

    private var showSkeleton: Bool {
        app.repository.isLoading && !app.repository.hasLoadedOnce && !hasDashboardData
    }

    private var hasDashboardData: Bool {
        !app.repository.incidents.isEmpty ||
        !app.repository.signals.isEmpty ||
        !app.repository.actions.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CrisisMapView(
                incidents: app.repository.incidents,
                signals: app.repository.signals,
                routes: app.repository.routeOptions,
                blockedSegments: app.repository.blockedSegments
            )
            .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CrisisX")
                            .font(.title3.bold())
                            .foregroundStyle(AppTheme.ink)
                        Text("Live Crisis Map")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)
                    }
                    Spacer()
                    StatusPill(status: app.repository.isShowingCachedData ? "cached" : (app.realtime.isConnected ? "live" : "connecting"))
                }

                HStack(spacing: 10) {
                    if showSkeleton {
                        SkeletonStatTile(icon: "exclamationmark.triangle.fill")
                        SkeletonStatTile(icon: "dot.radiowaves.left.and.right")
                        SkeletonStatTile(icon: "checklist")
                    } else {
                        StatTile(title: "Incidents", value: "\(app.repository.incidents.count)", icon: "exclamationmark.triangle.fill")
                        StatTile(title: "Signals", value: "\(app.repository.signals.count)", icon: "dot.radiowaves.left.and.right")
                        StatTile(title: "Actions", value: "\(app.repository.actions.count)", icon: "checklist")
                    }
                }

                if (app.repository.isRefreshing || app.repository.isShowingCachedData) && !hasDashboardData {
                    SyncStatusBanner(
                        isRefreshing: app.repository.isRefreshing,
                        isCached: app.repository.isShowingCachedData,
                        message: syncMessage
                    )
                }

                if let error = app.repository.lastError, !hasDashboardData && !showSkeleton {
                    EmptyState(
                        icon: "exclamationmark.triangle.fill",
                        title: "Waiting for safe refresh",
                        message: error
                    )
                    .padding(.vertical, 4)
                } else if showSkeleton {
                    DashboardSkeletonList()
                } else if app.repository.incidents.isEmpty {
                    EmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: app.repository.signals.isEmpty ? "Supabase connected, no data yet" : "Signals loaded, no incidents yet",
                        message: app.repository.signals.isEmpty
                            ? "The CIRO tables are reachable but currently empty. Submit a report or generate a backend API signal from Settings."
                            : "Signals are present. Open Inbox or keep the agent pipeline running to create incidents."
                    )
                    .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(app.repository.incidents) { incident in
                                NavigationLink {
                                    IncidentDetailScreen(incidentId: incident.id)
                                } label: {
                                    IncidentMapCard(incident: incident)
                                        .frame(width: 280, height: 216)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .task {
            if app.repository.incidents.isEmpty && app.repository.signals.isEmpty {
                await app.repository.loadAll()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if app.repository.isRefreshing {
                    ProgressView()
                        .tint(AppTheme.blue)
                } else {
                    Button {
                        Task { await app.repository.loadAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var syncMessage: String {
        if app.repository.isShowingCachedData {
            if let savedAt = app.repository.lastCacheSavedAt {
                return "Showing local cache from \(savedAt.shortRelative) while Supabase verifies fresh data."
            }
            return "Showing local cache while Supabase verifies fresh data."
        }
        return "Refreshing Supabase data safely."
    }
}

private struct SkeletonStatTile: View {
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.blue.opacity(0.75))
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.line)
                .frame(width: 42, height: 24)
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.line)
                .frame(width: 68, height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .ciroCard()
        .shimmeringSkeleton()
    }
}

private struct DashboardSkeletonList: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.line)
                            .frame(width: 54, height: 20)
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.line)
                            .frame(width: 74, height: 20)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.line)
                        .frame(height: 16)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.line)
                        .frame(width: 180, height: 12)
                }
                .ciroCard()
                .shimmeringSkeleton()
            }
        }
    }
}

private struct IncidentMapCard: View {
    let incident: Incident

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SeverityBadge(severity: incident.severity)
                StatusPill(status: incident.status)
                Spacer()
            }
            Text(incident.title)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
            Text(incident.description ?? incident.category.capitalized)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .lineLimit(2)
            HStack {
                Label("\(Int(incident.confidence * 100))%", systemImage: "checkmark.seal")
                Spacer()
                Text(incident.updatedAt.shortRelative)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.blue)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .ciroCard()
    }
}
