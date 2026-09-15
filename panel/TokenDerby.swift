import Foundation

// Token Derby — a horse race where each runner advances on the tokens its owner
// burns. Third-party service (token-derby.mauricode.co.uk), read-only here: we
// GET a race and render it. Nothing about this machine's usage is ever sent.
//
// Off unless STACKNUDGE_DERBY_ORG names an organisation, which is also what
// gates the tab — no org, no tab, no network.

struct DerbyHorse: Equatable {
    let id: String
    let name: String
    let userName: String?
    let rank: Int?
    // What the race is scored on, and therefore what rank reflects. Drawing
    // current_tokens instead put a 4th-placed horse's bar ahead of 2nd's: the
    // league discounts raw usage (input counting, stamina), so the two diverge.
    let tokens: Double
    let rawTokens: Double
    let pace15m: Double?
    let division: Int?
    let bodyColor: String?
    let model: String?
}

struct DerbyRace: Equatable {
    let joinCode: String
    let name: String
    let status: String          // pending | live | finished
    let timeLeftSeconds: Int?
    let divisionNames: [String]
    let horses: [DerbyHorse]

    var isLive: Bool { status == "live" }

    // The bar scale. Ranks come from the server, but the leader's total is what
    // every other bar is drawn against.
    var leaderTokens: Double { horses.map(\.tokens).max() ?? 0 }
}

// One entry in an org's race list, enough to choose which race to show.
struct DerbySummary: Equatable {
    let joinCode: String
    let name: String
    let status: String
    let startTime: String?
}

enum DerbyParse {

    // `GET /api/organisations/{org}/races`
    static func summaries(from data: Data) -> [DerbySummary] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let races = obj["races"] as? [[String: Any]] else { return [] }
        return races.compactMap { r in
            guard let code = r["join_code"] as? String else { return nil }
            return DerbySummary(joinCode: code,
                                name: r["name"] as? String ?? "Race",
                                status: r["status"] as? String ?? "",
                                startTime: r["start_time"] as? String)
        }
    }

    // The race worth showing: whichever is running, else the most recent. The
    // list arrives newest-first, so "first" is the fallback rather than a sort.
    static func pick(_ summaries: [DerbySummary]) -> DerbySummary? {
        summaries.first(where: { $0.status == "live" }) ?? summaries.first
    }

    // `GET /api/races/{join_code}`
    static func race(from data: Data) -> DerbyRace? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["join_code"] as? String else { return nil }
        let raw = obj["horses"] as? [[String: Any]] ?? []
        let horses: [DerbyHorse] = raw.compactMap { h in
            guard let id = h["horse_id"] as? String else { return nil }
            // current_tokens arrives as an int for some horses and a half-token
            // double for others, so decode through NSNumber rather than picking one.
            let raw = (h["current_tokens"] as? NSNumber)?.doubleValue ?? 0
            // scored_tokens is absent on a race that isn't scoring; fall back so
            // a plain race still draws.
            let scored = (h["scored_tokens"] as? NSNumber)?.doubleValue ?? raw
            return DerbyHorse(
                id: id,
                name: h["name"] as? String ?? "Unnamed",
                userName: h["user_name"] as? String,
                rank: (h["rank"] as? NSNumber)?.intValue,
                tokens: scored,
                rawTokens: raw,
                pace15m: (h["pace_15m"] as? NSNumber)?.doubleValue,
                division: (h["division"] as? NSNumber)?.intValue,
                bodyColor: (h["colors"] as? [String: Any])?["body"] as? String,
                model: h["primary_model"] as? String)
        }
        return DerbyRace(
            joinCode: code,
            name: obj["name"] as? String ?? "Race",
            status: obj["status"] as? String ?? "",
            timeLeftSeconds: (obj["time_left_seconds"] as? NSNumber)?.intValue,
            divisionNames: obj["league_division_names"] as? [String] ?? [],
            // Server order is the ranking; don't re-sort and risk disagreeing with it.
            horses: horses)
    }
}

final class TokenDerbyProbe {

    static let defaultBase = "https://token-derby.mauricode.co.uk/api"

    private let session: URLSession
    private let base: String

    init(base: String = defaultBase) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "stack-nudge"]
        session = URLSession(configuration: config)
    }

    // Two hops: the org's races, then the one worth showing. Completion is on
    // the main queue; nil means "nothing to show" and the tab says so rather
    // than holding a stale race.
    func fetch(org: String, completion: @escaping (DerbyRace?) -> Void) {
        guard let listURL = url("/organisations/\(escape(org))/races") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        session.dataTask(with: listURL) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let pick = DerbyParse.pick(DerbyParse.summaries(from: data)),
                  let raceURL = self.url("/races/\(self.escape(pick.joinCode))")
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.session.dataTask(with: raceURL) { data, _, _ in
                let race = data.flatMap(DerbyParse.race(from:))
                DispatchQueue.main.async { completion(race) }
            }.resume()
        }.resume()
    }

    private func url(_ path: String) -> URL? { URL(string: base + path) }

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
