using System;

namespace RAEngine.Water;

/// <summary>Per-cell state flags (packed into <see cref="WaterCell.Flags"/>).</summary>
[Flags]
public enum WaterFlags : byte
{
    None = 0,
    Source = 1,     // infinite source; always full, never decays
    Falling = 2,    // fed from above; renders thin, spreads from landing
    SeaFilled = 4,  // produced by the global sea-level fill (cheap bulk evict)
    Frozen = 8,     // cosmetic ice
    Settled = 16,   // unchanged for N ticks; removed from the active set
    Edge = 32,      // shoreline (horizontally adjacent to non-water)
}

/// <summary>Rendering/audio class for a water cell, produced by the classifier.</summary>
public enum WaterClass : byte
{
    Calm = 0,
    River = 1,
    Waterfall = 2,
    WaterfallLip = 3, // calm/river cell about to tip over an edge
    PlungePool = 4,   // turbulent receiving pool under a fall
    Shoreline = 5,    // water meeting solid (edge foam)
    Rapids = 6,       // fast river with a steep level gradient
}

/// <summary>
/// The side-channel record for one water cell. 4 bytes, blittable. The host
/// voxel grid only knows "water present here"; this holds the level/flow detail.
/// </summary>
public struct WaterCell
{
    public byte Level;   // 0 = empty, 1..8 = water (8 = full/source-equivalent)
    public byte Flags;   // WaterFlags bitfield
    public sbyte FlowX;  // quantized horizontal flow direction (-127..127)
    public sbyte FlowZ;

    public const byte MaxLevel = 8;

    public readonly bool IsWater => Level > 0;

    public readonly bool Has(WaterFlags f) => (Flags & (byte)f) != 0;

    public void Set(WaterFlags f, bool on)
    {
        if (on) Flags |= (byte)f;
        else Flags &= unchecked((byte)~(byte)f);
    }

    public readonly bool IsSource => Has(WaterFlags.Source);
    public readonly bool IsFalling => Has(WaterFlags.Falling);

    public static WaterCell Source() => new() { Level = MaxLevel, Flags = (byte)WaterFlags.Source };
    public static WaterCell Flow(byte level) => new() { Level = level };
}
