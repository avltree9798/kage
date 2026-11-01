import Foundation
import Observation
import KageModels
import SecurityKit
import BrowserCore

/// Non-secret preferences in UserDefaults. Secrets live only in the Keychain (spec 8.1).
@MainActor @Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") } }
    public var defaultProfile: PrivacyProfile.Kind { didSet { defaults.set(defaultProfile.rawValue, forKey: "defaultProfile") } }
    /// Minutes; nil = profile default; 0 = on tab close; -1 = manual.
    public var retentionMinutes: Int? { didSet { defaults.set(retentionMinutes ?? Int.min, forKey: "retentionMinutes") } }
    public var searchEngineID: String { didSet { defaults.set(searchEngineID, forKey: "searchEngine") } }
    public var searchSuggestions: Bool { didSet { defaults.set(searchSuggestions, forKey: "searchSuggestions") } }
    public var blockingMode: BlockingMode { didSet { defaults.set(blockingMode.rawValue, forKey: "blockingMode") } }
    public var blockingExceptions: [String] { didSet { defaults.set(blockingExceptions, forKey: "blockingExceptions") } }
    public var lockMode: LockPolicy { didSet { defaults.set(lockMode.rawValue, forKey: "lockMode") } }
    public var lockOnBackground: Bool { didSet { defaults.set(lockOnBackground, forKey: "lockOnBackground") } }
    /// Hide pages from screen recording, mirroring and AirPlay in every profile, not only Private and Vault.
    public var hideFromScreenCapture: Bool { didSet { defaults.set(hideFromScreenCapture, forKey: "hideFromScreenCapture") } }
    public var lockOnInactivity: Bool { didSet { defaults.set(lockOnInactivity, forKey: "lockOnInactivity") } }
    public var inactivityMinutes: Int { didSet { defaults.set(inactivityMinutes, forKey: "inactivityMinutes") } }
    public var smartPreSummary: Bool { didSet { defaults.set(smartPreSummary, forKey: "smartPreSummary") } }
    public var aiModelID: String? { didSet { defaults.set(aiModelID, forKey: "aiModelID") } }
    public var cleanWebsiteDataRoutinely: Bool { didSet { defaults.set(cleanWebsiteDataRoutinely, forKey: "cleanWebsiteData") } }
    public var readerTheme: ReaderTheme { didSet { defaults.set(readerTheme.rawValue, forKey: "readerTheme") } }
    public var readerFontSize: Double { didSet { defaults.set(readerFontSize, forKey: "readerFontSize") } }
    public var homepage: String { didSet { defaults.set(homepage, forKey: "homepage") } }
    public var iCloudSync: Bool { didSet { defaults.set(iCloudSync, forKey: "iCloudSync") } }
    public var accentColourName: String { didSet { defaults.set(accentColourName, forKey: "accent") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        defaultProfile = PrivacyProfile.Kind(rawValue: defaults.string(forKey: "defaultProfile") ?? "") ?? .standard
        let r = defaults.object(forKey: "retentionMinutes") as? Int
        retentionMinutes = (r == nil || r == Int.min) ? nil : r
        searchEngineID = defaults.string(forKey: "searchEngine") ?? SearchEngine.duckDuckGo.id
        searchSuggestions = defaults.bool(forKey: "searchSuggestions")
        blockingMode = BlockingMode(rawValue: defaults.string(forKey: "blockingMode") ?? "") ?? .standard
        blockingExceptions = defaults.stringArray(forKey: "blockingExceptions") ?? []
        lockMode = LockPolicy(rawValue: defaults.string(forKey: "lockMode") ?? "") ?? .none
        lockOnBackground = defaults.object(forKey: "lockOnBackground") as? Bool ?? true
        lockOnInactivity = defaults.bool(forKey: "lockOnInactivity")
        hideFromScreenCapture = defaults.bool(forKey: "hideFromScreenCapture")
        inactivityMinutes = defaults.object(forKey: "inactivityMinutes") as? Int ?? 5
        smartPreSummary = defaults.bool(forKey: "smartPreSummary")   // default off (spec 8.4)
        aiModelID = defaults.string(forKey: "aiModelID")
        cleanWebsiteDataRoutinely = defaults.bool(forKey: "cleanWebsiteData")
        readerTheme = ReaderTheme(rawValue: defaults.string(forKey: "readerTheme") ?? "") ?? .light
        readerFontSize = defaults.object(forKey: "readerFontSize") as? Double ?? 19
        homepage = defaults.string(forKey: "homepage") ?? ""
        iCloudSync = defaults.bool(forKey: "iCloudSync")
        accentColourName = defaults.string(forKey: "accent") ?? "indigo"
    }

    public var searchEngine: SearchEngine { SearchEngine.all.first { $0.id == searchEngineID } ?? .duckDuckGo }

    public var retentionOverride: RetentionInterval? {
        guard let m = retentionMinutes else { return nil }
        if m == 0 { return .onTabClose }
        if m < 0 { return .manual }
        return .minutes(m)
    }

    public static let retentionChoices: [(label: String, minutes: Int?)] = [
        ("Profile default", nil), ("When tab closes", 0), ("5 minutes", 5), ("15 minutes", 15), ("30 minutes", 30),
        ("1 hour", 60), ("24 hours", 1440), ("1 week", 10_080), ("Manual only", -1),
    ]
}
