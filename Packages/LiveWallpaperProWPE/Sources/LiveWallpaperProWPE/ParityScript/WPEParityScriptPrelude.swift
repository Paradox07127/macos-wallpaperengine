/// `host.floats`: 4 lanes per slot in stored units. `G`: 0 frametime, 1 runtime, 2 timeOfDay, 3-4 canvasSize,
/// 5-6 screenResolution, 7-8 cursor screen, 9-11 cursor world, 12 left button, 13 shortcut gate, 14 dt ms.
enum WPEParityScriptPrelude {
    static let source = #"""
    (function (host) {
    'use strict';
    const global = globalThis;
    const assetIndexOf = Function.prototype.call.bind(String.prototype.indexOf);
    const assetSlice = Function.prototype.call.bind(String.prototype.slice);
    const assetWellFormed = Function.prototype.call.bind(String.prototype.toWellFormed);
    let F = host.floats, I = host.integers, D = host.dirtyFlags, L = host.dirty;
    const G = host.globals, S = [];
    const TO_RADIANS = Math.fround(0.017453292), TO_DEGREES = Math.fround(57.29578);
    host.rebind = function (f, i, d, l) { F = f; I = i; D = d; L = l; };
    function mark(s) { if (D[s] === 0) { D[s] = 1; L[++L[0]] = s; } }
    function read(s, type, angle) {
      if (s < 0) return undefined;
      const o = s * 4;
      switch (type) {
      case 0: return I[s];
      case 4: return angle ? Math.fround(F[o] * TO_DEGREES) : F[o];
      case 1: return new Vec2(F[o], F[o + 1]);
      case 2: {
        const k = angle ? TO_DEGREES : 1;
        return new Vec3(Math.fround(F[o] * k), Math.fround(F[o + 1] * k), Math.fround(F[o + 2] * k));
      }
      case 3: return new Vec4(F[o], F[o + 1], F[o + 2], F[o + 3]);
      case 5: return S[s] && typeof S[s] === 'object' ? S[s].value : S[s];
      case 6: return F[o] !== 0;
      case 8: return F[o];
      }
      return undefined;
    }
    function write(s, type, angle, v) {
      if (s < 0) return;
      const o = s * 4;
      if (type === 5) {
        if (v === null || v === undefined) return;
        const entry = S[s], values = entry && typeof entry === 'object' ? entry.values : null;
        let t = String(v);
        if (values) { t = t.split('\u0000', 1)[0]; if (!values.includes(t)) t = values[0]; }
        if (read(s, type, angle) !== t) { if (values) entry.value = t; else S[s] = t; mark(s); } return;
      }
      if (type === 6 || type === 8) {
        if (typeof v !== 'boolean') return;
        const n = v ? 1 : 0; if (F[o] !== n) { F[o] = n; mark(s); } return;
      }
      if (type === 0) {
        if (typeof v !== 'number') return;
        const n = v | 0; if (I[s] !== n) { I[s] = n; mark(s); } return;
      }
      if (type === 4) {
        if (typeof v !== 'number') return;
        const n = Math.fround(Math.fround(v) * (angle ? TO_RADIANS : 1));
        if (!Object.is(F[o], n)) { F[o] = n; mark(s); } return;
      }
      if (type >= 1 && type <= 3) {
        const scalar = typeof v === 'number', count = type + 1;
        if (!scalar && (v === null || typeof v !== 'object')) return;
        const values = scalar ? Array(count).fill(v) : [v.x, v.y];
        if (!scalar && count > 2) values.push(v.z);
        if (!scalar && count > 3) values.push(v.w);
        if (values.some(n => typeof n !== 'number')) return;
        const k = type === 2 && angle && !scalar ? TO_RADIANS : 1;
        for (let lane = 0; lane < count; lane++) values[lane] = Math.fround(Math.fround(values[lane]) * k);
        let changed = false;
        for (let lane = 0; lane < count; lane++) if (!Object.is(F[o + lane], values[lane])) changed = true;
        if (changed) { for (let lane = 0; lane < count; lane++) F[o + lane] = values[lane]; mark(s); }
      }
    }
    function accessor(slotOf, f, receiverAllowed) {
      const descriptor = {
        get() {
          if (receiverAllowed && !receiverAllowed(this)) return undefined;
          return read(slotOf(this) + f.rel, f.type, f.angle);
        },
        enumerable: true, configurable: true
      };
      if (!f.readonly) descriptor.set = function (v) {
        if (!receiverAllowed || receiverAllowed(this)) write(slotOf(this) + f.rel, f.type, f.angle, v);
      };
      return descriptor;
    }
    function hidden(object, values) {
      for (const key in values) Object.defineProperty(object, key, { value: values[key], writable: true });
      return object;
    }

    """# + WPEParityScriptLayers.layers + "\n" + #"""
    // Bindings and events.
    const NAMES = host.eventNames;
    const bindings = [];
    let current = null;
    let compilingBinding = -1;
    function assetBinding() { return current ? current.index : compilingBinding; }
    let currentEvent = -1;
    function report(b, e) { host.error(b ? b.name : '', String(e && e.stack ? e + '\n' + e.stack : e)); }
    const modules = new Map();
    function importer(path) {
      return function (specifier) {
        const resolved = host.resolve(specifier, path);
        let namespace = modules.get(resolved);
        if (namespace !== undefined) return namespace;
        const fn = host.load(resolved);
        if (typeof fn !== 'function') throw new SyntaxError("Cannot find module '" + specifier + "'");
        namespace = Object.create(null);
        modules.set(resolved, namespace);
        fn(importer(resolved), (name, get) => Object.defineProperty(namespace, name, { get, enumerable: true }), undefined, undefined);
        return namespace;
      };
    }
    host.addBinding = function (fn, name, path, index, layerIndex, slot, type, angle, readonly, vars) {
      const owner = owners[slot];
      const targetLayer = layerIndex < 0 ? null : table[layerIndex];
      const layer = layerIndex < 0 ? owner : targetLayer;
      const exports = Object.create(null);
      const previous = current, previousCompile = compilingBinding, previousEvent = currentEvent;
      current = null;
      compilingBinding = index;
      currentEvent = -1;
      try {
        fn(importer(path), (n, get) => Object.defineProperty(exports, n, { get, enumerable: true }), layer, owner);
      } catch (e) { report({ name }, e); return -1; }
      finally { current = previous; compilingBinding = previousCompile; currentEvent = previousEvent; }
      const b = { name, path, index, layer, targetLayer, owner, slot, type, angle, readonly, exports, fns: [], bits: 0, disabled: 0, dead: false, initialized: false, timers: new Map() };
      for (let id = 0; id < NAMES.length; id++) {
        const f = NAMES[id] && exports[NAMES[id]];
        if (typeof f === 'function') { b.fns[id] = f; b.bits |= 1 << id; }
      }
      if (vars && exports.scriptProperties) _Internal.updateScriptProperties(exports, vars);
      bindings.push(b);
      return b.bits;
    };
    function call(b, id, args) {
      const previous = current;
      const previousEvent = currentEvent;
      current = b;
      currentEvent = id;
      try { return b.fns[id].apply(undefined, args); }
      catch (e) { b.disabled |= 1 << id; report(b, e); return undefined; }
      finally { current = previous; currentEvent = previousEvent; }
    }
    function valueEvent(b, id) {
      const r = call(b, id, [read(b.slot, b.type, b.angle)]);
      if (!b.readonly && r !== undefined && b.slot >= 0) write(b.slot, b.type, b.angle, r);
    }
    host.init = function (first) {
      for (let i = first; i < bindings.length; i++) {
        const b = bindings[i];
        if (b.initialized || b.dead) continue;
        b.initialized = true;
        if (b.fns[0] && !(b.disabled & 1)) valueEvent(b, 0);
      }
    };
    host.tick = function () {
      runTimers(G[0]);
      for (let i = 0; i < bindings.length; i++) { const b = bindings[i]; if (b.fns[1] && !b.dead && !(b.disabled & 2)) valueEvent(b, 1); }
      if (pending.size) flushDestroys();
    };
    function payload(id, json) {
      if (id === 4) return [_Internal.convertUserProperties(json)];
      if (id === 2) { const p = JSON.parse(json); return [new Vec2(p[0], p[1])]; }
      const p = json ? JSON.parse(json) : undefined;
      if (id >= 8 && id <= 13 && p) {
        return [{ worldPosition: new Vec3(p.world[0], p.world[1], p.world[2]),
          localPosition: new Vec3(p.local[0], p.local[1], p.local[2]), hitBox: p.hitBox }];
      }
      if (id === 6) return [p];
      if (id === 17 && p) {
        for (const k in p) if (Array.isArray(p[k]) && p[k].length === 3) p[k] = new Vec3(p[k][0], p[k][1], p[k][2]);
      }
      return [p];
    }
    // `target` -1 reaches every binding; a layer index reaches that layer's bindings and those without a layer.
    host.dispatch = function (id, target, json) {
      const args = payload(id, json);
      for (let i = 0; i < bindings.length; i++) {
        const b = bindings[i];
        if (!b.fns[id] || b.dead || (b.disabled & (1 << id))) continue;
        if (target >= 0 && b.targetLayer !== null && b.targetLayer !== table[target]) continue;
        const result = call(b, id, id === 6 ? [args[0], read(b.slot, b.type, b.angle)] : args);
        if (id === 6 && !b.readonly && result !== undefined) write(b.slot, b.type, b.angle, result);
      }
    };
    function flushDestroys() {
      // 14018b390 copies and clears the pending collection before invoking object destruction.
      // Requests made by destroy callbacks belong to the following sweep.
      const snapshot = Array.from(pending);
      pending.clear();
      for (const layer of snapshot) {
        if (!host.destroyed(layer.__index)) continue;
        // 1401909c0 removes a successfully deleted object from the live pending set as well:
        // an earlier callback may have queued this later member of the same snapshot again.
        pending.delete(layer);
        // Original common membership is already gone when the layer's destroy callback executes.
        order.splice(order.indexOf(layer), 1);
        for (const b of bindings) if (b.targetLayer === layer && !b.dead) { if (b.fns[3] && !(b.disabled & 8)) call(b, 3, []); b.dead = true; b.timers.clear(); }
        // 181620620 and the bounded original receiver probe: a retained JS wrapper does not keep
        // the deleted native object alive. Its typed getters/methods yield undefined, setters no-op.
        delete table[layer.__index];
      }
    }
    host.destroyAll = function () {
      for (const b of bindings) if (b.fns[3] && !b.dead && !(b.disabled & 8)) call(b, 3, []);
      for (const b of bindings) { b.dead = true; b.timers.clear(); }
    };

    // Each script takes its own timer snapshot at its sweep. Stable IDs also keep cancellation safe.
    let timerId = 0;
    function requireScope(name) {
      if (!current) throw new SyntaxError(name + ' cannot be called from global scope.');
    }
    function addTimer(callback, delay, every) {
      requireScope(every ? 'setInterval' : 'setTimeout');
      if (typeof callback !== 'function' || (every && typeof delay !== 'number')) return undefined;
      const seconds = typeof delay === 'number' ? Math.fround(delay / 1000) : 0;
      if (every && seconds <= 0) return undefined;
      const id = ++timerId, owner = current;
      owner.timers.set(id, { callback, remaining: seconds, period: seconds, repeat: every });
      return () => { requireScope('clearTimeout'); return owner.timers.delete(id); };
    }
    function runTimers(dt) {
      for (const b of bindings) {
        if (b.dead || b.timers.size === 0) continue;
        const snapshot = Array.from(b.timers.keys());
        for (const id of snapshot) {
          const t = b.timers.get(id);
          if (!t) continue;
          t.remaining = Math.fround(t.remaining - dt);
          if (t.remaining > 0) continue;
          const previous = current;
          current = b;
          try { t.callback(); } catch (e) { report(b, e); } finally { current = previous; }
          if (!b.timers.has(id)) continue;
          if (t.repeat) t.remaining = t.period; else b.timers.delete(id);
        }
      }
    }
    const setTimeout = (callback, delay) => addTimer(callback, delay, false);
    const setInterval = (callback, delay) => addTimer(callback, delay, true);
    const clearTimeout = () => { requireScope('clearTimeout'); return false; };

    // Host objects.
    const audio = host.audio;
    const engine = {
      AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64,
      get frametime() { return G[0]; },
      get runtime() { return G[1]; },
      get timeOfDay() { return G[2]; },
      get canvasSize() { return new Vec2(G[3], G[4]); },
      get screenResolution() { return new Vec2(G[5], G[6]); },
      userProperties: {},
      registerAsset(path, flag) {
        if (current) throw new SyntaxError('registerAsset can only be called from global scope.');
        if (typeof path !== 'string' || compilingBinding < 0) return undefined;
        const nul = assetIndexOf(path, '\u0000');
        const canonical = assetWellFormed(nul < 0 ? path : assetSlice(path, 0, nul));
        return host.registerAsset(compilingBinding, canonical, typeof flag === 'boolean' ? flag : false) ? canonical : undefined;
      },
      registerAudioBuffers(resolution) {
        if (!argument(resolution, 8)) return null;
        const start = resolution === 16 ? 0 : resolution === 32 ? 48 : resolution === 64 ? 144 : -1;
        if (start < 0) return null;
        host.registerAudio(resolution);
        return { left: audio.subarray(start, start + resolution),
          right: audio.subarray(start + resolution, start + 2 * resolution),
          average: audio.subarray(start + 2 * resolution, start + 3 * resolution), resolution };
      },
      isDesktopDevice() { return true; }, isMobileDevice() { return false; },
      isWallpaper() { return true; }, isScreensaver() { return false; }, isRunningInEditor() { return false; },
      isPortrait() { return G[6] > G[5]; }, isLandscape() { return G[5] >= G[6]; },
      openUserShortcut(name) {
        if (!argument(name, 0x200)) return false;
        if (G[13] === 0) throw new SyntaxError('openUserShortcut needs a user click');
        G[13] = 0;
        return host.openUserShortcut(name);
      },
      setTimeout, setInterval, clearTimeout
    };
    const input = {
      get cursorScreenPosition() { return new Vec2(G[7], G[8]); },
      get cursorWorldPosition() { return new Vec3(G[9], G[10], G[11]); },
      get cursorLeftDown() { return G[12] !== 0; }
    };
    """# + WPEParityScriptLayers.scene + "\n" + WPEParityScriptModels.source + "\n" + #"""
    const general = Object.create(null);
    for (const f of host.sceneFields) {
      Object.defineProperty(scene, f.name, accessor(() => host.sceneBase, f));
      Object.defineProperty(general, f.name, accessor(() => host.sceneBase, f));
      owners[host.sceneBase + f.rel] = general;
    }
    function storageScope(location) { return location === 'global' ? 0 : 1; }
    function storageKey(key) { if (typeof key !== 'string') throw new TypeError('localStorage key must be a string'); return key; }
    function storagePhase() { if (!current) throw new SyntaxError('localStorage cannot be called from global scope.'); }
    // This default store deliberately lives for one engine. A product backend can provide serialized values;
    // cross-reload/screen persistence and the native special-value encoding remain separate contracts.
    const stores = [new Map(), new Map()];
    const localStorage = {
      LOCATION_GLOBAL: 'global', LOCATION_SCREEN: 'screen',
      get(key, location) {
        storagePhase(); storageKey(key);
        const text = host.storageEnabled ? host.storageGet(key, storageScope(location)) : stores[storageScope(location)].get(key);
        return text == null ? undefined : JSON.parse(text);
      },
      set(key, value, location) {
        storagePhase(); storageKey(key);
        const text = JSON.stringify(value);
        if (text === undefined) throw new TypeError('Unsupported localStorage value');
        if (host.storageEnabled) host.storageSet(key, text, storageScope(location));
        else stores[storageScope(location)].set(key, text);
      },
      delete(key, location) {
        storagePhase(); storageKey(key);
        return host.storageEnabled ? host.storageDelete(key, storageScope(location)) : stores[storageScope(location)].delete(key);
      },
      clear(location) {
        storagePhase();
        if (host.storageEnabled) return host.storageClear(storageScope(location));
        stores[storageScope(location)].clear(); return true;
      }
    };
    const log = level => (...args) => host.log(level, args.map(a => typeof a === 'string' ? a : String(a)).join(' '));
    const console = { log: log(0), info: log(0), debug: log(0), warn: log(1), error: log(2) };
    host.setUserProperties = function (json) { engine.userProperties = _Internal.convertUserProperties(json); };
    host.applyScriptProperties = function (index, vars) {
      const b = bindings[index];
      if (b && b.exports.scriptProperties) _Internal.updateScriptProperties(b.exports, vars);
    };
    for (const [key, value] of Object.entries({ engine, input, thisScene: scene, localStorage, console })) {
      Object.defineProperty(global, key, { value, writable: true, configurable: true });
    }
    })
    """#
}
