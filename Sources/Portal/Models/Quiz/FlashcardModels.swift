import Foundation

// MARK: - Flashcard Model

/// A single flashcard with front (question) and back (answer) sides.
/// Used for self-graded spaced repetition study.
///
/// `id` is a String: card identity round-trips through the gateway learning
/// store (server-minted `c-<hex8>` ids); locally-minted cards use a UUID
/// string, which the gateway id grammar accepts, so no translation table.
/// Legacy files decode unchanged — Swift encodes UUID as a JSON string.
struct Flashcard: Identifiable, Codable, Equatable {
    internal let id: String
    let front: String
    let back: String
    let explanation: String
    let category: String?
    let tags: [String]

    internal init(front: String, back: String, explanation: String, category: String? = nil,
                  tags: [String] = [], id: String = UUID().uuidString) {
        self.id = id
        self.front = front
        self.back = back
        self.explanation = explanation
        self.category = category
        self.tags = tags
    }
}

// MARK: - Self-Grading Quality

/// Quality of recall when self-grading a flashcard.
/// Maps to SM-2 algorithm quality values.
enum SRSQuality: Int, Codable, CaseIterable {
    /// Complete failure — couldn't recall at all
    case blackout = 0
    /// Recalled with serious difficulty — "Almost"
    case difficult = 2
    /// Recalled correctly with some hesitation
    case good = 4
    /// Perfect recall, effortless — "Knew it"
    case perfect = 5

    var label: String {
        switch self {
        case .blackout: return "Didn't know"
        case .difficult: return "Almost"
        case .good: return "Good"
        case .perfect: return "Knew it"
        }
    }

    var emoji: String {
        switch self {
        case .blackout: return "🔴"
        case .difficult: return "🟡"
        case .good: return "🟢"
        case .perfect: return "⭐"
        }
    }
}

// MARK: - Spaced Repetition State

/// SM-2 spaced repetition state for a single flashcard.
/// Persisted as part of FlashcardDeck.
struct SRSState: Codable, Equatable {
    /// The flashcard this state tracks
    internal var cardID: String
    /// Days until next review (0 = due now, 1 = tomorrow, 6 = next week, etc.)
    var interval: TimeInterval = 0
    /// SM-2 ease factor (minimum 1.3, default 2.5)
    var easeFactor: Double = 2.5
    /// Number of consecutive correct reviews (quality >= 3)
    var repetitions: Int = 0
    /// When this card should be reviewed again
    internal var nextReviewDate = Date()
    /// When this card was last reviewed
    var lastReviewedAt: Date?
    /// Quality score from last review
    var lastQuality: Int = 0
    /// Total number of reviews for this card
    var reviewCount: Int = 0

    /// True if the card is due for review right now.
    var isDue: Bool {
        Date() >= nextReviewDate
    }

    internal init(cardID: String) {
        self.cardID = cardID
    }
}

// MARK: - Flashcard Deck

/// A collection of flashcards with SRS state, persisted across sessions.
struct FlashcardDeck: Identifiable, Codable, Equatable {
    internal let id: String
    let topic: String
    var cards: [Flashcard]
    internal var srsStates: [String: SRSState]
    let created: Date
    let sourceSessionID: String?
    /// Gateway revision. 0 = local-only (never pushed) — the migration
    /// marker `LearningStore.pull()` uses, mirroring `LivingArtifact`.
    internal var rev: Int = 0

    /// Number of cards due for review right now.
    var dueCount: Int {
        cards.filter { card in
            srsStates[card.id]?.isDue ?? true
        }.count
    }

    /// Total number of cards in this deck.
    var totalCount: Int { cards.count }

    /// Number of cards with strong recall (3+ correct reps and healthy ease factor).
    var learnedCount: Int {
        cards.filter { card in
            guard let state = srsStates[card.id] else { return false }
            return state.repetitions >= 3 && state.easeFactor >= 2.5
        }.count
    }

    /// Cards sorted by urgency (most overdue first).
    var dueCards: [Flashcard] {
        cards.filter { card in
            srsStates[card.id]?.isDue ?? true
        }.sorted { a, b in
            let dateA = srsStates[a.id]?.nextReviewDate ?? .distantPast
            let dateB = srsStates[b.id]?.nextReviewDate ?? .distantPast
            return dateA < dateB
        }
    }

