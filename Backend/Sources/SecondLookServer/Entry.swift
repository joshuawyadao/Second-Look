import Vapor
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
struct Entry {
    static func main() async throws {
        let config: ServerConfiguration
        do { config = try ServerConfiguration() }
        catch {
            FileHandle.standardError.write(Data("Invalid Second Look server configuration. See docs/Backend-Operations.md.\n".utf8))
            exit(78)
        }
        let app = try await Application.make(.detect())
        do {
            try configure(app, configuration: config)
            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}
