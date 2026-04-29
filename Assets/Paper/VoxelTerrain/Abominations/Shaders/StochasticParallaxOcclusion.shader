// Stochastic Parallax Occlusion Mapping shader.
//
// Replaces triplanar projection entirely with stochastic texturing:
//   - A single tangent frame is derived analytically from the vertex normal
//     (T = cross(up, N), B = cross(N, T)), giving one world-space UV per fragment.
//   - A triangular grid divides that UV space into cells. Each cell vertex gets a
//     unique hash-derived UV offset. The fragment samples every texture 3 times
//     (once per nearby vertex) and blends with barycentric weights.
//   - A variance-preserving correction (1/sqrt(dot(bary,bary))) restores the
//     contrast that linear blending would otherwise reduce.
//   - POM works in the natural TBN space — no world-space displacement, no seam.
//
// The stochastic offsets are computed from the base (pre-POM) UV so they are
// view-independent and anchored to the surface. The same offsets are applied
// throughout the POM height march and all final texture lookups.

Shader "Custom/StochasticParallaxOcclusion"

Properties
{
    _MainTex ("Albedo", Texture2D) = "grid"
    _MainColor ("Tint", Color) = (1.0, 1.0, 1.0, 1.0)
    _Tiling ("Tiling", Float) = 1.0

    _NormalTex ("Normal", Texture2D) = "normal"
    _SurfaceTex ("Surface (AO, Roughness, Metallicness)", Texture2D) = "surface"
    _EmissionTex ("Emission", Texture2D) = "emission"
    _EmissionIntensity ("Emission Intensity", Float) = 1.0

    _AlphaCutoff ("Alpha Cutoff", Float) = 0.5

    _ParallaxMap ("Height Map (G)", Texture2D) = "black"
    _Parallax ("Height Scale", Float) = 0.0
    _ParallaxSteps ("POM Steps", Int) = 16

    _TranslucencyMap ("Translucency (B) Occlusion (G)", Texture2D) = "white"
    _TranslucencyStrength ("Translucency Strength", Float) = 0.0
    _ScatteringPower ("Scattering Power", Float) = 0.0
    _ScatteringDistortion ("Scattering Distortion", Float) = 0.5
    _ScatteringScale ("Scattering Scale", Float) = 1.0
}

