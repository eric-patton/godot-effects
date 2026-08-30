using System;
using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Implements the portable <see cref="IVoxelWorld"/> seam over the sandbox's
/// <see cref="SandboxWorld"/>. This is the exact analogue of the adapter a
/// ra-engine developer will write over their real VoxelWorld.
/// </summary>
public sealed class SandboxVoxelWorldAdapter : IVoxelWorld
{
    private readonly SandboxWorld _w;

    public SandboxVoxelWorldAdapter(SandboxWorld w)
    {
        _w = w;
        // re-raise the host's event through the seam, verbatim (no filtering
        // here — the WaterManager itself ignores WaterCause.WaterSim).
        _w.BlockChanged += (p, o, n, c) => BlockChanged?.Invoke(p, o, n, c);
    }

    public ushort GetBlockId(int x, int y, int z) => _w.GetBlockId(x, y, z);
    public bool IsSolid(int x, int y, int z) => _w.IsSolid(x, y, z);
    public bool IsAir(int x, int y, int z) => _w.GetBlockId(x, y, z) == SandboxBlocks.Air;

    public void SetBlock(int x, int y, int z, ushort id, bool remesh = true, int cause = WaterCause.WaterSim)
        => _w.SetBlock(x, y, z, id, remesh, cause);

    public ushort WaterId => SandboxBlocks.Water;
    public ushort AirId => SandboxBlocks.Air;
    public int MinY => -32;
    public int MaxY => 96;

    public event Action<Vector3I, ushort, ushort, int> BlockChanged;

    /// <summary>Amanatides &amp; Woo DDA voxel traversal; returns the first solid cell.</summary>
    public bool Raycast(Vector3 origin, Vector3 dir, float maxDist,
        out Vector3I cell, out Vector3I faceNormal, out Vector3 hitPos)
    {
        cell = default; faceNormal = default; hitPos = default;
        dir = dir.Normalized();
        if (dir == Vector3.Zero) return false;

        int x = Mathf.FloorToInt(origin.X);
        int y = Mathf.FloorToInt(origin.Y);
        int z = Mathf.FloorToInt(origin.Z);

        int stepX = Math.Sign(dir.X), stepY = Math.Sign(dir.Y), stepZ = Math.Sign(dir.Z);
        float tMaxX = IntBound(origin.X, dir.X);
        float tMaxY = IntBound(origin.Y, dir.Y);
        float tMaxZ = IntBound(origin.Z, dir.Z);
        float tDeltaX = stepX != 0 ? Mathf.Abs(1f / dir.X) : float.PositiveInfinity;
        float tDeltaY = stepY != 0 ? Mathf.Abs(1f / dir.Y) : float.PositiveInfinity;
        float tDeltaZ = stepZ != 0 ? Mathf.Abs(1f / dir.Z) : float.PositiveInfinity;

        var norm = Vector3I.Zero;
        float t = 0f;
        // generous iteration cap
        for (int iter = 0; iter < 1024 && t <= maxDist; iter++)
        {
            if (_w.IsSolid(x, y, z))
            {
                cell = new Vector3I(x, y, z);
                faceNormal = norm;
                hitPos = origin + dir * t;
                return true;
            }
            if (tMaxX < tMaxY)
            {
                if (tMaxX < tMaxZ) { x += stepX; t = tMaxX; tMaxX += tDeltaX; norm = new Vector3I(-stepX, 0, 0); }
                else { z += stepZ; t = tMaxZ; tMaxZ += tDeltaZ; norm = new Vector3I(0, 0, -stepZ); }
            }
            else
            {
                if (tMaxY < tMaxZ) { y += stepY; t = tMaxY; tMaxY += tDeltaY; norm = new Vector3I(0, -stepY, 0); }
                else { z += stepZ; t = tMaxZ; tMaxZ += tDeltaZ; norm = new Vector3I(0, 0, -stepZ); }
            }
        }
        return false;
    }

    private static float IntBound(float s, float ds)
    {
        if (ds == 0f) return float.PositiveInfinity;
        if (ds < 0f) { s = -s; ds = -ds; }
        float frac = s - Mathf.Floor(s);
        return (1f - frac) / ds;
    }
}
