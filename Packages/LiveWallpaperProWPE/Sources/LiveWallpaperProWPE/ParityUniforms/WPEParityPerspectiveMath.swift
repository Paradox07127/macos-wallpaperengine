/// Selector-3 finite perspective helpers translated from the original instructions. The full finite
/// domain, floating-point environment/status and exceptional paths remain unqualified.
enum WPEParityPerspectiveMath {
    /// 14041b0d0: finite paths before the unqualified 1404720e0 argument-reduction table.
    static func tangent(_ input: Float) -> Float? {
        let magnitudeBits = input.bitPattern & 0x7FFF_FFFF
        guard magnitudeBits < 0x7F80_0000 else { return nil }
        let value = Double(input)
        if magnitudeBits <= 0x3F49_0FDB {
            if magnitudeBits < 0x3200_0000 {
                // The original returns XMM0 unchanged; unused flag-raising operations are not emulated.
                return input
            }
            if magnitudeBits < 0x3900_0000 {
                let square = value * value
                let cubic = square * value
                return Float(value.addingProduct(cubic, Double(bitPattern: 0x3FD5_5555_5555_5555)))
            }
            return Float(tangentRational(value))
        }

        let magnitude = Double(bitPattern: value.bitPattern & 0x7FFF_FFFF_FFFF_FFFF)
        guard magnitude.bitPattern < 0x41E9_21FB_4000_0000 else { return nil }
        // 41b19d..1bc: FMA, CVTTPD2DQ, sign extension, then integer-to-Double conversion.
        let scaled = Double(bitPattern: 0x3FE0_0000_0000_0000)
            .addingProduct(magnitude, Double(bitPattern: 0x3FE4_5F30_6DC9_C883))
        let turns = WPEParityNumericConversion.cvttsd2si(scaled)
        let turnsValue = Double(turns)
        let remainder = magnitude.addingProduct(-turnsValue, Double(bitPattern: 0x3FF9_21FB_5440_0000))
        let tail = turnsValue * Double(bitPattern: 0x3DD0_B461_1A62_6331)
        let reduced = remainder - tail
        // 41b1d9..1dd's correction is overwritten at 41b341 before any output use.
        var result = tangentRational(reduced)
        if turns & 1 == 1 {
            result = Double(bitPattern: 0xBFF0_0000_0000_0000) / result
        }
        let signed = Double(bitPattern: result.bitPattern ^ (value.bitPattern & 0x8000_0000_0000_0000))
        return Float(signed)
    }

    /// 14041b3b0: finite paths that do not call the external error helper at 1402de940.
    static func arctangent(_ input: Float) -> Float? {
        guard input.isFinite else { return nil }
        let value = Double(input)
        let magnitudeBits = value.bitPattern & 0x7FFF_FFFF_FFFF_FFFF
        guard magnitudeBits <= 0x43D3_2000_0000_0000 else { return nil }
        let magnitude = Double(bitPattern: magnitudeBits)
        let reduced: Double
        let offset: Double
        if magnitudeBits < 0x3FDC_0000_0000_0000 {
            reduced = magnitude
            offset = 0
        } else if magnitudeBits < 0x3FE6_0000_0000_0000 {
            let doubled = magnitude + magnitude
            let numerator = doubled - Double(bitPattern: 0x3FF0_0000_0000_0000)
            let denominator = magnitude + Double(bitPattern: 0x4000_0000_0000_0000)
            reduced = numerator / denominator
            offset = Double(bitPattern: 0x3FDD_AC67_0561_BB4F)
        } else if magnitudeBits < 0x3FF3_0000_0000_0000 {
            let numerator = magnitude - Double(bitPattern: 0x3FF0_0000_0000_0000)
            let denominator = magnitude + Double(bitPattern: 0x3FF0_0000_0000_0000)
            reduced = numerator / denominator
            offset = Double(bitPattern: 0x3FE9_21FB_5444_2D18)
        } else if magnitudeBits < 0x4003_8000_0000_0000 {
            let denominator = Double(bitPattern: 0x3FF0_0000_0000_0000)
                .addingProduct(magnitude, Double(bitPattern: 0x3FF8_0000_0000_0000))
            let numerator = magnitude - Double(bitPattern: 0x3FF8_0000_0000_0000)
            reduced = numerator / denominator
            offset = Double(bitPattern: 0x3FEF_730B_D281_F69B)
        } else {
            reduced = Double(bitPattern: 0xBFF0_0000_0000_0000) / magnitude
            offset = Double(bitPattern: 0x3FF9_21FB_5444_2D18)
        }

        // 41b4fc..544: each addingProduct is one native fused rounding; other operators stay separate.
        let square = reduced * reduced
        var numerator = Double(bitPattern: 0x3FC8_9E17_3A81_EE7F)
            .addingProduct(square, Double(bitPattern: 0x3F73_476A_758D_A22A))
        numerator = Double(bitPattern: 0x3FD2_FA53_1690_7834).addingProduct(square, numerator)
        let cubic = reduced * square
        let product = numerator * cubic
        var denominator = Double(bitPattern: 0x3FF1_C587_93DA_6EA4)
            .addingProduct(square, Double(bitPattern: 0x3FD3_27E3_DF2C_F2AA))
        denominator = Double(bitPattern: 0x3FEC_777C_A210_53F0).addingProduct(square, denominator)
        let quotient = product / denominator
        let residual = quotient - reduced
        let result = offset - residual
        let signed = Double(bitPattern: result.bitPattern ^ (value.bitPattern & 0x8000_0000_0000_0000))
        return Float(signed)
    }

    /// Shared original 41b13e..175 / 41b341..378, including the four fused operations.
    private static func tangentRational(_ value: Double) -> Double {
        let square = value * value
        let numerator = Double(bitPattern: 0x3FD8_A8B0_DA56_CB17)
            .addingProduct(square, Double(bitPattern: 0xBF91_9DBA_6EFD_6AAD))
        var denominator = Double(bitPattern: 0xBFE0_7266_D7B3_511B)
            .addingProduct(square, Double(bitPattern: 0x3F92_E290_03C6_92D9))
        denominator = Double(bitPattern: 0x3FF2_7E84_A3E7_3A2E).addingProduct(square, denominator)
        let quotient = numerator / denominator
        let cubic = square * value
        return value.addingProduct(cubic, quotient)
    }
}
