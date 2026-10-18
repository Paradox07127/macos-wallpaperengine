import Accelerate
import Foundation

/// WPE 2.8 audio provider: 64 raw peak magnitudes per channel from the newest `frameSamples` samples.
/// 1400d02b0.c (0x1400d18c4, 0x1400d1491, 0x1400d1c40-1d5d), 1400cf120.c:257-265, 1400c0c80.c:58-61.
public final class WPEParityAudioProvider {
    /// N: DFT length; samples past `frameSamples` are the constant (127, 1/127).
    public let fftSize: Int
    /// M: bins k = 1..<M are analyzed.
    public let analyzedBins: Int
    /// L: newest samples per channel that `bins` takes.
    public let frameSamples: Int
    /// Band of DFT bin k at index k - 1.
    public let bandOfBin: [Int]

    private let binWeights: [Float]
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    /// Chirp e^{-iπn²/N} for n < L.
    private let chirpReal: [Float]
    private let chirpImag: [Float]
    /// Forward transform of e^{+iπm²/N} (m in -(N-1)...(N-1), circular), pre-divided by the transform size.
    private let kernelReal: [Float]
    private let kernelImag: [Float]

    public init(sampleRate: Double) {
        let fftSize = Int(max(Float(sampleRate) / 44100, 1) * 64 * 30)
        let analyzedBins = 640
        let frameSamples = Int(Float(fftSize) - Float(10) / Float(30) * Float(fftSize))
        (self.fftSize, self.analyzedBins, self.frameSamples) = (fftSize, analyzedBins, frameSamples)

        var previous = 0
        bandOfBin = (0 ..< analyzedBins - 1).map { j in
            let band = Int(powf(Float(j) / Float(analyzedBins - 1), 0.25) * 64) & 63
            previous = min(previous + 1, band)
            return previous
        }
        // Bin weight a - (1 - a)·cos(π(k-1)/(M-1)), a ≈ 0.501 (0x1400d1c40).
        let a = Float(bitPattern: 0x3F00_4189)
        binWeights = (0 ..< analyzedBins - 1).map { j in
            a - (1 - a) * cosf(Float.pi * Float(j) / Float(analyzedBins - 1))
        }

        // Bluestein: kn = (k² + n² - (k-n)²)/2; a size ≥ 2N-1 keeps the circular convolution unaliased.
        var log2Size = 0
        while 1 << log2Size < 2 * fftSize - 1 {
            log2Size += 1
        }
        self.log2Size = vDSP_Length(log2Size)
        let size = 1 << log2Size
        func phase(_ m: Int) -> Double {
            Double.pi * Double(m * m % (2 * fftSize)) / Double(fftSize)
        }
        chirpReal = (0 ..< frameSamples).map { Float(cos(phase($0))) }
        chirpImag = (0 ..< frameSamples).map { Float(-sin(phase($0))) }
        var kernel = (real: [Float](repeating: 0, count: size), imag: [Float](repeating: 0, count: size))
        for m in 0 ..< fftSize {
            let (re, im) = (Float(cos(phase(m))), Float(sin(phase(m))))
            (kernel.real[m], kernel.imag[m]) = (re, im)
            if m > 0 {
                (kernel.real[size - m], kernel.imag[size - m]) = (re, im)
            }
        }
        let setup = vDSP_create_fftsetup(self.log2Size, FFTRadix(kFFTRadix2))!
        self.setup = setup
        Self.transform(&kernel, setup: setup, log2Size: self.log2Size, direction: FFTDirection(kFFTDirection_Forward))
        kernelReal = vDSP.multiply(1 / Float(size), kernel.real)
        kernelImag = vDSP.multiply(1 / Float(size), kernel.imag)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Left 64 then right 64 band peaks; `left`/`right` hold the newest `frameSamples` samples, oldest first.
    public func bins(left: [Float], right: [Float], volume: Float = 1) -> [Float] {
        precondition(left.count == frameSamples && right.count == frameSamples)
        let scale = volume * 0.001 * (Float(analyzedBins) / (Float(fftSize) * 0.5))
        return channelBands(left, setup: setup).map { $0 * scale } + channelBands(right, setup: setup).map { $0 * scale }
    }

    private func channelBands(_ samples: [Float], setup: FFTSetup) -> [Float] {
        let size = 1 << Int(log2Size)
        var data = (real: [Float](repeating: 0, count: size), imag: [Float](repeating: 0, count: size))
        // Padding samples equal (127, 1/127), so subtracting it zeroes them and changes only bin 0.
        for n in 0 ..< frameSamples {
            let re = samples[n] * 127 + 127
            let (xr, xi) = (re - 127, 1 / re - Float(1) / 127)
            data.real[n] = xr * chirpReal[n] - xi * chirpImag[n]
            data.imag[n] = xr * chirpImag[n] + xi * chirpReal[n]
        }
        Self.transform(&data, setup: setup, log2Size: log2Size, direction: FFTDirection(kFFTDirection_Forward))
        for i in 0 ..< size {
            let (sr, si) = (data.real[i], data.imag[i])
            data.real[i] = sr * kernelReal[i] - si * kernelImag[i]
            data.imag[i] = sr * kernelImag[i] + si * kernelReal[i]
        }
        Self.transform(&data, setup: setup, log2Size: log2Size, direction: FFTDirection(kFFTDirection_Inverse))

        var bands = [Float](repeating: 0, count: 64)
        for k in 1 ..< analyzedBins {
            let (re, im) = (data.real[k], data.imag[k])
            let power = re * re + im * im
            let magnitude = (binWeights[k - 1] * (power.isFinite ? power : 0)).squareRoot()
            let band = bandOfBin[k - 1]
            bands[band] = max(bands[band], magnitude)
        }
        return bands
    }

    private static func transform(
        _ data: inout (real: [Float], imag: [Float]),
        setup: FFTSetup,
        log2Size: vDSP_Length,
        direction: FFTDirection
    ) {
        data.real.withUnsafeMutableBufferPointer { real in
            data.imag.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2Size, direction)
            }
        }
    }
}
