import Foundation

/// Injected IIFEs for `HTMLWallpaperView`. Idempotent via `__lw*Installed__` sentinels.
enum HTMLWallpaperRuntimeScript {

    // MARK: - Number formatting

    /// en_US_POSIX so locales cannot inject commas/exponents into JS literals.
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Audio controller

    /// Master mute/volume: MO + play + `new Audio` + WebAudio GainNode (each covers a gap).
    static func masterAudioController(initialVolume: Double, initialMuted: Bool) -> String {
        let volumeLiteral = jsNumber(initialVolume)
        let mutedLiteral = initialMuted ? "true" : "false"
        return """
        (function () {
            if (window.__lwAudioInstalled__) {
                if (typeof window.__lwUpdateAudio__ === 'function') {
                    window.__lwUpdateAudio__(\(volumeLiteral), \(mutedLiteral));
                }
                return;
            }
            window.__lwAudioInstalled__ = true;
            var __lwVolume__ = \(volumeLiteral);
            var __lwMuted__ = \(mutedLiteral);
            var __lwAudioContexts__ = [];
            var __lwOriginalAudioNodeConnect__ = null;
            var __lwMediaVolumes__ = typeof WeakMap !== 'undefined' ? new WeakMap() : null;
            var __lwMediaMutes__ = typeof WeakMap !== 'undefined' ? new WeakMap() : null;
            // `new Audio()` elements do not belong to the DOM, so a later
            // master-volume/unmute update cannot find them via querySelectorAll.
            // Keep weak references where WebKit supports them; the bounded
            // fallback prevents old one-shot sound effects from leaking forever.
            var __lwTrackedMedia__ = [];
            var __lwKnownMedia__ = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
            var __lwNativeVolumeGetter__ = null;
            var __lwNativeVolumeSetter__ = null;
            var __lwNativeMutedGetter__ = null;
            var __lwNativeMutedSetter__ = null;

            function effectiveLevel() { return __lwMuted__ ? 0 : __lwVolume__; }
            function clamp01(value) {
                value = Number(value);
                return isFinite(value) ? Math.max(0, Math.min(1, value)) : 1;
            }

            function findMediaDescriptor(name) {
                var cursor = window.HTMLMediaElement && HTMLMediaElement.prototype;
                while (cursor && cursor !== Object.prototype) {
                    try {
                        var d = Object.getOwnPropertyDescriptor(cursor, name);
                        if (d && (typeof d.get === 'function' || typeof d.set === 'function')) return d;
                    } catch (e) {}
                    cursor = Object.getPrototypeOf(cursor);
                }
                return null;
            }

            function rememberPageVolume(el, value) {
                value = clamp01(value);
                if (__lwMediaVolumes__) {
                    try { __lwMediaVolumes__.set(el, value); } catch (e) {}
                } else {
                    try { el.__lwPageVolume__ = value; } catch (e) {}
                }
                return value;
            }

            function pageVolume(el) {
                try {
                    if (__lwMediaVolumes__ && __lwMediaVolumes__.has(el)) return __lwMediaVolumes__.get(el);
                    if (!__lwMediaVolumes__ && typeof el.__lwPageVolume__ === 'number') return el.__lwPageVolume__;
                } catch (e) {}
                try {
                    if (__lwNativeVolumeGetter__) return clamp01(__lwNativeVolumeGetter__.call(el));
                } catch (e) {}
                return 1;
            }

            function rememberPageMuted(el, value) {
                value = !!value;
                if (__lwMediaMutes__) {
                    try { __lwMediaMutes__.set(el, value); } catch (e) {}
                } else {
                    try { el.__lwPageMuted__ = value; } catch (e) {}
                }
                return value;
            }

            function pageMuted(el) {
                try {
                    if (__lwMediaMutes__ && __lwMediaMutes__.has(el)) return !!__lwMediaMutes__.get(el);
                    if (!__lwMediaMutes__ && typeof el.__lwPageMuted__ === 'boolean') return !!el.__lwPageMuted__;
                } catch (e) {}
                try {
                    if (__lwNativeMutedGetter__) return !!__lwNativeMutedGetter__.call(el);
                } catch (e) {}
                return false;
            }

            function setNativeVolume(el, value) {
                value = clamp01(value);
                try {
                    if (__lwNativeVolumeSetter__) {
                        __lwNativeVolumeSetter__.call(el, value);
                    } else {
                        el.volume = value;
                    }
                } catch (e) {}
            }

            function setNativeMuted(el, value) {
                value = !!value;
                try {
                    if (__lwNativeMutedSetter__) {
                        __lwNativeMutedSetter__.call(el, value);
                    } else {
                        el.muted = value;
                    }
                } catch (e) {}
            }

            function rememberMediaElement(el) {
                if (!el) return;
                try {
                    if (__lwKnownMedia__ && __lwKnownMedia__.has(el)) return;
                    if (__lwKnownMedia__) __lwKnownMedia__.add(el);
                } catch (e) {}
                try {
                    __lwTrackedMedia__.push(
                        typeof WeakRef !== 'undefined' ? new WeakRef(el) : el
                    );
                    var limit = typeof WeakRef !== 'undefined' ? 256 : 64;
                    if (__lwTrackedMedia__.length > limit) {
                        __lwTrackedMedia__ = __lwTrackedMedia__.slice(-limit);
                    }
                } catch (e) {}
            }

            function trackedMediaElements() {
                var elements = [];
                var retained = [];
                for (var i = 0; i < __lwTrackedMedia__.length; i++) {
                    var entry = __lwTrackedMedia__[i];
                    var el = entry;
                    try {
                        if (entry && typeof entry.deref === 'function') el = entry.deref();
                    } catch (e) { el = null; }
                    if (!el) continue;
                    elements.push(el);
                    retained.push(entry);
                }
                __lwTrackedMedia__ = retained;
                return elements;
            }

            function forEachKnownMedia(callback) {
                var seen = typeof WeakSet !== 'undefined' ? new WeakSet() : [];
                function visit(el) {
                    if (!el) return;
                    try {
                        if (seen instanceof Array) {
                            if (seen.indexOf(el) !== -1) return;
                            seen.push(el);
                        } else {
                            if (seen.has(el)) return;
                            seen.add(el);
                        }
                    } catch (e) {}
                    callback(el);
                }
                try {
                    var nodes = document.querySelectorAll('audio,video');
                    for (var i = 0; i < nodes.length; i++) visit(nodes[i]);
                } catch (e) {}
                var tracked = trackedMediaElements();
                for (var j = 0; j < tracked.length; j++) visit(tracked[j]);
            }

            function applyToElement(el) {
                if (!el) return;
                var tag = el.tagName;
                if (tag !== 'AUDIO' && tag !== 'VIDEO') return;
                rememberMediaElement(el);
                var requestedVolume = pageVolume(el);
                var requestedMuted = pageMuted(el);
                // Snapshot the page's intent before writing the master-scaled
                // native values. Otherwise the next update mistakes our own
                // native `muted=true` (or scaled volume) for a page request and
                // an anonymous BGM element can never be unmuted again.
                rememberPageVolume(el, requestedVolume);
                rememberPageMuted(el, requestedMuted);
                setNativeVolume(el, requestedVolume * __lwVolume__);
                setNativeMuted(el, __lwMuted__ || requestedMuted);
            }

            function scanAndApply(root) {
                if (!root) return;
                if (root.nodeType === 1) applyToElement(root);
                if (root.querySelectorAll) {
                    var nodes = root.querySelectorAll('audio,video');
                    for (var i = 0; i < nodes.length; i++) applyToElement(nodes[i]);
                }
            }

            function startObserver() {
                if (!document.body || window.__lwAudioObserver__) return;
                try {
                    var observer = new MutationObserver(function (mutations) {
                        for (var m = 0; m < mutations.length; m++) {
                            var added = mutations[m].addedNodes;
                            for (var n = 0; n < added.length; n++) scanAndApply(added[n]);
                        }
                    });
                    observer.observe(document.body, { childList: true, subtree: true });
                    window.__lwAudioObserver__ = observer;
                } catch (e) {}
            }

            function patchMediaProperties() {
                if (!window.HTMLMediaElement || !HTMLMediaElement.prototype) return;
                if (HTMLMediaElement.prototype.__lwMediaPropertiesPatched__) return;
                var volumeDescriptor = findMediaDescriptor('volume');
                var mutedDescriptor = findMediaDescriptor('muted');
                __lwNativeVolumeGetter__ = volumeDescriptor && volumeDescriptor.get;
                __lwNativeVolumeSetter__ = volumeDescriptor && volumeDescriptor.set;
                __lwNativeMutedGetter__ = mutedDescriptor && mutedDescriptor.get;
                __lwNativeMutedSetter__ = mutedDescriptor && mutedDescriptor.set;
                if (__lwNativeVolumeSetter__) {
                    try {
                        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
                            configurable: true,
                            get: function () { return pageVolume(this); },
                            set: function (value) {
                                var requested = rememberPageVolume(this, value);
                                setNativeVolume(this, requested * __lwVolume__);
                            }
                        });
                    } catch (e) {}
                }
                if (__lwNativeMutedSetter__) {
                    try {
                        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
                            configurable: true,
                            get: function () { return pageMuted(this) || __lwMuted__; },
                            set: function (value) {
                                var requested = rememberPageMuted(this, value);
                                setNativeMuted(this, __lwMuted__ || requested);
                            }
                        });
                    } catch (e) {}
                }
                try { HTMLMediaElement.prototype.__lwMediaPropertiesPatched__ = true; } catch (e) {}
            }
            patchMediaProperties();

            if (window.HTMLMediaElement && HTMLMediaElement.prototype.play) {
                var originalPlay = HTMLMediaElement.prototype.play;
                HTMLMediaElement.prototype.play = function () {
                    applyToElement(this);
                    return originalPlay.apply(this, arguments);
                };
            }

            if (window.Audio) {
                var OriginalAudio = window.Audio;
                function PatchedAudio() {
                    var bound = Function.prototype.bind.apply(
                        OriginalAudio,
                        [null].concat(Array.prototype.slice.call(arguments))
                    );
                    var instance = new bound();
                    applyToElement(instance);
                    return instance;
                }
                PatchedAudio.prototype = OriginalAudio.prototype;
                try { window.Audio = PatchedAudio; } catch (e) {}
            }

            function findOriginalDestinationGetter(proto) {
                // `destination` is on BaseAudioContext.prototype — walk the chain.
                var cursor = proto;
                while (cursor && cursor !== Object.prototype) {
                    try {
                        var d = Object.getOwnPropertyDescriptor(cursor, 'destination');
                        if (d && typeof d.get === 'function') return d.get;
                    } catch (e) {}
                    cursor = Object.getPrototypeOf(cursor);
                }
                return null;
            }

            function rememberContext(ctx) {
                if (!ctx) return;
                if (__lwAudioContexts__.indexOf(ctx) === -1) {
                    __lwAudioContexts__.push(ctx);
                }
            }

            function connectMasterGain(gain, realDestination) {
                try {
                    if (__lwOriginalAudioNodeConnect__) {
                        __lwOriginalAudioNodeConnect__.call(gain, realDestination);
                    } else {
                        gain.connect(realDestination);
                    }
                } catch (e) {}
            }

            function ensureMasterGain(ctx, realDestination) {
                if (!ctx || !realDestination) return realDestination;
                if (!ctx.__lwGainNode__) {
                    try {
                        var gain = ctx.createGain();
                        gain.gain.value = effectiveLevel();
                        gain.__lwMasterGainNode__ = true;
                        connectMasterGain(gain, realDestination);
                        ctx.__lwGainNode__ = gain;
                    } catch (e) {
                        return realDestination;
                    }
                }
                rememberContext(ctx);
                return ctx.__lwGainNode__;
            }

            function isAudioDestinationNode(node) {
                if (!node) return false;
                try {
                    if (window.AudioDestinationNode && node instanceof window.AudioDestinationNode) return true;
                } catch (e) {}
                try {
                    return node.constructor && node.constructor.name === 'AudioDestinationNode';
                } catch (e) {
                    return false;
                }
            }

            function patchAudioNodeConnect() {
                if (!window.AudioNode || !AudioNode.prototype || !AudioNode.prototype.connect) return;
                if (AudioNode.prototype.__lwConnectPatched__) return;
                var originalConnect = AudioNode.prototype.connect;
                __lwOriginalAudioNodeConnect__ = originalConnect;
                AudioNode.prototype.connect = function (destination) {
                    var args = Array.prototype.slice.call(arguments);
                    try {
                        if (isAudioDestinationNode(destination) && this.context) {
                            args[0] = ensureMasterGain(this.context, destination);
                        }
                    } catch (e) {}
                    return originalConnect.apply(this, args);
                };
                AudioNode.prototype.__lwConnectPatched__ = true;
            }

            function patchAudioContext(Ctor) {
                if (!Ctor || !Ctor.prototype) return;
                var originalGetter = findOriginalDestinationGetter(Ctor.prototype);
                if (!originalGetter) return;
                try {
                    Object.defineProperty(Ctor.prototype, 'destination', {
                        configurable: true,
                        get: function () {
                            var real = originalGetter.call(this);
                            return ensureMasterGain(this, real);
                        }
                    });
                } catch (e) {}
            }
            patchAudioNodeConnect();
            patchAudioContext(window.AudioContext);
            patchAudioContext(window.webkitAudioContext);
            patchAudioContext(window.OfflineAudioContext);
            patchAudioContext(window.webkitOfflineAudioContext);

            window.__lwUpdateAudio__ = function (volume, muted) {
                if (typeof volume === 'number' && isFinite(volume)) {
                    __lwVolume__ = Math.max(0, Math.min(1, volume));
                }
                __lwMuted__ = !!muted;
                forEachKnownMedia(applyToElement);
                var level = effectiveLevel();
                for (var k = 0; k < __lwAudioContexts__.length; k++) {
                    var ctx = __lwAudioContexts__[k];
                    if (ctx && ctx.__lwGainNode__) {
                        try { ctx.__lwGainNode__.gain.value = level; } catch (e) {}
                    }
                }
            };

            window.__lwAudioDebugSnapshot__ = function () {
                var media = [];
                forEachKnownMedia(function (el) {
                    var source = '';
                    try {
                        var raw = el.currentSrc || el.src || '';
                        source = raw ? raw.split('/').pop().split('?')[0] : '';
                    } catch (e) {}
                    var nativeVolume = null;
                    var nativeMuted = null;
                    try {
                        if (__lwNativeVolumeGetter__) nativeVolume = __lwNativeVolumeGetter__.call(el);
                    } catch (e) {}
                    try {
                        if (__lwNativeMutedGetter__) nativeMuted = __lwNativeMutedGetter__.call(el);
                    } catch (e) {}
                    media.push({
                        source: source,
                        pageVolume: pageVolume(el),
                        nativeVolume: nativeVolume,
                        pageMuted: pageMuted(el),
                        nativeMuted: nativeMuted,
                        paused: !!el.paused,
                        ended: !!el.ended,
                        readyState: Number(el.readyState || 0),
                        networkState: Number(el.networkState || 0),
                        currentTime: Number(el.currentTime || 0),
                        errorCode: el.error ? Number(el.error.code || 0) : 0
                    });
                });
                return {
                    masterVolume: __lwVolume__,
                    masterMuted: __lwMuted__,
                    media: media,
                    audioContexts: __lwAudioContexts__.map(function (ctx) {
                        return ctx && ctx.state ? ctx.state : 'unknown';
                    })
                };
            };

            window.__lwSuspendAudioContexts__ = function () {
                for (var i = 0; i < __lwAudioContexts__.length; i++) {
                    var ctx = __lwAudioContexts__[i];
                    if (ctx && typeof ctx.suspend === 'function' && ctx.state === 'running') {
                        try { ctx.suspend(); } catch (e) {}
                    }
                }
            };
            window.__lwResumeAudioContexts__ = function () {
                for (var i = 0; i < __lwAudioContexts__.length; i++) {
                    var ctx = __lwAudioContexts__[i];
                    if (ctx && typeof ctx.resume === 'function' && ctx.state === 'suspended') {
                        try { ctx.resume(); } catch (e) {}
                    }
                }
            };

            if (document.body) {
                startObserver();
                scanAndApply(document);
            } else if (document.addEventListener) {
                document.addEventListener('DOMContentLoaded', function () {
                    startObserver();
                    scanAndApply(document);
                });
            }
        })();
        """
    }

