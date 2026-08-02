import Foundation

public enum WAV {
    /// Float32 モノラルサンプル列を 16bit PCM WAV に変換する
    public static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767)
            pcm.append(le(value))
        }

        let byteRate = sampleRate * 2  // mono, 16bit
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(le(UInt32(36 + pcm.count)))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(le(UInt32(16)))          // fmt chunk size
        data.append(le(UInt16(1)))           // PCM
        data.append(le(UInt16(1)))           // mono
        data.append(le(UInt32(sampleRate)))
        data.append(le(UInt32(byteRate)))
        data.append(le(UInt16(2)))           // block align
        data.append(le(UInt16(16)))          // bits per sample
        data.append("data".data(using: .ascii)!)
        data.append(le(UInt32(pcm.count)))
        data.append(pcm)
        return data
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
