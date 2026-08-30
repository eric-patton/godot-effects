using System;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// The single seam between the portable water module and whatever voxel world
/// hosts it. The sandbox implements this over its toy world; ra-engine
/// implements it over its real VoxelWorld. The water module references nothing
/// else about the host — implement this and the module drops in.
///
/// Coordinates are world block coordinates (1 block = 1 unit). The host grid is
/// the source of truth for water *presence* (a single <see cref="WaterId"/>
/// block); the module keeps the rich per-cell level/flow detail in its own
/// side channel (<see cref="WaterField"/>).
/// </summary>
public interface IVoxelWorld
{
    // ---- reads (called heavily by the sim; keep them cheap) ----
    ushort GetBlockId(int x, int y, int z);
    bool IsSolid(int x, int y, int z);   // stops flow and supports water
    bool IsAir(int x, int y, int z);     // can be flowed into

    // ---- writes (the sim writes only the water id / air) ----
    // cause lets the host adapter suppress re-notifying us about our own edits
    // (avoids a BlockChanged feedback loop). See WaterCause.
    void SetBlock(int x, int y, int z, ushort id, bool remesh = true, int cause = WaterCause.WaterSim);

    // ---- ids (module stays id-agnostic) ----
    ushort WaterId { get; }
    ushort AirId { get; }

    // ---- world vertical bounds (sea-level fill & sim clamping) ----
    int MinY { get; }
    int MaxY { get; }

    // ---- raycast (build tools / swimmer). Returns the first solid cell. ----
    bool Raycast(Vector3 origin, Vector3 dir, float maxDist,
                 out Vector3I cell, out Vector3I faceNormal, out Vector3 hitPos);

    // ---- change notification: host raises this for EVERY block edit ----
    // (pos, oldId, newId, cause). The manager subscribes and ignores
    // cause == WaterCause.WaterSim to avoid reacting to itself.
    event Action<Vector3I, ushort, ushort, int> BlockChanged;
}

/// <summary>Edit-cause tags. Mirrors ra-engine's BlockChangeCause loosely; the
/// only one the module cares about is <see cref="WaterSim"/>.</summary>
public static class WaterCause
{
    public const int PlayerEdit = 0;
    public const int WorldGen = 1;
    public const int WaterSim = 2;
}
