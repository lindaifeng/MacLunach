import Foundation
import Testing
@testable import FileActionServiceProtocol

@Test func fileActionPingReturnsVersionedProcessIdentityAndTimestamp() {
    let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
    let processor = FileActionServiceRequestProcessor(
        processID: 42,
        now: { timestamp }
    )
    let request = FileActionServiceRequest(action: .ping)

    let response = processor.process(request)

    #expect(response.protocolVersion == FileActionServiceProtocolVersion.current)
    #expect(response.requestID == request.id)
    guard case let .pong(pong) = response.payload else {
        Issue.record("ping 应返回 pong")
        return
    }
    #expect(pong.processID == 42)
    #expect(pong.timestamp == timestamp)
}

@Test func fileActionServiceRejectsIncompatibleProtocolBeforeDispatch() {
    let receivedVersion = FileActionServiceProtocolVersion.current + 1
    let request = FileActionServiceRequest(
        protocolVersion: receivedVersion,
        action: .ping
    )

    let response = FileActionServiceRequestProcessor().process(request)

    #expect(response.requestID == request.id)
    #expect(response.payload == .failure(.incompatibleProtocol(
        expected: FileActionServiceProtocolVersion.current,
        received: receivedVersion
    )))
}

@Test func malformedFileActionRequestProducesFailureInsteadOfThrowing() throws {
    let responseData = FileActionServiceRequestProcessor().process(Data("not-json".utf8))
    let response = try JSONDecoder().decode(FileActionServiceResponse.self, from: responseData)

    #expect(response.requestID == nil)
    guard case .failure(.malformedRequest) = response.payload else {
        Issue.record("损坏请求应返回 malformedRequest")
        return
    }
}

@Test func fileActionXPCInterfaceAllowsOnlyDataEnvelopes() {
    #expect(FileActionServiceXPCInterface.allowedSecureCodingClassNames == ["NSData"])
}

@Test func moveResultDecodesLegacyPayloadWithoutFailedItems() throws {
    let source = URL(fileURLWithPath: "/tmp/source.txt")
    let legacyData = Data("""
    {"movedItems":[{"sourceURL":"file:///tmp/source.txt","destinationURL":"file:///tmp/destination.txt"}],"skippedSourceURLs":[],"conflicts":[]}
    """.utf8)

    let result = try JSONDecoder().decode(FileActionServiceMoveResult.self, from: legacyData)

    #expect(result.movedItems.map(\.sourceURL) == [source])
    #expect(result.failedItems.isEmpty)
}
