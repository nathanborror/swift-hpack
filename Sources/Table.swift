//
//  HPACK support for HTTP/2
//  Adapted from PerfectLib/hpack.swift
//

import Foundation

class HeaderField {
    static let headerEntryOverhead = 32

    let name: [UInt8]
    let value: [UInt8]

    var size: Int {
        return name.count + value.count + HeaderField.headerEntryOverhead
    }

    var nameStr: String {
        return String(bytes: name, encoding: .utf8)!
    }

    init(name: [UInt8], value: [UInt8]) {
        self.name = name
        self.value = value
    }

    init(name: String, value: String) {
        self.name = [UInt8](name.utf8)
        self.value = [UInt8](value.utf8)
    }

    convenience init(name: String) {
        self.init(name: name, value: "")
    }

    static func sizeOf(name: [UInt8], value: [UInt8]) -> Int {
        return name.count + value.count + headerEntryOverhead
    }
}

class StaticTable {

    static let table = [
        HeaderField(name: ":authority"),
        HeaderField(name: ":method", value: "GET"),
        HeaderField(name: ":method", value: "POST"),
        HeaderField(name: ":path", value: "/"),
        HeaderField(name: ":path", value: "/index.html"),
        HeaderField(name: ":scheme", value: "http"),
        HeaderField(name: ":scheme", value: "https"),
        HeaderField(name: ":status", value: "200"),
        HeaderField(name: ":status", value: "204"),
        HeaderField(name: ":status", value: "206"),
        HeaderField(name: ":status", value: "304"),
        HeaderField(name: ":status", value: "400"),
        HeaderField(name: ":status", value: "404"),
        HeaderField(name: ":status", value: "500"),
        HeaderField(name: "accept-charset"),
        HeaderField(name: "accept-encoding", value: "gzip, deflate"),
        HeaderField(name: "accept-language"),
        HeaderField(name: "accept-ranges"),
        HeaderField(name: "accept"),
        HeaderField(name: "access-control-allow-origin"),
        HeaderField(name: "age"),
        HeaderField(name: "allow"),
        HeaderField(name: "authorization"),
        HeaderField(name: "cache-control"),
        HeaderField(name: "content-disposition"),
        HeaderField(name: "content-encoding"),
        HeaderField(name: "content-language"),
        HeaderField(name: "content-length"),
        HeaderField(name: "content-location"),
        HeaderField(name: "content-range"),
        HeaderField(name: "content-type"),
        HeaderField(name: "cookie"),
        HeaderField(name: "date"),
        HeaderField(name: "etag"),
        HeaderField(name: "expect"),
        HeaderField(name: "expires"),
        HeaderField(name: "from"),
        HeaderField(name: "host"),
        HeaderField(name: "if-match"),
        HeaderField(name: "if-modified-since"),
        HeaderField(name: "if-none-match"),
        HeaderField(name: "if-range"),
        HeaderField(name: "if-unmodified-since"),
        HeaderField(name: "last-modified"),
        HeaderField(name: "link"),
        HeaderField(name: "location"),
        HeaderField(name: "max-forwards"),
        HeaderField(name: "proxy-authenticate"),
        HeaderField(name: "proxy-authorization"),
        HeaderField(name: "range"),
        HeaderField(name: "referer"),
        HeaderField(name: "refresh"),
        HeaderField(name: "retry-after"),
        HeaderField(name: "server"),
        HeaderField(name: "set-cookie"),
        HeaderField(name: "strict-transport-security"),
        HeaderField(name: "transfer-encoding"),
        HeaderField(name: "user-agent"),
        HeaderField(name: "vary"),
        HeaderField(name: "via"),
        HeaderField(name: "www-authenticate")
    ]

    static let tableByName: [String:Int] = {
        var ret = [String:Int]()
        var i = table.count

        while i > 0 {
            ret[StaticTable.getEntry(index: i).nameStr] = i
            i -= 1
        }

        return ret
    }()

    static let length = table.count

    static func getEntry(index: Int) -> HeaderField {
        return table[index - 1]
    }

    static func getIndex(name: [UInt8]) -> Int {
        let s = String(bytes: name, encoding: .utf8)!
        if let idx = tableByName[s] {
            return idx
        }
        return -1
    }

    static func getIndex(name: [UInt8], value: [UInt8]) -> Int {
        let idx = getIndex(name: name)
        if idx != -1 {
            for i in idx...length {
                let entry = getEntry(index: i)
                if entry.name != name {
                    break
                }
                if entry.value == value {
                    return i
                }
            }
        }
        return -1
    }
}

class DynamicTable {

    var headerFields = [HeaderField?]()
    var head = 0
    var tail = 0
    var size = 0
    var capacity = -1 {
        didSet {
            self.capacityChanged(oldValue: oldValue)
        }
    }

    var length: Int {
        if head < tail {
            return headerFields.count - tail + head
        }
        return head - tail
    }

    init(initialCapacity: Int) {
        self.capacity = initialCapacity
        self.capacityChanged(oldValue: -1)
    }

    private func capacityChanged(oldValue: Int) {
        guard capacity >= 0 else {
            return
        }
        guard capacity != oldValue else {
            return
        }
        if capacity == 0 {
            clear()
        } else {
            while size > capacity {
                remove()
            }
        }

        var maxEntries = capacity / HeaderField.headerEntryOverhead
        if capacity % HeaderField.headerEntryOverhead != 0 {
            maxEntries += 1
        }

        if headerFields.count != maxEntries {
            var tmp = [HeaderField?](repeating: nil, count: maxEntries)

            let len = length
            var cursor = tail

            for i in 0..<len {
                tmp[i] = headerFields[cursor]
                if cursor == headerFields.count {
                    cursor = 0
                } else {
                    cursor += 1
                }
            }

            tail = 0
            head = tail + len
            headerFields = tmp
        }
    }

    func clear() {
        while tail != head {
            headerFields[tail] = nil
            tail += 1
            if tail == headerFields.count {
                tail = 0
            }
        }
        head = 0
        tail = 0
        size = 0
    }

    @discardableResult
    func remove() -> HeaderField? {
        guard let removed = headerFields[tail] else {
            return nil
        }
        size -= removed.size
        headerFields[tail] = nil
        tail += 1
        if tail == headerFields.count {
            tail = 0
        }
        return removed
    }

    func getEntry(index: Int) -> HeaderField {
        let i = head - index
        if i < 0 {
            return headerFields[i + headerFields.count]!
        }
        return headerFields[i]!
    }

    func add(header: HeaderField) {
        let headerSize = header.size
        if headerSize > capacity {
            clear()
        } else {
            while size + headerSize > capacity {
                remove()
            }
            headerFields[head] = header
            head += 1
            size += header.size
            if head == headerFields.count {
                head = 0
            }
        }
    }
}
