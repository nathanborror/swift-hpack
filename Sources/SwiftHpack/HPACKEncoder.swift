//
//  HPACK support for HTTP/2
//  Adapted from PerfectLib/hpack.swift
//

import Foundation

public class HPACKEncoder {

    static let bucketSize = 17
    static let empty = [UInt8]()
    static let INDEX_MAX = 2147483647
    static let INDEX_MIN = -2147483648

    var headerFields: [HeaderEntry?]
    var head = HeaderEntry(hash: -1, name: empty, value: empty, index: INDEX_MAX, next: nil)
    var size = 0
    var capacity = 0

    var maxHeaderTableSize: Int { return capacity }
    var length: Int {
        return size == 0 ? 0 : head.after!.index - head.before!.index + 1
    }

    class HeaderEntry: HeaderField {

        var before: HeaderEntry?
        var after: HeaderEntry?
        var next: HeaderEntry?

        let hash: Int
        let index: Int

        init(hash: Int, name: [UInt8], value: [UInt8], index: Int, next: HeaderEntry?) {
            self.index = index
            self.hash = hash
            super.init(name: name, value: value)
            self.next = next
        }

        func remove() {
            before!.after = after
            after!.before = before
        }

        func addBefore(existingEntry: HeaderEntry) {
            after = existingEntry
            before = existingEntry.before
            before!.after = self
            after!.before = self
        }
    }

    /// Construct an Encoder with the indicated maximum capacity.
    public init(maxCapacity: Int = 256) {
        self.capacity = maxCapacity
        self.head.after = self.head
        self.head.before = self.head
        self.headerFields = [HeaderEntry?](repeating: nil, count: HPACKEncoder.bucketSize)
    }

    /// Encodes a new header field and value, writing the results to out Bytes.
    public func encodeHeader(out: Bytes, name: String, value: String, sensitive: Bool = false, incrementalIndexing: Bool = true) throws {
        return try encodeHeader(out: out, name: [UInt8](name.utf8), value: [UInt8](value.utf8), sensitive: sensitive, incrementalIndexing: incrementalIndexing)
    }

    /// Encodes a new header field and value, writing the results to out Bytes.
    public func encodeHeader(out: Bytes, name: [UInt8], value: [UInt8], sensitive: Bool = false, incrementalIndexing: Bool = true) throws {
        if sensitive {
            let nameIndex = getNameIndex(name: name)
            try encodeLiteral(out: out, name: name, value: value, indexType: .Never, nameIndex: nameIndex)
            return
        }
        if capacity == 0 {
            let staticTableIndex = StaticTable.getIndex(name: name, value: value)
            if staticTableIndex == -1 {
                let nameIndex = StaticTable.getIndex(name: name)
                try encodeLiteral(out: out, name: name, value: value, indexType: .None, nameIndex: nameIndex)
            } else {
                encodeInteger(out: out, mask: 0x80, n: 7, i: staticTableIndex)
            }
            return
        }
        let headerSize = HeaderField.sizeOf(name: name, value: value)
        if headerSize > capacity {
            let nameIndex = getNameIndex(name: name)
            try encodeLiteral(out: out, name: name, value: value, indexType: .None, nameIndex: nameIndex)
        } else if let headerField = getEntry(name: name, value: value) {
            let index = getIndex(index: headerField.index) + StaticTable.length
            encodeInteger(out: out, mask: 0x80, n: 7, i: index)
        } else {
            let staticTableIndex = StaticTable.getIndex(name: name, value: value)
            if staticTableIndex != -1 {
                encodeInteger(out: out, mask: 0x80, n: 7, i: staticTableIndex)
            } else {
                let nameIndex = getNameIndex(name: name)
                ensureCapacity(headerSize: headerSize)
                let indexType = incrementalIndexing ? IndexType.Incremental : IndexType.None
                try encodeLiteral(out: out, name: name, value: value, indexType: indexType, nameIndex: nameIndex)
                add(name: name, value: value)
            }
        }
    }

    func index(h: Int) -> Int {
        return h % HPACKEncoder.bucketSize
    }

    func hash(name: [UInt8]) -> Int {
        var h = 0
        for b in name {
            h = 31 &* h &+ Int(b)
        }
        if h > 0 {
            return h
        }
        if h == HPACKEncoder.INDEX_MIN {
            return HPACKEncoder.INDEX_MAX
        }
        return -h
    }

    func clear() {
        for i in 0..<self.headerFields.count {
            self.headerFields[i] = nil
        }
        head.before = head
        head.after = head
        size = 0
    }

    @discardableResult
    func remove() -> HeaderField? {
        if size == 0 {
            return nil
        }
        let eldest = head.after
        let h = eldest!.hash
        let i = index(h: h)

        var prev = headerFields[i]
        var e = prev

        while let ee = e {
            let next = ee.next
            if ee === eldest! {
                if prev === eldest! {
                    headerFields[i] = next
                } else {
                    prev!.next = next
                }
                eldest!.remove()
                size -= eldest!.size
                return eldest
            }
            prev = e
            e = next
        }
        return nil
    }

