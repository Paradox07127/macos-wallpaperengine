@testable import LiveWallpaper
import Metal
import Testing

@Suite("WPE Metal bootstrap initialization token")
struct WPEMetalBootstrapInitializationTests {
    /// Never committed: the token only compares identities and its own state.
    private static func commandBuffers(_ count: Int) throws -> [MTLCommandBuffer] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        return try (0 ..< count).map { _ in try #require(queue.makeCommandBuffer()) }
    }

    @Test("Encoded clear is readable by its own command buffer only")
    func encodedReadableByOwnerOnly() throws {
        let buffers = try Self.commandBuffers(2)
        let token = WPEMetalBootstrapInitialization(commandBuffer: buffers[0])

        #expect(token.canRead(in: buffers[0]))
        #expect(!token.canRead(in: buffers[1]))
    }

    @Test("Successful completion publishes the clear to every command buffer")
    func successPublishesToAllBuffers() throws {
        let buffers = try Self.commandBuffers(2)
        let token = WPEMetalBootstrapInitialization(commandBuffer: buffers[0])

        token.complete(succeeded: true)

        #expect(token.canRead(in: buffers[0]))
        #expect(token.canRead(in: buffers[1]))
    }

    @Test("Failed completion revokes reads for the owner as well")
    func failureRevokesAllReads() throws {
        let buffers = try Self.commandBuffers(2)
        let token = WPEMetalBootstrapInitialization(commandBuffer: buffers[0])

        token.complete(succeeded: false)

        #expect(!token.canRead(in: buffers[0]))
        #expect(!token.canRead(in: buffers[1]))
    }

    @Test("An older token's failure leaves a newer token's success intact")
    func tokensAreIndependent() throws {
        let buffers = try Self.commandBuffers(3)
        let older = WPEMetalBootstrapInitialization(commandBuffer: buffers[0])
        let newer = WPEMetalBootstrapInitialization(commandBuffer: buffers[1])

        newer.complete(succeeded: true)
        older.complete(succeeded: false)

        #expect(newer.canRead(in: buffers[2]))
        #expect(!older.canRead(in: buffers[2]))
        #expect(!older.canRead(in: buffers[0]))
    }

    @Test("belongs(to:) recognizes only the owning command buffer, in every state")
    func belongsToOwnerOnly() throws {
        let buffers = try Self.commandBuffers(2)
        let token = WPEMetalBootstrapInitialization(commandBuffer: buffers[0])

        #expect(token.belongs(to: buffers[0]))
        #expect(!token.belongs(to: buffers[1]))
        token.complete(succeeded: false)
        #expect(token.belongs(to: buffers[0]))
        #expect(!token.belongs(to: buffers[1]))
    }
}