    // MARK: - Transform controller

    /// Body transform via injected style; identity values skip the DOM.
    static func transformController(
        scale: Double,
        translateX: Double,
        translateY: Double,
        rotation: Double
    ) -> String {
        let s = jsNumber(scale)
        let tx = jsNumber(translateX)
        let ty = jsNumber(translateY)
        let r = jsNumber(rotation)
        return """
        (function () {
            function ensureStyle() {
                var el = document.getElementById('__lw-transform-style__');
                if (el) return el;
                el = document.createElement('style');
                el.id = '__lw-transform-style__';
                (document.head || document.documentElement).appendChild(el);
                return el;
            }
            function apply(scale, tx, ty, rotation) {
                var identity = scale === 1 && tx === 0 && ty === 0 && rotation === 0;
                var style = ensureStyle();
                if (identity) {
                    style.textContent = '';
                    if (document.documentElement) {
                        document.documentElement.classList.remove('lw-transformed');
                    }
                    return;
                }
                var transform = 'translate(' + tx + 'px,' + ty + 'px) rotate(' + rotation + 'deg) scale(' + scale + ')';
                style.textContent =
                    'html.lw-transformed{overflow:hidden!important;}' +
                    'html.lw-transformed body{transform:' + transform + ';transform-origin:50% 50%;}';
                if (document.documentElement) {
                    document.documentElement.classList.add('lw-transformed');
                }
            }
            window.__lwUpdateTransform__ = apply;
            if (document.body) {
                apply(\(s), \(tx), \(ty), \(r));
            } else if (document.addEventListener) {
                document.addEventListener('DOMContentLoaded', function () {
                    apply(\(s), \(tx), \(ty), \(r));
                });
            }
        })();
        """
    }

