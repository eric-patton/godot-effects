using System;
using System.Collections.Generic;
using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Sandbox implementation of <see cref="IWaterAudio"/> that synthesizes looping
/// water beds at runtime (no audio asset files) and plays them positionally from
/// a pool of <see cref="AudioStreamPlayer3D"/>. ra-engine would implement this
/// with its own runtime synth; the module never references concrete streams.
/// </summary>
public sealed class SandboxWaterAudio : IWaterAudio
{
    private readonly Node3D _root;
    private AudioStreamWav _calm, _river, _falls;
    private AudioStreamPlayer3D[] _players = Array.Empty<AudioStreamPlayer3D>();
    private bool _submerged;

    public SandboxWaterAudio(Node3D root)
    {
        _root = root;
        _calm = MakeLoop(brightness: 0.06f, vol: 0.18f, seed: 1);
        _river = MakeLoop(brightness: 0.28f, vol: 0.32f, seed: 2);
        _falls = MakeLoop(brightness: 0.85f, vol: 0.6f, seed: 3);
    }

    public void Configure(WaterSettings s)
    {
        int n = Math.Max(0, s.AudioMaxSources);
        foreach (var p in _players) p?.QueueFree();
        _players = new AudioStreamPlayer3D[n];
        for (int i = 0; i < n; i++)
        {
            var p = new AudioStreamPlayer3D { UnitSize = 6f, MaxDistance = 48f, VolumeDb = -80f };
            _root.AddChild(p);
            _players[i] = p;
        }
    }

    public void UpdateClusters(Vector3 listener, IReadOnlyList<WaterAudioCluster> clusters)
    {
        for (int i = 0; i < _players.Length; i++)
        {
            var p = _players[i];
            if (i >= clusters.Count) { if (p.Playing) p.Stop(); p.VolumeDb = -80f; continue; }

            var c = clusters[i];
            var stream = c.Class switch
            {
                WaterClass.Waterfall or WaterClass.PlungePool or WaterClass.WaterfallLip => _falls,
                WaterClass.River or WaterClass.Rapids => _river,
                _ => _calm,
            };
            if (p.Stream != stream) { p.Stream = stream; p.Play(); }
            else if (!p.Playing) p.Play();

            p.GlobalPosition = c.Pos;
            float baseDb = Mathf.LinearToDb(Mathf.Clamp(c.Strength, 0.01f, 1f));
            p.VolumeDb = baseDb + (_submerged ? -8f : 0f);
            p.PitchScale = _submerged ? 0.8f : 1f; // muffle underwater
        }
    }

    public void SetSubmerged(bool submerged) => _submerged = submerged;

    // --- procedural looping water bed: filtered noise, brighter = louder/splashier ---
    private static AudioStreamWav MakeLoop(float brightness, float vol, int seed)
    {
        const int rate = 22050;
        int len = rate * 2; // 2 s loop
        var data = new byte[len * 2];
        var rng = new Random(seed);
        float prev = 0f;
        for (int i = 0; i < len; i++)
        {
            float n = (float)(rng.NextDouble() * 2.0 - 1.0);
            prev = Mathf.Lerp(prev, n, brightness);   // low-pass: small brightness = darker
            // gentle loop-edge fade to avoid a click
            float edge = Mathf.Min(1f, Mathf.Min(i, len - 1 - i) / (rate * 0.05f));
            short s = (short)(Mathf.Clamp(prev * vol, -1f, 1f) * edge * 32767f);
            data[i * 2] = (byte)(s & 0xFF);
            data[i * 2 + 1] = (byte)((s >> 8) & 0xFF);
        }
        return new AudioStreamWav
        {
            Format = AudioStreamWav.FormatEnum.Format16Bits,
            MixRate = rate,
            Stereo = false,
            Data = data,
            LoopMode = AudioStreamWav.LoopModeEnum.Forward,
            LoopBegin = 0,
            LoopEnd = len,
        };
    }
}
