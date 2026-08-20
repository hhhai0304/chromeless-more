//
// The AI side of the browser: one AI endpoint, one conversation per tab, and the
// page the tab is showing handed over as context.
//
// Four things live here — the provider templates, the settings on disk, a thin
// OpenAI-compatible client, and the per-tab chat session. The views are in
// AIUI.swift, the wiring in main.swift.
//
// Any provider speaking the OpenAI chat-completions dialect works, which by now
// is nearly all of them: OpenAI, OpenRouter, Gemini (its OpenAI-compatible
// endpoint), Anthropic (same), Groq, DeepSeek, xAI, Mistral, and anything local
// serving that shape. So the whole configuration is three fields — base URL, API
// key, model id — and the templates only exist to fill the first one in and
// suggest model ids for the third.
//
// Scope is deliberately per tab: a `Tab` owns its `AIChatSession`, so switching
// tabs switches the conversation, closing a tab throws it away, and a second tab
// on the same site starts a fresh thread. The sidebar itself is per window; it
// just paints whichever session the active tab holds.

import Cocoa
import CryptoKit
import WebKit

extension Notification.Name {
    static let aiSettingsDidChange = Notification.Name("chromeless.aiSettingsDidChange")
    static let aiButtonPreferenceDidChange = Notification.Name("chromeless.aiButtonDidChange")
}

/// Whether the little round AI button shows next to the profile chip. Off by
/// default — the window is supposed to be the page — and shared by every window,
/// which is why it lives in defaults rather than on a controller.
enum AIButtonPreference {
    private static let key = "ChromelessShowAIButton"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        NotificationCenter.default.post(name: .aiButtonPreferenceDidChange, object: nil)
    }
}

// MARK: - Providers

/// A starting point, not a driver: every template ends up as the same three
/// fields, and a provider nobody thought of is reachable by typing its base URL.
struct AIProviderTemplate {
    let id: String
    let name: String
    /// Everything up to but not including `/chat/completions`.
    let baseURL: String
    /// Suggestions for the model field, shown when the endpoint cannot list its
    /// own models — and as the fallback while a listing is still in flight.
    let models: [String]
    /// `GET {base}/models` returns an OpenAI-shaped list.
    let listsModels: Bool
    let keysURL: String?
    let note: String

    static let custom = AIProviderTemplate(
        id: "custom", name: "Custom (OpenAI-compatible)",
        baseURL: "", models: [], listsModels: true, keysURL: nil,
        note: "Any endpoint that serves POST {base}/chat/completions.")

    static let all: [AIProviderTemplate] = [
        AIProviderTemplate(
            id: "openrouter", name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            models: [
                "openai/gpt-4o-mini",
                "openai/gpt-4o",
                "anthropic/claude-3.5-sonnet",
                "google/gemini-2.0-flash-001",
                "deepseek/deepseek-chat",
                "meta-llama/llama-3.3-70b-instruct",
            ],
            listsModels: true, keysURL: "https://openrouter.ai/keys",
            note: "One key for every model, and the key endpoint reports credit left."),
        AIProviderTemplate(
            id: "openai", name: "OpenAI (ChatGPT)",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini"],
            listsModels: true, keysURL: "https://platform.openai.com/api-keys",
            note: "Uses the API, not a ChatGPT subscription — billing is per token."),
        AIProviderTemplate(
            id: "gemini", name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            models: ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro", "gemini-2.0-flash"],
            listsModels: true, keysURL: "https://aistudio.google.com/apikey",
            note: "Google's OpenAI-compatible endpoint. A 503 here means the model is busy — retry."),
        AIProviderTemplate(
            id: "anthropic", name: "Anthropic (Claude)",
            baseURL: "https://api.anthropic.com/v1",
            models: [
                "claude-sonnet-4-20250514",
                "claude-3-7-sonnet-latest",
                "claude-3-5-haiku-latest",
            ],
            listsModels: false, keysURL: "https://console.anthropic.com/settings/keys",
            note: "Anthropic's OpenAI-compatible layer. It cannot list models, so type the id."),
        AIProviderTemplate(
            id: "groq", name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"],
            listsModels: true, keysURL: "https://console.groq.com/keys",
            note: "Fast and free-tiered; model ids change often, so load the list."),
        AIProviderTemplate(
            id: "deepseek", name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-chat", "deepseek-reasoner"],
            listsModels: true, keysURL: "https://platform.deepseek.com/api_keys",
            note: ""),
        AIProviderTemplate(
            id: "xai", name: "xAI (Grok)",
            baseURL: "https://api.x.ai/v1",
            models: ["grok-2-latest", "grok-beta"],
            listsModels: true, keysURL: "https://console.x.ai",
            note: ""),
        AIProviderTemplate(
            id: "mistral", name: "Mistral",
            baseURL: "https://api.mistral.ai/v1",
            models: ["mistral-small-latest", "mistral-large-latest", "open-mistral-nemo"],
            listsModels: true, keysURL: "https://console.mistral.ai/api-keys",
            note: ""),
        AIProviderTemplate(
            id: "ollama", name: "Ollama (local)",
            baseURL: "http://localhost:11434/v1",
            models: ["llama3.2", "qwen2.5", "mistral"],
            listsModels: true, keysURL: nil,
            note: "Runs on this machine, so the key can stay empty."),
        AIProviderTemplate(
            id: "lmstudio", name: "LM Studio (local)",
            baseURL: "http://localhost:1234/v1",
            models: [],
            listsModels: true, keysURL: nil,
            note: "Start the local server in LM Studio, then load the model list."),
        .custom,
    ]

