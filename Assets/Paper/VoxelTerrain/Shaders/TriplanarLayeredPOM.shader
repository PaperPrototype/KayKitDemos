Shader "Custom/TriplanarLayeredPOM"

Properties
{
    // --- Rock / sides / bottom ---
    _MainTex ("Rock Albedo", Texture2D) = "grid"
    _MainColor ("Rock Tint", Color) = (1.0, 1.0, 1.0, 1.0)
    _Tiling ("Rock Tiling", Float) = 1.0
    _TriplanarBlend ("Blend Sharpness", Float) = 4.0

    _NormalTex ("Rock Normal", Texture2D) = "normal"
    _SurfaceTex ("Rock Surface (AO, Roughness, Metallicness)", Texture2D) = "surface"
    _EmissionTex ("Emission", Texture2D) = "emission"
    _EmissionIntensity ("Emission Intensity", Float) = 1.0

    _AlphaCutoff ("Alpha Cutoff", Float) = 0.5

    _ParallaxMap ("Rock Height Map (G)", Texture2D) = "black"
    _Parallax ("Rock Height Scale", Float) = 0.0
    _ParallaxSteps ("POM Steps", Int) = 16

    _TranslucencyMap ("Translucency (B) Occlusion (G)", Texture2D) = "white"
    _TranslucencyStrength ("Translucency Strength", Float) = 0.0
    _ScatteringPower ("Scattering Power", Float) = 0.0
    _ScatteringDistortion ("Scattering Distortion", Float) = 0.5
    _ScatteringScale ("Scattering Scale", Float) = 1.0

    // --- Grass / top ---
    _TopTex ("Top Albedo (Grass)", Texture2D) = "grid"
    _TopColor ("Top Tint", Color) = (1.0, 1.0, 1.0, 1.0)
    _TopTiling ("Top Tiling", Float) = 1.0
    _TopNormalTex ("Top Normal", Texture2D) = "normal"
    _TopSurfaceTex ("Top Surface (AO, Roughness, Metallicness)", Texture2D) = "surface"
    _TopParallaxMap ("Top Height Map (G)", Texture2D) = "black"
    _TopParallax ("Top Height Scale", Float) = 0.0

    // Higher = grass appears only on more directly upward-facing surfaces (sharper rock/grass edge)
    // Lower = grass bleeds further onto slopes. ~16 works well for axis-aligned voxel meshes.
    _TopBlendSharpness ("Top Blend Sharpness", Float) = 1.0
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

            // Rock
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
            uniform sampler2D _TranslucencyMap;
            uniform float _TranslucencyStrength;
            uniform float _ScatteringPower;
            uniform float _ScatteringDistortion;
            uniform float _ScatteringScale;

            // Top / grass
            uniform sampler2D _TopTex;
            uniform vec4 _TopColor;
            uniform float _TopTiling;
            uniform sampler2D _TopNormalTex;
            uniform sampler2D _TopSurfaceTex;
            uniform sampler2D _TopParallaxMap;
            uniform float _TopParallax;
            uniform float _TopBlendSharpness;

            void main()
            {
                vec3 N = normalize(vNormal);
                vec3 viewDir = normalize(_WorldSpaceCameraPos.xyz - worldPos);

                // How much this surface faces up — drives rock-to-grass blend.
                // Power function: high exponent snaps to 0/1 quickly so averaged vertex normals
                // at face boundaries don't bleed the blend into the interior of each face.
                float topFactor = pow(clamp(N.y, 0.0, 1.0), _TopBlendSharpness);

                // Triplanar blend weights
                vec3 absN = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

                // World-space UVs (pre-POM)
                vec2 uvX     = worldPos.zy * _Tiling;
                vec2 uvY     = worldPos.xz * _Tiling;
                vec2 uvZ     = worldPos.xy * _Tiling;
                vec2 uvY_top = worldPos.xz * _TopTiling;

                // Seamless triplanar POM.
                // The Y projection blends rock and grass heightmaps according to topFactor
                // so the POM depth is consistent with the final blended surface.
                float pomScale = max(_Parallax, _TopParallax * topFactor);
                if (pomScale > 0.0 && _ParallaxSteps > 0)
                {
                    float viewDotN  = max(dot(viewDir, N), 0.001);
                    vec3  tangDrift = viewDir - viewDotN * N;
                    vec3 worldStep = -tangDrift / (viewDotN * _Tiling)
                                   * pomScale / float(_ParallaxSteps);

                    float stepSize   = 1.0 / float(_ParallaxSteps);
                    float layerDepth = 0.0;
                    vec3  curPos     = worldPos;
                    vec3  prevPos    = worldPos;
                    float mapH       = 1.0;
                    float prevMapH   = 1.0;

                    for (int i = 0; i < _ParallaxSteps; i++)
                    {
                        prevPos  = curPos;
                        prevMapH = mapH;
                        curPos  += worldStep;
                        layerDepth += stepSize;

                        float rockH_Y = texture(_ParallaxMap,    curPos.xz * _Tiling).g;
                        float topH_Y  = texture(_TopParallaxMap, curPos.xz * _TopTiling).g;

                        mapH = texture(_ParallaxMap, curPos.zy * _Tiling).g  * weights.x
                             + mix(rockH_Y, topH_Y, topFactor)               * weights.y
                             + texture(_ParallaxMap, curPos.xy * _Tiling).g  * weights.z;

                        if (layerDepth >= 1.0 - mapH) break;
                    }

                    float d0    = (layerDepth - stepSize) - (1.0 - prevMapH);
                    float d1    = layerDepth - (1.0 - mapH);
                    float denom = d1 - d0;
                    float t     = abs(denom) > 0.0001 ? clamp(-d0 / denom, 0.0, 1.0) : 0.5;
                    curPos = mix(prevPos, curPos, t);

                    uvX     = curPos.zy * _Tiling;
                    uvY     = curPos.xz * _Tiling;
                    uvZ     = curPos.xy * _Tiling;
                    uvY_top = curPos.xz * _TopTiling;
                }

                // Albedo — Y projection blends rock with grass
                vec4 yAlbedo = mix(texture(_MainTex, uvY),
                                   texture(_TopTex, uvY_top) * _TopColor,
                                   topFactor);
                vec4 albedo = (texture(_MainTex, uvX) * weights.x
                             + yAlbedo                * weights.y
                             + texture(_MainTex, uvZ) * weights.z)
                            * vColor * _MainColor;
                vec3 baseColor = gammaToLinearSpace(albedo.rgb);

                // Normals — same blend strategy on the Y axis
                vec3 tnX = texture(_NormalTex, uvX).rgb * 2.0 - 1.0;
                vec3 tnY = texture(_NormalTex, uvY).rgb * 2.0 - 1.0;
                vec3 tnZ = texture(_NormalTex, uvZ).rgb * 2.0 - 1.0;
                vec3 tnY_top = texture(_TopNormalTex, uvY_top).rgb * 2.0 - 1.0;

                vec3 nWX      = vec3(tnX.z * sign(N.x), tnX.y, tnX.x);
                vec3 nWY_rock = vec3(tnY.x, tnY.z * sign(N.y), tnY.y);
                vec3 nWY_top  = vec3(tnY_top.x, tnY_top.z * sign(N.y), tnY_top.y);
                vec3 nWY      = mix(nWY_rock, nWY_top, topFactor);
                vec3 nWZ      = vec3(tnZ.x, tnZ.y, tnZ.z * sign(N.z));
                vec3 worldNormal = normalize(nWX * weights.x + nWY * weights.y + nWZ * weights.z);

                // Surface (AO / Roughness / Metallic) — same blend on Y
                vec4 ySurface = mix(texture(_SurfaceTex, uvY),
                                    texture(_TopSurfaceTex, uvY_top),
                                    topFactor);
                vec4 surface = texture(_SurfaceTex, uvX) * weights.x
                             + ySurface                  * weights.y
                             + texture(_SurfaceTex, uvZ) * weights.z;
                float ao        = 1.0 - surface.r;
                float roughness = surface.g;
                float metallic  = surface.b;

                // Translucency map (rock only — grass rarely needs SSS)
                vec4 transOcc = texture(_TranslucencyMap, uvX) * weights.x
                              + texture(_TranslucencyMap, uvY) * weights.y
                              + texture(_TranslucencyMap, uvZ) * weights.z;
                ao *= transOcc.g;
                float translucency = transOcc.b * _TranslucencyStrength;

                // Emission
                vec3 emission = (texture(_EmissionTex, uvX).rgb * weights.x
                               + texture(_EmissionTex, uvY).rgb * weights.y
                               + texture(_EmissionTex, uvZ).rgb * weights.z) * _EmissionIntensity;

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
            uniform sampler2D _TopNormalTex;
            uniform sampler2D _MainTex;
            uniform vec4 _MainColor;
            uniform float _AlphaCutoff;
            uniform float _Tiling;
            uniform float _TopTiling;
            uniform float _TriplanarBlend;
            uniform float _TopBlendSharpness;

            void main()
            {
                vec3 N = normalize(vNormal);
                vec3 absN = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

                float topFactor = pow(clamp(N.y, 0.0, 1.0), _TopBlendSharpness);

                if (_AlphaCutoff > 0.0)
                {
                    vec4 albedo = texture(_MainTex, worldPos.zy * _Tiling) * weights.x
                                + texture(_MainTex, worldPos.xz * _Tiling) * weights.y
                                + texture(_MainTex, worldPos.xy * _Tiling) * weights.z;
                    if (albedo.a * _MainColor.a < _AlphaCutoff) discard;
                }

                vec3 tnX = texture(_NormalTex, worldPos.zy * _Tiling).rgb * 2.0 - 1.0;
                vec3 tnY = texture(_NormalTex, worldPos.xz * _Tiling).rgb * 2.0 - 1.0;
                vec3 tnZ = texture(_NormalTex, worldPos.xy * _Tiling).rgb * 2.0 - 1.0;
                vec3 tnY_top = texture(_TopNormalTex, worldPos.xz * _TopTiling).rgb * 2.0 - 1.0;

                vec3 nWX      = vec3(tnX.z * sign(N.x), tnX.y, tnX.x);
                vec3 nWY_rock = vec3(tnY.x, tnY.z * sign(N.y), tnY.y);
                vec3 nWY_top  = vec3(tnY_top.x, tnY_top.z * sign(N.y), tnY_top.y);
                vec3 nWY      = mix(nWY_rock, nWY_top, topFactor);
                vec3 nWZ      = vec3(tnZ.x, tnZ.y, tnZ.z * sign(N.z));
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

            void main()
            {
                if (_AlphaCutoff > 0.0)
                {
                    vec3 N = normalize(vNormal);
                    vec3 absN = abs(N);
                    vec3 weights = pow(absN, vec3(_TriplanarBlend));
                    weights /= (weights.x + weights.y + weights.z + 0.0001);

                    vec4 albedo = texture(_MainTex, worldPos.zy * _Tiling) * weights.x
                                + texture(_MainTex, worldPos.xz * _Tiling) * weights.y
                                + texture(_MainTex, worldPos.xy * _Tiling) * weights.z;
                    if (albedo.a * _MainColor.a < _AlphaCutoff) discard;
                }
                gl_FragDepth = gl_FragCoord.z;
            }
        }
    ENDGLSL
}
