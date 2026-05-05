/*
This file implements a meshing approach that is a hybrid of VoxelChunk
and MarchingChunk: it emits quads like VoxelChunk but displaces each of
the 8 integer-grid corners to the MC edge-interpolated surface crossing
position before emitting the quad.  This is a simple way to get smoother
meshes without the complexity of full marching cubes with lookup tables
and case handling.  The topology is the same as VoxelChunk so it shares
the same vertex colors and fast quad emission, but the vertex positions
are more expensive to compute and the meshes are smoother and have
better lighting.  This is the "best of both worlds" approach that I
ended up choosing.
*/

using Prowl.Runtime;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using System;
using System.Collections.Generic;

namespace Paper.VoxelTerrain;

// Cube-face meshing (same topology as VoxelChunk) but each of the 8 integer-grid
// corners is displaced to the MC edge-interpolated surface crossing position before
// the quads are emitted.  No lookup table meshing, just corner displacement.
public class InterpolatedCubeChunk : MonoBehaviour
{
    private const int ChunkWidth  = 16;
    private const int ChunkHeight = 128; // terrain peaks around y=20; 48 gives safe headroom
    private const int ChunkDepth  = 16;

    private const int WorldHeight = 256; // used for normalizing world-Y when sampling noise

    // Density grid covers local coords [-1, ChunkWidth] x [-1, ChunkHeight] x [-1, ChunkDepth]
    private const int DensityGridX = ChunkWidth  + 2; // 18
    private const int DensityGridY = ChunkHeight + 2; // 130
    private const int DensityGridZ = ChunkDepth  + 2; // 18
    private readonly float[] _densityGrid = new float[DensityGridX * DensityGridY * DensityGridZ];

    private Int3 chunkPosition;
    private MeshRenderer? meshRenderer;
    private Rigidbody3D? rigidbody3D;
    private VoxelCollider? meshCollider;
    private VoxelWorld voxelWorld;
    private Mesh? _cachedMesh;

    // The 8 voxels that share a grid corner, expressed as offsets in {-1, 0} per axis.
    private static readonly (int ox, int oy, int oz)[] CubeCornerOffsets =
    [
        (-1, -1, -1), // 0
        ( 0, -1, -1), // 1
        (-1,  0, -1), // 2
        ( 0,  0, -1), // 3
        (-1, -1,  0), // 4
        ( 0, -1,  0), // 5
        (-1,  0,  0), // 6
        ( 0,  0,  0), // 7
    ];

    private static readonly Float2[] faceUVs =
    [
        new Float2(0.0f, 0.0f),
        new Float2(1.0f, 0.0f),
        new Float2(1.0f, 1.0f),
        new Float2(0.0f, 1.0f)
    ];

    // All 12 edges of the local 2x2x2 cube (pairs of corner indices above).
    private static readonly (int a, int b)[] CubeEdges =
    [
        (0, 1), (2, 3), (4, 5), (6, 7), // X-axis edges
        (0, 2), (1, 3), (4, 6), (5, 7), // Y-axis edges
        (0, 4), (1, 5), (2, 6), (3, 7), // Z-axis edges
    ];

    public void Initialize(Int3 chunkPos, VoxelWorld world)
    {
        voxelWorld    = world;
        chunkPosition = chunkPos;
        meshRenderer  = AddComponent<MeshRenderer>();
        meshRenderer.Material = world.Material;
        // Physics components are created lazily when collision is first enabled
        // with a valid mesh, to avoid "MeshCollider: no mesh assigned" warnings.
    }

    public void BakeDensityGrid()
    {
        for (int x = -1; x <= ChunkWidth;  x++)
        for (int y = -1; y <= ChunkHeight; y++)
        for (int z = -1; z <= ChunkDepth;  z++)
            _densityGrid[(x + 1) * DensityGridY * DensityGridZ + (y + 1) * DensityGridZ + (z + 1)] = ComputeDensity(x, y, z);
    }

