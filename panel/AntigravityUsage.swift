import Foundation

// Antigravity (agy) usage, read from the running CLI's local loopback
// Connect-RPC. `agy` serves a language-server `GetUserStatus` endpoint on two
// 127.0.0.1 ports (one HTTP, one HTTPS); we POST to the HTTP one — no TLS, no
// CSRF, no auth (the running agy is already signed in, and it's loopback only,
// so nothing leaves the machine). Per-model quota windows + plan credits.
// Source: github.com/steipete/CodexBar#1178.
struct AntigravityQuotaSnapshot: Equatable {
    let planType: String?
    let models: [ModelQuota]
    let promptCredits: Credits?
    let flowCredits: Credits?

    struct ModelQuota: Equatable {
        let label: String      // e.g. "Claude Opus 4.6 (Thinking)"
        let tier: QuotaTier    // utilization 0…100 + reset time
    }
    struct Credits: Equatable {
        let available: Int
        let monthly: Int
    }
}

final class AntigravityUsageProbe {

    // Calls completion on the main queue. The loopback request runs off-main.
    func fetch(completion: @escaping (AntigravityQuotaSnapshot?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = AntigravityLocalServer.call("GetUserStatus").flatMap(Self.parse)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parse(_ data: Data) -> AntigravityQuotaSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userStatus = json["userStatus"] as? [String: Any]
        else { return nil }

        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]

        var models: [AntigravityQuotaSnapshot.ModelQuota] = []
        if let configs = (userStatus["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"]
            as? [[String: Any]] {
            for config in configs {
                guard let label = config["label"] as? String,
                      let quota = config["quotaInfo"] as? [String: Any],
                      let remaining = (quota["remainingFraction"] as? NSNumber)?.doubleValue
                else { continue }
                let utilization = max(0, min(100, (1 - remaining) * 100))
                let resetsAt = (quota["resetTime"] as? String).flatMap { iso.date(from: $0) }
                models.append(.init(label: label,
                                    tier: QuotaTier(utilization: utilization, resetsAt: resetsAt)))
            }
        }
        guard !models.isEmpty else { return nil }

        return AntigravityQuotaSnapshot(
            planType: planInfo?["planName"] as? String,
            models: models,
            promptCredits: credits(available: planStatus?["availablePromptCredits"],
                                   monthly: planInfo?["monthlyPromptCredits"]),
            flowCredits: credits(available: planStatus?["availableFlowCredits"],
                                 monthly: planInfo?["monthlyFlowCredits"])
        )
    }

    private static func credits(available: Any?, monthly: Any?) -> AntigravityQuotaSnapshot.Credits? {
        guard let available = (available as? NSNumber)?.intValue,
              let monthly = (monthly as? NSNumber)?.intValue, monthly > 0
        else { return nil }
        return .init(available: available, monthly: monthly)
    }
}