Pass "Standard"
{
    Tags { "RenderOrder" = "Opaque" }
    Cull Back

    GLSLPROGRAM

        Vertex
        {
            #include "Fragment"
            #include "VertexAttributes"

            out vec3 worldPos;
            out vec4 vColor;
            out vec3 vNormal;

            void main()
            {
                gl_Position = TransformClip(vertexPosition);
                worldPos    = TransformPosition(vertexPosition);
                vColor      = GetInstanceColor();
                vNormal     = TransformDirection(vertexNormal);
            }
        }

        Fragment
        {
            #include "Fragment"
            #include "Lighting"

            layout (location = 0) out vec4 fragColor;

            in vec3 worldPos;
            in vec4 vColor;
            in vec3 vNormal;

            uniform sampler2D _MainTex;
            uniform sampler2D _NormalTex;
            uniform sampler2D _SurfaceTex;
            uniform sampler2D _EmissionTex;
            uniform float     _EmissionIntensity;
            uniform vec4      _MainColor;
            uniform float     _AlphaCutoff;
            uniform float     _Tiling;

            uniform sampler2D _ParallaxMap;
            uniform float     _Parallax;
            uniform int       _ParallaxSteps;

            uniform sampler2D _TranslucencyMap;
            uniform float     _TranslucencyStrength;
            uniform float     _ScatteringPower;
            uniform float     _ScatteringDistortion;
            uniform float     _ScatteringScale;

            // -----------------------------------------------------------------------
            // Stochastic helpers
            // -----------------------------------------------------------------------

            // Maps integer cell coordinates to a random UV offset in [0, 1)^2.
            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            // Triangular-grid stochastic setup.
            //
            // Transforms the input UV to a skewed coordinate space where the integer
            // grid forms equilateral triangles. Determines which triangle the UV sits
            // in, returns the 3 vertex hashes as UV offsets (ox1..ox3) and the
            // barycentric blend weights (bary).
            //
            // Grid transform: g = (uv.x + uv.y*0.5,  uv.y*sqrt(3)/2)
            // This maps square UV tiles to a triangular lattice so the 3 nearest
            // vertices are always the corners of one equilateral triangle.
            void stochasticSetup(vec2 uv,
                                 out vec2 ox1, out vec2 ox2, out vec2 ox3,
                                 out vec3 bary)
            {
                const float k = 0.8660254; // sqrt(3)/2
                vec2 g = vec2(uv.x + uv.y * 0.5, uv.y * k);
                vec2 i = floor(g);
                vec2 f = fract(g);

                vec2 v1, v2, v3;
                if (f.x + f.y < 1.0)
                {
                    v1   = i;
                    v2   = i + vec2(1.0, 0.0);
                    v3   = i + vec2(0.0, 1.0);
                    bary = vec3(1.0 - f.x - f.y, f.x, f.y);
                }
                else
                {
                    v1   = i + vec2(1.0, 1.0);
                    v2   = i + vec2(0.0, 1.0);
                    v3   = i + vec2(1.0, 0.0);
                    bary = vec3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
                }

                ox1 = sHash(v1);
                ox2 = sHash(v2);
                ox3 = sHash(v3);
            }

            // Samples tex at (uv+ox1), (uv+ox2), (uv+ox3), blends by bary, and
            // applies a variance-preserving correction so the blended result has the
            // same apparent contrast as the original texture.
            //
            // Derivation: linear blending reduces std-dev by sqrt(sum(wi^2)).
            // Correcting: result = mean + (blend - mean) * 1/sqrt(sum(wi^2))
            vec4 sSample(sampler2D tex, vec2 uv,
                         vec2 ox1, vec2 ox2, vec2 ox3, vec3 bary)
            {
                vec4 s1      = texture(tex, uv + ox1);
                vec4 s2      = texture(tex, uv + ox2);
                vec4 s3      = texture(tex, uv + ox3);
                vec4 blended = s1 * bary.x + s2 * bary.y + s3 * bary.z;
                vec4 mean    = (s1 + s2 + s3) / 3.0;
                return mean + (blended - mean) * inversesqrt(dot(bary, bary));
            }

            void main()
            {
                vec3 N       = normalize(vNormal);
                vec3 viewDir = normalize(_WorldSpaceCameraPos.xyz - worldPos);

                // Analytical tangent frame from the vertex normal.
                // T = cross(up, N) gives a consistent world-space "right" vector for
                // any N, rotating smoothly as the surface normal changes.
                // Fallback up avoids degeneracy when N is nearly vertical.
                vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
                vec3 T  = normalize(cross(up, N));
                vec3 B  = cross(N, T);

                // World-space UV: project worldPos onto the surface tangent plane.
                // Tiled in world units — view-independent and anchored to the surface.
                vec2 uv = vec2(dot(worldPos, T), dot(worldPos, B)) * _Tiling;

                // Stochastic cell setup from the base (pre-POM) UV.
                // View-independent: offsets are fixed to the surface, not the camera.
                vec2 ox1, ox2, ox3;
                vec3 bary;
                stochasticSetup(uv, ox1, ox2, ox3, bary);

                // Blended stochastic offset: single representative point used inside the
                // POM ray march loop so height sampling breaks tiling without 3x cost.
                vec2 pomOff = ox1 * bary.x + ox2 * bary.y + ox3 * bary.z;

                // -----------------------------------------------------------------------
                // POM in tangent space with stochastic height sampling.
                //
                // Works in the natural TBN space — no world-space displacement, no seam.
                // Horizon flattening reduces parallax at grazing angles to prevent extreme
                // UV offsets that cause stretching artifacts.
                // -----------------------------------------------------------------------
                if (_Parallax > 0.0 && _ParallaxSteps > 0)
                {
                    // Horizon flattening: full parallax above ~17°, fades to 0 at surface
                    float viewDotN = max(dot(viewDir, N), 0.0);
                    float effP     = _Parallax * clamp(viewDotN / 0.3, 0.0, 1.0);

                    // View direction in tangent space
                    vec3 vdTS  = vec3(dot(viewDir, T), dot(viewDir, B), viewDotN);
                    vec2 uvStep = -vdTS.xy / max(vdTS.z, 0.1) * effP / float(_ParallaxSteps);

                    float sizeInv = 1.0 / float(_ParallaxSteps);
                    float depth   = 0.0;
                    vec2  curUV   = uv, prevUV = uv;
                    float mapH    = 1.0, prevH = 1.0;

                    for (int i = 0; i < _ParallaxSteps; i++)
                    {
                        prevUV = curUV;
                        prevH  = mapH;
                        curUV += uvStep;
                        depth += sizeInv;

                        // Stochastic height: same fixed offsets + marching UV breaks
                        // tiling repetition in the apparent depth field.
                        mapH = texture(_ParallaxMap, curUV + pomOff).g;

                        if (depth >= 1.0 - mapH) break;
                    }

                    // Linear refinement between last two steps
                    float d0    = (depth - sizeInv) - (1.0 - prevH);
                    float d1    = depth - (1.0 - mapH);
                    float denom = d1 - d0;
                    float t     = abs(denom) > 0.0001 ? clamp(-d0 / denom, 0.0, 1.0) : 0.5;
                    uv = mix(prevUV, curUV, t);
                }

                // -----------------------------------------------------------------------
                // Stochastic texture sampling for all surface properties.
                // Each texture is sampled 3 times (one per stochastic cell vertex) and
                // blended with variance-preserving correction.
                // -----------------------------------------------------------------------

                // Albedo
                vec4 albedo = sSample(_MainTex, uv, ox1, ox2, ox3, bary) * vColor * _MainColor;
                vec3 baseColor = gammaToLinearSpace(albedo.rgb);

                // Normal map — decode, transform to world space via TBN
                vec3 tn = sSample(_NormalTex, uv, ox1, ox2, ox3, bary).rgb * 2.0 - 1.0;
                vec3 worldNormal = normalize(tn.x * T + tn.y * B + tn.z * N);

                // Surface: R=AO, G=Roughness, B=Metallic
                vec4 surface  = sSample(_SurfaceTex, uv, ox1, ox2, ox3, bary);
                float ao        = 1.0 - surface.r;
                float roughness = surface.g;
                float metallic  = surface.b;

                // Translucency map: G=extra occlusion, B=thickness
                vec4 transOcc = sSample(_TranslucencyMap, uv, ox1, ox2, ox3, bary);
                ao *= transOcc.g;
                float translucency = transOcc.b * _TranslucencyStrength;

                // Emission
                vec3 emission = sSample(_EmissionTex, uv, ox1, ox2, ox3, bary).rgb
                              * _EmissionIntensity;

                // PBR lighting
                vec3 lighting = CalculateForwardLighting(worldPos, worldNormal, viewDir,
                                                         baseColor, metallic, roughness, ao);

                // Translucency backscatter
                if (translucency > 0.0 && _LightCount > 0)
                {
                    for (int i = 0; i < _LightCount && i < MAX_FORWARD_LIGHTS; i++)
                    {
                        vec3 lightDir;
                        if (_LightType[i] == 0)
                            lightDir = normalize(_LightDirections[i]);
                        else
                            lightDir = normalize(_LightPositions[i] - worldPos);

                        vec3 lightColor = _LightColors[i] * _LightIntensities[i];
                        vec3 scatter = CalculateTranslucency(lightDir, viewDir, worldNormal,
                                           translucency, _ScatteringPower,
                                           _ScatteringDistortion, _ScatteringScale, lightColor);
                        lighting += scatter * baseColor;
                    }
                }

                // Ambient + fog
                vec3 diffuseColor = baseColor * (1.0 - metallic);
                vec3 ambient = CalculateAmbient(worldNormal) * diffuseColor * ao * _AmbientStrength;
                vec3 color   = ApplyFog(ambient + lighting + emission, worldPos);

                if (albedo.a < _AlphaCutoff) discard;
                fragColor = vec4(color, 1.0);
            }
        }
    ENDGLSL
}