    func add(name: [UInt8], value: [UInt8]) {
        let headerSize = HeaderField.sizeOf(name: name, value: value)

        if headerSize > capacity {
            clear()
            return
        }

        while size + headerSize > capacity {
            remove()
        }

        let h = hash(name: name)
        let i = index(h: h)

        let old = headerFields[i]
        let e = HeaderEntry(hash: h, name: name, value: value, index: head.before!.index - 1, next: old)
        headerFields[i] = e
        e.addBefore(existingEntry: head)
        size += headerSize
    }

    func getIndex(index: Int) -> Int {
        if index == -1 {
            return index
        }
        return index - head.before!.index + 1
    }

    func getIndex(name: [UInt8]) -> Int {
        if length == 0 || name.count == 0 {
            return -1
        }
        let h = hash(name: name)
        let i = self.index(h: h)
        var index = -1
        var e = headerFields[i]
        while let ee = e {
            if ee.hash == h && name == ee.name {
                index = ee.index
                break
            }
            e = ee.next
        }
        return getIndex(index: index)
    }

    func getEntry(name: [UInt8], value: [UInt8]) -> HeaderEntry? {
        if length == 0 || name.count == 0 || value.count == 0 {
            return nil
        }
        let h = hash(name: name)
        let i = index(h: h)
        var e = headerFields[i]
        while let ee = e {
            if ee.hash == h && name == ee.name && value == ee.value {
                return ee
            }
            e = ee.next
        }
        return nil
    }

    func getHeaderField(index: Int) -> HeaderField? {
        var entry = head
        var i = index
        while i >= 0 {
            i -= 1
            entry = entry.before!
        }
        return entry
    }

    func ensureCapacity(headerSize: Int) {
        while size + headerSize > capacity {
            if length == 0 {
                break
            }
            remove()
        }
    }

    func getNameIndex(name: [UInt8]) -> Int {
        var index = StaticTable.getIndex(name: name)
        if index == -1 {
            index = getIndex(name: name)
            if index >= 0 {
                index += StaticTable.length
            }
        }
        return index
    }

    func encodeInteger(out: Bytes, mask: Int, n: Int, i: Int) {
        let nbits = 0xFF >> (8 - n)
        if i < nbits {
            out.import8Bits(from: UInt8(mask | i))
        } else {
            out.import8Bits(from: UInt8(mask | nbits))
            var length = i - nbits
            while true {
                if (length & ~0x7F) == 0 {
                    out.import8Bits(from: UInt8(length))
                    return
                } else {
                    out.import8Bits(from: UInt8((length & 0x7f) | 0x80))
                    length >>= 7
                }
            }
        }
    }

    func encodeStringLiteral(out: Bytes, string: [UInt8]) throws {
        let length = sharedHuffmanEncoder.getEncodedLength(data: string)
        if length < string.count {
            encodeInteger(out: out, mask: 0x80, n: 7, i: length)
            try sharedHuffmanEncoder.encode(out: out, input: Bytes(existingBytes: string))
        } else {
            encodeInteger(out: out, mask: 0x00, n: 7, i: string.count)
            out.importBytes(from: string)
        }
    }

    func encodeLiteral(out: Bytes, name: [UInt8], value: [UInt8], indexType: IndexType, nameIndex: Int) throws {
        var mask = 0
        var prefixBits = 0
        switch indexType {
        case .Incremental:
            mask = 0x40
            prefixBits = 6
        case .None:
            mask = 0x00
            prefixBits = 4
        case .Never:
            mask = 0x10
            prefixBits = 4
        }
        encodeInteger(out: out, mask: mask, n: prefixBits, i: nameIndex == -1 ? 0 : nameIndex)
        if nameIndex == -1 {
            try encodeStringLiteral(out: out, string: name)
        }
        try encodeStringLiteral(out: out, string: value)
    }

    func setMaxHeaderTableSize(out: Bytes, maxHeaderTableSize: Int) {
        if capacity == maxHeaderTableSize {
            return
        }
        capacity = maxHeaderTableSize
        ensureCapacity(headerSize: 0)
        encodeInteger(out: out, mask: 0x20, n: 5, i: maxHeaderTableSize)
    }
}

class HuffmanEncoder {

    let codes: [Int]
    let lengths: [UInt8]

    init(codes: [Int], lengths: [UInt8]) {
        self.codes = codes
        self.lengths = lengths
    }

    func encode(input: Bytes) throws -> Bytes {
        let o = Bytes()
        try encode(out: o, input: input)
        return o
    }

    func encode(out: Bytes, input: Bytes) throws {
        var current = 0
        var n = 0

        while input.availableExportBytes > 0 {
            let b = Int(input.export8Bits()) & 0xFF
            let code = codes[b]
            let nbits = Int(lengths[b])

            current <<= nbits
            current |= code
            n += nbits

            while n >= 8 {
                n -= 8
                let newVal = (current >> n) & 0xFF
                out.import8Bits(from: UInt8(newVal))
            }
        }
        if n > 0 {
            current <<= (8 - n)
            current |= (0xFF >> n)
            let newVal = current & 0xFF
            out.import8Bits(from: UInt8(newVal))
        }
    }

    func getEncodedLength(data: [UInt8]) -> Int {
        var len = 0
        for b in data {
            len += Int(lengths[Int(b & 0xFF)])
        }
        return (len + 7) >> 3
    }
}