    static func template(id: String?) -> AIProviderTemplate {
        all.first { $0.id == id } ?? .custom
    }

    /// Which template a base URL belongs to, so a settings file written by hand
    /// still shows the right provider in the picker.
    static func matching(baseURL: String) -> AIProviderTemplate? {
        let normalized = AISettings.normalize(baseURL)
        return all.first { !$0.baseURL.isEmpty && AISettings.normalize($0.baseURL) == normalized }
    }
}

// MARK: - Settings

/// One endpoint the user has set up: where it is, the key it wants, and the
/// models added under it.
///
/// The check is per provider, not per model, because the base URL and the key are
/// what can be wrong in a way worth blocking on. A bad model id fails on the
/// first question instead, in the endpoint's own words — which is cheaper than a
/// probe for every id someone adds.
struct AIProvider: Codable, Equatable {
    var id = AIProvider.newID()
    var templateID = AIProviderTemplate.custom.id
    var name = AIProviderTemplate.custom.name
    var baseURL = ""
    var apiKey = ""
    /// Added under this provider, in the order they were added. This is the list
    /// the sidebar's picker offers.
    var models: [String] = []
    var verifiedLabel: String?
    var verifiedAt: Date?
    /// The URL and key that actually answered. Editing either drops the stamp, so
    /// a typo can never ride along on an old pass.
    var verifiedFingerprint: String?

    static func newID() -> String { UUID().uuidString }

    static func from(_ template: AIProviderTemplate) -> AIProvider {
        AIProvider(templateID: template.id, name: template.name, baseURL: template.baseURL)
    }

