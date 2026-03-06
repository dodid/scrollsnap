import Foundation
import Combine
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [GeneratedImageItem] = []

    private let fileManager = FileManager.default
    private let imagesDirectoryURL: URL
    private let indexURL: URL
    /// Ever-increasing counter – never decremented, never reused.
    private static let nextSequenceNumberKey = "nextSequenceNumber"
    private var nextSequenceNumber: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.nextSequenceNumberKey)
            return v > 0 ? v : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.nextSequenceNumberKey) }
    }

    init() {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        imagesDirectoryURL = documentsURL.appendingPathComponent("Generated", isDirectory: true)
        indexURL = documentsURL.appendingPathComponent("generated-index.json")

        do {
            try fileManager.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("Failed to create generated images directory: \(error.localizedDescription)")
        }

        loadIndex()
    }

    var usedStorageText: String {
        let bytes = items.reduce(into: Int64(0)) { total, item in
            guard let size = try? fileSize(for: imageURL(for: item)) else { return }
            total += Int64(size)
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func imageURL(for item: GeneratedImageItem) -> URL {
        imagesDirectoryURL.appendingPathComponent(item.imageFilename)
    }

    func image(for item: GeneratedImageItem) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: item).path)
    }

    @discardableResult
    func addImage(_ image: UIImage) throws -> GeneratedImageItem {
        guard let jpegData = image.jpegData(compressionQuality: 0.95), let cgImage = image.cgImage else {
            throw LibraryStoreError.failedToEncodeImage
        }

        let filename = "\(UUID().uuidString).jpg"
        let outputURL = imagesDirectoryURL.appendingPathComponent(filename)
        try jpegData.write(to: outputURL, options: [.atomic])

        let assignedNumber = nextSequenceNumber
        nextSequenceNumber = assignedNumber + 1
        let item = GeneratedImageItem(
            imageFilename: filename,
            width: cgImage.width,
            height: cgImage.height,
            sequenceNumber: assignedNumber
        )

        items.insert(item, at: 0)
        try saveIndex()
        return item
    }

    func update(_ updatedItem: GeneratedImageItem) {
        guard let index = items.firstIndex(where: { $0.id == updatedItem.id }) else { return }
        items[index] = updatedItem
        sortItems()
        try? saveIndex()
    }

    func delete(_ item: GeneratedImageItem) {
        try? fileManager.removeItem(at: imageURL(for: item))
        items.removeAll { $0.id == item.id }
        try? saveIndex()
    }

    func clearAll() {
        for item in items {
            try? fileManager.removeItem(at: imageURL(for: item))
        }
        items.removeAll()
        try? saveIndex()
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([GeneratedImageItem].self, from: data)
            var filtered = decoded.filter { fileManager.fileExists(atPath: imageURL(for: $0).path) }
            filtered = migratingSequenceNumbers(in: filtered)
            items = filtered
            sortItems()
        } catch {
            print("Failed to read generated index: \(error.localizedDescription)")
            items = []
        }
    }

    private func saveIndex() throws {
        try saveIndex(items)
    }

    private func saveIndex(_ snapshot: [GeneratedImageItem]) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: indexURL, options: [.atomic])
    }

    private func sortItems() {
        items.sort { $0.createdAt > $1.createdAt }
    }

    /// Assigns permanent sequence numbers to any items that were stored before
    /// the sequenceNumber field was introduced (sequenceNumber == 0).
    private func migratingSequenceNumbers(in list: [GeneratedImageItem]) -> [GeneratedImageItem] {
        let needsMigration = list.filter { $0.sequenceNumber == 0 }
        guard !needsMigration.isEmpty else { return list }

        // Assign to oldest-first so lower numbers go to earlier images.
        let sorted = needsMigration.sorted { $0.createdAt < $1.createdAt }
        var counter = nextSequenceNumber
        var mapping: [UUID: Int] = [:]
        for item in sorted {
            mapping[item.id] = counter
            counter += 1
        }
        nextSequenceNumber = counter

        let migrated = list.map { item -> GeneratedImageItem in
            guard let seq = mapping[item.id] else { return item }
            return GeneratedImageItem(
                id: item.id,
                createdAt: item.createdAt,
                imageFilename: item.imageFilename,
                width: item.width,
                height: item.height,
                sequenceNumber: seq
            )
        }
        try? saveIndex(migrated)
        return migrated
    }

    private func fileSize(for url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }
}

enum LibraryStoreError: LocalizedError {
    case failedToEncodeImage

    var errorDescription: String? {
        switch self {
        case .failedToEncodeImage:
            return String(localized: "Couldn’t encode the generated image.")
        }
    }
}
