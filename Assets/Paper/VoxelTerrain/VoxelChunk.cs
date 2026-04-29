using Prowl.Runtime;
using Prowl.Runtime.Rendering;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using Prowl.Vector.Geometry;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.Net;

namespace Paper.VoxelTerrain;

public enum BlockType : byte
{
    Air   = 0,
    Stone = 1,
    Dirt  = 2,
    Grass = 3,
}

public class VoxelChunk : MonoBehaviour
{
    private const int ChunkWidth = 16;
    private const int ChunkHeight = 256;
    private const int ChunkDepth = 16;

    private Int3 chunkPosition;

    private byte[,,] voxels = new byte[ChunkWidth, ChunkHeight, ChunkDepth];
    private MeshRenderer? meshRenderer;

    // private MeshCollider meshCollider;

    private VoxelWorld voxelWorld;

    public bool EnableSmoothing = true;
    public float SmoothingAmount = 1f;
    
    private Float2[] faceUVs = new Float2[4]
    {
        new Float2(0.0f, 0.0f),
        new Float2(1.0f, 0.0f),
        new Float2(1.0f, 1.0f),
        new Float2(0.0f, 1.0f)
    };

    private static readonly Color[] BlockColors = new Color[]
    {
        new Color(0f, 0f, 0f, 0f),               // Air      (unused)
        new Color(0.50f, 0.50f, 0.50f, 1f),      // Stone    - grey
        new Color(0.55f, 0.36f, 0.18f, 1f),      // Dirt     - brown
        new Color(0.27f, 0.62f, 0.18f, 1f),      // Grass    - green
    };

    private static readonly float[] BlockSmoothingLevels = new float[]
    {
        1.0f,    // Air
        0.0f,  // Stone
        0.7f,  // Dirt
        1.0f,  // Grass
    };
    
    public void Initialize(Int3 chunkPos, VoxelWorld voxelWorld)
    {
        this.voxelWorld = voxelWorld;
        chunkPosition = chunkPos;
        meshRenderer = GameObject.AddComponent<MeshRenderer>();
        // meshCollider = GameObject.AddComponent<MeshCollider>();
        meshRenderer.Material = voxelWorld.Material;
    }

    public byte GetVoxel(int x, int y, int z)
    {
        if (x < 0 || x >= ChunkWidth || y < 0 || y >= ChunkHeight || z < 0 || z >= ChunkDepth)
            return 0;
        return voxels[x, y, z];
    }

    public void SetVoxel(int x, int y, int z, byte value)
    {
        if (x < 0 || x >= ChunkWidth || y < 0 || y >= ChunkHeight || z < 0 || z >= ChunkDepth)
            return;
        voxels[x, y, z] = value;
        GenerateMesh();
    }

    public void GenerateChunk()
    {
        // Generate simple terrain with world coordinates
        int worldOffsetX = chunkPosition.X * ChunkWidth;
        int worldOffsetY = chunkPosition.Y * ChunkDepth;
        int worldOffsetZ = chunkPosition.Z * ChunkDepth;
        
        for (int x = 0; x < ChunkWidth; x++)
        {
            for (int z = 0; z < ChunkDepth; z++)
            {
                // Use world coordinates for noise
                float worldX = worldOffsetX + x;
                float worldZ = worldOffsetZ + z;

                // Create a simple height map
                int baseHeight = 64;

                
                int heightVariation = (int)(voxelWorld.noise.GetNoise(worldX * 0.9f, worldZ * 0.9f) * 10f);
                // int heightVariation = (int)(Maths.Sin() * 10 + Maths.Cos(worldZ * 0.1) * 10 +
                //                            Maths.Sin(worldX * 0.05) * 5 + Maths.Cos(worldZ * 0.05) * 5);
                
                int height = baseHeight + heightVariation;

                for (int y = 0; y < ChunkHeight; y++)
                {
                    float worldY = worldOffsetY + y;
                    float caveGen = voxelWorld.noise.GetNoise(worldX * 0.9f, worldY * 0.9f, worldZ * 0.9f);
                    if (caveGen > 0.3f)
                    {
                        voxels[x, y, z] = 0; // Air (cave)
                    }
                    else if (y < height - 5)
                    {
                        voxels[x, y, z] = 1; // Stone
                    }
                    else if (y < height - 1)
                    {
                        voxels[x, y, z] = 2; // Dirt
                    }
                    else if (y < height)
                    {
                        voxels[x, y, z] = 3; // Grass
                    }
                    else
                    {
                        voxels[x, y, z] = 0; // Air
                    }
                }
            }
        }
    }

