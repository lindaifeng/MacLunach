import CryptoKit
import CoreFoundation
import Foundation

public enum ParserTool: String, CaseIterable, Identifiable, Sendable {
    case json
    case base64
    case jwt
    case jsonToYAML
    case yamlToJSON
    case javascript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .json: "JSON 压缩转义"
        case .base64: "Base64 转码"
        case .jwt: "JWT 加解密"
        case .jsonToYAML: "JSON 转 YAML"
        case .yamlToJSON: "YAML 转 JSON"
        case .javascript: "JS 压缩格式化"
        }
    }

    public var symbolName: String {
        switch self {
        case .json: "curlybraces"
        case .base64: "textformat.abc"
        case .jwt: "key.horizontal"
        case .jsonToYAML: "doc.text"
        case .yamlToJSON: "curlybraces.square"
        case .javascript: "chevron.left.forwardslash.chevron.right"
        }
    }

    public var operations: [ParserOperation] {
        switch self {
        case .json: [.format, .minify, .escape, .unescape]
        case .base64: [.encode, .decode]
        case .jwt: [.decodeJWT, .signHS256]
        case .jsonToYAML, .yamlToJSON: [.convert]
        case .javascript: [.format, .minify]
        }
    }

    public var inputHint: String {
        switch self {
        case .json, .jsonToYAML: "在这里粘贴 JSON…"
        case .base64: "输入文本或 Base64 内容…"
        case .jwt: "粘贴 JWT，或输入要签名的 JSON Payload…"
        case .yamlToJSON: "在这里粘贴 YAML…"
        case .javascript: "在这里粘贴 JavaScript…"
        }
    }
}

public enum ParserOperation: String, Identifiable, Sendable {
    case format
    case minify
    case escape
    case unescape
    case encode
    case decode
    case decodeJWT
    case signHS256
    case convert

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .format: "格式化"
        case .minify: "压缩"
        case .escape: "转义"
        case .unescape: "去转义"
        case .encode: "编码"
        case .decode: "解码"
        case .decodeJWT: "解析"
        case .signHS256: "HS256 签名"
        case .convert: "转换"
        }
    }
}

public enum ParserTransformerError: LocalizedError, Equatable {
    case emptyInput
    case invalidJSON
    case invalidBase64
    case invalidJWT
    case missingSecret
    case invalidYAML(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: "等待输入内容"
        case .invalidJSON: "JSON 语法无效，请检查括号、引号或逗号。"
        case .invalidBase64: "Base64 内容无效，无法解码。"
        case .invalidJWT: "JWT 格式无效，应包含由两个点分隔的三段内容。"
        case .missingSecret: "生成 HS256 签名需要填写密钥。"
        case let .invalidYAML(message): "YAML 解析失败：\(message)"
        }
    }
}

