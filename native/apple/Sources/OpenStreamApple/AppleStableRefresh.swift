enum AppleStableRefresh {
    /// Display-session ordering only; canonical provider data must retain its incoming order.
    static func merge<Value, ID: Hashable>(_ previous: [Value], incoming: [Value], id: (Value) -> ID) -> [Value] {
        let replacements = Dictionary(incoming.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<ID>()
        let retained = previous.compactMap { value -> Value? in
            let key = id(value)
            guard seen.insert(key).inserted else { return nil }
            return replacements[key]
        }
        return retained + incoming.filter { seen.insert(id($0)).inserted }
    }
}