    internal init(topic: String, cards: [Flashcard], sourceSessionID: String? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.topic = topic
        self.cards = cards
        self.srsStates = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, SRSState(cardID: $0.id)) })
        self.created = Date()
        self.sourceSessionID = sourceSessionID
    }

    /// Decode tolerating BOTH key shapes for `srsStates`: Swift encodes
    /// `[UUID: SRSState]` as a FLAT ARRAY, not an object, so every deck
    /// saved before the String-id migration carries the array form on disk.
    /// A naive `[String: SRSState]` decode would throw — and since
    /// `allDecks()` drops files that fail to decode, that failure mode is
    /// the user's entire review history silently vanishing.
    internal init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.topic = try c.decode(String.self, forKey: .topic)
        self.cards = try c.decode([Flashcard].self, forKey: .cards)
        self.created = try c.decode(Date.self, forKey: .created)
        self.sourceSessionID = try c.decodeIfPresent(String.self, forKey: .sourceSessionID)
        self.rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        do {
            self.srsStates = try c.decode([String: SRSState].self, forKey: .srsStates)
        } catch {
            // Expected branch for pre-migration files: [UUID: V] encodes as
            // a flat array, which the modern object decode rejects. Only the
            // KEY shape differs — the value's cardID was a UUID, which
            // encodes as a JSON string and decodes into the String-typed
            // SRSState unchanged.
            let legacy = try c.decode([UUID: SRSState].self, forKey: .srsStates)
            self.srsStates = Dictionary(uniqueKeysWithValues: legacy.map {
                ($0.key.uuidString, $0.value)
            })
        }
    }
}

// MARK: - Agent JSON Response Parsing

/// Raw JSON structure for parsing flashcard responses from the agent.
struct FlashcardResponse: Codable {
    let flashcards: [RawFlashcard]

    struct RawFlashcard: Codable {
        let front: String
        let back: String
        let explanation: String?
        let category: String?
        let tags: [String]?

        func toFlashcard() -> Flashcard {
            Flashcard(
                front: front,
                back: back,
                explanation: explanation ?? back,
                category: category,
                tags: tags ?? []
            )
        }
    }

    /// Attempt to parse flashcard JSON from an agent's response text.
    /// Handles markdown code fences, braced JSON extraction, and lenient parsing.
    static func extract(from text: String) -> FlashcardDeck? {
        var jsonString = text

        // Strip markdown code fences
        if let range = text.range(of: "```json") {
            let start = range.upperBound
            if let end = text[start...].range(of: "```") {
                jsonString = String(text[start..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let range = text.range(of: "```") {
            let start = range.upperBound
            if let end = text[start...].range(of: "```") {
                jsonString = String(text[start..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Try to extract braced JSON
        let attempts: [String] = [
            jsonString,
            extractBracedJSON(from: text) ?? jsonString
        ]

        for attempt in attempts {
            guard let data = attempt.data(using: .utf8) else { continue }

            // Try strict Codable parse
            if let response = try? JSONDecoder().decode(FlashcardResponse.self, from: data) {
                let cards = response.flashcards.map { $0.toFlashcard() }
                let topic = cards.first?.category ?? "Flashcards"
                return FlashcardDeck(topic: topic, cards: cards)
            }

            // Try lenient JSONSerialization parse
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let flashcardsArray = json["flashcards"] as? [[String: Any]] {
                let cards = flashcardsArray.compactMap { dict -> Flashcard? in
                    guard let front = dict["front"] as? String,
                          let back = dict["back"] as? String else { return nil }
                    return Flashcard(
                        front: front,
                        back: back,
                        explanation: dict["explanation"] as? String ?? back,
                        category: dict["category"] as? String,
                        tags: dict["tags"] as? [String] ?? []
                    )
                }
                guard !cards.isEmpty else { return nil }
                let topic = cards.first?.category ?? "Flashcards"
                return FlashcardDeck(topic: topic, cards: cards)
            }
        }

        return nil
    }

    private static func extractBracedJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }
}
