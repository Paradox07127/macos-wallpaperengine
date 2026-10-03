#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import os
import Testing

@Suite("Shader translation input bounds")
struct WPEShaderTranslationBoundsTests {
    private static let fragment = "varying vec2 v_TexCoord; void main(){gl_FragColor=vec4(v_TexCoord,0.0,1.0);}"

    @Test("Authored vertex rejects a texture slot whose count would overflow")
    func authoredVertexRejectsOverflowingTextureSlot() throws {
        let vertex = """
        attribute vec3 a_Position;
        uniform sampler2D g_Texture9223372036854775807;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        let fragment = "void main(){gl_FragColor=vec4(1.0);}"
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(throws: WPEShaderCompilerError.self) {
            try WPEShaderTranspiler.translateAuthoredVertex(shaderName: "overflow", preprocessedSource: vertex, link: link)
        }
    }

    @Test("Local-effect position proof still admits a short shared macro chain")
    func shortMacroChainStillProven() {
        let macros = (1 ... 3).map { "#define M\($0) (M\($0 + 1)+1.0+M\($0 + 1)+1.0)" } + ["#define M4 1.0"]
        #expect(Self.prove(macros, timeout: 1) == true)
    }

    @Test("Exponentially shared macro chain returns a conservative result promptly", .timeLimit(.minutes(1)))
    func exponentialMacroChainReturnsPromptly() {
        let macros = (1 ... 39).map { "#define M\($0) (M\($0 + 1)+1.0+M\($0 + 1)+1.0)" } + ["#define M40 1.0"]
        #expect(Self.prove(macros, timeout: 1) == false)
    }

    @Test("Deep macro chain does not exhaust a 512KB worker stack", .timeLimit(.minutes(1)))
    func deepMacroChainDoesNotOverflowWorkerStack() {
        let macros = (1 ... 4999).map { "#define M\($0) (M\($0 + 1)+1.0)" } + ["#define M5000 1.0"]
        #expect(Self.prove(macros, timeout: 5) == false)
    }

    /// nil = the proof did not finish within `timeout`.
    private static func prove(_ macros: [String], timeout: TimeInterval) -> Bool? {
        let vertex = macros.joined(separator: "\n") + """

        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() {
            vec3 position = a_Position;
            position.xy += vec2(M1, M1);
            gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let fragment = Self.fragment
        let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            let proven = WPEShaderStageLink.usesMVPOnlyForLocalEffectPosition(vertex, fragment: fragment)
            outcome.withLock { $0 = proven }
            done.signal()
        }
        worker.stackSize = 512 * 1024
        worker.qualityOfService = .userInitiated
        worker.start()
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return outcome.withLock { $0 }
    }
}
#endif
