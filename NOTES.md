Different ways to opimize the voxel terrain.

Here are the researched approaches, ranked by expected impact:

**Meshing**

1. **Greedy meshing** — merge coplanar adjacent faces into larger quads; flat terrain goes from 512 quads → ~4, 3-8x fewer vertices
2. **Background thread meshin**g — move all of GenerateMesh off the main thread, swap the mesh in when done
3. **Defer neighbor re-meshes** — queue them like regular chunks instead of running 4 synchronous re-meshes the moment a chunk loads (this alone can cut a 300ms spike to ~60ms)
4. **LOD meshes** — coarser mesh for far chunks (skip every 2nd/4th voxel), full detail only up close
5. **Reduce Y scan range** — terrain density is heavily weighted to the bottom 20 units; add a per-column height prepass to skip scanning dead air above the surface

**Noise / Generation**
6. Pre-bake density grid — sample the full 18×18×18 block of densities once before meshing starts, then all of SampleWorld becomes a cheap array lookup; avoids 60k–96k repeated noise calls
7. Reduce noise layers — SampleWorld fires 3 separate noise calls per voxel; combining or pre-slicing the 2D height variation (constant per X/Z column) drops this by ~30%

**Collision**
8. Async collider baking — check if Jitter2 supports off-thread baking; synchronous baking is currently 15–30ms per chunk and fires on every re-mesh

**Architecture**
9. Double-buffered meshes — keep a "live" and "building" slot per chunk; renderer always shows the live mesh while the new one generates in the background
10. Coroutine/yielding meshing — if threading isn't available, spread the voxel loop across multiple frames by yielding every N rows