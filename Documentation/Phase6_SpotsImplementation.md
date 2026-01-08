# Phase 6: Spots & Geography - Implementation Guide

## Overview

This phase adds community features and rich media to flight spots, including community-driven spot name validation, weather integration, and photo galleries.

---

## 6.1 Community Validation System for Spot Renaming

**Complexity**: Very High (Multi-week feature)

### Architecture

This feature allows pilots to propose spot name changes, which are then voted on by the community before being applied.

### New Appwrite Collection: `spot_rename_proposals`

**Schema**:
```javascript
{
  collectionId: "spot_rename_proposals",
  name: "Spot Rename Proposals",
  permissions: [
    // Read: Anyone
    Permission.read(Role.users()),
    // Create: Authenticated users only
    Permission.create(Role.users()),
    // Update: Only proposal creator + moderators
    Permission.update(Role.user("[USER_ID]")),
    Permission.update(Role.team("moderators"))
  ],
  attributes: [
    {
      key: "spotId",
      type: "string",
      required: true,
      size: 100
    },
    {
      key: "currentName",
      type: "string",
      required: true,
      size: 200
    },
    {
      key: "proposedName",
      type: "string",
      required: true,
      size: 200
    },
    {
      key: "proposedBy",
      type: "string",  // userId
      required: true,
      size: 100
    },
    {
      key: "reason",
      type: "string",
      required: false,
      size: 500
    },
    {
      key: "votes",
      type: "string",  // JSON: {"userId1": true, "userId2": false, ...}
      required: true,
      size: 10000,  // Supports ~300 votes
      default: "{}"
    },
    {
      key: "status",
      type: "enum",
      elements: ["pending", "approved", "rejected", "expired"],
      required: true,
      default: "pending"
    },
    {
      key: "voteCount",
      type: "integer",
      required: true,
      default: 0
    },
    {
      key: "approvalCount",
      type: "integer",
      required: true,
      default: 0
    },
    {
      key: "createdAt",
      type: "datetime",
      required: true
    },
    {
      key: "expiresAt",
      type: "datetime",
      required: true
    },
    {
      key: "resolvedAt",
      type: "datetime",
      required: false
    }
  ],
  indexes: [
    {
      key: "spotId_idx",
      type: "key",
      attributes: ["spotId"]
    },
    {
      key: "status_idx",
      type: "key",
      attributes: ["status"]
    },
    {
      key: "proposedBy_idx",
      type: "key",
      attributes: ["proposedBy"]
    }
  ]
}
```

### New Service: `SpotModerationService.swift`

