#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit
import os

extension WPEMetalSceneRenderer {
    struct FrameContext {
        let uniforms: WPEMetalRuntimeUniforms
        let pointer: SIMD2<Double>
        let followPointerIsLive: Bool
        let layerScriptPointerFrame: WPEPointerFrame
        let parallaxFrame: WPECameraParallaxFrame
    }

    /// The pointer arrives normalised to the drawable, but every consumer below works in
    /// scene space, which present crops (`cover`) or insets (`contain`/`center`) whenever
    /// the aspect ratios differ. Identity when they match, so 16:9 displays are unchanged.
    private func scenePointer(fromDrawable pointer: SIMD2<Double>) -> SIMD2<Double> {
        let present = WPEPresentUniforms.make(
            fitMode: presentFitMode,
            sourceWidth: Int(sceneRenderSize.width),
            sourceHeight: Int(sceneRenderSize.height),
            targetWidth: Int(surfaceDrawableSize.width),
            targetHeight: Int(surfaceDrawableSize.height)
        )
        // A pointer on a letterbox margin is outside the scene; the neutral centre is what
        // this frame already uses to mean "no live pointer".
        return present.scenePointer(fromDrawablePointer: pointer) ?? SIMD2<Double>(0.5, 0.5)
    }

    func sampleFrameContext(inputs: WPEFrameInputs) -> FrameContext {
        // Click capture stays independent because Interaction can be enabled without Follow Cursor. The snapshot always sampled the pointer, so an inactive gate discards it.
        let pointerSample = (mouseInteractionEnabled || inputs.clickCaptureEnabled)
            ? inputs.pointerSample
            : .inactive
        let pointerIsInsideView = pointerSample.isInsideView
        let followPointerIsLive = mouseInteractionEnabled && pointerIsInsideView
        let clickPointerIsLive = inputs.clickCaptureEnabled && pointerIsInsideView
        // Oracle overrides are authored in scene space already; a live pointer is
        // normalised to the drawable and has to be mapped across.
        let pointer = oracleFrameOverride?.pointer ?? scenePointer(
            fromDrawable: followPointerIsLive ? pointerSample.position : SIMD2<Double>(0.5, 0.5)
        )
        if !followPointerIsLive && previousPointerWasLive {
            for system in particleSystems where system.tracksPointer {
                system.clearLiveParticles()
            }
        }
        previousPointerWasLive = followPointerIsLive
        var uniforms = frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: pointer
        )
        if let override = oracleFrameOverride {
            uniforms = WPEMetalRuntimeUniforms(
                time: override.time,
                daytime: override.daytime,
                brightness: uniforms.brightness,
                pointerPosition: uniforms.pointerPosition
            )
        }
        // Compute once per frame (advances smoothing state); assigned below
        // after the audio path may have rebuilt `uniforms`.
        let parallaxFrame = cameraParallaxSmoother.frame(
            settings: cameraParallaxSettings,
            pointerPosition: pointer,
            time: uniforms.time,
            gain: cameraParallaxGain
        )
        // Audio-reactive uniforms follow the shared system-audio capture, not the scene's own sounds. When capture is off the broker is silent (flat bars).
        if SystemAudioCaptureManager.isCapturing, oracleFrameOverride == nil {
            let audio = SystemAudioCaptureManager.broker.snapshot()
            if audioDebugLogEnabled {
                audioDiagCounter += 1
                if audioDiagCounter % 60 == 1 {
                    let peakL = audio.left.max() ?? 0
                    let peakR = audio.right.max() ?? 0
                    Logger.notice(
                        "[AudioCapture] renderer: capturing=true peakL=\(String(format: "%.3f", peakL)) peakR=\(String(format: "%.3f", peakR)) fps=\(inputs.preferredFramesPerSecond) → feeding g_AudioSpectrum*",
                        category: .audioCapture
                    )
                }
            }
            uniforms = WPEMetalRuntimeUniforms(
                time: uniforms.time,
                daytime: uniforms.daytime,
                brightness: uniforms.brightness,
                pointerPosition: uniforms.pointerPosition,
                audioSpectrumLeft: audio.left.map(Double.init),
                audioSpectrumRight: audio.right.map(Double.init)
            )
        }
        uniforms.cameraParallax = parallaxFrame
        // Re-apply pointer fields here: the audio path above may have rebuilt `uniforms` via the stereo initializer, which would otherwise reset them.
        let layerScriptPointerFrame = clickPointerIsLive
            ? inputs.pointerFrame
            : WPEPointerFrame(
                position: pointer,
                clickPosition: pointer,
                isDown: false,
                isRightDown: false
            )
        uniforms.pointerPositionLast = previousPointer
        uniforms.pointerClick = clickPointerIsLive ? layerScriptPointerFrame : .neutral
        previousPointer = pointer
        lastRuntimeUniforms = uniforms
        return FrameContext(
            uniforms: uniforms,
            pointer: pointer,
            followPointerIsLive: followPointerIsLive,
            layerScriptPointerFrame: layerScriptPointerFrame,
            parallaxFrame: parallaxFrame
        )
    }
}
#endif