Pass "DepthNormals"
{
    Tags { "LightMode" = "DepthNormals" }
    Cull Back

    GLSLPROGRAM

        Vertex
        {
            #include "Fragment"
            #include "VertexAttributes"

            out vec3 worldPos;
            out vec3 vNormal;

            void main()
            {
                gl_Position = TransformClip(vertexPosition);
                worldPos    = TransformPosition(vertexPosition);
                vNormal     = TransformDirection(vertexNormal);
            }
        }

        Fragment
        {
            #include "Fragment"

            layout (location = 0) out vec4 normalOut;

            in vec3 worldPos;
            in vec3 vNormal;

            uniform sampler2D _NormalTex;
            uniform sampler2D _MainTex;
            uniform vec4      _MainColor;
            uniform float     _AlphaCutoff;
            uniform float     _Tiling;

            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            void stochasticSetup(vec2 uv,
                                 out vec2 ox1, out vec2 ox2, out vec2 ox3,
                                 out vec3 bary)
            {
                const float k = 0.8660254;
                vec2 g = vec2(uv.x + uv.y * 0.5, uv.y * k);
                vec2 i = floor(g);
                vec2 f = fract(g);
                vec2 v1, v2, v3;
                if (f.x + f.y < 1.0)
                {
                    v1 = i; v2 = i + vec2(1,0); v3 = i + vec2(0,1);
                    bary = vec3(1.0 - f.x - f.y, f.x, f.y);
                }
                else
                {
                    v1 = i + vec2(1,1); v2 = i + vec2(0,1); v3 = i + vec2(1,0);
                    bary = vec3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
                }
                ox1 = sHash(v1); ox2 = sHash(v2); ox3 = sHash(v3);
            }

            vec4 sSample(sampler2D tex, vec2 uv,
                         vec2 ox1, vec2 ox2, vec2 ox3, vec3 bary)
            {
                vec4 s1 = texture(tex, uv + ox1);
                vec4 s2 = texture(tex, uv + ox2);
                vec4 s3 = texture(tex, uv + ox3);
                vec4 blended = s1 * bary.x + s2 * bary.y + s3 * bary.z;
                vec4 mean    = (s1 + s2 + s3) / 3.0;
                return mean + (blended - mean) * inversesqrt(dot(bary, bary));
            }

            void main()
            {
                vec3 N  = normalize(vNormal);
                vec3 up = abs(N.y) < 0.999 ? vec3(0,1,0) : vec3(1,0,0);
                vec3 T  = normalize(cross(up, N));
                vec3 B  = cross(N, T);
                vec2 uv = vec2(dot(worldPos, T), dot(worldPos, B)) * _Tiling;

                vec2 ox1, ox2, ox3; vec3 bary;
                stochasticSetup(uv, ox1, ox2, ox3, bary);

                if (_AlphaCutoff > 0.0)
                {
                    float alpha = sSample(_MainTex, uv, ox1, ox2, ox3, bary).a * _MainColor.a;
                    if (alpha < _AlphaCutoff) discard;
                }

                vec3 tn = sSample(_NormalTex, uv, ox1, ox2, ox3, bary).rgb * 2.0 - 1.0;
                vec3 worldNormal = normalize(tn.x * T + tn.y * B + tn.z * N);
                normalOut = EncodeViewNormal(worldNormal);
            }
        }
    ENDGLSL
}

