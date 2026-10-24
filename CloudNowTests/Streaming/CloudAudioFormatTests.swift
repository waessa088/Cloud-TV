import AVFAudio
@testable import CloudNow
import Testing

@Suite("Multichannel audio output")
struct CloudAudioFormatTests {
    @Test(
        "Output chooses a supported layout without exceeding the request or route",
        arguments: [(8, 8, 8), (8, 32, 8), (8, 7, 6), (8, 6, 6), (8, 5, 2), (8, 2, 2),
                    (8, 1, 1), (8, 0, 1), (6, 8, 6), (6, 2, 2), (2, 8, 2)]
    )
    func routeFallback(requested: Int, available: Int, expected: Int) throws {
        let channels = CloudAudioDevice.playoutChannelCount(requested: requested, available: available)
        #expect(channels == expected)
        let format = try #require(CloudAudioDevice.playoutFormat(channels: channels))
        #expect(format.channelCount == expected)
        #expect(format.streamDescription.pointee.mBytesPerFrame == UInt32(expected * 2))
        #expect(format.sampleRate == 48000)
        #expect(format.commonFormat == .pcmFormatInt16)
        #expect(format.isInterleaved)
    }

    @Test("7.1 uses side and rear surrounds; 5.1 retains its existing channel order")
    func surroundLayouts() throws {
        let surround71 = try #require(CloudAudioDevice.playoutFormat(channels: 8))
        let surround51 = try #require(CloudAudioDevice.playoutFormat(channels: 6))
        #expect(surround71.channelLayout?.layoutTag == kAudioChannelLayoutTag_MPEG_7_1_C)
        #expect(surround71.channelLayout?.channelCount == 8)
        #expect(surround51.channelLayout?.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(surround51.channelLayout?.channelCount == 6)
        #expect(CloudAudioDevice.playoutFormat(channels: 7) == nil)
    }
}
