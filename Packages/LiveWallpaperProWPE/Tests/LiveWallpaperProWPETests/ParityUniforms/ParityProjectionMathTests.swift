@testable import LiveWallpaperProWPE
import XCTest

final class ParityProjectionMathTests: XCTestCase {
    /// Original 09a360 instructions emulated with MXCSR 0x1f80; no native backend/assertion claim.
    /// The pinned compact oracle is SHA256 9e1cf61caa55098038bb9712e7a2166f24a0ddfff4e93aaa20cc6ffa1fe44c71.
    func testProjectionMatchesAllOriginalMatrixBitsAcrossFiniteAnglesAndDepthRanges() {
        let samples: [([UInt32], [UInt32])] = [
            // general-0.1-a1-n1-f9
            ([0x3AE4_C388, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x448F_3D4A, 0x448F_3D4A, 0x3E00_0000, 0x3F90_0000]),
            // general-0.1-a2-n0.1-f10000
            ([0x3AE4_C388, 0x4000_0000, 0x3DCC_CCCD, 0x461C_4000], [0x440F_3D4A, 0x448F_3D4A, 0x3727_C61A, 0x3DCC_CD53]),
            // general-50-a1-n1-f9
            ([0x3F5F_66F3, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x4009_3F99, 0x4009_3F99, 0x3E00_0000, 0x3F90_0000]),
            // general-50-a2-n0.1-f10000
            ([0x3F5F_66F3, 0x4000_0000, 0x3DCC_CCCD, 0x461C_4000], [0x3F89_3F99, 0x4009_3F99, 0x3727_C61A, 0x3DCC_CD53]),
            // general-60-a1-n1-f9
            ([0x3F86_0A92, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3FDD_B3D7, 0x3FDD_B3D7, 0x3E00_0000, 0x3F90_0000]),
            // general-60-a2-n0.1-f10000
            ([0x3F86_0A92, 0x4000_0000, 0x3DCC_CCCD, 0x461C_4000], [0x3F5D_B3D7, 0x3FDD_B3D7, 0x3727_C61A, 0x3DCC_CD53]),
            // general-90-a1-n1-f9
            ([0x3FC9_0FDB, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3F7F_FFFF, 0x3F7F_FFFF, 0x3E00_0000, 0x3F90_0000]),
            // general-90-a2-n0.1-f10000
            ([0x3FC9_0FDB, 0x4000_0000, 0x3DCC_CCCD, 0x461C_4000], [0x3EFF_FFFF, 0x3F7F_FFFF, 0x3727_C61A, 0x3DCC_CD53]),
            // general-250-a1-n1-f9
            ([0x4048_F342, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3A64_C406, 0x3A64_C406, 0x3E00_0000, 0x3F90_0000]),
            // general-250-a2-n0.1-f10000
            ([0x4048_F342, 0x4000_0000, 0x3DCC_CCCD, 0x461C_4000], [0x39E4_C406, 0x3A64_C406, 0x3727_C61A, 0x3DCC_CD53]),
            // reversed-50-a1
            ([0x3F5F_66F3, 0x3F80_0000, 0x4110_0000, 0x3F80_0000], [0x4009_3F99, 0x4009_3F99, 0xBF90_0000, 0xBF90_0000]),
            // reversed-90-a2
            ([0x3FC9_0FDB, 0x4000_0000, 0x4110_0000, 0x3F80_0000], [0x3EFF_FFFF, 0x3F7F_FFFF, 0xBF90_0000, 0xBF90_0000]),
            // leaf-rad-12
            ([0xC140_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x405B_ED2B, 0x405B_ED2B, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad-10
            ([0xC120_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3E97_74C4, 0x3E97_74C4, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad-8
            ([0xC100_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0xBF5D_1ADF, 0xBF5D_1ADF, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad-6
            ([0xC0C0_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x40E0_7CEA, 0x40E0_7CEA, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad-4
            ([0xC080_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3EEA_5213, 0x3EEA_5213, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad-3.5
            ([0xC060_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3E39_7E94, 0x3E39_7E94, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad3.5
            ([0x4060_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0xBE39_7E94, 0xBE39_7E94, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad4
            ([0x4080_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0xBEEA_5213, 0xBEEA_5213, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad6
            ([0x40C0_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0xC0E0_7CEA, 0xC0E0_7CEA, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad8
            ([0x4100_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0x3F5D_1ADF, 0x3F5D_1ADF, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad10
            ([0x4120_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0xBE97_74C4, 0xBE97_74C4, 0x3E00_0000, 0x3F90_0000]),
            // leaf-rad12
            ([0x4140_0000, 0x3F80_0000, 0x3F80_0000, 0x4110_0000], [0xC05B_ED2B, 0xC05B_ED2B, 0x3E00_0000, 0x3F90_0000]),
        ]
        for (input, output) in samples {
            let values = input.map(Float.init(bitPattern:))
            let matrix = WPEParityCamera.perspective(fovY: values[0], aspect: values[1], near: values[2], far: values[3])
            // Transposing native DirectX rows gives Swift columns with identical underlying bytes.
            let actual = (0 ..< 4).flatMap { column in (0 ..< 4).map { matrix[column][$0].bitPattern } }
            var expected = [UInt32](repeating: 0, count: 16)
            for (index, bits) in zip([0, 5, 10, 14], output) {
                expected[index] = bits
            }
            expected[11] = 0xBF80_0000
            XCTAssertEqual(actual, expected, "Input bits: \(input)")
        }
    }
}