    public void GenerateMesh()
    {    
        var stopWatch = Stopwatch.StartNew();
        List<Float3> vertices = [];
        List<int> triangles = [];
        List<Float2> uvs = [];
        List<Color> colors = [];
        List<Float3> normals = [];
        Dictionary<(int, int, int), Float3> smoothCache = new();

        for (int x = 0; x < ChunkWidth; x++)
        {
            for (int y = 0; y < ChunkHeight; y++)
            {
                for (int z = 0; z < ChunkDepth; z++)
                {
                    byte block = voxels[x, y, z];
                    if (block == 0) continue; // Skip air

                    Color blockColor = BlockColors[block < BlockColors.Length ? block : 0];

                    // Check each face and only add if adjacent voxel is air
                    // Top face (+Y)
                    if (y == ChunkHeight - 1 || voxels[x, y + 1, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, normals, x, y, z, 0, faceUVs, blockColor, smoothCache);

                    // Bottom face (-Y)
                    if (y == 0 || voxels[x, y - 1, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, normals, x, y, z, 1, faceUVs, blockColor, smoothCache);

                    // Front face (+Z)
                    if (z == ChunkDepth - 1 || voxels[x, y, z + 1] == 0)
                        AddFace(vertices, triangles, uvs, colors, normals, x, y, z, 2, faceUVs, blockColor, smoothCache);

                    // Back face (-Z)
                    if (z == 0 || voxels[x, y, z - 1] == 0)
                        AddFace(vertices, triangles, uvs, colors, normals, x, y, z, 3, faceUVs, blockColor, smoothCache);

                    // Right face (+X)
                    if (x == ChunkWidth - 1 || voxels[x + 1, y, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, normals, x, y, z, 4, faceUVs, blockColor, smoothCache);

                    // Left face (-X)
                    if (x == 0 || voxels[x - 1, y, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, normals, x, y, z, 5, faceUVs, blockColor, smoothCache);
                }
            }
        }

        if (vertices.Count == 0)
        {
            // Clear mesh if empty
            if (meshRenderer?.Mesh.Res != null)
            {
                meshRenderer.Mesh = null!;
            }
            return;
        }

        // Create mesh
        Mesh mesh = new();
        mesh.Vertices = [.. vertices.Select(v => new Float3((float)v.X, (float)v.Y, (float)v.Z))];
        mesh.Indices = [.. triangles.Select(i => (uint)i)];
        mesh.UV = [.. uvs];
        mesh.Colors = [.. colors];
        mesh.Normals = [.. normals];

        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        mesh.RecalculateTangents();

        meshRenderer!.Mesh = mesh;
        // meshCollider!.Mesh = mesh;

        stopWatch.Stop();
        Prowl.Runtime.Debug.Log("Meshing took" + stopWatch.ElapsedMilliseconds);
    }

    private void AddFace(
        List<Float3> vertices, List<int> triangles, List<Float2> uvs, List<Color> colors,
        List<Float3> normals, int x, int y, int z, int face, Float2[] faceUVs, Color blockColor,
        Dictionary<(int, int, int), Float3> smoothCache)
    {
        int vertexIndex = vertices.Count;

        Float3[] faceVertices = face switch
        {
            0 => [ // Top (+Y)
                new Float3(0, 1, 0),
                new Float3(0, 1, 1),
                new Float3(1, 1, 1),
                new Float3(1, 1, 0)
            ],
            1 => [ // Bottom (-Y)
                new Float3(0, 0, 1),
                new Float3(0, 0, 0),
                new Float3(1, 0, 0),
                new Float3(1, 0, 1),
            ],
            2 => [ // Front (+Z)
                new Float3(0, 0, 1),
                new Float3(1, 0, 1),
                new Float3(1, 1, 1),
                new Float3(0, 1, 1)
            ],
            3 => [ // Back (-Z)
                new Float3(1, 0, 0),
                new Float3(0, 0, 0),
                new Float3(0, 1, 0),
                new Float3(1, 1, 0)
            ],
            4 => [ // Right (+X)
                new Float3(1, 0, 1),
                new Float3(1, 0, 0),
                new Float3(1, 1, 0),
                new Float3(1, 1, 1)
            ],
            5 => [ // Left (-X)
                new Float3(0, 0, 0),
                new Float3(0, 0, 1),
                new Float3(0, 1, 1),
                new Float3(0, 1, 0)
            ]
        };

        Float3 faceNormal = GetFaceNormal(face);
        Float3[] faceNormals = [faceNormal, faceNormal, faceNormal, faceNormal];

        Float3 ClampMaginitude(Float3 value, float max)
        {
            if (Float3.Length(value) > max) return Float3.Normalize(value) * max;
            if (Float3.Length(value) < -max) return -Float3.Normalize(value) * max;
            return value;
        }

        if (EnableSmoothing)
        {
            for (int i = 0; i < 4; i++)
            {
                var vertex = faceVertices[i] + new Float3(x, y, z);

                // var maxOffsetDistance = 0.4f;

                // var offset = Maths.Clamp(GetOffsetToSurface(vertex.X, vertex.Y, vertex.Z, smoothCache), -0.25f, 0.25f);
                // var offset = ClampMaginitude(GetOffsetToSurface(vertex.X, vertex.Y, vertex.Z, smoothCache), 0.5f);
                var offset = GetOffsetToSurface(vertex.X, vertex.Y, vertex.Z, smoothCache);
                faceVertices[i] = new Float3(
                    vertex.X + offset.X * SmoothingAmount,
                    vertex.Y + offset.Y * SmoothingAmount,
                    vertex.Z + offset.Z * SmoothingAmount
                );
                float len = Float3.Length(offset); // Maths.Sqrt(ox * ox + oy * oy + oz * oz);
                if (len > 0.0001f)
                    faceNormals[i] = Float3.Normalize(offset); // new Float3(ox / len, oy / len, oz / len);
            }
        }

        for (int i = 0; i < 4; i++)
        {
            vertices.Add(faceVertices[i]);
            uvs.Add(faceUVs[i]);
            colors.Add(blockColor);
            normals.Add(faceNormals[i]);
        }

        triangles.Add(vertexIndex);
        triangles.Add(vertexIndex + 1);
        triangles.Add(vertexIndex + 2);

        triangles.Add(vertexIndex);
        triangles.Add(vertexIndex + 2);
        triangles.Add(vertexIndex + 3);
    }

    // private (float ox, float oy, float oz) GetOffsetToSurface(float px, float py, float pz,
    //     Dictionary<(int, int, int), (float, float, float)> cache)
    // {
    //     var key = ((int)px, (int)py, (int)pz);
    //     if (cache.TryGetValue(key, out var cached))
    //         return cached;

    //     float gx = SampleDensity(px + 0.5f, py, pz) - SampleDensity(px - 0.5f, py, pz);
    //     float gy = SampleDensity(px, py + 0.5f, pz) - SampleDensity(px, py - 0.5f, pz);
    //     float gz = SampleDensity(px, py, pz + 0.5f) - SampleDensity(px, py, pz - 0.5f);

    //     float len = Maths.Sqrt(gx * gx + gy * gy + gz * gz);
    //     if (len > 0.0001f) { gx /= len; gy /= len; gz /= len; }

    //     float density = SampleDensity(px, py, pz);
    //     var result = (-gx * density, -gy * density, -gz * density);
    //     cache[key] = result;
    //     return result;
    // }

    private Float3 GetOffsetToSurface(float px, float py, float pz,
        Dictionary<(int, int, int), Float3> cache)
    {
        var key = ((int)px, (int)py, (int)pz);
        if (cache.TryGetValue(key, out var cached))
            return cached;

        float gx = SampleDensity(px + 0.5f, py, pz) - SampleDensity(px - 0.5f, py, pz);
        float gy = SampleDensity(px, py + 0.5f, pz) - SampleDensity(px, py - 0.5f, pz);
        float gz = SampleDensity(px, py, pz + 0.5f) - SampleDensity(px, py, pz - 0.5f);

        float len = Maths.Sqrt(gx * gx + gy * gy + gz * gz);
        if (len > 0.0001f) { gx /= len; gy /= len; gz /= len; }

        float density = SampleDensity(px, py, pz);
        var result = new Float3(-gx * density, -gy * density, -gz * density);
        cache[key] = result;
        return result;
    }

    private float SampleDensity(float px, float py, float pz)
    {
        // Offset for cube mesh difference
        px -= 0.5f; py -= 0.5f; pz -= 0.5f;

        int cx = (int)Maths.Floor(px);
        int cy = (int)Maths.Floor(py);
        int cz = (int)Maths.Floor(pz);
        float dx = px - cx, dy = py - cy, dz = pz - cz;

        float c00 = Lerp(GetDistance(cx,     cy,     cz    ), GetDistance(cx + 1, cy,     cz    ), dx);
        float c01 = Lerp(GetDistance(cx,     cy,     cz + 1), GetDistance(cx + 1, cy,     cz + 1), dx);
        float c10 = Lerp(GetDistance(cx,     cy + 1, cz    ), GetDistance(cx + 1, cy + 1, cz    ), dx);
        float c11 = Lerp(GetDistance(cx,     cy + 1, cz + 1), GetDistance(cx + 1, cy + 1, cz + 1), dx);

        return Lerp(Lerp(c00, c10, dy), Lerp(c01, c11, dy), dz);
    }

    private float GetDistance(int x, int y, int z) => IsVoxelSolid(x, y, z) ? 1f : -1f;

    private static float Lerp(float a, float b, float t) => a + (b - a) * t;

    private static Float3 GetFaceNormal(int face) => face switch
    {
        0 => new Float3( 0,  1,  0),
        1 => new Float3( 0, -1,  0),
        2 => new Float3( 0,  0,  1),
        3 => new Float3( 0,  0, -1),
        4 => new Float3( 1,  0,  0),
        5 => new Float3(-1,  0,  0),
        _ => new Float3( 0,  1,  0),
    };

    // Used by smoothing — falls back to world query for border voxels so density
    // sampling is seamless across chunk boundaries.
    private bool IsVoxelSolid(int localX, int localY, int localZ)
    {
        if (localX >= 0 && localX < ChunkWidth && localY >= 0 && localY < ChunkHeight && localZ >= 0 && localZ < ChunkDepth)
            return voxels[localX, localY, localZ] != 0;

        return GetVoxel(localX, localY, localZ) != 0;
    }
}