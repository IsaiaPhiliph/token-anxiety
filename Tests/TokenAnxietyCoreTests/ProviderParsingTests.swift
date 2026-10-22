import Foundation
import Testing
@testable import TokenAnxietyCore

private func json(_ text: String) -> JSONValue {
    try! JSONValue.parse(Data(text.utf8))
}

@Suite struct ClaudeTests {
    @Test func renewalKeepsEveryOtherField() throws {
        let stored = Data(#"""
        {"claudeAiOauth":{"accessToken":"old","refreshToken":"r-old","expiresAt":1,"scopes":["user:inference"],
          "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
         "mcpOAuth":{"server":{"accessToken":"keep-me"}}}
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = json(#"{"access_token":"new","refresh_token":"r-new","expires_in":28800}"#)
        let updated = try #require(ClaudeProvider.renewedCredentials(stored, response: response, now: now))
        let result = try JSONValue.parse(updated)
        let oauth = try #require(result["claudeAiOauth"])
        #expect(oauth["accessToken"]?.string == "new")
        #expect(oauth["refreshToken"]?.string == "r-new")
        #expect(oauth["expiresAt"]?.double == Double(1_800_028_800_000))
        #expect(oauth["subscriptionType"]?.string == "max")
        #expect(oauth["rateLimitTier"]?.string == "default_claude_max_20x")
        #expect(oauth["scopes"]?.array?.first?.string == "user:inference")
        #expect(result["mcpOAuth"]?["server"]?["accessToken"]?.string == "keep-me")
    }

    @Test func renewalWithoutNewRefreshTokenKeepsTheOldOne() throws {
        let stored = Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r-old","expiresAt":1}}"#.utf8)
        let updated = try #require(ClaudeProvider.renewedCredentials(stored, response: json(#"{"access_token":"new"}"#)))
        #expect(ClaudeProvider.refreshToken(in: updated) == "r-old")
        #expect(ClaudeProvider.parseCredentials(updated)?.accessToken == "new")
    }

    @Test func renewalNeedsAnAccessToken() {
        let stored = Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r"}}"#.utf8)
        #expect(ClaudeProvider.renewedCredentials(stored, response: json(#"{"error":"invalid_grant"}"#)) == nil)
    }

    @Test func parsesTheUsageEndpoint() {
        let usage = json(#"""
        {"five_hour":{"utilization":34.0,"resets_at":"2026-10-22T15:59:59.943648+00:00"},
         "seven_day":{"utilization":61.0,"resets_at":"2026-10-25T08:00:00.123456+00:00"},
         "seven_day_opus":{"utilization":12.0,"resets_at":null},
         "seven_day_sonnet":{"utilization":null,"resets_at":null},
         "seven_day_oauth_apps":null,
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":400,"utilization":8.0}}
        """#)
        let snapshot = ClaudeProvider.snapshot(from: usage, plan: "Max 20x", account: nil)
        #expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(snapshot.primary?.usedPercent == 34)
        #expect(snapshot.secondary?.usedPercent == 61)
        #expect(snapshot.primary?.resetsAt == DateParsing.iso8601("2026-10-22T15:59:59.943Z"))
        #expect(snapshot.facts.first?.label == "Uso extra")
    }

    @Test func plansReadLikePeopleSayThem() {
        #expect(ClaudeProvider.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(ClaudeProvider.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudeProvider.planName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
    }

    @Test func findsTheKeychainAccount() {
        let output = """
        keychain: "/Users/x/Library/Keychains/login.keychain-db"
            "acct"<blob>="pablo"
            "svce"<blob>="Claude Code-credentials"
        """
        #expect(ClaudeProvider.accountAttribute(output) == "pablo")
    }
}

@Suite struct CodexTests {
    @Test func parsesAppServerRateLimits() {
        let limits = json(#"""
        {"rateLimits":{"limitId":"codex","planType":"plus",
          "primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1800000000},
          "secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1800400000},
          "credits":{"hasCredits":false,"unlimited":false}},
         "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":8}}}}
        """#)
        let account = json(#"{"account":{"type":"chatgpt","email":"a@b.c","planType":"plus"},"requiresOpenaiAuth":true}"#)
        let usage = json(#"{"summary":{"currentStreakDays":4,"lifetimeTokens":12400000},"dailyUsageBuckets":[{"startDate":"2026-10-21","tokens":1200}]}"#)
        let snapshot = CodexProvider.snapshot(account: account, limits: limits, usage: usage)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.account == "a@b.c")
        #expect(snapshot.primary?.kind == .session)
        #expect(snapshot.primary?.usedPercent == 8)
        #expect(snapshot.secondary?.kind == .weekly)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_800_400_000))
        #expect(snapshot.windows.count == 2) // the "codex" bucket is the main one
        #expect(snapshot.dailyTokens.count == 1)
        #expect(snapshot.facts.map(\.label).contains("Racha"))
    }

    @Test func freePlanHasAMonthlyWindow() {
        let limits = json(#"{"rateLimits":{"planType":"free","primary":{"usedPercent":0,"windowDurationMins":43200,"resetsAt":1800000000}}}"#)
        let snapshot = CodexProvider.snapshot(account: nil, limits: limits, usage: nil)
        #expect(snapshot.plan == "Free")
        #expect(snapshot.windows.first?.kind == .monthly)
        #expect(snapshot.primary?.kind == .monthly)
    }

    @Test func parsesTheHTTPFallback() {
        let body = json(#"""
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":4,"limit_window_seconds":18000,"reset_after_seconds":600},
          "secondary_window":{"used_percent":18,"limit_window_seconds":604800,"reset_at":1800000000}}}
        """#)
        let now = Date(timeIntervalSince1970: 1_799_000_000)
        let snapshot = CodexProvider.snapshot(httpUsage: body, email: nil, now: now)
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.primary?.resetsAt == now.addingTimeInterval(600))
        #expect(snapshot.secondary?.usedPercent == 18)
    }
}

@Suite struct AntigravityTests {
    @Test func groupsVariantsAndReadsMissingFractionsAsSpent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = ISO8601DateFormatter().string(from: now.addingTimeInterval(2 * 3600))
        let later = ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 86_400))
        let response = json("""
        {"userStatus":{"email":"a@b.c","userTier":{"name":"Google AI Plus"},
          "planStatus":{"availablePromptCredits":500},
          "cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini 3 Flash (Low)","quotaInfo":{"remainingFraction":0.97,"resetTime":"\(later)"}},
            {"label":"Gemini 3 Flash (High)","quotaInfo":{"remainingFraction":0.9,"resetTime":"\(later)"}},
            {"label":"Claude Opus 4.6 (Thinking)","quotaInfo":{"resetTime":"\(soon)"}},
            {"label":"No quota"}
          ]}}}
        """)
        let snapshot = AntigravityProvider.snapshot(from: response, now: now)
        #expect(snapshot.plan == "Google AI Plus")
        #expect(snapshot.windows.map(\.label) == ["Gemini 3 Flash", "Claude Opus 4.6"])
        #expect(abs((snapshot.windows.first?.usedPercent ?? 0) - 10) < 0.001)
        #expect(snapshot.windows.last?.usedPercent == 100)
        #expect(snapshot.primary?.label == "Claude Opus 4.6") // resets within hours
        #expect(snapshot.secondary?.label == "Gemini 3 Flash") // resets within days
    }

    @Test func findsTheServerAndItsToken() {
        let ps = """
          123 /Applications/Windsurf.app/Contents/Resources/language_server_macos_arm --csrf_token nope
          456 /Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm --csrf_token abc-123 --extension_server_port 64503
        """
        let servers = AntigravityProvider.findServers(in: ps)
        #expect(servers == [.init(pid: 456, csrfToken: "abc-123", extensionPort: 64503)])
        #expect(AntigravityProvider.listeningPorts(in: "p456\nf12\nn127.0.0.1:64510\nf13\nn*:64511\n") == [64510, 64511])
    }
}

@Suite struct CursorTests {
    @Test func parsesTheUsageSummary() throws {
        let summary = json(#"""
        {"billingCycleStart":"2026-10-04T00:00:00.000Z","billingCycleEnd":"2026-11-04T00:00:00.000Z","membershipType":"pro",
         "individualUsage":{"plan":{"enabled":true,"used":820,"limit":2000,"totalPercentUsed":41,"autoPercentUsed":30,"apiPercentUsed":52},
           "onDemand":{"enabled":true,"used":320,"limit":5000}}}
        """#)
        let snapshot = try #require(CursorProvider.snapshot(summary: summary, membership: nil, email: nil))
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.primary?.kind == .monthly)
        #expect(snapshot.primary?.usedPercent == 41)
        #expect(snapshot.primary?.detail?.contains("8,20") == true)
        #expect(snapshot.windows.map(\.id) == ["plan", "auto", "api"])
        #expect(snapshot.facts.first?.label == "Bajo demanda")
    }
}

@Suite struct ParsingTests {
    @Test func datesWithSixFractionalDigits() {
        let date = DateParsing.iso8601("2025-11-04T04:59:59.943648+00:00")
        #expect(date == DateParsing.iso8601("2025-11-04T04:59:59.943Z"))
        #expect(DateParsing.unix(1_800_000_000_000) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func jwtClaims() {
        // {"sub":"auth0|user_1"}
        #expect(JWT.claims("x.eyJzdWIiOiJhdXRoMHx1c2VyXzEifQ.y")?["sub"]?.string == "auth0|user_1")
    }
}