    // Builds vertex/triangle/uv data and returns a ready-to-use Mesh, or null for empty chunks.
    // Safe to call from a background thread — only reads _densityGrid and creates a new Mesh object.
    public Mesh? BuildMeshData()
    {
        List<Float3> vertices  = new(2048);
        List<uint>   triangles = new(3072);
        List<Float2> uvs       = new(2048);
        var cornerCache = new Dictionary<(int, int, int), Float3>();

        for (int x = 0; x < ChunkWidth; x++)
        for (int y = 0; y < ChunkHeight; y++)
        for (int z = 0; z < ChunkDepth; z++)
        {
            float centerD = LookupDensity(x, y, z);
            if (centerD > 0) continue;

            float topD   = LookupDensity(x, y + 1, z);
            float downD  = LookupDensity(x, y - 1, z);
            float frontD = LookupDensity(x, y, z + 1);
            float backD  = LookupDensity(x, y, z - 1);
            float rightD = LookupDensity(x + 1, y, z);
            float leftD  = LookupDensity(x - 1, y, z);

            if (topD   > 0) AddFace(vertices, triangles, uvs, x, y, z, 0, cornerCache);
            if (downD  > 0) AddFace(vertices, triangles, uvs, x, y, z, 1, cornerCache);
            if (frontD > 0) AddFace(vertices, triangles, uvs, x, y, z, 2, cornerCache);
            if (backD  > 0) AddFace(vertices, triangles, uvs, x, y, z, 3, cornerCache);
            if (rightD > 0) AddFace(vertices, triangles, uvs, x, y, z, 4, cornerCache);
            if (leftD  > 0) AddFace(vertices, triangles, uvs, x, y, z, 5, cornerCache);
        }

        if (vertices.Count == 0) return null;

        Mesh mesh = new();
        mesh.Vertices = vertices.ToArray();
        mesh.Indices  = triangles.ToArray();
        mesh.UV       = uvs.ToArray();
        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        mesh.RecalculateTangents();

        return mesh;
    }

    // Sets the chunk's mesh on the renderer only. Must run on main thread.
    // Pass null to clear the chunk (e.g. when a rebuild produces an empty chunk after voxel edits).
    public void SetMesh(Mesh? mesh)
    {
        _cachedMesh = mesh;

        if (mesh is null)
        {
            // Clear a previously assigned mesh so a rebuilt empty chunk doesn't leave stale geometry visible.
            meshRenderer!.Mesh = default;
            meshCollider?.ComputeColliderShape(null);
            return;
        }

        meshRenderer!.Mesh = mesh;
    }

    // Enables physics collision for this chunk using the current cached mesh.
    // Only called for chunks within CollisionDistance of the player — skipped for distant chunks.
    // Physics components are created lazily here rather than in SetMesh so distant chunks
    // never pay the cost of building a triangle mesh collider.
    public void AddCollision()
    {
        if (_cachedMesh is null) return;

        if (rigidbody3D is null)
        {
            rigidbody3D = AddComponent<Rigidbody3D>();
            rigidbody3D.Mass = 1f;
            rigidbody3D.MotionType = Jitter2.Dynamics.MotionType.Static;
            meshCollider = AddComponent<VoxelCollider>();
        }

        meshCollider!.ComputeColliderShape(_cachedMesh);
    }

    private void AddFace(
        List<Float3> vertices,
        List<uint> triangles,
        List<Float2> uvs,
        int x, int y, int z, int face,
        Dictionary<(int, int, int), Float3> cache)
    {
        (int cx0, int cy0, int cz0,
         int cx1, int cy1, int cz1,
         int cx2, int cy2, int cz2,
         int cx3, int cy3, int cz3) = face switch
        {
            0 => (x,   y+1, z,   x,   y+1, z+1, x+1, y+1, z+1, x+1, y+1, z  ), // Top    (+Y)
            1 => (x,   y,   z+1, x,   y,   z,   x+1, y,   z,   x+1, y,   z+1), // Bottom (-Y)
            2 => (x,   y,   z+1, x+1, y,   z+1, x+1, y+1, z+1, x,   y+1, z+1), // Front  (+Z)
            3 => (x+1, y,   z,   x,   y,   z,   x,   y+1, z,   x+1, y+1, z  ), // Back   (-Z)
            4 => (x+1, y,   z+1, x+1, y,   z,   x+1, y+1, z,   x+1, y+1, z+1), // Right  (+X)
            _ => (x,   y,   z,   x,   y,   z+1, x,   y+1, z+1, x,   y+1, z  ), // Left   (-X)
        };

        uint baseIdx = (uint)vertices.Count;
        vertices.Add(GetInterpolatedCorner(cx0, cy0, cz0, cache));
        vertices.Add(GetInterpolatedCorner(cx1, cy1, cz1, cache));
        vertices.Add(GetInterpolatedCorner(cx2, cy2, cz2, cache));
        vertices.Add(GetInterpolatedCorner(cx3, cy3, cz3, cache));

        triangles.Add(baseIdx);
        triangles.Add(baseIdx + 1);
        triangles.Add(baseIdx + 2);
        triangles.Add(baseIdx);
        triangles.Add(baseIdx + 2);
        triangles.Add(baseIdx + 3);

        uvs.AddRange(faceUVs);
    }

