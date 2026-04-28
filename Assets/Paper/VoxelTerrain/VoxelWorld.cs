using Prowl.Runtime;
using Prowl.Runtime.Rendering;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using Prowl.Vector.Geometry;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using Auburn.FastNoiseLite;

namespace Paper.VoxelTerrain;

public class VoxelWorld : MonoBehaviour
{
    public GameObject Player;
    public AssetRef<Material> Material;

    private const int ChunkWidth = 16;
    private const int ChunkHeight = 256;
    private const int ChunkDepth = 16;
    private const int RenderDistance = 3;

    // How often (in seconds) to check if the player has crossed a chunk boundary
    private const float UpdateInterval = 0.5f;
    private float _updateTimer = 0f;

    private Dictionary<Int3, VoxelChunk> chunks = [];
    public FastNoiseLite noise;

    // The chunk the player was in during the last update
    private Int3 _lastPlayerChunk = new(int.MaxValue, 0, int.MaxValue);

    public override void OnEnable()
    {
        noise = new FastNoiseLite();
        noise.SetNoiseType(FastNoiseLite.NoiseType.OpenSimplex2);
        UpdateChunksAroundPlayer(force: true);
    }

    public override void Update()
    {
        if (Player == null) return;

        _updateTimer -= Time.DeltaTime;
        if (_updateTimer > 0f) return;
        _updateTimer = UpdateInterval;

        Int3 currentPlayerChunk = WorldToChunkPos(new Int3(
            (int)Maths.Floor(Player.Transform.Position.X),
            0,
            (int)Maths.Floor(Player.Transform.Position.Z)
        ));

        // Only rebuild if the player has moved into a different chunk
        if (currentPlayerChunk != _lastPlayerChunk)
            UpdateChunksAroundPlayer(force: false);
    }

    private void UpdateChunksAroundPlayer(bool force)
    {
        Int3 playerChunk;
        if (Player != null)
        {
            playerChunk = WorldToChunkPos(new Int3(
                (int)Maths.Floor(Player.Transform.Position.X),
                0,
                (int)Maths.Floor(Player.Transform.Position.Z)
            ));
        }
        else
        {
            playerChunk = new Int3(0, 0, 0);
        }

        if (!force && playerChunk == _lastPlayerChunk) return;
        _lastPlayerChunk = playerChunk;

        // Build the set of chunk positions that should be loaded
        HashSet<Int3> desired = [];
        for (int x = -RenderDistance; x <= RenderDistance; x++)
        for (int z = -RenderDistance; z <= RenderDistance; z++)
            desired.Add(new Int3(playerChunk.X + x, 0, playerChunk.Z + z));

        // Unload chunks that are no longer in range
        List<Int3> toRemove = [];
        foreach (var (pos, chunk) in chunks)
        {
            if (!desired.Contains(pos))
                toRemove.Add(pos);
        }

        foreach (var pos in toRemove)
            DestroyChunk(pos);

        // Load chunks that are missing
        foreach (var pos in desired)
        {
            if (!chunks.ContainsKey(pos))
                CreateChunk(pos);
        }
    }

    // Removed GenerateWorld() — replaced by UpdateChunksAroundPlayer

    private void CreateChunk(Int3 chunkPos)
    {
        GameObject chunkGO = new($"Chunk_{chunkPos.X}_{chunkPos.Y}_{chunkPos.Z}");
        chunkGO.Transform.Position = new Float3(
            chunkPos.X * ChunkWidth,
            chunkPos.Y * ChunkHeight,
            chunkPos.Z * ChunkDepth
        );

        VoxelChunk chunk = chunkGO.AddComponent<VoxelChunk>();
        chunk.Initialize(chunkPos, this);
        chunk.GenerateChunk();

        chunks[chunkPos] = chunk;
        GameObject.Scene.Add(chunkGO);
    }

    private void DestroyChunk(Int3 chunkPos)
    {
        if (!chunks.TryGetValue(chunkPos, out VoxelChunk? chunk)) return;

        chunks.Remove(chunkPos);
        Scene.Remove(chunk.GameObject);
    }

    public byte GetVoxel(Int3 worldPos)
    {
        Int3 chunkPos = WorldToChunkPos(worldPos);
        if (!chunks.TryGetValue(chunkPos, out VoxelChunk? chunk))
            return 0;

        Int3 localPos = WorldToLocalPos(worldPos);
        return chunk.GetVoxel(localPos.X, localPos.Y, localPos.Z);
    }