    // MARK: - GPU canvas MSAA / backing-store upgrader

    /// Default `antialias: true` for WebGL — WPE Spine often omits it (MSAA-off on WebKit).
    /// Only fills the gap: a page that asked for `antialias:false` pays no MSAA
    /// VRAM. WebIDL treats an absent key and an explicit `undefined` alike.
    static func gpuCanvasMSAAForcer() -> String {
        return """
        (function () {
            if (window.__lwCanvasMSAAInstalled__) return;
            window.__lwCanvasMSAAInstalled__ = true;
            try {
                var proto = HTMLCanvasElement && HTMLCanvasElement.prototype;
                if (!proto || !proto.getContext) return;
                var orig = proto.getContext;
                proto.getContext = function (type, attrs) {
                    if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
                        var merged = {};
                        var specifiedAntialias = false;
                        if (attrs && typeof attrs === 'object') {
                            for (var k in attrs) {
                                if (Object.prototype.hasOwnProperty.call(attrs, k)) merged[k] = attrs[k];
                            }
                            specifiedAntialias =
                                Object.prototype.hasOwnProperty.call(attrs, 'antialias')
                                && attrs.antialias !== undefined;
                        }
                        if (!specifiedAntialias) merged.antialias = true;
                        return orig.call(this, type, merged);
                    }
                    return orig.apply(this, arguments);
                };
            } catch (e) {}
        })();
        """
    }

