// This file is part of the Prowl Game Engine
// Licensed under the MIT License. See the LICENSE file in the project root for details.

using System.Collections.Generic;

using Jitter2.Collision.Shapes;
using Jitter2.LinearMath;

using Prowl.Echo;
using Prowl.Runtime;
using Prowl.Runtime.Resources;
using Prowl.Vector;

namespace Paper.VoxelTerrain;

/// <summary>
/// Builds a physics collider from a Mesh asset.
/// </summary>
// [AddComponentMenu("Voxel Collider")]
[ComponentIcon("\uf1b3")] // Cubes
public sealed class VoxelCollider : Collider
{
    // Cached convex hull shape and its tessellation for gizmo drawing — rebuilt when mesh or convex flag changes.

    [SerializeIgnore] private Mesh? _mesh;
    [SerializeIgnore] private bool _convex;
    [SerializeIgnore] private ConvexHullShape? _cachedConvexShape;
    [SerializeIgnore] private List<JTriangle>? _cachedHullTris;
    [SerializeIgnore] private RigidBodyShape[] _cachedRigidBodyShapes = null;

    public void ComputeColliderShape(Mesh? mesh, bool convex = false)
    {
        _mesh = mesh;
        _convex = convex;

        if (mesh is null)
        {
            _cachedRigidBodyShapes = [];
            return;
        }

        _cachedHullTris = ToTriangleList(mesh);
        if (_cachedHullTris.Count == 0)
        {
            Debug.LogWarning("MeshCollider: mesh has no triangles.");
            return;
        }

        if (_convex)
        {
            _cachedConvexShape = new ConvexHullShape(_cachedHullTris);
            _cachedRigidBodyShapes = [_cachedConvexShape];
        }
        else
        {
            var triMesh = new TriangleMesh(_cachedHullTris, true);
            var shapes = new TriangleShape[_cachedHullTris.Count];
            for (int i = 0; i < _cachedHullTris.Count; i++)
                shapes[i] = new TriangleShape(triMesh, i);
            _cachedRigidBodyShapes = shapes;
        }
    }

    public override RigidBodyShape[] CreateShapes()
    {
        return _cachedRigidBodyShapes;
    }

    public override void OnValidate()
    {
        base.OnValidate();
    }

    public override void DrawGizmos()
    {
        Float4x4 matrix = Float4x4.CreateTRS(Transform.Position, Transform.Rotation * Quaternion.FromEuler(Rotation), Transform.LossyScale);
        Debug.PushMatrix(matrix);

        if (_convex)
        {
            DrawConvexHullGizmo();
        }
        else
        {
            DrawMeshWireframeGizmo();
        }

        Debug.PopMatrix();
    }

    private void DrawMeshWireframeGizmo()
    {
        if (_mesh == null) return;

        Float3[] vertices = _mesh.Vertices;
        uint[] indices = _mesh.Indices;
        if (vertices == null || indices == null) return;

        for (int i = 0; i + 2 < indices.Length; i += 3)
        {
            uint i0 = indices[i], i1 = indices[i + 1], i2 = indices[i + 2];
            if (i0 >= vertices.Length || i1 >= vertices.Length || i2 >= vertices.Length)
                continue;

            Float3 v0 = vertices[i0] + Center;
            Float3 v1 = vertices[i1] + Center;
            Float3 v2 = vertices[i2] + Center;

            Debug.DrawLine(v0, v1, Color.Green);
            Debug.DrawLine(v1, v2, Color.Green);
            Debug.DrawLine(v2, v0, Color.Green);
        }
    }

    private void DrawConvexHullGizmo()
    {
        if (_cachedConvexShape == null) return;
        if (_cachedHullTris == null) return;

        JVector shift = _cachedConvexShape.Shift;

        foreach (JTriangle tri in _cachedHullTris)
        {
            // Hull vertices are CoM-centered; add Shift to convert back to mesh-local space.
            Float3 a = new Float3(tri.V0.X + shift.X, tri.V0.Y + shift.Y, tri.V0.Z + shift.Z) + Center;
            Float3 b = new Float3(tri.V1.X + shift.X, tri.V1.Y + shift.Y, tri.V1.Z + shift.Z) + Center;
            Float3 c = new Float3(tri.V2.X + shift.X, tri.V2.Y + shift.Y, tri.V2.Z + shift.Z) + Center;

            Debug.DrawLine(a, b, Color.Green);
            Debug.DrawLine(b, c, Color.Green);
            Debug.DrawLine(c, a, Color.Green);
        }
    }

    private static List<JTriangle> ToTriangleList(Mesh mesh)
    {
        var vertices = mesh.Vertices;
        var indices = mesh.Indices;
        var triangles = new List<JTriangle>(indices.Length / 3);

        // i + 2 < indices.Length protects against malformed meshes whose index count
        // isn't a multiple of 3, and also protects the i+1/i+2 reads.
        for (int i = 0; i + 2 < indices.Length; i += 3)
        {
            uint i0 = indices[i];
            uint i1 = indices[i + 1];
            uint i2 = indices[i + 2];

            // Skip degenerate triangles whose indices are out of range
            if (i0 >= vertices.Length || i1 >= vertices.Length || i2 >= vertices.Length)
                continue;

            var v0 = vertices[i0];
            var v1 = vertices[i1];
            var v2 = vertices[i2];
            triangles.Add(new JTriangle(
                new JVector(v0.X, v0.Y, v0.Z),
                new JVector(v1.X, v1.Y, v1.Z),
                new JVector(v2.X, v2.Y, v2.Z)));
        }

        return triangles;
    }
}