```swift
import Foundation
import Appwrite

@Observable
class SpotModerationService {
    static let shared = SpotModerationService()

    private let databases: Databases
    private let tablesDB: String

    private(set) var activeProposals: [SpotRenameProposal] = []

    private init() {
        self.databases = AppwriteService.shared.databases
        self.tablesDB = AppwriteService.shared.tablesDB
    }

    // MARK: - Create Proposal

    func proposeRename(
        spotId: String,
        currentName: String,
        proposedName: String,
        reason: String?
    ) async throws -> SpotRenameProposal {
        guard let userId = try? await AuthService.shared.getCurrentUserId() else {
            throw SpotModerationError.notAuthenticated
        }

        // Check if user has flown at this spot
        guard try await hasUserFlownAtSpot(userId: userId, spotId: spotId) else {
            throw SpotModerationError.notEligibleToPropose
        }

        // Check for existing active proposals for this spot
        if try await hasActivePendingProposal(spotId: spotId) {
            throw SpotModerationError.proposalAlreadyExists
        }

        // Create proposal
        let expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: Date())!

        let data: [String: Any] = [
            "spotId": spotId,
            "currentName": currentName,
            "proposedName": proposedName,
            "proposedBy": userId,
            "reason": reason ?? "",
            "votes": "{}",
            "status": "pending",
            "voteCount": 0,
            "approvalCount": 0,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt)
        ]

        let document = try await databases.createDocument(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.spotRenameProposalsCollection,
            documentId: ID.unique(),
            data: data
        )

        let proposal = try decodeProposal(from: document)

        // Award XP for proposing
        await UserService.shared.awardXP(5, reason: "Proposition de renommage de spot")

        return proposal
    }

    // MARK: - Vote

    func vote(proposalId: String, approve: Bool) async throws {
        guard let userId = try? await AuthService.shared.getCurrentUserId() else {
            throw SpotModerationError.notAuthenticated
        }

        // Fetch proposal
        let document = try await databases.getDocument(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.spotRenameProposalsCollection,
            documentId: proposalId
        )

        var proposal = try decodeProposal(from: document)

        // Check eligibility (user has flown at this spot)
        guard try await hasUserFlownAtSpot(userId: userId, spotId: proposal.spotId) else {
            throw SpotModerationError.notEligibleToVote
        }

        // Update votes
        var votes = proposal.votesDict
        votes[userId] = approve

        let newVoteCount = votes.count
        let newApprovalCount = votes.values.filter { $0 }.count

        // Update document
        try await databases.updateDocument(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.spotRenameProposalsCollection,
            documentId: proposalId,
            data: [
                "votes": try JSONEncoder().encode(votes).base64EncodedString(),
                "voteCount": newVoteCount,
                "approvalCount": newApprovalCount
            ]
        )

        // Check if quorum reached (10 votes OR 7 days passed)
        if newVoteCount >= 10 {
            try await resolveProposal(proposalId: proposalId)
        }

        // Award XP for voting
        await UserService.shared.awardXP(1, reason: "Vote sur proposition de spot")
    }

    // MARK: - Resolution

    private func resolveProposal(proposalId: String) async throws {
        let document = try await databases.getDocument(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.spotRenameProposalsCollection,
            documentId: proposalId
        )

        let proposal = try decodeProposal(from: document)

        // Calculate approval rate
        let approvalRate = Double(proposal.approvalCount) / Double(proposal.voteCount)

        let approved = approvalRate >= 0.7  // 70% threshold

        // Update status
        try await databases.updateDocument(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.spotRenameProposalsCollection,
            documentId: proposalId,
            data: [
                "status": approved ? "approved" : "rejected",
                "resolvedAt": ISO8601DateFormatter().string(from: Date())
            ]
        )

        if approved {
            // Apply rename (update all flights with this spot)
            try await applySpotRename(spotId: proposal.spotId, newName: proposal.proposedName)

            // Award XP to proposer
            await UserService.shared.awardXP(50, toUser: proposal.proposedBy, reason: "Renommage de spot approuvé")

            // Create notification
            await NotificationService.shared.createNotification(
                userId: proposal.proposedBy,
                type: .spotRenameApproved,
                message: "Votre proposition de renommage pour \"\(proposal.currentName)\" a été approuvée !"
            )
        }
    }

    private func applySpotRename(spotId: String, newName: String) async throws {
        // This would require an Appwrite Function for bulk updates
        // Or batch update all flights locally then sync

        // For now, documented as TODO:
        // Appwrite Function to bulk update all flights with spotId
        logInfo("Spot rename approved: \(spotId) -> \(newName)", category: .spots)
    }

    // MARK: - Helpers

    private func hasUserFlownAtSpot(userId: String, spotId: String) async throws -> Bool {
        // Query user's flights for this spot
        let queries = [
            Query.equal("userId", value: userId),
            Query.equal("spotId", value: spotId),
            Query.limit(1)
        ]

        let result = try await databases.listDocuments(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.flightsCollection,
            queries: queries
        )

        return result.total > 0
    }

    private func hasActivePendingProposal(spotId: String) async throws -> Bool {
        let queries = [
            Query.equal("spotId", value: spotId),
            Query.equal("status", value: "pending"),
            Query.limit(1)
        ]

        let result = try await databases.listDocuments(
            databaseId: tablesDB,
            collectionId: AppwriteConfig.spotRenameProposalsCollection,
            queries: queries
        )

        return result.total > 0
    }

    private func decodeProposal(from document: Document) throws -> SpotRenameProposal {
        // Decode logic
        // ...
    }
}

// MARK: - Models

struct SpotRenameProposal: Identifiable, Codable {
    let id: String
    let spotId: String
    let currentName: String
    let proposedName: String
    let proposedBy: String
    let reason: String?
    let votes: String  // JSON string
    let status: ProposalStatus
    let voteCount: Int
    let approvalCount: Int
    let createdAt: Date
    let expiresAt: Date
    let resolvedAt: Date?

    var votesDict: [String: Bool] {
        get {
            guard let data = votes.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            votes = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}"
        }
    }

    enum ProposalStatus: String, Codable {
        case pending
        case approved
        case rejected
        case expired
    }
}

enum SpotModerationError: LocalizedError {
    case notAuthenticated
    case notEligibleToPropose
    case notEligibleToVote
    case proposalAlreadyExists

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .notEligibleToPropose:
            return "Vous devez avoir volé à ce spot pour proposer un renommage"
        case .notEligibleToVote:
            return "Vous devez avoir volé à ce spot pour voter"
        case .proposalAlreadyExists:
            return "Une proposition est déjà en cours pour ce spot"
        }
    }
}
```

