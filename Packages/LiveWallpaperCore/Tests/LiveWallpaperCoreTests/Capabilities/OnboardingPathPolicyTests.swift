import Testing
@testable import LiveWallpaperCore

@Suite("OnboardingPathPolicy")
struct OnboardingPathPolicyTests {

    @Test("Unconfigured: no import or gallery action is exposed")
    func unconfiguredPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .unconfigured)

        #expect(policy.sku == .unconfigured)
        #expect(!policy.showsWorkshopSetup)
        #expect(policy.galleryActions.isEmpty)
    }

    @Test("Pro without the Workshop capability: Import file + Apple Aerials, no setup step")
    func proPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .pro)

        #expect(policy.sku == .pro)
        #expect(!policy.showsWorkshopSetup)
        #expect(policy.galleryActions == [.importFile, .appleAerials])
    }

    @Test("Direct Pro makes Workshop setup and acquisition first-class")
    func directProPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .pro.withWorkshopOnline())

        #expect(policy.showsWorkshopSetup)
        #expect(policy.galleryActions == [.steamWorkshop, .importFile, .appleAerials])
    }

    @Test("Lite: Import file + Apple Aerials, never Workshop")
    func litePolicy() {
        let policy = OnboardingPathPolicy(capabilities: .lite)

        #expect(policy.sku == .lite)
        #expect(!policy.showsWorkshopSetup)
        #expect(policy.galleryActions == [.importFile, .appleAerials])
    }
}
