using Prowl.Runtime;
using Prowl.Runtime.Resources;
using Prowl.Vector;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading.Tasks;
using Auburn.FastNoiseLite;
using System.Diagnostics;

namespace Paper.VoxelTerrain;

public enum ChunkLoadMode { SingleThreaded, Multithreaded }

public class VoxelWorld : MonoBehaviour
{
    public GameObject Player;
    public AnimationCurve HeightCurve;
    public AssetRef<Material> Material;

    public int RenderDistance = 4;
    public int CollisionDistance = 1;
    public ChunkLoadMode LoadMode = ChunkLoadMode.Multithreaded;

    private const int ChunkWidth  = 16;
    private const int ChunkHeight = 48;
    private const int ChunkDepth  = 16;

    private const float UpdateInterval = 0.5f;
    private float _updateTimer = 0f;

    private Dictionary<Int3, InterpolatedCubeChunk> chunks = [];
    private Queue<Int3> _chunkLoadQueue = new();
    private HashSet<Int3> _pendingChunks = new();
    private readonly ConcurrentQueue<Action> _mainThreadQueue = new();

    public FastNoiseLite noise;

    private Int3 _lastPlayerChunk = new(int.MaxValue, 0, int.MaxValue);

    Stopwatch _stopwatch = new Stopwatch();

    public override void OnEnable()
    {
        noise = new FastNoiseLite();
        noise.SetNoiseType(FastNoiseLite.NoiseType.OpenSimplex2);
        UpdateChunksAroundPlayer(GetPlayerChunk());
        ProcessChunkQueue();
    }

    public override void Update()
    {
        if (Player is null) return;

        // Process one upload per frame to avoid spiking when many Tasks finish at once
        if (_mainThreadQueue.TryDequeue(out var action))
            action();

        ProcessChunkQueue();

        _updateTimer -= Time.DeltaTime;
        if (_updateTimer > 0f) return;
        _updateTimer = UpdateInterval;

        Int3 playerChunk = GetPlayerChunk();
        if (playerChunk != _lastPlayerChunk)
        {
            UpdateChunksAroundPlayer(playerChunk);
            ProcessChunkQueue(); // immediately load the new player chunk on boundary crossing
        }
    }

    private Int3 GetPlayerChunk() => Player is not null
        ? WorldToChunkPos(new Int3(
            (int)Maths.Floor(Player.Transform.Position.X), 0,
            (int)Maths.Floor(Player.Transform.Position.Z)))
        : new Int3(0, 0, 0);

    private void UpdateChunksAroundPlayer(Int3 playerChunk)
    {
        _stopwatch.Restart();
        _lastPlayerChunk = playerChunk;

        HashSet<Int3> desired = [];
        for (int x = -RenderDistance; x <= RenderDistance; x++)
        for (int z = -RenderDistance; z <= RenderDistance; z++)
            desired.Add(new Int3(playerChunk.X + x, 0, playerChunk.Z + z));

        List<Int3> toRemove = [];
        foreach (var (pos, _) in chunks)
            if (!desired.Contains(pos))
                toRemove.Add(pos);
        foreach (var pos in toRemove)
            DestroyChunk(pos);

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
        _stopwatch.Stop();
        Prowl.Runtime.Debug.Log("Update Chunks took " + _stopwatch.ElapsedMilliseconds + "ms");

        _stopwatch.Restart();
        UpdateCollisionForChunks(playerChunk);
        _stopwatch.Stop();
        Prowl.Runtime.Debug.Log("Update Collision took " + _stopwatch.ElapsedMilliseconds + "ms");
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
        var sw = Stopwatch.StartNew();

        GameObject chunkGO = new($"Chunk_{chunkPos.X}_{chunkPos.Y}_{chunkPos.Z}");
        chunkGO.Transform.SetParent(Transform);
        chunkGO.Transform.Position = new Float3(
            chunkPos.X * ChunkWidth,
            chunkPos.Y * ChunkHeight,
            chunkPos.Z * ChunkDepth
        );
        var chunk = chunkGO.AddComponent<InterpolatedCubeChunk>()!;
        chunk.Initialize(chunkPos, this);
        chunks[chunkPos] = chunk;
        Prowl.Runtime.Debug.Log($"[{LoadMode}] GameObject+AddComponent: {sw.ElapsedMilliseconds}ms");

        sw.Restart();
        Scene.Add(chunkGO);
        Prowl.Runtime.Debug.Log($"[{LoadMode}] Scene.Add: {sw.ElapsedMilliseconds}ms");

        int dx = chunkPos.X - _lastPlayerChunk.X; if (dx < 0) dx = -dx;
        int dz = chunkPos.Z - _lastPlayerChunk.Z; if (dz < 0) dz = -dz;
        chunk.SetCollisionEnabled(dx <= CollisionDistance && dz <= CollisionDistance);

        if (LoadMode == ChunkLoadMode.SingleThreaded)
        {
            sw.Restart();
            chunk.BakeDensityGrid();
            Prowl.Runtime.Debug.Log($"[SingleThreaded] BakeDensityGrid: {sw.ElapsedMilliseconds}ms");

            sw.Restart();
            var mesh = chunk.BuildMeshData();
            Prowl.Runtime.Debug.Log($"[SingleThreaded] BuildMeshData: {sw.ElapsedMilliseconds}ms");

            sw.Restart();
            chunk.ApplyMesh(mesh);
            Prowl.Runtime.Debug.Log($"[SingleThreaded] ApplyMesh: {sw.ElapsedMilliseconds}ms");
            return;
        }

        // BakeDensityGrid and BuildMeshData are safe off-thread:
        // noise/curve reads are stateless, and the Mesh object is exclusively
        // owned by the Task until ApplyMesh hands it to the main thread.
        Task.Run(() =>
        {
            var tsw = Stopwatch.StartNew();
            chunk.BakeDensityGrid();
            Prowl.Runtime.Debug.Log($"[Multithreaded Task] BakeDensityGrid: {tsw.ElapsedMilliseconds}ms");

            tsw.Restart();
            var mesh = chunk.BuildMeshData();
            Prowl.Runtime.Debug.Log($"[Multithreaded Task] BuildMeshData: {tsw.ElapsedMilliseconds}ms");

            _mainThreadQueue.Enqueue(() =>
            {
                if (chunks.ContainsKey(chunkPos))
                {
                    var usw = Stopwatch.StartNew();
                    chunk.ApplyMesh(mesh);
                    Prowl.Runtime.Debug.Log($"[Multithreaded Upload] ApplyMesh: {usw.ElapsedMilliseconds}ms");
                }
            });
        });
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
            worldPos.X >= 0 ? worldPos.X / ChunkWidth  : (worldPos.X - ChunkWidth  + 1) / ChunkWidth,
            0,
            worldPos.Z >= 0 ? worldPos.Z / ChunkDepth  : (worldPos.Z - ChunkDepth  + 1) / ChunkDepth
        );
    }
}
