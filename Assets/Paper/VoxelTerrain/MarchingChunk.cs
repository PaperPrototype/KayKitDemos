using Prowl.Runtime;
using Prowl.Runtime.Rendering;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using System.Collections.Generic;
using System.Diagnostics;

namespace Paper.VoxelTerrain;

public class MarchingChunk : MonoBehaviour
{
    private const int ChunkWidth = 16;
    private const int ChunkHeight = 256;
    private const int ChunkDepth = 16;

    private Int3 chunkPosition;
    private byte[,,] voxels = new byte[ChunkWidth, ChunkHeight, ChunkDepth];
    private MeshRenderer? meshRenderer;
    private VoxelWorld voxelWorld;

    private static readonly Color[] BlockColors = new Color[]
    {
        new Color(0f,    0f,    0f,    0f),
        new Color(0.50f, 0.50f, 0.50f, 1f),
        new Color(0.55f, 0.36f, 0.18f, 1f),
        new Color(0.27f, 0.62f, 0.18f, 1f),
    };

    public void Initialize(Int3 chunkPos, VoxelWorld world)
    {
        voxelWorld = world;
        chunkPosition = chunkPos;
        meshRenderer = AddComponent<MeshRenderer>();
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

            int baseHeight = 64;
            int heightVariation = (int)(voxelWorld.noise.GetNoise(worldX * 0.9f, worldZ * 0.9f) * 10f);
            int height = baseHeight + heightVariation;

            for (int y = 0; y < ChunkHeight; y++)
            {
                float worldY = worldOffsetY + y;
                float caveGen = voxelWorld.noise.GetNoise(worldX * 0.9f, worldY * 0.9f, worldZ * 0.9f);
                if (caveGen > 0.3f)
                    voxels[x, y, z] = 0;
                else if (y < height - 5)
                    voxels[x, y, z] = 1;
                else if (y < height - 1)
                    voxels[x, y, z] = 2;
                else if (y < height)
                    voxels[x, y, z] = 3;
                else
                    voxels[x, y, z] = 0;
            }
        }
    }

    public void GenerateMesh()
    {
        var stopWatch = Stopwatch.StartNew();

        // Build per-corner density and block-type fields (one larger than voxel grid in each axis)
        float[,,] density    = new float[ChunkWidth + 1, ChunkHeight + 1, ChunkDepth + 1];
        byte[,,]  cornerBlock = new byte[ChunkWidth + 1, ChunkHeight + 1, ChunkDepth + 1];

        for (int x = 0; x <= ChunkWidth; x++)
        for (int y = 0; y <= ChunkHeight; y++)
        for (int z = 0; z <= ChunkDepth; z++)
        {
            // Sample the block type at this corner (may cross into a neighboring chunk)
            byte b = SampleWorld(x, y, z);

            // Store the block type so MarchCube can look up vertex colors later
            cornerBlock[x, y, z] = b;

            // Convert block presence into a signed density value:
            // solid corners get +1, air corners get -1.
            // The marching cubes surface is drawn where density crosses zero.
            if (b != 0)
                density[x, y, z] = 1f;   // solid
            else
                density[x, y, z] = -1f;  // air
        }

        List<Float3> vertices  = [];
        List<uint>   triangles = [];
        List<Color>  colors    = [];

        for (int x = 0; x < ChunkWidth; x++)
        for (int y = 0; y < ChunkHeight; y++)
        for (int z = 0; z < ChunkDepth; z++)
            MarchCube(x, y, z, density, cornerBlock, vertices, triangles, colors);

        if (vertices.Count == 0)
        {
            if (meshRenderer?.Mesh.Res != null)
                meshRenderer.Mesh = null!;
            return;
        }

        Mesh mesh = new();
        mesh.Vertices = vertices.ToArray();
        mesh.Indices  = triangles.ToArray();
        mesh.Colors   = colors.ToArray();
        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        mesh.RecalculateTangents();
        meshRenderer!.Mesh = mesh;

        stopWatch.Stop();
        Prowl.Runtime.Debug.Log("MC Meshing took " + stopWatch.ElapsedMilliseconds + "ms");
    }

    private void MarchCube(int x, int y, int z,
        float[,,] density, byte[,,] cornerBlock,
        List<Float3> vertices, List<uint> triangles, List<Color> colors)
    {
        float[] cube       = new float[8];
        byte[]  cubeBlocks = new byte[8];

        for (int i = 0; i < 8; i++)
        {
            Float3 c = Marching.CornerTable[i];
            int cx = x + (int)c.X;
            int cy = y + (int)c.Y;
            int cz = z + (int)c.Z;
            cube[i]       = density[cx, cy, cz];
            cubeBlocks[i] = cornerBlock[cx, cy, cz];
        }

        int configIndex = 0;
        for (int i = 0; i < 8; i++)
            if (cube[i] < 0f)
                configIndex |= 1 << i;

        if (configIndex == 0 || configIndex == 255)
            return;

        int edgeIndex = 0;
        for (int tri = 0; tri < 5; tri++)
        for (int p = 0; p < 3; p++)
        {
            int indice = Marching.TriangleTable[configIndex][edgeIndex];
            if (indice == -1) return;

            int e0 = Marching.EdgeIndexes[indice][0];
            int e1 = Marching.EdgeIndexes[indice][1];

            // Match Marching.cs convention: vert1 = e1 corner, vert2 = e0 corner
            Float3 vert1 = new Float3(x, y, z) + Marching.CornerTable[e1];
            Float3 vert2 = new Float3(x, y, z) + Marching.CornerTable[e0];

            float s1 = cube[e1];
            float s2 = cube[e0];
            float t  = Maths.Abs(s2 - s1) > 0.0001f ? -s1 / (s2 - s1) : 0.5f;

            Float3 vertPos = vert1 + (vert2 - vert1) * t;

            // Use the solid corner's block color for the surface vertex
            byte solidBlock = cube[e1] > 0f ? cubeBlocks[e1] : cubeBlocks[e0];
            Color vertColor = BlockColors[solidBlock < BlockColors.Length ? solidBlock : 0];

            vertices.Add(vertPos);
            triangles.Add((uint)(vertices.Count - 1));
            colors.Add(vertColor);
            edgeIndex++;
        }
    }

    // Returns the block byte at a local position, crossing chunk boundaries via the world query.
    private byte SampleWorld(int localX, int localY, int localZ)
    {
        if (localX >= 0 && localX < ChunkWidth &&
            localY >= 0 && localY < ChunkHeight &&
            localZ >= 0 && localZ < ChunkDepth)
            return voxels[localX, localY, localZ];

        return GetVoxel(localX, localY, localZ);
    }
}
