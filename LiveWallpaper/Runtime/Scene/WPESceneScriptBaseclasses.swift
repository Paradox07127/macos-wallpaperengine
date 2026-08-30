#if !LITE_BUILD
import JavaScriptCore

enum WPESceneScriptBaseclasses {
    static func install(in context: JSContext) {
        _ = context.evaluateScript(Self.prelude)
    }

    private static let prelude = #"""
(function () {
    var root = (typeof globalThis !== "undefined") ? globalThis : this;
    var EPSILON = 1e-8;
    var hasSymbol = typeof Symbol !== "undefined";

    function number(value, fallback) {
        var n = Number(value);
        return isFinite(n) ? n : (fallback || 0);
    }

    function isArrayLike(value) {
        return value && typeof value !== "function" && typeof value.length === "number";
    }

    function component(value, key, index, fallback) {
        if (value == null) { return number(fallback, 0); }
        if (isArrayLike(value)) { return number(value[index], fallback); }
        if (typeof value === "object") {
            if (typeof value[key] !== "undefined") { return number(value[key], fallback); }
            if (typeof value[index] !== "undefined") { return number(value[index], fallback); }
        }
        return number(value, fallback);
    }

    function finiteOr(value, fallback) {
        var n = Number(value);
        return isFinite(n) ? n : fallback;
    }

    function hypot2(x, y) {
        return Math.sqrt(x * x + y * y);
    }

    function hypot3(x, y, z) {
        return Math.sqrt(x * x + y * y + z * z);
    }

    function parseNumbers(value, count) {
        var matches = String(value).match(/[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/g) || [];
        var result = [];
        for (var i = 0; i < count; i += 1) {
            result.push(i < matches.length ? number(matches[i], 0) : 0);
        }
        return result;
    }

    function smoothScalar(edge0, edge1, value) {
        if (edge0 === edge1) { return value < edge0 ? 0 : 1; }
        var t = Math.min(Math.max((value - edge0) / (edge1 - edge0), 0), 1);
        return t * t * (3 - 2 * t);
    }

    function defineGlobal(name, value) {
        try {
            if (typeof root[name] !== "undefined") { return; }
            Object.defineProperty(root, name, {
                configurable: true,
                writable: true,
                value: value
            });
        } catch (e) {
            try { root[name] = value; } catch (ignored) {}
        }
    }

    function installMethod(target, name, value) {
        if (target == null) { return; }
        try {
            if (typeof target[name] === "undefined") { target[name] = value; }
        } catch (e) {}
    }

    class Vec2 {
        constructor(x, y) {
            if (arguments.length === 0) { x = 0; y = 0; }
            else if (arguments.length === 1) {
                if (typeof x === "string") {
                    var values = parseNumbers(x, 2);
                    x = values[0]; y = values[1];
                } else if (isArrayLike(x) || typeof x === "object") {
                    var source = x;
                    x = component(source, "x", 0, 0);
                    y = component(source, "y", 1, 0);
                } else { y = x; }
            }
            this.x = number(x, 0);
            this.y = number(y, 0);
        }
        clone() { return new Vec2(this.x, this.y); }
        copy() { return new Vec2(this.x, this.y); }
        toArray() { return [this.x, this.y]; }
        add(v) { v = new Vec2(v); return new Vec2(this.x + v.x, this.y + v.y); }
        sub(v) { v = new Vec2(v); return new Vec2(this.x - v.x, this.y - v.y); }
        subtract(v) { return this.sub(v); }
        mul(v) { v = new Vec2(v); return new Vec2(this.x * v.x, this.y * v.y); }
        multiply(v) { return this.mul(v); }
        divide(v) {
            v = new Vec2(v);
            var result = new Vec2();
            result.x = this.x / v.x; result.y = this.y / v.y;
            return result;
        }
        scale(s) { s = number(s, 0); return new Vec2(this.x * s, this.y * s); }
        dot(v) { v = new Vec2(v); return this.x * v.x + this.y * v.y; }
        lengthSqr() { return this.dot(this); }
        length() { return hypot2(this.x, this.y); }
        distanceSqr(v) { return this.subtract(v).lengthSqr(); }
        distance(v) { return Math.sqrt(this.distanceSqr(v)); }
        normalize() { var l = this.length(); return l > EPSILON ? this.scale(1 / l) : new Vec2(0); }
        mix(v, t) { v = new Vec2(v); var a = (t instanceof Vec2) ? t : new Vec2(number(t, 0)); return new Vec2(this.x + (v.x - this.x) * a.x, this.y + (v.y - this.y) * a.y); }
        lerp(v, t) { return this.mix(v, t); }
        equals(v) { v = new Vec2(v); return Math.abs(this.x - v.x) <= EPSILON && Math.abs(this.y - v.y) <= EPSILON; }
        isFinite() { return isFinite(this.x) && isFinite(this.y); }
        negate() { return new Vec2(-this.x, -this.y); }
        reflect(normal) { normal = new Vec2(normal); return this.subtract(normal.multiply(2 * this.dot(normal))); }
        min(v) { v = new Vec2(v); return new Vec2(Math.min(this.x, v.x), Math.min(this.y, v.y)); }
        max(v) { v = new Vec2(v); return new Vec2(Math.max(this.x, v.x), Math.max(this.y, v.y)); }
        clamp(minimum, maximum) {
            minimum = new Vec2(minimum); maximum = new Vec2(maximum);
            return new Vec2(
                Math.min(Math.max(this.x, minimum.x), maximum.x),
                Math.min(Math.max(this.y, minimum.y), maximum.y)
            );
        }
        abs() { return new Vec2(Math.abs(this.x), Math.abs(this.y)); }
        sign() { return new Vec2(Math.sign(this.x), Math.sign(this.y)); }
        round() { return new Vec2(Math.round(this.x), Math.round(this.y)); }
        floor() { return new Vec2(Math.floor(this.x), Math.floor(this.y)); }
        ceil() { return new Vec2(Math.ceil(this.x), Math.ceil(this.y)); }
        fract() { return new Vec2(this.x - Math.floor(this.x), this.y - Math.floor(this.y)); }
        mod(v) {
            v = new Vec2(v);
            var result = new Vec2();
            result.x = this.x - v.x * Math.floor(this.x / v.x);
            result.y = this.y - v.y * Math.floor(this.y / v.y);
            return result;
        }
        step(edge) { edge = new Vec2(edge); return new Vec2(this.x < edge.x ? 0 : 1, this.y < edge.y ? 0 : 1); }
        smoothStep(minimum, maximum) {
            minimum = new Vec2(minimum); maximum = new Vec2(maximum);
            return new Vec2(
                smoothScalar(minimum.x, maximum.x, this.x),
                smoothScalar(minimum.y, maximum.y, this.y)
            );
        }
        toString() { return this.x + " " + this.y; }
        static add(a, b) { return new Vec2(a).add(b); }
        static sub(a, b) { return new Vec2(a).sub(b); }
        static mul(a, b) { return new Vec2(a).mul(b); }
        static scale(v, s) { return new Vec2(v).scale(s); }
        static dot(a, b) { return new Vec2(a).dot(b); }
        static lerp(a, b, t) { return new Vec2(a).lerp(b, t); }
    }

    class Vec3 {
        constructor(x, y, z) {
            if (arguments.length === 0) { x = 0; y = 0; z = 0; }
            else if (arguments.length === 1) {
                if (typeof x === "string") {
                    var values = parseNumbers(x, 3);
                    x = values[0]; y = values[1]; z = values[2];
                } else if (isArrayLike(x) || typeof x === "object") {
                    var source = x;
                    x = component(source, "x", 0, 0);
                    y = component(source, "y", 1, 0);
                    z = component(source, "z", 2, 0);
                } else { y = x; z = x; }
            }
            this.x = number(x, 0);
            this.y = number(y, 0);
            this.z = number(z, 0);
        }
        clone() { return new Vec3(this.x, this.y, this.z); }
        copy() { return new Vec3(this.x, this.y, this.z); }
        toArray() { return [this.x, this.y, this.z]; }
        add(v) { v = new Vec3(v); return new Vec3(this.x + v.x, this.y + v.y, this.z + v.z); }
        sub(v) { v = new Vec3(v); return new Vec3(this.x - v.x, this.y - v.y, this.z - v.z); }
        subtract(v) { return this.sub(v); }
        mul(v) { v = new Vec3(v); return new Vec3(this.x * v.x, this.y * v.y, this.z * v.z); }
        multiply(v) { return this.mul(v); }
        divide(v) {
            v = new Vec3(v);
            var result = new Vec3();
            result.x = this.x / v.x; result.y = this.y / v.y; result.z = this.z / v.z;
            return result;
        }
        scale(s) { s = number(s, 0); return new Vec3(this.x * s, this.y * s, this.z * s); }
        dot(v) { v = new Vec3(v); return this.x * v.x + this.y * v.y + this.z * v.z; }
        cross(v) {
            v = new Vec3(v);
            return new Vec3(
                this.y * v.z - this.z * v.y,
                this.z * v.x - this.x * v.z,
                this.x * v.y - this.y * v.x
            );
        }
        lengthSqr() { return this.dot(this); }
        length() { return hypot3(this.x, this.y, this.z); }
        distanceSqr(v) { return this.subtract(v).lengthSqr(); }
        distance(v) { return Math.sqrt(this.distanceSqr(v)); }
        normalize() { var l = this.length(); return l > EPSILON ? this.scale(1 / l) : new Vec3(0); }
        mix(v, t) { v = new Vec3(v); var a = (t instanceof Vec3) ? t : new Vec3(number(t, 0)); return new Vec3(this.x + (v.x - this.x) * a.x, this.y + (v.y - this.y) * a.y, this.z + (v.z - this.z) * a.z); }
        lerp(v, t) { return this.mix(v, t); }
        equals(v) {
            v = new Vec3(v);
            return Math.abs(this.x - v.x) <= EPSILON
                && Math.abs(this.y - v.y) <= EPSILON
                && Math.abs(this.z - v.z) <= EPSILON;
        }
        isFinite() { return isFinite(this.x) && isFinite(this.y) && isFinite(this.z); }
        negate() { return new Vec3(-this.x, -this.y, -this.z); }
        reflect(normal) { normal = new Vec3(normal); return this.subtract(normal.multiply(2 * this.dot(normal))); }
        project(v) {
            v = new Vec3(v);
            var denominator = v.lengthSqr();
            return denominator <= EPSILON ? new Vec3(0) : v.multiply(this.dot(v) / denominator);
        }
        angleBetween(v) {
            v = new Vec3(v);
            var denominator = this.length() * v.length();
            if (denominator <= EPSILON) { return 0; }
            return Math.acos(Math.min(Math.max(this.dot(v) / denominator, -1), 1)) * 180 / Math.PI;
        }
        min(v) { v = new Vec3(v); return new Vec3(Math.min(this.x, v.x), Math.min(this.y, v.y), Math.min(this.z, v.z)); }
        max(v) { v = new Vec3(v); return new Vec3(Math.max(this.x, v.x), Math.max(this.y, v.y), Math.max(this.z, v.z)); }
        clamp(minimum, maximum) {
            minimum = new Vec3(minimum); maximum = new Vec3(maximum);
            return new Vec3(
                Math.min(Math.max(this.x, minimum.x), maximum.x),
                Math.min(Math.max(this.y, minimum.y), maximum.y),
                Math.min(Math.max(this.z, minimum.z), maximum.z)
            );
        }
        abs() { return new Vec3(Math.abs(this.x), Math.abs(this.y), Math.abs(this.z)); }
        sign() { return new Vec3(Math.sign(this.x), Math.sign(this.y), Math.sign(this.z)); }
        round() { return new Vec3(Math.round(this.x), Math.round(this.y), Math.round(this.z)); }
        floor() { return new Vec3(Math.floor(this.x), Math.floor(this.y), Math.floor(this.z)); }
        ceil() { return new Vec3(Math.ceil(this.x), Math.ceil(this.y), Math.ceil(this.z)); }
        fract() { return new Vec3(this.x - Math.floor(this.x), this.y - Math.floor(this.y), this.z - Math.floor(this.z)); }
        mod(v) {
            v = new Vec3(v);
            var result = new Vec3();
            result.x = this.x - v.x * Math.floor(this.x / v.x);
            result.y = this.y - v.y * Math.floor(this.y / v.y);
            result.z = this.z - v.z * Math.floor(this.z / v.z);
            return result;
        }
        step(edge) {
            edge = new Vec3(edge);
            return new Vec3(this.x < edge.x ? 0 : 1, this.y < edge.y ? 0 : 1, this.z < edge.z ? 0 : 1);
        }
        smoothStep(minimum, maximum) {
            minimum = new Vec3(minimum); maximum = new Vec3(maximum);
            return new Vec3(
                smoothScalar(minimum.x, maximum.x, this.x),
                smoothScalar(minimum.y, maximum.y, this.y),
                smoothScalar(minimum.z, maximum.z, this.z)
            );
        }
        toString() { return this.x + " " + this.y + " " + this.z; }
        toSpherical() { return toSpherical(this); }
        refract(normal, eta) { return refract(this, normal, eta); }
        static fromSpherical(r, theta, phi) {
            r = number(r, 0); theta = number(theta, 0) * Math.PI / 180; phi = number(phi, 0) * Math.PI / 180;
            var radial = r * Math.sin(theta);
            return new Vec3(radial * Math.cos(phi), r * Math.cos(theta), radial * Math.sin(phi));
        }
        static add(a, b) { return new Vec3(a).add(b); }
        static sub(a, b) { return new Vec3(a).sub(b); }
        static mul(a, b) { return new Vec3(a).mul(b); }
        static scale(v, s) { return new Vec3(v).scale(s); }
        static dot(a, b) { return new Vec3(a).dot(b); }
        static cross(a, b) { return new Vec3(a).cross(b); }
        static lerp(a, b, t) { return new Vec3(a).lerp(b, t); }
    }

    class Vec4 {
        constructor(x, y, z, w) {
            if (arguments.length === 0) { x = 0; y = 0; z = 0; w = 0; }
            else if (arguments.length === 1) {
                if (typeof x === "string") {
                    var values = parseNumbers(x, 4);
                    x = values[0]; y = values[1]; z = values[2]; w = values[3];
                } else if (isArrayLike(x) || typeof x === "object") {
                    var source = x;
                    x = component(source, "x", 0, 0);
                    y = component(source, "y", 1, 0);
                    z = component(source, "z", 2, 0);
                    w = component(source, "w", 3, 0);
                } else { y = x; z = x; w = x; }
            }
            this.x = number(x, 0);
            this.y = number(y, 0);
            this.z = number(z, 0);
            this.w = number(w, 0);
        }
        clone() { return new Vec4(this.x, this.y, this.z, this.w); }
        copy() { return new Vec4(this.x, this.y, this.z, this.w); }
        toArray() { return [this.x, this.y, this.z, this.w]; }
        add(v) { v = new Vec4(v); return new Vec4(this.x + v.x, this.y + v.y, this.z + v.z, this.w + v.w); }
        sub(v) { v = new Vec4(v); return new Vec4(this.x - v.x, this.y - v.y, this.z - v.z, this.w - v.w); }
        subtract(v) { return this.sub(v); }
        mul(v) { v = new Vec4(v); return new Vec4(this.x * v.x, this.y * v.y, this.z * v.z, this.w * v.w); }
        multiply(v) { return this.mul(v); }
        divide(v) {
            v = new Vec4(v);
            var result = new Vec4();
            result.x = this.x / v.x; result.y = this.y / v.y; result.z = this.z / v.z; result.w = this.w / v.w;
            return result;
        }
        scale(s) { s = number(s, 0); return new Vec4(this.x * s, this.y * s, this.z * s, this.w * s); }
        dot(v) { v = new Vec4(v); return this.x * v.x + this.y * v.y + this.z * v.z + this.w * v.w; }
        lengthSqr() { return this.dot(this); }
        length() { return Math.sqrt(this.dot(this)); }
        distanceSqr(v) { return this.subtract(v).lengthSqr(); }
        distance(v) { return Math.sqrt(this.distanceSqr(v)); }
        normalize() { var l = this.length(); return l > EPSILON ? this.scale(1 / l) : new Vec4(0); }
        mix(v, t) { v = new Vec4(v); var a = (t instanceof Vec4) ? t : new Vec4(number(t, 0)); return new Vec4(this.x + (v.x - this.x) * a.x, this.y + (v.y - this.y) * a.y, this.z + (v.z - this.z) * a.z, this.w + (v.w - this.w) * a.w); }
        lerp(v, t) { return this.mix(v, t); }
        equals(v) {
            v = new Vec4(v);
            return Math.abs(this.x - v.x) <= EPSILON
                && Math.abs(this.y - v.y) <= EPSILON
                && Math.abs(this.z - v.z) <= EPSILON
                && Math.abs(this.w - v.w) <= EPSILON;
        }
        isFinite() { return isFinite(this.x) && isFinite(this.y) && isFinite(this.z) && isFinite(this.w); }
        negate() { return new Vec4(-this.x, -this.y, -this.z, -this.w); }
        reflect(normal) { normal = new Vec4(normal); return this.subtract(normal.multiply(2 * this.dot(normal))); }
        project(v) {
            v = new Vec4(v);
            var denominator = v.lengthSqr();
            return denominator <= EPSILON ? new Vec4(0) : v.multiply(this.dot(v) / denominator);
        }
        min(v) { v = new Vec4(v); return new Vec4(Math.min(this.x, v.x), Math.min(this.y, v.y), Math.min(this.z, v.z), Math.min(this.w, v.w)); }
        max(v) { v = new Vec4(v); return new Vec4(Math.max(this.x, v.x), Math.max(this.y, v.y), Math.max(this.z, v.z), Math.max(this.w, v.w)); }
        clamp(minimum, maximum) {
            minimum = new Vec4(minimum); maximum = new Vec4(maximum);
            return new Vec4(
                Math.min(Math.max(this.x, minimum.x), maximum.x),
                Math.min(Math.max(this.y, minimum.y), maximum.y),
                Math.min(Math.max(this.z, minimum.z), maximum.z),
                Math.min(Math.max(this.w, minimum.w), maximum.w)
            );
        }
        abs() { return new Vec4(Math.abs(this.x), Math.abs(this.y), Math.abs(this.z), Math.abs(this.w)); }
        sign() { return new Vec4(Math.sign(this.x), Math.sign(this.y), Math.sign(this.z), Math.sign(this.w)); }
        round() { return new Vec4(Math.round(this.x), Math.round(this.y), Math.round(this.z), Math.round(this.w)); }
        floor() { return new Vec4(Math.floor(this.x), Math.floor(this.y), Math.floor(this.z), Math.floor(this.w)); }
        ceil() { return new Vec4(Math.ceil(this.x), Math.ceil(this.y), Math.ceil(this.z), Math.ceil(this.w)); }
        fract() { return new Vec4(this.x - Math.floor(this.x), this.y - Math.floor(this.y), this.z - Math.floor(this.z), this.w - Math.floor(this.w)); }
        mod(v) {
            v = new Vec4(v);
            var result = new Vec4();
            result.x = this.x - v.x * Math.floor(this.x / v.x);
            result.y = this.y - v.y * Math.floor(this.y / v.y);
            result.z = this.z - v.z * Math.floor(this.z / v.z);
            result.w = this.w - v.w * Math.floor(this.w / v.w);
            return result;
        }
        step(edge) {
            edge = new Vec4(edge);
            return new Vec4(this.x < edge.x ? 0 : 1, this.y < edge.y ? 0 : 1, this.z < edge.z ? 0 : 1, this.w < edge.w ? 0 : 1);
        }
        smoothStep(minimum, maximum) {
            minimum = new Vec4(minimum); maximum = new Vec4(maximum);
            return new Vec4(
                smoothScalar(minimum.x, maximum.x, this.x),
                smoothScalar(minimum.y, maximum.y, this.y),
                smoothScalar(minimum.z, maximum.z, this.z),
                smoothScalar(minimum.w, maximum.w, this.w)
            );
        }
        toString() { return this.x + " " + this.y + " " + this.z + " " + this.w; }
        static add(a, b) { return new Vec4(a).add(b); }
        static sub(a, b) { return new Vec4(a).sub(b); }
        static mul(a, b) { return new Vec4(a).mul(b); }
        static scale(v, s) { return new Vec4(v).scale(s); }
        static dot(a, b) { return new Vec4(a).dot(b); }
        static lerp(a, b, t) { return new Vec4(a).lerp(b, t); }
    }

    // Official WEColor module. The ESM import itself is stripped before JSC
    // evaluation, so the namespace must be present as a global. Accept object
    // literals as well as Vec3 instances, matching the official rainbow sample.
    function rgb2hsv(rgb) {
        var c = new Vec3(rgb);
        var maximum = Math.max(c.x, c.y, c.z);
        var minimum = Math.min(c.x, c.y, c.z);
        var delta = maximum - minimum;
        var hue = 0;
        if (delta > 0) {
            if (maximum === c.x) {
                hue = ((c.y - c.z) / delta) % 6;
            } else if (maximum === c.y) {
                hue = (c.z - c.x) / delta + 2;
            } else {
                hue = (c.x - c.y) / delta + 4;
            }
            hue /= 6;
            if (hue < 0) { hue += 1; }
        }
        var saturation = maximum === 0 ? 0 : delta / maximum;
        return new Vec3(hue, saturation, maximum);
    }

    function hsv2rgb(hsv) {
        var c = new Vec3(hsv);
        // WPE's documented rainbow example lets hue increase without bounding
        // it. `fract` mirrors the shader helper, wrapping every full turn.
        var hue = c.x - Math.floor(c.x);
        function channel(offset) {
            var p = Math.abs(((hue + offset) - Math.floor(hue + offset)) * 6 - 3);
            var chroma = clamp(p - 1, 0, 1);
            return c.z * mix(1, chroma, c.y);
        }
        return new Vec3(channel(1), channel(2 / 3), channel(1 / 3));
    }

    var WEColor = {
        rgb2hsv: rgb2hsv,
        hsv2rgb: hsv2rgb,
        normalizeColor: function (rgb) { return new Vec3(rgb).scale(1 / 255); },
        expandColor: function (rgb) { return new Vec3(rgb).scale(255); }
    };

    function readMatrix(values, size, identity) {
        if (values && values.m) { values = values.m; }
        var count = size * size;
        var out = identity.slice();
        if (isArrayLike(values) && values.length >= count) {
            for (var i = 0; i < count; i += 1) { out[i] = number(values[i], identity[i]); }
        }
        return out;
    }

    class Mat3 {
        constructor(values) { this.m = readMatrix(values, 3, Mat3.identityArray()); }
        clone() { return new Mat3(this.m); }
        copy() { return new Mat3(this.m); }
        toArray() { return this.m.slice(); }
        translation(position) {
            if (arguments.length > 0) {
                position = new Vec2(position);
                this.m[6] = position.x; this.m[7] = position.y;
                return;
            }
            return new Vec2(this.m[6], this.m[7]);
        }
        angle() { return Math.atan2(this.m[1], this.m[0]) * 180 / Math.PI; }
        add(other) {
            var b = new Mat3(other).m, out = new Array(9);
            for (var i = 0; i < 9; i += 1) { out[i] = this.m[i] + b[i]; }
            return new Mat3(out);
        }
        subtract(other) {
            var b = new Mat3(other).m, out = new Array(9);
            for (var i = 0; i < 9; i += 1) { out[i] = this.m[i] - b[i]; }
            return new Mat3(out);
        }
        multiply(value) {
            if (typeof value === "number") {
                var scaled = new Array(9);
                for (var i = 0; i < 9; i += 1) { scaled[i] = this.m[i] * value; }
                return new Mat3(scaled);
            }
            if (value instanceof Vec3) {
                var v = new Vec3(value), m = this.m;
                return new Vec3(
                    m[0] * v.x + m[3] * v.y + m[6] * v.z,
                    m[1] * v.x + m[4] * v.y + m[7] * v.z,
                    m[2] * v.x + m[5] * v.y + m[8] * v.z
                );
            }
            var a = this.m, b = new Mat3(value).m, out = new Array(9);
            for (var c = 0; c < 3; c += 1) {
                for (var r = 0; r < 3; r += 1) {
                    out[c * 3 + r] = a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2];
                }
            }
            return new Mat3(out);
        }
        translate(v) { return this.multiply(Mat3.fromTranslation(v)); }
        rotate(angle) { return this.multiply(Mat3.fromRotation(angle)); }
        scale(v) { return this.multiply(Mat3.fromScale(v)); }
        transformPoint(v) {
            v = new Vec2(v);
            var result = this.multiply(new Vec3(v.x, v.y, 1));
            return new Vec2(result.x, result.y);
        }
        transformDirection(v) {
            v = new Vec2(v);
            var result = this.multiply(new Vec3(v.x, v.y, 0));
            return new Vec2(result.x, result.y);
        }
        transpose() {
            var m = this.m;
            return new Mat3([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);
        }
        inverse() {
            var m = this.m;
            var b01 = m[8] * m[4] - m[5] * m[7];
            var b11 = -m[8] * m[3] + m[5] * m[6];
            var b21 = m[7] * m[3] - m[4] * m[6];
            var det = m[0] * b01 + m[1] * b11 + m[2] * b21;
            if (Math.abs(det) <= EPSILON) { return Mat3.identity(); }
            det = 1 / det;
            return new Mat3([
                b01 * det,
                (-m[8] * m[1] + m[2] * m[7]) * det,
                (m[5] * m[1] - m[2] * m[4]) * det,
                b11 * det,
                (m[8] * m[0] - m[2] * m[6]) * det,
                (-m[5] * m[0] + m[2] * m[3]) * det,
                b21 * det,
                (-m[7] * m[0] + m[1] * m[6]) * det,
                (m[4] * m[0] - m[1] * m[3]) * det
            ]);
        }
        determinant() {
            var m = this.m;
            return m[0] * (m[4] * m[8] - m[7] * m[5])
                - m[3] * (m[1] * m[8] - m[7] * m[2])
                + m[6] * (m[1] * m[5] - m[4] * m[2]);
        }
        decompose() {
            var m = this.m;
            var sx = hypot2(m[0], m[1]);
            var det = this.determinant();
            var sy = sx > EPSILON ? det / sx : hypot2(m[3], m[4]);
            return {
                translation: new Vec2(m[6], m[7]),
                rotation: sx > EPSILON ? Math.atan2(m[1], m[0]) * 180 / Math.PI : 0,
                scale: new Vec2(sx, sy)
            };
        }
        equals(other) {
            var b = new Mat3(other).m;
            for (var i = 0; i < 9; i += 1) {
                if (Math.abs(this.m[i] - b[i]) > EPSILON) { return false; }
            }
            return true;
        }
        static identityArray() { return [1, 0, 0, 0, 1, 0, 0, 0, 1]; }
        static identity() { return new Mat3(); }
        static multiply(a, b) { return new Mat3(a).multiply(b); }
        static transpose(m) { return new Mat3(m).transpose(); }
        static inverse(m) { return new Mat3(m).inverse(); }
        static fromTranslation(v) {
            v = new Vec2(v);
            return new Mat3([1, 0, 0, 0, 1, 0, v.x, v.y, 1]);
        }
        static fromScale(v) {
            v = new Vec2(v);
            return new Mat3([v.x, 0, 0, 0, v.y, 0, 0, 0, 1]);
        }
        static fromRotation(angle) {
            angle = number(angle, 0) * Math.PI / 180;
            var s = Math.sin(angle), c = Math.cos(angle);
            return new Mat3([c, s, 0, -s, c, 0, 0, 0, 1]);
        }
        static fromBasis(right, up) {
            right = new Vec2(right); up = new Vec2(up);
            return new Mat3([right.x, right.y, 0, up.x, up.y, 0, 0, 0, 1]);
        }
        static fromMat4(mat) {
            var m = new Mat4(mat).m;
            return new Mat3([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]);
        }
        static compose(translation, rotation, scale) {
            return Mat3.fromTranslation(translation).multiply(Mat3.fromRotation(rotation)).multiply(Mat3.fromScale(scale));
        }
    }

    class Mat4 {
        constructor(values) { this.m = readMatrix(values, 4, Mat4.identityArray()); }
        clone() { return new Mat4(this.m); }
        copy() { return new Mat4(this.m); }
        toArray() { return this.m.slice(); }
        translation(position) {
            if (arguments.length > 0) {
                position = new Vec3(position);
                this.m[12] = position.x; this.m[13] = position.y; this.m[14] = position.z;
                return;
            }
            return new Vec3(this.m[12], this.m[13], this.m[14]);
        }
        right() { return new Vec3(this.m[0], this.m[1], this.m[2]); }
        up() { return new Vec3(this.m[4], this.m[5], this.m[6]); }
        forward() { return new Vec3(this.m[8], this.m[9], this.m[10]); }
        add(other) {
            var b = new Mat4(other).m, out = new Array(16);
            for (var i = 0; i < 16; i += 1) { out[i] = this.m[i] + b[i]; }
            return new Mat4(out);
        }
        subtract(other) {
            var b = new Mat4(other).m, out = new Array(16);
            for (var i = 0; i < 16; i += 1) { out[i] = this.m[i] - b[i]; }
            return new Mat4(out);
        }
        multiply(value) {
            if (typeof value === "number") {
                var scaled = new Array(16);
                for (var i = 0; i < 16; i += 1) { scaled[i] = this.m[i] * value; }
                return new Mat4(scaled);
            }
            if (value instanceof Vec4) {
                var v = new Vec4(value), m = this.m;
                return new Vec4(
                    m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12] * v.w,
                    m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13] * v.w,
                    m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14] * v.w,
                    m[3] * v.x + m[7] * v.y + m[11] * v.z + m[15] * v.w
                );
            }
            var a = this.m, b = new Mat4(value).m, out = new Array(16);
            for (var c = 0; c < 4; c += 1) {
                for (var r = 0; r < 4; r += 1) {
                    out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
                }
            }
            return new Mat4(out);
        }
        translate(v) { return this.multiply(Mat4.fromTranslation(v)); }
        rotate(angle, axis) { return this.multiply(Mat4.fromRotation(angle, axis)); }
        scale(v) { return this.multiply(Mat4.fromScale(v)); }
        transformPoint(v) {
            v = new Vec3(v);
            var result = this.multiply(new Vec4(v.x, v.y, v.z, 1));
            return new Vec3(result.x, result.y, result.z);
        }
        transformDirection(v) {
            v = new Vec3(v);
            var result = this.multiply(new Vec4(v.x, v.y, v.z, 0));
            return new Vec3(result.x, result.y, result.z);
        }
        transpose() {
            var m = this.m;
            return new Mat4([
                m[0], m[4], m[8], m[12],
                m[1], m[5], m[9], m[13],
                m[2], m[6], m[10], m[14],
                m[3], m[7], m[11], m[15]
            ]);
        }
        inverse() {
            var a = this.m;
            var b00 = a[0] * a[5] - a[1] * a[4];
            var b01 = a[0] * a[6] - a[2] * a[4];
            var b02 = a[0] * a[7] - a[3] * a[4];
            var b03 = a[1] * a[6] - a[2] * a[5];
            var b04 = a[1] * a[7] - a[3] * a[5];
            var b05 = a[2] * a[7] - a[3] * a[6];
            var b06 = a[8] * a[13] - a[9] * a[12];
            var b07 = a[8] * a[14] - a[10] * a[12];
            var b08 = a[8] * a[15] - a[11] * a[12];
            var b09 = a[9] * a[14] - a[10] * a[13];
            var b10 = a[9] * a[15] - a[11] * a[13];
            var b11 = a[10] * a[15] - a[11] * a[14];
            var det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
            if (Math.abs(det) <= EPSILON) { return Mat4.identity(); }
            det = 1 / det;
            return new Mat4([
                (a[5] * b11 - a[6] * b10 + a[7] * b09) * det,
                (a[2] * b10 - a[1] * b11 - a[3] * b09) * det,
                (a[13] * b05 - a[14] * b04 + a[15] * b03) * det,
                (a[10] * b04 - a[9] * b05 - a[11] * b03) * det,
                (a[6] * b08 - a[4] * b11 - a[7] * b07) * det,
                (a[0] * b11 - a[2] * b08 + a[3] * b07) * det,
                (a[14] * b02 - a[12] * b05 - a[15] * b01) * det,
                (a[8] * b05 - a[10] * b02 + a[11] * b01) * det,
                (a[4] * b10 - a[5] * b08 + a[7] * b06) * det,
                (a[1] * b08 - a[0] * b10 - a[3] * b06) * det,
                (a[12] * b04 - a[13] * b02 + a[15] * b00) * det,
                (a[9] * b02 - a[8] * b04 - a[11] * b00) * det,
                (a[5] * b07 - a[4] * b09 - a[6] * b06) * det,
                (a[0] * b09 - a[1] * b07 + a[2] * b06) * det,
                (a[13] * b01 - a[12] * b03 - a[14] * b00) * det,
                (a[8] * b03 - a[9] * b01 + a[10] * b00) * det
            ]);
        }
        normalMatrix() {
            var m = this.inverse().m;
            return new Mat3([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]).transpose();
        }
        determinant() {
            var a = this.m;
            var b00 = a[0] * a[5] - a[1] * a[4];
            var b01 = a[0] * a[6] - a[2] * a[4];
            var b02 = a[0] * a[7] - a[3] * a[4];
            var b03 = a[1] * a[6] - a[2] * a[5];
            var b04 = a[1] * a[7] - a[3] * a[5];
            var b05 = a[2] * a[7] - a[3] * a[6];
            var b06 = a[8] * a[13] - a[9] * a[12];
            var b07 = a[8] * a[14] - a[10] * a[12];
            var b08 = a[8] * a[15] - a[11] * a[12];
            var b09 = a[9] * a[14] - a[10] * a[13];
            var b10 = a[9] * a[15] - a[11] * a[13];
            var b11 = a[10] * a[15] - a[11] * a[14];
            return b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
        }
        decompose() {
            var m = this.m;
            var sx = hypot3(m[0], m[1], m[2]) || 1;
            var sy = hypot3(m[4], m[5], m[6]) || 1;
            var sz = hypot3(m[8], m[9], m[10]) || 1;
            var r00 = m[0] / sx, r11 = m[5] / sy, r12 = m[9] / sz;
            var r10 = m[1] / sx, r20 = m[2] / sx, r21 = m[6] / sy, r22 = m[10] / sz;
            var ry = Math.asin(clamp(-r20, -1, 1));
            var cy = Math.cos(ry);
            var rx, rz;
            if (Math.abs(cy) > EPSILON) {
                rx = Math.atan2(r21, r22);
                rz = Math.atan2(r10, r00);
            } else {
                rx = Math.atan2(-r12, r11);
                rz = 0;
            }
            return {
                translation: new Vec3(m[12], m[13], m[14]),
                rotation: new Vec3(rx, ry, rz).scale(180 / Math.PI),
                scale: new Vec3(sx, sy, sz)
            };
        }
        extractEuler() { return this.decompose().rotation; }
        equals(other) {
            var b = new Mat4(other).m;
            for (var i = 0; i < 16; i += 1) {
                if (Math.abs(this.m[i] - b[i]) > EPSILON) { return false; }
            }
            return true;
        }
        static identityArray() { return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; }
        static identity() { return new Mat4(); }
        static multiply(a, b) { return new Mat4(a).multiply(b); }
        static transpose(m) { return new Mat4(m).transpose(); }
        static inverse(m) { return new Mat4(m).inverse(); }
        static normalMatrix(m) { return new Mat4(m).normalMatrix(); }
        static decompose(m) { return new Mat4(m).decompose(); }
        static fromTranslation(x, y, z) {
            var v = arguments.length === 1 ? new Vec3(x) : new Vec3(x, y, z);
            return new Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, v.x, v.y, v.z, 1]);
        }
        static fromScale(x, y, z) {
            var v = arguments.length === 1 ? new Vec3(x) : new Vec3(x, y, z);
            return new Mat4([v.x, 0, 0, 0, 0, v.y, 0, 0, 0, 0, v.z, 0, 0, 0, 0, 1]);
        }
        static fromScaling(x, y, z) { return Mat4.fromScale.apply(Mat4, arguments); }
        static fromRotation(angle, axis) {
            angle = number(angle, 0) * Math.PI / 180;
            axis = new Vec3(axis).normalize();
            if (axis.lengthSqr() <= EPSILON) { return Mat4.identity(); }
            var x = axis.x, y = axis.y, z = axis.z;
            var s = Math.sin(angle), c = Math.cos(angle), t = 1 - c;
            return new Mat4([
                t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0,
                t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0,
                t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0,
                0, 0, 0, 1
            ]);
        }
        static fromBasis(right, up, forward) {
            right = new Vec3(right); up = new Vec3(up); forward = new Vec3(forward);
            return new Mat4([
                right.x, right.y, right.z, 0,
                up.x, up.y, up.z, 0,
                forward.x, forward.y, forward.z, 0,
                0, 0, 0, 1
            ]);
        }
        static fromRotationX(r) {
            r = number(r, 0);
            var s = Math.sin(r), c = Math.cos(r);
            return new Mat4([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]);
        }
        static fromRotationY(r) {
            r = number(r, 0);
            var s = Math.sin(r), c = Math.cos(r);
            return new Mat4([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]);
        }
        static fromRotationZ(r) {
            r = number(r, 0);
            var s = Math.sin(r), c = Math.cos(r);
            return new Mat4([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
        }
        static fromRotationXYZ(x, y, z) {
            var v = arguments.length === 1 ? new Vec3(x) : new Vec3(x, y, z);
            return Mat4.fromRotationZ(v.z).multiply(Mat4.fromRotationY(v.y)).multiply(Mat4.fromRotationX(v.x));
        }
        static perspective(fovy, aspect, near, far) {
            fovy = number(fovy, 0); aspect = number(aspect, 1); near = number(near, 0.1); far = number(far, 1000);
            if (Math.abs(aspect) <= EPSILON || Math.abs(near - far) <= EPSILON) { return Mat4.identity(); }
            var f = 1 / Math.tan(fovy / 2);
            if (!isFinite(f)) { return Mat4.identity(); }
            var nf = 1 / (near - far);
            return new Mat4([f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) * nf, -1, 0, 0, (2 * far * near) * nf, 0]);
        }
        static ortho(left, right, bottom, top, near, far) {
            left = number(left, -1); right = number(right, 1); bottom = number(bottom, -1); top = number(top, 1);
            near = number(near, -1); far = number(far, 1);
            if (Math.abs(left - right) <= EPSILON || Math.abs(bottom - top) <= EPSILON || Math.abs(near - far) <= EPSILON) { return Mat4.identity(); }
            var lr = 1 / (left - right), bt = 1 / (bottom - top), nf = 1 / (near - far);
            return new Mat4([-2 * lr, 0, 0, 0, 0, -2 * bt, 0, 0, 0, 0, 2 * nf, 0, (left + right) * lr, (top + bottom) * bt, (far + near) * nf, 1]);
        }
        static lookAt(eye, center, up) {
            eye = new Vec3(eye);
            center = new Vec3(center);
            up = new Vec3(up == null ? [0, 1, 0] : up);
            var z = eye.sub(center).normalize();
            if (z.length() <= EPSILON) { z = new Vec3(0, 0, 1); }
            var x = up.cross(z).normalize();
            if (x.length() <= EPSILON) { x = new Vec3(1, 0, 0); }
            var y = z.cross(x).normalize();
            return new Mat4([
                x.x, y.x, z.x, 0,
                x.y, y.y, z.y, 0,
                x.z, y.z, z.z, 0,
                -x.dot(eye), -y.dot(eye), -z.dot(eye), 1
            ]);
        }
    }

    function mapValue(value, mapper) {
        if (value instanceof Vec2) { return new Vec2(mapper(value.x), mapper(value.y)); }
        if (value instanceof Vec3) { return new Vec3(mapper(value.x), mapper(value.y), mapper(value.z)); }
        if (value instanceof Vec4) { return new Vec4(mapper(value.x), mapper(value.y), mapper(value.z), mapper(value.w)); }
        if (isArrayLike(value)) {
            var out = [];
            for (var i = 0; i < value.length; i += 1) { out.push(mapper(value[i])); }
            return out;
        }
        return mapper(value);
    }

    function clamp(x, minValue, maxValue) {
        minValue = finiteOr(minValue, 0);
        maxValue = finiteOr(maxValue, 1);
        if (minValue > maxValue) { var t = minValue; minValue = maxValue; maxValue = t; }
        return mapValue(x, function (v) { return Math.min(Math.max(number(v, 0), minValue), maxValue); });
    }

    function mix(a, b, t) {
        t = number(t, 0);
        if (a instanceof Vec2) { return new Vec2(a).lerp(b, t); }
        if (a instanceof Vec3) { return new Vec3(a).lerp(b, t); }
        if (a instanceof Vec4) { return new Vec4(a).lerp(b, t); }
        if (isArrayLike(a)) {
            var out = [];
            for (var i = 0; i < a.length; i += 1) { out.push(number(a[i], 0) * (1 - t) + number(b && b[i], 0) * t); }
            return out;
        }
        return number(a, 0) * (1 - t) + number(b, 0) * t;
    }

    function saturate(x) { return clamp(x, 0, 1); }
    function radians(x) { return mapValue(x, function (v) { return number(v, 0) * Math.PI / 180; }); }
    function degrees(x) { return mapValue(x, function (v) { return number(v, 0) * 180 / Math.PI; }); }
    function toSpherical(v) {
        v = new Vec3(v);
        var radius = v.length();
        if (radius <= EPSILON) { return new Vec3(0); }
        return new Vec3(
            radius,
            Math.acos(clamp(v.y / radius, -1, 1)) * 180 / Math.PI,
            Math.atan2(v.z, v.x) * 180 / Math.PI
        );
    }
    function refract(incident, normal, eta) {
        var i = new Vec3(incident);
        var n = new Vec3(normal);
        eta = number(eta, 1);
        var d = i.dot(n);
        var k = 1 - eta * eta * (1 - d * d);
        if (k < 0) { return new Vec3(0); }
        return i.scale(eta).subtract(n.scale(eta * d + Math.sqrt(k)));
    }

    function safeGet(object, property, fallback) {
        if (hasSymbol && property === Symbol.toPrimitive) { return function (hint) { return hint === "string" ? "" : 0; }; }
        if (hasSymbol && property === Symbol.iterator) { return function () { return { next: function () { return { done: true }; } }; }; }
        if (property === "then") { return undefined; }
        if (property === "toString") { return function () { return ""; }; }
        if (property === "valueOf") { return function () { return 0; }; }
        if (property === "toJSON") { return function () { return null; }; }
        if (property === "length") { return 0; }
        if (property === "x" || property === "y" || property === "z" || property === "w" || property === "width" || property === "height" || property === "alpha" || property === "opacity") { return 0; }
        if (property === "visible" || property === "enabled") { return true; }
        try {
            if (property in object) { return object[property]; }
        } catch (e) {}
        return fallback;
    }

    function createSafeCallable(label) {
        var proxy;
        var target = function () { return proxy || target; };
        target.toString = function () { return ""; };
        target.valueOf = function () { return 0; };
        target.toJSON = function () { return null; };
        if (typeof Proxy === "undefined") { return target; }
        proxy = new Proxy(target, {
            get: function (object, property) { return safeGet(object, property, proxy); },
            set: function () { return true; },
            apply: function () { return proxy; },
            construct: function () { return proxy; },
            has: function () { return true; },
            getOwnPropertyDescriptor: function (object, property) {
                var descriptor = Object.getOwnPropertyDescriptor(object, property);
                return descriptor || { configurable: true, enumerable: false, writable: true, value: proxy };
            }
        });
        return proxy;
    }

    function createSafeObject(label) {
        var nested = createSafeCallable(label + ".noop");
        var target = {};
        if (typeof Proxy === "undefined") { return nested; }
        return new Proxy(target, {
            get: function (object, property) { return safeGet(object, property, nested); },
            set: function () { return true; },
            has: function () { return true; },
            getOwnPropertyDescriptor: function (object, property) {
                var descriptor = Object.getOwnPropertyDescriptor(object, property);
                return descriptor || { configurable: true, enumerable: false, writable: true, value: nested };
            }
        });
    }

    var safeScene = createSafeObject("scene");
    var timerStub = function () { return 0; };
    var modelAccessor = createSafeCallable("modelAccessor");
    // Scenes branch on the raw numbers (`state == 1` drives a Play icon), so
    // these stay plain Numbers, per lib.sceneScript.d.ts.
    var mediaPlaybackEvent = Object.freeze({
        PLAYBACK_STOPPED: 0,
        PLAYBACK_PLAYING: 1,
        PLAYBACK_PAUSED: 2
    });

    defineGlobal("Vec2", Vec2);
    defineGlobal("Vec3", Vec3);
    defineGlobal("Vec4", Vec4);
    defineGlobal("Mat3", Mat3);
    defineGlobal("Mat4", Mat4);
    defineGlobal("WEColor", WEColor);
    defineGlobal("clamp", clamp);
    defineGlobal("mix", mix);
    defineGlobal("saturate", saturate);
    defineGlobal("radians", radians);
    defineGlobal("degrees", degrees);
    defineGlobal("toSpherical", toSpherical);
    defineGlobal("refract", refract);
    defineGlobal("setTimeout", timerStub);
    defineGlobal("setInterval", timerStub);
    defineGlobal("clearTimeout", timerStub);
    defineGlobal("clearInterval", timerStub);
    defineGlobal("scene", safeScene);
    defineGlobal("thisScene", safeScene);
    defineGlobal("thisLayer", createSafeObject("thisLayer"));
    defineGlobal("thisProperty", createSafeObject("thisProperty"));
    defineGlobal("IModelData", createSafeCallable("IModelData"));
    defineGlobal("getModel", modelAccessor);
    defineGlobal("getModelData", modelAccessor);
    defineGlobal("getLayer", createSafeCallable("getLayer"));
    defineGlobal("getScene", createSafeCallable("getScene"));
    defineGlobal("MediaPlaybackEvent", mediaPlaybackEvent);

    installMethod(root.engine, "getModel", modelAccessor);
    installMethod(root.engine, "getModelData", modelAccessor);
    installMethod(root.engine, "getLayer", createSafeCallable("engine.getLayer"));
    installMethod(root.engine, "getScene", createSafeCallable("engine.getScene"));
}());
"""#
}
#endif
