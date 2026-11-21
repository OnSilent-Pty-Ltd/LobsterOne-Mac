import AVFoundation
import Testing
@testable import LobsterOne

@Test func unknownMicrophoneFallsBackToTheDefault() {
    let device = DictationMicrophones.captureDevice(forUID: "com.lobsterone.tests.no-such-microphone")
    #expect(device?.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID)
}

@Test func connectedMicrophonesResolveToThemselves() {
    // Whatever is plugged in on the machine running the tests; none at all is fine too.
    for microphone in DictationMicrophones.available() {
        #expect(!microphone.name.isEmpty)
        #expect(DictationMicrophones.captureDevice(forUID: microphone.uid)?.uniqueID == microphone.uid)
    }
}
