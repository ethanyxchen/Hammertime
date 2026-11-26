import GitHubMaxxerCore
import Testing

@testable import GitHubMaxxer

struct DestinationTests {
  @Test func stepsThroughSidebarInOrderAndWraps() {
    let activities: [ActivityFilter] = [.all, .personal, .organization("acme")]

    #expect(Destination.activity(.all).step(1, through: activities) == .activity(.personal))
    #expect(
      Destination.activity(.personal).step(1, through: activities)
        == .activity(.organization("acme")))
    #expect(
      Destination.activity(.organization("acme")).step(1, through: activities) == .repositories)
    #expect(Destination.repositories.step(1, through: activities) == .activity(.all))
    #expect(Destination.activity(.all).step(-1, through: activities) == .repositories)
  }
}
