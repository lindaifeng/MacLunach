import Foundation
import TouchCore

private enum Benchmark {
    static let recordCount = 1_000_000
    static let batchSize = 10_000
    static let resultLimit = 80
    static let warmupCount = 10
    static let measurementCount = 100
    static let rootPath = "/tmp/touch-search-benchmark/root"

    static func fileName(for index: Int) -> String {
        switch index % 10_000 {
        case 0:
            return String(format: "design-specification-%07d.md", index)
        case 1:
            return String(format: "fd-report-%07d.txt", index)
        default:
            return String(format: "document-%07d.data", index)
        }
    }
}

@main
struct SearchBenchmark {
    static func main() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("TouchSearchBenchmark-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = try FileIndexStore(databaseURL: directory.appendingPathComponent("file-index.sqlite"))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        for start in stride(from: 0, to: Benchmark.recordCount, by: Benchmark.batchSize) {
            let end = min(start + Benchmark.batchSize, Benchmark.recordCount)
            let records = (start..<end).map { index in
                let fileName = Benchmark.fileName(for: index)
                return FileIndexRecord(
                    path: "\(Benchmark.rootPath)/\(fileName)",
                    rootPath: Benchmark.rootPath,
                    contentType: "public.data",
                    size: Int64(index),
                    createdAt: fixedDate,
                    modifiedAt: fixedDate,
                    isDirectory: false
                )
            }
            try await store.upsert(records)
        }

        let insertedCount = try await store.recordCount()
        guard insertedCount == Benchmark.recordCount else {
            throw BenchmarkError.unexpectedRecordCount(insertedCount)
        }
        print("SearchBenchmark records \(insertedCount) limit \(Benchmark.resultLimit)")

        for query in ["design", "fd"] {
            for _ in 0..<Benchmark.warmupCount {
                _ = try await store.search(query, limit: Benchmark.resultLimit)
            }

            var samples: [Double] = []
            samples.reserveCapacity(Benchmark.measurementCount)
            for _ in 0..<Benchmark.measurementCount {
                let start = DispatchTime.now().uptimeNanoseconds
                let results = try await store.search(query, limit: Benchmark.resultLimit)
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                guard results.count == Benchmark.resultLimit else {
                    throw BenchmarkError.unexpectedResultCount(query: query, count: results.count)
                }
                samples.append(Double(elapsed) / 1_000_000)
            }

            samples.sort()
            let p50 = percentile(0.50, samples: samples)
            let p95 = percentile(0.95, samples: samples)
            print(String(format: "SearchBenchmark query=%@ samples=%d p50_ms=%.3f p95_ms=%.3f", query, samples.count, p50, p95))
        }

        try await store.close()
    }

    private static func percentile(_ percentile: Double, samples: [Double]) -> Double {
        let index = max(0, min(samples.count - 1, Int(ceil(percentile * Double(samples.count))) - 1))
        return samples[index]
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case unexpectedRecordCount(Int)
    case unexpectedResultCount(query: String, count: Int)

    var description: String {
        switch self {
        case let .unexpectedRecordCount(count):
            return "expected \(Benchmark.recordCount) records, got \(count)"
        case let .unexpectedResultCount(query, count):
            return "expected \(Benchmark.resultLimit) results for \(query), got \(count)"
        }
    }
}