    public void SetVoxel(Int3 worldPos, byte value)
    {
        Int3 chunkPos = WorldToChunkPos(worldPos);
        if (!chunks.TryGetValue(chunkPos, out VoxelChunk? chunk))
            return;

        Int3 localPos = WorldToLocalPos(worldPos);
        chunk.SetVoxel(localPos.X, localPos.Y, localPos.Z, value);

        // Update neighboring chunks if on edge
        if (localPos.X == 0 && chunks.TryGetValue(chunkPos + new Int3(-1, 0, 0), out VoxelChunk? leftChunk))
            leftChunk.GenerateMesh();
        if (localPos.X == ChunkWidth - 1 && chunks.TryGetValue(chunkPos + new Int3(1, 0, 0), out VoxelChunk? rightChunk))
            rightChunk.GenerateMesh();
        if (localPos.Z == 0 && chunks.TryGetValue(chunkPos + new Int3(0, 0, -1), out VoxelChunk? backChunk))
            backChunk.GenerateMesh();
        if (localPos.Z == ChunkDepth - 1 && chunks.TryGetValue(chunkPos + new Int3(0, 0, 1), out VoxelChunk? frontChunk))
            frontChunk.GenerateMesh();
    }

    public bool RaycastVoxel(Ray ray, float maxDistance, bool destroy)
    {
        // DDA Voxel Traversal
        Float3 rayPos = ray.Origin;
        Float3 rayDir = Float3.Normalize(ray.Direction);

        // Current voxel position
        Int3 voxelPos = new(
            (int)Maths.Floor(rayPos.X),
            (int)Maths.Floor(rayPos.Y),
            (int)Maths.Floor(rayPos.Z)
        );

        // Step direction for each axis
        Int3 step = new(
            rayDir.X > 0 ? 1 : -1,
            rayDir.Y > 0 ? 1 : -1,
            rayDir.Z > 0 ? 1 : -1
        );

        // Distance to next voxel boundary on each axis
        Float3 tDelta = new(
            Maths.Abs(1.0f / rayDir.X),
            Maths.Abs(1.0f / rayDir.Y),
            Maths.Abs(1.0f / rayDir.Z)
        );

        // Initial t values to reach next voxel boundary
        Float3 tMax = new(
            rayDir.X > 0 ? (voxelPos.X + 1 - rayPos.X) / rayDir.X : (rayPos.X - voxelPos.X) / -rayDir.X,
            rayDir.Y > 0 ? (voxelPos.Y + 1 - rayPos.Y) / rayDir.Y : (rayPos.Y - voxelPos.Y) / -rayDir.Y,
            rayDir.Z > 0 ? (voxelPos.Z + 1 - rayPos.Z) / rayDir.Z : (rayPos.Z - voxelPos.Z) / -rayDir.Z
        );

        float distance = 0;
        Int3 previousVoxel = voxelPos;

        while (distance < maxDistance)
        {
            // Check current voxel
            byte voxel = GetVoxel(voxelPos);
            if (voxel != 0) // Hit a solid voxel
            {
                if (destroy)
                {
                    SetVoxel(voxelPos, 0); // Destroy voxel
                }
                else
                {
                    SetVoxel(previousVoxel, 1); // Place voxel at previous position (stone)
                }
                return true;
            }

            previousVoxel = voxelPos;

            // Advance to next voxel
            if (tMax.X < tMax.Y)
            {
                if (tMax.X < tMax.Z)
                {
                    voxelPos.X += step.X;
                    distance = tMax.X;
                    tMax.X += tDelta.X;
                }
                else
                {
                    voxelPos.Z += step.Z;
                    distance = tMax.Z;
                    tMax.Z += tDelta.Z;
                }
            }
            else
            {
                if (tMax.Y < tMax.Z)
                {
                    voxelPos.Y += step.Y;
                    distance = tMax.Y;
                    tMax.Y += tDelta.Y;
                }
                else
                {
                    voxelPos.Z += step.Z;
                    distance = tMax.Z;
                    tMax.Z += tDelta.Z;
                }
            }
        }

        return false;
    }

    private Int3 WorldToChunkPos(Int3 worldPos)
    {
        return new Int3(
            worldPos.X >= 0 ? worldPos.X / ChunkWidth : (worldPos.X - ChunkWidth + 1) / ChunkWidth,
            0, // Single layer of chunks vertically for now
            worldPos.Z >= 0 ? worldPos.Z / ChunkDepth : (worldPos.Z - ChunkDepth + 1) / ChunkDepth
        );
    }

    private Int3 WorldToLocalPos(Int3 worldPos)
    {
        int localX = worldPos.X >= 0 ? worldPos.X % ChunkWidth : (ChunkWidth - 1 - ((-worldPos.X - 1) % ChunkWidth));
        int localZ = worldPos.Z >= 0 ? worldPos.Z % ChunkDepth : (ChunkDepth - 1 - ((-worldPos.Z - 1) % ChunkDepth));

        return new Int3(localX, worldPos.Y, localZ);
    }
}
