using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Sparse store of <see cref="WaterChunk"/>s keyed by chunk coordinate, with
/// host-identical coordinate math. Cross-chunk neighbour access is just
/// <see cref="GetCell(int,int,int)"/> on the neighbour's world position — the
/// dictionary absorbs the boundary, so the sim never asks the host to resolve
/// neighbours. A one-entry "last chunk" cache makes within-chunk iteration cheap.
/// </summary>
public sealed class WaterField
{
    public const int CS = 16;

    private readonly Dictionary<Vector3I, WaterChunk> _chunks = new();
    private Vector3I _lastCoord = new(int.MinValue, int.MinValue, int.MinValue);
    private WaterChunk _last;

    public IReadOnlyDictionary<Vector3I, WaterChunk> Chunks => _chunks;

    public static Vector3I ChunkOf(int x, int y, int z) => new(x >> 4, y >> 4, z >> 4);

    public WaterChunk GetChunk(Vector3I cc)
    {
        if (cc == _lastCoord) return _last;
        _chunks.TryGetValue(cc, out var c);
        _lastCoord = cc;
        _last = c;
        return c;
    }

    public WaterChunk GetOrCreateChunk(Vector3I cc)
    {
        var c = GetChunk(cc);
        if (c == null)
        {
            c = new WaterChunk { Coord = cc };
            _chunks[cc] = c;
            _last = c;
            _lastCoord = cc;
        }
        return c;
    }

    public WaterCell GetCell(int x, int y, int z)
    {
        var c = GetChunk(ChunkOf(x, y, z));
        return c == null ? default : c.Cells[WaterChunk.Index(x & 15, y & 15, z & 15)];
    }

    public WaterCell GetCell(Vector3I p) => GetCell(p.X, p.Y, p.Z);

    public byte GetClass(int x, int y, int z)
    {
        var c = GetChunk(ChunkOf(x, y, z));
        return c == null ? (byte)0 : c.Class[WaterChunk.Index(x & 15, y & 15, z & 15)];
    }

    /// <summary>Write a cell, maintaining WaterCount and dirtying the chunk.</summary>
    public void SetCell(int x, int y, int z, WaterCell cell)
    {
        var cc = ChunkOf(x, y, z);
        var c = GetOrCreateChunk(cc);
        int i = WaterChunk.Index(x & 15, y & 15, z & 15);
        bool wasWater = c.Cells[i].Level > 0;
        bool isWater = cell.Level > 0;
        c.Cells[i] = cell;
        if (!wasWater && isWater) c.WaterCount++;
        else if (wasWater && !isWater) c.WaterCount--;
        c.MeshDirty = true;
        c.ClassDirty = true;
        c.MeshVersion++;

        // a boundary change affects the neighbour chunk's seam (corner heights + side culling)
        int lx = x & 15, ly = y & 15, lz = z & 15;
        if (lx == 0) DirtyNeighbor(cc + new Vector3I(-1, 0, 0));
        else if (lx == 15) DirtyNeighbor(cc + new Vector3I(1, 0, 0));
        if (ly == 0) DirtyNeighbor(cc + new Vector3I(0, -1, 0));
        else if (ly == 15) DirtyNeighbor(cc + new Vector3I(0, 1, 0));
        if (lz == 0) DirtyNeighbor(cc + new Vector3I(0, 0, -1));
        else if (lz == 15) DirtyNeighbor(cc + new Vector3I(0, 0, 1));
    }

    private void DirtyNeighbor(Vector3I cc)
    {
        if (_chunks.TryGetValue(cc, out var c)) { c.MeshDirty = true; c.ClassDirty = true; }
    }

    public void SetCell(Vector3I p, WaterCell cell) => SetCell(p.X, p.Y, p.Z, cell);

    public void ClearCell(int x, int y, int z) => SetCell(x, y, z, default);

    public bool HasWater(int x, int y, int z) => GetCell(x, y, z).Level > 0;

    /// <summary>Drop chunks that no longer contain any water.</summary>
    public int EvictEmpty()
    {
        List<Vector3I> rm = null;
        foreach (var kv in _chunks)
            if (kv.Value.WaterCount <= 0)
                (rm ??= new List<Vector3I>()).Add(kv.Key);
        if (rm == null) return 0;
        foreach (var k in rm)
        {
            _chunks.Remove(k);
            if (_lastCoord == k) { _last = null; _lastCoord = new(int.MinValue, int.MinValue, int.MinValue); }
        }
        return rm.Count;
    }

    public int ChunkCount => _chunks.Count;

    public int TotalWaterCells
    {
        get
        {
            int n = 0;
            foreach (var c in _chunks.Values) n += c.WaterCount;
            return n;
        }
    }
}
