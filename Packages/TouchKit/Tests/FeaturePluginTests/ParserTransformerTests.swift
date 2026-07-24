import Foundation
import Testing
@testable import ParserToolsFeature

@Test func jsonCanBeFormattedMinifiedEscapedAndUnescaped() throws {
    let source = #"{"name":"一念","enabled":true}"#
    let formatted = try ParserTransformer.transform(source, tool: .json, operation: .format)
    #expect(formatted.contains("\n"))
    let minified = try ParserTransformer.transform(formatted, tool: .json, operation: .minify)
    let sourceObject = try #require(
        JSONSerialization.jsonObject(with: Data(source.utf8)) as? NSDictionary
    )
    let minifiedObject = try #require(
        JSONSerialization.jsonObject(with: Data(minified.utf8)) as? NSDictionary
    )
    #expect(sourceObject == minifiedObject)

    let escaped = try ParserTransformer.transform(source, tool: .json, operation: .escape)
    #expect(try ParserTransformer.transform(escaped, tool: .json, operation: .unescape) == source)
}

@Test func jsonFormattingDoesNotExposeBinaryFloatingPointTails() throws {
    let formatted = try ParserTransformer.transform(
        #"{"rating":4.9,"price":6999.00}"#,
        tool: .json,
        operation: .format
    )
    #expect(formatted.contains("4.9"))
    #expect(!formatted.contains("4.9000000000000004"))
}

@Test func jsonMinificationPreservesKeysNumbersAndStringWhitespaceExactly() throws {
    let source = """
    {
      "account": 90071992547409931234567890,
      "amount": 6999.00,
      "label": "保留 两个 空格",
      "duplicate": 1,
      "duplicate": 2
    }
    """

    let minified = try ParserTransformer.transform(source, tool: .json, operation: .minify)

    #expect(
        minified
            == #"{"account":90071992547409931234567890,"amount":6999.00,"label":"保留 两个 空格","duplicate":1,"duplicate":2}"#
    )
}

@Test func base64RoundTripsUnicodeText() throws {
    let source = "一念 · Touch"
    let encoded = try ParserTransformer.transform(source, tool: .base64, operation: .encode)
    #expect(try ParserTransformer.transform(encoded, tool: .base64, operation: .decode) == source)
}

@Test func jwtHS256CanBeSignedAndDecoded() throws {
    let token = try ParserTransformer.transform(
        #"{"sub":"touch-user","admin":false}"#,
        tool: .jwt,
        operation: .signHS256,
        secret: "local-secret"
    )
    #expect(token.split(separator: ".").count == 3)
    let decoded = try ParserTransformer.transform(token, tool: .jwt, operation: .decodeJWT)
    #expect(decoded.contains("touch-user"))
    #expect(decoded.contains("HS256"))

    let verified = try ParserTransformer.transform(
        token,
        tool: .jwt,
        operation: .decodeJWT,
        secret: "local-secret"
    )
    #expect(verified.contains(#""valid" : true"#))

    let rejected = try ParserTransformer.transform(
        token,
        tool: .jwt,
        operation: .decodeJWT,
        secret: "wrong-secret"
    )
    #expect(rejected.contains(#""valid" : false"#))
}

@Test func jsonAndYAMLRoundTripNestedContent() throws {
    let json = #"{"name":"Touch","items":[{"id":1,"ready":true},{"id":2,"ready":false}]}"#
    let yaml = try ParserTransformer.transform(json, tool: .jsonToYAML, operation: .convert)
    #expect(yaml.contains("items:"))
    #expect(yaml.contains("- id: 1"))

    let restored = try ParserTransformer.transform(yaml, tool: .yamlToJSON, operation: .convert)
    let data = try #require(restored.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["name"] as? String == "Touch")
    #expect((object["items"] as? [Any])?.count == 2)
}

@Test func javascriptFormatterPreservesStringsAndMinifierRemovesComments() throws {
    let source = "const value = { name: \"a b\" }; // note\nconsole.log(value);"
    let minified = try ParserTransformer.transform(source, tool: .javascript, operation: .minify)
    #expect(minified.contains("\"a b\""))
    #expect(!minified.contains("note"))
    let formatted = try ParserTransformer.transform(minified, tool: .javascript, operation: .format)
    #expect(formatted.contains("\n"))
}
