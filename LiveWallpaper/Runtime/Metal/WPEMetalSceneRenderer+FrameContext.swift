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

    /// Everything a frame derives from the pointer, in scene space.
    struct PointerSpace: Equatable {
        let pointer: SIMD2<Double>
        let followPointerIsLive: Bool
        let clickPointerIsLive: Bool
        let pointerFrame: WPEPointerFrame
    }

    /// Liveness comes from the mapping, not `isInsideView`: a pointer on a letterbox margin is
    /// inside the drawable but outside the scene. The click frame goes through the same crop
    /// as the follow pointer, or shaders and scripts disagree by up to half the cropped extent.
    static func pointerSpace(
        present: WPEPresentUniforms,
        sample: WPEMetalPointerSample,
        frame: WPEPointerFrame,
        followEnabled: Bool,
        clickEnabled: Bool
    ) -> PointerSpace {
        let centre = SIMD2<Double>(0.5, 0.5)
        let inScene = sample.isInsideView ? present.scenePointer(fromDrawablePointer: sample.position) : nil
        let followPointerIsLive = followEnabled && inScene != nil
        let pointer = (followEnabled ? inScene : nil) ?? centre
        let position = present.scenePointer(fromDrawablePointer: frame.position)
        let click = present.scenePointer(fromDrawablePointer: frame.clickPosition)
        let clickPointerIsLive = clickEnabled && sample.isInsideView && position != nil && click != nil
        let pointerFrame = if clickPointerIsLive, let position, let click {
            WPEPointerFrame(position: position, clickPosition: click, isDown: frame.isDown, isRightDown: frame.isRightDown)
        } else {
            WPEPointerFrame(position: pointer, clickPosition: pointer, isDown: false, isRightDown: false)
        }
        return PointerSpace(
            pointer: pointer,
            followPointerIsLive: followPointerIsLive,
            clickPointerIsLive: clickPointerIsLive,
            pointerFrame: pointerFrame
        )
    }

    private func presentUniforms() -> WPEPresentUniforms {
        WPEPresentUniforms.make(
            fitMode: presentFitMode,
            sourceWidth: Int(sceneRenderSize.width),
            sourceHeight: Int(sceneRenderSize.height),
            targetWidth: Int(surfaceDrawableSize.width),
            targetHeight: Int(surfaceDrawableSize.height)
        )
    }

    func sampleFrameContext(inputs: WPEFrameInputs) -> FrameContext {
        // Click capture stays independent because Interaction can be enabled without Follow Cursor. The snapshot always sampled the pointer, so an inactive gate discards it.
        let pointerSample = (mouseInteractionEnabled || inputs.clickCaptureEnabled)
            ? inputs.pointerSample
            : .inactive
        let space = Self.pointerSpace(
            present: presentUniforms(),
            sample: pointerSample,
            frame: inputs.pointerFrame,
            followEnabled: mouseInteractionEnabled,
            clickEnabled: inputs.clickCaptureEnabled
        )
        let followPointerIsLive = space.followPointerIsLive
        let clickPointerIsLive = space.clickPointerIsLive
        // Oracle overrides are authored in scene space already.
        let pointer = oracleFrameOverride?.pointer ?? space.pointer
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
            ? space.pointerFrame
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
