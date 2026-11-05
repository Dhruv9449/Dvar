/// Minimal parser for `<positional>... [--option value] [--flag]`.
struct Arguments {
    private(set) var positional: [String] = []
    private var options: [String: String] = [:]

    init(_ arguments: [String], options valued: Set<String> = [], flags: Set<String> = []) throws {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if valued.contains(argument) {
                guard let value = remaining.popFirst() else {
                    throw DvarError("\(argument) needs a value")
                }
                options[argument] = value
            } else if flags.contains(argument) {
                options[argument] = ""
            } else if argument.hasPrefix("--") {
                throw DvarError("unknown option \(argument)")
            } else {
                positional.append(argument)
            }
        }
    }

    subscript(option: String) -> String? {
        options[option]
    }

    func has(_ flag: String) -> Bool {
        options[flag] != nil
    }
}
