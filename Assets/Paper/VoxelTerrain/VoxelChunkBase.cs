using Prowl.Runtime;
using Prowl.Vector;

namespace Paper.VoxelTerrain;

public abstract class VoxelChunkBase : MonoBehaviour
{
    public abstract void Initialize(Int3 chunkPos, VoxelWorld voxelWorld);
    public abstract byte GetVoxel(int x, int y, int z);
    public abstract void SetVoxel(int x, int y, int z, byte value);
    public abstract void GenerateChunk();
    public abstract void GenerateMesh();
}
