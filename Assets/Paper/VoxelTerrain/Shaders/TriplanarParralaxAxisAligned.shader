Shader "Custom/TriplanarParallaxOcclusion"

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

            uniform sampler2D _TranslucencyMap;
            uniform float _TranslucencyStrength;
            uniform float _ScatteringPower;
            uniform float _ScatteringDistortion;
            uniform float _ScatteringScale;

            void main()
            {
                vec3 N = normalize(vNormal);
                vec3 viewDir = normalize(_WorldSpaceCameraPos.xyz - worldPos);

                // Blend weights from surface normal, sharpened by _TriplanarBlend
                vec3 absN = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

                // World-space UVs for each axis projection:
                //   uvX: YZ plane  (X-facing surfaces), UV = (world.z, world.y)
                //   uvY: XZ plane  (Y-facing surfaces), UV = (world.x, world.z)
                //   uvZ: XY plane  (Z-facing surfaces), UV = (world.x, world.y)
                vec2 uvX = worldPos.zy * _Tiling;
                vec2 uvY = worldPos.xz * _Tiling;
                vec2 uvZ = worldPos.xy * _Tiling;

                // Parallax Occlusion Mapping — per-axis with analytically derived tangent frames.
                // Each axis has a fixed TBN in world space; we project viewDir into each:
                //   X: T=(0,0,1) B=(0,1,0)  face=(sign(N.x),0,0)  → vdTS=(V.z, V.y, V.x*sign)
                //   Y: T=(1,0,0) B=(0,0,1)  face=(0,sign(N.y),0)  → vdTS=(V.x, V.z, V.y*sign)
                //   Z: T=(1,0,0) B=(0,1,0)  face=(0,0,sign(N.z))  → vdTS=(V.x, V.y, V.z*sign)
                if (_Parallax > 0.0 && _ParallaxSteps > 0)
                {
                    vec3 vdX = vec3(viewDir.z, viewDir.y, viewDir.x * sign(N.x));
                    vec3 vdY = vec3(viewDir.x, viewDir.z, viewDir.y * sign(N.y));
                    vec3 vdZ = vec3(viewDir.x, viewDir.y, viewDir.z * sign(N.z));

                    uvX = ParallaxOcclusionMapping(_ParallaxMap, uvX, vdX, _Parallax, _ParallaxSteps);
                    uvY = ParallaxOcclusionMapping(_ParallaxMap, uvY, vdY, _Parallax, _ParallaxSteps);
                    uvZ = ParallaxOcclusionMapping(_ParallaxMap, uvZ, vdZ, _Parallax, _ParallaxSteps);
                }

                // Albedo
                vec4 albedo = texture(_MainTex, uvX) * weights.x
                            + texture(_MainTex, uvY) * weights.y
                            + texture(_MainTex, uvZ) * weights.z;
                albedo *= vColor * _MainColor;
                vec3 baseColor = gammaToLinearSpace(albedo.rgb);

                // Triplanar normal mapping: sample per-axis then transform to world space.
                // For each axis, world_normal = tn.r*T + tn.g*B + tn.b*faceN, which gives:
                //   X: (tn.z*sign(N.x), tn.y, tn.x)
                //   Y: (tn.x, tn.z*sign(N.y), tn.y)
                //   Z: (tn.x, tn.y, tn.z*sign(N.z))
                vec3 tnX = texture(_NormalTex, uvX).rgb * 2.0 - 1.0;
                vec3 tnY = texture(_NormalTex, uvY).rgb * 2.0 - 1.0;
                vec3 tnZ = texture(_NormalTex, uvZ).rgb * 2.0 - 1.0;
                vec3 nWX = vec3(tnX.z * sign(N.x), tnX.y, tnX.x);
                vec3 nWY = vec3(tnY.x, tnY.z * sign(N.y), tnY.y);
                vec3 nWZ = vec3(tnZ.x, tnZ.y, tnZ.z * sign(N.z));
                vec3 worldNormal = normalize(nWX * weights.x + nWY * weights.y + nWZ * weights.z);

                // Surface: R=AO, G=Roughness, B=Metallic
                vec4 surface = texture(_SurfaceTex, uvX) * weights.x
                             + texture(_SurfaceTex, uvY) * weights.y
                             + texture(_SurfaceTex, uvZ) * weights.z;
                float ao        = 1.0 - surface.r;
                float roughness = surface.g;
                float metallic  = surface.b;

                // Translucency map: G=extra occlusion, B=thickness
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
            uniform sampler2D _MainTex;
            uniform vec4 _MainColor;
            uniform float _AlphaCutoff;
            uniform float _Tiling;
            uniform float _TriplanarBlend;

            void main()
            {
                vec3 N = normalize(vNormal);
                vec3 absN = abs(N);
                vec3 weights = pow(absN, vec3(_TriplanarBlend));
                weights /= (weights.x + weights.y + weights.z + 0.0001);

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