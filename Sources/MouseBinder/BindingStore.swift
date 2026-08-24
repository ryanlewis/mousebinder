import Foundation
import os

private let log = Logger(subsystem: "io.rlew.mousebinder", category: "store")

/// A single button→action mapping. `swallow` is wired through the store and event
/// core but fixed to `true` in v1 (we always eat the bound button so default
/// back/forward nav doesn't also fire). The field exists now so a per-binding
/// toggle can be added later without a schema migration.
struct ButtonBinding: Codable, Equatable, Identifiable {
    var button: Int
    var action: BindableAction
    var swallow: Bool = true

    var id: Int { button }
}

/// An app in which bound buttons are passed through untouched (so e.g. a browser
/// keeps its native back/forward on the side buttons). Matched by bundle id.
struct IgnoredApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String

    var id: String { bundleID }
}

/// Persists bindings and the ignore list in `UserDefaults` as JSON. Bindings are
/// stored as an array even though v1 holds few — keeping the multi shape from the
/// start (a decision from discovery) means scaling up is a UI change, not a data one.
struct BindingStore {
    private let defaults = UserDefaults.standard

    func load() -> [ButtonBinding] { decode("bindings") ?? [] }
    func save(_ bindings: [ButtonBinding]) { encode(bindings, "bindings") }

    func loadIgnoredApps() -> [IgnoredApp] { decode("ignoredApps") ?? [] }
    func saveIgnoredApps(_ apps: [IgnoredApp]) { encode(apps, "ignoredApps") }

    func loadEnabled() -> Bool { defaults.object(forKey: "enabled") as? Bool ?? true }
    func saveEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: "enabled") }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Don't silently wipe persisted data: surface the decode failure so a
            // schema change or corruption is diagnosable rather than appearing as an
            // empty list that the next save would overwrite for good.
            log.error("decode \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            log.error("encode \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
