Shader "Custom/HexaplanarPOM"

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
            uniform float     _HeightBlendStrength;

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
                ox1 = sHash(v1); ox2 = sHash(v2); ox3 = sHash(v3);
                r1  = floor(rHash(v1) * 6.0) * PI_OVER_3;
                r2  = floor(rHash(v2) * 6.0) * PI_OVER_3;
                r3  = floor(rHash(v3) * 6.0) * PI_OVER_3;
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

            // Samples a normal map with rotation correction so the result is expressed
            // in the unrotated face tangent frame, ready for the per-face world transform.
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

                // -----------------------------------------------------------------------
                // Six-face blend weights — positive and negative halves of each axis
                // separated so top/bottom and each cardinal side can have distinct
                // hex patterns and (optionally) height-biased blending.
                //
                // With sharpness >= 4, at most 3 weights are non-zero per pixel:
                //   only the components of N that are positive (or negative) contribute.
                //   A normal in one octant activates at most 3 of the 6 faces, and with
                //   high sharpness typically just 1-2, matching the performance expectation
                //   of hexaplanar: 1-3 samples per pixel in practice.
                // -----------------------------------------------------------------------
                const float W_MIN = 0.005;

                vec3 nPos    = pow(max( N, vec3(0.0)), vec3(_TriplanarBlend));
                vec3 nNeg    = pow(max(-N, vec3(0.0)), vec3(_TriplanarBlend));
                float wPX    = nPos.x, wNX = nNeg.x;
                float wPY    = nPos.y, wNY = nNeg.y;
                float wPZ    = nPos.z, wNZ = nNeg.z;
                float wSum   = wPX + wNX + wPY + wNY + wPZ + wNZ + 0.0001;
                wPX /= wSum; wNX /= wSum;
                wPY /= wSum; wNY /= wSum;
                wPZ /= wSum; wNZ /= wSum;

                // -----------------------------------------------------------------------
                // Six-face world-space UVs.
                //
                // Each face uses the two world axes orthogonal to its normal as UV.
                // Negative-direction faces flip one component so the hex grid differs
                // from its positive counterpart — this derives from the face's tangent
                // frame (T × B = N) and ensures correct normal-map reconstruction.
                //
                //   Face   UV                  Tangent T        Bitangent B      Normal
                //   +X     ( z,  y)            (0, 0, 1)        (0, 1, 0)        (+1, 0, 0)
                //   -X     (-z,  y)            (0, 0,-1)        (0, 1, 0)        (-1, 0, 0)
                //   +Y     ( x,  z)            (1, 0, 0)        (0, 0, 1)        (0,+1, 0)
                //   -Y     (-x, -z)            (-1,0, 0)        (0, 0,-1)        (0,-1, 0)
                //   +Z     ( x,  y)            (1, 0, 0)        (0, 1, 0)        (0, 0,+1)
                //   -Z     (-x,  y)            (-1,0, 0)        (0, 1, 0)        (0, 0,-1)
                // -----------------------------------------------------------------------
                vec2 uvPX = vec2( worldPos.z,  worldPos.y) * _Tiling;
                vec2 uvNX = vec2(-worldPos.z,  worldPos.y) * _Tiling;
                vec2 uvPY = vec2( worldPos.x,  worldPos.z) * _Tiling;
                vec2 uvNY = vec2(-worldPos.x, -worldPos.z) * _Tiling;
                vec2 uvPZ = vec2( worldPos.x,  worldPos.y) * _Tiling;
                vec2 uvNZ = vec2(-worldPos.x,  worldPos.y) * _Tiling;

                // Hex setup for each face (computed once from pre-POM UVs; surface-anchored)
                vec2  ox1PX,ox2PX,ox3PX; float r1PX,r2PX,r3PX; vec3 baryPX;
                vec2  ox1NX,ox2NX,ox3NX; float r1NX,r2NX,r3NX; vec3 baryNX;
                vec2  ox1PY,ox2PY,ox3PY; float r1PY,r2PY,r3PY; vec3 baryPY;
                vec2  ox1NY,ox2NY,ox3NY; float r1NY,r2NY,r3NY; vec3 baryNY;
                vec2  ox1PZ,ox2PZ,ox3PZ; float r1PZ,r2PZ,r3PZ; vec3 baryPZ;
                vec2  ox1NZ,ox2NZ,ox3NZ; float r1NZ,r2NZ,r3NZ; vec3 baryNZ;

                if (wPX > W_MIN) hexSetup(uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX);
                if (wNX > W_MIN) hexSetup(uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX);
                if (wPY > W_MIN) hexSetup(uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY);
                if (wNY > W_MIN) hexSetup(uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY);
                if (wPZ > W_MIN) hexSetup(uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ);
                if (wNZ > W_MIN) hexSetup(uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ);

                // Blended translation offsets for POM height march (rotation omitted:
                // applying per-cell rotations mid-march causes depth discontinuities).
                vec2 pomOffPX = ox1PX*baryPX.x + ox2PX*baryPX.y + ox3PX*baryPX.z;
                vec2 pomOffNX = ox1NX*baryNX.x + ox2NX*baryNX.y + ox3NX*baryNX.z;
                vec2 pomOffPY = ox1PY*baryPY.x + ox2PY*baryPY.y + ox3PY*baryPY.z;
                vec2 pomOffNY = ox1NY*baryNY.x + ox2NY*baryNY.y + ox3NY*baryNY.z;
                vec2 pomOffPZ = ox1PZ*baryPZ.x + ox2PZ*baryPZ.y + ox3PZ*baryPZ.z;
                vec2 pomOffNZ = ox1NZ*baryNZ.x + ox2NZ*baryNZ.y + ox3NZ*baryNZ.z;

                // -----------------------------------------------------------------------
                // Seamless world-space POM over six faces.
                // viewDir decomposed into depth rate (viewDotN) and surface-tangent drift —
                // both smooth in N, no axis branches. Horizon flattening kills parallax at
                // grazing angles. Height is blended across active faces using W_MIN guards
                // so inactive faces skip their texture fetch every step.
                // -----------------------------------------------------------------------
                if (_Parallax > 0.0 && _ParallaxSteps > 0)
                {
                    float viewDotN = max(dot(viewDir, N), 0.001);
                    float effP     = _Parallax * clamp(viewDotN / 0.3, 0.0, 1.0);
                    vec3  tangDrift = viewDir - viewDotN * N;
                    vec3  worldStep = -tangDrift / (viewDotN * _Tiling) * effP / float(_ParallaxSteps);

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

                        mapH = 0.0;
                        if (wPX > W_MIN) mapH += texture(_ParallaxMap, vec2( curPos.z,  curPos.y)*_Tiling + pomOffPX).g * wPX;
                        if (wNX > W_MIN) mapH += texture(_ParallaxMap, vec2(-curPos.z,  curPos.y)*_Tiling + pomOffNX).g * wNX;
                        if (wPY > W_MIN) mapH += texture(_ParallaxMap, vec2( curPos.x,  curPos.z)*_Tiling + pomOffPY).g * wPY;
                        if (wNY > W_MIN) mapH += texture(_ParallaxMap, vec2(-curPos.x, -curPos.z)*_Tiling + pomOffNY).g * wNY;
                        if (wPZ > W_MIN) mapH += texture(_ParallaxMap, vec2( curPos.x,  curPos.y)*_Tiling + pomOffPZ).g * wPZ;
                        if (wNZ > W_MIN) mapH += texture(_ParallaxMap, vec2(-curPos.x,  curPos.y)*_Tiling + pomOffNZ).g * wNZ;

                        if (layerDepth >= 1.0 - mapH) break;
                    }

                    float d0    = (layerDepth - stepSize) - (1.0 - prevMapH);
                    float d1    = layerDepth - (1.0 - mapH);
                    float denom = d1 - d0;
                    float t     = abs(denom) > 0.0001 ? clamp(-d0 / denom, 0.0, 1.0) : 0.5;
                    curPos = mix(prevPos, curPos, t);

                    uvPX = vec2( curPos.z,  curPos.y) * _Tiling;
                    uvNX = vec2(-curPos.z,  curPos.y) * _Tiling;
                    uvPY = vec2( curPos.x,  curPos.z) * _Tiling;
                    uvNY = vec2(-curPos.x, -curPos.z) * _Tiling;
                    uvPZ = vec2( curPos.x,  curPos.y) * _Tiling;
                    uvNZ = vec2(-curPos.x,  curPos.y) * _Tiling;
                }

                // -----------------------------------------------------------------------
                // Height-biased blend weights.
                // Per-face height samples shift the face weights so taller features
                // dominate at face transitions (e.g. a rock edge vs flat ground).
                // The soft threshold (0.2 margin) keeps at least one face active.
                // -----------------------------------------------------------------------
                float fwPX = wPX, fwNX = wNX;
                float fwPY = wPY, fwNY = wNY;
                float fwPZ = wPZ, fwNZ = wNZ;

                if (_HeightBlendStrength > 0.001)
                {
                    float hPX = 0.0, hNX = 0.0, hPY = 0.0, hNY = 0.0, hPZ = 0.0, hNZ = 0.0;
                    if (wPX > W_MIN) hPX = hexSample(_ParallaxMap, uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX).g;
                    if (wNX > W_MIN) hNX = hexSample(_ParallaxMap, uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX).g;
                    if (wPY > W_MIN) hPY = hexSample(_ParallaxMap, uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY).g;
                    if (wNY > W_MIN) hNY = hexSample(_ParallaxMap, uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY).g;
                    if (wPZ > W_MIN) hPZ = hexSample(_ParallaxMap, uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ).g;
                    if (wNZ > W_MIN) hNZ = hexSample(_ParallaxMap, uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ).g;

                    float bPX = wPX + hPX, bNX = wNX + hNX;
                    float bPY = wPY + hPY, bNY = wNY + hNY;
                    float bPZ = wPZ + hPZ, bNZ = wNZ + hNZ;

                    float hM = max(max(max(bPX, bNX), max(bPY, bNY)), max(bPZ, bNZ));
                    bPX = max(bPX - (hM - 0.2), 0.0);
                    bNX = max(bNX - (hM - 0.2), 0.0);
                    bPY = max(bPY - (hM - 0.2), 0.0);
                    bNY = max(bNY - (hM - 0.2), 0.0);
                    bPZ = max(bPZ - (hM - 0.2), 0.0);
                    bNZ = max(bNZ - (hM - 0.2), 0.0);

                    float hSum = bPX + bNX + bPY + bNY + bPZ + bNZ + 0.0001;
                    bPX /= hSum; bNX /= hSum; bPY /= hSum; bNY /= hSum; bPZ /= hSum; bNZ /= hSum;

                    fwPX = mix(wPX, bPX, _HeightBlendStrength);
                    fwNX = mix(wNX, bNX, _HeightBlendStrength);
                    fwPY = mix(wPY, bPY, _HeightBlendStrength);
                    fwNY = mix(wNY, bNY, _HeightBlendStrength);
                    fwPZ = mix(wPZ, bPZ, _HeightBlendStrength);
                    fwNZ = mix(wNZ, bNZ, _HeightBlendStrength);

                    float fwSum = fwPX + fwNX + fwPY + fwNY + fwPZ + fwNZ + 0.0001;
                    fwPX /= fwSum; fwNX /= fwSum; fwPY /= fwSum;
                    fwNY /= fwSum; fwPZ /= fwSum; fwNZ /= fwSum;
                }

                // -----------------------------------------------------------------------
                // Albedo — full hex sample per active face, blended by final weights
                // -----------------------------------------------------------------------
                vec4 albedo = vec4(0.0);
                if (fwPX > W_MIN) albedo += hexSample(_MainTex, uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX) * fwPX;
                if (fwNX > W_MIN) albedo += hexSample(_MainTex, uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX) * fwNX;
                if (fwPY > W_MIN) albedo += hexSample(_MainTex, uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY) * fwPY;
                if (fwNY > W_MIN) albedo += hexSample(_MainTex, uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY) * fwNY;
                if (fwPZ > W_MIN) albedo += hexSample(_MainTex, uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ) * fwPZ;
                if (fwNZ > W_MIN) albedo += hexSample(_MainTex, uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ) * fwNZ;
                albedo *= vColor * _MainColor;
                vec3 baseColor = gammaToLinearSpace(albedo.rgb);

                // -----------------------------------------------------------------------
                // Normal map — hex sample with UV-rotation correction, then face-specific
                // tangent-frame → world-space transform.
                //
                // Derivation: for each face UV = (u_axis, v_axis) × Tiling, the tangent
                // frame is T = normalize(d(worldPos)/d(UV.x)), B = normalize(d(worldPos)/d(UV.y)).
                // A tangent-space normal tn maps to world via: tn.x*T + tn.y*B + tn.z*N_face.
                //
                //   +X: T=(0,0, 1) B=(0,1,0) → world = ( tn.z,  tn.y,  tn.x)
                //   -X: T=(0,0,-1) B=(0,1,0) → world = (-tn.z,  tn.y, -tn.x)
                //   +Y: T=(1,0, 0) B=(0,0,1) → world = ( tn.x,  tn.z,  tn.y)
                //   -Y: T=(-1,0,0) B=(0,0,-1)→ world = (-tn.x, -tn.z, -tn.y) -- flat(0,0,1)→(0,-1,0) ✓
                //   +Z: T=(1,0, 0) B=(0,1,0) → world = ( tn.x,  tn.y,  tn.z)
                //   -Z: T=(-1,0,0) B=(0,1,0) → world = (-tn.x,  tn.y, -tn.z)
                // -----------------------------------------------------------------------
                vec3 worldNormal = vec3(0.0);
                if (fwPX > W_MIN) { vec3 tn = hexSampleNormal(_NormalTex, uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX); worldNormal += vec3( tn.z,  tn.y,  tn.x) * fwPX; }
                if (fwNX > W_MIN) { vec3 tn = hexSampleNormal(_NormalTex, uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX); worldNormal += vec3(-tn.z,  tn.y, -tn.x) * fwNX; }
                if (fwPY > W_MIN) { vec3 tn = hexSampleNormal(_NormalTex, uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY); worldNormal += vec3( tn.x,  tn.z,  tn.y) * fwPY; }
                if (fwNY > W_MIN) { vec3 tn = hexSampleNormal(_NormalTex, uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY); worldNormal += vec3(-tn.x, -tn.z, -tn.y) * fwNY; }
                if (fwPZ > W_MIN) { vec3 tn = hexSampleNormal(_NormalTex, uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ); worldNormal += vec3( tn.x,  tn.y,  tn.z) * fwPZ; }
                if (fwNZ > W_MIN) { vec3 tn = hexSampleNormal(_NormalTex, uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ); worldNormal += vec3(-tn.x,  tn.y, -tn.z) * fwNZ; }
                worldNormal = normalize(worldNormal);

                // Surface: R=AO, G=Roughness, B=Metallic
                vec4 surface = vec4(0.0);
                if (fwPX > W_MIN) surface += hexSample(_SurfaceTex, uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX) * fwPX;
                if (fwNX > W_MIN) surface += hexSample(_SurfaceTex, uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX) * fwNX;
                if (fwPY > W_MIN) surface += hexSample(_SurfaceTex, uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY) * fwPY;
                if (fwNY > W_MIN) surface += hexSample(_SurfaceTex, uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY) * fwNY;
                if (fwPZ > W_MIN) surface += hexSample(_SurfaceTex, uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ) * fwPZ;
                if (fwNZ > W_MIN) surface += hexSample(_SurfaceTex, uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ) * fwNZ;
                float ao        = 1.0 - surface.r;
                float roughness = surface.g;
                float metallic  = surface.b;

                // Translucency map: G=extra occlusion, B=thickness
                vec4 transOcc = vec4(0.0);
                if (fwPX > W_MIN) transOcc += hexSample(_TranslucencyMap, uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX) * fwPX;
                if (fwNX > W_MIN) transOcc += hexSample(_TranslucencyMap, uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX) * fwNX;
                if (fwPY > W_MIN) transOcc += hexSample(_TranslucencyMap, uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY) * fwPY;
                if (fwNY > W_MIN) transOcc += hexSample(_TranslucencyMap, uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY) * fwNY;
                if (fwPZ > W_MIN) transOcc += hexSample(_TranslucencyMap, uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ) * fwPZ;
                if (fwNZ > W_MIN) transOcc += hexSample(_TranslucencyMap, uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ) * fwNZ;
                ao *= transOcc.g;
                float translucency = transOcc.b * _TranslucencyStrength;

                // Emission
                vec3 emission = vec3(0.0);
                if (fwPX > W_MIN) emission += hexSample(_EmissionTex, uvPX, ox1PX,ox2PX,ox3PX, r1PX,r2PX,r3PX, baryPX).rgb * fwPX;
                if (fwNX > W_MIN) emission += hexSample(_EmissionTex, uvNX, ox1NX,ox2NX,ox3NX, r1NX,r2NX,r3NX, baryNX).rgb * fwNX;
                if (fwPY > W_MIN) emission += hexSample(_EmissionTex, uvPY, ox1PY,ox2PY,ox3PY, r1PY,r2PY,r3PY, baryPY).rgb * fwPY;
                if (fwNY > W_MIN) emission += hexSample(_EmissionTex, uvNY, ox1NY,ox2NY,ox3NY, r1NY,r2NY,r3NY, baryNY).rgb * fwNY;
                if (fwPZ > W_MIN) emission += hexSample(_EmissionTex, uvPZ, ox1PZ,ox2PZ,ox3PZ, r1PZ,r2PZ,r3PZ, baryPZ).rgb * fwPZ;
                if (fwNZ > W_MIN) emission += hexSample(_EmissionTex, uvNZ, ox1NZ,ox2NZ,ox3NZ, r1NZ,r2NZ,r3NZ, baryNZ).rgb * fwNZ;
                emission *= _EmissionIntensity;

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
                        vec3 scatter    = CalculateTranslucency(lightDir, viewDir, worldNormal,
                                              translucency, _ScatteringPower,
                                              _ScatteringDistortion, _ScatteringScale, lightColor);
                        lighting += scatter * baseColor;
                    }
                }

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
            float rHash(vec2 p) { return fract(sin(dot(p, vec2(41.5, 93.7))) * 43758.5453123); }
            vec2 hexRot(vec2 uv, float a) { float c=cos(a),s=sin(a); return vec2(uv.x*c-uv.y*s, uv.x*s+uv.y*c); }

            void hexSetup(vec2 uv,
                          out vec2 ox1, out vec2 ox2, out vec2 ox3,
                          out float r1,  out float r2,  out float r3,
                          out vec3 bary)
            {
                const float k=0.8660254, P3=1.04719755;
                vec2 g=vec2(uv.x+uv.y*0.5, uv.y*k), i=floor(g), f=fract(g);
                vec2 v1,v2,v3;
                if (f.x+f.y < 1.0) { v1=i; v2=i+vec2(1,0); v3=i+vec2(0,1); bary=vec3(1.0-f.x-f.y,f.x,f.y); }
                else                { v1=i+vec2(1,1); v2=i+vec2(0,1); v3=i+vec2(1,0); bary=vec3(f.x+f.y-1.0,1.0-f.x,1.0-f.y); }
                ox1=sHash(v1); ox2=sHash(v2); ox3=sHash(v3);
                r1=floor(rHash(v1)*6.0)*P3; r2=floor(rHash(v2)*6.0)*P3; r3=floor(rHash(v3)*6.0)*P3;
            }

            vec4 hexSample(sampler2D tex, vec2 uv,
                           vec2 ox1, vec2 ox2, vec2 ox3,
                           float r1, float r2, float r3, vec3 bary)
            {
                vec4 s1=texture(tex,hexRot(uv,r1)+ox1), s2=texture(tex,hexRot(uv,r2)+ox2), s3=texture(tex,hexRot(uv,r3)+ox3);
                vec4 bl=s1*bary.x+s2*bary.y+s3*bary.z, mn=(s1+s2+s3)/3.0;
                return mn+(bl-mn)*inversesqrt(dot(bary,bary));
            }

            vec3 hexSampleNormal(sampler2D tex, vec2 uv,
                                 vec2 ox1, vec2 ox2, vec2 ox3,
                                 float r1, float r2, float r3, vec3 bary)
            {
                vec3 n1=texture(tex,hexRot(uv,r1)+ox1).rgb*2.0-1.0;
                vec3 n2=texture(tex,hexRot(uv,r2)+ox2).rgb*2.0-1.0;
                vec3 n3=texture(tex,hexRot(uv,r3)+ox3).rgb*2.0-1.0;
                float c1=cos(r1),sv1=sin(r1), c2=cos(r2),sv2=sin(r2), c3=cos(r3),sv3=sin(r3);
                n1.xy=vec2(n1.x*c1-n1.y*sv1, n1.x*sv1+n1.y*c1);
                n2.xy=vec2(n2.x*c2-n2.y*sv2, n2.x*sv2+n2.y*c2);
                n3.xy=vec2(n3.x*c3-n3.y*sv3, n3.x*sv3+n3.y*c3);
                vec3 bl=n1*bary.x+n2*bary.y+n3*bary.z, mn=(n1+n2+n3)/3.0;
                return normalize(mn+(bl-mn)*inversesqrt(dot(bary,bary)));
            }

            void main()
            {
                const float W_MIN = 0.005;
                vec3 N = normalize(vNormal);
                vec3 nPos = pow(max( N, vec3(0.0)), vec3(_TriplanarBlend));
                vec3 nNeg = pow(max(-N, vec3(0.0)), vec3(_TriplanarBlend));
                float wPX=nPos.x, wNX=nNeg.x, wPY=nPos.y, wNY=nNeg.y, wPZ=nPos.z, wNZ=nNeg.z;
                float wS=wPX+wNX+wPY+wNY+wPZ+wNZ+0.0001;
                wPX/=wS; wNX/=wS; wPY/=wS; wNY/=wS; wPZ/=wS; wNZ/=wS;

                vec2 uvPX=vec2( worldPos.z, worldPos.y)*_Tiling, uvNX=vec2(-worldPos.z, worldPos.y)*_Tiling;
                vec2 uvPY=vec2( worldPos.x, worldPos.z)*_Tiling, uvNY=vec2(-worldPos.x,-worldPos.z)*_Tiling;
                vec2 uvPZ=vec2( worldPos.x, worldPos.y)*_Tiling, uvNZ=vec2(-worldPos.x, worldPos.y)*_Tiling;

                vec2 ox1PX,ox2PX,ox3PX; float r1PX,r2PX,r3PX; vec3 baryPX;
                vec2 ox1NX,ox2NX,ox3NX; float r1NX,r2NX,r3NX; vec3 baryNX;
                vec2 ox1PY,ox2PY,ox3PY; float r1PY,r2PY,r3PY; vec3 baryPY;
                vec2 ox1NY,ox2NY,ox3NY; float r1NY,r2NY,r3NY; vec3 baryNY;
                vec2 ox1PZ,ox2PZ,ox3PZ; float r1PZ,r2PZ,r3PZ; vec3 baryPZ;
                vec2 ox1NZ,ox2NZ,ox3NZ; float r1NZ,r2NZ,r3NZ; vec3 baryNZ;
                if (wPX>W_MIN) hexSetup(uvPX,ox1PX,ox2PX,ox3PX,r1PX,r2PX,r3PX,baryPX);
                if (wNX>W_MIN) hexSetup(uvNX,ox1NX,ox2NX,ox3NX,r1NX,r2NX,r3NX,baryNX);
                if (wPY>W_MIN) hexSetup(uvPY,ox1PY,ox2PY,ox3PY,r1PY,r2PY,r3PY,baryPY);
                if (wNY>W_MIN) hexSetup(uvNY,ox1NY,ox2NY,ox3NY,r1NY,r2NY,r3NY,baryNY);
                if (wPZ>W_MIN) hexSetup(uvPZ,ox1PZ,ox2PZ,ox3PZ,r1PZ,r2PZ,r3PZ,baryPZ);
                if (wNZ>W_MIN) hexSetup(uvNZ,ox1NZ,ox2NZ,ox3NZ,r1NZ,r2NZ,r3NZ,baryNZ);

                if (_AlphaCutoff > 0.0)
                {
                    vec4 a = vec4(0.0);
                    if (wPX>W_MIN) a += hexSample(_MainTex,uvPX,ox1PX,ox2PX,ox3PX,r1PX,r2PX,r3PX,baryPX)*wPX;
                    if (wNX>W_MIN) a += hexSample(_MainTex,uvNX,ox1NX,ox2NX,ox3NX,r1NX,r2NX,r3NX,baryNX)*wNX;
                    if (wPY>W_MIN) a += hexSample(_MainTex,uvPY,ox1PY,ox2PY,ox3PY,r1PY,r2PY,r3PY,baryPY)*wPY;
                    if (wNY>W_MIN) a += hexSample(_MainTex,uvNY,ox1NY,ox2NY,ox3NY,r1NY,r2NY,r3NY,baryNY)*wNY;
                    if (wPZ>W_MIN) a += hexSample(_MainTex,uvPZ,ox1PZ,ox2PZ,ox3PZ,r1PZ,r2PZ,r3PZ,baryPZ)*wPZ;
                    if (wNZ>W_MIN) a += hexSample(_MainTex,uvNZ,ox1NZ,ox2NZ,ox3NZ,r1NZ,r2NZ,r3NZ,baryNZ)*wNZ;
                    if (a.a * _MainColor.a < _AlphaCutoff) discard;
                }

                vec3 wn = vec3(0.0);
                if (wPX>W_MIN) { vec3 tn=hexSampleNormal(_NormalTex,uvPX,ox1PX,ox2PX,ox3PX,r1PX,r2PX,r3PX,baryPX); wn+=vec3( tn.z, tn.y, tn.x)*wPX; }
                if (wNX>W_MIN) { vec3 tn=hexSampleNormal(_NormalTex,uvNX,ox1NX,ox2NX,ox3NX,r1NX,r2NX,r3NX,baryNX); wn+=vec3(-tn.z, tn.y,-tn.x)*wNX; }
                if (wPY>W_MIN) { vec3 tn=hexSampleNormal(_NormalTex,uvPY,ox1PY,ox2PY,ox3PY,r1PY,r2PY,r3PY,baryPY); wn+=vec3( tn.x, tn.z, tn.y)*wPY; }
                if (wNY>W_MIN) { vec3 tn=hexSampleNormal(_NormalTex,uvNY,ox1NY,ox2NY,ox3NY,r1NY,r2NY,r3NY,baryNY); wn+=vec3(-tn.x,-tn.z,-tn.y)*wNY; }
                if (wPZ>W_MIN) { vec3 tn=hexSampleNormal(_NormalTex,uvPZ,ox1PZ,ox2PZ,ox3PZ,r1PZ,r2PZ,r3PZ,baryPZ); wn+=vec3( tn.x, tn.y, tn.z)*wPZ; }
                if (wNZ>W_MIN) { vec3 tn=hexSampleNormal(_NormalTex,uvNZ,ox1NZ,ox2NZ,ox3NZ,r1NZ,r2NZ,r3NZ,baryNZ); wn+=vec3(-tn.x, tn.y,-tn.z)*wNZ; }

                normalOut = EncodeViewNormal(normalize(wn));
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
            float rHash(vec2 p) { return fract(sin(dot(p, vec2(41.5, 93.7))) * 43758.5453123); }
            vec2 hexRot(vec2 uv, float a) { float c=cos(a),s=sin(a); return vec2(uv.x*c-uv.y*s, uv.x*s+uv.y*c); }

            void hexSetup(vec2 uv,
                          out vec2 ox1, out vec2 ox2, out vec2 ox3,
                          out float r1,  out float r2,  out float r3,
                          out vec3 bary)
            {
                const float k=0.8660254, P3=1.04719755;
                vec2 g=vec2(uv.x+uv.y*0.5, uv.y*k), i=floor(g), f=fract(g);
                vec2 v1,v2,v3;
                if (f.x+f.y < 1.0) { v1=i; v2=i+vec2(1,0); v3=i+vec2(0,1); bary=vec3(1.0-f.x-f.y,f.x,f.y); }
                else                { v1=i+vec2(1,1); v2=i+vec2(0,1); v3=i+vec2(1,0); bary=vec3(f.x+f.y-1.0,1.0-f.x,1.0-f.y); }
                ox1=sHash(v1); ox2=sHash(v2); ox3=sHash(v3);
                r1=floor(rHash(v1)*6.0)*P3; r2=floor(rHash(v2)*6.0)*P3; r3=floor(rHash(v3)*6.0)*P3;
            }

            void main()
            {
                if (_AlphaCutoff > 0.0)
                {
                    const float W_MIN = 0.005;
                    vec3 N = normalize(vNormal);
                    vec3 nPos = pow(max( N, vec3(0.0)), vec3(_TriplanarBlend));
                    vec3 nNeg = pow(max(-N, vec3(0.0)), vec3(_TriplanarBlend));
                    float wPX=nPos.x, wNX=nNeg.x, wPY=nPos.y, wNY=nNeg.y, wPZ=nPos.z, wNZ=nNeg.z;
                    float wS=wPX+wNX+wPY+wNY+wPZ+wNZ+0.0001;
                    wPX/=wS; wNX/=wS; wPY/=wS; wNY/=wS; wPZ/=wS; wNZ/=wS;

                    vec2 uvPX=vec2( worldPos.z, worldPos.y)*_Tiling, uvNX=vec2(-worldPos.z, worldPos.y)*_Tiling;
                    vec2 uvPY=vec2( worldPos.x, worldPos.z)*_Tiling, uvNY=vec2(-worldPos.x,-worldPos.z)*_Tiling;
                    vec2 uvPZ=vec2( worldPos.x, worldPos.y)*_Tiling, uvNZ=vec2(-worldPos.x, worldPos.y)*_Tiling;

                    vec2 ox1PX,ox2PX,ox3PX; float r1PX,r2PX,r3PX; vec3 baryPX;
                    vec2 ox1NX,ox2NX,ox3NX; float r1NX,r2NX,r3NX; vec3 baryNX;
                    vec2 ox1PY,ox2PY,ox3PY; float r1PY,r2PY,r3PY; vec3 baryPY;
                    vec2 ox1NY,ox2NY,ox3NY; float r1NY,r2NY,r3NY; vec3 baryNY;
                    vec2 ox1PZ,ox2PZ,ox3PZ; float r1PZ,r2PZ,r3PZ; vec3 baryPZ;
                    vec2 ox1NZ,ox2NZ,ox3NZ; float r1NZ,r2NZ,r3NZ; vec3 baryNZ;
                    if (wPX>W_MIN) hexSetup(uvPX,ox1PX,ox2PX,ox3PX,r1PX,r2PX,r3PX,baryPX);
                    if (wNX>W_MIN) hexSetup(uvNX,ox1NX,ox2NX,ox3NX,r1NX,r2NX,r3NX,baryNX);
                    if (wPY>W_MIN) hexSetup(uvPY,ox1PY,ox2PY,ox3PY,r1PY,r2PY,r3PY,baryPY);
                    if (wNY>W_MIN) hexSetup(uvNY,ox1NY,ox2NY,ox3NY,r1NY,r2NY,r3NY,baryNY);
                    if (wPZ>W_MIN) hexSetup(uvPZ,ox1PZ,ox2PZ,ox3PZ,r1PZ,r2PZ,r3PZ,baryPZ);
                    if (wNZ>W_MIN) hexSetup(uvNZ,ox1NZ,ox2NZ,ox3NZ,r1NZ,r2NZ,r3NZ,baryNZ);

                    float alpha = 0.0;
                    if (wPX>W_MIN) { vec4 s1=texture(_MainTex,hexRot(uvPX,r1PX)+ox1PX), s2=texture(_MainTex,hexRot(uvPX,r2PX)+ox2PX), s3=texture(_MainTex,hexRot(uvPX,r3PX)+ox3PX); alpha+=(s1.a*baryPX.x+s2.a*baryPX.y+s3.a*baryPX.z)*wPX; }
                    if (wNX>W_MIN) { vec4 s1=texture(_MainTex,hexRot(uvNX,r1NX)+ox1NX), s2=texture(_MainTex,hexRot(uvNX,r2NX)+ox2NX), s3=texture(_MainTex,hexRot(uvNX,r3NX)+ox3NX); alpha+=(s1.a*baryNX.x+s2.a*baryNX.y+s3.a*baryNX.z)*wNX; }
                    if (wPY>W_MIN) { vec4 s1=texture(_MainTex,hexRot(uvPY,r1PY)+ox1PY), s2=texture(_MainTex,hexRot(uvPY,r2PY)+ox2PY), s3=texture(_MainTex,hexRot(uvPY,r3PY)+ox3PY); alpha+=(s1.a*baryPY.x+s2.a*baryPY.y+s3.a*baryPY.z)*wPY; }
                    if (wNY>W_MIN) { vec4 s1=texture(_MainTex,hexRot(uvNY,r1NY)+ox1NY), s2=texture(_MainTex,hexRot(uvNY,r2NY)+ox2NY), s3=texture(_MainTex,hexRot(uvNY,r3NY)+ox3NY); alpha+=(s1.a*baryNY.x+s2.a*baryNY.y+s3.a*baryNY.z)*wNY; }
                    if (wPZ>W_MIN) { vec4 s1=texture(_MainTex,hexRot(uvPZ,r1PZ)+ox1PZ), s2=texture(_MainTex,hexRot(uvPZ,r2PZ)+ox2PZ), s3=texture(_MainTex,hexRot(uvPZ,r3PZ)+ox3PZ); alpha+=(s1.a*baryPZ.x+s2.a*baryPZ.y+s3.a*baryPZ.z)*wPZ; }
                    if (wNZ>W_MIN) { vec4 s1=texture(_MainTex,hexRot(uvNZ,r1NZ)+ox1NZ), s2=texture(_MainTex,hexRot(uvNZ,r2NZ)+ox2NZ), s3=texture(_MainTex,hexRot(uvNZ,r3NZ)+ox3NZ); alpha+=(s1.a*baryNZ.x+s2.a*baryNZ.y+s3.a*baryNZ.z)*wNZ; }

                    if (alpha * _MainColor.a < _AlphaCutoff) discard;
                }
                gl_FragDepth = gl_FragCoord.z;
            }
        }
    ENDGLSL
}
