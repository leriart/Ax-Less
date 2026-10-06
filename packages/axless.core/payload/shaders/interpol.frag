#version 440

#ifdef GL_ES
precision highp float;
precision mediump int;
#endif

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D currentFrame;
layout(binding = 2) uniform sampler2D previousFrame;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float blendFactor;
    vec2 iResolution;
    int blockSize;
    int searchRadius;
    float motionThreshold;
    int debugMode;
    int isOriginalFrame;
    int frameCounter;
} ubuf;

// -------------------------------------------------------------------
// Ultra‑fast approximate exp() – Refined Quake‑style polynomial
// -------------------------------------------------------------------
float fast_exp(float x) {
    x = clamp(x, -10.0, 10.0);
    float x2 = x * x;
    float x3 = x2 * x;
    float x4 = x2 * x2;
    return 1.0 + x + 0.5 * x2 + 0.16666666 * x3 + 0.04166666 * x4;
}

// -------------------------------------------------------------------
// Utility: clamp integer coordinate
// -------------------------------------------------------------------
ivec2 clampCoord(ivec2 coord, ivec2 minBound, ivec2 maxBound) {
    return ivec2(clamp(coord.x, minBound.x, maxBound.x),
                 clamp(coord.y, minBound.y, maxBound.y));
}

// -------------------------------------------------------------------
// Sample a pixel safely
// -------------------------------------------------------------------
// Sampling takes a UV, not texel coordinates.
//
// This used to texelFetch with ivec2(uv * iResolution), which mixes two
// different ideas: texture() is resolution independent but texelFetch is not,
// and iResolution carries the *effect's* logical size while the frame texture
// is allocated in device pixels. Whenever those differ, the frame is read from
// a sub-rectangle and stretched over the whole effect - a zoom, whose
// magnitude is exactly the device pixel ratio.
//
// ShaderEffectSource.textureSize is not readable from QML here, so the size
// cannot be recovered; sampling by UV sidesteps needing it. The block math
// still uses iResolution, and a wrong value there only shifts which block a
// pixel lands in - block boundaries soften, nothing scales.
vec3 samplePixel(sampler2D tex, vec2 uv) {
    return texture(tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

// -------------------------------------------------------------------
// Optimized SAD using texelFetch (with manual unrolling for speed)
// -------------------------------------------------------------------
float blockSADFast(vec2 centerCurr, vec2 centerPrev, vec2 texel, int bSize) {
    float sad = 0.0;
    int h = bSize / 2;

    for (int y = -h; y < h; ++y) {
        for (int x = -h; x < h; ++x) {
            vec2 offset = vec2(float(x), float(y)) * texel;
            vec3 c = samplePixel(currentFrame, centerCurr + offset);
            vec3 p = samplePixel(previousFrame, centerPrev + offset);
            sad += dot(abs(c - p), vec3(0.299, 0.587, 0.114));
        }
    }
    return sad / float(bSize * bSize);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 res = vec2(ubuf.iResolution);
    vec2 texel = 1.0 / res;

    int bSize = ubuf.blockSize;
    float bs = float(bSize);
    vec2 uvPerBlock = texel * bs;

    // Colour is sampled in UV, so this is exact at any texture size.
    vec3 curr = samplePixel(currentFrame, uv);
    vec3 prev = samplePixel(previousFrame, uv);

    // Block bookkeeping stays in the effect's own units. A mismatch with the
    // frame texture only moves block boundaries, it cannot scale the picture.
    vec2 blockIdx = uv / uvPerBlock;
    vec2 blockCenter = (blockIdx + 0.5) * uvPerBlock;

    vec2 motion = vec2(0.0);
    float bestCost = 1e10;
    bool motionValid = false;

    // Motion search only at block centres, as in the original.
    if (abs(uv.x / uvPerBlock.x - floor(uv.x / uvPerBlock.x + 0.5)) < 0.001
        && abs(uv.y / uvPerBlock.y - floor(uv.y / uvPerBlock.y + 0.5)) < 0.001) {

        float coarseDiff = blockSADFast(blockCenter, blockCenter, texel, bSize);
        if (coarseDiff > ubuf.motionThreshold) {
            int sr = ubuf.searchRadius;
            vec2 coarseTexel = 4.0 * texel;
            for (int dy = -sr; dy <= sr; ++dy) {
                for (int dx = -sr; dx <= sr; ++dx) {
                    vec2 offset = vec2(float(dx), float(dy)) * coarseTexel;
                    vec3 c = textureLod(currentFrame, blockCenter, 2.0).rgb;
                    vec3 p = textureLod(previousFrame, blockCenter + offset, 2.0).rgb;
                    float cost = dot(abs(c - p), vec3(0.299, 0.587, 0.114));
                    if (cost < bestCost) {
                        bestCost = cost;
                        // `offset` is already a UV delta: coarseTexel is 4/res,
                        // one coarse tap equals four full-res pixels. Scaling
                        // it again quadruples the displacement.
                        motion = offset;
                    }
                }
            }
            if (bestCost < 1e9) {
                // Refine at full resolution, +/- 2 texels around the coarse hit.
                for (int dy = -2; dy <= 2; ++dy) {
                    for (int dx = -2; dx <= 2; ++dx) {
                        vec2 offset = motion + vec2(float(dx), float(dy)) * texel;
                        float sad = blockSADFast(blockCenter, blockCenter + offset, texel, bSize);
                        if (sad < bestCost) {
                            bestCost = sad;
                            motion = offset;
                        }
                    }
                }
                motionValid = (bestCost < ubuf.motionThreshold * 2.0);
            }
        }
    }

    vec2 halfTexel = texel * 0.5;
    vec2 warpedUV = uv - motion * ubuf.blendFactor;
    vec2 warpedCurrUV = uv + motion * (1.0 - ubuf.blendFactor);

    // A warp that leaves the frame has nothing to sample. Clamping it to the
    // edge instead drags interior pixels outward and eats a band of the
    // picture, which reads as the frame being inset.
    bool prevIn = all(greaterThanEqual(warpedUV, vec2(0.0)))
              && all(lessThanEqual(warpedUV, vec2(1.0)));
    bool currIn = all(greaterThanEqual(warpedCurrUV, vec2(0.0)))
              && all(lessThanEqual(warpedCurrUV, vec2(1.0)));

    vec3 warpedPrev = samplePixel(previousFrame, clamp(warpedUV, halfTexel, 1.0 - halfTexel));
    vec3 warpedCurr = samplePixel(currentFrame, clamp(warpedCurrUV, halfTexel, 1.0 - halfTexel));

    vec3 blended = mix(prev, curr, ubuf.blendFactor);
    vec3 finalColor;

    if (motionValid && prevIn && currIn) {
        float holeWeight = clamp(dot(abs(curr - warpedPrev), vec3(0.299, 0.587, 0.114)) / 0.3, 0.0, 1.0);
        vec3 motionCompensated = mix(warpedPrev, warpedCurr, holeWeight);
        float confidence = 1.0 - clamp(bestCost / (ubuf.motionThreshold * 3.0), 0.0, 1.0);
        finalColor = mix(blended, motionCompensated, confidence * 0.9);
    } else {
        finalColor = blended;
    }

    if (ubuf.debugMode != 0 && ubuf.isOriginalFrame == 0) {
        finalColor *= vec3(1.0, 1.2, 1.0);
    }

    fragColor = vec4(finalColor, 1.0) * ubuf.qt_Opacity;
}
