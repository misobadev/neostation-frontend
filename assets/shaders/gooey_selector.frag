#version 460 core
#include <flutter/runtime_effect.glsl>

// The grids' liquid selection: up to eight rounded boxes (circles are boxes
// whose half size equals their radius) fused into one body with a smooth
// minimum of their signed distance fields, so shapes close to each other
// join with soft, liquid necks instead of hard overlaps.

#define MAX_SHAPES 8

uniform vec2 uSize;
uniform vec4 uColor;
// How far the smooth minimum reaches: the size of the joins, in pixels.
uniform float uK;
// Half the width of the anti-aliased edge, in pixels.
uniform float uAA;
uniform float uCount;
// When above zero, only a band this wide inside the outline is drawn: the
// liquid as a ring rather than a fill.
uniform float uRing;
// Each shape: centre (xy) and half size (zw), in pixels.
uniform vec4 uBoxes[MAX_SHAPES];
uniform float uRadii[MAX_SHAPES];

out vec4 fragColor;

float roundedBox(vec2 p, vec2 halfSize, float r) {
    r = min(r, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Polynomial smooth minimum.
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void main() {
    vec2 p = FlutterFragCoord().xy;
    float d = 1e5;
    for (int i = 0; i < MAX_SHAPES; i++) {
        if (float(i) >= uCount) break;
        vec4 box = uBoxes[i];
        float shape = roundedBox(p - box.xy, box.zw, uRadii[i]);
        d = (i == 0) ? shape : smin(d, shape, uK);
    }
    float alpha = smoothstep(uAA, -uAA, d);
    if (uRing > 0.0) {
        alpha -= smoothstep(uAA, -uAA, d + uRing);
    }
    fragColor = vec4(uColor.rgb * uColor.a, uColor.a) * alpha;
}
