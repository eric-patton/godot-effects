using Godot;

namespace Sandbox.Water;

/// <summary>
/// Tiny block table for the sandbox harness. This mirrors the *contract* the
/// water module needs from a host (an air id, a water id, solidity/opacity
/// predicates) without any of ra-engine's richness. Throwaway — not ported.
/// </summary>
public static class SandboxBlocks
{
    public const ushort Air = 0;
    public const ushort Stone = 1;
    public const ushort Dirt = 2;
    public const ushort Grass = 3;
    public const ushort Glass = 4;
    public const ushort Water = 5;

    /// <summary>Blocks that occupy space (stop flow, can be walked on).</summary>
    public static bool IsSolid(ushort id) => id is Stone or Dirt or Grass or Glass;

    /// <summary>Blocks that fully hide neighbouring faces (used for face culling).</summary>
    public static bool IsOpaque(ushort id) => id is Stone or Dirt or Grass;

    public static bool IsWater(ushort id) => id == Water;

    /// <summary>Vertex-colour for the opaque/glass mesher (RGBA; glass uses alpha).</summary>
    public static Color ColorOf(ushort id) => id switch
    {
        Stone => new Color(0.54f, 0.55f, 0.58f),
        Dirt  => new Color(0.42f, 0.30f, 0.19f),
        Grass => new Color(0.33f, 0.55f, 0.27f),
        Glass => new Color(0.60f, 0.82f, 0.92f, 0.32f),
        _     => Colors.Magenta,
    };
}