public enum ParserTransformer {
    public static func transform(
        _ input: String,
        tool: ParserTool,
        operation: ParserOperation,
        secret: String = ""
    ) throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParserTransformerError.emptyInput
        }

        switch tool {
        case .json:
            return try transformJSON(input, operation: operation)
        case .base64:
            return try transformBase64(input, operation: operation)
        case .jwt:
            return try transformJWT(input, operation: operation, secret: secret)
        case .jsonToYAML:
            return try YAMLCodec.encode(json: input)
        case .yamlToJSON:
            return try YAMLCodec.decodeToJSON(input)
        case .javascript:
            return operation == .minify
                ? JavaScriptTransformer.minify(input)
                : JavaScriptTransformer.format(input)
        }
    }

    private static func transformJSON(_ input: String, operation: ParserOperation) throws -> String {
        switch operation {
        case .escape:
            let data = try JSONEncoder().encode(input)
            return String(decoding: data, as: UTF8.self)
        case .unescape:
            let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                throw ParserTransformerError.invalidJSON
            }
            return decoded
        case .minify:
            _ = try jsonObject(input)
            return minifyJSONWithoutReencoding(input)
        default:
            let object = normalizedJSONValue(try jsonObject(input))
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// 只移除 JSON 字符串之外的空白，避免对象化重编码合并重复键或改变数字精度。
    private static func minifyJSONWithoutReencoding(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var isInsideString = false
        var isEscaped = false

        for character in input {
            if isInsideString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
                output.append(character)
            } else if !character.isWhitespace {
                output.append(character)
            }
        }
        return output
    }

    private static func transformBase64(_ input: String, operation: ParserOperation) throws -> String {
        if operation == .decode {
            let compact = input.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: compact),
                  let output = String(data: data, encoding: .utf8) else {
                throw ParserTransformerError.invalidBase64
            }
            return output
        }
        return Data(input.utf8).base64EncodedString()
    }

    private static func transformJWT(
        _ input: String,
        operation: ParserOperation,
        secret: String
    ) throws -> String {
        if operation == .signHS256 {
            guard !secret.isEmpty else { throw ParserTransformerError.missingSecret }
            _ = try jsonObject(input)
            let header = #"{"alg":"HS256","typ":"JWT"}"#
            let headerPart = base64URL(Data(header.utf8))
            let payloadObject = try jsonObject(input)
            let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            let payloadPart = base64URL(payloadData)
            let signingInput = "\(headerPart).\(payloadPart)"
            let key = SymmetricKey(data: Data(secret.utf8))
            let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
            return "\(signingInput).\(base64URL(Data(signature)))"
        }

        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3,
              let headerData = base64URLData(String(parts[0])),
              let payloadData = base64URLData(String(parts[1])),
              let header = try? JSONSerialization.jsonObject(with: headerData),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) else {
            throw ParserTransformerError.invalidJWT
        }
        var object: [String: Any] = [
            "header": normalizedJSONValue(header),
            "payload": normalizedJSONValue(payload),
            "signature": String(parts[2])
        ]
        if !secret.isEmpty {
            let signature = base64URLData(String(parts[2]))
            let algorithm = (header as? [String: Any])?["alg"] as? String
            let key = SymmetricKey(data: Data(secret.utf8))
            let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
            let isValid = algorithm == "HS256"
                && signature.map {
                    HMAC<SHA256>.isValidAuthenticationCode(
                        $0,
                        authenticating: signingInput,
                        using: key
                    )
                } == true
            object["verification"] = [
                "algorithm": algorithm ?? "unknown",
                "valid": isValid
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonObject(_ input: String) throws -> Any {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ParserTransformerError.invalidJSON
        }
        return object
    }

    private static func normalizedJSONValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(normalizedJSONValue)
        }
        if let array = value as? [Any] {
            return array.map(normalizedJSONValue)
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            return NSDecimalNumber(string: number.stringValue)
        }
        return value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLData(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private enum YAMLCodec {
    static func encode(json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ParserTransformerError.invalidJSON
        }
        return render(object, indent: 0)
    }

    static func decodeToJSON(_ yaml: String) throws -> String {
        let lines = yaml.components(separatedBy: .newlines).enumerated().compactMap(YAMLLine.init)
        guard !lines.isEmpty else { throw ParserTransformerError.emptyInput }
        var index = 0
        let object = try parseBlock(lines, index: &index, indent: lines[0].indent)
        guard index == lines.count else {
            throw ParserTransformerError.invalidYAML("第 \(lines[index].number) 行缩进不一致")
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ParserTransformerError.invalidYAML("根节点必须是对象或数组")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func render(_ value: Any, indent: Int) -> String {
        let padding = String(repeating: " ", count: indent)
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { key in
                let item = dictionary[key]!
                if isContainer(item) {
                    return "\(padding)\(quoteKey(key)):\n\(render(item, indent: indent + 2))"
                }
                return "\(padding)\(quoteKey(key)): \(scalar(item))"
            }.joined(separator: "\n")
        }
        if let array = value as? [Any] {
            return array.map { item in
                if isContainer(item) {
                    let nested = render(item, indent: indent + 2)
                    let prefix = String(repeating: " ", count: indent + 2)
                    let firstAdjusted = nested.hasPrefix(prefix)
                        ? String(nested.dropFirst(prefix.count))
                        : nested
                    return "\(padding)- \(firstAdjusted)"
                }
                return "\(padding)- \(scalar(item))"
            }.joined(separator: "\n")
        }
        return "\(padding)\(scalar(value))"
    }

    private static func parseBlock(_ lines: [YAMLLine], index: inout Int, indent: Int) throws -> Any {
        guard index < lines.count, lines[index].indent == indent else {
            throw ParserTransformerError.invalidYAML("缺少缩进内容")
        }
        return lines[index].content.hasPrefix("- ") || lines[index].content == "-"
            ? try parseArray(lines, index: &index, indent: indent)
            : try parseMapping(lines, index: &index, indent: indent)
    }

    private static func parseMapping(_ lines: [YAMLLine], index: inout Int, indent: Int) throws -> [String: Any] {
        var result: [String: Any] = [:]
        while index < lines.count, lines[index].indent == indent, !lines[index].content.hasPrefix("- ") {
            let line = lines[index]
            guard let colon = line.content.firstIndex(of: ":") else {
                throw ParserTransformerError.invalidYAML("第 \(line.number) 行缺少冒号")
            }
            let key = unquote(String(line.content[..<colon]).trimmingCharacters(in: .whitespaces))
            let remainder = String(line.content[line.content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1
            if remainder.isEmpty {
                guard index < lines.count, lines[index].indent > indent else {
                    result[key] = NSNull()
                    continue
                }
                result[key] = try parseBlock(lines, index: &index, indent: lines[index].indent)
            } else {
                result[key] = parseScalar(remainder)
            }
        }
        return result
    }

    private static func parseArray(_ lines: [YAMLLine], index: inout Int, indent: Int) throws -> [Any] {
        var result: [Any] = []
        while index < lines.count, lines[index].indent == indent {
            let line = lines[index]
            guard line.content == "-" || line.content.hasPrefix("- ") else { break }
            let remainder = String(line.content.dropFirst()).trimmingCharacters(in: .whitespaces)
            index += 1
            if remainder.isEmpty {
                guard index < lines.count, lines[index].indent > indent else {
                    result.append(NSNull())
                    continue
                }
                result.append(try parseBlock(lines, index: &index, indent: lines[index].indent))
            } else if let colon = remainder.firstIndex(of: ":") {
                let key = unquote(String(remainder[..<colon]).trimmingCharacters(in: .whitespaces))
                let valueText = String(remainder[remainder.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                var object: [String: Any] = [key: valueText.isEmpty ? NSNull() : parseScalar(valueText)]
                if index < lines.count, lines[index].indent > indent,
                   let nested = try parseBlock(lines, index: &index, indent: lines[index].indent) as? [String: Any] {
                    object.merge(nested) { current, _ in current }
                }
                result.append(object)
            } else {
                result.append(parseScalar(remainder))
            }
        }
        return result
    }

    private static func parseScalar(_ text: String) -> Any {
        let lower = text.lowercased()
        if lower == "null" || text == "~" { return NSNull() }
        if lower == "true" { return true }
        if lower == "false" { return false }
        if let integer = Int64(text) { return integer }
        if let double = Double(text) { return double }
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("{") && text.hasSuffix("}")),
           let data = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return value
        }
        return unquote(text)
    }

    private static func scalar(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        let string = String(describing: value)
        let safe = string.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil
            && !["null", "true", "false", "~"].contains(string.lowercased())
        if safe { return string }
        let data = try? JSONEncoder().encode(string)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\(string)\""
    }

    private static func isContainer(_ value: Any) -> Bool {
        value is [String: Any] || value is [Any]
    }

    private static func quoteKey(_ key: String) -> String {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
            ? key
            : scalar(key)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("\"") && text.hasSuffix("\""),
           let data = text.data(using: .utf8),
           let value = try? JSONDecoder().decode(String.self, from: data) {
            return value
        }
        if text.hasPrefix("'") && text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return text
    }
}

private struct YAMLLine {
    let number: Int
    let indent: Int
    let content: String

    init?(_ pair: (offset: Int, element: String)) {
        let raw = pair.element.replacingOccurrences(of: "\t", with: "  ")
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        number = pair.offset + 1
        indent = raw.prefix { $0 == " " }.count
        content = trimmed
    }

}

private enum JavaScriptTransformer {
    static func minify(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var quote: Character?
        var escaped = false
        var pendingSpace = false

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : nil

            if let activeQuote = quote {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = next
                continue
            }

            if character == "\"" || character == "'" || character == "`" {
                appendPendingSpace(&output, pending: &pendingSpace, before: character)
                quote = character
                output.append(character)
                index = next
                continue
            }
            if character == "/", nextCharacter == "/" {
                index = source.index(after: next)
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                pendingSpace = true
                continue
            }
            if character == "/", nextCharacter == "*" {
                index = source.index(after: next)
                while index < source.endIndex {
                    let after = source.index(after: index)
                    if source[index] == "*", after < source.endIndex, source[after] == "/" {
                        index = source.index(after: after)
                        break
                    }
                    index = after
                }
                pendingSpace = true
                continue
            }
            if character.isWhitespace {
                pendingSpace = true
                index = next
                continue
            }
            appendPendingSpace(&output, pending: &pendingSpace, before: character)
            output.append(character)
            index = next
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func format(_ source: String) -> String {
        let compact = minify(source)
        var output = ""
        var indent = 0
        var quote: Character?
        var escaped = false

        for character in compact {
            if let activeQuote = quote {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                output.append(character)
            } else if character == "{" {
                output.append(character)
                indent += 1
                newline(&output, indent: indent)
            } else if character == "}" {
                indent = max(0, indent - 1)
                trimTrailingSpace(&output)
                if !output.hasSuffix("\n") { newline(&output, indent: indent) }
                output.append(character)
            } else if character == ";" {
                output.append(character)
                newline(&output, indent: indent)
            } else if character == "," {
                output.append(character)
                if indent > 0 { newline(&output, indent: indent) } else { output.append(" ") }
            } else {
                output.append(character)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendPendingSpace(_ output: inout String, pending: inout Bool, before: Character) {
        defer { pending = false }
        guard pending, let last = output.last,
              (last.isLetter || last.isNumber || last == "_" || last == "$") &&
              (before.isLetter || before.isNumber || before == "_" || before == "$") else { return }
        output.append(" ")
    }

    private static func newline(_ output: inout String, indent: Int) {
        trimTrailingSpace(&output)
        output.append("\n")
        output.append(String(repeating: "  ", count: indent))
    }

    private static func trimTrailingSpace(_ output: inout String) {
        while output.last == " " { output.removeLast() }
    }
}
