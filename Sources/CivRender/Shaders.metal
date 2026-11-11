#ifndef EVOLVING_SHADERS_H
#define EVOLVING_SHADERS_H

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared layouts. These mirror the Swift structs exactly; every member is
// 16-byte aligned on both sides so there is no padding guesswork.
// ---------------------------------------------------------------------------

struct FrameUniforms {
    float4x4 viewProjection;
    float4x4 lightViewProjection;
    float4x4 inverseViewProjection;
    float4   cameraAndTime;   // xyz = camera position, w = seconds since start
    float4   sunAndPad;       // xyz = direction *towards* the sun, w = sun elevation 0..1
    float4   night;           // x = night, y = season, z = fog, w = weather
    float4   shadow;          // x = texel size, y = normal offset, z = depth bias, w = unused
    float4x4 closeLightProjection;
    float4   closeShadow;     // same layout as shadow, for the town-scale cascade
};

struct InstanceData {
    float4x4 model;
    float4   color;           // rgb = tint, a = emissive weight
    float4   material;        // x = material id
};

struct Vertex {
    float3 position;
    float3 normal;
    float4 color;             // rgb albedo, a = extra scalar
    float2 uv;                // atlas coordinates for imported assets
};

struct MeshVaryings {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float3 color;
    float  emissive;
    float  extra;
    float  local;     // object-space height, for base contact shading
    float  material;  // per-instance surface material id
    float  plate;     // sign atlas row
    float  bias;      // traffic density bias
    float2 uv;        // atlas coordinates for imported assets
};

vertex MeshVaryings meshVertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device Vertex *vertices  [[buffer(0)]],
                               constant FrameUniforms &u      [[buffer(1)]],
                               const device InstanceData *instances [[buffer(2)]])
{
    Vertex v = vertices[vid];
    InstanceData inst = instances[iid];

    float4 world = inst.model * float4(v.position, 1.0);

    MeshVaryings out;
    out.position = u.viewProjection * world;
    out.world    = world.xyz;
    out.normal   = normalize((inst.model * float4(v.normal, 0.0)).xyz);
    out.color    = v.color.rgb * inst.color.rgb;
    out.emissive = inst.color.a;
    out.extra    = v.color.a;
    out.local    = v.position.y;
    out.material = inst.material.x;
    out.plate = inst.material.y;
    out.bias = inst.material.z;
    out.uv = v.uv;
    return out;
}

// Cheap ACES-ish filmic curve.
static inline float3 tonemap(float3 x)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

static inline float hash21(float2 p)
{
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float valueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// Soft, slowly drifting cloud shadows. Cheap enough to evaluate per pixel and
/// it is the main thing that makes the island feel alive while nothing grows.
static inline float cloudShadow(float2 world, float t)
{
    float2 p = world * 1.55 + float2(t * 0.0060, t * 0.0026);
    float n = valueNoise(p) * 0.62 + valueNoise(p * 2.31 + 7.0) * 0.38;
    return smoothstep(0.52, 0.80, n);
}

/// Occasional double-blink lightning during heavy weather.
static inline float lightningFlash(float t, float weather)
{
    if (weather < 0.45) return 0.0;

    float period = 9.0;
    float cycle = floor(t / period);
    float phase = fract(t / period);
    float gate = step(0.35, fract(sin(cycle * 12.9898) * 43758.5453));

    float a = smoothstep(0.0, 0.012, phase) * (1.0 - smoothstep(0.02, 0.055, phase));
    float b = smoothstep(0.085, 0.095, phase) * (1.0 - smoothstep(0.10, 0.14, phase));
    return saturate(a + b * 0.65) * gate * smoothstep(0.45, 0.85, weather);
}

static inline float shadowFactor(texture2d<float> map, sampler smp,
                                 float4x4 lightVP, float4 shadow,
                                 float3 world, float3 n, float3 sun,
                                 float spread)
{
    float4 lp = lightVP * float4(world + n * shadow.y, 1.0);
    float3 p = lp.xyz / lp.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;

    float bias = shadow.z * (1.0 - max(dot(n, sun), 0.0) * 0.85);
    float depth = p.z;
    float sum = 0.0;
    float2 texel = float2(shadow.x, shadow.x) * spread;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float d = map.sample(smp, uv + float2(x, y) * texel).r;
            sum += (depth - bias <= d) ? 1.0 : 0.0;
        }
    }
    return sum / 9.0;
}

static inline float3 skyRadiance(float3 ray, constant FrameUniforms &u)
{
    float day = saturate(u.sunAndPad.w * 3.0);
    float weather = u.night.w;

    float3 zenith  = mix(float3(0.015, 0.025, 0.07), float3(0.13, 0.30, 0.60), day);
    float3 horizon = mix(float3(0.04, 0.06, 0.13), float3(0.66, 0.77, 0.88), day);
    float3 col = mix(horizon, zenith, pow(saturate(ray.y), 0.60));

    float3 overcast = mix(float3(0.10, 0.12, 0.15), float3(0.36, 0.40, 0.44), day);
    col = mix(col, overcast, weather * 0.85);

    if (ray.y > 0.02) {
        float2 cp = ray.xz / max(ray.y, 0.10) * 0.16
                  + float2(u.cameraAndTime.w * 0.0030, u.cameraAndTime.w * 0.0012);
        float cn = valueNoise(cp) * 0.55
                 + valueNoise(cp * 2.3 + 3.7) * 0.30
                 + valueNoise(cp * 4.7 + 9.1) * 0.15;
        float cover = smoothstep(0.42, 0.70, cn) * smoothstep(0.0, 0.05, ray.y);
        float3 cloudLit = mix(float3(0.10, 0.12, 0.17), float3(0.94, 0.95, 0.96), day);
        float3 cloudShade = mix(float3(0.05, 0.06, 0.09), float3(0.56, 0.59, 0.64), day);
        col = mix(col, mix(cloudShade, cloudLit, saturate(day)), cover * (0.55 + 0.30 * weather));
    }
    return col;
}

static inline float3 skyColour(float sunElevation)
{
    float day = saturate(sunElevation);
    float3 zenith  = mix(float3(0.03, 0.05, 0.12), float3(0.16, 0.33, 0.62), day);
    float3 horizon = mix(float3(0.06, 0.08, 0.16), float3(0.68, 0.78, 0.88), day);
    return mix(horizon, zenith, 0.55);
}

