using System;
using Prowl.Runtime;
using Prowl.Runtime.Rendering;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using Prowl.Vector.Geometry;
using System.Collections.Generic;
using System.Linq;

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
    private VoxelWorld voxelWorld;
    
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
    
    public void Initialize(Int3 chunkPos, VoxelWorld voxelWorld)
    {
        this.voxelWorld = voxelWorld;
        chunkPosition = chunkPos;
        meshRenderer = GameObject.AddComponent<MeshRenderer>();
        meshRenderer.Material = voxelWorld.Material;
        GenerateChunk();
        GenerateMesh();
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
                    if (y < height - 5)
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
        List<Float3> vertices = [];
        List<int> triangles = [];
        List<Float2> uvs = [];
        List<Color> colors = [];

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
                        AddFace(vertices, triangles, uvs, colors, x, y, z, 0, faceUVs, blockColor);

                    // Bottom face (-Y)
                    if (y == 0 || voxels[x, y - 1, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, x, y, z, 1, faceUVs, blockColor);

                    // Front face (+Z)
                    if (z == ChunkDepth - 1 || voxels[x, y, z + 1] == 0)
                        AddFace(vertices, triangles, uvs, colors, x, y, z, 2, faceUVs, blockColor);

                    // Back face (-Z)
                    if (z == 0 || voxels[x, y, z - 1] == 0)
                        AddFace(vertices, triangles, uvs, colors, x, y, z, 3, faceUVs, blockColor);

                    // Right face (+X)
                    if (x == ChunkWidth - 1 || voxels[x + 1, y, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, x, y, z, 4, faceUVs, blockColor);

                    // Left face (-X)
                    if (x == 0 || voxels[x - 1, y, z] == 0)
                        AddFace(vertices, triangles, uvs, colors, x, y, z, 5, faceUVs, blockColor);
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

        // Generate normals for proper lighting
        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        mesh.RecalculateTangents();

        meshRenderer!.Mesh = mesh;
    }

    private void AddFace(List<Float3> vertices, List<int> triangles, List<Float2> uvs, List<Color> colors,
                        int x, int y, int z, int face, Float2[] faceUVs, Color blockColor)
    {
        int vertexIndex = vertices.Count;
        
        // Define the 4 vertices of the face based on face direction
        Float3[] faceVertices = face switch
        {
            0 => [ // Top (+Y)
                new Float3(x, y + 1, z),
                new Float3(x, y + 1, z + 1),
                new Float3(x + 1, y + 1, z + 1),
                new Float3(x + 1, y + 1, z)
            ],
            1 => [ // Bottom (-Y)
                new Float3(x, y, z + 1),
                new Float3(x, y, z),
                new Float3(x + 1, y, z),
                new Float3(x + 1, y, z + 1),
            ],
            2 => [ // Front (+Z)
                new Float3(x, y, z + 1),
                new Float3(x + 1, y, z + 1),
                new Float3(x + 1, y + 1, z + 1),
                new Float3(x, y + 1, z + 1)
            ],
            3 => [ // Back (-Z)
                new Float3(x + 1, y, z),
                new Float3(x, y, z),
                new Float3(x, y + 1, z),
                new Float3(x + 1, y + 1, z)
            ],
            4 => [ // Right (+X)
                new Float3(x + 1, y, z + 1),
                new Float3(x + 1, y, z),
                new Float3(x + 1, y + 1, z),
                new Float3(x + 1, y + 1, z + 1)
            ],
            5 => [ // Left (-X)
                new Float3(x, y, z),
                new Float3(x, y, z + 1),
                new Float3(x, y + 1, z + 1),
                new Float3(x, y + 1, z)
            ],
            _ => throw new ArgumentException("Invalid face index")
        };

        // Add vertices, UVs, and colors
        foreach (int i in Enumerable.Range(0, 4))
        {
            vertices.Add(faceVertices[i]);
            uvs.Add(faceUVs[i]);
            colors.Add(blockColor);
        }

        // Add triangles (two triangles per face)
        triangles.Add(vertexIndex);
        triangles.Add(vertexIndex + 1);
        triangles.Add(vertexIndex + 2);

        triangles.Add(vertexIndex);
        triangles.Add(vertexIndex + 2);
        triangles.Add(vertexIndex + 3);
    }
}