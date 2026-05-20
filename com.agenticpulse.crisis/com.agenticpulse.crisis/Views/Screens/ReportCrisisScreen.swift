import SwiftUI

struct ReportCrisisScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var reportText = ""
    @State private var locationText = ""
    @State private var category = "unknown"
    @State private var urgency = 3.0
    @State private var activeSignalId: UUID?
    @State private var pipelineResponse: [String: JSONValue]?
    @State private var pipelineError: String?
    @State private var isPipelineSheetPresented = false
    @State private var isSubmitting = false
    @FocusState private var focused: Field?

    private let categories = ["unknown", "fire", "flood", "medical", "traffic", "violence", "infrastructure", "weather", "environment"]

    private var activeSignalRunning: Bool {
        app.repository.isRunActive(for: activeSignalId)
    }

    private var activeSignalCanRetry: Bool {
        guard let activeSignalId,
              let run = app.repository.run(for: activeSignalId) else {
            return false
        }
        return run.status == "failed"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(
                    title: "Report Crisis",
                    subtitle: "Submit a real user report for the agent pipeline to normalize, verify, cluster, and simulate.",
                    icon: "plus.message.fill"
                )

                VStack(alignment: .leading, spacing: 12) {
                    Label("What is happening?", systemImage: "text.bubble.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    TextEditor(text: $reportText)
                        .frame(minHeight: 150)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        )
                        .focused($focused, equals: .report)
                    Text("English, Urdu, and Roman Urdu are accepted.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .padding(.horizontal)

                VStack(spacing: 14) {
                    TextField("Location, landmark, or address", text: $locationText)
                        .textInputAutocapitalization(.words)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .location)

                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { value in
                            Text(value.capitalized).tag(value)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Urgency", systemImage: "gauge.with.dots.needle.bottom.50percent")
                            Spacer()
                            Text("\(Int(urgency))/5")
                                .font(.headline)
                                .foregroundStyle(AppTheme.blue)
                        }
                        Slider(value: $urgency, in: 1...5, step: 1)
                            .tint(AppTheme.blue)
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 10) {
                    Button {
                        if activeSignalRunning, activeSignalId != nil {
                            isPipelineSheetPresented = true
                        } else if activeSignalCanRetry {
                            focused = nil
                            Task { await retryActiveSignal() }
                        } else {
                            focused = nil
                            Task { await submit() }
                        }
                    } label: {
                        Label(submitButtonTitle, systemImage: submitButtonIcon)
                    }
                    .buttonStyle(PrimaryButtonStyle(isDisabled: isSubmitting))
                    .disabled(isSubmitting)

                    if activeSignalRunning, activeSignalId != nil {
                        Button {
                            isPipelineSheetPresented = true
                        } label: {
                            Label("Open live logs and agent steps", systemImage: "list.clipboard.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.blue)
                        }
                    }

                    if let pipelineError {
                        Text(pipelineError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.danger)
                            .multilineTextAlignment(.center)
                    }

                    Text("CrisisX stores the report as a live signal, then backend agents enrich it with configured APIs and write every decision to Supabase.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .background(AppTheme.surface)
        .navigationTitle("Report")
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
        .sheet(isPresented: $isPipelineSheetPresented) {
            if let activeSignalId {
                PipelineProgressSheet(
                    signalId: activeSignalId,
                    isProcessing: activeSignalRunning,
                    response: pipelineResponse,
                    error: pipelineError,
                    onDismiss: {
                        isPipelineSheetPresented = false
                    }
                )
            }
        }
    }

    private var canSubmit: Bool {
        sanitized(reportText).count >= 12 &&
        !sanitized(locationText).isEmpty
    }

    private var submitButtonTitle: String {
        if activeSignalRunning {
            return "View Agent Progress"
        }
        if activeSignalCanRetry {
            return "Retry with Fallback"
        }
        return "Submit to Agents"
    }

    private var submitButtonIcon: String {
        if activeSignalRunning {
            return "heart.fill"
        }
        if activeSignalCanRetry {
            return "arrow.triangle.2.circlepath"
        }
        return "paperplane.fill"
    }

    private func submit() async {
        guard !isSubmitting, !activeSignalRunning else {
            if activeSignalId != nil {
                isPipelineSheetPresented = true
            }
            return
        }

        let trimmedReport = sanitized(reportText)
        let trimmedLocation = sanitized(locationText)
        guard trimmedReport.count >= 12, !trimmedLocation.isEmpty else {
            pipelineError = "Please enter a real report and location before submitting."
            return
        }
        pipelineResponse = nil
        pipelineError = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let signal = try await app.repository.createReportSignal(
                text: trimmedReport,
                locationText: trimmedLocation,
                category: category,
                urgency: Int(urgency)
            )
            activeSignalId = signal.id
            isPipelineSheetPresented = true
            reportText = ""
            locationText = ""
            category = "unknown"
            urgency = 3
            let response = try await app.repository.processSignal(signal.id)
            pipelineResponse = response["status"]?.stringValue == "completed" ? response : nil
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("timed out") {
                pipelineError = nil
                app.repository.lastError = "Agent request is still syncing from Supabase. Keep the progress sheet open for live heartbeat updates."
                await app.repository.loadAll()
            } else {
                pipelineError = message
                app.repository.lastError = message
            }
            if activeSignalId != nil {
                isPipelineSheetPresented = true
            }
        }
    }

    private func retryActiveSignal() async {
        guard !isSubmitting, let activeSignalId else { return }

        pipelineResponse = nil
        pipelineError = nil
        isSubmitting = true
        isPipelineSheetPresented = true
        defer { isSubmitting = false }

        do {
            let response = try await app.repository.processSignal(activeSignalId)
            pipelineResponse = response["status"]?.stringValue == "completed" ? response : nil
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("timed out") {
                pipelineError = nil
                app.repository.lastError = "Agent request is still syncing from Supabase. Keep the progress sheet open for live heartbeat updates."
                await app.repository.loadAll()
            } else {
                pipelineError = message
                app.repository.lastError = message
            }
        }
    }

    private enum Field {
        case report
        case location
    }

    private func sanitized(_ value: String) -> String {
        value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