fragment float4 meshFragment(MeshVaryings in [[stage_in]],
                             constant FrameUniforms &u [[buffer(1)]],
                             texture2d<float> shadowMap [[texture(1)]],
                             texture2d<float> albedoTexture [[texture(2)]],
                             texture2d<float> normalTexture [[texture(3)]],
                             texture2d<float> closeShadowMap [[texture(4)]],
                             texture2d<float> roughnessTexture [[texture(5)]],
                             texture2d<float> groundTexture [[texture(6)]],
                             texture2d<float> groundNormalTexture [[texture(7)]],
                             texture2d<float> rockTexture [[texture(8)]],
                             texture2d<float> rockNormalTexture [[texture(9)]],
                             texture2d<float> signAtlas [[texture(10)]],
                             texture2d<float> townSignAtlas [[texture(11)]],
                             texture2d<float> groundFineTexture [[texture(12)]],
                             texture2d<float> groundFineNormalTexture [[texture(13)]])
{
    constexpr sampler shadowSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);
    constexpr sampler signSampler(coord::normalized,
                                  address::clamp_to_edge,
                                  filter::linear,
                                  mip_filter::linear);
    constexpr sampler albedoSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear,
                                    mip_filter::linear,
                                    max_anisotropy(8));
    constexpr sampler groundSampler(coord::normalized,
                                    address::repeat,
                                    filter::linear,
                                    mip_filter::linear,
                                    max_anisotropy(8));
    float3 n   = normalize(in.normal);
    float3 sun = normalize(u.sunAndPad.xyz);


    float sunUp = u.sunAndPad.w;
    float day   = saturate(sunUp * 3.0);
    float night = u.night.x;
    float season = u.night.y;   // 0 = midsummer, 1 = midwinter

    // Seasonal ground: green land turns ochre in autumn and grey in winter,
    // and the snowline drops as the season deepens. Purely cosmetic — the
    // simulation never sees it.
    float3 albedo = in.color;
    float greenness = saturate((albedo.g - albedo.r) * 4.5);
    float autumn = smoothstep(0.28, 0.58, season);
    float winter = smoothstep(0.62, 0.95, season);
    albedo = mix(albedo, float3(0.55, 0.40, 0.18), greenness * autumn * 0.75);
    albedo = mix(albedo, float3(0.42, 0.44, 0.40), greenness * winter * 0.85);

    // Contact shading: a narrow darkening right where a building meets the
    // ground. It must stay near the base — `in.local` is mesh-local, so a wide
    // ramp would blacken the whole lower half of every house.
    albedo *= mix(0.70, 1.0, smoothstep(-0.50, -0.42, in.local));

    float snowLine = mix(0.20, 0.075, season);
    float snow = smoothstep(snowLine, snowLine + 0.030, in.world.y)
               * smoothstep(0.22, 0.55, season);
    albedo = mix(albedo, float3(0.90, 0.93, 0.97), snow);

    // Horizontal floor bands on late-era towers. A few darker lines are enough
    // to turn a flat slab into a building at close range. Faded out with
    // distance so the wide shot does not shimmer.
    float wall = 1.0 - smoothstep(0.70, 0.95, abs(n.y));
    float bandFade = saturate(1.0 - length(u.cameraAndTime.xyz - in.world) * 0.55);

    float win = 0.0;
    float on = 0.0;
    float3 glow = float3(0.0);
    float surfaceRough = 0.9;

    if (in.emissive > 0.001 && in.emissive < 1.5) {
        float2 uvp = float2(dot(in.world, float3(n.z, 0.0, -n.x)), in.world.y);
        float2 cells = uvp * float2(240.0, 180.0);
        float2 f = fract(cells);
        float2 id = floor(cells);
        win = step(0.24, f.x) * step(f.x, 0.76)
            * step(0.20, f.y) * step(f.y, 0.80);
        float r = fract(sin(dot(id, float2(12.9898, 78.233))) * 43758.5453);
        on = step(0.35, r);
        float warm = step(0.65, fract(sin(dot(floor(in.world.xz * 90.0),
                                               float2(12.9898, 78.233))) * 43758.5453));
        glow = mix(float3(1.00, 0.78, 0.44), float3(0.70, 0.84, 1.00), warm);

        if (bandFade > 0.01) {
            float floors = fract(in.world.y * 190.0);
            albedo *= 1.0 - 0.12 * smoothstep(0.86, 1.0, floors) * wall * bandFade;

            // Vertical mullions between window bays, aligned with the grid.
            float bay = fract(dot(in.world, float3(n.z, 0.0, -n.x)) * 240.0);
            float mull = smoothstep(0.10, 0.0, bay) + smoothstep(0.90, 1.0, bay);
            albedo *= 1.0 - 0.06 * mull * wall * bandFade;
        }

        // Daytime glass: dark panes, a little lighter where the window is open.
        float3 glass = mix(float3(0.09, 0.13, 0.17), float3(0.20, 0.28, 0.34), on);
        albedo = mix(albedo, glass, win * wall * bandFade * smoothstep(0.05, 0.45, day) * 0.85);
    }

    // Material-specific surface detail (timber, stone, shingles), faded with
    // distance so the wide shot does not shimmer.
    float detailFade = saturate(1.2 - length(u.cameraAndTime.xyz - in.world) * 0.50);

    float windowGlow = 0.0;
    float3 glowTint = float3(1.00, 0.70, 0.40);

    bool plasterWall = (in.material > 0.5 && in.material < 1.5)
                    || (in.material > 5.5 && in.material < 6.5);
    if (plasterWall && wall > 0.5) {
        float h = saturate(in.local + 0.5);
        float2 fuv = float2(dot(in.world, float3(n.z, 0.0, -n.x)), h);

        // Plaster and timber framing: uprights and rails at storey heights,
        // sized for houses rather than island-scale features.
        float pxCoord = fuv.x * 210.0;
        float px = fract(pxCoord);
        float pxAA = saturate(1.0 - fwidth(pxCoord) * 1.8);
        float post = (step(0.90, px) + step(px, 0.10)) * pxAA;
        float ryCoord = h * 2.0;
        float ry = fract(ryCoord);
        float ryAA = saturate(1.0 - fwidth(ryCoord) * 1.8);
        float rail = (smoothstep(0.05, 0.0, ry) + smoothstep(0.95, 1.0, ry)) * ryAA;
        float timber = saturate(post + rail) * detailFade;
        albedo = mix(albedo, float3(0.20, 0.13, 0.08), timber * 0.80);

        // Small dark windows between the rails, only on walls that do not
        // carry real window geometry.
        if (in.material < 5.5) {
            float2 wf = fract(float2(fuv.x * 150.0, h * 2.0));
            float winMask = step(0.30, wf.x) * step(wf.x, 0.70)
                          * step(0.28, wf.y) * step(wf.y, 0.72);
            float wr = fract(sin(dot(floor(float2(fuv.x * 150.0, h * 2.0)),
                                      float2(12.9898, 78.233))) * 43758.5453);
            albedo = mix(albedo, float3(0.10, 0.12, 0.16),
                         winMask * step(0.20, wr) * 0.85 * detailFade);
        }
    } else if (in.material > 6.5 && in.material < 7.5) {
        // Real window panes: dark cool glass by day, warm rooms at night.
        float unit = floor(dot(in.world.xz, float2(210.0, 190.0)) + in.world.y * 160.0);
        float litRoom = step(0.42, fract(sin(unit * 12.9898) * 43758.5453));
        albedo = float3(0.085, 0.115, 0.150);
        windowGlow = night * litRoom * 2.2;
    } else if (in.material > 9.5 && in.material < 10.5) {
        // Stained glass: coloured by day, glowing in its own colour at night.
        albedo = in.color * (0.45 + day * 0.55);
        glowTint = in.color;
        windowGlow = night * 1.9;
    } else if (in.material > 12.5 && in.material < 13.5) {
        // Rail corridor: rough ballast and polished steel.
        bool steel = in.color.b > 0.55 && in.color.r > 0.55;
        if (steel) {
            albedo = in.color;
            surfaceRough = 0.32;
        } else {
            float g = valueNoise(in.world.xz * 900.0);
            albedo = in.color * (0.82 + 0.28 * g);
            surfaceRough = 0.92;
        }
    } else if (in.material > 14.5 && in.material < 15.5) {
        // Traffic signal: one lamp lit at a time, phase offset per junction.
        float slot = in.color.r < 0.6 ? 2.0 : (in.color.g > 0.4 ? 1.0 : 0.0);
        float greenSpan = 0.36 + in.bias * 0.18;
        float amberSpan = 0.06;
        float redEnd = 1.0 - greenSpan - amberSpan;
        float cycle = fract(u.cameraAndTime.w * (0.45 + in.bias * 0.15) + in.plate);
        bool litLamp = (slot < 0.5 && cycle < redEnd)
                    || (slot > 0.5 && slot < 1.5 && cycle >= redEnd && cycle < redEnd + amberSpan)
                    || (slot > 1.5 && cycle >= redEnd + amberSpan);
        albedo = in.color * (litLamp ? 1.0 : 0.14);
        if (litLamp) {
            glowTint = in.color;
            windowGlow = night * 1.6;
        }
        surfaceRough = 0.35;
    } else if (in.material > 15.5 && in.material < 16.5) {
        // Sign and milestone plates from a small text atlas.
        float row = floor(in.plate + 0.5);
        float2 uv = float2(in.uv.x, (in.uv.y + row) / 8.0);
        albedo = signAtlas.sample(signSampler, uv).rgb;
        surfaceRough = 0.72;
    } else if (in.material > 17.5 && in.material < 18.5) {
        // River surface: dark flowing water with sky reflection and ripples.
        float classValue = in.extra;
        float3 base = mix(float3(0.045, 0.16, 0.20),
                          float3(0.025, 0.08, 0.16), classValue);
        float t = u.cameraAndTime.w;
        float2 p = in.world.xz;
        float w1 = sin(p.x * 95.0 + p.y * 15.0 + t * 1.4)
                 * cos(p.y * 82.0 - p.x * 11.0 - t * 1.1);
        float w2 = sin((p.x + p.y) * 60.0 - t * 0.9);
        n = normalize(n + float3(w1 * 0.10, 0.0, w2 * 0.10));
        float3 vd = normalize(u.cameraAndTime.xyz - in.world);
        float3 reflected = reflect(-vd, n);
        float3 sky = skyRadiance(reflected, u);
        float fres = 0.05 + 0.95 * pow(1.0 - saturate(dot(n, vd)), 5.0);
        albedo = mix(base, sky, fres * 0.72);
        surfaceRough = 0.12;
    } else if (in.material > 16.5 && in.material < 17.5) {
        // Town-name gateway sign from the settlement-name atlas.
        float index = floor(in.plate + 0.5);
        float column = fmod(index, 8.0);
        float row = floor(index / 8.0);
        float2 uv = float2((in.uv.x + column) / 8.0,
                           (in.uv.y + row) / 8.0);
        albedo = townSignAtlas.sample(signSampler, uv).rgb;
        surfaceRough = 0.70;
    } else if (in.material > 10.5 && in.material < 12.5) {
        // Road and street surfaces. Vertex alpha carries the surface family;
        // uv.x is across the ribbon (0…1), uv.y is distance in road widths.
        float style = in.extra;
        float across = in.uv.x;
        albedo = float3(1.0, 0.0, 0.0);
        float along = in.uv.y;
        float3 base = in.color;
        float3 rc = base;
        float rough = 0.85;

        if (style < 0.5) {
            // Packed earth with cart ruts and a grassy crown.
            float broad = valueNoise(float2(across * 7.0, along * 7.0));
            float fine = valueNoise(float2(across * 38.0, along * 90.0));
            float rut = smoothstep(0.13, 0.0, abs(across - 0.30))
                      + smoothstep(0.13, 0.0, abs(across - 0.70));
            float crown = smoothstep(0.20, 0.0, abs(across - 0.5));
            rc = base * (0.86 + 0.18 * broad + 0.06 * fine);
            rc = mix(rc, rc * 0.56, saturate(rut) * 0.55);
            rc = mix(rc, float3(0.30, 0.34, 0.22), crown * 0.22);
            rough = 0.96;
        } else if (style < 1.5) {
            // Compacted gravel.
            float g = valueNoise(float2(across * 55.0, along * 55.0));
            float f = valueNoise(float2(across * 140.0, along * 140.0));
            rc = base * (0.82 + 0.26 * g + 0.08 * f);
            rough = 0.92;
        } else if (style < 2.5) {
            // Roman polygonal paving with dark mortar joints.
            float2 g = float2(across * 12.0, along * 14.0);
            float2 cell = floor(g);
            float2 f = fract(g);
            float2 j = float2(hash21(cell), hash21(cell + 11.3));
            float d = length(f - j);
            float joint = smoothstep(0.42, 0.50, d);
            float tone = hash21(cell + 3.7);
            rc = mix(base * (0.62 + 0.26 * tone), base * 0.30, joint);
            rough = mix(0.68, 0.92, joint);
        } else if (style < 3.5) {
            // Rounded cobbles set in hoggin.
            float2 g = float2(across * 12.0, along * 14.0);
            float2 cell = floor(g);
            float2 f = fract(g);
            float2 j = float2(0.5 + 0.28 * (hash21(cell) - 0.5),
                              0.5 + 0.28 * (hash21(cell + 5.1) - 0.5));
            float d = length(f - j);
            float stone = smoothstep(0.46, 0.32, d);
            float tone = hash21(cell + 9.1);
            rc = mix(base * 0.68, base * (0.86 + 0.22 * tone), stone);
            float wear = smoothstep(0.15, 0.0, abs(across - 0.35))
                       + smoothstep(0.15, 0.0, abs(across - 0.65));
            rc *= 1.0 - 0.10 * saturate(wear);
            rough = mix(0.96, 0.82, stone);
        } else if (style < 4.5) {
            // Dressed setts in tight staggered rows.
            float2 g = float2(across * 24.0, along * 30.0);
            float2 cell = floor(g);
            float2 f = fract(g);
            float jointX = smoothstep(0.93, 1.0, f.x) + smoothstep(0.07, 0.0, f.x);
            float jointY = smoothstep(0.91, 1.0, f.y);
            float joint = saturate(jointX + jointY);
            float tone = hash21(cell);
            rc = mix(base * (0.80 + 0.36 * tone), base * 0.45, joint);
            rough = mix(0.78, 0.92, joint);
        } else if (style < 5.5) {
            // Water-bound macadam: angular aggregate, dust and patches.
            float g = valueNoise(float2(across * 85.0, along * 85.0));
            float f = valueNoise(float2(across * 210.0, along * 210.0));
            rc = base * (0.84 + 0.22 * g + 0.10 * f);
            float patch = smoothstep(0.55, 0.66, valueNoise(float2(across * 3.0, along * 3.0)));
            rc = mix(rc, rc * 1.14, patch * 0.40);
            rough = 0.90;
        } else if (style < 6.5) {
            // Asphalt with fine aggregate and repaired patches.
            float f = valueNoise(float2(across * 180.0, along * 180.0));
            float g = valueNoise(float2(across * 13.0, along * 13.0));
            rc = base * (0.92 + 0.10 * f + 0.06 * g);
            float patch = smoothstep(0.58, 0.70, valueNoise(float2(across * 2.5, along * 2.5)));
            rc = mix(rc, rc * 0.80, patch);
            rough = mix(0.62, 0.80, patch);
        } else if (style < 7.5) {
            // Brick paving, laid in a running bond.
            float2 g = float2(across * 14.0, along * 15.0);
            float row = floor(g.y);
            g.x += step(1.0, fmod(row, 2.0)) * 0.5;
            float2 cell = floor(g);
            float2 f = fract(g);
            float brick = step(f.y, 0.80) * step(0.05, f.x) * step(f.x, 0.95);
            float tone = hash21(cell);
            rc = mix(base * 0.55, base * (0.82 + 0.30 * tone), brick);
            rough = mix(0.88, 0.78, brick);
        } else {
            // Painted marking.
            rc = base;
            rough = 0.55;
        }

        // A shallow camber and a little surface relief.
        if (style < 7.5) {
            float camber = 1.0 - 0.16 * abs(across - 0.5) * 2.0;
            rc *= camber;
            float bump = valueNoise(float2(across * 70.0, along * 70.0)) - 0.5;
            n = normalize(n + float3(bump * 0.08, 0.0, bump * 0.08));
        }
        float wetRoad = saturate(u.night.w * 1.25 - 0.10);
        float puddle = 0.0;
        if (wetRoad > 0.001) {
            rc *= mix(1.0, 0.58, wetRoad);
            rough = mix(rough, 0.18, wetRoad);
            float mask = smoothstep(0.52, 0.74,
                                    valueNoise(float2(across * 3.0 + 4.0,
                                                      along * 3.0 - 2.0)));
            mask *= smoothstep(0.0, 0.30, across) * smoothstep(1.0, 0.70, across);
            puddle = saturate(wetRoad * mask);
        }
        albedo = rc;
        surfaceRough = rough;
        if (puddle > 0.01) {
            albedo *= mix(1.0, 0.70, puddle);
            surfaceRough = mix(surfaceRough, 0.05, puddle);
            float2 q = float2(across * 24.0, along * 24.0);
            float t = u.cameraAndTime.w;
            // Water drains down the camber, so ripple fronts move toward the kerbs.
            float edge = across < 0.5 ? -1.0 : 1.0;
            float flow = abs(across - 0.5) * 70.0 + along * 6.0;
            float ripple = sin(flow - t * 3.2) * 0.65
                         + sin(q.y * 1.7 + q.x * 0.8 + t * 1.4) * 0.35;
            n = normalize(n + float3(edge * ripple * 0.22 * puddle, 0.0,
                                     ripple * 0.10 * puddle));
        }
    } else if (in.material > 8.5 && in.material < 9.5) {
        // Imported hero asset: the atlas carries colour and surface detail.
        albedo = albedoTexture.sample(albedoSampler, in.uv).rgb;
    } else if (in.material > 1.5 && in.material < 2.5) {
        // Stone courses with a running bond. Fade the fine lines once their
        // screen-space derivative grows, which kills grazing-angle moire.
        float courseCoord = in.world.y * 240.0;
        float course = fract(courseCoord);
        float shift = floor(courseCoord) * 0.5;
        float brickCoord = dot(in.world, float3(n.z, 0.0, -n.x)) * 180.0 + shift;
        float brick = fract(brickCoord);
        float courseAA = saturate(1.0 - fwidth(courseCoord) * 1.8);
        float brickAA = saturate(1.0 - fwidth(brickCoord) * 1.8);
        albedo *= 1.0 - 0.10 * smoothstep(0.85, 1.0, course) * courseAA * detailFade;
        albedo *= 1.0 - 0.05 * smoothstep(0.90, 1.0, brick) * brickAA * detailFade;
    } else if (in.material > 4.5 && in.material < 5.5) {
        // Ploughed crops: fine furrows so fields read as worked land.
        float furrowCoord = (in.world.x + in.world.z * 0.35) * 520.0;
        float furrow = fract(furrowCoord);
        float furrowAA = saturate(1.0 - fwidth(furrowCoord) * 1.8);
        albedo *= 1.0 - 0.16 * smoothstep(0.42, 1.0, furrow) * furrowAA * detailFade;
        float crossCoord = (in.world.z - in.world.x * 0.35) * 260.0;
        float cross = fract(crossCoord);
        float crossAA = saturate(1.0 - fwidth(crossCoord) * 1.8);
        albedo *= 1.0 - 0.05 * smoothstep(0.60, 1.0, cross) * crossAA * detailFade;
    } else if (in.material > 7.5 && in.material < 8.5) {
        // Ground cover: broad mottling plus fine grain, so hillsides read as
        // land rather than a flat wash of colour at any camera distance.
        float broad = valueNoise(in.world.xz * 55.0);
        float fine  = valueNoise(in.world.xz * 130.0);
        albedo *= 0.90 + 0.14 * broad + 0.030 * fine * detailFade;

        // Triplanar projections keep grass and rock from stretching on cliffs.
        float3 bw = pow(abs(n), float3(4.0));
        bw /= (bw.x + bw.y + bw.z + 1e-5);
        float2 guvX = in.world.zy * 34.0;
        float2 guvY = in.world.xz * 34.0;
        float3 gtex = groundTexture.sample(groundSampler, guvX).rgb * bw.x
                    + groundTexture.sample(groundSampler, guvY).rgb * (bw.y + bw.z);

        // A rotated fine scale breaks the tiling of the macro texture.
        float2 fineUV = float2(in.world.x * 470.0 + in.world.z * 170.0,
                               in.world.z * 470.0 - in.world.x * 170.0);
        float3 fineTex = groundFineTexture.sample(groundSampler, fineUV).rgb;

        float rockMask = smoothstep(0.62, 0.30, n.y);
        float soilMask = 1.0 - rockMask;

        // Macro patchiness: grass, dry grass and bare soil at field scale.
        float macroNoise = valueNoise(in.world.xz * 3.4);
        float mesoNoise = valueNoise(in.world.xz * 14.0);
        float dirtNoise = valueNoise(in.world.xz * 7.5 + 13.0);
        float dirt = smoothstep(0.58, 0.78, dirtNoise) * soilMask;
        albedo = mix(albedo, float3(0.40, 0.32, 0.20), dirt * 0.38);
        albedo *= 0.82 + 0.26 * macroNoise + 0.10 * mesoNoise;

        float grass = smoothstep(0.015, 0.10, albedo.g - albedo.r);
        float3 detailTex = gtex * (0.72 + 0.36 * fineTex);
        detailTex = min(detailTex, float3(1.35));
        albedo *= mix(1.0, detailTex, soilMask * 1.0);

        float tintNoise = valueNoise(in.world.xz * 9.0);
        float3 grassTint = mix(float3(0.92, 0.95, 0.84),
                               float3(1.04, 1.02, 0.86), tintNoise);
        albedo *= mix(float3(1.0), grassTint, soilMask * 0.38);

        // Sub-metre procedural grain keeps close-ups sharp when the tiled
        // textures are magnified past their texel density.
        float closeFade = saturate(1.0 - length(u.cameraAndTime.xyz - in.world) * 9.0);
        float micro = valueNoise(in.world.xz * 1900.0);
        float blade = valueNoise(in.world.xz * 5200.0);
        float clump = smoothstep(0.58, 0.82, valueNoise(in.world.xz * 3100.0));
        albedo *= 1.0 + (micro - 0.5) * 0.16 * closeFade
                      + (blade - 0.5) * 0.10 * closeFade;
        albedo *= 1.0 - 0.09 * clump * closeFade * soilMask;

        float2 ruvY = in.world.xz * 9.0;
        float3 rtex = rockTexture.sample(groundSampler, ruvY).rgb;
        float rock = smoothstep(0.62, 0.30, n.y);
        albedo = mix(albedo, albedo * rtex * 1.18, rock);

        float3 gn = groundNormalTexture.sample(groundSampler, guvY).xyz * 2.0 - 1.0;
        n = normalize(n + float3(gn.x, 0.0, gn.y) * 0.52 * soilMask * detailFade);
        float3 fgn = groundFineNormalTexture.sample(groundSampler, fineUV).xyz * 2.0 - 1.0;
        n = normalize(n + float3(fgn.x, 0.0, fgn.y) * 0.62 * soilMask * detailFade);
        n = normalize(n + float3(blade - 0.5, 0.0, micro - 0.5)
                          * 0.26 * closeFade * soilMask);
        float3 rn = rockNormalTexture.sample(groundSampler, ruvY).xyz * 2.0 - 1.0;
        n = normalize(n + float3(rn.x, 0.0, rn.y) * 0.5 * rock);
        n = normalize(n + float3(fgn.x, 0.0, fgn.y) * 0.28 * rock);
        surfaceRough = mix(0.95, 0.82, rock);
    } else if (in.material > 2.5 && in.material < 3.5) {
        // Roof shingles, anti-aliased with screen derivatives.
        float rowCoord = in.local * 9.0;
        float row = fract(rowCoord);
        float shift = floor(rowCoord) * 0.5;
        float shingleCoord = dot(in.world, float3(n.z, 0.0, -n.x)) * 160.0 + shift;
        float shingle = fract(shingleCoord);
        float rowAA = saturate(1.0 - fwidth(rowCoord) * 1.8);
        float shingleAA = saturate(1.0 - fwidth(shingleCoord) * 1.8);
        float vary = 0.90 + 0.18 * fract(sin(dot(floor(float2(shingle, row)),
                                                float2(12.9898, 78.233))) * 43758.5453);
        albedo *= mix(1.0, vary, detailFade * shingleAA);
        albedo *= 1.0 - 0.10 * smoothstep(0.86, 1.0, row) * rowAA * detailFade;
    }

    float  ndl     = max(dot(n, sun), 0.0);
    float  wrap    = max(dot(n, sun) * 0.5 + 0.5, 0.0);
    float3 skyAmb  = mix(float3(0.145, 0.175, 0.30), float3(0.34, 0.46, 0.66), day);
    float3 gndAmb  = mix(float3(0.095, 0.105, 0.135), float3(0.20, 0.18, 0.14), day);
    float3 ambient = mix(gndAmb, skyAmb, n.y * 0.5 + 0.5) * mix(0.95, 0.50, day);
    float3 sunCol  = mix(float3(1.00, 0.52, 0.28), float3(1.00, 0.94, 0.84), day);

    // Moonlight keeps the island readable at night without pretending it is day.
    float3 moonDir = normalize(-sun);
    float  moonLit = max(dot(n, moonDir), 0.0) * night;
    float3 moonCol = float3(0.42, 0.55, 0.82);

    float cloud = cloudShadow(in.world.xz, u.cameraAndTime.w);
    float weather = u.night.w;
    float sunVis = (1.0 - cloud * 0.55 * day) * (1.0 - weather * 0.55);
    ambient *= mix(1.0, 0.78, weather);

    float shadow = shadowFactor(shadowMap, shadowSampler,
                                u.lightViewProjection, u.shadow,
                                in.world, n, sun, 1.0);

    // Town-scale cascade: inside its bounds, use the higher-resolution map.
    float4 clp = u.closeLightProjection * float4(in.world + n * u.closeShadow.y, 1.0);
    float3 cp = clp.xyz / max(clp.w, 1e-5);
    float2 cuv = float2(cp.x * 0.5 + 0.5, 0.5 - cp.y * 0.5);
    if (all(cuv > 0.005) && all(cuv < 0.995)) {
        float closeShadow = shadowFactor(closeShadowMap, shadowSampler,
                                         u.closeLightProjection, u.closeShadow,
                                         in.world, n, sun, 1.1);
        float edge = min(min(cuv.x, 1.0 - cuv.x), min(cuv.y, 1.0 - cuv.y));
        float blend = smoothstep(0.010, 0.060, edge);
        shadow = mix(shadow, closeShadow, blend);
    }
    // Debug flag: u.shadow.w == 1 disables shadows, 2 also tags the river.
    if (u.shadow.w > 0.5) { shadow = 1.0; }

    float3 lit = albedo * (ambient
                           + sunCol * (ndl * 0.95 + wrap * 0.10) * sunVis * shadow * mix(0.03, 0.52, day)
                           + moonCol * moonLit * 0.55);

    if (in.material > 17.5 && in.material < 18.5) {
        // River water: depth-shaded body, flow-aligned ripples, grazing sky
        // reflection and a continuous shoreline foam lip. `in.extra` is the
        // normalised depth written at the water mesh's vertices (zero at the
        // waterline), so every effect follows the real channel.
        float t = u.cameraAndTime.w;
        float2 uv = in.uv;
        float depth = saturate(in.extra);
        float dist = length(u.cameraAndTime.xyz - in.world);
        float detail = saturate(1.0 - dist * 9.0);

        // Ripple coordinates follow the channel: uv.y runs downstream, so the
        // two noise layers streak with the flow instead of tiling in world
        // space. The broad layer drifts slowly, the fine layer faster.
        float2 flowUv = float2(uv.x * 5.0, uv.y * 0.45);
        float2 r1 = float2(
            valueNoise(flowUv * float2(3.2, 1.0) + float2(0.0, -t * 0.030)),
            valueNoise(flowUv * float2(3.2, 1.0) + float2(11.7, -t * 0.030 + 4.2)));
        float2 r2 = float2(
            valueNoise(flowUv * float2(7.4, 2.4) + float2(3.1, t * 0.050)),
            valueNoise(flowUv * float2(7.4, 2.4) + float2(8.4, t * 0.050 + 9.3)));
        float2 ripple = (r1 * 0.64 + r2 * 0.36) * 2.0 - 1.0;
        ripple *= mix(0.30, 1.0, detail);

        float3 vd = normalize(u.cameraAndTime.xyz - in.world);
        float3 nRipple = normalize(n + float3(ripple.x, 0.0, ripple.y)
                                       * mix(0.002, 0.030, detail));

        // A flat sheet can carry a real Fresnel without the bed-step pools
        // that made Phase 2 switch it off: grazing views reflect the sky,
        // steep views look into the tinted body.
        float3 sky = skyColour(u.sunAndPad.w) * 0.90;
        float fres = 0.07 + 0.38 * pow(1.0 - saturate(dot(n, vd)), 4.0);

        // Shore silt, clear shallow shelf, mid channel and deep water.
        float3 shore = float3(0.085, 0.130, 0.115);
        float3 shallow = float3(0.020, 0.090, 0.100);
        float3 mid = float3(0.009, 0.048, 0.078);
        float3 deep = float3(0.003, 0.020, 0.040);
        float3 body = mix(deep, mid, smoothstep(0.16, 0.62, depth));
        body = mix(body, shallow, smoothstep(0.42, 0.04, depth) * 0.85);
        body = mix(body, shore, smoothstep(0.045, 0.0, depth) * 0.60);

        float3 water = mix(body, sky, fres * 0.55);

        // Sun glint: the sheet's normal is nearly flat, so a high power lobe
        // is modulated by fine world-space glitter. This keeps a sun path on
        // the water without the regular lanes a stretched flow texture made.
        float3 halfDir = normalize(sun + vd);
        float glint = pow(max(dot(n, halfDir), 0.0), 220.0);
        water += sunCol * glint * sunVis * shadow
               * mix(0.015, 0.09, detail);

        // Shoreline foam: a continuous lip where depth reaches zero, broken
        // up by two slow noise bands so it reads as moving water rather than
        // a painted outline. A second surge band sits just inside the lip.
        float along = uv.y * 1.7;
        float f1 = valueNoise(float2(along * 9.0, uv.x * 5.0 - t * 0.08));
        float f2 = valueNoise(float2(along * 23.0 + 4.0, uv.x * 11.0));
        float breakup = smoothstep(0.26, 0.74, f1 * 0.65 + f2 * 0.35);
        float lip = smoothstep(0.055, 0.0, depth) * (0.30 + 0.70 * breakup);
        float surge = smoothstep(0.105, 0.025, depth)
                    * smoothstep(0.55, 0.85, f1);
        float foam = saturate(lip + surge * 0.30);
        water += foam * float3(0.62, 0.70, 0.70) * (0.13 + 0.10 * day);

        lit = water;
        if (u.shadow.w > 2.5 && u.shadow.w < 3.5) {
            lit = float3(uv.x, fract(uv.y), 0.0);
        } else if (u.shadow.w > 3.5) {
            lit = float3(foam, foam, foam);
        } else if (u.shadow.w > 1.5) {
            lit = float3(1.0, 0.0, 1.0);
        }
    }

    // Specular response from the roughness map: glass and metal catch the sun.
    // Water already has its own, flow-aware highlight; the generic one turns
    // cloud shadows into dark blobs on the river.
    if (in.material < 17.5 || in.material > 18.5) {
        float3 V = normalize(u.cameraAndTime.xyz - in.world);
        float3 H = normalize(V + sun);
        float shininess = mix(12.0, 90.0, 1.0 - surfaceRough);
        float shine = smoothstep(0.55, 0.15, surfaceRough);
        float spec = pow(max(dot(n, H), 0.0), shininess) * shine;
        lit += sunCol * spec * shadow * sunVis * 0.65;
    }

    float flash = lightningFlash(u.cameraAndTime.w, weather);
    lit += flash * (albedo * 0.30 + float3(0.05, 0.06, 0.09));
    lit += glowTint * windowGlow;

    // A faint warm city glow lifts imported buildings out of black at night
    // without touching the landscape.
    if (in.material > 8.5 && in.material < 9.5) {
        lit += albedo * float3(0.13, 0.105, 0.085) * night;
    }

    // Windows and street lights come alive at night. A procedural window grid
    // keeps the glow on the walls (never the roofs) and lets a skyline read as
    // hundreds of little decisions rather than one giant bulb.
    float emissive = in.emissive * night;
    if (in.emissive > 1.5) {
        // Retroreflective glint by day (cat's eyes, lamps, lit windows).
        float3 vd = normalize(u.cameraAndTime.xyz - in.world);
        float3 hd = normalize(sun + vd);
        float glint = pow(max(dot(n, hd), 0.0), 90.0) * day;
        lit += glint * 1.2 * float3(1.0, 0.95, 0.82);
        // Street lamp: a solid point of light rather than a window grid.
        lit = mix(lit, float3(1.00, 0.74, 0.38) * 2.6, night);
    } else if (emissive > 0.001) {
        lit += glow * emissive * win * on * wall * 2.6;

        // A faint sheen so unlit towers still read as glass at night.
        lit += albedo * emissive * 0.10;
    }

    float3 viewDir = normalize(u.cameraAndTime.xyz - in.world);
    float  rim     = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0) * 0.07;
    if (in.material < 17.5 || in.material > 18.5) {
        lit += rim * float3(0.65, 0.78, 1.00) * day;
    }

    if (in.material > 10.5 && in.material < 12.5) {
        float wetRoad = saturate(u.night.w * 1.25 - 0.10);
        if (wetRoad > 0.001) {
            float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0);
            lit += wetRoad * fresnel * float3(0.42, 0.52, 0.66) * 0.85;
        }
    }

    // Rivers are marked in the vertex alpha; give them a wet specular sheen.
    float wet = (in.material > 7.5 && in.material < 8.5)
              ? saturate(1.0 - in.extra) : 0.0;
    if (wet > 0.01) {
        float3 halfDir = normalize(sun + viewDir);
        float  sheen = pow(max(dot(n, halfDir), 0.0), 70.0);
        lit += wet * sheen * float3(0.55, 0.75, 0.90) * day * 0.35;
    }

    // Distance fog plus a radial horizon fade so the edge of the world grid
    // dissolves into the sky instead of ending in a hard square.
    float3 horizonColour = mix(float3(0.04, 0.06, 0.12), float3(0.60, 0.70, 0.82), day);
    float dist = length(u.cameraAndTime.xyz - in.world);
    float fog  = 1.0 - exp(-max(dist - 3.0, 0.0) * 0.30);
    float radial = smoothstep(0.98, 1.24, length(in.world.xz));
    lit = mix(lit, horizonColour, saturate(max(fog * u.night.z, radial)));

    return float4(tonemap(lit), 1.0);
}