    // For a corner at integer grid position (cx,cy,cz):
    // 1. Sample the density of each of the 8 voxels that share this corner.
    // 2. Check all 12 edges of the local 2x2x2 cube for sign changes.
    // 3. For each crossing edge compute the MC-interpolated surface position.
    // 4. Average all crossing positions -> final vertex position.
    // If no edges cross (deep interior or exterior) the corner stays put.
    private Float3 GetInterpolatedCorner(int cx, int cy, int cz, Dictionary<(int, int, int), Float3> cache)
    {
        var key = (cx, cy, cz);
        if (cache.TryGetValue(key, out var cached)) return cached;

        Span<float> d = stackalloc float[8];
        for (int i = 0; i < 8; i++)
        {
            (int ox, int oy, int oz) = CubeCornerOffsets[i];
            d[i] = LookupDensity(cx + ox, cy + oy, cz + oz);
        }

        float sx = 0f, sy = 0f, sz = 0f;
        int   crossings = 0;

        foreach ((int a, int b) in CubeEdges)
        {
            if ((d[a] > 0f) != (d[b] > 0f)) // sign change → surface crossing
            {
                float t = d[a] / (d[a] - d[b]); // MC interpolation ∈ (0,1)
                (int oax, int oay, int oaz) = CubeCornerOffsets[a];
                (int obx, int oby, int obz) = CubeCornerOffsets[b];
                sx += (cx + oax) + (obx - oax) * t;
                sy += (cy + oay) + (oby - oay) * t;
                sz += (cz + oaz) + (obz - oaz) * t;
                crossings++;
            }
        }

        var result = crossings > 0
            ? new Float3(sx / crossings, sy / crossings, sz / crossings)
            : new Float3(cx, cy, cz);

        cache[key] = result;
        return result;
    }

    private float LookupDensity(int x, int y, int z)
        => _densityGrid[(x + 1) * DensityGridY * DensityGridZ + (y + 1) * DensityGridZ + (z + 1)];

    private float ComputeDensity(int localX, int localY, int localZ)
    {
        int worldChunkX = chunkPosition.X * ChunkWidth;
        int worldChunkY = chunkPosition.Y * ChunkHeight;
        int worldChunkZ = chunkPosition.Z * ChunkDepth;

        float worldX = worldChunkX + localX;
        float worldY = worldChunkY + localY;
        float worldZ = worldChunkZ + localZ;

        float normalizedY = worldY / WorldHeight;
        float heightCurveValue = voxelWorld.HeightCurve.Evaluate(normalizedY);

        float groundHeight = 20f;
        float normalizedGroundY = worldY / groundHeight;

        float varianceFrequency = 1.5f;
        float heightVariation = Maths.Clamp(
            (voxelWorld.noise.GetNoise(worldX * varianceFrequency, worldZ * varianceFrequency) + 1f) * 0.5f * normalizedGroundY * groundHeight,
            0f, groundHeight
        ) + 1f;

        float heightVariationStrengthFrequency = 0.5f;
        float heightVariationStrengthNoise = (voxelWorld.noise.GetNoise(worldX * heightVariationStrengthFrequency, worldY * heightVariationStrengthFrequency, worldZ * heightVariationStrengthFrequency) + 1f) * 0.5f;

        float frequency = 2f;
        return Maths.Clamp(voxelWorld.noise.GetNoise(worldX * frequency, worldY * frequency, worldZ * frequency) + heightCurveValue + (heightVariation * heightVariationStrengthNoise), -1f, 1f);
    }
}
