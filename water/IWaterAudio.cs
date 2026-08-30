using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>A point of water sound the manager wants heard (the host decides how).</summary>
public struct WaterAudioCluster
{
    public Vector3 Pos;
    public WaterClass Class;   // calm / river / waterfall etc — selects the loop
    public float Strength;     // 0..1, drives volume
}

/// <summary>
/// Audio abstraction: the module says WHAT should sound and WHERE; the host
/// implements playback (the sandbox synthesizes loops; ra-engine uses its own
/// runtime synth). Optional — water works fine without it.
/// </summary>
public interface IWaterAudio
{
    void Configure(WaterSettings s);
    void UpdateClusters(Vector3 listener, IReadOnlyList<WaterAudioCluster> clusters);
    void SetSubmerged(bool submerged);
}
