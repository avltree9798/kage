import Foundation
import Testing
@testable import KageModels

@Suite struct RetentionTests {
    let visit = Date(timeIntervalSince1970: 1_000_000)

    @Test func minuteRetentionAddsInterval() {
        #expect(RetentionInterval.fifteenMinutes.expiry(after: visit) == visit.addingTimeInterval(900))
        #expect(RetentionInterval.oneDay.expiry(after: visit) == visit.addingTimeInterval(86_400))
    }

    @Test func tabCloseAndManualHaveNoTimeExpiry() {
        #expect(RetentionInterval.onTabClose.expiry(after: visit) == nil)
        #expect(RetentionInterval.manual.expiry(after: visit) == nil)
    }
}

@Suite struct ProtectedSiteTests {
    @Test func matchesDomainAndSubdomains() {
        let site = ProtectedSite(domain: "Example.com")
        #expect(site.matches(host: "example.com"))
        #expect(site.matches(host: "login.example.com"))
        #expect(!site.matches(host: "notexample.com"))
    }

    @Test func exactDomainOnly() {
        let site = ProtectedSite(domain: "example.com", includeSubdomains: false)
        #expect(!site.matches(host: "login.example.com"))
    }
}