    /// Physical-pixel GPU backing for CSS-sized canvases; DPR-aware callers untouched.
    /// Scales viewport/scissor only on the default framebuffer; skips 2D.
    static func canvasBackingStoreUpgrader() -> String {
        return """
        (function () {
            if (window.__lwCanvasUpgraderInstalled__) return;
            window.__lwCanvasUpgraderInstalled__ = true;

            function nativeDPR() {
                var v = window.__liveWallpaperNativeDevicePixelRatio;
                if (typeof v === 'number' && v > 0) return v;
                v = window.devicePixelRatio;
                return (typeof v === 'number' && v > 0) ? v : 1;
            }

            if (nativeDPR() <= 1) return;

            var wDesc, hDesc;
            try {
                wDesc = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, 'width');
                hDesc = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, 'height');
                if (!wDesc || !wDesc.set || !hDesc || !hDesc.set) return;
            } catch (e) { return; }

            try {
                function installSetter(propName, desc, axis) {
                    var ownedKey = (axis === 'w') ? '__lwOwnedStyleW__' : '__lwOwnedStyleH__';
                    function adoptStyle(canvas, value) {
                        var current = canvas.style[propName];
                        if (current !== '' && current !== canvas[ownedKey]) return;
                        canvas.style[propName] = value;
                        canvas[ownedKey] = value;
                    }
                    function releaseStyle(canvas) {
                        if (canvas.style[propName] === canvas[ownedKey]) {
                            canvas.style[propName] = '';
                        }
                        canvas[ownedKey] = undefined;
                    }
                    Object.defineProperty(HTMLCanvasElement.prototype, propName, {
                        configurable: true,
                        enumerable: desc.enumerable,
                        get: function () {
                            var stash = (axis === 'w') ? this.__lwLogicalW__ : this.__lwLogicalH__;
                            return (typeof stash === 'number') ? stash : desc.get.call(this);
                        },
                        set: function (v) {
                            var n = Number(v) || 0;
                            if (axis === 'w') this.__lwLogicalW__ = n;
                            else              this.__lwLogicalH__ = n;
                            if (n <= 0 || !this.__lwIsGPUCanvas__) {
                                this.__lwScale__ = 1;
                                releaseStyle(this);
                                desc.set.call(this, n);
                                return;
                            }
                            var dpr = nativeDPR();
                            if (dpr <= 1) {
                                this.__lwScale__ = 1;
                                releaseStyle(this);
                                desc.set.call(this, n);
                                return;
                            }
                            var clientSize = (axis === 'w') ? this.clientWidth : this.clientHeight;
                            var innerSize  = (axis === 'w') ? window.innerWidth : window.innerHeight;
                            var ref = Math.max(clientSize || 0, innerSize || 0, 1);
                            if (n > ref * 1.05) {
                                this.__lwScale__ = 1;
                                releaseStyle(this);
                                desc.set.call(this, n);
                                return;
                            }
                            this.__lwScale__ = dpr;
                            adoptStyle(this, n + 'px');
                            desc.set.call(this, Math.round(n * dpr));
                        }
                    });
                }
                installSetter('width',  wDesc, 'w');
                installSetter('height', hDesc, 'h');
            } catch (e) {}

            try {
                var origGetContext = HTMLCanvasElement.prototype.getContext;
                HTMLCanvasElement.prototype.getContext = function (type, attrs) {
                    if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
                        if (!this.__lwIsGPUCanvas__) {
                            this.__lwIsGPUCanvas__ = true;
                            var w = (typeof this.__lwLogicalW__ === 'number')
                                ? this.__lwLogicalW__ : wDesc.get.call(this);
                            var h = (typeof this.__lwLogicalH__ === 'number')
                                ? this.__lwLogicalH__ : hDesc.get.call(this);
                            this.width  = w;
                            this.height = h;
                        }
                    }
                    return origGetContext.apply(this, arguments);
                };
            } catch (e) {}

            function hookContextPrototype(proto) {
                if (!proto || proto.__lwGLHookInstalled__) return;
                proto.__lwGLHookInstalled__ = true;
                var origViewport     = proto.viewport;
                var origScissor      = proto.scissor;
                var origBindFB       = proto.bindFramebuffer;
                var FRAMEBUFFER      = 0x8D40;
                var DRAW_FRAMEBUFFER = 0x8CA9;

                proto.bindFramebuffer = function (target, fb) {
                    if (target === FRAMEBUFFER || target === DRAW_FRAMEBUFFER) {
                        this.__lwBoundFB__ = fb;
                    }
                    return origBindFB.call(this, target, fb);
                };

                function scaledRect(ctx, x, y, w, h) {
                    var canvas = ctx.canvas;
                    var bound = ctx.__lwBoundFB__;
                    if (bound != null) return null;
                    var s = canvas && canvas.__lwScale__;
                    if (!s || s === 1) return null;
                    return [
                        Math.round(x * s),
                        Math.round(y * s),
                        Math.round(w * s),
                        Math.round(h * s)
                    ];
                }

                proto.viewport = function (x, y, w, h) {
                    var r = scaledRect(this, x, y, w, h);
                    if (r) return origViewport.call(this, r[0], r[1], r[2], r[3]);
                    return origViewport.call(this, x, y, w, h);
                };

                proto.scissor = function (x, y, w, h) {
                    var r = scaledRect(this, x, y, w, h);
                    if (r) return origScissor.call(this, r[0], r[1], r[2], r[3]);
                    return origScissor.call(this, x, y, w, h);
                };
            }

            try {
                if (typeof WebGLRenderingContext !== 'undefined') {
                    hookContextPrototype(WebGLRenderingContext.prototype);
                }
                if (typeof WebGL2RenderingContext !== 'undefined') {
                    hookContextPrototype(WebGL2RenderingContext.prototype);
                }
            } catch (e) {}
        })();
        """
    }

