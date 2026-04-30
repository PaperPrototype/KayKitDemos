using Prowl.Runtime;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using System.Collections.Generic;
using Auburn.FastNoiseLite;

namespace Paper.VoxelTerrain;

public class VoxelWorld : MonoBehaviour
{
    public GameObject Player;
    public AnimationCurve HeightCurve;
    // public float HeightCurveStrength = 28f;
    public AssetRef<Material> Material;

    private const int ChunkWidth = 16;
    private const int ChunkHeight = 256;
    private const int ChunkDepth = 16;
    private const int RenderDistance = 10;

    // How often (in seconds) to check if the player has crossed a chunk boundary
    private const float UpdateInterval = 0.5f;
    private float _updateTimer = 0f;

    private Dictionary<Int3, InterpolatedCubeChunk> chunks = [];
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

    private void CreateChunk(Int3 chunkPos)
    {
        GameObject chunkGO = new($"Chunk_{chunkPos.X}_{chunkPos.Y}_{chunkPos.Z}");
        chunkGO.Transform.SetParent(Transform);
        chunkGO.Transform.Position = new Float3(
            chunkPos.X * ChunkWidth,
            chunkPos.Y * ChunkHeight,
            chunkPos.Z * ChunkDepth
        );

        var chunk = chunkGO.AddComponent<InterpolatedCubeChunk>();
        chunk.Initialize(chunkPos, this);

        // Register before generating mesh so neighbor chunks can query this chunk's
        // voxel data during their own border smoothing, and vice versa.
        chunks[chunkPos] = chunk;
        Scene.Add(chunkGO);

        // chunk.GenerateChunk();
        chunk.GenerateMesh();

        // Re-mesh adjacent already-loaded neighbors so they can incorporate this
        // chunk's border data into their smoothing.
        Int3[] neighborOffsets = [new(-1, 0, 0), new(1, 0, 0), new(0, 0, -1), new(0, 0, 1)];
        foreach (var offset in neighborOffsets)
        {
            if (chunks.TryGetValue(chunkPos + offset, out InterpolatedCubeChunk? neighbor))
                neighbor.GenerateMesh();
        }
    }

    private void DestroyChunk(Int3 chunkPos)
    {
        if (!chunks.TryGetValue(chunkPos, out InterpolatedCubeChunk? chunk)) return;

        chunks.Remove(chunkPos);
        Scene.Remove(chunk.GameObject);
    }

    private Int3 WorldToChunkPos(Int3 worldPos)
    {
        return new Int3(
            worldPos.X >= 0 ? worldPos.X / ChunkWidth : (worldPos.X - ChunkWidth + 1) / ChunkWidth,
            0, // Single layer of chunks vertically for now
            worldPos.Z >= 0 ? worldPos.Z / ChunkDepth : (worldPos.Z - ChunkDepth + 1) / ChunkDepth
        );
    }

    // private Int3 WorldToLocalPos(Int3 worldPos)
    // {
    //     int localX = worldPos.X >= 0 ? worldPos.X % ChunkWidth : (ChunkWidth - 1 - ((-worldPos.X - 1) % ChunkWidth));
    //     int localZ = worldPos.Z >= 0 ? worldPos.Z % ChunkDepth : (ChunkDepth - 1 - ((-worldPos.Z - 1) % ChunkDepth));

    //     return new Int3(localX, worldPos.Y, localZ);
    // }
}