    var template: AIProviderTemplate { AIProviderTemplate.template(id: templateID) }
    /// A digest of the URL and the key, not the key itself. The file already holds
    /// the key once because requests need it back; a second plaintext copy in a
    /// field that only ever gets compared would be a copy for nothing.
    var fingerprint: String {
        let material = AISettings.normalize(baseURL) + "\u{1}" + apiKey
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// What builds before the digest wrote there: the two halves in the clear.
    /// Still accepted, so an upgrade does not ask for every provider to be checked
    /// again — and `tidy()` writes the digest back over it.
    var legacyFingerprint: String { AISettings.normalize(baseURL) + "\u{1}" + apiKey }

    var isVerified: Bool {
        guard verifiedAt != nil, let stored = verifiedFingerprint else { return false }
        return stored == fingerprint || stored == legacyFingerprint
    }

    /// True when the key would leave this machine in the clear: a plain-http URL
    /// that is not the local machine. `http://localhost` is how Ollama and LM
    /// Studio work and never leaves the loopback, so it is not the same thing.
    var sendsKeyInClear: Bool {
        guard !apiKey.isEmpty,
              let url = URL(string: AISettings.normalize(baseURL)),
              url.scheme?.lowercased() == "http" else { return false }
        let host = (url.host ?? "").lowercased()
        return !["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host)
            && !host.hasSuffix(".local")
    }

    /// For the lists: `generativelanguage.googleapis.com`, or the raw URL when it
    /// is too broken to parse.
    var host: String {
        let url = AISettings.normalize(baseURL)
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Missing keys read as their defaults, so a file written by an older build —
    /// or edited by hand — still loads.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(String.self, forKey: .id) ?? AIProvider.newID()
        templateID = try box.decodeIfPresent(String.self, forKey: .templateID)
            ?? AIProviderTemplate.custom.id
        baseURL = try box.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        name = try box.decodeIfPresent(String.self, forKey: .name)
            ?? AIProviderTemplate.template(id: templateID).name
        apiKey = try box.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        models = try box.decodeIfPresent([String].self, forKey: .models) ?? []
        verifiedLabel = try box.decodeIfPresent(String.self, forKey: .verifiedLabel)
        verifiedAt = try box.decodeIfPresent(Date.self, forKey: .verifiedAt)
        verifiedFingerprint = try box.decodeIfPresent(String.self, forKey: .verifiedFingerprint)
    }

    init(id: String = AIProvider.newID(),
         templateID: String = AIProviderTemplate.custom.id,
         name: String = AIProviderTemplate.custom.name,
         baseURL: String = "", apiKey: String = "", models: [String] = [],
         verifiedLabel: String? = nil, verifiedAt: Date? = nil,
         verifiedFingerprint: String? = nil) {
        self.id = id
        self.templateID = templateID
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.verifiedLabel = verifiedLabel
        self.verifiedAt = verifiedAt
        self.verifiedFingerprint = verifiedFingerprint
    }
}

/// A provider and one of its models: what a tab is talking to. Tabs hold one of
/// these, so two tabs can be on two different models at the same time.
struct AIModelRef: Codable, Equatable, Hashable {
    var providerID: String
    var model: String
}

struct AISettings: Codable, Equatable {
    var providers: [AIProvider] = []
    /// What a new tab starts on. Set by the last pick in the sidebar, so the
    /// choice carries forward without a settings trip.
    var defaultModel: AIModelRef?
    var systemPrompt = AISettings.defaultSystemPrompt
    /// How much of the page text is sent. Roughly four characters per token, so
    /// 24k characters is about 6k tokens — cheap enough to send every turn.
    var maxContextCharacters = 24_000
    var includePageByDefault = true

    static let defaultSystemPrompt = """
        You are the assistant inside Chromeless, a minimal macOS browser. The user \
        is reading a web page and the page's own text may be given to you as \
        context. Answer from that text when it is there, say so plainly when the \
        answer is not in it, and never invent quotes or numbers. Be concise: short \
        paragraphs, markdown when structure helps. Reply in the language the user \
        writes in.
        """

    /// Trailing slashes and a stray `/chat/completions` are the two things people
    /// paste by accident, so both are taken off before anything is compared.
    static func normalize(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/chat/completions", "/chat"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return text
    }

    /// `openai/gpt-4o-mini` → `gpt-4o-mini`, for the header and the transcript.
    static func shortModel(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    func provider(_ id: String?) -> AIProvider? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// Every pair the chat can actually use: the provider passed its check and
    /// the model is one of the ones added under it. This is the picker's content
    /// and the gate the sidebar honours.
    var readyModels: [AIModelRef] {
        providers.filter(\.isVerified).flatMap { provider in
            provider.models.map { AIModelRef(providerID: provider.id, model: $0) }
        }
    }

    var isReady: Bool { !readyModels.isEmpty }

    /// What a tab should talk to: what it asked for, else the default, else the
    /// first thing that works. Nil only when nothing is set up at all.
    func resolve(_ ref: AIModelRef?) -> AIModelRef? {
        let ready = readyModels
        if let ref, ready.contains(ref) { return ref }
        if let defaultModel, ready.contains(defaultModel) { return defaultModel }
        return ready.first
    }

    /// `Google Gemini · gemini-2.5-flash`, for the sidebar header.
    func label(for ref: AIModelRef?) -> String? {
        guard let ref, let provider = provider(ref.providerID) else { return nil }
        return "\(provider.name) · \(AISettings.shortModel(ref.model))"
    }

    /// Has anything been set up at all? Distinguishes "nothing here yet" from
    /// "set up but not checked", which are different things to say.
    var isBlank: Bool {
        providers.allSatisfy { $0.baseURL.isEmpty && $0.apiKey.isEmpty && $0.models.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case providers, defaultModel, systemPrompt, maxContextCharacters, includePageByDefault
    }

    /// The one-endpoint file this replaced: a base URL, a key, one model id, and a
    /// stamp naming exactly what had been checked.
    private enum LegacyKeys: String, CodingKey {
        case providerID, baseURL, apiKey, model
        case verifiedBaseURL, verifiedKey, verifiedModel, verifiedLabel, verifiedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try box.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? AISettings.defaultSystemPrompt
        maxContextCharacters = try box.decodeIfPresent(Int.self, forKey: .maxContextCharacters)
            ?? 24_000
        includePageByDefault = try box.decodeIfPresent(Bool.self, forKey: .includePageByDefault)
            ?? true
        defaultModel = try box.decodeIfPresent(AIModelRef.self, forKey: .defaultModel)
        if let providers = try box.decodeIfPresent([AIProvider].self, forKey: .providers) {
            self.providers = providers
            return
        }
        try migrateSingleEndpoint(from: decoder)
    }

    /// Reads a pre-provider-list file into one provider. The old check is kept
    /// only if it was for exactly this URL and key — the stamp named them, so
    /// there is no guessing.
    private mutating func migrateSingleEndpoint(from decoder: Decoder) throws {
        guard let box = try? decoder.container(keyedBy: LegacyKeys.self) else { return }
        let baseURL = AISettings.normalize(
            try box.decodeIfPresent(String.self, forKey: .baseURL) ?? "")
        let key = try box.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        let model = (try box.decodeIfPresent(String.self, forKey: .model) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty else { return }
        let savedID = try box.decodeIfPresent(String.self, forKey: .providerID)
        let templateID = AIProviderTemplate.matching(baseURL: baseURL)?.id
            ?? savedID ?? AIProviderTemplate.custom.id
        var provider = AIProvider.from(AIProviderTemplate.template(id: templateID))
        provider.baseURL = baseURL
        provider.apiKey = key
        provider.models = model.isEmpty ? [] : [model]
        let verifiedURL = try box.decodeIfPresent(String.self, forKey: .verifiedBaseURL)
        let verifiedKey = try box.decodeIfPresent(String.self, forKey: .verifiedKey)
        let verifiedModel = try box.decodeIfPresent(String.self, forKey: .verifiedModel)
        if verifiedURL.map(AISettings.normalize) == baseURL, verifiedKey == key,
           verifiedModel == model, !model.isEmpty {
            provider.verifiedAt = try box.decodeIfPresent(Date.self, forKey: .verifiedAt) ?? Date()
            provider.verifiedLabel = try box.decodeIfPresent(String.self, forKey: .verifiedLabel)
            provider.verifiedFingerprint = provider.fingerprint
        }
        providers = [provider]
        if !model.isEmpty {
            defaultModel = AIModelRef(providerID: provider.id, model: model)
        }
    }

    /// Everything the rest of the app is allowed to assume: URLs normalised, keys
    /// and ids trimmed, no duplicate or empty models, no stamp outliving the URL
    /// and key it was for, and a default that points at something real.
    mutating func tidy() {
        for index in providers.indices {
            var provider = providers[index]
            provider.baseURL = AISettings.normalize(provider.baseURL)
            provider.apiKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.name = provider.name.trimmingCharacters(in: .whitespaces)
            if provider.name.isEmpty { provider.name = provider.template.name }
            var seen = Set<String>()
            provider.models = provider.models
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            if provider.isVerified {
                // Upgrades a plaintext stamp in place, so the key stops being in
                // the file twice the first time anything is saved.
                provider.verifiedFingerprint = provider.fingerprint
            } else if provider.verifiedFingerprint.map({ !AIProvider.isDigest($0) }) ?? false {
                // A stamp that failed to match and is still in the old plaintext
                // form is a second copy of a key that is not even in use any more.
                provider.verifiedAt = nil
                provider.verifiedLabel = nil
                provider.verifiedFingerprint = nil
            }
            // A digest of the URL and key that were checked is kept even when it no
            // longer matches: it says the endpoint did work once, and putting the
            // old URL back makes it count again without another round trip.
            providers[index] = provider
        }
        maxContextCharacters = min(max(maxContextCharacters, 1_000), 200_000)
        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt = AISettings.defaultSystemPrompt
        }
        // The default has to name a model that still exists; being unchecked is
        // fine, since `resolve` is the thing that insists on a passing check.
        let existing = providers.flatMap { provider in
            provider.models.map { AIModelRef(providerID: provider.id, model: $0) }
        }
        if let defaultModel, existing.contains(defaultModel) { return }
        defaultModel = existing.first
    }
}

final class AISettingsStore {
    static let shared = AISettingsStore()

    private(set) var settings = AISettings()
    private let directoryURL: URL
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = appSupport.appendingPathComponent("Chromeless", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("ai.json")
        load()
    }

    /// The one way settings change: mutate, tidy, write, tell every window.
    func update(_ mutate: (inout AISettings) -> Void) {
        var next = settings
        mutate(&next)
        next.tidy()
        guard next != settings else { return }
        settings = next
        persist()
    }

    /// Adds an endpoint from a template and hands back its id, so the window can
    /// select the row it just made.
    func addProvider(_ template: AIProviderTemplate) -> String {
        let provider = AIProvider.from(template)
        update { $0.providers.append(provider) }
        return provider.id
    }

    func removeProvider(_ id: String) {
        update { $0.providers.removeAll { $0.id == id } }
    }

    /// Edits one provider in place. Anything that changes the URL or the key
    /// drops its check, which `tidy()` takes care of.
    func updateProvider(_ id: String, _ mutate: (inout AIProvider) -> Void) {
        update { settings in
            guard let index = settings.providers.firstIndex(where: { $0.id == id }) else { return }
            mutate(&settings.providers[index])
        }
    }

    func markVerified(_ id: String, label: String?) {
        updateProvider(id) { provider in
            provider.verifiedAt = Date()
            provider.verifiedLabel = label
            provider.verifiedFingerprint = provider.fingerprint
        }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            var loaded = try JSONDecoder().decode(AISettings.self, from: Data(contentsOf: fileURL))
            // A stamp still in the old plaintext form means the key is in the file
            // twice; the rewrite below is what takes the second copy out.
            let hadPlaintextStamp = loaded.providers.contains {
                $0.verifiedFingerprint != nil && $0.verifiedFingerprint == $0.legacyFingerprint
            }
            loaded.tidy()
            settings = loaded
            if hadPlaintextStamp { persist() }
        } catch {
            fputs("chromeless: could not load AI settings: \(error.localizedDescription)\n", stderr)
        }
    }

    // The file holds API keys, so it is written owner-read/write only. It is still
    // a plaintext file: an ad-hoc signed build cannot keep a Keychain item across
    // rebuilds without asking for the login password every time, which would be
    // worse than a 0600 file in the user's own container.
    //
    // The mode is set on an empty temporary file *before* any key goes into it,
    // and only then is that file moved into place. Writing with `.atomic` and
    // chmod-ing afterwards leaves the new file world-readable for the moment in
    // between — brief, but it is a key, and the fix costs three lines.
    private func persist() {
        let manager = FileManager.default
        let temporaryURL = directoryURL.appendingPathComponent("ai.json.\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            guard manager.createFile(atPath: temporaryURL.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
                throw AIError(message: "could not create \(temporaryURL.lastPathComponent)")
            }
            // Not `.atomic`: that would make a second file with default permissions
            // and defeat the point. This truncates the 0600 file just made.
            try data.write(to: temporaryURL)
            _ = try manager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? manager.removeItem(at: temporaryURL)
            fputs("chromeless: could not save AI settings: \(error.localizedDescription)\n", stderr)
        }
        NotificationCenter.default.post(name: .aiSettingsDidChange, object: nil)
    }
}

let aiSettingsStore = AISettingsStore.shared

// MARK: - Client

struct AIError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }

