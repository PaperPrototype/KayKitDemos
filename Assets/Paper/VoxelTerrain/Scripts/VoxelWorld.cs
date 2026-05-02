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

    public int RenderDistance = 4;
    public int CollisionDistance = 1;

    private const int ChunkWidth = 16;
    private const int ChunkHeight = 256;
    private const int ChunkDepth = 16;

    // How often (in seconds) to check if the player has crossed a chunk boundary
    private const float UpdateInterval = 0.5f;
    private float _updateTimer = 0f;

    private Dictionary<Int3, InterpolatedCubeChunk> chunks = [];
    private Queue<Int3> _chunkLoadQueue = new();
    private HashSet<Int3> _pendingChunks = new();

    public FastNoiseLite noise;

    // The chunk the player was in during the last update
    private Int3 _lastPlayerChunk = new(int.MaxValue, 0, int.MaxValue);

    public override void OnEnable()
    {
        noise = new FastNoiseLite();
        noise.SetNoiseType(FastNoiseLite.NoiseType.OpenSimplex2);
        UpdateChunksAroundPlayer(force: true);
        ProcessChunkQueue(); // Create the player's chunk immediately on start
    }

    public override void Update()
    {
        if (Player == null) return;

        // Load one queued chunk per frame to avoid lag spikes
        ProcessChunkQueue();

        _updateTimer -= Time.DeltaTime;
        if (_updateTimer > 0f) return;
        _updateTimer = UpdateInterval;

        Int3 currentPlayerChunk = WorldToChunkPos(new Int3(
            (int)Maths.Floor(Player.Transform.Position.X),
            0,
            (int)Maths.Floor(Player.Transform.Position.Z)
        ));

        if (currentPlayerChunk != _lastPlayerChunk)
        {
            UpdateChunksAroundPlayer(force: false);
            ProcessChunkQueue(); // Immediately load the new player chunk on boundary crossing
        }
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

        // Rebuild the load queue sorted closest-first so the player's chunk loads first
        _chunkLoadQueue.Clear();
        _pendingChunks.Clear();

        var toLoad = new List<Int3>();
        foreach (var pos in desired)
            if (!chunks.ContainsKey(pos))
                toLoad.Add(pos);

        toLoad.Sort((a, b) => ChebyshevDist(a, playerChunk).CompareTo(ChebyshevDist(b, playerChunk)));

        foreach (var pos in toLoad)
        {
            _chunkLoadQueue.Enqueue(pos);
            _pendingChunks.Add(pos);
        }

        // Update collision on already-loaded chunks
        UpdateCollisionForChunks(playerChunk);
    }

    private void ProcessChunkQueue()
    {
        if (_chunkLoadQueue.Count == 0) return;
        var pos = _chunkLoadQueue.Dequeue();
        _pendingChunks.Remove(pos);
        if (!chunks.ContainsKey(pos))
            CreateChunk(pos);
    }

    private void UpdateCollisionForChunks(Int3 playerChunk)
    {
        foreach (var (pos, chunk) in chunks)
        {
            int dx = pos.X - playerChunk.X; if (dx < 0) dx = -dx;
            int dz = pos.Z - playerChunk.Z; if (dz < 0) dz = -dz;
            chunk.SetCollisionEnabled(dx <= CollisionDistance && dz <= CollisionDistance);
        }
    }

    private static int ChebyshevDist(Int3 a, Int3 b)
    {
        int dx = a.X - b.X; if (dx < 0) dx = -dx;
        int dz = a.Z - b.Z; if (dz < 0) dz = -dz;
        return dx > dz ? dx : dz;
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

        // Set collision state before meshing so GenerateMesh respects it
        int dx = chunkPos.X - _lastPlayerChunk.X; if (dx < 0) dx = -dx;
        int dz = chunkPos.Z - _lastPlayerChunk.Z; if (dz < 0) dz = -dz;
        chunk.SetCollisionEnabled(dx <= CollisionDistance && dz <= CollisionDistance);

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
