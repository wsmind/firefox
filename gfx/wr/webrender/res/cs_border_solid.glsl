/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include shared,rect,border_shared,ellipse,debug

#define DONT_MIX 0
#define MIX_AA 1
#define MIX_NO_AA 2

// For edges, the colors are the same. For corners, these
// are the colors of each edge making up the corner.
flat varying mediump vec4 vColor0;
flat varying mediump vec4 vColor1;

// A point + tangent defining the line where the edge
// transition occurs. Used for corners only.
flat varying highp vec4 vColorLine;

// A boolean indicating that we should be mixing between edge colors.
// Packed in to a vector to work around bug 1630356.
flat varying mediump ivec2 vMixColors;

// xy = Local space position of the clip center.
// zw = Scale the rect origin by this to get the outer
// corner from the segment rectangle.
flat varying highp vec4 vClipCenter_Sign;

// An outer and inner elliptical radii for border
// corner clipping.
flat varying highp vec4 vClipRadii;
flat varying highp vec4 vClipOffsets;

flat varying highp vec3 vShape;
flat varying highp vec2 vWidths;

// Position, scale, and radii of horizontally and vertically adjacent corner clips.
flat varying highp vec4 vHorizontalClipCenter_Sign;
flat varying highp vec2 vHorizontalClipRadii;
flat varying highp vec4 vVerticalClipCenter_Sign;
flat varying highp vec2 vVerticalClipRadii;

// Local space position
varying highp vec2 vPos;

#ifdef WR_VERTEX_SHADER

vec2 get_outer_corner_scale(int segment) {
    vec2 p;

    switch (segment) {
        case SEGMENT_TOP_LEFT:
            p = vec2(0.0, 0.0);
            break;
        case SEGMENT_TOP_RIGHT:
            p = vec2(1.0, 0.0);
            break;
        case SEGMENT_BOTTOM_RIGHT:
            p = vec2(1.0, 1.0);
            break;
        case SEGMENT_BOTTOM_LEFT:
            p = vec2(0.0, 1.0);
            break;
        default:
            // The result is only used for non-default segment cases
            p = vec2(0.0);
            break;
    }

    return p;
}

void main(void) {
    BorderInstanceGpuData data = fetch_gpu_data(aGpuDataAddress);

    int segment = aFlags & 0xff;
    bool do_aa = ((aFlags >> 24) & 0xf0) != 0;

    vec2 outer_scale = get_outer_corner_scale(segment);
    vec2 size = data.rect.zw - data.rect.xy;
    vec2 outer = outer_scale * size;
    vec2 clip_sign = 1.0 - 2.0 * outer_scale;

    int mix_colors;
    switch (segment) {
        case SEGMENT_TOP_LEFT:
        case SEGMENT_TOP_RIGHT:
        case SEGMENT_BOTTOM_RIGHT:
        case SEGMENT_BOTTOM_LEFT: {
            mix_colors = do_aa ? MIX_AA : MIX_NO_AA;
            break;
        }
        default:
            mix_colors = DONT_MIX;
            break;
    }

    vMixColors.x = mix_colors;
    vPos = size * aPosition.xy;

    //data.shape = abs(data.shape);
    //data.shape_offset = vec2(0.0);

    vec2 clipOffset = vec2(0.0);
    if (data.shape < 1.0) {
        clipOffset = max(data.radii, data.widths) + data.shape_offset;
    }

    vColor0 = data.color0;
    vColor1 = data.color1;
    vClipCenter_Sign = vec4(outer + clip_sign * (data.radii + clipOffset), clip_sign);
    vClipRadii = vec4(data.radii, max(data.radii - data.widths, 0.0));
    vShape = vec3(data.shape, clipOffset);
    vWidths = data.widths;
    vColorLine = vec4(outer, data.widths.y * -clip_sign.y, data.widths.x * clip_sign.x);

    if (data.shape != 1.0) {
        float n = exp2(abs(data.shape));
        float q = pow(0.05, n - 1.0);

        // x: dy/dx at (0.05 * data.radii.x, data.radii.y)
        // y: dx/dy at (data.radii.x, 0.05 * data.radii.y)
        vec2 grad = -q * data.radii.yx / max(data.radii.xy, 0.1);

        // normals
        vec2 n1 = normalize(vec2(grad.x, -1.0)) * data.widths.y;
        vec2 n2 = normalize(vec2(-1.0, grad.y)) * data.widths.x;

        if (data.shape >= 0.0) {
            vec2 offset = vec2(n1.x, n2.y); // always negative
            vec2 shrunkRadii = max(data.radii + vec2(n2.x, n1.y) - offset, 0.1);
            vClipRadii = vec4(data.radii, shrunkRadii);
            vClipOffsets = vec4(vec2(0.0), offset);
        } else {
            // Flip x/y for symmetry
            vec2 offset = vec2(n1.y, n2.x);
            vec2 inflatedRadii = max(data.radii + vec2(n2.y, n1.x) - offset, 0.1);
            vClipRadii = vec4(data.radii, inflatedRadii);
            vClipOffsets = vec4(vec2(0.0), offset);
        }
    }

    vec2 horizontal_clip_sign = vec2(-clip_sign.x, clip_sign.y);
    vHorizontalClipCenter_Sign = vec4(aClipParams1.xy +
                                      horizontal_clip_sign * aClipParams1.zw,
                                      horizontal_clip_sign);
    vHorizontalClipRadii = aClipParams1.zw;

    vec2 vertical_clip_sign = vec2(clip_sign.x, -clip_sign.y);
    vVerticalClipCenter_Sign = vec4(aClipParams2.xy +
                                    vertical_clip_sign * aClipParams2.zw,
                                    vertical_clip_sign);
    vVerticalClipRadii = aClipParams2.zw;

    gl_Position = uTransform * vec4(aTaskOrigin + data.rect.xy + vPos, 0.0, 1.0);
}
#endif

