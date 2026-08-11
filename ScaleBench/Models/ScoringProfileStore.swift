import Foundation
import Combine

struct CustomScoringProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var profile: ScoringProfile
    var updatedAt: Date

    init(id: UUID = UUID(), profile: ScoringProfile, updatedAt: Date = Date()) {
        self.id = id
        self.profile = profile
        self.updatedAt = updatedAt
    }
}

final class CustomScoringProfileStore: ObservableObject {
    @Published private(set) var profiles: [CustomScoringProfile] = []
    @Published private(set) var lastErrorMessage: String?

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        load()
    }

    @discardableResult
    func save(profile inputProfile: ScoringProfile, id: UUID? = nil) -> CustomScoringProfile? {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var profile = inputProfile.normalized
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.name.isEmpty else {
                lastErrorMessage = "Profile name cannot be empty"
                return nil
            }

            let saved = CustomScoringProfile(id: id ?? UUID(), profile: profile)
            if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
                profiles[index] = saved
            } else {
                profiles.removeAll { existing in
                    existing.profile.name.localizedCaseInsensitiveCompare(saved.profile.name) == .orderedSame
                }
                profiles.append(saved)
            }

            profiles = profiles.sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
            try persist()
            lastErrorMessage = nil
            return saved
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ profile: CustomScoringProfile) {
        do {
            profiles.removeAll { $0.id == profile.id }
            try persist()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func load() {
        do {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                profiles = []
                lastErrorMessage = nil
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([CustomScoringProfile].self, from: Data(contentsOf: fileURL))
                .sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
            lastErrorMessage = nil
        } catch {
            profiles = []
            lastErrorMessage = error.localizedDescription
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ScaleBench", isDirectory: true)
            .appendingPathComponent("ScoringProfiles", isDirectory: true)
            .appendingPathComponent("custom-scoring-profiles.json")
    }
}
