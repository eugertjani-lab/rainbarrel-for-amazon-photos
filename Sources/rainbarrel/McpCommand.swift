import ArgumentParser
import Dispatch
import Foundation
import MCP
import RainbarrelCore

/// `rainbarrel mcp`: an MCP server over stdio. The tool logic lives in RainbarrelCore (`RainbarrelToolRegistry`);
/// this file only adapts it to the MCP SDK's types.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run an MCP server on stdin/stdout so assistants can query the sync state.",
        discussion: """
            Tools: sync_status, list_online_only, list_drive_only, breakdown_by_year, refresh_catalog, \
            scan_drive. Register it with an MCP client, for example: claude mcp add rainbarrel -- \
            /path/to/rainbarrel mcp
            """)

    func run() async throws {
        let registry = RainbarrelToolRegistry(tools: RainbarrelTools(paths: .forCLI()))
        let server = Server(
            name: RainbarrelInfo.serverName,
            version: RainbarrelInfo.version,
            instructions: """
                Rainbarrel compares an Amazon Photos account with a backup drive by MD5. Start with \
                sync_status. Use list_online_only and list_drive_only for details, refresh_catalog to \
                re-read the Amazon Photos app index, and scan_drive to index new files on the drive.
                """,
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: RainbarrelToolRegistry.definitions.map(Self.mcpTool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            let arguments = params.arguments.map { Self.jsonArguments($0) }
            let outcome = await Self.runOffTheCooperativePool {
                registry.call(name: params.name, arguments: arguments)
            }
            return .init(content: [.text(outcome.text)], isError: outcome.isError)
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    // MARK: Adapters

    static func mcpTool(_ definition: ToolDefinition) -> Tool {
        Tool(
            name: definition.name,
            description: definition.description,
            inputSchema: (try? convert(definition.inputSchema, to: Value.self)) ?? .object([:]),
            annotations: .init(readOnlyHint: definition.readOnly, openWorldHint: false))
    }

    static func jsonArguments(_ arguments: [String: Value]) -> [String: JSONValue] {
        arguments.compactMapValues { try? convert($0, to: JSONValue.self) }
    }

    private static func convert<From: Encodable, To: Decodable>(_ value: From, to: To.Type) throws -> To {
        try JSONDecoder().decode(To.self, from: JSONEncoder().encode(value))
    }

    /// Tool work is blocking (file and database I/O, hashing); keep it off Swift's cooperative threads.
    private static func runOffTheCooperativePool(
        _ work: @escaping @Sendable () -> ToolCallOutcome
    ) async -> ToolCallOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