#ifdef WR_FRAGMENT_SHADER
float debug_circle(vec2 pos, vec2 center) {
    return length(pos - center) - 10.0;
}

void main(void) {
    float aa_range = compute_aa_range(vPos);
    bool do_aa = vMixColors.x != MIX_NO_AA;

    float mix_factor = 0.0;
    if (vMixColors.x != DONT_MIX) {
        float d_line = distance_to_line(vColorLine.xy, vColorLine.zw, vPos);
        if (do_aa) {
            mix_factor = distance_aa(aa_range, -d_line);
        } else {
            mix_factor = d_line + EPSILON >= 0. ? 1.0 : 0.0;
        }
    }

    //oFragColor = vec4(0.0, 1.0, 0.0, 1.0);

    // Check if inside main corner clip-region
    vec2 clip_relative_pos = vPos - vClipCenter_Sign.xy;
    bool in_clip_region = all(lessThan(vClipCenter_Sign.zw * clip_relative_pos, vec2(0.0)));

    //oFragColor = debug_sdf(length(clip_relative_pos - vShape.yz));

    float d = -1.0;
    float d2 = 1000.0;
    if (in_clip_region) {
        float d_radii_a;
        float d_radii_b;

        if (vShape.x == 1.0) {
            d_radii_a = distance_to_ellipse(clip_relative_pos, vClipRadii.xy);
            d_radii_b = distance_to_ellipse(clip_relative_pos, vClipRadii.zw);
        } else {
            clip_relative_pos = abs(clip_relative_pos) - vShape.yz;
            d_radii_a = distance_to_superellipse(clip_relative_pos - vClipOffsets.xy, vClipRadii.xy, vShape.x);
            d_radii_b = distance_to_superellipse(clip_relative_pos - vClipOffsets.zw, vClipRadii.zw, vShape.x);

            // exclude the straight border part from the subtracted region
            vec2 included_region = vClipRadii.xy - vWidths.xy - clip_relative_pos.xy;
            d_radii_b = max(d_radii_b, -min(included_region.x, included_region.y));

            d2 = min(d2, debug_circle(clip_relative_pos - vClipOffsets.xy, vec2(vClipRadii.x, 0.0)));
            d2 = min(d2, debug_circle(clip_relative_pos - vClipOffsets.xy, vec2(0.0, vClipRadii.y)));
            d2 = min(d2, debug_circle(clip_relative_pos - vClipOffsets.zw, vec2(vClipRadii.z, 0.0)));
            d2 = min(d2, debug_circle(clip_relative_pos - vClipOffsets.zw, vec2(0.0, vClipRadii.w)));
        }

        d = max(d_radii_a, -d_radii_b);

        oFragColor = vec4(1.0, 1.0, 0.0, 1.0);
    }

    // And again for horizontally-adjacent corner
    clip_relative_pos = vPos - vHorizontalClipCenter_Sign.xy;
    in_clip_region = all(lessThan(vHorizontalClipCenter_Sign.zw * clip_relative_pos, vec2(0.0)));
    if (in_clip_region) {
        float d_radii = distance_to_ellipse(clip_relative_pos, vHorizontalClipRadii.xy);
        d = max(d_radii, d);
    }

    // And finally for vertically-adjacent corner
    clip_relative_pos = vPos - vVerticalClipCenter_Sign.xy;
    in_clip_region = all(lessThan(vVerticalClipCenter_Sign.zw * clip_relative_pos, vec2(0.0)));
    if (in_clip_region) {
        float d_radii = distance_to_ellipse(clip_relative_pos, vVerticalClipRadii.xy);
        d = max(d_radii, d);
    }

    float alpha = do_aa ? distance_aa(aa_range, d) : 1.0;
    vec4 color = mix(vColor0, vColor1, mix_factor);
    oFragColor = color * alpha;
    //oFragColor = debug_sdf(d);

    //if (d2 <= 0.0) oFragColor = vec4(1.0, 0.0, 0.0, 1.0);
}
#endif
