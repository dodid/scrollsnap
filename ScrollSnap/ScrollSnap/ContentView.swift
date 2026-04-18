//
//  ContentView.swift
//  ScrollSnap
//
//  Created by ww on 2026/2/26.
//

import SwiftUI
import PhotosUI
import AVFoundation
import StoreKit

struct ContentView: View {
    @StateObject private var libraryStore = LibraryStore()
    @EnvironmentObject private var supportStore: SupportStore

    var body: some View {
        TabView {
            Tab("Process", systemImage: "sparkles.rectangle.stack") {
                NavigationStack {
                    ProcessView()
                        .environmentObject(libraryStore)
                        .environmentObject(supportStore)
                }
            }

            Tab("Library", systemImage: "photo.on.rectangle.angled") {
                NavigationStack {
                    LibraryView()
                        .environmentObject(libraryStore)
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                        .environmentObject(libraryStore)
                        .environmentObject(supportStore)
                }
            }
        }
    }
}

private struct ProcessView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var supportStore: SupportStore
    @Environment(\.requestReview) private var requestReview

    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?

    @State private var isProcessing = false
    @State private var progressValue = 0.0
    @State private var statusMessage = String(localized: "Pick a video to begin.")
    @State private var errorMessage: String?

    @State private var currentResultItem: GeneratedImageItem?
    @State private var isSavingToPhotos = false
    @State private var isPinnedStateCardVisible = false

    @State private var processingTask: Task<Void, Never>?
    @State private var showScrollWarning = false

    // Support prompt (shown once after first successful stitch)
    @AppStorage("didPromptSupport") private var didPromptSupport: Bool = false
    @State private var showSupportPrompt = false

    // Video timeline trim
    @State private var videoTotalDuration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var filmstripThumbnails: [UIImage] = []
    @State private var isLoadingFilmstrip = false
    @State private var filmstripTask: Task<Void, Never>?

    private let stitchingService = VideoStitchingService()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard

                if selectedVideoURL != nil {
                    videoTimelineCard
                }

                stateCard()
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: StateCardMinYPreferenceKey.self,
                                    value: geometry.frame(in: .named("processScroll")).minY
                                )
                        }
                    )

                if currentResultItem != nil {
                    resultPreviewCard

                    Label(
                        "If content looks missing or jumpy, try recording at a slower scroll speed. Use the trim handles above to exclude unwanted content at the start or end.",
                        systemImage: "lightbulb"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
            .padding(16)
        }
        .coordinateSpace(name: "processScroll")
        .navigationTitle("Process")
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground))
        .alert("Couldn’t Process Video", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }        .alert("Not a Scrolling Video?", isPresented: $showScrollWarning) {
            Button("Process Anyway") {
                beginStitching()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This video doesn't look like a scrolling screen recording. The result may have artifacts or missing content.")
        }        .safeAreaInset(edge: .top) {
            if isPinnedStateCardVisible {
                stateCard(isPinned: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectedVideoURL == nil, !supportStore.hasSupporterBadge {
                preLoadSupportCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        }
        .onPreferenceChange(StateCardMinYPreferenceKey.self, perform: updatePinnedStateCardVisibility)
        .onChange(of: selectedVideoItem) { _, newItem in
            Task {
                await loadSelectedVideo(from: newItem)
            }
        }
        .onDisappear {
            processingTask?.cancel()
            filmstripTask?.cancel()
        }
        .animation(.none, value: isPinnedStateCardVisible)
        .sheet(isPresented: $showSupportPrompt) {
            SupportPromptSheet()
                .environmentObject(supportStore)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stitch scrolling video")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Load one screen-recorded video and generate a seamless long screenshot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $selectedVideoItem, matching: .videos, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
                    Text("Load Video")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                startProcessing()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(isProcessing ? "Processing…" : "Process to Long Image")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isProcessing || selectedVideoURL == nil)

        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var preLoadSupportCard: some View {
        Button {
            showSupportPrompt = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SupportPalette.deepAmber)
                    .frame(width: 36, height: 36)
                    .background(SupportPalette.lightAmber.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Support ScrollSnap")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Turn on your supporter badge with a quick review or coffee.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SupportPalette.panelBackground(isActive: false))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(SupportPalette.lightAmber.opacity(0.18), lineWidth: 1)
                )
        }
    }

    private func stateCard(isPinned: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label(isProcessing ? "Processing" : "Ready", systemImage: isProcessing ? "hourglass" : "checkmark.circle")
                    .font(.headline)
                Spacer()

                if isProcessing {
                    Text("\(Int(progressValue * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let currentResultItem {
                    resultActionButtons(for: currentResultItem, compact: true)
                }
            }

            if isProcessing {
                ProgressView(value: progressValue)
                    .tint(.accentColor)
            }

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if isPinned {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
            }
        }
        .shadow(color: isPinned ? Color.black.opacity(0.14) : .clear, radius: 16, x: 0, y: 8)
    }

    // MARK: - Video timeline card

    private var videoTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Trim Range", systemImage: "timeline.selection")
                    .font(.headline)
                Spacer()
                if isLoadingFilmstrip {
                    ProgressView().controlSize(.small)
                }
            }

            if let url = selectedVideoURL, videoTotalDuration > 0 {
                VideoTimeline(
                    videoURL: url,
                    thumbnails: filmstripThumbnails,
                    duration: videoTotalDuration,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd
                )
            }

            HStack {
                Text(formatDuration(trimStart))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: String(localized: "%@ selected"), formatDuration(trimEnd - trimStart)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatDuration(trimEnd))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        let tenths = Int((s - floor(s)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, tenths)
    }

    private func loadFilmstrip(url: URL, duration: Double) async {
        guard duration > 0 else { return }
        await MainActor.run { isLoadingFilmstrip = true }
        let count = 20
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.3, preferredTimescale: 600)
        var thumbnails: [UIImage] = []
        for i in 0..<count {
            guard !Task.isCancelled else { break }
            let t = (Double(i) / Double(count - 1)) * duration
            let cmT = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: cmT).image {
                thumbnails.append(UIImage(cgImage: cgImage))
            }
        }
        await MainActor.run {
            filmstripThumbnails = thumbnails
            isLoadingFilmstrip = false
        }
    }

    private var resultPreviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Result")
                .font(.headline)

            if let currentResultItem, let image = libraryStore.image(for: currentResultItem) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func resultActionButtons(for item: GeneratedImageItem, compact: Bool = false) -> some View {
        if compact {
            HStack(spacing: 8) {
                Button {
                    Task { await saveToPhotos(item: item) }
                } label: {
                    Image(systemName: isSavingToPhotos ? "hourglass" : "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(isSavingToPhotos)
                .accessibilityLabel("Save image")

                if let image = libraryStore.image(for: item) {
                    ImageShareButton(image: image, displayName: item.displayName) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .accessibilityLabel("Share image")
                }
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    Task { await saveToPhotos(item: item) }
                } label: {
                    Label(isSavingToPhotos ? "Saving" : "Save", systemImage: isSavingToPhotos ? "hourglass" : "square.and.arrow.down")
                        .frame(width: 94)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSavingToPhotos)
                .accessibilityLabel("Save image")

                if let image = libraryStore.image(for: item) {
                    ImageShareButton(image: image, displayName: item.displayName) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(width: 94)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Share image")
                }
            }
        }
    }

    private func updatePinnedStateCardVisibility(_ cardMinY: CGFloat) {
        guard currentResultItem != nil else {
            if isPinnedStateCardVisible {
                isPinnedStateCardVisible = false
            }
            return
        }

        let showThreshold: CGFloat = -24
        let hideThreshold: CGFloat = 8

        if !isPinnedStateCardVisible, cardMinY < showThreshold {
            isPinnedStateCardVisible = true
        } else if isPinnedStateCardVisible, cardMinY > hideThreshold {
            isPinnedStateCardVisible = false
        }
    }

    private func loadSelectedVideo(from item: PhotosPickerItem?) async {
        guard let item else {
            selectedVideoURL = nil
            currentResultItem = nil
            isPinnedStateCardVisible = false
            videoTotalDuration = 0
            filmstripThumbnails = []
            trimStart = 0
            trimEnd = 0
            return
        }

        await MainActor.run {
            currentResultItem = nil
            isPinnedStateCardVisible = false
            statusMessage = String(localized: "Loading selected video…")
            progressValue = 0
            errorMessage = nil
        }

        do {
            let imported = try await item.loadTransferable(type: VideoTransferable.self)
            guard let imported else {
                selectedVideoURL = nil
                statusMessage = String(localized: "Unable to load video.")
                return
            }

            selectedVideoURL = imported.url
            statusMessage = String(localized: "Video loaded. Ready to process.")

            let asset = AVURLAsset(url: imported.url)
            if let dur = try? await asset.load(.duration) {
                let totalDur = CMTimeGetSeconds(dur)
                await MainActor.run {
                    videoTotalDuration = totalDur
                    trimStart = 0
                    trimEnd = totalDur
                }
                filmstripTask?.cancel()
                filmstripTask = Task { await loadFilmstrip(url: imported.url, duration: totalDur) }
            }
        } catch {
            selectedVideoURL = nil
            statusMessage = String(localized: "Video import failed")
            errorMessage = error.localizedDescription
        }
    }

    private func startProcessing() {
        guard let selectedVideoURL else { return }

        processingTask?.cancel()
        statusMessage = String(localized: "Checking video…")
        errorMessage = nil

        processingTask = Task {
            let confidence = await stitchingService.detectScrollingVideo(videoURL: selectedVideoURL)

            await MainActor.run {
                switch confidence {
                case .confident:
                    beginStitching()
                case .uncertain, .notScrolling:
                    showScrollWarning = true
                }
            }
        }
    }

    private func beginStitching() {
        guard let selectedVideoURL else { return }

        processingTask?.cancel()
        isProcessing = true
        progressValue = 0.0
        statusMessage = String(localized: "Extracting frames…")
        errorMessage = nil

        processingTask = Task {
            do {
                let image = try await stitchingService.stitch(
                    videoURL: selectedVideoURL,
                    startTime: trimStart,
                    endTime: trimEnd
                ) { progress in
                    Task { @MainActor in
                        self.progressValue = progress
                        if progress < 0.92 {
                            self.statusMessage = String(localized: "Aligning frames…")
                        } else {
                            self.statusMessage = String(localized: "Compositing final image…")
                        }
                    }
                }

                let item = try await MainActor.run {
                    try libraryStore.addImage(image)
                }

                await MainActor.run {
                    self.currentResultItem = item
                    self.statusMessage = String(localized: "Long image generated.")
                    self.isProcessing = false
                    if !self.didPromptSupport {
                        self.didPromptSupport = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            await MainActor.run { self.showSupportPrompt = true }
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = String(localized: "Processing cancelled.")
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = String(localized: "Automatic stitching failed for this clip. Try a slower, steady scroll recording.")
                    self.isProcessing = false
                }
            }
        }
    }

    private func saveToPhotos(item: GeneratedImageItem) async {
        await MainActor.run { isSavingToPhotos = true }
        do {
            try await PhotoLibrarySaver.saveImage(at: libraryStore.imageURL(for: item))
            await MainActor.run { statusMessage = String(localized: "Saved to Photos.") }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
        await MainActor.run { isSavingToPhotos = false }
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var itemPendingDeletion: GeneratedImageItem?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        Group {
            if libraryStore.items.isEmpty {
                ContentUnavailableView(
                    "No Snapshots Yet",
                    systemImage: "photo.stack",
                    description: Text("Generated long images will appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(libraryStore.items) { item in
                            ZStack(alignment: .bottomTrailing) {
                                NavigationLink {
                                    LibraryDetailView(itemID: item.id)
                                        .environmentObject(libraryStore)
                                } label: {
                                    LibraryItemCard(item: item, displayName: item.displayName)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button(role: .destructive) {
                                    itemPendingDeletion = item
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .padding(8)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 10)
                                .padding(.bottom, 14)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground))
        .confirmationDialog("Delete this image?", isPresented: Binding(
            get: { itemPendingDeletion != nil },
            set: { if !$0 { itemPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let itemPendingDeletion {
                    libraryStore.delete(itemPendingDeletion)
                }
                itemPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                itemPendingDeletion = nil
            }
        }
    }
}

private struct LibraryItemCard: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    let item: GeneratedImageItem
    let displayName: String

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                if let image = libraryStore.image(for: item) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    Color(.secondarySystemFill)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(Self.dateFormatter.localizedString(for: item.createdAt, relativeTo: .now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var supportStore: SupportStore
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            // ── Support hero — full-bleed, no default row chrome ──
            Section {
                SupportHeroSection()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Storage") {
                LabeledContent("Used Space", value: libraryStore.usedStorageText)
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("Clear Library")
                }
            }

            Section("Legal") {
                Link("Terms of Service", destination: URL(string: "https://scrollsnap.candiapps.com/terms.html")!)
                Link("Privacy Policy", destination: URL(string: "https://scrollsnap.candiapps.com/privacy.html")!)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .confirmationDialog("Clear all generated images?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                libraryStore.clearAll()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}


private struct StateCardMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct LibraryDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let itemID: UUID

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteConfirm = false

    var body: some View {
        Group {
            if let item = libraryStore.items.first(where: { $0.id == itemID }), let image = libraryStore.image(for: item) {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(16)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ImageShareButton(image: image, displayName: item.displayName) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                Task { await save(item) }
                            } label: {
                                Label(isSaving ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down")
                            }
                            .disabled(isSaving)

                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Snapshot Missing", systemImage: "exclamationmark.triangle", description: Text("This image may have been deleted."))
            }
        }
        .navigationTitle(libraryStore.items.first(where: { $0.id == itemID })?.displayName ?? String(localized: "Snapshot"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog("Delete this image?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            if let item = libraryStore.items.first(where: { $0.id == itemID }) {
                Button("Delete", role: .destructive) {
                    libraryStore.delete(item)
                    dismiss()
                }
            }

            Button("Cancel", role: .cancel) { }
        }
    }

    private func save(_ item: GeneratedImageItem) async {
        await MainActor.run { isSaving = true }
        do {
            try await PhotoLibrarySaver.saveImage(at: libraryStore.imageURL(for: item))
        } catch {
            await MainActor.run { saveError = error.localizedDescription }
        }
        await MainActor.run { isSaving = false }
    }
}

// MARK: - Video Timeline

private struct ImageShareButton<Label: View>: View {
    let image: UIImage
    let displayName: String
    @ViewBuilder let label: () -> Label

    @State private var isShowingShareSheet = false

    var body: some View {
        Button {
            isShowingShareSheet = true
        } label: {
            label()
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivitySheet(activityItems: [ImageActivityItemSource(image: image, title: displayName)])
        }
    }
}

private struct VideoTimeline: View {
    let videoURL: URL
    let thumbnails: [UIImage]
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double

    @State private var isDraggingLeft = false
    @State private var isDraggingRight = false
    @State private var leftDragBaseTime: Double = 0
    @State private var rightDragBaseTime: Double = 0
    @State private var leftPopupImage: UIImage?
    @State private var rightPopupImage: UIImage?
    @State private var popupTask: Task<Void, Never>?

    private let stripHeight:   CGFloat = 74
    private let earWidth:      CGFloat = 14
    private let popupMaxWidth:  CGFloat = 160
    private let popupMaxHeight: CGFloat = 220
    private let popupGap:       CGFloat = 8

    private func popupSize(for image: UIImage) -> CGSize {
        let r = image.size.width / max(1, image.size.height)
        let w = min(popupMaxWidth, popupMaxHeight * r)
        let h = w / max(0.01, r)
        return CGSize(width: w, height: h)
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let lx = timeToX(trimStart, W: W)
            let rx = timeToX(trimEnd,   W: W)

            // ---- Layer 0: Filmstrip + decorations (clipped separately) ----
            ZStack(alignment: .topLeading) {
                filmstripView(W: W)

                // Dim area before selection
                if lx > 0 {
                    Color.black.opacity(0.52)
                        .frame(width: lx, height: stripHeight)
                }
                // Dim area after selection
                if rx < W {
                    Color.black.opacity(0.52)
                        .frame(width: W - rx, height: stripHeight)
                        .offset(x: rx)
                }

                // Blue top/bottom border of selected range
                Color.blue.frame(width: max(0, rx - lx), height: 2).offset(x: lx)
                Color.blue.frame(width: max(0, rx - lx), height: 2).offset(x: lx, y: stripHeight - 2)
            }
            .frame(width: W, height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // ---- Layer 1: Ear handles (outside clip so they catch gestures at edge) ----
            earView(isLeft: true)
                .frame(width: earWidth, height: stripHeight)
                .offset(x: lx)
                .gesture(leftEarGesture(W: W))
                .zIndex(5)

            earView(isLeft: false)
                .frame(width: earWidth, height: stripHeight)
                .offset(x: rx - earWidth)
                .gesture(rightEarGesture(W: W))
                .zIndex(5)

            // ---- Layer 2: Floating popups — offset above strip top, no position() quirks ----
            if isDraggingLeft, let img = leftPopupImage {
                let sz = popupSize(for: img)
                let cx = max(sz.width / 2, min(W - sz.width / 2, lx + earWidth / 2))
                popupView(img, size: sz)
                    .offset(x: cx - sz.width / 2, y: -(sz.height + popupGap))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
            if isDraggingRight, let img = rightPopupImage {
                let sz = popupSize(for: img)
                let cx = max(sz.width / 2, min(W - sz.width / 2, rx - earWidth / 2))
                popupView(img, size: sz)
                    .offset(x: cx - sz.width / 2, y: -(sz.height + popupGap))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .frame(height: stripHeight)
    }

    // MARK: Sub-views

    @ViewBuilder
    private func filmstripView(W: CGFloat) -> some View {
        if thumbnails.isEmpty {
            Rectangle().fill(Color.gray.opacity(0.3))
                .frame(width: W, height: stripHeight)
        } else {
            HStack(spacing: 0) {
                ForEach(0..<thumbnails.count, id: \.self) { i in
                    Image(uiImage: thumbnails[i])
                        .resizable()
                        .scaledToFill()
                        .frame(width: W / CGFloat(thumbnails.count), height: stripHeight)
                        .clipped()
                }
            }
        }
    }

    @ViewBuilder
    private func popupView(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.30), radius: 10, x: 0, y: 3)
    }

    private func earView(isLeft: Bool) -> some View {
        let r: CGFloat = 6
        let shape = isLeft
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: 0, topTrailingRadius: 0,
                                      style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: r, topTrailingRadius: r,
                                      style: .continuous)
        return shape
            .fill(Color.blue)
            .overlay(
                Image(systemName: isLeft ? "chevron.left" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            )
    }

    // MARK: Gestures

    private func leftEarGesture(W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDraggingLeft {
                    isDraggingLeft = true
                    leftDragBaseTime = trimStart
                }
                let delta = Double(value.translation.width / W) * duration
                let minGap = max(0.5, Double(earWidth * 2 / W) * duration)
                trimStart = max(0, min(leftDragBaseTime + delta, trimEnd - minGap))
                fetchPopup(for: trimStart, isLeft: true)
            }
            .onEnded { _ in
                isDraggingLeft = false
                leftPopupImage = nil
                popupTask?.cancel()
            }
    }

    private func rightEarGesture(W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDraggingRight {
                    isDraggingRight = true
                    rightDragBaseTime = trimEnd
                }
                let delta = Double(value.translation.width / W) * duration
                let minGap = max(0.5, Double(earWidth * 2 / W) * duration)
                trimEnd = max(trimStart + minGap, min(rightDragBaseTime + delta, duration))
                fetchPopup(for: trimEnd, isLeft: false)
            }
            .onEnded { _ in
                isDraggingRight = false
                rightPopupImage = nil
                popupTask?.cancel()
            }
    }

    // MARK: Helpers

    private func timeToX(_ t: Double, W: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(max(0, min(t / duration, 1))) * W
    }

    private func fetchPopup(for time: Double, isLeft: Bool) {
        popupTask?.cancel()
        popupTask = Task {
            guard !Task.isCancelled else { return }
            do {
                let asset = AVURLAsset(url: videoURL)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
                let cgImage = try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                let ui = UIImage(cgImage: cgImage)
                await MainActor.run {
                    if isLeft { leftPopupImage = ui } else { rightPopupImage = ui }
                }
            } catch { }
        }
    }
}

// MARK: - Support UI

private enum SupportPalette {
    static let lightAmber = Color(red: 0.85, green: 0.62, blue: 0.28)
    static let deepAmber = Color(red: 0.72, green: 0.44, blue: 0.14)
    static let settingsBackground = Color(.systemGroupedBackground)

    static func panelBackground(isActive: Bool) -> LinearGradient {
        LinearGradient(
            colors: [
                lightAmber.opacity(isActive ? 0.22 : 0.14),
                Color(.systemGroupedBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var opaqueSheetBackground: some View {
        ZStack(alignment: .top) {
            settingsBackground
            LinearGradient(
                colors: [
                    lightAmber.opacity(0.18),
                    settingsBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static var buttonGradient: LinearGradient {
        LinearGradient(
            colors: [lightAmber, deepAmber],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Full-bleed hero card shown at the top of SettingsView.
private struct SupportHeroSection: View {
    @EnvironmentObject private var supportStore: SupportStore
    @Environment(\.openURL) private var openURL

    // Maps stable product IDs to coffee presentation.
    private struct CoffeeInfo { let emoji: String; let label: LocalizedStringResource }
    private let appStoreWriteReviewURL = URL(string: "https://apps.apple.com/app/id6759849068?action=write-review")!
    private let coffeeMap: [String: CoffeeInfo] = [
        "com.scrollsnap.tip.small":  CoffeeInfo(emoji: "☕",     label: "A Coffee"),
        "com.scrollsnap.tip.medium": CoffeeInfo(emoji: "☕☕",   label: "Two Coffees"),
        "com.scrollsnap.tip.large":  CoffeeInfo(emoji: "☕☕☕", label: "Three Coffees"),
    ]

    var body: some View {
        VStack(spacing: 0) {

            // ── Hero header ──────────────────────────────────────────────
            VStack(spacing: 10) {
                if supportStore.hasSupporterBadge {
                    // ── Supporter state ──
                    if supportStore.hasDonated {
                        let n = supportStore.coffeeCount
                        Group {
                            if n <= 3 {
                                Text(String(repeating: "☕", count: max(n, 1)))
                                    .font(.system(size: 48))
                            } else {
                                HStack(spacing: 4) {
                                    Text("☕")
                                        .font(.system(size: 48))
                                    Text("×\(n)")
                                        .font(.system(size: 36, weight: .bold, design: .rounded))
                                        .foregroundStyle(SupportPalette.deepAmber)
                                }
                            }
                        }
                        // Halo attached to the emoji itself — three layered glows
                        .shadow(color: SupportPalette.lightAmber.opacity(0.55), radius: 8,  x: 0, y: 0)
                        .shadow(color: SupportPalette.lightAmber.opacity(0.30), radius: 16, x: 0, y: 0)
                        .shadow(color: SupportPalette.lightAmber.opacity(0.15), radius: 28, x: 0, y: 0)
                        .padding(.bottom, 2)
                    } else {
                        Image(systemName: "star.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(SupportPalette.lightAmber)
                            .shadow(color: SupportPalette.lightAmber.opacity(0.45), radius: 8, x: 0, y: 0)
                            .shadow(color: SupportPalette.lightAmber.opacity(0.22), radius: 18, x: 0, y: 0)
                            .padding(.bottom, 2)
                    }

                    // Supporter badge pill
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Supporter")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        SupportPalette.buttonGradient,
                        in: Capsule()
                    )
                    .shadow(color: SupportPalette.lightAmber.opacity(0.4), radius: 6, x: 0, y: 2)

                    Text(supportStore.isReviewSupporterOnly
                         ? "Thanks for reviewing ScrollSnap.\nThat support really helps."
                         : "Thank you for keeping ScrollSnap alive.\nYour generosity means everything.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    // ── Default state ──
                    Text("☕")
                        .font(.system(size: 48))
                        .padding(.bottom, 2)

                    Text("Enjoying ScrollSnap?")
                        .font(.title3.weight(.bold))

                    Text("Built by one developer. Your support\nkeeps it alive and improving.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 22)
            .padding(.horizontal, 16)

            Divider()

            // ── Actions ──────────────────────────────────────────────────
            if supportStore.thankYouShown {
                Label("Thank you so much! 🙏", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.pink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 16) {

                    // Coffee buttons
                    if supportStore.products.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(supportStore.products) { product in
                                let info = coffeeMap[product.id] ?? CoffeeInfo(emoji: "☕", label: "Tip")
                                CoffeeTipButton(
                                    product: product,
                                    emoji: info.emoji,
                                    label: info.label
                                )
                            }
                        }
                    }

                    // ── or ──
                    HStack(spacing: 10) {
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(.quaternary)
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                    }

                    // Rate button
                    Button {
                        supportStore.markReviewedSupport()
                        openURL(appStoreWriteReviewURL)
                    } label: {
                        Label("Leave a Review on the App Store", systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(SupportPalette.buttonGradient)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(SupportPalette.lightAmber.opacity(0.18), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)

                    Text("Every ★★★★★ review makes a real difference.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        // Warm amber tint that fades to grouped background
        .background(
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground)
                SupportPalette.panelBackground(isActive: supportStore.hasSupporterBadge)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 4)
    }
}

private struct CoffeeTipButton: View {
    @EnvironmentObject private var supportStore: SupportStore
    let product: Product
    let emoji: String
    let label: LocalizedStringResource

    var body: some View {
        Button {
            Task { await supportStore.purchase(product) }
        } label: {
            VStack(spacing: 5) {
                Text(emoji)
                    .font(.title2)

                Text(product.displayPrice)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(supportStore.isPurchasing)
    }
}

private struct TipButton: View {
    @EnvironmentObject private var supportStore: SupportStore
    let product: Product
    var onPurchased: (() -> Void)? = nil

    private static let emojiMap: [String: String] = [
        "com.scrollsnap.tip.small":  "☕",
        "com.scrollsnap.tip.medium": "☕☕",
        "com.scrollsnap.tip.large":  "☕☕☕",
    ]

    var body: some View {
        Button {
            Task {
                let success = await supportStore.purchase(product)
                if success { onPurchased?() }
            }
        } label: {
            VStack(spacing: 4) {
                Text(Self.emojiMap[product.id] ?? "☕")
                    .font(.title3)
                Text(product.displayPrice)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SupportPalette.lightAmber.opacity(0.22), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(supportStore.isPurchasing)
    }
}

private struct SupportPromptSheet: View {
    @EnvironmentObject private var supportStore: SupportStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private let appStoreWriteReviewURL = URL(string: "https://apps.apple.com/app/id6759849068?action=write-review")!

    private var showsHeroIcon: Bool {
        UIDevice.current.userInterfaceIdiom != .pad
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                if showsHeroIcon {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(SupportPalette.deepAmber)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }

                Text("Enjoying ScrollSnap?")
                    .font(.title2.weight(.bold))

                Text("A quick review helps others discover the app — and means the world to an indie developer.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            VStack(spacing: 14) {
                Button {
                    supportStore.markReviewedSupport()
                    openURL(appStoreWriteReviewURL)
                    dismiss()
                } label: {
                    Label("Leave a Review on the App Store", systemImage: "star.fill")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(SupportPalette.buttonGradient)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(SupportPalette.lightAmber.opacity(0.18), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .controlSize(.large)

                if !supportStore.products.isEmpty {
                    VStack(spacing: 8) {
                                Text("or buy a coffee")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(supportStore.products) { product in
                                TipButton(product: product, onPurchased: { dismiss() })
                            }
                        }
                    }
                }
            }

            Button("Maybe Later") {
                dismiss()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(24)
        .background(SupportPalette.opaqueSheetBackground)
        .presentationBackground {
            SupportPalette.opaqueSheetBackground
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    ContentView()
}