    /// Host backing scale on `window` — do not override `devicePixelRatio`
    /// (spine-player/PIXI size from clientWidth×DPR and would mis-frame).
    static func physicalPixelState(enabled: Bool, backingScale: CGFloat) -> String {
        let scale = max(Double(backingScale), 1.0)
        let scaleLiteral = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), scale)
        return """
        (function () {
            window.__liveWallpaperNativeDevicePixelRatio = \(scaleLiteral);
            window.__liveWallpaperPhysicalPixelLayout = \(enabled ? "true" : "false");
        })();
        """
    }

    // MARK: - Lifecycle Controller

    /// Suspend/resume/RAF throttle. Injected into every frame; the host drives
    /// the main frame, which relays the phase to subframes over `postMessage`.
    /// Layers visibility + rAF queue + CSS pause; `aggressiveSuspend` also
    /// loses GPU contexts (off by default — restore often leaves black pages).
    static func lifecycleController(aggressiveSuspend: Bool) -> String {
        let aggressive = aggressiveSuspend ? "true" : "false"
        return """
        (function () {
            if (window.__lwLifecycleInstalled__) return;
            window.__lwLifecycleInstalled__ = true;
            var aggressive = \(aggressive);
            var rafBackup = null;
            var rafThrottleRatio = 1;
            var rafThrottleCounter = 0;
            // Minimum milliseconds between dispatched rAF callbacks — the user's
            // frame-rate ceiling. Separate from the thermal ratio above: an
            // integer divisor of the display refresh cannot express 30 on a
            // 136 Hz panel, and the two must compose instead of overwriting.
            var rafTargetIntervalMs = 0;
            var rafLastDispatchMs = 0;
            var rafLastTickMs = 0;
            var rafNativeIntervalMs = 0;
            var rafGateStampMs = null;
            var rafGateStampAllows = true;
            var suspended = false;
            var hiddenDescriptorBackup = null;
            var visibilityDescriptorBackup = null;
            var gpuCanvasContexts = [];
            var nativeSetTimeout = window.setTimeout;
            var nativeClearTimeout = window.clearTimeout;
            var nativeSetInterval = window.setInterval;
            var nativeClearInterval = window.clearInterval;
            var timerRecords = Object.create(null);
            var nextTimerId = 1000000000;
            // Weak entries when available — auto-wrapped workers would otherwise
            // be pinned for the page's lifetime.
            var managedWorkers = [];
            var supportsWeakRef = (typeof WeakRef === 'function');
            var isTopFrame = true;
            try { isTopFrame = (window.top === window); } catch (e) { isTopFrame = false; }

            function timerNow() {
                try {
                    if (window.performance && typeof window.performance.now === 'function') {
                        return window.performance.now();
                    }
                } catch (e) {}
                return Date.now();
            }

            function invokeTimerCallback(record) {
                if (timerRecords[record.id] !== record || suspended) return;
                record.nativeId = null;
                if (!record.repeating) delete timerRecords[record.id];
                var callbackThrew = false;
                var callbackError = null;
                try {
                    if (typeof record.callback === 'function') {
                        record.callback.apply(window, record.args);
                    } else {
                        (0, eval)(String(record.callback));
                    }
                } catch (e) {
                    callbackThrew = true;
                    callbackError = e;
                }
                if (record.repeating
                    && timerRecords[record.id] === record
                    && !suspended) {
                    scheduleTimer(record, record.delay);
                }
                // Re-throw in this callback so no unmanaged timer escapes suspend.
                if (callbackThrew) throw callbackError;
            }

            function scheduleTimer(record, delay) {
                delay = Math.max(0, Number(delay) || 0);
                record.remaining = delay;
                record.deadline = timerNow() + delay;
                record.nativeId = nativeSetTimeout.call(window, function () {
                    invokeTimerCallback(record);
                }, delay);
            }

            function createTimer(callback, delay, args, repeating) {
                var normalizedDelay = Math.max(0, Number(delay) || 0);
                var id = nextTimerId++;
                var record = {
                    id: id,
                    callback: callback,
                    args: args,
                    repeating: repeating,
                    delay: normalizedDelay,
                    remaining: normalizedDelay,
                    deadline: 0,
                    nativeId: null
                };
                timerRecords[id] = record;
                if (!suspended) scheduleTimer(record, normalizedDelay);
                return id;
            }

            function clearManagedTimer(id, nativeClear) {
                var record = timerRecords[id];
                if (!record) {
                    nativeClear.call(window, id);
                    return;
                }
                if (record.nativeId !== null) {
                    nativeClearTimeout.call(window, record.nativeId);
                }
                delete timerRecords[id];
            }

            window.setTimeout = function (callback, delay) {
                return createTimer(
                    callback,
                    delay,
                    Array.prototype.slice.call(arguments, 2),
                    false
                );
            };
            window.setInterval = function (callback, delay) {
                return createTimer(
                    callback,
                    delay,
                    Array.prototype.slice.call(arguments, 2),
                    true
                );
            };
            window.clearTimeout = function (id) {
                clearManagedTimer(id, nativeClearTimeout);
            };
            window.clearInterval = function (id) {
                clearManagedTimer(id, nativeClearInterval);
            };

            function suspendTimers() {
                var now = timerNow();
                Object.keys(timerRecords).forEach(function (id) {
                    var record = timerRecords[id];
                    if (record.nativeId === null) return;
                    record.remaining = Math.max(0, record.deadline - now);
                    nativeClearTimeout.call(window, record.nativeId);
                    record.nativeId = null;
                });
            }

            function resumeTimers() {
                Object.keys(timerRecords).forEach(function (id) {
                    var record = timerRecords[id];
                    if (record.nativeId === null) {
                        scheduleTimer(record, record.remaining);
                    }
                });
            }

            function signalWorker(worker, phase) {
                var type = phase === 'suspend'
                    ? 'livewallpaper:suspend'
                    : 'livewallpaper:resume';
                try {
                    worker.postMessage({ type: type });
                } catch (e) {}
            }

            function workerFromEntry(entry) {
                if (!entry) return null;
                if (!supportsWeakRef) return entry;
                try { return entry.deref() || null; } catch (e) { return null; }
            }

            function indexOfWorker(worker) {
                for (var i = 0; i < managedWorkers.length; i++) {
                    if (workerFromEntry(managedWorkers[i]) === worker) return i;
                }
                return -1;
            }

            function trackWorker(worker) {
                if (!worker || typeof worker.postMessage !== 'function') {
                    return function () {};
                }
                if (indexOfWorker(worker) < 0) {
                    managedWorkers.push(supportsWeakRef ? new WeakRef(worker) : worker);
                    if (suspended) signalWorker(worker, 'suspend');
                }
                return function () { untrackWorker(worker); };
            }

            function untrackWorker(worker) {
                var index = indexOfWorker(worker);
                if (index >= 0) managedWorkers.splice(index, 1);
            }

            function signalWorkers(phase) {
                // Prune collected entries while walking: auto-wrapped workers have
                // no page-side unregister call to rely on.
                var live = [];
                for (var i = 0; i < managedWorkers.length; i++) {
                    var worker = workerFromEntry(managedWorkers[i]);
                    if (!worker) continue;
                    live.push(managedWorkers[i]);
                    signalWorker(worker, phase);
                }
                managedWorkers = live;
            }

            function installWorkerLifecycle() {
                // Kept for pages that build workers behind their own factory.
                window.__lwRegisterWorkerForLifecycle__ = function (worker) {
                    return trackWorker(worker);
                };

                var NativeWorker = window.Worker;
                if (typeof NativeWorker !== 'function' || NativeWorker.__lwWorkerWrapped__) return;
                // Registration used to be opt-in, so a page that never called the
                // hook kept its workers running through every suspend.
                function LWManagedWorker(scriptURL, options) {
                    var worker = new NativeWorker(scriptURL, options);
                    trackWorker(worker);
                    var nativeTerminate = worker.terminate;
                    if (typeof nativeTerminate === 'function') {
                        worker.terminate = function () {
                            untrackWorker(worker);
                            return nativeTerminate.apply(worker, arguments);
                        };
                    }
                    // Returning the real Worker keeps `instanceof Worker` true.
                    return worker;
                }
                LWManagedWorker.prototype = NativeWorker.prototype;
                LWManagedWorker.__lwWorkerWrapped__ = true;
                try { window.Worker = LWManagedWorker; } catch (e) {}
            }
            installWorkerLifecycle();

            // The host can only evaluate script in the main frame, so an ad or
            // embedded-player iframe keeps its own timers, rAF and canvases
            // running; relay the phase down the frame tree instead.
            function broadcastToChildFrames(phase) {
                var children;
                try { children = window.frames; } catch (e) { return; }
                if (!children) return;
                for (var i = 0; i < children.length; i++) {
                    try {
                        children[i].postMessage({ __lwLifecycle__: phase }, '*');
                    } catch (e) {}
                }
            }

            // The host can only evaluate script in the main frame, so the frame
            // pacing rides the same relay the suspend phase does.
            function currentPacingMessage() {
                return {
                    __lwPacing__: {
                        ratio: rafThrottleRatio,
                        intervalMs: rafTargetIntervalMs
                    }
                };
            }

            function broadcastPacingToChildFrames() {
                var children;
                try { children = window.frames; } catch (e) { return; }
                if (!children) return;
                for (var i = 0; i < children.length; i++) {
                    try {
                        children[i].postMessage(currentPacingMessage(), '*');
                    } catch (e) {}
                }
            }

            function isOwnChildFrame(source) {
                if (!source) return false;
                var children;
                try { children = window.frames; } catch (e) { return false; }
                if (!children) return false;
                for (var i = 0; i < children.length; i++) {
                    try { if (children[i] === source) return true; } catch (e) {}
                }
                return false;
            }

            // A broadcast only reaches the frames that exist when it is sent, so an iframe inserted
            // after the last push used to run at the display rate until the next thermal/limit change —
            // the newcomer asks instead. Reaches exactly the frames WebKit injects this script into
            // (`forMainFrameOnly: false`), which is not every frame.
            function installPacingRequestResponder() {
                try {
                    window.addEventListener('message', function (event) {
                        var data = event && event.data;
                        if (!data || typeof data !== 'object') return;
                        if (data.__lwPacingRequest__ !== true) return;
                        // Only a frame we actually embed may pull our pacing.
                        if (!isOwnChildFrame(event.source)) return;
                        try {
                            event.source.postMessage(currentPacingMessage(), '*');
                        } catch (e) {}
                    }, false);
                } catch (e) {}
            }

            function requestPacingFromParent() {
                try {
                    window.parent.postMessage({ __lwPacingRequest__: true }, '*');
                } catch (e) {}
            }

            function installFrameLifecycleRelay() {
                if (isTopFrame) return;
                try {
                    window.addEventListener('message', function (event) {
                        var data = event && event.data;
                        if (!data || typeof data !== 'object') return;
                        // Only the embedding frame may drive this one.
                        if (event.source !== window.parent) return;
                        var pacing = data.__lwPacing__;
                        if (pacing && typeof pacing === 'object') {
                            // Both knobs then one broadcast: going through the
                            // public setters would post twice per level and
                            // double the message count at every nesting depth.
                            installRafThrottle(clampRafRatio(pacing.ratio));
                            installRafTargetInterval(clampRafInterval(pacing.intervalMs));
                            broadcastPacingToChildFrames();
                            return;
                        }
                        var phase = data.__lwLifecycle__;
                        if (phase !== 'suspend' && phase !== 'resume') return;
                        if (phase === 'suspend') window.__lwSuspend__();
                        else window.__lwResume__();
                    }, false);
                } catch (e) {}
                // After the listener exists, or the answer arrives at nobody.
                requestPacingFromParent();
            }

            function captureDescriptor(name) {
                try {
                    var proto = Object.getPrototypeOf(document) || Document.prototype;
                    return Object.getOwnPropertyDescriptor(proto, name)
                        || Object.getOwnPropertyDescriptor(Document.prototype, name);
                } catch (e) { return null; }
            }

            function forceHidden(hidden) {
                try {
                    Object.defineProperty(document, 'hidden', {
                        configurable: true,
                        get: function () { return hidden; }
                    });
                    Object.defineProperty(document, 'visibilityState', {
                        configurable: true,
                        get: function () { return hidden ? 'hidden' : 'visible'; }
                    });
                } catch (e) {}
            }

            function restoreVisibility() {
                try {
                    if (hiddenDescriptorBackup) {
                        Object.defineProperty(document, 'hidden', hiddenDescriptorBackup);
                    } else {
                        delete document.hidden;
                    }
                    if (visibilityDescriptorBackup) {
                        Object.defineProperty(document, 'visibilityState', visibilityDescriptorBackup);
                    } else {
                        delete document.visibilityState;
                    }
                } catch (e) {}
            }

            function dispatchVisibility() {
                try {
                    document.dispatchEvent(new Event('visibilitychange'));
                } catch (e) {}
            }

            // Queue rAF while suspended so self-perpetuating loops can resume.
            var rafCafBackup = null;
            var rafQueue = [];
            var rafQueueNextId = 1;

            function installRafOverride() {
                if (rafBackup) return;
                rafBackup = window.requestAnimationFrame;
                rafCafBackup = window.cancelAnimationFrame;
                window.requestAnimationFrame = function (cb) {
                    var id = rafQueueNextId++;
                    rafQueue.push({ id: id, cb: cb });
                    return id;
                };
                window.cancelAnimationFrame = function (id) {
                    for (var i = 0; i < rafQueue.length; i++) {
                        if (rafQueue[i].id === id) { rafQueue.splice(i, 1); return; }
                    }
                };
            }

            function restoreRaf() {
                if (!rafBackup) return;
                var native = rafBackup;
                window.requestAnimationFrame = native;
                if (rafCafBackup) window.cancelAnimationFrame = rafCafBackup;
                rafBackup = null;
                rafCafBackup = null;
                // Timestamps from before the suspend would make the gate's first
                // decision on a gap the size of the whole absence.
                rafLastDispatchMs = 0;
                rafLastTickMs = 0;
                rafGateStampMs = null;
                var pending = rafQueue;
                rafQueue = [];
                for (var i = 0; i < pending.length; i++) {
                    (function (entry) {
                        native.call(window, function (t) { entry.cb(t); });
                    })(pending[i]);
                }
            }

            function clampRafRatio(ratio) {
                var value = parseInt(ratio, 10);
                if (!isFinite(value) || value < 1) return 1;
                return value > 8 ? 8 : value;
            }

            function clampRafInterval(intervalMs) {
                var value = parseFloat(intervalMs);
                if (!isFinite(value) || value < 0) return 0;
                return value > 1000 ? 1000 : value;
            }

            // One decision per frame timestamp: every callback scheduled for the
            // same frame gets the same answer. Deciding per callback lets two
            // independent loops alternate through the gate and hand the page
            // back its full rate while each loop looks throttled.
            function rafFrameGateAllows(t) {
                if (rafGateStampMs === t) return rafGateStampAllows;
                rafGateStampMs = t;
                if (rafLastTickMs > 0) {
                    var tick = t - rafLastTickMs;
                    // Ignore the huge gap a resumed or backgrounded page reports.
                    if (tick > 0 && tick < 200) rafNativeIntervalMs = tick;
                }
                rafLastTickMs = t;

                var allows = true;
                if (rafThrottleRatio > 1) {
                    rafThrottleCounter = (rafThrottleCounter + 1) % rafThrottleRatio;
                    if (rafThrottleCounter !== 0) allows = false;
                }
                if (allows && rafTargetIntervalMs > 0) {
                    if (rafLastDispatchMs === 0) {
                        rafLastDispatchMs = t;
                    } else {
                        // Half a native frame of slack: a plain `>= interval`
                        // test rejects the tick that lands a fraction early and
                        // drops a 30 fps target to 20 on a 60 Hz display.
                        var slack = rafNativeIntervalMs > 0 ? rafNativeIntervalMs / 2 : 0;
                        if (t - rafLastDispatchMs >= rafTargetIntervalMs - slack) {
                            // Advance the schedule instead of restamping to `t`: restamping folds every slack-sized early
                            // accept into the next deadline, so the error accumulates (30 fps on a 75 Hz panel ran at 37.5);
                            // advancing leaves the deadline at most `slack` ahead of `t`, keeping the long-run rate <= the
                            // target.
                            rafLastDispatchMs += rafTargetIntervalMs;
                            // More than a whole interval behind means the page
                            // was stalled (long frame, offscreen tab). Snapping
                            // caps the catch-up at this one frame instead of
                            // letting the backlog run ungated.
                            if (t - rafLastDispatchMs >= rafTargetIntervalMs) {
                                rafLastDispatchMs = t;
                            }
                        } else {
                            allows = false;
                        }
                    }
                }
                rafGateStampAllows = allows;
                return allows;
            }

            function installRafThrottle(ratio) {
                rafThrottleRatio = ratio;
                rafThrottleCounter = 0;
                // While suspended, keep ratio; resume reconciles after restoreRaf.
                if (rafBackup) return;
                reconcileRafPacing();
            }

            function installRafTargetInterval(intervalMs) {
                rafTargetIntervalMs = intervalMs;
                rafLastDispatchMs = 0;
                // Same suspended-keeps-the-value rule as the ratio above.
                if (rafBackup) return;
                reconcileRafPacing();
            }

            function reconcileRafPacing() {
                if (rafThrottleRatio <= 1 && rafTargetIntervalMs <= 0) {
                    if (window.__lwRafThrottleBackup__) {
                        window.requestAnimationFrame = window.__lwRafThrottleBackup__;
                        window.__lwRafThrottleBackup__ = null;
                    }
                    return;
                }
                if (!window.__lwRafThrottleBackup__) {
                    window.__lwRafThrottleBackup__ = window.requestAnimationFrame;
                }
                var original = window.__lwRafThrottleBackup__;
                window.requestAnimationFrame = function (cb) {
                    return original.call(window, function (t) {
                        if (rafFrameGateAllows(t)) cb(t);
                        else window.requestAnimationFrame(cb);
                    });
                };
            }

            // animation-play-state does not inherit — class on <html> + rule.
            function ensurePauseStyle() {
                var el = document.getElementById('__lw-suspend-style__');
                if (el) return el;
                el = document.createElement('style');
                el.id = '__lw-suspend-style__';
                el.textContent =
                    'html.__lw-suspended__ *, html.__lw-suspended__ *::before, html.__lw-suspended__ *::after {' +
                    '  animation-play-state: paused !important;' +
                    '  -webkit-animation-play-state: paused !important;' +
                    '  transition: none !important;' +
                    '}';
                (document.head || document.documentElement).appendChild(el);
                return el;
            }

            function setCSSPaused(paused) {
                if (!document.documentElement) return;
                ensurePauseStyle();
                document.documentElement.classList.toggle('__lw-suspended__', paused);
            }

            function collectGPUCanvasContexts() {
                gpuCanvasContexts = [];
                try {
                    var canvases = document.querySelectorAll('canvas');
                    for (var i = 0; i < canvases.length; i++) {
                        var ctx = null;
                        try { ctx = canvases[i].getContext('webgl2'); } catch (e) {}
                        if (!ctx) { try { ctx = canvases[i].getContext('webgl'); } catch (e) {} }
                        if (!ctx) { try { ctx = canvases[i].getContext('experimental-webgl'); } catch (e) {} }
                        if (ctx) gpuCanvasContexts.push(ctx);
                    }
                } catch (e) {}
            }

            function releaseGPUCanvasContexts() {
                collectGPUCanvasContexts();
                for (var i = 0; i < gpuCanvasContexts.length; i++) {
                    var ctx = gpuCanvasContexts[i];
                    try {
                        var ext = ctx.getExtension('WEBGL_lose_context');
                        if (ext) ext.loseContext();
                    } catch (e) {}
                }
            }

            function restoreGPUCanvasContexts() {
                for (var i = 0; i < gpuCanvasContexts.length; i++) {
                    var ctx = gpuCanvasContexts[i];
                    try {
                        var ext = ctx.getExtension('WEBGL_lose_context');
                        if (ext) ext.restoreContext();
                    } catch (e) {}
                }
                gpuCanvasContexts = [];
            }

            window.__lwSuspend__ = function () {
                if (suspended) return;
                suspended = true;
                suspendTimers();
                signalWorkers('suspend');
                broadcastToChildFrames('suspend');
                if (!hiddenDescriptorBackup) hiddenDescriptorBackup = captureDescriptor('hidden');
                if (!visibilityDescriptorBackup) visibilityDescriptorBackup = captureDescriptor('visibilityState');
                forceHidden(true);
                dispatchVisibility();
                installRafOverride();
                setCSSPaused(true);
                if (typeof window.__lwSuspendAudioContexts__ === 'function') {
                    window.__lwSuspendAudioContexts__();
                }
                if (aggressive) releaseGPUCanvasContexts();
            };

            window.__lwResume__ = function () {
                if (!suspended) return;
                suspended = false;
                if (aggressive) restoreGPUCanvasContexts();
                if (typeof window.__lwResumeAudioContexts__ === 'function') {
                    window.__lwResumeAudioContexts__();
                }
                setCSSPaused(false);
                restoreRaf();
                restoreVisibility();
                dispatchVisibility();
                signalWorkers('resume');
                broadcastToChildFrames('resume');
                resumeTimers();
                // Ratio 1 still reconciles so a pre-suspend throttle wrapper is cleared.
                installRafThrottle(rafThrottleRatio);
                installRafTargetInterval(rafTargetIntervalMs);
            };

            window.__lwSetRafThrottle__ = function (ratio) {
                installRafThrottle(clampRafRatio(ratio));
                broadcastPacingToChildFrames();
            };

            // Milliseconds; 0 means "no ceiling, run at the display rate".
            window.__lwSetRafTargetInterval__ = function (intervalMs) {
                installRafTargetInterval(clampRafInterval(intervalMs));
                broadcastPacingToChildFrames();
            };

            installPacingRequestResponder();
            installFrameLifecycleRelay();
        })();
        """
    }

    // MARK: - CSP Injection

    /// Opt-in meta CSP (paired with scheme-handler header). Permissive for WPE
    /// corpus; off means no CSP from either path.
    static func cspInjection() -> String {
        return """
        (function () {
            if (window.__lwCSPInstalled__) return;
            window.__lwCSPInstalled__ = true;
            var policy = "default-src 'self' https: data: blob: livewallpaper:; " +
                         "script-src 'self' 'unsafe-inline' 'unsafe-eval' https: blob:; " +
                         "style-src 'self' 'unsafe-inline' https:; " +
                         "img-src 'self' https: data: blob:; " +
                         "media-src 'self' https: data: blob: livewallpaper:; " +
                         "font-src 'self' https: data:; " +
                         "connect-src 'self' https: wss: data: blob:; " +
                         "frame-src 'self' https:; " +
                         "object-src 'none'; " +
                         "base-uri 'self';";
            function install() {
                if (!document.head && !document.documentElement) return false;
                if (document.querySelector('meta[http-equiv="Content-Security-Policy"][data-lw-csp]')) return true;
                var meta = document.createElement('meta');
                meta.setAttribute('http-equiv', 'Content-Security-Policy');
                meta.setAttribute('data-lw-csp', '1');
                meta.setAttribute('content', policy);
                var target = document.head || document.documentElement;
                if (target.firstChild) target.insertBefore(meta, target.firstChild);
                else target.appendChild(meta);
                return true;
            }
            if (install()) return;
            try {
                var mo = new MutationObserver(function () {
                    if (install()) mo.disconnect();
                });
                mo.observe(document.documentElement || document, { childList: true });
            } catch (e) {}
        })();
        """
    }

    // MARK: - Frame pacing

    /// Pushes the user's frame-rate ceiling into the lifecycle controller's rAF
    /// gate. JS animation only: `<video>`/`<audio>` decode is owned by the media
    /// element and is never rate-limited from here.
    static func rafTargetFrameInterval(milliseconds: Double) -> String {
        let literal = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            max(milliseconds, 0)
        )
        return """
        if (typeof window.__lwSetRafTargetInterval__ === 'function') { try { window.__lwSetRafTargetInterval__(\(literal)); } catch (e) {} }
        """
    }

    // MARK: - WPE general property notification

    static func wallpaperEngineGeneralProperties(fps: Int) -> String {
        let clampedFPS = min(max(fps, 1), 240)
        return """
        (function () {
            var properties = {"fps":\(clampedFPS)};
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyGeneralProperties === 'function') {
                try {
                    listener.applyGeneralProperties(properties);
                } catch (error) {
                    console.error('Loomscreen failed to apply Wallpaper Engine general properties', error);
                }
            }
        })();
        """
    }
}