### UI: Spot Rename Proposal View

**File**: `Views/SpotRenameProposalView.swift`

```swift
struct SpotRenameProposalView: View {
    let spotId: String
    let currentName: String

    @State private var proposedName = ""
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Nom actuel") {
                Text(currentName)
                    .foregroundStyle(.secondary)
            }

            Section("Nouveau nom proposé") {
                TextField("Nom du spot", text: $proposedName)
            }

            Section("Raison (optionnel)") {
                TextEditor(text: $reason)
                    .frame(height: 100)
            }

            Section {
                Button("Proposer") {
                    Task { await submit() }
                }
                .disabled(proposedName.isEmpty || isSubmitting)
            }

            if let error = error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Renommer le spot")
    }

    private func submit() async {
        isSubmitting = true
        error = nil

        do {
            _ = try await SpotModerationService.shared.proposeRename(
                spotId: spotId,
                currentName: currentName,
                proposedName: proposedName,
                reason: reason.isEmpty ? nil : reason
            )

            // Success - dismiss
            // ...
        } catch {
            self.error = error.localizedDescription
        }

        isSubmitting = false
    }
}
```

**Voting UI**: Add to SpotDetailView

```swift
// In SpotDetailView
if let activeProposal = spotProposal {
    Section("Proposition de renommage") {
        VStack(alignment: .leading, spacing: 8) {
            Text("Renommer \"\(activeProposal.currentName)\" en \"\(activeProposal.proposedName)\"")
                .font(.headline)

            if let reason = activeProposal.reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("\(activeProposal.approvalCount) approuvent")
                    .foregroundStyle(.green)
                Text("•")
                Text("\(activeProposal.voteCount - activeProposal.approvalCount) rejettent")
                    .foregroundStyle(.red)
            }
            .font(.caption)

            HStack(spacing: 12) {
                Button("Approuver") {
                    Task {
                        try? await SpotModerationService.shared.vote(
                            proposalId: activeProposal.id,
                            approve: true
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Rejeter") {
                    Task {
                        try? await SpotModerationService.shared.vote(
                            proposalId: activeProposal.id,
                            approve: false
                        )
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }
}
```

---

## 6.2 Weather Display on Spots

**Complexity**: Medium

### Weather API Integration

**Recommended API**: OpenWeatherMap (free tier: 1000 calls/day)

### New Service: `WeatherService.swift` (Enhancement)

```swift
// Assuming WeatherService already exists, add spot-specific method

extension WeatherService {
    func getSpotWeather(latitude: Double, longitude: Double) async throws -> SpotWeather {
        // Call OpenWeatherMap API
        let apiKey = AppwriteConfig.openWeatherApiKey
        let url = "https://api.openweathermap.org/data/2.5/weather?lat=\(latitude)&lon=\(longitude)&appid=\(apiKey)&units=metric&lang=fr"

        // Fetch weather data
        // Parse response
        // Return SpotWeather model
        // ...
    }
}

struct SpotWeather {
    let temperature: Double
    let feelsLike: Double
    let windSpeed: Double  // m/s
    let windDirection: Int  // degrees
    let gusts: Double?
    let description: String
    let icon: String
    let pressure: Double
    let humidity: Int
    let visibility: Int?

    var flyability: Flyability {
        // Simple heuristic
        if windSpeed > 15 { return .dangerous }
        if windSpeed > 10 { return .challenging }
        if windSpeed < 3 { return .light }
        return .good
    }

    enum Flyability {
        case light, good, challenging, dangerous

        var color: Color {
            switch self {
            case .light: return .yellow
            case .good: return .green
            case .challenging: return .orange
            case .dangerous: return .red
            }
        }

        var label: String {
            switch self {
            case .light: return "Vent léger"
            case .good: return "Bonnes conditions"
            case .challenging: return "Difficile"
            case .dangerous: return "Dangereux"
            }
        }
    }
}
```

### UI: Weather Card in SpotDetailView

```swift
// Add to SpotDetailView
if let weather = spotWeather {
    Section("Météo actuelle") {
        VStack(spacing: 12) {
            HStack {
                // Weather icon
                AsyncImage(url: URL(string: "https://openweathermap.org/img/wn/\(weather.icon)@2x.png")) { image in
                    image.resizable()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading) {
                    Text("\(Int(weather.temperature))°C")
                        .font(.title)
                        .fontWeight(.bold)
                    Text(weather.description.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Flyability indicator
                VStack {
                    Image(systemName: weather.flyability == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(weather.flyability.color)
                    Text(weather.flyability.label)
                        .font(.caption)
                }
            }

            Divider()

            // Wind info
            HStack {
                Label("\(Int(weather.windSpeed * 3.6)) km/h", systemImage: "wind")
                if let gusts = weather.gusts {
                    Text("(rafales: \(Int(gusts * 3.6)) km/h)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Direction: \(weather.windDirection)°")
                    .font(.caption)
            }
        }
    }
}
```