// Smoke: reuses the mesh vertex stage, with the instance alpha as opacity.
fragment float4 smokeFragment(MeshVaryings in [[stage_in]],
                              constant FrameUniforms &u [[buffer(1)]])
{
    float3 n = normalize(in.normal);
    float3 sun = normalize(u.sunAndPad.xyz);
    float day = saturate(u.sunAndPad.w * 3.0);
    float ndl = max(dot(n, sun), 0.0);
    float3 col = in.color * (0.40 + 0.60 * day) * (0.72 + 0.28 * ndl);

    // Soft edge: the sphere's rim fades out so overlapping puffs read as a
    // plume rather than a string of balls.
    float3 viewDir = normalize(u.cameraAndTime.xyz - in.world);
    float facing = saturate(dot(n, viewDir));
    float alpha = in.emissive * smoothstep(0.0, 0.85, facing);
    return float4(tonemap(col), alpha);
}

// Rain and snow: simple tinted geometry with per-instance opacity.
fragment float4 weatherFragment(MeshVaryings in [[stage_in]],
                                constant FrameUniforms &u [[buffer(1)]])
{
    float day = saturate(u.sunAndPad.w * 3.0);
    float3 col = in.color * (0.45 + 0.55 * day);
    return float4(tonemap(col), in.emissive);
}

