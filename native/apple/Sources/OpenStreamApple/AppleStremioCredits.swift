#if OPENSTREAM_ADDONS
import Foundation

/// The people a Stremio meta response names with their pictures.
///
/// `cast`, `director` and `writer` are bare names, so a title page built
/// from them drew initials in every circle (owner, 2026-09-24: "cast and
/// crew don't get pictures"). The pictures ride elsewhere in the same
/// response: Cinemeta and the TMDB add-on send `app_extras.cast` (and
/// `directors`, `writers`) as `{name, character, photo}`, and some add-ons
/// pass TMDB's own `credits_cast` / `credits_crew` through with a
/// `profile_path`. Every field is optional and a malformed entry is skipped,
/// so a response this cannot read still loads.
struct AppleMediaCredits: Decodable, Sendable {
    let people: [AppleCreditPerson]

    static let tmdbProfileBase = "https://image.tmdb.org/t/p/\(AppleCreditPerson.tmdbPortraitSize)"

    private enum CodingKeys: String, CodingKey {
        case appExtras = "app_extras"
        case creditsCast = "credits_cast"
        case creditsCrew = "credits_crew"
    }

    private enum ExtrasKeys: String, CodingKey { case cast, directors, writers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var people: [AppleCreditPerson] = []
        if let extras = try? container.nestedContainer(keyedBy: ExtrasKeys.self, forKey: .appExtras) {
            people += Self.entries(in: extras, forKey: .cast).prefix(15).map { $0.person(role: $0.character) }
            people += Self.entries(in: extras, forKey: .directors).prefix(2).map { $0.person(role: "Director") }
            people += Self.entries(in: extras, forKey: .writers).prefix(4).map { $0.person(role: "Writer") }
        }
        if people.isEmpty {
            let cast = (try? container.decode([Lenient<Entry>].self, forKey: .creditsCast))?.compactMap(\.value) ?? []
            let crew = (try? container.decode([Lenient<Entry>].self, forKey: .creditsCrew))?.compactMap(\.value) ?? []
            people += cast.prefix(15).map { $0.person(role: $0.character) }
            people += crew.filter { $0.job == "Director" }.prefix(2).map { $0.person(role: "Director") }
            people += crew.filter { $0.department == "Writing" }.prefix(4).map { $0.person(role: "Writer") }
        }
        var seen = Set<String>()
        self.people = people.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
    }

    private static func entries(
        in container: KeyedDecodingContainer<ExtrasKeys>,
        forKey key: ExtrasKeys
    ) -> [Entry] {
        (try? container.decode([Lenient<Entry>].self, forKey: key))?.compactMap(\.value) ?? []
    }

    /// One person, in either shape.
    private struct Entry: Decodable {
        let name: String
        let character: String?
        let job: String?
        let department: String?
        let photo: URL?

        private enum CodingKeys: String, CodingKey {
            case name, character, job, department, photo
            case profilePath = "profile_path"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            character = try? container.decode(String.self, forKey: .character)
            job = try? container.decode(String.self, forKey: .job)
            department = try? container.decode(String.self, forKey: .department)
            if let photo = try? container.decode(String.self, forKey: .photo) {
                self.photo = Self.photoURL(photo)
            } else if let path = try? container.decode(String.self, forKey: .profilePath),
                      path.hasPrefix("/"), !path.contains("..") {
                self.photo = URL(string: AppleStremioCredits.tmdbProfileBase + path)
            } else {
                self.photo = nil
            }
        }

        func person(role: String?) -> AppleCreditPerson {
            AppleCreditPerson(name: name, role: role, portraitURL: photo)
        }

        /// A picture from the web. An `http` one is asked for over `https`:
        /// the page only draws secure images (`AppleCreditPerson`), and the
        /// hosts these come from serve both.
        private static func photoURL(_ value: String) -> URL? {
            guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  components.host?.isEmpty == false,
                  components.user == nil, components.password == nil else { return nil }
            components.scheme = "https"
            // A TMDB thumbnail (w45…w185) drawn in a Cast & Crew circle
            // upscaled and looked blurry on the Mac and Apple TV
            // (owner, 2026-09-25): ask TMDB for its sharp profile size.
            if components.host?.lowercased() == "image.tmdb.org" {
                components.path = AppleCreditPerson.sharpTMDBPortraitPath(components.path)
            }
            return components.url
        }
    }

    /// Decodes an array element or nothing, so one bad entry does not throw
    /// away the rest of the list.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

typealias AppleStremioCredits = AppleMediaCredits

#endif
