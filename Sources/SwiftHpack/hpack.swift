//
//  HPACK support for HTTP/2
//  Adapted from PerfectLib/hpack.swift
//

import Foundation

let sharedHuffmanEncoder = HuffmanEncoder(codes: huffmanCodes, lengths: huffmanCodeLengths)
let sharedHuffmanDecoder = HuffmanDecoder(codes: huffmanCodes, lengths: huffmanCodeLengths)

func ==(lhs: [UInt8], rhs: [UInt8]) -> Bool {
    let c1 = lhs.count
    if c1 == rhs.count {
        for i in 0..<c1 {
            if lhs[i] != rhs[i] {
                return false
            }
        }
        return true
    }
    return false
}

public protocol HeaderListener {
    func addHeader(name: [UInt8], value: [UInt8], sensitive: Bool)
}

enum IndexType {
    case Incremental, None, Never
}
