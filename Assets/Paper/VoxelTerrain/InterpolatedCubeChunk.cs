using Prowl.Runtime;
using Prowl.Runtime.Rendering;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using System.Collections.Generic;
using System.Diagnostics;

namespace Paper.VoxelTerrain;

// Cube-face meshing (same topology as VoxelChunk) but each of the 8 integer-grid
// corners is displaced to the MC edge-interpolated surface crossing position before
// the quads are emitted.  No lookup tables — just corner displacement.
public class InterpolatedCubeChunk : MonoBehaviour
{
    private const int ChunkWidth  = 16;
    private const int ChunkHeight = 256;
    private const int ChunkDepth  = 16;

    private Int3 chunkPosition;
    private byte[,,] voxels = new byte[ChunkWidth, ChunkHeight, ChunkDepth];
    private MeshRenderer? meshRenderer;
    private VoxelWorld voxelWorld;

    private static readonly (int nx, int ny, int nz)[] NeighborDirs =
    [
        ( 1,  0,  0), (-1,  0,  0),
        ( 0,  1,  0), ( 0, -1,  0),
        ( 0,  0,  1), ( 0,  0, -1),
    ];

    public void Initialize(Int3 chunkPos, VoxelWorld world)
    {
        voxelWorld    = world;
        chunkPosition = chunkPos;
        meshRenderer  = AddComponent<MeshRenderer>();
        meshRenderer.Material = world.Material;
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
        int worldOffsetX = chunkPosition.X * ChunkWidth;
        int worldOffsetY = chunkPosition.Y * ChunkDepth;
        int worldOffsetZ = chunkPosition.Z * ChunkDepth;

        for (int x = 0; x < ChunkWidth; x++)
        for (int z = 0; z < ChunkDepth; z++)
        {
            float worldX = worldOffsetX + x;
            float worldZ = worldOffsetZ + z;

            int baseHeight     = 64;
            int heightVariation = (int)(voxelWorld.noise.GetNoise(worldX * 0.9f, worldZ * 0.9f) * 10f);
            int height          = baseHeight + heightVariation;

            for (int y = 0; y < ChunkHeight; y++)
            {
                float worldY  = worldOffsetY + y;
                float caveGen = voxelWorld.noise.GetNoise(worldX * 0.9f, worldY * 0.9f, worldZ * 0.9f);
                if      (caveGen > 0.3f)    voxels[x, y, z] = 0;
                else if (y < height - 5)    voxels[x, y, z] = 1;
                else if (y < height - 1)    voxels[x, y, z] = 2;
                else if (y < height)        voxels[x, y, z] = 3;
                else                        voxels[x, y, z] = 0;
            }
        }
    }

    public void GenerateMesh()
    {
        var stopWatch = Stopwatch.StartNew();

        List<Float3> vertices  = [];
        List<uint>   triangles = [];

        // Displaced corner positions are cached so adjacent faces share the same
        // interpolated corner without recomputing it.
        var cornerCache = new Dictionary<(int, int, int), Float3>();

        for (int x = 0; x < ChunkWidth; x++)
        for (int y = 0; y < ChunkHeight; y++)
        for (int z = 0; z < ChunkDepth; z++)
        {
            if (voxels[x, y, z] == 0) continue;

            if (y == ChunkHeight - 1 || voxels[x, y + 1, z] == 0)
                AddFace(vertices, triangles, x, y, z, 0, cornerCache);
            if (y == 0               || voxels[x, y - 1, z] == 0)
                AddFace(vertices, triangles, x, y, z, 1, cornerCache);
            if (z == ChunkDepth - 1  || voxels[x, y, z + 1] == 0)
                AddFace(vertices, triangles, x, y, z, 2, cornerCache);
            if (z == 0               || voxels[x, y, z - 1] == 0)
                AddFace(vertices, triangles, x, y, z, 3, cornerCache);
            if (x == ChunkWidth - 1  || voxels[x + 1, y, z] == 0)
                AddFace(vertices, triangles, x, y, z, 4, cornerCache);
            if (x == 0               || voxels[x - 1, y, z] == 0)
                AddFace(vertices, triangles, x, y, z, 5, cornerCache);
        }

        if (vertices.Count == 0)
        {
            if (meshRenderer?.Mesh.Res != null)
                meshRenderer.Mesh = null!;
            return;
        }

        Mesh mesh = new();
        mesh.Vertices = vertices.ToArray();
        mesh.Indices  = triangles.ToArray();
        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        mesh.RecalculateTangents();
        meshRenderer!.Mesh = mesh;

        stopWatch.Stop();
        Prowl.Runtime.Debug.Log("ICube Meshing took " + stopWatch.ElapsedMilliseconds + "ms");
    }

