using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// The module's per-chunk side channel, aligned 1:1 with the host's voxel grid
/// (same 16³ size and <c>(y*16+z)*16+x</c> indexing). Holds the rich water
/// state the host grid can't. ~20 KB per water-bearing chunk; dry chunks don't
/// exist (sparse) and a chunk is evicted when its WaterCount hits 0.
/// </summary>
public sealed class WaterChunk
{
    public const int CS = 16;
    public const int CV = CS * CS * CS; // 4096

    public Vector3I Coord;
    public readonly WaterCell[] Cells = new WaterCell[CV];
    public readonly byte[] Class = new byte[CV]; // WaterClass per cell, set by classifier
    public int WaterCount;                        // live water cells; 0 => evictable

    public bool MeshDirty = true;   // surface mesh needs rebuild
    public bool ClassDirty = true;  // classification needs recompute
    public uint MeshVersion;        // bumped on edit; async builder drops stale results

    /// <summary>Local indices of turbulent cells (lip/plunge/rapids) — foam &amp; spray spawn here.</summary>
    public readonly List<int> Turbulent = new();

    public static int Index(int lx, int ly, int lz) => (ly * CS + lz) * CS + lx;
}
