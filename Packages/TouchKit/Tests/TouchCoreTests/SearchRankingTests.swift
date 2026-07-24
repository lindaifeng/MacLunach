import Testing
@testable import TouchCore

@Test func exactAndPrefixMatchesPrecedeFuzzyMatches() {
    let results = [
        SearchResult(title: "Finder", pinyin: "finder", initials: "fd", kind: .application),
        SearchResult(title: "Find My", pinyin: "find my", initials: "fm", kind: .application),
        SearchResult(title: "Calendar", pinyin: "calendar", initials: "cl", kind: .application)
    ]

    #expect(SearchRanking.sort(results, query: "finder").map(\.title) == ["Finder"])
}

@Test func pinyinInitialsAreSearchable() {
    let finder = SearchResult(title: "访达", pinyin: "fang da", initials: "fd", kind: .application)

    #expect(SearchRanking.score(finder, query: "fd") > 0)
}

@Test func subsequenceMatchesRankBelowPrefixMatches() {
    let fuzzy = SearchResult(title: "Fast Index Navigator", pinyin: "", initials: "", kind: .application)

    #expect(SearchRanking.score(fuzzy, query: "fin") > 0)
    #expect(SearchRanking.score(fuzzy, query: "fin") < SearchRanking.score(
        SearchResult(title: "Finder", pinyin: "", initials: "", kind: .application),
        query: "fin"
    ))
}

@Test func strictSearchTermsRequireContiguousMatches() {
    let webAction = SearchResult(
        title: "百度",
        pinyin: "网页",
        strictSearchTerms: ["https://www.baidu.com/"],
        kind: .action
    )

    #expect(SearchRanking.score(webAction, query: "baidu") > 0)
    #expect(SearchRanking.score(webAction, query: "do") == 0)
}
