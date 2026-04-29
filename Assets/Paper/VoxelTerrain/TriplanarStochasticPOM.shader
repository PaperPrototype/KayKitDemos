Shader "Custom/TriplanarStochasticPOM"

Properties
{
    _MainTex ("Albedo", Texture2D) = "grid"
    _MainColor ("Tint", Color) = (1.0, 1.0, 1.0, 1.0)
    _Tiling ("Tiling", Float) = 1.0
    _TriplanarBlend ("Blend Sharpness", Float) = 4.0

    _NormalTex ("Normal", Texture2D) = "normal"
    _SurfaceTex ("Surface (AO, Roughness, Metallicness)", Texture2D) = "surface"
    _EmissionTex ("Emission", Texture2D) = "emission"
    _EmissionIntensity ("Emission Intensity", Float) = 1.0

    _AlphaCutoff ("Alpha Cutoff", Float) = 0.5

    _ParallaxMap ("Height Map (G)", Texture2D) = "black"
    _Parallax ("Height Scale", Float) = 0.0
    _ParallaxSteps ("POM Steps", Int) = 16
    _HeightBlendStrength ("Height Blend Strength", Float) = 0.0

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
                worldPos = TransformPosition(vertexPosition);
                vColor = GetInstanceColor();
                vNormal = TransformDirection(vertexNormal);
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
            uniform float _EmissionIntensity;
            uniform vec4 _MainColor;
            uniform float _AlphaCutoff;
            uniform float _Tiling;
            uniform float _TriplanarBlend;

            uniform sampler2D _ParallaxMap;
            uniform float _Parallax;
            uniform int _ParallaxSteps;
            uniform float _HeightBlendStrength;

            uniform sampler2D _TranslucencyMap;
            uniform float _TranslucencyStrength;
            uniform float _ScatteringPower;
            uniform float _ScatteringDistortion;
            uniform float _ScatteringScale;

            // -----------------------------------------------------------------------
            // Stochastic helpers (Heitz & Neyret triangular-grid approach)
            // -----------------------------------------------------------------------

            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            // Maps UV to the triangular grid, returning 3 hash-derived UV offsets and
            // barycentric blend weights for the enclosing triangle cell.
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

            // Samples tex at uv+ox1/2/3, blends by bary, and restores contrast with
            // variance-preserving correction: result = mean + (blend-mean)/sqrt(sum(wi^2))
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

                // Triplanar blend weights from surface normal
                vec3 absN   = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

                // World-space triplanar UVs:
                //   uvX: YZ plane (X-facing), uvY: XZ plane (Y-facing), uvZ: XY plane (Z-facing)
                vec2 uvX = worldPos.zy * _Tiling;
                vec2 uvY = worldPos.xz * _Tiling;
                vec2 uvZ = worldPos.xy * _Tiling;

                // Stochastic grid setup from base (pre-POM) UVs.
                // Offsets are surface-anchored: computed once, reused for all samples
                // including the POM march and final texture reads.
                vec2 ox1X, ox2X, ox3X; vec3 baryX;
                vec2 ox1Y, ox2Y, ox3Y; vec3 baryY;
                vec2 ox1Z, ox2Z, ox3Z; vec3 baryZ;
                stochasticSetup(uvX, ox1X, ox2X, ox3X, baryX);
                stochasticSetup(uvY, ox1Y, ox2Y, ox3Y, baryY);
                stochasticSetup(uvZ, ox1Z, ox2Z, ox3Z, baryZ);

                // Blended stochastic offset per axis — single representative offset used
                // inside the POM loop so height sampling costs 3 samples/step, not 9.
                vec2 pomOffX = ox1X * baryX.x + ox2X * baryX.y + ox3X * baryX.z;
                vec2 pomOffY = ox1Y * baryY.x + ox2Y * baryY.y + ox3Y * baryY.z;
                vec2 pomOffZ = ox1Z * baryZ.x + ox2Z * baryZ.y + ox3Z * baryZ.z;

                // -----------------------------------------------------------------------
                // Seamless world-space POM with per-axis stochastic height sampling.
                //
                // View direction is decomposed into depth rate (viewDotN) and surface-
                // tangent drift — both smooth functions of N with no axis branches, so
                // the march transitions continuously through triplanar blend regions.
                // Horizon flattening smoothly kills parallax at grazing angles.
                // -----------------------------------------------------------------------
                if (_Parallax > 0.0 && _ParallaxSteps > 0)
                {
                    float viewDotN = max(dot(viewDir, N), 0.001);
                    float effP     = _Parallax * clamp(viewDotN / 0.3, 0.0, 1.0);

                    vec3 tangDrift = viewDir - viewDotN * N;
                    vec3 worldStep = -tangDrift / (viewDotN * _Tiling) * effP / float(_ParallaxSteps);

                    float stepSize   = 1.0 / float(_ParallaxSteps);
                    float layerDepth = 0.0;
                    vec3  curPos     = worldPos;
                    vec3  prevPos    = worldPos;
                    float mapH       = 1.0;
                    float prevMapH   = 1.0;

                    for (int i = 0; i < _ParallaxSteps; i++)
                    {
                        prevPos    = curPos;
                        prevMapH   = mapH;
                        curPos    += worldStep;
                        layerDepth += stepSize;

                        // Triplanar-blended height with per-axis stochastic offsets.
                        // The fixed offsets break tiling repetition in the depth field
                        // without adding extra samples per step.
                        mapH = texture(_ParallaxMap, curPos.zy * _Tiling + pomOffX).g * weights.x
                             + texture(_ParallaxMap, curPos.xz * _Tiling + pomOffY).g * weights.y
                             + texture(_ParallaxMap, curPos.xy * _Tiling + pomOffZ).g * weights.z;

                        if (layerDepth >= 1.0 - mapH) break;
                    }

                    // Linear refinement between the last two steps
                    float d0    = (layerDepth - stepSize) - (1.0 - prevMapH);
                    float d1    = layerDepth - (1.0 - mapH);
                    float denom = d1 - d0;
                    float t     = abs(denom) > 0.0001 ? clamp(-d0 / denom, 0.0, 1.0) : 0.5;
                    curPos = mix(prevPos, curPos, t);

                    uvX = curPos.zy * _Tiling;
                    uvY = curPos.xz * _Tiling;
                    uvZ = curPos.xy * _Tiling;
                }

                // Height-lerp triplanar blend: biases weights toward taller features at
                // axis transitions. Uses stochastic height for consistency with final samples.
                vec3 fw = weights;
                if (_HeightBlendStrength > 0.001)
                {
                    float hX = sSample(_ParallaxMap, uvX, ox1X, ox2X, ox3X, baryX).g;
                    float hY = sSample(_ParallaxMap, uvY, ox1Y, ox2Y, ox3Y, baryY).g;
                    float hZ = sSample(_ParallaxMap, uvZ, ox1Z, ox2Z, ox3Z, baryZ).g;
                    vec3  h  = weights + vec3(hX, hY, hZ);
                    float hM = max(h.x, max(h.y, h.z));
                    vec3  hB = max(h - (hM - 0.2), 0.0);
                    hB /= (hB.x + hB.y + hB.z + 0.0001);
                    fw  = mix(weights, hB, _HeightBlendStrength);
                    fw /= (fw.x + fw.y + fw.z + 0.0001);
                }

                // Albedo — full stochastic per axis, triplanar-blended
                vec4 albedo = sSample(_MainTex, uvX, ox1X, ox2X, ox3X, baryX) * fw.x
                            + sSample(_MainTex, uvY, ox1Y, ox2Y, ox3Y, baryY) * fw.y
                            + sSample(_MainTex, uvZ, ox1Z, ox2Z, ox3Z, baryZ) * fw.z;
                albedo *= vColor * _MainColor;
                vec3 baseColor = gammaToLinearSpace(albedo.rgb);

                // Normal map — stochastic per axis, world-space transform per axis, blend.
                // Per-axis transform: X=(tn.z*sign(N.x), tn.y, tn.x)
                //                     Y=(tn.x, tn.z*sign(N.y), tn.y)
                //                     Z=(tn.x, tn.y, tn.z*sign(N.z))
                vec3 tnX = sSample(_NormalTex, uvX, ox1X, ox2X, ox3X, baryX).rgb * 2.0 - 1.0;
                vec3 tnY = sSample(_NormalTex, uvY, ox1Y, ox2Y, ox3Y, baryY).rgb * 2.0 - 1.0;
                vec3 tnZ = sSample(_NormalTex, uvZ, ox1Z, ox2Z, ox3Z, baryZ).rgb * 2.0 - 1.0;
                vec3 nWX = vec3(tnX.z * sign(N.x), tnX.y, tnX.x);
                vec3 nWY = vec3(tnY.x, tnY.z * sign(N.y), tnY.y);
                vec3 nWZ = vec3(tnZ.x, tnZ.y, tnZ.z * sign(N.z));
                vec3 worldNormal = normalize(nWX * fw.x + nWY * fw.y + nWZ * fw.z);

                // Surface: R=AO, G=Roughness, B=Metallic
                vec4 surface = sSample(_SurfaceTex, uvX, ox1X, ox2X, ox3X, baryX) * fw.x
                             + sSample(_SurfaceTex, uvY, ox1Y, ox2Y, ox3Y, baryY) * fw.y
                             + sSample(_SurfaceTex, uvZ, ox1Z, ox2Z, ox3Z, baryZ) * fw.z;
                float ao        = 1.0 - surface.r;
                float roughness = surface.g;
                float metallic  = surface.b;

                // Translucency map: G=extra occlusion, B=thickness
                vec4 transOcc = sSample(_TranslucencyMap, uvX, ox1X, ox2X, ox3X, baryX) * fw.x
                              + sSample(_TranslucencyMap, uvY, ox1Y, ox2Y, ox3Y, baryY) * fw.y
                              + sSample(_TranslucencyMap, uvZ, ox1Z, ox2Z, ox3Z, baryZ) * fw.z;
                ao *= transOcc.g;
                float translucency = transOcc.b * _TranslucencyStrength;

                // Emission
                vec3 emission = (sSample(_EmissionTex, uvX, ox1X, ox2X, ox3X, baryX).rgb * fw.x
                               + sSample(_EmissionTex, uvY, ox1Y, ox2Y, ox3Y, baryY).rgb * fw.y
                               + sSample(_EmissionTex, uvZ, ox1Z, ox2Z, ox3Z, baryZ).rgb * fw.z)
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
                vec3 color = ApplyFog(ambient + lighting + emission, worldPos);

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
                worldPos = TransformPosition(vertexPosition);
                vNormal = TransformDirection(vertexNormal);
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
            uniform vec4 _MainColor;
            uniform float _AlphaCutoff;
            uniform float _Tiling;
            uniform float _TriplanarBlend;

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
                vec3 N = normalize(vNormal);
                vec3 absN = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

                vec2 uvX = worldPos.zy * _Tiling;
                vec2 uvY = worldPos.xz * _Tiling;
                vec2 uvZ = worldPos.xy * _Tiling;

                vec2 ox1X, ox2X, ox3X; vec3 baryX;
                vec2 ox1Y, ox2Y, ox3Y; vec3 baryY;
                vec2 ox1Z, ox2Z, ox3Z; vec3 baryZ;
                stochasticSetup(uvX, ox1X, ox2X, ox3X, baryX);
                stochasticSetup(uvY, ox1Y, ox2Y, ox3Y, baryY);
                stochasticSetup(uvZ, ox1Z, ox2Z, ox3Z, baryZ);

                if (_AlphaCutoff > 0.0)
                {
                    vec4 albedo = sSample(_MainTex, uvX, ox1X, ox2X, ox3X, baryX) * weights.x
                                + sSample(_MainTex, uvY, ox1Y, ox2Y, ox3Y, baryY) * weights.y
                                + sSample(_MainTex, uvZ, ox1Z, ox2Z, ox3Z, baryZ) * weights.z;
                    if (albedo.a * _MainColor.a < _AlphaCutoff) discard;
                }

                vec3 tnX = sSample(_NormalTex, uvX, ox1X, ox2X, ox3X, baryX).rgb * 2.0 - 1.0;
                vec3 tnY = sSample(_NormalTex, uvY, ox1Y, ox2Y, ox3Y, baryY).rgb * 2.0 - 1.0;
                vec3 tnZ = sSample(_NormalTex, uvZ, ox1Z, ox2Z, ox3Z, baryZ).rgb * 2.0 - 1.0;
                vec3 nWX = vec3(tnX.z * sign(N.x), tnX.y, tnX.x);
                vec3 nWY = vec3(tnY.x, tnY.z * sign(N.y), tnY.y);
                vec3 nWZ = vec3(tnZ.x, tnZ.y, tnZ.z * sign(N.z));
                vec3 worldNormal = normalize(nWX * weights.x + nWY * weights.y + nWZ * weights.z);

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
                worldPos = TransformPosition(vertexPosition);
                vNormal = TransformDirection(vertexNormal);
            }
        }

        Fragment
        {
            #include "Fragment"

            in vec3 worldPos;
            in vec3 vNormal;

            uniform sampler2D _MainTex;
            uniform vec4 _MainColor;
            uniform float _AlphaCutoff;
            uniform float _Tiling;
            uniform float _TriplanarBlend;

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
                    vec3 N = normalize(vNormal);
                    vec3 absN = abs(N);
                    vec3 weights = pow(absN, vec3(_TriplanarBlend));
                    weights /= (weights.x + weights.y + weights.z + 0.0001);

                    vec2 uvX = worldPos.zy * _Tiling;
                    vec2 uvY = worldPos.xz * _Tiling;
                    vec2 uvZ = worldPos.xy * _Tiling;

                    vec2 ox1X, ox2X, ox3X; vec3 baryX;
                    vec2 ox1Y, ox2Y, ox3Y; vec3 baryY;
                    vec2 ox1Z, ox2Z, ox3Z; vec3 baryZ;
                    stochasticSetup(uvX, ox1X, ox2X, ox3X, baryX);
                    stochasticSetup(uvY, ox1Y, ox2Y, ox3Y, baryY);
                    stochasticSetup(uvZ, ox1Z, ox2Z, ox3Z, baryZ);

                    vec4 s1X = texture(_MainTex, uvX + ox1X);
                    vec4 s2X = texture(_MainTex, uvX + ox2X);
                    vec4 s3X = texture(_MainTex, uvX + ox3X);
                    float alphaX = (s1X.a * baryX.x + s2X.a * baryX.y + s3X.a * baryX.z);

                    vec4 s1Y = texture(_MainTex, uvY + ox1Y);
                    vec4 s2Y = texture(_MainTex, uvY + ox2Y);
                    vec4 s3Y = texture(_MainTex, uvY + ox3Y);
                    float alphaY = (s1Y.a * baryY.x + s2Y.a * baryY.y + s3Y.a * baryY.z);

                    vec4 s1Z = texture(_MainTex, uvZ + ox1Z);
                    vec4 s2Z = texture(_MainTex, uvZ + ox2Z);
                    vec4 s3Z = texture(_MainTex, uvZ + ox3Z);
                    float alphaZ = (s1Z.a * baryZ.x + s2Z.a * baryZ.y + s3Z.a * baryZ.z);

                    float alpha = (alphaX * weights.x + alphaY * weights.y + alphaZ * weights.z)
                                * _MainColor.a;
                    if (alpha < _AlphaCutoff) discard;
                }
                gl_FragDepth = gl_FragCoord.z;
            }
        }
    ENDGLSL
}
