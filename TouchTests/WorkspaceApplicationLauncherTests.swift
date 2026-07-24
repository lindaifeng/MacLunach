import AppKit
import XCTest
@testable import 触达

final class WorkspaceApplicationLauncherTests: XCTestCase {
    func testCompletionHandlerReportsFailureWhenLaunchServicesReturnsNoApplication() async {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completionHandler = WorkspaceApplicationLauncher.makeCompletionHandler(for: continuation)

                DispatchQueue.global().async {
                    completionHandler(nil, nil)
                }
            }
            XCTFail("没有应用对象的启动回调不能被当作成功")
        } catch {
            // 完成回调在后台队列调用时仍必须恢复 continuation，并提供可诊断的失败。
        }
    }
}