    /// Worth retrying: the endpoint is busy, not wrong. Google, OpenAI, and
    /// OpenRouter all ask for exponential backoff on exactly these.
    var isTransient: Bool {
        guard let status else { return false }
        return status == 408 || status == 429 || (500...599).contains(status)
    }
}

struct AIModelInfo {
    let id: String
    let contextLength: Int

    var menuTitle: String {
        contextLength > 0 ? "\(id)  —  \(contextLength / 1000)k ctx" : id
    }
}

enum AIClient {
    static func request(_ path: String, baseURL: String, key: String,
                        method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: AISettings.normalize(baseURL) + path),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 90
        // Bearer covers every template here, including Gemini's and Anthropic's
        // OpenAI-compatible endpoints. A local server that wants no key gets no
        // header at all rather than an empty one.
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // OpenRouter attributes traffic with these two and every other endpoint
        // ignores them, so they are sent unconditionally.
        request.setValue("https://github.com/chromeless", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Chromeless", forHTTPHeaderField: "X-Title")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// What the sidebar shows. The provider's own wording when there is one, plus
    /// a line about waiting when the failure was only ever temporary — Google's
    /// 503 says "the model is overloaded", which reads like the model was the
    /// wrong pick, and by the time this is built the retries have already run.
    static func errorMessage(status: Int, data: Data) -> String {
        guard let provided = providedMessage(data) else { return fallback(status: status) }
        guard AIError(message: provided, status: status).isTransient else { return provided }
        return provided + " (\(status)) — already retried; wait a moment or pick another model."
    }

    /// `error.message` out of the body: the shape every one of these APIs uses.
    private static func providedMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return nil
    }

