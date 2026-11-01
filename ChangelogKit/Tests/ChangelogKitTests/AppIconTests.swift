import Testing
@testable import ChangelogKit

@Suite struct AppIconTests {
  @Test func aMemberChoosesAmongAllFive() {
    for current in AppIcon.allCases {
      #expect(AppIcon.offered(member: true, current: current) == [.versions, .paper, .copper, .terminal, .afterglow])
    }
  }

  @Test func anyoneElseSeesNothing() {
    #expect(AppIcon.offered(member: false, current: .versions).isEmpty)
  }

  @Test func aLapsedMemberKeepsTheirIconAndCanGoBack() {
    #expect(AppIcon.offered(member: false, current: .copper) == [.versions, .copper])
  }

  @Test func namesMatchTheAssetCatalog() {
    #expect(AppIcon.named(nil) == .versions)
    #expect(AppIcon.named("AppIcon-Terminal") == .terminal)
    #expect(AppIcon.named("Gone") == .versions)
    #expect(AppIcon.versions.alternateName == nil)
    #expect(AppIcon.afterglow.alternateName == "AppIcon-Afterglow")
    #expect(AppIcon.paper.preview == "AppIcon-Paper-Preview")
  }
}
