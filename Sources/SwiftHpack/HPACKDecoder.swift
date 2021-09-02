//
//  HPACK support for HTTP/2
//  Adapted from PerfectLib/hpack.swift
//

import Foundation

public class HPACKDecoder {

    public enum Exception: Error {
        case decompressionException
        case illegalIndexValue(Int)
        case invalidMaxDynamicTableSize
        case maxDynamicTableSizeChangeRequested
    }

    enum State {
        case readHeaderRepresentation
        case readMaxDynamicTableSize
        case readIndexedHeader
        case readIndexedHeaderName
        case readLiteralHeaderNameLengthPrefix
        case readLiteralHeaderNameLength
        case readLiteralHeaderName
        case skipLiteralHeaderName
        case readLiteralHeaderValueLengthPrefix
        case readLiteralHeaderValueLength
        case readLiteralHeaderValue
        case skipLiteralHeaderValue
    }

    static let empty = [UInt8]()

    let dynamicTable: DynamicTable

    let maxHeaderSize: Int
    var maxDynamicTableSize: Int
    var encoderMaxDynamicTableSize: Int

    var maxDynamicTableSizeChangeRequired: Bool

    var state: State

    var index = 0
    var headerSize = 0
    var indexType = IndexType.None
    var huffmanEncoded = false
    var name: [UInt8]?
    var skipLength = 0
    var nameLength = 0
    var valueLength = 0

    /// Construct an HPACKDecoder with the given memory constraints.
    public init(maxHeaderSize: Int = 256, maxHeaderTableSize: Int = 256) {
        self.dynamicTable = DynamicTable(initialCapacity: maxHeaderTableSize * 8)
        self.maxHeaderSize = maxHeaderSize
        self.maxDynamicTableSize = maxHeaderTableSize
        self.encoderMaxDynamicTableSize = maxHeaderTableSize
        self.maxDynamicTableSizeChangeRequired = false
        self.state = .readHeaderRepresentation
    }

    func reset() {
        headerSize = 0
        state = .readHeaderRepresentation
        indexType = .None
    }

    func endHeaderBlock() -> Bool {
        let truncated = headerSize > maxHeaderSize
        reset()
        return truncated
    }

    func setMaxHeaderTableSize(maxHeaderTableSize: Int) {
        maxDynamicTableSize = maxHeaderTableSize
        if maxDynamicTableSize < encoderMaxDynamicTableSize {
            maxDynamicTableSizeChangeRequired = true
            dynamicTable.capacity = maxDynamicTableSize
        }
    }

    func getMaxHeaderTableSize() -> Int {
        return dynamicTable.capacity
    }

    var length: Int { return dynamicTable.length }
    var size: Int { return dynamicTable.size }

    func getHeaderField(index: Int) -> HeaderField {
        return dynamicTable.getEntry(index: index + 1)
    }

    func setDynamicTableSize(dynamicTableSize: Int) {
        encoderMaxDynamicTableSize = dynamicTableSize
        maxDynamicTableSizeChangeRequired = false
        dynamicTable.capacity = dynamicTableSize
    }

    func readName(index: Int) throws {
        if index <= StaticTable.length {
            name = StaticTable.getEntry(index: index).name
        } else if index - StaticTable.length <= dynamicTable.length {
            name = dynamicTable.getEntry(index: index - StaticTable.length).name
        } else {
            throw Exception.illegalIndexValue(index)
        }
    }

    func indexHeader(index: Int, headerListener: HeaderListener) throws {
        if index <= StaticTable.length {
            let headerField = StaticTable.getEntry(index: index)
            addHeader(headerListener: headerListener, name: headerField.name, value: headerField.value, sensitive: false)
        } else if index - StaticTable.length <= dynamicTable.length {
            let headerField = dynamicTable.getEntry(index: index - StaticTable.length)
            addHeader(headerListener: headerListener, name: headerField.name, value: headerField.value, sensitive: false)
        } else {
            throw Exception.illegalIndexValue(index)
        }
    }