---

## 6.3 Add Photos to Spots

**Complexity**: Medium

**Note**: Appwrite free tier allows only 1 storage bucket. Use prefixes for organization.

### Storage Organization

- Bucket: `app-storage` (existing)
- Prefixes:
  - `wings/` → Wing photos
  - `profiles/` → Profile photos
  - `spots/` → Spot photos
  - `flights/` → Flight photos

### New Service Method: `SpotService.uploadSpotPhoto()`

```swift
// Add to SpotService.swift

func uploadSpotPhoto(spotId: String, image: UIImage) async throws -> String {
    // Compress image
    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
        throw SpotError.invalidImage
    }

    // Size limit: 5MB
    guard imageData.count <= 5 * 1024 * 1024 else {
        throw SpotError.imageTooLarge
    }

    // Generate file ID with prefix
    let timestamp = Date().timeIntervalSince1970
    let fileId = "spots/\(spotId)/\(timestamp)_\(UUID().uuidString).jpg"

    // Upload to Appwrite Storage
    let file = try await AppwriteService.shared.storage.createFile(
        bucketId: AppwriteConfig.storageBucketId,
        fileId: fileId,
        file: InputFile.fromData(imageData, filename: "spot.jpg", mimeType: "image/jpeg")
    )

    // Link photo to spot in database
    try await linkPhotoToSpot(spotId: spotId, photoFileId: file.id)

    return file.id
}

private func linkPhotoToSpot(spotId: String, photoFileId: String) async throws {
    // Option 1: Add to Spot model (if spots have their own collection)
    // Option 2: Create separate SpotPhoto collection
    // Recommended: SpotPhoto collection for scalability

    let data: [String: Any] = [
        "spotId": spotId,
        "photoFileId": photoFileId,
        "uploadedBy": try await AuthService.shared.getCurrentUserId(),
        "uploadedAt": ISO8601DateFormatter().string(from: Date()),
        "votes": 0  // For community voting on best photos
    ]

    _ = try await databases.createDocument(
        databaseId: tablesDB,
        collectionId: AppwriteConfig.spotPhotosCollection,
        documentId: ID.unique(),
        data: data
    )
}

func getSpotPhotos(spotId: String) async throws -> [SpotPhoto] {
    let queries = [
        Query.equal("spotId", value: spotId),
        Query.orderDesc("votes"),  // Best photos first
        Query.limit(50)
    ]

    let result = try await databases.listDocuments(
        databaseId: tablesDB,
        collectionId: AppwriteConfig.spotPhotosCollection,
        queries: queries
    )

    return try result.documents.map { try decodeSpotPhoto(from: $0) }
}
```

### UI: Spot Photo Gallery

```swift
// In SpotDetailView
if !spotPhotos.isEmpty {
    Section("Photos") {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(spotPhotos) { photo in
                    SpotPhotoThumbnail(photo: photo)
                        .onTapGesture {
                            selectedPhoto = photo
                        }
                }
            }
            .padding(.horizontal)
        }
    }
    .listRowInsets(EdgeInsets())
}

// Add photo button
Button {
    showingPhotoUpload = true
} label: {
    Label("Ajouter une photo", systemImage: "camera.fill")
}
```

---

## Implementation Priority

1. **Phase 6.2 (Weather)**: Medium priority, high user value, medium complexity ✅ Implement first
2. **Phase 6.3 (Photos)**: Medium priority, high engagement, medium complexity ✅ Implement second
3. **Phase 6.1 (Spot Renaming)**: Low priority initially, very complex, defer to post-launch

---

## Testing Checklist

### Weather
- [ ] API calls respect rate limits (cache for 15 minutes)
- [ ] Handles offline gracefully
- [ ] Weather icons display correctly
- [ ] Flyability indicator is accurate
- [ ] Works for spots worldwide

### Photos
- [ ] Image compression works (reduces size to <1MB)
- [ ] Upload progress indicator
- [ ] Photos display in gallery
- [ ] Handles upload errors
- [ ] Storage quota not exceeded

### Spot Renaming
- [ ] Only eligible users can propose/vote
- [ ] Voting works correctly
- [ ] Quorum and threshold calculated properly
- [ ] Notifications sent on resolution
- [ ] XP awarded correctly

---

*Phase 6 Implementation Guide - SoarX*
*Last Updated: 2026-01-07*