    private void AddFace(
        List<Float3> vertices, List<uint> triangles,
        int x, int y, int z, int face,
        Dictionary<(int, int, int), Float3> cache)
    {
        // The 4 integer-grid corner positions for each face, matching VoxelChunk winding.
        (int cx, int cy, int cz)[] corners = face switch
        {
            0 => [(x,   y+1, z  ), (x,   y+1, z+1), (x+1, y+1, z+1), (x+1, y+1, z  )], // Top    (+Y)
            1 => [(x,   y,   z+1), (x,   y,   z  ), (x+1, y,   z  ), (x+1, y,   z+1)], // Bottom (-Y)
            2 => [(x,   y,   z+1), (x+1, y,   z+1), (x+1, y+1, z+1), (x,   y+1, z+1)], // Front  (+Z)
            3 => [(x+1, y,   z  ), (x,   y,   z  ), (x,   y+1, z  ), (x+1, y+1, z  )], // Back   (-Z)
            4 => [(x+1, y,   z+1), (x+1, y,   z  ), (x+1, y+1, z  ), (x+1, y+1, z+1)], // Right  (+X)
            _ => [(x,   y,   z  ), (x,   y,   z+1), (x,   y+1, z+1), (x,   y+1, z  )], // Left   (-X)
        };

        uint baseIdx = (uint)vertices.Count;
        foreach (var (cx, cy, cz) in corners)
            vertices.Add(GetInterpolatedCorner(cx, cy, cz, cache));

        triangles.Add(baseIdx);
        triangles.Add(baseIdx + 1);
        triangles.Add(baseIdx + 2);
        triangles.Add(baseIdx);
        triangles.Add(baseIdx + 2);
        triangles.Add(baseIdx + 3);
    }

    // For a corner at integer grid position (cx,cy,cz), find all 6 adjacent edges
    // that cross the solid/air boundary and average their MC interpolated crossing
    // positions.  If no crossings exist (interior or fully exterior corner) the
    // corner stays at its original integer position.
    private Float3 GetInterpolatedCorner(int cx, int cy, int cz, Dictionary<(int, int, int), Float3> cache)
    {
        var key = (cx, cy, cz);
        if (cache.TryGetValue(key, out var cached)) return cached;

        float d0 = GetCornerDensity(cx, cy, cz);

        float sx = 0f, sy = 0f, sz = 0f;
        int   crossings = 0;

        foreach (var (nx, ny, nz) in NeighborDirs)
        {
            float d1 = GetCornerDensity(cx + nx, cy + ny, cz + nz);
            if ((d0 > 0f) != (d1 > 0f)) // sign change → surface crossing on this edge
            {
                float t = d0 / (d0 - d1); // MC interpolation parameter ∈ (0,1)
                sx += cx + nx * t;
                sy += cy + ny * t;
                sz += cz + nz * t;
                crossings++;
            }
        }

        var result = crossings > 0
            ? new Float3(sx / crossings, sy / crossings, sz / crossings)
            : new Float3(cx, cy, cz);

        cache[key] = result;
        return result;
    }

    private float GetCornerDensity(int x, int y, int z) => SampleWorld(x, y, z) != 0 ? 1f : -1f;

    private byte SampleWorld(int localX, int localY, int localZ)
    {
        if (localX >= 0 && localX < ChunkWidth &&
            localY >= 0 && localY < ChunkHeight &&
            localZ >= 0 && localZ < ChunkDepth)
            return voxels[localX, localY, localZ];

        return GetVoxel(localX, localY, localZ);
    }
}
