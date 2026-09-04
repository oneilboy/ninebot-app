//
//  JavaRandom.swift
//  Herimplementatie van java.util.Random (48-bit Linear Congruential Generator).
//  Nodig omdat de Segway/Ninebot Android-app dit gebruikt om het sessiewachtwoord
//  te genereren tijdens SET_PWD — voor interoperabiliteit moet de iOS-kant exact
//  hetzelfde algoritme volgen.
//

import Foundation

struct JavaRandom {
    private var seed: UInt64
    private static let multiplier: UInt64 = 0x5DEECE66D
    private static let addend: UInt64 = 0xB
    private static let mask: UInt64 = (1 << 48) - 1

    init(seed: Int64) {
        self.seed = (UInt64(bitPattern: seed) ^ JavaRandom.multiplier) & JavaRandom.mask
    }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* JavaRandom.multiplier &+ JavaRandom.addend) & JavaRandom.mask
        let shifted = Int64(bitPattern: seed) >> (48 - bits)
        return Int32(truncatingIfNeeded: shifted)
    }

    /// Komt overeen met java.util.Random#nextBytes(byte[])
    mutating func nextBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var i = 0
        while i < count {
            var rnd = next(32)
            var n = min(count - i, 4)
            while n > 0 {
                bytes[i] = UInt8(truncatingIfNeeded: rnd)
                rnd = rnd >> 8   // arithmetic shift, zoals Java's rnd >>= 8 op een int
                i += 1
                n -= 1
            }
        }
        return bytes
    }
}
