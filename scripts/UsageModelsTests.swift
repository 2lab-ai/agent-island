import Foundation

@main
enum UsageModelsTests {
    static func main() {
        let json = """
        {
          "claude": { "name": "Claude", "available": true, "error": false,
            "fiveHourPercent": 12, "sevenDayPercent": 34,
            "fiveHourReset": "2026-02-05T10:00:00.000Z",
            "sevenDayReset": "2026-02-12T10:00:00.000Z"
          },
          "codex": null,
          "gemini": null,
          "zai": null,
          "recommendation": "claude",
          "recommendationReason": "lowest usage"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try! decoder.decode(CheckUsageOutput.self, from: data)
        print("OK")
    }
}
