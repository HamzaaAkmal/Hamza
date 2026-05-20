import SwiftUI

struct ScreenHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(AppTheme.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
}

struct StatusPill: View {
    let status: String

    var body: some View {
        Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var color: Color {
        if status.contains("fail") || status.contains("offline") { return AppTheme.danger }
        if status.contains("cached") { return AppTheme.warning }
        if status.contains("running") || status.contains("progress") || status.contains("queued") { return AppTheme.warning }
        if status.contains("completed") || status.contains("healthy") || status.contains("active") || status.contains("ready") { return AppTheme.success }
        return AppTheme.blue
    }
}

struct SeverityBadge: View {
    let severity: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.path.ecg")
            Text("S\(severity)")
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(AppTheme.severityColor(severity))
        .clipShape(Capsule())
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(AppTheme.sky)
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.muted)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

struct BottomSystemBar: View {
    let isRunning: Bool
    let error: String?

    var body: some View {
        if let error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.warning)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Spacer()
            }
            .padding(14)
            .background(.white)
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .top)
        }
    }
}

struct SyncStatusBanner: View {
    let isRefreshing: Bool
    let isCached: Bool
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            if isRefreshing {
                ProgressView()
                    .tint(AppTheme.blue)
            } else {
                Image(systemName: isCached ? "externaldrive.badge.clock" : "checkmark.icloud.fill")
                    .foregroundStyle(isCached ? AppTheme.warning : AppTheme.success)
            }

            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background((isCached ? AppTheme.warning : AppTheme.blue).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.blue)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .ciroCard()
    }
}

struct SkeletonCardList: View {
    var rows = 3
    var includeHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if includeHeader {
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.line)
                    .frame(width: 140, height: 18)
                    .padding(.horizontal)
            }

            ForEach(0..<rows, id: \.self) { index in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.line)
                            .frame(width: 54, height: 22)
                        Spacer()
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.line)
                            .frame(width: 86, height: 22)
                    }
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.line)
                        .frame(height: 18)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.line)
                        .frame(width: index.isMultiple(of: 2) ? 210 : 165, height: 12)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                .ciroCard()
                .padding(.horizontal)
                .shimmeringSkeleton()
            }
        }
    }
}

struct SkeletonModifier: ViewModifier {
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.55),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .rotationEffect(.degrees(16))
                    .offset(x: phase ? proxy.size.width : -proxy.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            }
            .onAppear { phase = true }
            .animation(.linear(duration: 1.15).repeatForever(autoreverses: false), value: phase)
    }
}

extension View {
    func shimmeringSkeleton(active: Bool = true) -> some View {
        Group {
            if active {
                modifier(SkeletonModifier())
            } else {
                self
            }
        }
    }
}

extension Date {
    var shortRelative: String {
        Self.relative.localizedString(for: self, relativeTo: Date())
    }

    var compactTime: String {
        Self.time.string(from: self)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