// ---------------------------------------------------------------------------
// Water
// ---------------------------------------------------------------------------

fragment float4 waterFragment(MeshVaryings in [[stage_in]],
                              constant FrameUniforms &u [[buffer(1)]],
                              texture2d<float> heightMap [[texture(0)]])
{
    float t = u.cameraAndTime.w;
    float3 n = normalize(in.normal);

    // Two crossing ripple directions, cheap and stylised.
    float2 p = in.world.xz;
    float w1 = sin(p.x * 42.0 + t * 0.55) * cos(p.y * 37.0 - t * 0.40);
    float w2 = sin((p.x + p.y) * 23.0 - t * 0.30);

    // Damp ripples with distance; at grazing angles the high-frequency detail
    // otherwise aliases into broad bands across the open ocean.
    float distToCamera = length(u.cameraAndTime.xyz - in.world);
    float ripple = saturate(1.0 - distToCamera * 0.34);
    n = normalize(n + float3(w1 * 0.030, 0.0, w2 * 0.030) * ripple);

    float3 viewDir = normalize(u.cameraAndTime.xyz - in.world);

    float day = saturate(u.sunAndPad.w * 3.0);

    // Sample the height field per pixel: the shallow band and foam follow the
    // smooth sea-level contour instead of the coarse water mesh.
    constexpr sampler hmap(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 huv = (in.world.xz + 1.0) * 0.5;
    float ground = heightMap.sample(hmap, huv).r;
    float depth = saturate(-ground / 0.075);

    float3 shallow = mix(float3(0.04, 0.13, 0.17), float3(0.20, 0.50, 0.55), day);
    float3 deep    = mix(float3(0.01, 0.03, 0.07), float3(0.02, 0.12, 0.26), day);

    float3 base = mix(shallow, deep, smoothstep(0.0, 0.55, depth));

    float3 reflected = reflect(-viewDir, n);
    float3 sky = skyRadiance(reflected, u);
    float schlick = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, viewDir)), 5.0);
    float3 col = mix(base, sky, schlick);

    float3 sun = normalize(u.sunAndPad.xyz);
    float3 hv  = normalize(sun + viewDir);
    float cloud = cloudShadow(in.world.xz, t);
    float weather = u.night.w;
    float sunVis = (1.0 - cloud * 0.55 * day) * (1.0 - weather * 0.70);
    float spec = pow(max(dot(n, hv), 0.0), 140.0) * day * sunVis;
    col += spec * float3(1.0, 0.95, 0.85) * 1.4;
    col *= mix(1.0, 0.90, cloud * day);
    col *= mix(1.0, 0.82, weather);
    col += lightningFlash(t, weather) * float3(0.30, 0.38, 0.55) * 0.45;

    // Foam right at the shoreline, with a wave running up the sand.
    float foamWave = 0.5 + 0.5 * sin(depth * 220.0 - t * 1.1 + w2 * 1.5);
    float foam = smoothstep(0.09, 0.0, depth) * (0.42 + 0.30 * w1 + 0.28 * foamWave);
    col = mix(col, float3(0.85, 0.90, 0.92) * (0.35 + 0.65 * day), foam * 0.45);

    // Opaque-ish right at the shore so the jagged submerged sand is hidden,
    // clear in the shallows, fully opaque offshore.
    float alpha = mix(0.72, 0.98, smoothstep(0.0, 0.26, depth));

    // Blend the far edge of the ocean into the sky.
    // Fading *alpha* (rather than painting a flat sky colour) lets the real
    // gradient sky show through, so the horizon dissolves instead of ending at
    // a visible seam. Distance is measured from the camera so the haze band
    // stays put whichever shot we are in.
    float haze = smoothstep(4.5, 15.0, distToCamera);
    float3 horizonSky = skyRadiance(normalize(float3(-viewDir.x, 0.06, -viewDir.z)), u);
    col = mix(col, horizonSky, haze);
    alpha *= 1.0 - haze;

    return float4(tonemap(col), alpha);
}

