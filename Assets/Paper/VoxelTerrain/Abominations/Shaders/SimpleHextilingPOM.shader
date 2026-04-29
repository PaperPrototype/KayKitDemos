Shader "Custom/SimpleHextilingPOM"

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
            uniform float     _TriplanarBlend;

            uniform sampler2D _ParallaxMap;
            uniform float     _Parallax;
            uniform int       _ParallaxSteps;

            uniform sampler2D _TranslucencyMap;
            uniform float     _TranslucencyStrength;
            uniform float     _ScatteringPower;
            uniform float     _ScatteringDistortion;
            uniform float     _ScatteringScale;

            // -----------------------------------------------------------------------
            // Hex-tiling helpers
            // -----------------------------------------------------------------------

            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            float rHash(vec2 p)
            {
                return fract(sin(dot(p, vec2(41.5, 93.7))) * 43758.5453123);
            }

            vec2 hexRot(vec2 uv, float a)
            {
                float c = cos(a), s = sin(a);
                return vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
            }

            void hexSetup(vec2 uv,
                          out vec2 ox1, out vec2 ox2, out vec2 ox3,
                          out float r1,  out float r2,  out float r3,
                          out vec3 bary)
            {
                const float k         = 0.8660254;
                const float PI_OVER_3 = 1.04719755;

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

                r1 = floor(rHash(v1) * 6.0) * PI_OVER_3;
                r2 = floor(rHash(v2) * 6.0) * PI_OVER_3;
                r3 = floor(rHash(v3) * 6.0) * PI_OVER_3;
            }

            vec4 hexSample(sampler2D tex, vec2 uv,
                           vec2 ox1, vec2 ox2, vec2 ox3,
                           float r1, float r2, float r3, vec3 bary)
            {
                vec4 s1      = texture(tex, hexRot(uv, r1) + ox1);
                vec4 s2      = texture(tex, hexRot(uv, r2) + ox2);
                vec4 s3      = texture(tex, hexRot(uv, r3) + ox3);
                vec4 blended = s1 * bary.x + s2 * bary.y + s3 * bary.z;
                vec4 mean    = (s1 + s2 + s3) / 3.0;
                return mean + (blended - mean) * inversesqrt(dot(bary, bary));
            }

            vec3 hexSampleNormal(sampler2D tex, vec2 uv,
                                 vec2 ox1, vec2 ox2, vec2 ox3,
                                 float r1, float r2, float r3, vec3 bary)
            {
                vec3 n1 = texture(tex, hexRot(uv, r1) + ox1).rgb * 2.0 - 1.0;
                vec3 n2 = texture(tex, hexRot(uv, r2) + ox2).rgb * 2.0 - 1.0;
                vec3 n3 = texture(tex, hexRot(uv, r3) + ox3).rgb * 2.0 - 1.0;

                float c1 = cos(r1), sv1 = sin(r1);
                float c2 = cos(r2), sv2 = sin(r2);
                float c3 = cos(r3), sv3 = sin(r3);
                n1.xy = vec2(n1.x * c1 - n1.y * sv1, n1.x * sv1 + n1.y * c1);
                n2.xy = vec2(n2.x * c2 - n2.y * sv2, n2.x * sv2 + n2.y * c2);
                n3.xy = vec2(n3.x * c3 - n3.y * sv3, n3.x * sv3 + n3.y * c3);

                vec3 blended = n1 * bary.x + n2 * bary.y + n3 * bary.z;
                vec3 mean    = (n1 + n2 + n3) / 3.0;
                return normalize(mean + (blended - mean) * inversesqrt(dot(bary, bary)));
            }

            void main()
            {
                vec3 N       = normalize(vNormal);
                vec3 viewDir = normalize(_WorldSpaceCameraPos.xyz - worldPos);

                // Triplanar blend weights from surface normal
                vec3 absN    = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

                // World-space triplanar UVs:
                //   uvX: YZ plane, uvY: XZ plane, uvZ: XY plane
                vec2 uvX = worldPos.zy * _Tiling;
                vec2 uvY = worldPos.xz * _Tiling;
                vec2 uvZ = worldPos.xy * _Tiling;

                // Hex setup from pre-POM UVs — rotations and offsets are surface-anchored
                // and view-independent; reused unchanged for POM and all final samples.
                vec2  ox1X, ox2X, ox3X; float r1X, r2X, r3X; vec3 baryX;
                vec2  ox1Y, ox2Y, ox3Y; float r1Y, r2Y, r3Y; vec3 baryY;
                vec2  ox1Z, ox2Z, ox3Z; float r1Z, r2Z, r3Z; vec3 baryZ;
                hexSetup(uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX);
                hexSetup(uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY);
                hexSetup(uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ);

                // Blended translation offsets for the POM height march.
                // Rotation omitted here: per-cell rotations during the march would cause
                // adjacent cells to converge to inconsistent depths.
                vec2 pomOffX = ox1X * baryX.x + ox2X * baryX.y + ox3X * baryX.z;
                vec2 pomOffY = ox1Y * baryY.x + ox2Y * baryY.y + ox3Y * baryY.z;
                vec2 pomOffZ = ox1Z * baryZ.x + ox2Z * baryZ.y + ox3Z * baryZ.z;

                // Seamless world-space POM: viewDir decomposed into depth rate (viewDotN)
                // and surface-tangent drift — both smooth functions of N, no axis branches.
                // Horizon flattening kills parallax at grazing angles.
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

                        mapH = texture(_ParallaxMap, curPos.zy * _Tiling + pomOffX).g * weights.x
                             + texture(_ParallaxMap, curPos.xz * _Tiling + pomOffY).g * weights.y
                             + texture(_ParallaxMap, curPos.xy * _Tiling + pomOffZ).g * weights.z;

                        if (layerDepth >= 1.0 - mapH) break;
                    }

                    float d0    = (layerDepth - stepSize) - (1.0 - prevMapH);
                    float d1    = layerDepth - (1.0 - mapH);
                    float denom = d1 - d0;
                    float t     = abs(denom) > 0.0001 ? clamp(-d0 / denom, 0.0, 1.0) : 0.5;
                    curPos = mix(prevPos, curPos, t);

                    uvX = curPos.zy * _Tiling;
                    uvY = curPos.xz * _Tiling;
                    uvZ = curPos.xy * _Tiling;
                }

                // Albedo — full hex sample (rotation + offset + variance correction) per axis
                vec4 albedo = hexSample(_MainTex, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX) * weights.x
                            + hexSample(_MainTex, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY) * weights.y
                            + hexSample(_MainTex, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ) * weights.z;
                albedo *= vColor * _MainColor;
                vec3 baseColor = gammaToLinearSpace(albedo.rgb);

                // Normal map — hex sample with UV-rotation correction, then axis world transform.
                //   X: (tn.z*sign(N.x), tn.y, tn.x)
                //   Y: (tn.x, tn.z*sign(N.y), tn.y)
                //   Z: (tn.x, tn.y, tn.z*sign(N.z))
                vec3 tnX = hexSampleNormal(_NormalTex, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX);
                vec3 tnY = hexSampleNormal(_NormalTex, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY);
                vec3 tnZ = hexSampleNormal(_NormalTex, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ);
                vec3 nWX = vec3(tnX.z * sign(N.x), tnX.y, tnX.x);
                vec3 nWY = vec3(tnY.x, tnY.z * sign(N.y), tnY.y);
                vec3 nWZ = vec3(tnZ.x, tnZ.y, tnZ.z * sign(N.z));
                vec3 worldNormal = normalize(nWX * weights.x + nWY * weights.y + nWZ * weights.z);

                // Surface: R=AO, G=Roughness, B=Metallic
                vec4 surface  = hexSample(_SurfaceTex, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX) * weights.x
                              + hexSample(_SurfaceTex, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY) * weights.y
                              + hexSample(_SurfaceTex, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ) * weights.z;
                float ao        = 1.0 - surface.r;
                float roughness = surface.g;
                float metallic  = surface.b;

                // Translucency map: G=extra occlusion, B=thickness
                vec4 transOcc = hexSample(_TranslucencyMap, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX) * weights.x
                              + hexSample(_TranslucencyMap, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY) * weights.y
                              + hexSample(_TranslucencyMap, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ) * weights.z;
                ao *= transOcc.g;
                float translucency = transOcc.b * _TranslucencyStrength;

                // Emission
                vec3 emission = (hexSample(_EmissionTex, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX).rgb * weights.x
                               + hexSample(_EmissionTex, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY).rgb * weights.y
                               + hexSample(_EmissionTex, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ).rgb * weights.z)
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
            uniform float     _TriplanarBlend;

            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            float rHash(vec2 p)
            {
                return fract(sin(dot(p, vec2(41.5, 93.7))) * 43758.5453123);
            }

            vec2 hexRot(vec2 uv, float a)
            {
                float c = cos(a), s = sin(a);
                return vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
            }

            void hexSetup(vec2 uv,
                          out vec2 ox1, out vec2 ox2, out vec2 ox3,
                          out float r1,  out float r2,  out float r3,
                          out vec3 bary)
            {
                const float k         = 0.8660254;
                const float PI_OVER_3 = 1.04719755;
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
                r1 = floor(rHash(v1) * 6.0) * PI_OVER_3;
                r2 = floor(rHash(v2) * 6.0) * PI_OVER_3;
                r3 = floor(rHash(v3) * 6.0) * PI_OVER_3;
            }

            vec4 hexSample(sampler2D tex, vec2 uv,
                           vec2 ox1, vec2 ox2, vec2 ox3,
                           float r1, float r2, float r3, vec3 bary)
            {
                vec4 s1 = texture(tex, hexRot(uv, r1) + ox1);
                vec4 s2 = texture(tex, hexRot(uv, r2) + ox2);
                vec4 s3 = texture(tex, hexRot(uv, r3) + ox3);
                vec4 blended = s1 * bary.x + s2 * bary.y + s3 * bary.z;
                vec4 mean    = (s1 + s2 + s3) / 3.0;
                return mean + (blended - mean) * inversesqrt(dot(bary, bary));
            }

            vec3 hexSampleNormal(sampler2D tex, vec2 uv,
                                 vec2 ox1, vec2 ox2, vec2 ox3,
                                 float r1, float r2, float r3, vec3 bary)
            {
                vec3 n1 = texture(tex, hexRot(uv, r1) + ox1).rgb * 2.0 - 1.0;
                vec3 n2 = texture(tex, hexRot(uv, r2) + ox2).rgb * 2.0 - 1.0;
                vec3 n3 = texture(tex, hexRot(uv, r3) + ox3).rgb * 2.0 - 1.0;
                float c1 = cos(r1), sv1 = sin(r1);
                float c2 = cos(r2), sv2 = sin(r2);
                float c3 = cos(r3), sv3 = sin(r3);
                n1.xy = vec2(n1.x * c1 - n1.y * sv1, n1.x * sv1 + n1.y * c1);
                n2.xy = vec2(n2.x * c2 - n2.y * sv2, n2.x * sv2 + n2.y * c2);
                n3.xy = vec2(n3.x * c3 - n3.y * sv3, n3.x * sv3 + n3.y * c3);
                vec3 blended = n1 * bary.x + n2 * bary.y + n3 * bary.z;
                vec3 mean    = (n1 + n2 + n3) / 3.0;
                return normalize(mean + (blended - mean) * inversesqrt(dot(bary, bary)));
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

                vec2  ox1X, ox2X, ox3X; float r1X, r2X, r3X; vec3 baryX;
                vec2  ox1Y, ox2Y, ox3Y; float r1Y, r2Y, r3Y; vec3 baryY;
                vec2  ox1Z, ox2Z, ox3Z; float r1Z, r2Z, r3Z; vec3 baryZ;
                hexSetup(uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX);
                hexSetup(uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY);
                hexSetup(uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ);

                if (_AlphaCutoff > 0.0)
                {
                    vec4 albedo = hexSample(_MainTex, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX) * weights.x
                                + hexSample(_MainTex, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY) * weights.y
                                + hexSample(_MainTex, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ) * weights.z;
                    if (albedo.a * _MainColor.a < _AlphaCutoff) discard;
                }

                vec3 tnX = hexSampleNormal(_NormalTex, uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX);
                vec3 tnY = hexSampleNormal(_NormalTex, uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY);
                vec3 tnZ = hexSampleNormal(_NormalTex, uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ);
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
            uniform float     _TriplanarBlend;

            vec2 sHash(vec2 p)
            {
                p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
                return fract(sin(p) * 43758.5453123);
            }

            float rHash(vec2 p)
            {
                return fract(sin(dot(p, vec2(41.5, 93.7))) * 43758.5453123);
            }

            vec2 hexRot(vec2 uv, float a)
            {
                float c = cos(a), s = sin(a);
                return vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
            }

            void hexSetup(vec2 uv,
                          out vec2 ox1, out vec2 ox2, out vec2 ox3,
                          out float r1,  out float r2,  out float r3,
                          out vec3 bary)
            {
                const float k         = 0.8660254;
                const float PI_OVER_3 = 1.04719755;
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
                r1 = floor(rHash(v1) * 6.0) * PI_OVER_3;
                r2 = floor(rHash(v2) * 6.0) * PI_OVER_3;
                r3 = floor(rHash(v3) * 6.0) * PI_OVER_3;
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

                    vec2  ox1X, ox2X, ox3X; float r1X, r2X, r3X; vec3 baryX;
                    vec2  ox1Y, ox2Y, ox3Y; float r1Y, r2Y, r3Y; vec3 baryY;
                    vec2  ox1Z, ox2Z, ox3Z; float r1Z, r2Z, r3Z; vec3 baryZ;
                    hexSetup(uvX, ox1X, ox2X, ox3X, r1X, r2X, r3X, baryX);
                    hexSetup(uvY, ox1Y, ox2Y, ox3Y, r1Y, r2Y, r3Y, baryY);
                    hexSetup(uvZ, ox1Z, ox2Z, ox3Z, r1Z, r2Z, r3Z, baryZ);

                    vec4 s1X = texture(_MainTex, hexRot(uvX, r1X) + ox1X);
                    vec4 s2X = texture(_MainTex, hexRot(uvX, r2X) + ox2X);
                    vec4 s3X = texture(_MainTex, hexRot(uvX, r3X) + ox3X);
                    float aX = s1X.a * baryX.x + s2X.a * baryX.y + s3X.a * baryX.z;

                    vec4 s1Y = texture(_MainTex, hexRot(uvY, r1Y) + ox1Y);
                    vec4 s2Y = texture(_MainTex, hexRot(uvY, r2Y) + ox2Y);
                    vec4 s3Y = texture(_MainTex, hexRot(uvY, r3Y) + ox3Y);
                    float aY = s1Y.a * baryY.x + s2Y.a * baryY.y + s3Y.a * baryY.z;

                    vec4 s1Z = texture(_MainTex, hexRot(uvZ, r1Z) + ox1Z);
                    vec4 s2Z = texture(_MainTex, hexRot(uvZ, r2Z) + ox2Z);
                    vec4 s3Z = texture(_MainTex, hexRot(uvZ, r3Z) + ox3Z);
                    float aZ = s1Z.a * baryZ.x + s2Z.a * baryZ.y + s3Z.a * baryZ.z;

                    float alpha = (aX * weights.x + aY * weights.y + aZ * weights.z) * _MainColor.a;
                    if (alpha < _AlphaCutoff) discard;
                }
                gl_FragDepth = gl_FragCoord.z;
            }
        }
    ENDGLSL
}
