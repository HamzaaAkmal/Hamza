import SwiftUI

struct ResponsePlanScreen: View {
    @EnvironmentObject private var app: AppModel
    let incidentId: UUID

    private var incident: Incident? {
        app.repository.incidents.first { $0.id == incidentId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Response Plan",
                    subtitle: "Coordinated safe actions written by the Response Planner Agent.",
                    icon: "list.bullet.clipboard.fill"
                )

                if app.repository.isLoading && !app.repository.hasLoadedOnce {
                    SkeletonCardList(rows: 4)
                } else if let incident {
                    let actions = app.repository.actions(for: incident)
                    if actions.isEmpty {
                        EmptyState(
                            icon: "checklist.unchecked",
                            title: "No actions yet",
                            message: "The planner will write reroutes, mock alerts, mock tickets, resources, and monitoring tasks here."
                        )
                        .padding(.horizontal)
                    } else {
                        ForEach(actions) { action in
                            ActionRow(action: action) { status in
                                Task { await app.repository.updateAction(action, status: status) }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(AppTheme.surface)
        .navigationTitle("Plan")
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

private struct ActionRow: View {
    let action: ResponseAction
    let onStatus: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.blue.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(action.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text(action.description ?? action.actionType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let assignedTo = action.assignedTo {
                        Label(assignedTo, systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.blue)
                    }
                    if let confirmationId {
                        Label(confirmationId, systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.success)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    StatusPill(status: action.status)
                    Text("P\(action.priority)")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.blue)
                }
            }

            HStack {
                Text(action.actionType.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Menu {
                    Button("Ready") { onStatus("ready") }
                    Button("In progress") { onStatus("in_progress") }
                    Button("Completed") { onStatus("completed") }
                    Button("Cancelled", role: .destructive) { onStatus("cancelled") }
                } label: {
                    Label("Update", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.blue)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .ciroCard()
    }

    private var confirmationId: String? {
        action.payload["booking_confirmation_id"]?.stringValue
    }

    private var icon: String {
        switch action.actionType {
        case "reroute": return "arrow.triangle.turn.up.right.diamond.fill"
        case "alert": return "bell.badge.fill"
        case "ticket": return "ticket.fill"
        case "assign_resource": return "person.2.badge.gearshape.fill"
        case "field_check": return "figure.walk.motion"
        case "public_guidance": return "megaphone.fill"
        default: return "scope"
        }
    }
}
