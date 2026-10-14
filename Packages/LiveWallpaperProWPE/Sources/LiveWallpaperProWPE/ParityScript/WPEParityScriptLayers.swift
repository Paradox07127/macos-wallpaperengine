/// Layer wrappers and the dedicated scene callback protocol, inserted into the Prelude's host closure.
/// These fragments share its slots, bindings, current phase, common order and deferred pending set.
enum WPEParityScriptLayers {
    static let layers = #"""
    // Layers, in scene order; `table` keeps every layer the engine knows by its index.
    const table = [], order = [], pending = new Set(), owners = [];
    // __index is immutable. The private cache owns receiver admission; script properties cannot revive it.
    function liveLayer(receiver) { return receiver != null && table[receiver.__index] === receiver; }
    // Identity only: playback remains in the product's existing video source.
    const videoOwners = new WeakMap();
    // Method overloads are a separate protocol from property writes: vectors require their native class,
    // int32 is selected before float, and serialized configuration is passed as text.
    function argument(value, mask) {
      if ((mask & 0x200) && typeof value === 'string') return { type: 0x200, value };
      if ((mask & 2) && typeof value === 'boolean') return { type: 2, value };
      if ((mask & 8) && typeof value === 'number' && Number.isInteger(value) && value >= -2147483648 && value <= 2147483647)
        return { type: 8, value: value | 0 };
      if ((mask & 4) && typeof value === 'number') return { type: 4, value: Math.fround(value) };
      if ((mask & 0x10) && value instanceof Vec2) return { type: 0x10, value };
      if ((mask & 0x20) && value instanceof Vec3) return { type: 0x20, value };
      if ((mask & 0x40) && value instanceof Vec4) return { type: 0x40, value };
      if ((mask & 0x800) && value && order.includes(value)) return { type: 0x800, value };
      if ((mask & 0x400) && value !== null && typeof value === 'object') return { type: 0x400, value: _Internal.stringifyConfig(value) };
      return null;
    }
    const materialWrapper = Symbol('materialWrapper');
    function material(fields) {
      if (fields[materialWrapper]) return fields[materialWrapper];
      const wrapper = Object.create(null);
      Object.defineProperty(fields, materialWrapper, { value: wrapper });
      for (const name of Object.keys(fields)) {
        const f = fields[name];
        Object.defineProperty(wrapper, name, accessor(() => f.slot, { rel: 0, type: f.type, angle: f.angle, readonly: f.readonly }));
        owners[f.slot] = wrapper;
      }
      return wrapper;
    }
    // The material callback compares ASCII paths without slash/dot normalization. Locale/NUL behavior
    // is not covered by H09; do not replace it with Unicode case conversion or object coercion.
    function materialPathSupported(path) {
      if (typeof path !== 'string') return false;
      for (let i = 0; i < path.length; i++) {
        const c = path.charCodeAt(i);
        if (c === 0 || c > 127) return false;
      }
      return true;
    }
    function materialPathEqual(left, right) {
      if (left.length !== right.length) return false;
      for (let i = 0; i < left.length; i++) {
        let a = left.charCodeAt(i), b = right.charCodeAt(i);
        if (a >= 65 && a <= 90) a += 32;
        if (b >= 65 && b <= 90) b += 32;
        if (a !== b) return false;
      }
      return true;
    }
    const EffectProto = {
      executeMaterialFunction(name) {
        if (this == null || owners[this.__s] !== this) return;
        const a = argument(name, 0x200);
        host.executeMaterialFunction(this.__s, a ? a.value : '');
      },
      getMaterial(key) {
        if (!this.__metadataKnown) {
          host.log(1, 'getMaterial is unsupported without resolved effect resource metadata');
          return null;
        }
        const a = argument(key, 8 | 0x200);
        let record;
        if (a && a.type === 8) {
          record = this.__records[a.value];
        } else {
          if (typeof key === 'symbol' || typeof key === 'bigint' || typeof key === 'function') {
            host.log(1, 'getMaterial is unsupported for an unverified argument type');
            return null;
          }
          // H09b/c and the binder's default 0x200 slot: non-int32 inputs select the empty-path
          // default, including missing/null/bool/nonintegral/nonfinite/object inputs. Never String(key).
          const path = a && a.type === 0x200 ? a.value : '';
          if (!materialPathSupported(path)) {
            host.log(1, 'getMaterial is unsupported for NUL or non-ASCII material paths');
            return null;
          }
          for (const candidate of this.__records) {
            if (!candidate.hasMaterial) continue;
            if (path.length === 0) { record = candidate; continue; }
            if (!materialPathSupported(candidate.path)) {
              host.log(1, 'getMaterial is unsupported without verified material path metadata');
              return null;
            }
            if (materialPathEqual(path, candidate.path)) record = candidate;
          }
        }
        // Pure command and out-of-range records return null. A declared missing material is a
        // different case: Windows has a real fallback wrapper, whose state/render consumer is absent here.
        if (!record || !record.hasMaterial) return null;
        const pass = record.pass >= 0 ? this.__passes[record.pass] : null;
        if (!pass) {
          host.log(1, 'getMaterial has no resolved material state consumer; this candidate is unsupported');
          return null;
        }
        return pass[materialWrapper];
      },
      setMaterialProperty(name, value) {
        if (!argument(name, 0x200)) return;
        const a = argument(value, 4 | 8 | 0x10 | 0x20 | 0x40);
        if (!a) return;
        for (const pass of this.__passes) {
          const c = pass[name];
          if (c === undefined) continue;
          if (a.type === 4 || a.type === 8) {
            if (c.type !== 4 && c.type !== 0) continue;
            write(c.slot, c.type, false, c.angle ? Math.fround(a.value * TO_RADIANS) : a.value);
          } else if (a.type === 0x40) { if (c.type === 3) write(c.slot, 3, false, a.value); }
          else if (a.type === 0x20) { if (c.type === 2) write(c.slot, 2, false, a.value); }
          else if (a.type === 0x10) { if (c.type === 1) write(c.slot, 1, false, a.value); }
        }
      },
      getMaterialCount() {
        if (!this.__metadataKnown) host.log(1, 'getMaterialCount is unsupported without resolved effect resource metadata');
        return this.__metadataKnown ? this.__records.length : 0;
      }
    };
    Object.defineProperty(EffectProto, 'visible', accessor(e => e.__s, { rel: 0, type: 6, angle: false }));
    const LayerProto = {
      getParent() { if (!liveLayer(this)) return; return this.__parent < 0 ? null : table[this.__parent]; },
      getChildren() { if (!liveLayer(this)) return; return order.filter(l => l.__parent === this.__index); },
      getEffect(key) {
        if (!liveLayer(this)) return;
        const a = argument(key, 8 | 0x200);
        if (!a) return null;
        if (a.type === 8) return this.__effects[a.value] || null;
        return this.__effects.find(e => e.name === a.value) || null;
      },
      getEffectCount() { return liveLayer(this) ? this.__effects.length : undefined; },
      getVideoTexture() { return liveLayer(this) ? this.__video : undefined; }
    };
    const VideoProto = {
      pause() {
        const index = videoOwners.get(this);
        if (index === undefined) {
          host.log(1, 'video.pause is unsupported for an invalid video wrapper');
          return;
        }
        host.pauseVideoTexture(index);
      }
    };
    // 1401e0530 registers void methods with two native Vec3 (0x20) parameters. They use current local slots.
    function orientLayer(layer, originField, anglesField, camera, target, up, yawOnly) {
      if (!liveLayer(layer)) return;
      const t = argument(target, 0x20), u = argument(up, 0x20);
      if (!t) { host.log(1, 'lookAt and lookAtYaw are unsupported without a native Vec3 target'); return; }
      if (!originField || !anglesField || originField.type !== 2 || anglesField.type !== 2) {
        host.log(1, 'lookAt and lookAtYaw are unsupported without native local transform fields'); return;
      }
      const origin = read(layer.__base + originField.rel, 2, false), point = t.value;
      const axis = u ? u.value : new Vec3(0, 1, 0);
      const angles = host.lookAtAngles(origin.x, origin.y, origin.z, point.x, point.y, point.z,
        axis.x, axis.y, axis.z, camera ? 1 : 0, yawOnly ? 1 : 0);
      if (angles) write(layer.__base + anglesField.rel, 2, false, new Vec3(angles[0], angles[1], angles[2]));
    }
    const protos = host.kinds.map((fields, kind) => {
      const proto = Object.create(LayerProto), instance = {}, video = Object.create(VideoProto);
      const origin = fields.find(f => f.name === 'origin'), angles = fields.find(f => f.name === 'angles');
      proto.lookAt = function (target, up) { orientLayer(this, origin, angles, kind === host.cameraKind, target, up, false); };
      proto.lookAtYaw = function (target, up) { orientLayer(this, origin, angles, kind === host.cameraKind, target, up, true); };
      for (const f of fields) {
        const target = f.owner === 'instance' ? instance : f.owner === 'video' ? video : proto;
        const receiverAllowed = f.owner === 'instance' || f.owner === 'video' ? undefined : liveLayer;
        Object.defineProperty(target, f.name, accessor(o => o.__base, f, receiverAllowed));
      }
      return { proto, instance, video };
    });
    host.addLayer = function (index, kind, base, parent, effects, baseMaterials, hasVideo) {
      const p = protos[kind];
      const layer = hidden(Object.create(p.proto), { __base: base, __parent: parent, __effects: [], __video: null });
      Object.defineProperty(layer, '__index', { value: index });
      if (Object.keys(p.instance).length) Object.defineProperty(layer, 'instance', { value: hidden(Object.create(p.instance), { __base: base }) });
      if (hasVideo && Object.keys(p.video).length) {
        layer.__video = hidden(Object.create(p.video), { __base: base });
        videoOwners.set(layer.__video, index);
      }
      for (const f of host.kinds[kind]) owners[base + f.rel] = f.owner === 'instance' ? layer.instance : f.owner === 'video' ? layer.__video : layer;
      for (const e of effects) {
        const effect = hidden(Object.create(EffectProto), { __s: e.slot, __passes: e.passes,
          __records: e.records, __metadataKnown: e.metadataKnown, name: e.name });
        layer.__effects.push(effect);
        owners[e.slot] = effect;
        for (const pass of e.passes) material(pass);
      }
      for (const pass of baseMaterials) material(pass);
      table[index] = layer;
      order.push(layer);
      return layer;
    };
    host.setString = function (slot, value, values) {
      S[slot] = values ? { value: values.includes(value) ? value : values[0], values } : value;
    };
    host.getString = function (slot) { return read(slot, 5, false); };
    host.setCommonOrder = function (indices) {
      const members = new Set();
      order.length = 0;
      for (const index of indices) {
        const layer = table[index];
        if (layer !== undefined) { order.push(layer); members.add(layer); }
      }
      for (const layer of pending) if (!members.has(layer)) pending.delete(layer);
    };
    """#

    static let scene = #"""
    // 1816372d0 is shared by scene callbacks; generic native-method masks remain separate.
    function sceneScope(name) {
      if (!current) throw new Error(name + ' cannot be called from global scope.');
    }
    function resolveLayer(key) {
      if (typeof key === 'number') return order[key | 0] || null;
      if (typeof key === 'string') {
        const named = order.find(layer => layer.name === key);
        // The original bounded probe excludes pending name hits immediately. Number/wrapper pending
        // resolution is a separate branch; do not infer its admission from this observation.
        if (named) return pending.has(named) ? null : named;
        // Canonical nonnegative decimal IDs are verified. The native C-runtime parser's signed,
        // whitespace, partial and overflow cases need evidence; never substitute general JS coercion.
        if (!/^(0|[1-9][0-9]*)$/.test(key) || key.length > 10
            || (key.length === 10 && key > '4294967295')) {
          host.log(1, 'scene layer ID parsing is unsupported outside verified canonical decimal IDs');
          return null;
        }
        const layer = table[host.layerIndexByID(key)];
        return layer && order.includes(layer) ? layer : null;
      }
      return key && order.includes(key) ? key : null;
    }
    const scene = {
      getLayer(key) {
        sceneScope('getLayer');
        return resolveLayer(key);
      },
      getLayerCount() {
        sceneScope('getLayerCount');
        return order.length - pending.size;
      },
      enumerateLayers() {
        sceneScope('enumerateLayers');
        return order.filter(layer => !pending.has(layer));
      },
      getLayerByID(id) {
        if (!argument(id, 0x200)) {
          host.log(1, 'getLayerByID is unsupported for a non-string ID; native argument behavior is not verified');
          return null;
        }
        const layer = table[host.layerIndexByID(id)];
        if (layer && order.includes(layer)) return layer;
        host.log(1, 'getLayerByID found no exact ID; native missing-ID behavior is not verified');
        return null;
      },
      getLayerIndex(key) {
        sceneScope('getLayerIndex');
        return order.indexOf(resolveLayer(key));
      },
      sortLayer(key, index) {
        sceneScope('sortLayer');
        const layer = resolveLayer(key);
        if (!layer || typeof index !== 'number') return false;
        const position = index | 0;
        if (!host.sortLayer(layer.__index, position)) return false;
        order.splice(order.indexOf(layer), 1);
        // 14018bbd0 interprets the low 32 bits as unsigned, after removing the object itself.
        order.splice(Math.min(position >>> 0, order.length), 0, layer);
        return true;
      },
      getInitialLayerConfig(key) {
        // Native 181634980 deliberately shares destroyLayer's error-name literal.
        sceneScope('destroyLayer');
        const layer = resolveLayer(key);
        const json = layer ? host.initialConfig(layer.__index) : null;
        return json == null ? null : JSON.parse(json);
      },
      createLayer(config) {
        sceneScope('createLayer');
        // 14018ba00.c:25-27: null once the common scene holds 2048 objects, including pending.
        if (order.length > 2047) return null;
        if (modelOwners.has(config)) config = { model: config };
        const a = argument(config, 0x200 | 0x400);
        if (!a) return null;
        const index = host.createLayer(a.type === 0x200 ? JSON.stringify({ image: a.value }) : a.value);
        return index < 0 ? null : table[index];
      },
      destroyLayer(key) {
        sceneScope('destroyLayer');
        const layer = resolveLayer(key);
        if (!layer || !host.canDestroyLayer(layer.__index)) return false;
        pending.add(layer);
        return true;
      }
    };
    """#
}
