import Testing
@testable import TouchCore

@Test func coalescesSiblingEventsToTheirContainingDirectory() {
    #expect(FileEventMonitor.coalescedRoots([
        "/work/project/one.swift",
        "/work/project/two.swift",
        "/work/other/readme.md"
    ]) == ["/work/other", "/work/project"])
}

@Test func dropsDescendantRescanWhenAncestorAlreadyScheduled() {
    #expect(FileEventMonitor.coalescedRoots([
        "/work/project",
        "/work/project/sub/file.txt"
    ]) == ["/work"])
}
