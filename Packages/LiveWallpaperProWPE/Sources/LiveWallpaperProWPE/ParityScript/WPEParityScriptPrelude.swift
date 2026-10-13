/// `host.floats`: 4 lanes per slot in stored units. `G`: 0 frametime, 1 runtime, 2 timeOfDay, 3-4 canvasSize,
/// 5-6 screenResolution, 7-8 cursor screen, 9-11 cursor world, 12 left button, 13 shortcut gate, 14 dt ms.
enum WPEParityScriptPrelude {
    static let source = #"""
    (function (host) {
    'use strict';
    const global = globalThis;
    let F = host.floats, D = host.dirtyFlags, L = host.dirty;
    const G = host.globals, S = [];
    const DEG = Math.fround(0.017453292), RAD = Math.fround(57.29578);
    host.rebind = function (f, d, l) { F = f; D = d; L = l; };
    function mark(s) { if (D[s] === 0) { D[s] = 1; L[++L[0]] = s; } }
    function read(s, type, angle) {
      const o = s * 4, k = angle ? RAD : 1;
      switch (type) {
      case 0: case 4: return F[o] * k;
      case 1: return new Vec2(F[o] * k, F[o + 1] * k);
      case 2: return new Vec3(F[o] * k, F[o + 1] * k, F[o + 2] * k);
      case 3: return new Vec4(F[o] * k, F[o + 1] * k, F[o + 2] * k, F[o + 3] * k);
      case 5: return S[s];
      case 6: case 8: return F[o] !== 0;
      }
      return undefined;
    }
    function lane(v, key) { return typeof v === 'number' ? v : +v[key]; }
    function write(s, type, angle, v) {
      const o = s * 4;
      if (type === 5) { const t = String(v); if (S[s] !== t) { S[s] = t; mark(s); } return; }
      if (type === 6 || type === 8) { F[o] = v ? 1 : 0; mark(s); return; }
      const k = angle ? DEG : 1;
      if (type === 0) { F[o] = Math.trunc(+v); }
      else if (type === 4) { F[o] = Math.fround(+v) * k; }
      else {
        F[o] = Math.fround(lane(v, 'x')) * k; F[o + 1] = Math.fround(lane(v, 'y')) * k;
        if (type >= 2) F[o + 2] = Math.fround(lane(v, 'z')) * k;
        if (type === 3) F[o + 3] = Math.fround(lane(v, 'w')) * k;
      }
      mark(s);
    }
    function accessor(slotOf, f) {
      return {
        get() { return read(slotOf(this) + f.rel, f.type, f.angle); },
        set(v) { write(slotOf(this) + f.rel, f.type, f.angle, v); },
        enumerable: true, configurable: true
      };
    }
    function hidden(object, values) {
      for (const key in values) Object.defineProperty(object, key, { value: values[key], writable: true });
      return object;
    }

    // Layers, in scene order; `table` keeps every layer the engine knows by its index.
    const table = [], order = [], pending = new Set();
    const EffectProto = {
      setMaterialProperty(name, value) {
        for (const pass of this.__passes) {
          const c = pass[name];
          if (c === undefined) continue;
          if (typeof value === 'number') {
            if (c.type !== 4 && c.type !== 0) continue;
            write(c.slot, 4, false, c.angle ? Math.fround(value) * DEG : value);
          } else if (value instanceof Vec4) { if (c.type === 3) write(c.slot, 3, false, value); }
          else if (value instanceof Vec3) { if (c.type === 2) write(c.slot, 2, false, value); }
          else if (value instanceof Vec2) { if (c.type === 1) write(c.slot, 1, false, value); }
        }
      },
      getMaterialCount() { return this.__passes.length; }
    };
    Object.defineProperty(EffectProto, 'visible', accessor(e => e.__s, { rel: 0, type: 6, angle: false }));
    const LayerProto = {
      getParent() { return this.__parent < 0 ? null : table[this.__parent]; },
      getChildren() { return order.filter(l => l.__parent === this.__index); },
      getEffect(key) {
        if (typeof key === 'number') return this.__effects[key] || null;
        return this.__effects.find(e => e.name === key) || null;
      },
      getEffectCount() { return this.__effects.length; },
      getVideoTexture() { return this.__video; }
    };
    const protos = host.kinds.map(fields => {
      const proto = Object.create(LayerProto), instance = {}, video = {};
      for (const f of fields) {
        const target = f.owner === 'instance' ? instance : f.owner === 'video' ? video : proto;
        Object.defineProperty(target, f.name, accessor(o => o.__base, f));
      }
      return { proto, instance, video };
    });
    host.addLayer = function (index, kind, base, parent, effects) {
      const p = protos[kind];
      const layer = hidden(Object.create(p.proto), { __index: index, __base: base, __parent: parent, __effects: [], __video: null });
      if (Object.keys(p.instance).length) Object.defineProperty(layer, 'instance', { value: hidden(Object.create(p.instance), { __base: base }) });
      if (Object.keys(p.video).length) layer.__video = hidden(Object.create(p.video), { __base: base });
      for (const e of effects) {
        layer.__effects.push(hidden(Object.create(EffectProto), { __s: e.slot, __passes: e.passes, name: e.name }));
      }
      table[index] = layer;
      order.push(layer);
      return layer;
    };
    host.setString = function (slot, value) { S[slot] = value; };
    host.getString = function (slot) { return S[slot]; };

    // Bindings and events.
    const NAMES = host.eventNames;
    const bindings = [];
    let current = null;
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
    host.addBinding = function (fn, name, path, layerIndex, slot, type, angle, vars) {
      const layer = layerIndex < 0 ? null : table[layerIndex];
      const exports = Object.create(null);
      try {
        fn(importer(path), (n, get) => Object.defineProperty(exports, n, { get, enumerable: true }), layer, layer);
      } catch (e) { report({ name }, e); return -1; }
      const b = { name, layer, slot, type, angle, exports, fns: [], bits: 0, dead: false };
      for (let id = 0; id < NAMES.length; id++) {
        const f = NAMES[id] && exports[NAMES[id]];
        if (typeof f === 'function') { b.fns[id] = f; b.bits |= 1 << id; }
      }
      if (vars && exports.scriptProperties) _Internal.updateScriptProperties(exports, vars);
      bindings.push(b);
      return b.bits;
    };
    function call(b, id, args) {
      current = b;
      try { return b.fns[id].apply(undefined, args); } catch (e) { report(b, e); return undefined; } finally { current = null; }
    }
    function valueEvent(b, id) {
      const r = call(b, id, [read(b.slot, b.type, b.angle)]);
      if (r !== undefined && b.slot >= 0) write(b.slot, b.type, b.angle, r);
    }
    host.init = function (first) {
      for (let i = first; i < bindings.length; i++) { const b = bindings[i]; if (b.fns[0] && !b.dead) valueEvent(b, 0); }
    };
    host.tick = function () {
      runTimers(G[14]);
      for (let i = 0; i < bindings.length; i++) { const b = bindings[i]; if (b.fns[1] && !b.dead) valueEvent(b, 1); }
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
      if (id === 6 && p) return [p.event, p.value];
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
        if (!b.fns[id] || b.dead) continue;
        if (target >= 0 && b.layer !== null && b.layer !== table[target]) continue;
        call(b, id, args);
      }
    };
    function flushDestroys() {
      for (const layer of pending) {
        for (const b of bindings) if (b.layer === layer && !b.dead) { if (b.fns[3]) call(b, 3, []); b.dead = true; }
        order.splice(order.indexOf(layer), 1);
        host.destroyed(layer.__index);
      }
      pending.clear();
    }
    host.destroyAll = function () {
      for (const b of bindings) if (b.fns[3] && !b.dead) call(b, 3, []);
      for (const b of bindings) b.dead = true;
    };

    // Timers run on the unwrapped tick clock before the updates.
    const timers = new Map();
    let timerId = 0, now = 0;
    function addTimer(callback, delay, every) {
      const id = ++timerId, ms = Math.max(0, +delay || 0);
      timers.set(id, { callback, due: now + ms, every: every ? ms : -1 });
      return () => { timers.delete(id); };
    }
    function runTimers(ms) {
      now += ms;
      if (timers.size === 0) return;
      for (const [id, t] of timers) {
        if (t.due > now) continue;
        if (t.every < 0) timers.delete(id); else t.due = now + t.every;
        try { t.callback(); } catch (e) { report(null, e); }
      }
    }
    const setTimeout = (callback, delay) => addTimer(callback, delay, false);
    const setInterval = (callback, delay) => addTimer(callback, delay, true);
    const clearTimeout = cancel => { if (typeof cancel === 'function') cancel(); };

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
      registerAudioBuffers(resolution) {
        const start = resolution === 16 ? 0 : resolution === 32 ? 48 : resolution === 64 ? 144 : -1;
        if (start < 0) return null;
        return { left: audio.subarray(start, start + resolution),
          right: audio.subarray(start + resolution, start + 2 * resolution),
          average: audio.subarray(start + 2 * resolution, start + 3 * resolution), resolution };
      },
      isDesktopDevice() { return true; }, isMobileDevice() { return false; },
      isWallpaper() { return true; }, isScreensaver() { return false; }, isRunningInEditor() { return false; },
      isPortrait() { return G[6] > G[5]; }, isLandscape() { return G[5] >= G[6]; },
      openUserShortcut(name) {
        if (G[13] === 0) throw new SyntaxError('openUserShortcut needs a user click');
        G[13] = 0;
        return host.openUserShortcut(String(name));
      },
      setTimeout, setInterval, clearTimeout, clearInterval: clearTimeout
    };
    const input = {
      get cursorScreenPosition() { return new Vec2(G[7], G[8]); },
      get cursorWorldPosition() { return new Vec3(G[9], G[10], G[11]); },
      get cursorLeftDown() { return G[12] !== 0; }
    };
    const scene = {
      getLayer(key) {
        if (typeof key === 'number') return order[key] || null;
        return order.find(l => l.name === key) || null;
      },
      getLayerCount() { return order.length - pending.size; },
      enumerateLayers() { return order.filter(l => !pending.has(l)); },
      getLayerIndex(layer) { return order.indexOf(layer); },
      sortLayer(layer, index) {
        const at = order.indexOf(layer);
        if (at < 0) return;
        order.splice(at, 1);
        order.splice(Math.min(Math.max(0, index | 0), order.length), 0, layer);
      },
      getInitialLayerConfig(layer) {
        const json = layer ? host.initialConfig(layer.__index) : null;
        return json == null ? null : JSON.parse(json);
      },
      createLayer(config) {
        // 14018ba00.c:25-27: null once the scene holds 2048 objects.
        if (order.length > 2047) return null;
        const json = typeof config === 'string' ? JSON.stringify({ image: config }) : _Internal.stringifyConfig(config);
        const index = host.createLayer(json);
        return index < 0 ? null : table[index];
      },
      destroyLayer(layer) {
        if (order.indexOf(layer) < 0) return false;
        pending.add(layer);
        return true;
      }
    };
    for (const f of host.sceneFields) Object.defineProperty(scene, f.name, accessor(() => host.sceneBase, f));
    const stores = [new Map(), new Map()];
    const localStorage = {
      LOCATION_GLOBAL: 0, LOCATION_SCREEN: 1,
      get(key, location) { return stores[location === 1 ? 1 : 0].get(String(key)); },
      set(key, value, location) { stores[location === 1 ? 1 : 0].set(String(key), value); },
      delete(key, location) { return stores[location === 1 ? 1 : 0].delete(String(key)); },
      clear(location) { stores[location === 1 ? 1 : 0].clear(); }
    };
    const log = level => (...args) => host.log(level, args.map(a => typeof a === 'string' ? a : String(a)).join(' '));
    const console = { log: log(0), info: log(0), debug: log(0), warn: log(1), error: log(2) };
    host.setUserProperties = function (json) { engine.userProperties = _Internal.convertUserProperties(json); };
    host.applyScriptProperties = function (index, vars) {
      const b = bindings[index];
      if (b && b.exports.scriptProperties) _Internal.updateScriptProperties(b.exports, vars);
    };
    for (const [key, value] of Object.entries({ engine, input, thisScene: scene, localStorage, console,
      setTimeout, setInterval, clearTimeout, clearInterval: clearTimeout })) {
      Object.defineProperty(global, key, { value, writable: true, configurable: true });
    }
    })
    """#
}
