import Foundation

struct GeneratedImageItem: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let imageFilename: String
    let width: Int
    let height: Int
    /// Persistent 1-based sequence number assigned once at creation. Never reused.
    let sequenceNumber: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        imageFilename: String,
        width: Int,
        height: Int,
        sequenceNumber: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.imageFilename = imageFilename
        self.width = width
        self.height = height
        self.sequenceNumber = sequenceNumber
    }

    /// Human-readable name that never changes for this item.
    var displayName: String {
        String(format: String(localized: "Image %03d"), sequenceNumber)
    }
}

// MARK: - Codable (with migration for items created before sequenceNumber was added)

extension GeneratedImageItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, imageFilename, width, height, sequenceNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id             = try container.decode(UUID.self,   forKey: .id)
        createdAt      = try container.decode(Date.self,   forKey: .createdAt)
        imageFilename  = try container.decode(String.self, forKey: .imageFilename)
        width          = try container.decode(Int.self,    forKey: .width)
        height         = try container.decode(Int.self,    forKey: .height)
        // Default to 0 for items stored before this field was introduced.
        sequenceNumber = (try? container.decode(Int.self,  forKey: .sequenceNumber)) ?? 0
    }
}