    func addHeader(headerListener: HeaderListener, name: [UInt8], value: [UInt8], sensitive: Bool) {
        let newSize = headerSize + name.count + value.count
        if newSize <= maxHeaderSize {
            headerListener.addHeader(name: name, value: value, sensitive: sensitive)
            headerSize = newSize
        } else {
            headerSize = maxHeaderSize + 1
        }
    }

    func insertHeader(headerListener: HeaderListener, name: [UInt8], value: [UInt8], indexType: IndexType) {
        addHeader(headerListener: headerListener, name: name, value: value, sensitive: indexType == .Never)
        switch indexType {
        case .None, .Never:
            ()
        case .Incremental:
            dynamicTable.add(header: HeaderField(name: name, value: value))
        }
    }

    func exceedsMaxHeaderSize(size: Int) -> Bool {
        if size + headerSize <= maxHeaderSize {
            return false
        }
        headerSize = maxHeaderSize + 1
        return true
    }

    func readStringLiteral(input: Bytes, length: Int) throws -> [UInt8] {
        let read = input.exportBytes(count: length)
        if read.count != length {
            throw Exception.decompressionException
        }
        if huffmanEncoded {
            return try sharedHuffmanDecoder.decode(buf: read)
        } else {
            return read
        }
    }

    func decodeULE128(input: Bytes) throws -> Int {
        let oldPos = input.position
        var result = 0
        var shift = 0
        while shift < 32 {
            if input.availableExportBytes == 0 {
                input.position = oldPos
                return -1
            }
            let b = input.export8Bits()
            if shift == 28 && (b & 0xF8) != 0 {
                break
            }
            result |= Int(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        input.position = oldPos
        throw Exception.decompressionException
    }

    /// Decode the headers, sending them sequentially to headerListener.
    public func decode(input: Bytes, headerListener: HeaderListener) throws {
        while input.availableExportBytes > 0 {
            switch state {
            case .readHeaderRepresentation:
                let b = input.export8Bits()
                if maxDynamicTableSizeChangeRequired && (b & 0xE0) != 0x20 {
                    throw Exception.maxDynamicTableSizeChangeRequested
                }
                if (b & 0x80) != 0 { //b < 0 {
                    index = Int(b & 0x7F)
                    if index == 0 {
                        throw Exception.illegalIndexValue(index)
                    } else if index == 0x7F {
                        state = .readIndexedHeader
                    } else {
                        try indexHeader(index: index, headerListener: headerListener)
                    }
                } else if (b & 0x40) == 0x40 {
                    indexType = .Incremental
                    index = Int(b & 0x3F)
                    if index == 0 {
                        state = .readLiteralHeaderNameLengthPrefix
                    } else if index == 0x3F {
                        state = .readIndexedHeaderName
                    } else {
                        try readName(index: index)
                        state = .readLiteralHeaderValueLengthPrefix
                    }
                } else if (b & 0x20) == 0x20 {
                    index = Int(b & 0x1F)
                    if index == 0x1F {
                        state = .readMaxDynamicTableSize
                    } else {
                        setDynamicTableSize(dynamicTableSize: index)
                        state = .readHeaderRepresentation
                    }
                } else {
                    indexType = (b & 0x10) == 0x10 ? .Never : .None
                    index = Int(b & 0x0F)
                    if index == 0 {
                        state = .readLiteralHeaderNameLengthPrefix
                    } else if index == 0x0F {
                        state = .readIndexedHeaderName
                    } else {
                        try readName(index: index)
                        state = .readLiteralHeaderValueLengthPrefix
                    }
                }

            case .readMaxDynamicTableSize:
                let maxSize = try decodeULE128(input: input)
                if maxSize == -1 {
                    return
                }
                if maxSize > HPACKEncoder.INDEX_MAX - index {
                    throw Exception.decompressionException
                }
                setDynamicTableSize(dynamicTableSize: index + maxSize)
                state = .readHeaderRepresentation

            case .readIndexedHeader:
                let headerIndex = try decodeULE128(input: input)
                if headerIndex == -1 {
                    return
                }
                if headerIndex > HPACKEncoder.INDEX_MAX - index {
                    throw Exception.decompressionException
                }
                try indexHeader(index: index + headerIndex, headerListener: headerListener)
                state = .readHeaderRepresentation

            case .readIndexedHeaderName:
                let nameIndex = try decodeULE128(input: input)
                if nameIndex == -1 {
                    return
                }
                if nameIndex > HPACKEncoder.INDEX_MAX - index {
                    throw Exception.decompressionException
                }
                try readName(index: index + nameIndex)
                state = .readLiteralHeaderValueLengthPrefix

            case .readLiteralHeaderNameLengthPrefix:

                let b = input.export8Bits()
                huffmanEncoded = (b & 0x80) == 0x80
                index = Int(b & 0x7F)
                if index == 0x7F {
                    state = .readLiteralHeaderNameLength
                } else {
                    nameLength = index
                    if nameLength == 0 {
                        throw Exception.decompressionException
                    }
                    if exceedsMaxHeaderSize(size: nameLength) {
                        if indexType == .None {
                            name = HPACKDecoder.empty
                            skipLength = nameLength
                            state = .skipLiteralHeaderName
                            break // check me
                        }
                        if nameLength + HeaderField.headerEntryOverhead > dynamicTable.capacity {
                            dynamicTable.clear()
                            name = HPACKDecoder.empty
                            skipLength = nameLength
                            state  = .skipLiteralHeaderName
                            break
                        }
                    }
                    state = .readLiteralHeaderName
                }

            case .readLiteralHeaderNameLength:

                nameLength = try decodeULE128(input: input)
                if nameLength == -1 {
                    return
                }
                if nameLength > HPACKEncoder.INDEX_MAX - index {
                    throw Exception.decompressionException
                }
                nameLength += index
                if exceedsMaxHeaderSize(size: nameLength) {
                    if indexType == .None {
                        name = HPACKDecoder.empty
                        skipLength = nameLength
                        state = .skipLiteralHeaderName
                        break // check me
                    }
                    if nameLength + HeaderField.headerEntryOverhead > dynamicTable.capacity {
                        dynamicTable.clear()
                        name = HPACKDecoder.empty
                        skipLength = nameLength
                        state  = .skipLiteralHeaderName
                        break
                    }
                }
                state = .readLiteralHeaderName

            case .readLiteralHeaderName:

                if input.availableExportBytes < nameLength {
                    return
                }

                name = try readStringLiteral(input: input, length: nameLength)
                state = .readLiteralHeaderValueLengthPrefix

            case .skipLiteralHeaderName:

                let toSkip = min(skipLength, input.availableExportBytes)
                input.position += toSkip
                skipLength -= toSkip
                if skipLength == 0 {
                    state = .readLiteralHeaderValueLengthPrefix
                }

            case .readLiteralHeaderValueLengthPrefix:

                let b = input.export8Bits()
                huffmanEncoded = (b & 0x80) == 0x80
                index = Int(b & 0x7F)
                if index == 0x7f {
                    state = .readLiteralHeaderValueLength
                } else {
                    valueLength = index
                    let newHeaderSize = nameLength + valueLength
                    if exceedsMaxHeaderSize(size: newHeaderSize) {
                        headerSize = maxHeaderSize + 1
                        if indexType == .None {
                            state = .skipLiteralHeaderValue
                            break
                        }
                        if newHeaderSize + HeaderField.headerEntryOverhead > dynamicTable.capacity {
                            dynamicTable.clear()
                            state = .skipLiteralHeaderValue
                            break
                        }
                    }

                    if valueLength == 0 {
                        insertHeader(headerListener: headerListener, name: name!, value: HPACKDecoder.empty, indexType: indexType)
                        state = .readHeaderRepresentation
                    } else {
                        state = .readLiteralHeaderValue
                    }
                }

            case .readLiteralHeaderValueLength:

                valueLength = try decodeULE128(input: input)
                if valueLength == -1 {
                    return
                }
                if valueLength > HPACKEncoder.INDEX_MAX - index {
                    throw Exception.decompressionException
                }
                valueLength += index

                let newHeaderSize = nameLength + valueLength
                if newHeaderSize + headerSize > maxHeaderSize {
                    headerSize = maxHeaderSize + 1
                    if indexType == .None {
                        state = .skipLiteralHeaderValue
                        break
                    }
                    if newHeaderSize + HeaderField.headerEntryOverhead > dynamicTable.capacity {
                        dynamicTable.clear()
                        state = .skipLiteralHeaderValue
                        break
                    }
                }
                state = .readLiteralHeaderValue

            case .readLiteralHeaderValue:

                if input.availableExportBytes < valueLength {
                    return
                }

                let value = try readStringLiteral(input: input, length: valueLength)
                insertHeader(headerListener: headerListener, name: name!, value: value, indexType: indexType)
                state = .readHeaderRepresentation

            case .skipLiteralHeaderValue:
                let toSkip = min(valueLength, input.availableExportBytes)
                input.position += toSkip
                valueLength -= toSkip
                if valueLength == 0 {
                    state = .readHeaderRepresentation
                }
            }
        }
    }
}

class HuffmanDecoder {

    enum Exception: Error {
        case EOSDecoded, InvalidPadding
    }

    class Node {
        let symbol: Int
        let bits: UInt8
        var children: [Node?]?

        var isTerminal: Bool {
            return self.children == nil
        }

        init() {
            self.symbol = 0
            self.bits = 8
            self.children = [Node?](repeating: nil, count: 256)
        }

        init(symbol: Int, bits: UInt8) {
            self.symbol = symbol
            self.bits = bits
            self.children = nil
        }
    }

    let root: Node

    init(codes: [Int], lengths: [UInt8]) {
        self.root = HuffmanDecoder.buildTree(codes: codes, lengths: lengths)
    }

    func decode(buf: [UInt8]) throws -> [UInt8] {
        var retBytes = [UInt8]()

        var node = root
        var current = 0
        var bits = 0
        for byte in buf {
            let b = byte & 0xFF
            current = (current << 8) | Int(b)
            bits += 8
            while bits >= 8 {
                let c = (current >> (bits - 8)) & 0xFF
                node = node.children![c]!
                bits -= Int(node.bits)
                if node.isTerminal {
                    if node.symbol == huffmanEOS {
                        throw Exception.EOSDecoded
                    }
                    retBytes.append(UInt8(node.symbol))
                    node = root
                }
            }
        }

        while bits > 0 {
            let c = (current << (8 - bits)) & 0xFF
            node = node.children![c]!
            if node.isTerminal && Int(node.bits) <= bits {
                bits -= Int(node.bits)
                retBytes.append(UInt8(node.symbol))
                node = root
            } else {
                break
            }
        }

        let mask = (1 << bits) - 1
        if (current & mask) != mask {
            throw Exception.InvalidPadding
        }

        return retBytes
    }

    static func buildTree(codes: [Int], lengths: [UInt8]) -> Node {
        let root = Node()
        for i in 0..<codes.count {
            insert(root: root, symbol: i, code: codes[i], length: lengths[i])
        }
        return root
    }

    static func insert(root: Node, symbol: Int, code: Int, length: UInt8) {
        var current = root
        var len = Int(length)
        while len > 8 {
            len -= 8
            let i = (code >> len) & 0xFF
            if nil == current.children![i] {
                current.children![i] = Node()
            }
            current = current.children![i]!
        }
        let terminal = Node(symbol: symbol, bits: length)
        let shift = 8 - len
        let start = (code << shift) & 0xFF
        let end = 1 << shift
        for i in start..<(start+end) {
            current.children![i] = terminal
        }
    }
}
