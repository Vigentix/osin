import Foundation
import Testing
@testable import OsinCore

private func object(_ data: Data?) -> [String: Any] {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}

private func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])) ?? Data()
}

/// Calls a tool and returns its JSON payload (the text content) and whether it was an error.
private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) -> (payload: [String: Any], isError: Bool) {
    let response = object(server.handle(request(9, "tools/call", ["name": name, "arguments": arguments])))
    let result = response["result"] as? [String: Any] ?? [:]
    let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "{}"
    return (object(Data(text.utf8)), result["isError"] as? Bool ?? false)
}

struct MCPProtocolTests {
    @Test func initializeAnswersWithToolsCapability() throws {
        let fixture = try FixtureHome()
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        let response = object(server.handle(request(
            1,
            "initialize",
            ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test"]]
        )))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(((result["serverInfo"] as? [String: Any])?["name"] as? String) == "osin")
    }

    @Test func notificationsGetNoAnswer() throws {
        let fixture = try FixtureHome()
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        let note = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(server.handle(note) == nil)
    }

    @Test func listsOnlyReadAndProposeTools() throws {
        let fixture = try FixtureHome()
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        let result = object(server.handle(request(2, "tools/list")))["result"] as? [String: Any]
        let names = Set(((result?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        #expect(names == ["get_overview", "list_folder", "describe_folder", "smart_scan", "docker_usage", "propose_cleanup"])
    }

    @Test func unknownMethodsAndBadInputAreErrors() throws {
        let fixture = try FixtureHome()
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        let unknown = object(server.handle(request(3, "resources/read")))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = object(server.handle(Data("not json".utf8)))
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
        let code = { (text: String) in (object(server.handle(Data(text.utf8)))["error"] as? [String: Any])?["code"] as? Int }
        #expect(code(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#) == -32600)
        #expect(code(#"{"jsonrpc":"2.0","id":{},"method":"ping"}"#) == -32600)
        #expect(code(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#) == -32600)
        #expect(code("{}") == -32600)
        #expect(code("[1]") == -32600)
        #expect(code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1]}"#) == -32602)
        #expect(code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_overview","arguments":"x"}}"#) == -32602)
    }
}

struct AIToolTests {
    @Test func listFolderShowsSizesAndRefusesOutsideHome() throws {
        let fixture = try FixtureHome()
        try fixture.file(".cache/uv/wheels/a.whl", bytes: 3_000_000)
        try fixture.file(".cache/pip/b", bytes: 1_000_000)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        let listed = call(server, "list_folder", ["path": "~/.cache"])
        #expect(!listed.isError)
        let entries = listed.payload["entries"] as? [[String: Any]] ?? []
        #expect(entries.first?["name"] as? String == "uv")
        #expect((entries.first?["advice"] as? String) == "safe")
        #expect(call(server, "list_folder", ["path": "/etc"]).isError)
        #expect(call(server, "list_folder", ["path": "~/../.."]).isError)
    }

    @Test func protectedFoldersAreNotListed() throws {
        let fixture = try FixtureHome()
        try fixture.file("Documents/tax.pdf")
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        #expect(call(server, "list_folder", ["path": "~/Documents"]).isError)
    }

    @Test func describeFolderSaysWhatItIsAndWhetherItCanGo() throws {
        let fixture = try FixtureHome()
        try fixture.directory(".ssh")
        try fixture.directory(".cache/uv")
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        let ssh = call(server, "describe_folder", ["path": "~/.ssh"]).payload
        #expect(ssh["can_move_to_trash"] as? Bool == false)
        let uvCache = call(server, "describe_folder", ["path": "~/.cache/uv"]).payload
        #expect(uvCache["can_move_to_trash"] as? Bool == true)
        #expect(uvCache["advice"] as? String == "safe")
    }

    @Test func proposalsKeepOnlyWhatIsSafeAndRecordReasons() throws {
        let fixture = try FixtureHome()
        try fixture.file(".cache/uv/wheels/a.whl", bytes: 2_000_000)
        try fixture.file("Documents/tax.pdf")
        try fixture.file(".ssh/id_ed25519")
        let store = ProposalStore(folder: fixture.root)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: store, runID: "run-1", source: "claude"))
        let answer = call(server, "propose_cleanup", [
            "summary": "Caches you can rebuild.",
            "items": [
                ["path": "~/.cache/uv", "reason": "uv downloads it again"],
                ["path": "~/Documents/tax.pdf", "reason": "old"],
                ["path": "~/.ssh", "reason": "unused"],
                ["path": "~/nothing-here", "reason": "?"]
            ]
        ])
        #expect(!answer.isError)
        #expect((answer.payload["accepted"] as? [[String: Any]])?.count == 1)
        #expect((answer.payload["rejected"] as? [[String: Any]])?.count == 3)
        let proposal = try #require(try store.load(id: "run-1"))
        #expect(proposal.items.map(\.path) == [fixture.home.resolvingSymlinksInPath().appendingPathComponent(".cache/uv").path])
        #expect(proposal.items.first?.reason == "uv downloads it again")
        #expect(proposal.items.first?.identity != nil)
        #expect((proposal.items.first?.bytes ?? 0) >= 2_000_000)
        #expect(proposal.summary == "Caches you can rebuild.")
        #expect(proposal.source == "claude")
    }

    /// APFS is usually case-insensitive: `~/documents` must not slip past checks for `~/Documents`.
    @Test func differentlyCasedPathsAreRefused() throws {
        let fixture = try FixtureHome()
        try fixture.file("Documents/tax.pdf")
        try fixture.file(".cache/uv/a", bytes: 10000)
        let store = ProposalStore(folder: fixture.root)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: store, runID: "case", source: "claude"))
        #expect(call(server, "list_folder", ["path": "~/documents"]).isError)
        #expect(call(server, "describe_folder", ["path": "~/DOCUMENTS/tax.pdf"]).payload["can_move_to_trash"] as? Bool == false)
        #expect(call(server, "describe_folder", ["path": "~/.Cache/uv"]).isError)
        let answer = call(server, "propose_cleanup", [
            "summary": "s", "items": [["path": "~/documents/tax.pdf", "reason": "old"]]
        ])
        #expect((answer.payload["accepted"] as? [[String: Any]])?.isEmpty ?? true)
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ProtectedPaths(home: home).denies(home.appendingPathComponent("documents/tax.pdf")))
        #expect(ProtectedPaths(home: home).denies(home.appendingPathComponent(".SSH")))
    }

    @Test func libraryCanBeListedButNotItsPrivatePlaces() throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/app/a", bytes: 2_000_000)
        try fixture.file("Library/Mail/V10/mail.emlx", bytes: 2_000_000)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: ProposalStore(folder: fixture.root)))
        #expect(!call(server, "list_folder", ["path": "~/Library"]).isError)
        #expect(call(server, "list_folder", ["path": "~/Library/Mail"]).isError)
        #expect(call(server, "list_folder", ["path": "~/library/mail"]).isError)
        let home = call(server, "describe_folder", ["path": "~"]).payload
        #expect(home["can_move_to_trash"] as? Bool == false)
    }

    @Test func proposalsStopAtTheLimitAcrossCalls() throws {
        let fixture = try FixtureHome()
        for index in 0 ..< 3 {
            try fixture.file(".cache/tool\(index)/a", bytes: 1000)
        }
        let store = ProposalStore(folder: fixture.root)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: store, runID: "limit", source: "claude", maxItems: 2))
        let item = { (index: Int) in ["path": "~/.cache/tool\(index)", "reason": "r"] }
        let first = call(server, "propose_cleanup", ["summary": "s", "items": [item(0), item(1)]])
        #expect((first.payload["accepted"] as? [[String: Any]])?.count == 2)
        let second = call(server, "propose_cleanup", ["summary": "s", "items": [item(2)]])
        #expect((second.payload["rejected"] as? [[String: Any]])?.count == 1)
        #expect(try store.load(id: "limit")?.items.count == 2)
    }

    @Test func externalSessionsKeepOneProposal() throws {
        let fixture = try FixtureHome()
        try fixture.file(".cache/one/a", bytes: 1000)
        try fixture.file(".cache/two/a", bytes: 1000)
        let store = ProposalStore(folder: fixture.root)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: store))
        _ = call(server, "propose_cleanup", ["summary": "s", "items": [["path": "~/.cache/one", "reason": "r"]]])
        _ = call(server, "propose_cleanup", ["summary": "s", "items": [["path": "~/.cache/two", "reason": "r"]]])
        #expect(store.all().count == 1)
        #expect(store.all().first?.items.count == 2)
    }

    @Test func laterProposalsInTheSameRunAddUp() throws {
        let fixture = try FixtureHome()
        try fixture.file(".cache/uv/a", bytes: 10000)
        try fixture.file(".cache/pip/b", bytes: 10000)
        let store = ProposalStore(folder: fixture.root)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: store, runID: "run-2", source: "codex"))
        _ = call(server, "propose_cleanup", ["summary": "one", "items": [["path": "~/.cache/uv", "reason": "a"]]])
        _ = call(
            server,
            "propose_cleanup",
            ["summary": "two", "items": [["path": "~/.cache/pip", "reason": "b"], ["path": "~/.cache/uv", "reason": "again"]]]
        )
        let proposal = try #require(try store.load(id: "run-2"))
        #expect(proposal.items.count == 2)
        #expect(proposal.summary == "two")
    }

    @Test func nestedProposalsAreNotDoubleCounted() throws {
        let fixture = try FixtureHome()
        try fixture.file(".cache/uv/wheels/a", bytes: 10000)
        let store = ProposalStore(folder: fixture.root)
        let server = MCPServer(tools: AITools(home: fixture.home, proposals: store, runID: "run-3", source: "claude"))
        let answer = call(server, "propose_cleanup", ["summary": "s", "items": [
            ["path": "~/.cache/uv", "reason": "a"], ["path": "~/.cache/uv/wheels", "reason": "inside"]
        ]])
        #expect((answer.payload["accepted"] as? [[String: Any]])?.count == 1)
    }
}
