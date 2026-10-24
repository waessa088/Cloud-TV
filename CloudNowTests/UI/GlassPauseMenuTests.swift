@testable import CloudNow
import Foundation
import Testing

@Suite("Glass pause menu and device tuning")
struct GlassPauseMenuTests {
    @Test("Remaining time reads as hours and minutes")
    func durationFormatting() {
        #expect(GlassPauseMenu.duration(45) == "45 min")
        #expect(GlassPauseMenu.duration(60) == "1 h 0 min")
        #expect(GlassPauseMenu.duration(312) == "5 h 12 min")
    }

    @Test("Device tuning is only applied on iPad, and only once")
    func deviceTuning() {
        var settings = StreamSettings()
        settings.chromaFormat = .yuv444
        settings.maxBitrateKbps = 100_000
        let normalized = settings.normalizedForClient

        #if os(iOS)
            #expect(normalized.chromaFormat == .yuv420)
            #expect(normalized.maxBitrateKbps == 50000)
            #expect(normalized.deviceTuningVersion == 1)
            // A user who raises the settings afterwards keeps their choice.
            var raised = normalized
            raised.chromaFormat = .yuv444
            #expect(raised.normalizedForClient.chromaFormat == .yuv444)
        #else
            #expect(normalized.chromaFormat == .yuv444)
            #expect(normalized.maxBitrateKbps == 100_000)
            #expect(normalized.deviceTuningVersion == nil)
        #endif
    }

    @Test("The tuning marker survives a save and reload")
    func tuningMarkerRoundTrip() throws {
        var settings = StreamSettings()
        settings.deviceTuningVersion = 1
        let decoded = try JSONDecoder().decode(
            StreamSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.deviceTuningVersion == 1)

        let legacy = try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8))
        #expect(legacy.deviceTuningVersion == nil)
    }
}
