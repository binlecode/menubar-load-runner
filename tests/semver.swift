// SemVer + update-tag parse check — mirrors MenuBarLoadRunner.swift `SemVer` and
// `UpdateChecker.highestTag(inLsRemoteOutput:)`. Asserts the strict 3-component parse (rejecting
// pre-release / short / non-numeric tags), numeric (not lexical) ordering, and that the highest
// release tag is picked out of canned `git ls-remote` output — all with NO network. Keep in sync with
// the real types; a mismatch = the port drifted. Exits 0 if all checks pass, 1 otherwise.
// Run:  swiftc tests/semver.swift -o tmp/semver && ./tmp/semver
import Foundation

struct SemVer: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            nums.append(n)
        }
        (major, minor, patch) = (nums[0], nums[1], nums[2])
    }
    static func < (l: SemVer, r: SemVer) -> Bool { (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch) }
    var description: String { "\(major).\(minor).\(patch)" }
    var tagString: String { "v\(description)" }
}

func highestTag(inLsRemoteOutput text: String) -> SemVer? {
    text.split(whereSeparator: \.isNewline).compactMap { line -> SemVer? in
        guard let range = line.range(of: "refs/tags/", options: .backwards) else { return nil }
        return SemVer(String(line[range.upperBound...]))
    }.max()
}

func pullArguments(upstreamConfigured: Bool, branch: String?) -> [String] {
    let base = ["pull", "--ff-only"]
    guard !upstreamConfigured, let branch, !branch.isEmpty else { return base }
    return base + ["origin", branch]
}

var pass = 0, fail = 0
func check(_ n: String, _ c: Bool) { c ? (pass += 1) : (fail += 1); print("  \(c ? "PASS" : "FAIL") [\(n)]") }

// Accept forms
check("accepts 1.6.0", SemVer("1.6.0") != nil)
check("accepts v1.6.0", SemVer("v1.6.0") != nil)
check("accepts v1.10.2", SemVer("v1.10.2") != nil)
// Reject forms
check("rejects pre-release", SemVer("1.2.3-rc1") == nil)
check("rejects two components", SemVer("1.6") == nil)
check("rejects four components", SemVer("v1.6.0.1") == nil)
check("rejects non-numeric", SemVer("1.a.0") == nil)
check("rejects signed", SemVer("+1.2.3") == nil)
check("rejects empty", SemVer("") == nil)
check("rejects embedded space", SemVer("v1. 2.3") == nil)
// Ordering is numeric, not lexical (10 > 9)
check("v1.10.0 > v1.9.0 (numeric)", SemVer("v1.10.0")! > SemVer("v1.9.0")!)
check("equal versions not <", !(SemVer("1.6.0")! < SemVer("1.6.0")!))

// Canned ls-remote output (annotated-tag ^{} peel lines are stripped by --refs, so not present here).
let out = """
abc123\trefs/tags/v1.5.1
def456\trefs/tags/v1.6.0
0f00ba\trefs/tags/v1.4.0
99xyz9\trefs/tags/not-a-version
"""
check("highest tag = v1.6.0", highestTag(inLsRemoteOutput: out)?.tagString == "v1.6.0")
check("no tags -> nil", highestTag(inLsRemoteOutput: "abc\trefs/heads/main") == nil)

// Pull refspec: bare when tracking exists, explicit `origin <branch>` when it doesn't (a copied
// checkout has no branch.<name>.remote, and bare pull would dead-end on "no tracking information"),
// bare again on detached HEAD so git's own "not currently on a branch" is what surfaces.
check("tracked -> bare pull", pullArguments(upstreamConfigured: true, branch: "main") == ["pull", "--ff-only"])
check("untracked -> explicit origin main",
      pullArguments(upstreamConfigured: false, branch: "main") == ["pull", "--ff-only", "origin", "main"])
check("untracked non-main branch names itself",
      pullArguments(upstreamConfigured: false, branch: "feat/x") == ["pull", "--ff-only", "origin", "feat/x"])
check("detached HEAD -> bare pull", pullArguments(upstreamConfigured: false, branch: nil) == ["pull", "--ff-only"])
check("empty branch -> bare pull", pullArguments(upstreamConfigured: false, branch: "") == ["pull", "--ff-only"])

print("semver: passes=\(pass) fails=\(fail)"); exit(fail == 0 ? 0 : 1)