Pass "StandardShadow"
{
    Tags { "LightMode" = "ShadowCaster" }
    Cull Back

    GLSLPROGRAM

        Vertex
        {
            #include "Fragment"
            #include "VertexAttributes"

            out vec3 worldPos;
            out vec3 vNormal;

            void main()
            {
                gl_Position = TransformClip(vertexPosition);
                worldPos    = TransformPosition(vertexPosition);
                vNormal     = TransformDirection(vertexNormal);
            }
        }

        Fragment
        {
            #include "Fragment"

            in vec3 worldPos;
            in vec3 vNormal;

            uniform sampler2D _MainTex;
            uniform vec4      _MainColor;
            uniform float     _AlphaCutoff;
            uniform float     _Tiling;

            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            void stochasticSetup(vec2 uv,
                                 out vec2 ox1, out vec2 ox2, out vec2 ox3,
                                 out vec3 bary)
            {
                const float k = 0.8660254;
                vec2 g = vec2(uv.x + uv.y * 0.5, uv.y * k);
                vec2 i = floor(g);
                vec2 f = fract(g);
                vec2 v1, v2, v3;
                if (f.x + f.y < 1.0)
                {
                    v1 = i; v2 = i + vec2(1,0); v3 = i + vec2(0,1);
                    bary = vec3(1.0 - f.x - f.y, f.x, f.y);
                }
                else
                {
                    v1 = i + vec2(1,1); v2 = i + vec2(0,1); v3 = i + vec2(1,0);
                    bary = vec3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
                }
                ox1 = sHash(v1); ox2 = sHash(v2); ox3 = sHash(v3);
            }

            void main()
            {
                if (_AlphaCutoff > 0.0)
                {
                    vec3 N  = normalize(vNormal);
                    vec3 up = abs(N.y) < 0.999 ? vec3(0,1,0) : vec3(1,0,0);
                    vec3 T  = normalize(cross(up, N));
                    vec3 B  = cross(N, T);
                    vec2 uv = vec2(dot(worldPos, T), dot(worldPos, B)) * _Tiling;

                    vec2 ox1, ox2, ox3; vec3 bary;
                    stochasticSetup(uv, ox1, ox2, ox3, bary);

                    vec4 s1 = texture(_MainTex, uv + ox1);
                    vec4 s2 = texture(_MainTex, uv + ox2);
                    vec4 s3 = texture(_MainTex, uv + ox3);
                    float alpha = (s1.a * bary.x + s2.a * bary.y + s3.a * bary.z) * _MainColor.a;
                    if (alpha < _AlphaCutoff) discard;
                }
                gl_FragDepth = gl_FragCoord.z;
            }
        }
    ENDGLSL
}