    /// For the endpoints that fail with an empty or unreadable body.
    private static func fallback(status: Int) -> String {
        switch status {
        case 401, 403: return "The endpoint rejected the API key (\(status))."
        case 402: return "Out of credits on this key (402)."
        case 404: return "Not found (404) — check the base URL and the model id."
        case 429: return "Rate limited (429). Try again in a moment."
        // Google's own advice for 503 UNAVAILABLE is to back off and retry: the
        // model is busy, not misconfigured. Say so, because "HTTP 503" reads
        // like the settings are wrong when they are not.
        case 500, 502, 503, 504:
            return "The provider is overloaded or unavailable right now (\(status)). "
                + "Retried and still failing — try again shortly, or pick another model."
        case 0: return "No response from the endpoint."
        default: return "The endpoint returned HTTP \(status)."
        }
    }

    static func error(status: Int, data: Data) -> AIError {
        AIError(message: errorMessage(status: status, data: data), status: status)
    }

    // Transient failures are retried with exponential backoff and a little
    // jitter: 0.6s, 1.4s, then give up. Three attempts is enough to ride out a
    // busy provider without leaving the user staring at a dead button.
    private static let retryDelays: [TimeInterval] = [0.6, 1.4]

    private static func send(_ request: URLRequest, attempt: Int = 0,
                            completion: @escaping (Result<Data, Error>) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let payload = data ?? Data()
                let failure: Error? = {
                    if let error { return error }
                    return (200..<300).contains(status) ? nil : self.error(status: status, data: payload)
                }()
                guard let failure else {
                    completion(.success(payload))
                    return
                }
                let retryable = (failure as? AIError)?.isTransient == true
                    || (failure as NSError).domain == NSURLErrorDomain
                        && (failure as NSError).code == NSURLErrorTimedOut
                guard retryable, attempt < retryDelays.count else {
                    completion(.failure(failure))
                    return
                }
                let delay = retryDelays[attempt] + Double.random(in: 0...0.25)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    send(request, attempt: attempt + 1, completion: completion)
                }
            }
        }.resume()
    }

    /// The connection check: one real, small completion against the chosen model.
    /// Nothing else proves the whole path — URL, key, model id, credits, provider
    /// — actually works, and a key endpoint only some providers have would prove
    /// a third of it.
    static func check(baseURL: String, key: String, model: String,
                      completion: @escaping (Result<String, Error>) -> Void) {
        guard !AISettings.normalize(baseURL).isEmpty else {
            completion(.failure(AIError(message: "Enter the API base URL first.")))
            return
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion(.failure(AIError(message: "Enter a model id first.")))
            return
        }
        probe(baseURL: baseURL, key: key, model: model, capTokens: true) { result in
            switch result {
            case .failure(let error):
                // Reasoning models on some endpoints reject a token cap outright
                // (`max_tokens` vs `max_completion_tokens`). One retry without it
                // costs a few tokens and saves a false negative.
                let message = error.localizedDescription.lowercased()
                guard message.contains("max_tokens") || message.contains("max_completion_tokens") else {
                    completion(.failure(error))
                    return
                }
                probe(baseURL: baseURL, key: key, model: model, capTokens: false) { retry in
                    switch retry {
                    case .failure(let error): completion(.failure(error))
                    case .success: succeed(baseURL: baseURL, key: key, model: model, completion: completion)
                    }
                }
            case .success:
                succeed(baseURL: baseURL, key: key, model: model, completion: completion)
            }
        }
    }

    private static func succeed(baseURL: String, key: String, model: String,
                                completion: @escaping (Result<String, Error>) -> Void) {
        // OpenRouter is the one endpoint that will say what the key is worth, so
        // the check reports credit left when it is there.
        credit(baseURL: baseURL, key: key) { extra in
            var parts = ["\(model) answered"]
            if let extra { parts.append(extra) }
            completion(.success(parts.joined(separator: " · ")))
        }
    }

    /// A few tokens, no streaming: the cheapest request that still proves the
    /// whole path — key, model id, credits, provider — works.
    private static func probe(baseURL: String, key: String, model: String, capTokens: Bool,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "stream": false,
        ]
        // Not 1: a thinking model spends its first tokens on thought, and a cap
        // of one can come back empty or as an error on Gemini and o-series.
        if capTokens { body["max_tokens"] = 16 }
        guard let request = request("/chat/completions", baseURL: baseURL, key: key,
                                   method: "POST", body: body) else {
            completion(.failure(AIError(message: "That base URL is not a valid http(s) address.")))
            return
        }
        send(request) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: completion(.success(()))
            }
        }
    }

    /// OpenRouter's `/key`: label and remaining credit. Absent everywhere else,
    /// and a failure here never fails the check.
    private static func credit(baseURL: String, key: String,
                               completion: @escaping (String?) -> Void) {
        guard AISettings.normalize(baseURL).contains("openrouter.ai"), !key.isEmpty,
              let request = request("/key", baseURL: baseURL, key: key) else {
            completion(nil)
            return
        }
        send(request) { result in
            guard case .success(let data) = result,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["data"] as? [String: Any] else {
                completion(nil)
                return
            }
            var parts: [String] = []
            if let label = payload["label"] as? String, !label.isEmpty { parts.append("key “\(label)”") }
            if let remaining = payload["limit_remaining"] as? Double {
                parts.append(String(format: "$%.2f left", remaining))
            } else if let usage = payload["usage"] as? Double {
                parts.append(String(format: "$%.2f used", usage))
            }
            completion(parts.isEmpty ? nil : parts.joined(separator: " · "))
        }
    }

    /// `GET {base}/models` for the settings window's picker. Providers that do
    /// not serve it fall back to the template's suggestions.
    static func models(baseURL: String, key: String,
                       completion: @escaping (Result<[AIModelInfo], Error>) -> Void) {
        guard let request = request("/models", baseURL: baseURL, key: key) else {
            completion(.failure(AIError(message: "That base URL is not a valid http(s) address.")))
            return
        }
        send(request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let list = (object?["data"] as? [[String: Any]]) ?? []
                let models: [AIModelInfo] = list.compactMap { item in
                    // OpenAI-shaped lists key the id as `id`; a couple of local
                    // servers use `name` instead. Gemini answers with
                    // `models/gemini-…`, but its completions endpoint wants the
                    // bare id, so the prefix comes off here.
                    guard let raw = (item["id"] as? String) ?? (item["name"] as? String) else { return nil }
                    let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
                    let context = (item["context_length"] as? Int)
                        ?? (item["context_window"] as? Int) ?? 0
                    return AIModelInfo(id: id, contextLength: context)
                }
                guard !models.isEmpty else {
                    completion(.failure(AIError(message: "The endpoint listed no models.")))
                    return
                }
                completion(.success(models.sorted { $0.id < $1.id }))
            }
        }
    }
}

