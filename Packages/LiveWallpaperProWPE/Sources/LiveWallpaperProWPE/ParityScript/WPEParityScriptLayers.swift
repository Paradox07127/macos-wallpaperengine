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
    // Keyed by the layer wrapper so a deleted layer's callbacks are unreachable from the engine.
    let videoEndedCallbacks = new WeakMap();
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
    // IAnimation: one wrapper per host handle. Op numbers are WPEParityScriptEngine.AnimationCommand raw values.
    const animations = [], animationHandles = new WeakMap();
    function getAnimation(slot, layer, name) {
      const handle = host.findAnimation(slot, layer, typeof name === 'string' ? name : '');
      if (handle < 0) return undefined;
      if (!animations[handle]) {
        animations[handle] = Object.create(AnimationProto);
        animationHandles.set(animations[handle], handle);
      }
      return animations[handle];
    }
    function animationCommand(wrapper, op, value = 0) {
      const handle = animationHandles.get(wrapper);
      return handle === undefined ? undefined : host.animationCommand(handle, op, value);
    }
    const AnimationProto = {
      play() { animationCommand(this, 0); },
      pause() { animationCommand(this, 1); },
      stop() { animationCommand(this, 2); },
      isPlaying() { const r = animationCommand(this, 3); return r === undefined ? undefined : r === 1; },
      setFrame(frame) { const a = argument(frame, 4); if (a) animationCommand(this, 4, a.value); },
      getFrame() { return animationCommand(this, 5); },
      get rate() { return animationCommand(this, 6); },
      set rate(value) {
        const n = typeof value === 'number' ? Math.fround(value) : NaN;
        if (Number.isFinite(n)) animationCommand(this, 7, n);
      },
      get fps() { return animationCommand(this, 8); },
      get frameCount() { return animationCommand(this, 9); },
      get duration() { return animationCommand(this, 10); },
      get name() {
        const handle = animationHandles.get(this);
        return handle === undefined ? undefined : host.animationName(handle);
      }
    };
    // ITextureAnimation: one wrapper per image layer index. Op numbers are
    // WPEParityScriptEngine.TextureAnimationCommand raw values; null from the host means no sprite sheet.
    const textureAnimations = [], textureAnimationOwners = new WeakMap();
    function getTextureAnimation(layer) {
      if (textureAnimations[layer.__index]) return textureAnimations[layer.__index];
      if (host.textureAnimationCommand(layer.__index, 9, 0) == null) return null;
      const wrapper = Object.create(TextureAnimationProto);
      textureAnimationOwners.set(wrapper, layer.__index);
      return textureAnimations[layer.__index] = wrapper;
    }
    function textureAnimationCommand(wrapper, op, value = 0) {
      const index = textureAnimationOwners.get(wrapper);
      const r = index === undefined ? null : host.textureAnimationCommand(index, op, value);
      return r == null ? undefined : r;
    }
    const TextureAnimationProto = {
      play() { textureAnimationCommand(this, 0); },
      pause() { textureAnimationCommand(this, 1); },
      stop() { textureAnimationCommand(this, 2); },
      isPlaying() { const r = textureAnimationCommand(this, 3); return r === undefined ? undefined : r === 1; },
      getFrame() { return textureAnimationCommand(this, 4); },
      setFrame(frame) { const a = argument(frame, 8); if (a) textureAnimationCommand(this, 5, a.value); },
      join() { textureAnimationCommand(this, 6); },
      get rate() { return textureAnimationCommand(this, 7); },
      set rate(value) {
        const n = typeof value === 'number' ? Math.fround(value) : NaN;
        if (Number.isFinite(n)) textureAnimationCommand(this, 8, n);
      },
      get frameCount() { return textureAnimationCommand(this, 9); },
      get duration() { return textureAnimationCommand(this, 10); }
    };
    // IAnimationLayer: one wrapper per puppet animation layer. Op numbers are
    // WPEParityScriptEngine.AnimationLayerCommand raw values; null from the host means no such puppet layer.
    const animationLayerOwners = new WeakMap();
    function animationLayerLive(wrapper) {
      const owner = animationLayerOwners.get(wrapper);
      return owner !== undefined && liveLayer(table[owner.layer]);
    }
    function animationLayerCommand(wrapper, op, value = 0) {
      if (!animationLayerLive(wrapper)) return undefined;
      const owner = animationLayerOwners.get(wrapper);
      const r = host.animationLayerCommand(owner.layer, owner.index, op, value);
      return r == null ? undefined : r;
    }
    // Entries whose animation the puppet lacks get no native layer (1401fcc20); the host answers nil for them.
    function puppetAnimationLayers(layer) {
      return layer.__animationLayers.filter(w => animationLayerCommand(w, 7) !== undefined);
    }
    const AnimationLayerProto = {
      play() { animationLayerCommand(this, 0); },
      pause() { animationLayerCommand(this, 1); },
      stop() { animationLayerCommand(this, 2); },
      isPlaying() { const r = animationLayerCommand(this, 3); return r === undefined ? undefined : r === 1; },
      setFrame(frame) { const a = argument(frame, 4); if (a) animationLayerCommand(this, 4, a.value); },
      getFrame() { return animationLayerCommand(this, 5); },
      get fps() { return animationLayerCommand(this, 6); },
      get frameCount() { return animationLayerCommand(this, 7); },
      get duration() { return animationLayerCommand(this, 8); },
      addEndedCallback() { host.log(1, 'addEndedCallback is unsupported without an ended-callback consumer'); }
    };
    for (const f of host.animationLayerFields) {
      Object.defineProperty(AnimationLayerProto, f.name, accessor(o => o.__base, f, animationLayerLive));
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
      // The host maps any of this pass's constant slots to its material pass.
      const first = Object.keys(fields)[0], slot = first === undefined ? -1 : fields[first].slot;
      Object.defineProperty(wrapper, 'getAnimation', { value(name) { return getAnimation(slot, -1, name); } });
      return wrapper;
    }
    // The material callback compares ASCII paths without slash/dot normalization; do not replace it with
    // Unicode case conversion or object coercion.
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
          // The binder's default 0x200 slot: non-int32 inputs select the empty-path
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
      getParent() { if (!liveLayer(this)) return; return this.__parent < 0 ? undefined : table[this.__parent]; },
      // 1401e00b0: an unresolved or pending parent clears the parent without an error.
      setParent(parent, second, third) {
        if (!liveLayer(this)) return;
        if (typeof second === 'number' || typeof second === 'string' || second === true || third === true) {
          host.log(1, 'setParent with an attachment or adjustTransforms is unsupported');
          return;
        }
        let target = resolveLayer(parent) || null;
        if (target && pending.has(target)) target = null;
        const r = host.setParent(this.__index, target ? target.__index : -1);
        if (r == null) return;
        this.__parent = r === 1 && target ? target.__index : -1;
        if (r === 0 && target) throw new Error('Invalid parent configuration.');
      },
      getChildren() { if (!liveLayer(this)) return; return order.filter(l => l.__parent === this.__index); },
      getEffect(key) {
        if (!liveLayer(this)) return;
        const a = argument(key, 8 | 0x200);
        if (!a) return null;
        if (a.type === 8) return this.__effects[a.value] || null;
        return this.__effects.find(e => e.name === a.value) || null;
      },
      getEffectCount() { return liveLayer(this) ? this.__effects.length : undefined; },
      getAnimation(name) { return liveLayer(this) ? getAnimation(-1, this.__index, name) : undefined; },
      getVideoTexture() { return liveLayer(this) ? this.__video : undefined; },
      // 1401df5e0: a zero-argument Mat4 (0x80) copied from vfunc+0x80; the host gives 16 column-major floats.
      getTransformMatrix() {
        if (!liveLayer(this)) return;
        const m = host.transformMatrix(this.__index);
        return m ? new Mat4(m) : undefined;
      }
    };
    const VideoProto = {
      pause() {
        const index = videoOwners.get(this);
        if (index === undefined) {
          host.log(1, 'video.pause is unsupported for an invalid video wrapper');
          return;
        }
        host.pauseVideoTexture(index);
      },
      play() { videoCommand(this, 'play', 0, 0); },
      stop() { videoCommand(this, 'stop', 1, 0); },
      isPlaying() { return videoCommand(this, 'isPlaying', 2, 0) === 1; },
      getCurrentTime() {
        const time = videoCommand(this, 'getCurrentTime', 3, 0);
        return typeof time === 'number' ? Math.fround(time) : 0;
      },
      setCurrentTime(time) {
        const a = argument(time, 4);
        if (a && Number.isFinite(a.value)) videoCommand(this, 'setCurrentTime', 4, a.value);
      },
      addEndedCallback(callback) {
        const index = videoOwners.get(this);
        if (index === undefined) {
          host.log(1, 'video.addEndedCallback is unsupported for an invalid video wrapper');
          return;
        }
        const layer = table[index];
        if (typeof callback !== 'function' || !liveLayer(layer)) return;
        let list = videoEndedCallbacks.get(layer);
        if (!list) videoEndedCallbacks.set(layer, list = []);
        list.push({ owner: current, callback });
      }
    };
    host.videoEnded = function (index) {
      const layer = table[index];
      const list = liveLayer(layer) ? videoEndedCallbacks.get(layer) : undefined;
      if (!list) return;
      for (const entry of list.slice()) {
        const b = entry.owner;
        if (b && b.dead) continue;
        const previous = current;
        current = b;
        const previousAliases = b && b.aliases ? b.aliases(b.layer, b.owner, true) : null;
        try { entry.callback(); } catch (e) { report(b, e); } finally {
          if (previousAliases) b.aliases(previousAliases[0], previousAliases[1], false);
          current = previous;
        }
      }
      videoEndedCallbacks.set(layer, list.filter(entry => !(entry.owner && entry.owner.dead)));
    };
    host.clearVideoEnded = function () { videoEndedCallbacks = new WeakMap(); };
    // Command numbers are WPEParityScriptEngine.VideoCommand raw values. A missing consumer yields undefined.
    function videoCommand(video, name, command, value) {
      const index = videoOwners.get(video);
      if (index === undefined) {
        host.log(1, 'video.' + name + ' is unsupported for an invalid video wrapper');
        return undefined;
      }
      return host.videoTextureCommand(index, command, value);
    }
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
    // IImageLayer bones and blend shapes (140211070.c:332-777). Op numbers are WPEParityScriptEngine.PuppetCommand
    // raw values; the host answers null without a puppet or for an unresolved key, which reads as undefined.
    function puppetCommand(layer, op, key, mask, values = []) {
      if (!liveLayer(layer)) return;
      const a = mask ? argument(key, mask) : { value: 0 };
      const r = a ? host.puppetCommand(layer.__index, op, a.value, values) : null;
      return r == null ? undefined : r;
    }
    const boneKey = 8 | 0x200;
    const puppetMethods = {
      getBoneCount() { const r = puppetCommand(this, 0); return r && r[0]; },
      getBoneIndex(name) { const r = puppetCommand(this, 1, name, 0x200); return r && r[0]; },
      getBoneParentIndex(child) { const r = puppetCommand(this, 2, child, boneKey); return r && r[0]; },
      getBoneTransform(bone) { const r = puppetCommand(this, 3, bone, boneKey); return r && new Mat4(r); },
      setBoneTransform(bone, transform) {
        if (transform instanceof Mat4) puppetCommand(this, 4, bone, boneKey, transform.m);
      },
      getLocalBoneTransform(bone) { const r = puppetCommand(this, 5, bone, boneKey); return r && new Mat4(r); },
      setLocalBoneTransform(bone, transform) {
        if (transform instanceof Mat4) puppetCommand(this, 6, bone, boneKey, transform.m);
      },
      getLocalBoneAngles(bone) { const r = puppetCommand(this, 7, bone, boneKey); return r && new Vec3(r[0], r[1], r[2]); },
      setLocalBoneAngles(bone, angles) {
        const a = argument(angles, 0x20);
        if (a) puppetCommand(this, 8, bone, boneKey, [a.value.x, a.value.y, a.value.z]);
      },
      getLocalBoneOrigin(bone) { const r = puppetCommand(this, 9, bone, boneKey); return r && new Vec3(r[0], r[1], r[2]); },
      setLocalBoneOrigin(bone, origin) {
        const a = argument(origin, 0x20);
        if (a) puppetCommand(this, 10, bone, boneKey, [a.value.x, a.value.y, a.value.z]);
      },
      getBlendShapeIndex(name) { const r = puppetCommand(this, 11, name, 0x200); return r && r[0]; },
      getBlendShapeWeight(shape) { const r = puppetCommand(this, 12, shape, boneKey); return r && r[0]; },
      setBlendShapeWeight(shape, weight) {
        const a = argument(weight, 4);
        if (a) puppetCommand(this, 13, shape, boneKey, [a.value]);
      },
      // 140210990.c and 140210e10 feed the bone physics state, which nothing here simulates: accepted and dropped.
      applyBonePhysicsImpulse() { host.log(1, 'applyBonePhysicsImpulse is ignored without a bone physics simulation'); },
      resetBonePhysicsSimulation() { host.log(1, 'resetBonePhysicsSimulation is ignored without a bone physics simulation'); }
    };
    const protos = host.kinds.map((fields, kind) => {
      const proto = Object.create(LayerProto), instance = {}, video = Object.create(VideoProto);
      const origin = fields.find(f => f.name === 'origin'), angles = fields.find(f => f.name === 'angles');
      if (kind === host.soundKind) {
        proto.play = function () { if (liveLayer(this)) host.soundCommand(this.__index, 0); };
        proto.stop = function () { if (liveLayer(this)) host.soundCommand(this.__index, 1); };
        proto.pause = function () { if (liveLayer(this)) host.soundCommand(this.__index, 2); };
        proto.isPlaying = function () { return liveLayer(this) ? host.soundCommand(this.__index, 3) : undefined; };
      }
      // IParticleSystem: op numbers are WPEParityScriptEngine.ParticleCommand raw values.
      if (kind === host.particleKind) {
        proto.play = function () { if (liveLayer(this)) host.particleCommand(this.__index, 0, 0); };
        proto.pause = function () { if (liveLayer(this)) host.particleCommand(this.__index, 1, 0); };
        proto.stop = function () { if (liveLayer(this)) host.particleCommand(this.__index, 2, 0); };
        proto.isPlaying = function () {
          if (!liveLayer(this)) return;
          const r = host.particleCommand(this.__index, 3, 0);
          return r == null ? undefined : r === 1;
        };
        proto.emitParticles = function (count) {
          if (!liveLayer(this)) return;
          const a = argument(count, 8);
          if (!a) {
            host.log(1, 'emitParticles is unsupported for a non-int32 count; native argument behavior is not verified');
            return;
          }
          host.particleCommand(this.__index, 4, a.value);
        };
      }
      if (kind === host.imageKind) {
        Object.assign(proto, puppetMethods);
        proto.getTextureAnimation = function () { return liveLayer(this) ? getTextureAnimation(this) : undefined; };
        proto.getAnimationLayerCount = function () { return liveLayer(this) ? puppetAnimationLayers(this).length : undefined; };
        proto.getAnimationLayer = function (key) {
          if (!liveLayer(this)) return;
          const a = argument(key, 8 | 0x200);
          if (!a) return undefined;
          const list = puppetAnimationLayers(this);
          if (a.type === 8) return list[a.value];
          let found;
          if (a.value !== '') for (const w of list) if (w.name === a.value) found = w;
          return found;
        };
      }
      proto.lookAt = function (target, up) { orientLayer(this, origin, angles, kind === host.cameraKind, target, up, false); };
      proto.lookAtYaw = function (target, up) { orientLayer(this, origin, angles, kind === host.cameraKind, target, up, true); };
      for (const f of fields) {
        const target = f.owner === 'instance' ? instance : f.owner === 'video' ? video : proto;
        const receiverAllowed = f.owner === 'instance' || f.owner === 'video' ? undefined : liveLayer;
        Object.defineProperty(target, f.name, accessor(o => o.__base, f, receiverAllowed));
      }
      return { proto, instance, video };
    });
    host.addLayer = function (index, kind, base, parent, effects, baseMaterials, hasVideo, animationLayers) {
      const p = protos[kind];
      const layer = hidden(Object.create(p.proto), { __base: base, __parent: parent, __effects: [], __video: null,
        __animationLayers: [] });
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
      for (const a of animationLayers) {
        const wrapper = hidden(Object.create(AnimationLayerProto), { __base: a.base });
        animationLayerOwners.set(wrapper, { layer: index, index: a.index });
        for (const f of host.animationLayerFields) owners[a.base + f.rel] = wrapper;
        layer.__animationLayers.push(wrapper);
      }
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
        // No leading decimal digit: the native ID parse yields 0, and no layer has ID 0.
        if (!/^[ \t\n\v\f\r]*[+-]?[0-9]/.test(key)) return null;
        // Only canonical nonnegative decimal IDs are supported; never substitute general JS coercion.
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
    const solidLayer = 'models/util/solidlayer.json';
    // 181633290.c:552-635: the first directory (case-sensitive) and lowercase extension pick the factory key.
    function createLayerPath(value) {
      // 181633290.c:384-406 strips leading separators; 181653460.c:187-384 moves the path under __workshopId.
      let path = value.replace(/^[\/\\]+/, '');
      const segments = path.split(/[\/\\]/);
      const file = segments[segments.length - 1];
      const extension = file.includes('.') ? file.slice(file.lastIndexOf('.')).toLowerCase() : '';
      const first = segments[0];
      const key = first === 'models' ? (extension === '.json' ? 'image' : 'model') : first === 'particles' ? 'particle'
        : first === 'materials' ? 'sprite' : first === 'sounds' ? 'sound' : null;
      if (key === null) return null;
      if (current.workshopId) {
        const parts = path.split(/[\/\\]+/);
        if (parts[1] === 'workshop') parts.splice(1, 2);
        path = [parts[0], 'workshop', current.workshopId, ...parts.slice(1)].join('/')
          .replace(/\\/g, '/').replace(/\/{2,}/g, '/');
      }
      return JSON.stringify({ [key]: path });
    }
    function createLayerConfig(args) {
      // 181633290.c:771-780
      if (args.length !== 1) return JSON.stringify({ image: solidLayer });
      let config = args[0];
      if (modelOwners.has(config)) config = { model: config };
      let text;
      if (typeof config === 'string') {
        // 181633290.c:308-382: a string is a JSON object first, a path otherwise.
        let parsed = null;
        try { parsed = JSON.parse(config); } catch (error) { parsed = null; }
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return createLayerPath(config);
        text = config;
      } else if (config !== null && typeof config === 'object') {
        text = _Internal.stringifyConfig(config);
      } else {
        return null;
      }
      if (typeof text !== 'string') return null;
      const object = JSON.parse(text);
      // 181633290.c:225-282: a colour without any class key is a solid layer.
      const classes = ['model', 'particle', 'sprite', 'image', 'text', 'light', 'sound', 'camera'];
      if (object !== null && typeof object === 'object' && 'color' in object && !classes.some(key => key in object)) {
        object.image = solidLayer;
        return JSON.stringify(object);
      }
      return text;
    }
    const scene = {
      getAnimation(name) { return getAnimation(-1, -2, name); },
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
      createLayer(...args) {
        sceneScope('createLayer');
        // 14018ba00.c:25-27: null once the common scene holds 2048 objects, including pending.
        if (order.length > 2047) return null;
        const text = createLayerConfig(args);
        if (text === null) return null;
        const index = host.createLayer(text);
        return index < 0 ? null : table[index];
      },
      destroyLayer(key) {
        sceneScope('destroyLayer');
        const layer = resolveLayer(key);
        if (!layer || !host.canDestroyLayer(layer.__index)) return false;
        pending.add(layer);
        return true;
      },
      getCameraTransforms() {
        const t = host.cameraTransforms();
        if (!t) return undefined;
        return { eye: new Vec3(t[0], t[1], t[2]), center: new Vec3(t[3], t[4], t[5]), up: new Vec3(t[6], t[7], t[8]),
          zoom: t[9] };
      },
      // Members that fail the Vec3 or float argument check pass as null, which leaves that root value alone.
      setCameraTransforms(t) {
        if (t === null || typeof t !== 'object') return;
        const vector = v => { const a = argument(v, 0x20); return a ? [a.value.x, a.value.y, a.value.z] : null; };
        const zoom = argument(t.zoom, 4);
        host.setCameraTransforms(vector(t.eye), vector(t.center), vector(t.up), zoom ? zoom.value : null);
      }
    };
    """#
}