// ---------------------------------------------------------------------------
// Sky: a single full-screen triangle, evaluated from the view ray.
// ---------------------------------------------------------------------------

struct SkyVaryings {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyVaryings skyVertex(uint vid [[vertex_id]])
{
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    SkyVaryings out;
    out.position = float4(p[vid], 1.0, 1.0);
    out.ndc      = p[vid];
    return out;
}

fragment float4 skyFragment(SkyVaryings in [[stage_in]],
                            constant FrameUniforms &u [[buffer(1)]])
{
    float day = saturate(u.sunAndPad.w * 3.0);
    float night = u.night.x;
    float weather = u.night.w;

    float4 worldH = u.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 ray = normalize(worldH.xyz / worldH.w - u.cameraAndTime.xyz);
    float3 col = skyRadiance(ray, u);

    // Winter air is paler and less saturated.
    col = mix(col, float3(dot(col, float3(0.299, 0.587, 0.114))), u.night.y * 0.10);

    // Warm glow low on the sun side.
    float3 sun = normalize(u.sunAndPad.xyz);
    float  glow = pow(saturate(dot(ray, sun) * 0.5 + 0.5), 24.0);
    float  golden = 1.0 - saturate(abs(u.sunAndPad.w) * 4.0);
    col += float3(1.0, 0.55, 0.28) * glow * (0.30 + 0.55 * golden) * (0.25 + 0.75 * day);

    col += lightningFlash(u.cameraAndTime.w, weather) * float3(0.55, 0.60, 0.75) * 0.65;

    // Stars.
    float2 sp = in.ndc * float2(220.0, 140.0);
    float star = fract(sin(dot(floor(sp), float2(12.9898, 78.233))) * 43758.5453);
    float twinkle = step(0.9975, star) * night;
    col += twinkle * float3(0.8, 0.85, 1.0) * (0.5 + 0.5 * sin(u.cameraAndTime.w * 2.0 + star * 40.0));

    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------
// Post: tilt-shift depth of field, cheap bloom, vignette and grain.
//
// The scene is rendered into an offscreen texture and then composited here, so
// this pass only ever reads one texture and writes the drawable.
// ---------------------------------------------------------------------------

struct PostUniforms {
    // x = focus line (uv.y), y = sharp half-band, z = feather, w = max blur px
    float4 params;
    // x = time, y = vignette strength, z = bloom strength, w = unused
    float4 extra;
    // x = scene scale (scene px per output px), y = grain, z/w = unused
    float4 view;
    // x = warmth, y = contrast, z = saturation, w = unused
    float4 grade;
};

struct PostVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex PostVaryings postVertex(uint vid [[vertex_id]])
{
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    PostVaryings out;
    out.position = float4(p[vid], 0.0, 1.0);
    out.uv = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);
    return out;
}

fragment float4 postFragment(PostVaryings in [[stage_in]],
                             texture2d<float> scene [[texture(0)]],
                             constant PostUniforms &u [[buffer(1)]])
{
    constexpr sampler smp(coord::normalized,
                          address::clamp_to_edge,
                          filter::linear);

    float2 uv    = in.uv;
    float2 texel = 1.0 / float2(scene.get_width(), scene.get_height());
    // Offsets are expressed in output pixels, so scale them into scene texels.
    float2 stexel = texel * u.view.x;
    const float ga = 2.39996323;

    // ---- Tilt-shift ------------------------------------------------------
    // A sharp horizontal band across the subject, with the near foreground and
    // the sky falling out of focus. That is the whole miniature illusion.
    float dist = abs(uv.y - u.params.x);
    float coc  = smoothstep(u.params.y, u.params.y + u.params.z, dist);
    float radius = coc * u.params.w;

    float3 col = scene.sample(smp, uv).rgb;

    if (radius > 0.75) {
        // Golden-angle spiral: even coverage with few taps, no banding.
        float3 sum = col;
        for (int i = 0; i < 5; ++i) {
            float fi = float(i) + 0.5;
            float ang = fi * ga;
            float rr  = sqrt(fi / 5.0);
            float2 off = float2(cos(ang), sin(ang)) * (rr * radius) * stexel;
            sum += scene.sample(smp, uv + off).rgb;
        }
        col = sum / 6.0;
    }

    // ---- Bloom -----------------------------------------------------------
    // Only genuinely bright pixels (night windows, sun glitter) contribute.
    if (u.extra.z > 0.001) {
        float2 br = 12.0 * stexel;
        float3 glow = float3(0.0);
        for (int i = 0; i < 4; ++i) {
            float fi = float(i) + 0.5;
            float ang = fi * ga + 0.7;
            float2 off = float2(cos(ang), sin(ang)) * br;
            float3 s = scene.sample(smp, uv + off).rgb;
            glow += max(s - 0.60, 0.0);
        }
        col += glow * (u.extra.z / 6.0);
    }

    // ---- Sharpen ---------------------------------------------------------
    // A light unsharp mask restores the crispness lost to supersampling
    // resolve, MSAA and the tilt-shift, without ringing on flat colours.
    // It runs on the raw scene: mixing ungraded neighbours into a graded
    // colour pushes saturated darks below zero and rings around them.
    if (u.grade.w > 0.001) {
        float2 o = texel * 1.0;
        float3 around = scene.sample(smp, uv + float2( o.x, 0)).rgb
                      + scene.sample(smp, uv + float2(-o.x, 0)).rgb
                      + scene.sample(smp, uv + float2(0,  o.y)).rgb
                      + scene.sample(smp, uv + float2(0, -o.y)).rgb;
        around *= 0.25;
        col += (col - around) * u.grade.w;
    }

    // ---- Lens character --------------------------------------------------
    // Chromatic aberration also works on the raw scene. Applying it after the
    // grade mixed ungraded samples back into a graded colour, which drew a
    // hard disc at the threshold radius on dark saturated water. The weight
    // fades in smoothly so the boundary can never become an edge.
    float2 ca = uv - 0.5;
    float caR2 = dot(ca, ca);
    float caWeight = smoothstep(0.015, 0.070, caR2) * 0.6;
    if (caWeight > 0.001) {
        float2 caOff = ca * caR2 * 0.0008;
        col.r = mix(col.r, scene.sample(smp, uv + caOff).r, caWeight);
        col.b = mix(col.b, scene.sample(smp, uv - caOff).b, caWeight);
    }

    // ---- Grade -----------------------------------------------------------
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(float3(luma), col, u.grade.z);
    col = (col - 0.5) * u.grade.y + 0.5;
    col *= mix(float3(0.96, 0.98, 1.05), float3(1.05, 1.01, 0.95),
               smoothstep(0.10, 0.85, luma));
    col += u.grade.x * 0.03 * float3(1.0, 0.68, 0.38) * smoothstep(0.35, 1.0, luma);

    // ---- Vignette --------------------------------------------------------
    float2 v = (uv - 0.5) * float2(1.0, 1.12);
    float vig = 1.0 - u.extra.y * smoothstep(0.30, 0.78, length(v));
    col *= vig;

    // ---- Grain -----------------------------------------------------------
    // A whisper of grain keeps large flat skies from banding.
    float g = fract(sin(dot(uv * 1024.0 + u.extra.x, float2(12.9898, 78.233))) * 43758.5453);
    col += (g - 0.5) * u.view.y;

    // ---- Quantisation dither --------------------------------------------
    // A triangular dither at half an 8-bit step hides banding in wide sky
    // gradients without noise you can actually see.
    float d1 = fract(sin(dot(in.position.xy + float2(u.extra.x * 17.0, 0.0),
                             float2(12.9898, 78.233))) * 43758.5453);
    float d2 = fract(sin(dot(in.position.xy + float2(5.3, 19.7),
                             float2(39.3468, 11.135))) * 24634.6345);
    col += (d1 + d2 - 1.0) * (1.0 / 255.0);

    return float4(col, 1.0);
}

// Final upscale for displays where the post pass runs below native size.
fragment float4 blitFragment(PostVaryings in [[stage_in]],
                             texture2d<float> src [[texture(0)]])
{
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    return src.sample(smp, in.uv);
}

#endif