// MARK: - Streaming

/// One streaming chat completion. Deltas and the final result land on the main
/// queue, so callers never hop threads to touch a view.
final class AIStream: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var errorBody = Data()
    private var status = 0
    private var finished = false
    private var cancelled = false
    private let onDelta: (String) -> Void
    private let onFinish: (Error?) -> Void

    init(request: URLRequest,
         onDelta: @escaping (String) -> Void,
         onFinish: @escaping (Error?) -> Void) {
        self.onDelta = onDelta
        self.onFinish = onFinish
        super.init()
        // The session retains its delegate, so it is invalidated on the way out
        // — otherwise every answer would leak one session and one stream.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        task?.cancel()
        settle(nil)
    }

    private func settle(_ error: Error?) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        if !cancelled { onFinish(error) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // A failure before the first token is a plain JSON body, not SSE, so it
        // is collected whole and reported when the task ends.
        guard (200..<300).contains(status) else {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        drain()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { settle(nil); return }
            settle(error)
            return
        }
        guard (200..<300).contains(status) else {
            settle(AIClient.error(status: status, data: errorBody))
            return
        }
        drain()
        settle(nil)
    }

    /// Splits whole lines off the buffer and interprets the SSE frames. Comment
    /// lines (OpenRouter sends `: OPENROUTER PROCESSING` as a keep-alive) are
    /// skipped; a half-arrived line stays in the buffer for the next packet.
    private func drain() {
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            guard let raw = String(data: lineData, encoding: .utf8) else { continue }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(payload.utf8)) as? [String: Any] else { continue }
            // Mid-stream failures ride in on a 200 with an `error` field.
            if let error = object["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "The model stopped mid-answer."
                settle(AIError(message: message))
                return
            }
            guard let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String, !chunk.isEmpty else { continue }
            onDelta(chunk)
        }
    }
}

