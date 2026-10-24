import CoreAudio
import Foundation
import Testing
@testable import TypeMeIt

private func device(_ name: String, transport: UInt32, inputs: Int = 0, outputs: Int = 0, rate: Double,
                    defaultInput: Bool = false, defaultOutput: Bool = false) -> AudioCheck.DeviceState {
    AudioCheck.DeviceState(name: name, transport: transport, inputChannels: inputs, outputChannels: outputs, rate: rate,
                           alive: true, defaultInput: defaultInput, defaultOutput: defaultOutput)
}

struct AudioCheckTests {
    @Test func aBuiltInMicReadsAsItsTransportChannelsAndRate() {
        let mic = device("Built-in Microphone", transport: kAudioDeviceTransportTypeBuiltIn, inputs: 1, rate: 48000, defaultInput: true)
        #expect(AudioCheck.line(for: mic) == "Built-in Microphone: built-in · in 1 ch · 48000 Hz · default input")
    }

    @Test func aBluetoothOutputBelowMusicRatesIsInCallMode() {
        let headset = device("Headset", transport: kAudioDeviceTransportTypeBluetooth, outputs: 2, rate: 16000, defaultOutput: true)
        #expect(AudioCheck.line(for: headset) == "Headset: bluetooth · out 2 ch · 16000 Hz · call mode · default output")
    }

    @Test func aBluetoothOutputAtMusicRatesIsNotInCallMode() {
        #expect(!device("Headset", transport: kAudioDeviceTransportTypeBluetooth, outputs: 2, rate: 48000).inCallMode)
    }

    /// A headset's mic runs at call rates whenever it exists; only the output says which profile is on.
    @Test func aBluetoothInputAloneIsNeverInCallMode() {
        #expect(!device("Headset", transport: kAudioDeviceTransportTypeBluetoothLE, inputs: 1, rate: 16000).inCallMode)
    }

    @Test func aRateDropDuringATestNamesTheCallProfile() {
        #expect(AudioCheck.rateChanges(before: ["Headset": 48000], during: ["Headset": 16000]) == "Headset 48000 → 16000 Hz (call mode)")
    }

    @Test func steadyRatesReadAsUnchanged() {
        #expect(AudioCheck.rateChanges(before: ["Headset": 48000], during: ["Headset": 48000]) == "bluetooth outputs unchanged")
    }

    @Test func noBluetoothOutputSaysSo() {
        #expect(AudioCheck.rateChanges(before: [:], during: [:]) == "no bluetooth output")
    }

    @Test func theMeterHearsAToneAtItsOwnPitch() {
        let rate = AudioCapture.targetFormat.sampleRate
        var meter = ToneMeter()
        // Starts just below zero so the first sample of each cycle counts as a rising crossing.
        meter.add((0..<Int(rate)).map { Float(0.05 * sin(2 * Double.pi * AudioCheck.toneHz * (Double($0) - 0.5) / rate)) })
        #expect(abs((meter.pitch(rate: rate) ?? 0) - AudioCheck.toneHz) <= 1)
        #expect(abs(meter.peak - 0.05) < 0.001)
    }

    @Test func anEmptyMeterHasNoPitch() {
        #expect(ToneMeter().pitch(rate: AudioCapture.targetFormat.sampleRate) == nil)
    }
}