// MARK: - Page context

/// What the tab is showing, as text. Captured fresh for every question, so the
/// answer is about the page as it is now and not as it was when the sidebar
/// opened.
struct AIPageContext {
    var url: String
    var title: String
    var selection: String
    var text: String
    var truncated: Bool

    var host: String {
        guard let host = URL(string: url)?.host else { return "this page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The line under the composer: where the context came from and how big it is.
    var note: String {
        let size = text.count < 1000
            ? "\(text.count) chars"
            : String(format: "%.1fk chars", Double(text.count) / 1000)
        var note = "\(host) · \(size)"
        if truncated { note += " (trimmed)" }
        if !selection.isEmpty { note += " · selection" }
        return note
    }

    /// The block handed to the model. Only ever one of these per request: the
    /// history carries the questions and answers, not repeated copies of the page.
    func promptBlock() -> String {
        var block = """
            The user is looking at this page.

            URL: \(url)
            Title: \(title.isEmpty ? "(none)" : title)
            """
        if !selection.isEmpty {
            block += "\n\nThe user has selected this part of the page:\n\"\"\"\n\(selection)\n\"\"\""
        }
        block += "\n\nPage text\(truncated ? " (trimmed to fit)" : ""):\n\"\"\"\n\(text)\n\"\"\""
        return block
    }
}

enum AIPageCapture {
    /// innerText, not innerHTML: WebKit has already dropped script, style, and
    /// anything not displayed, which is most of what a model would have to wade
    /// through. Main frame only — cross-origin iframes are unreachable by design.
    private static let script = """
        (function () {
          function clean(s) {
            return (s || "")
              .replace(/[ \\t\\u00a0]+/g, " ")
              .replace(/\\n{3,}/g, "\\n\\n")
              .split("\\n").map(function (l) { return l.trim(); }).join("\\n")
              .trim();
          }
          var main = document.querySelector("main, article, [role=main]");
          var body = clean((main && main.innerText && main.innerText.length > 400)
            ? main.innerText
            : (document.body ? document.body.innerText : ""));
          var meta = document.querySelector('meta[name="description"]');
          if (meta && meta.content && body.indexOf(meta.content.trim()) === -1) {
            body = clean(meta.content) + "\\n\\n" + body;
          }
          var selection = "";
          try { selection = clean(String(window.getSelection())); } catch (e) {}
          return JSON.stringify({
            url: location.href,
            title: document.title || "",
            selection: selection.length > 4000 ? selection.slice(0, 4000) : selection,
            text: body
          });
        })();
        """

    static func capture(from webView: WKWebView, limit: Int,
                        completion: @escaping (AIPageContext?) -> Void) {
        webView.evaluateJavaScript(script) { result, _ in
            guard let json = result as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            else {
                completion(nil)
                return
            }
            var text = (object["text"] as? String) ?? ""
            var truncated = false
            if text.count > limit {
                // Head and tail: the top of a page carries the subject, the
                // bottom often carries the conclusion; the middle is the filler.
                let head = text.prefix(limit * 2 / 3)
                let tail = text.suffix(limit / 3)
                text = head + "\n\n…[middle of the page trimmed]…\n\n" + tail
                truncated = true
            }
            completion(AIPageContext(
                url: (object["url"] as? String) ?? "",
                title: (object["title"] as? String) ?? "",
                selection: (object["selection"] as? String) ?? "",
                text: text,
                truncated: truncated))
        }
    }
}

// MARK: - Conversation

struct AIMessage: Identifiable {
    enum Role: String { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    /// Shown under a question that carried the page with it.
    var contextNote: String?
}

/// One tab's conversation. Owned by `Tab`, so its lifetime is the tab's: no
/// window, no profile, and no other tab can see it.
final class AIChatSession {
    private(set) var messages: [AIMessage] = []
    /// What was typed but not sent. Kept here so switching tabs and coming back
    /// does not lose a half-written question.
    var draft = ""
    /// Which model this tab talks to. Per tab on purpose: one tab can sit on a big
    /// model for a dense page while another stays on a cheap one. Nil means "use
    /// whatever the settings default to", which is what a fresh tab wants.
    var model: AIModelRef? = aiSettingsStore.settings.defaultModel
    var includePage = aiSettingsStore.settings.includePageByDefault
    private(set) var streaming = false
    private(set) var streamingText = ""
    private(set) var errorText: String?
    /// The last capture, for the note under the composer.
    var pageContext: AIPageContext?

    private var stream: AIStream?
    private static let historyLimit = 24

    var isEmpty: Bool { messages.isEmpty && !streaming && errorText == nil }

    func reset() {
        cancel()
        messages.removeAll()
        streamingText = ""
        errorText = nil
    }

    func cancel() {
        stream?.cancel()
        stream = nil
        // A cancelled answer is kept: half an answer is still worth reading, and
        // dropping it would look like the app lost it.
        if streaming, !streamingText.isEmpty {
            messages.append(AIMessage(role: .assistant, text: streamingText))
        }
        streaming = false
        streamingText = ""
    }

    /// Sends one turn. `page` is the capture taken moments ago, or nil when the
    /// context switch is off or the page could not be read.
    func send(_ prompt: String, page: AIPageContext?, onChange: @escaping () -> Void) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        let settings = aiSettingsStore.settings
        // Which endpoint this tab is talking to. `resolve` falls back to the
        // default and then to anything that passed its check, so a tab that never
        // picked still works.
        guard let ref = settings.resolve(model), let provider = settings.provider(ref.providerID) else {
            errorText = settings.isBlank
                ? "Add a provider and a model in View ▸ AI Settings first."
                : "Check the connection in View ▸ AI Settings first."
            onChange()
            return
        }
        model = ref

        pageContext = page
        errorText = nil
        messages.append(AIMessage(role: .user, text: text, contextNote: page?.note))
        streaming = true
        streamingText = ""
        draft = ""
        onChange()

        // One system message, not two: Gemini and the o-series fold system turns
        // into a single instruction and can reject a second one, so the prompt and
        // the page are joined here instead of being sent as separate turns.
        var instruction = settings.systemPrompt
        if let page { instruction += "\n\n" + page.promptBlock() }
        var payload: [[String: String]] = [["role": "system", "content": instruction]]
        for message in messages.suffix(Self.historyLimit) {
            payload.append(["role": message.role.rawValue, "content": message.text])
        }

        let body: [String: Any] = [
            "model": ref.model,
            "messages": payload,
            "stream": true,
        ]
        guard let request = AIClient.request("/chat/completions", baseURL: provider.baseURL,
                                             key: provider.apiKey, method: "POST", body: body) else {
            streaming = false
            errorText = "Could not build the request for \(provider.baseURL)."
            onChange()
            return
        }
        start(request, attempt: 0, onChange: onChange)
    }

    /// Opens the stream, and opens it once more if the provider was merely busy.
    /// A retry is only safe while nothing has been shown yet — after the first
    /// token the answer would restart mid-sentence.
    private func start(_ request: URLRequest, attempt: Int, onChange: @escaping () -> Void) {
        stream = AIStream(
            request: request,
            onDelta: { [weak self] chunk in
                guard let self, self.streaming else { return }
                self.streamingText += chunk
                onChange()
            },
            onFinish: { [weak self] error in
                guard let self else { return }
                self.stream = nil
                let answer = self.streamingText
                if let error, answer.isEmpty, attempt < 1,
                   (error as? AIError)?.isTransient == true {
                    self.errorText = "The provider is busy — retrying…"
                    onChange()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self, self.streaming else { return }
                        self.errorText = nil
                        self.start(request, attempt: attempt + 1, onChange: onChange)
                    }
                    return
                }
                self.streaming = false
                self.streamingText = ""
                if !answer.isEmpty {
                    self.messages.append(AIMessage(role: .assistant, text: answer))
                }
                if let error { self.errorText = error.localizedDescription }
                onChange()
            })
    }

    /// The transcript as the sidebar draws it: finished turns plus whatever is
    /// arriving right now.
    var visibleMessages: [AIMessage] {
        guard streaming, !streamingText.isEmpty else { return messages }
        return messages + [AIMessage(role: .assistant, text: streamingText)]
    }
}
