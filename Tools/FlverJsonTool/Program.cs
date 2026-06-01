// BB Reborne DIY Tool
// Copyright (C) 2026 Greg Pitta
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// See the LICENSE file for details.


// FlverJsonTool — JSON dump + rebuild for SoulsFormatsNEXT (FLVER0/FLVER2)
//
// Key fixes applied in THIS version:
//  - Adds full FLVER2 GXLists export/import (critical for rendering)
//  - Restores Material.GXIndex from JSON (no more forced -1)
//  - FLVER.Node indices are short on import (cast)
//  - FLVER.Vertex.NormalW is INT
//  - VertexColors are float[4] (RGBA)
//  - LayoutTypeSize includes UByte4/UByte4Norm
//  - FLVER2.VertexBuffer "last fixes" preserved (EdgeCompressed + internal fields via reflection)
//  - FIX (UV/Tangent/Color correctness): per-mesh slot counts derived from the ACTUAL layouts used by that mesh's vertex buffers
//      * UV slot counting is TYPE-aware (Float4/UByte4Norm/Short4/Half4 consume 2 UV slots)
//      * Tangent/VertexColor slots are 1 each per semantic member (skipping SpeedTree special modifier)
//  - FIX: VertexBuffers are ordered by BufferIndex on import (stable stream order)
//  - FIX: UVs exported as float[3] (XYZ) and importer accepts float[2] or float[3] (back-compat)
//
// Notes:
//  - JSON byte[] fields (GXItem.Data) serialize as base64 via System.Text.Json (fine).
//  - Backslashes in JSON paths are escaped; deserialization restores them properly.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using SoulsFormats;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1)
                return Usage();

            var cmd = args[0].Trim().ToLowerInvariant();
            if (cmd is "dump" or "export")
            {
                if (args.Length < 3) return Usage();
                Dump(args[1], args[2]);
                Console.WriteLine($"OK: Wrote JSON dump to: {args[2]}");
                return 0;
            }
            else if (cmd is "rebuild" or "import")
            {
                if (args.Length < 3) return Usage();
                Rebuild(args[1], args[2]);
                Console.WriteLine($"OK: Wrote rebuilt FLVER to: {args[2]}");
                return 0;
            }

            return Usage();
        }
        catch (SchemaException se)
        {
            Console.Error.WriteLine("SCHEMA ERROR:");
            Console.Error.WriteLine(se.Message);
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ERROR:");
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
    }

    private static int Usage()
    {
        Console.WriteLine("FlverJsonTool");
        Console.WriteLine("Usage:");
        Console.WriteLine("  FlverJsonTool dump <in.flver> <out.json>");
        Console.WriteLine("  FlverJsonTool rebuild <in.json> <out.flver>");
        return 64;
    }

    // ---------------------------
    // JSON Models
    // ---------------------------

    private sealed class FlverDump
    {
        public string SchemaVersion { get; set; } = "2026-02-22.materialfix1";
        public string FlverKind { get; set; } = ""; // "FLVER0" or "FLVER2"
        public int Version { get; set; }
        public bool BigEndian { get; set; }
        public bool Unicode { get; set; }

        public HeaderJson Header { get; set; } = new();

        public List<NodeJson> Nodes { get; set; } = new();
        public List<DummyJson> Dummies { get; set; } = new();

        // FLVER2
        public List<BufferLayoutJson> GlobalBufferLayouts { get; set; } = new();
        public List<GXListJson> GXLists2 { get; set; } = new();
        public List<Flver2MaterialJson> Materials2 { get; set; } = new();
        public List<Flver2MeshJson> Meshes2 { get; set; } = new();

        // FLVER0
        public List<Flver0MaterialJson> Materials0 { get; set; } = new();
        public List<Flver0MeshJson> Meshes0 { get; set; } = new();
    }

    private sealed class HeaderJson
    {
        public float[] BoundingBoxMin { get; set; } = new float[3];
        public float[] BoundingBoxMax { get; set; } = new float[3];

        // FLVER2-only extras
        public bool? Unk4A { get; set; }
        public bool? Unk4B { get; set; }
        public int? Unk4C { get; set; }
        public byte? Unk5C { get; set; }
        public byte? Unk5D { get; set; }
        public int? Unk68 { get; set; }
        public short? SpecialModifier { get; set; }
        public int? Unk74 { get; set; }

        // FLVER0-only extras
        public byte? VertexIndexSize { get; set; }
        public byte? Unk4A0 { get; set; }
        public byte? Unk4B0 { get; set; }
        public int? Unk4C0 { get; set; }
        public int? Unk5C0 { get; set; }
    }

    private sealed class NodeJson
    {
        public int Index { get; set; }
        public string? Name { get; set; }

        // Keep as int in JSON for readability, but SoulsFormats uses short internally -> cast on import.
        public int ParentIndex { get; set; }
        public int FirstChildIndex { get; set; }
        public int NextSiblingIndex { get; set; }
        public int PreviousSiblingIndex { get; set; }

        public float[] Translation { get; set; } = new float[3];
        public float[] Rotation { get; set; } = new float[3];
        public float[] Scale { get; set; } = new float[3];

        public float[] BoundingBoxMin { get; set; } = new float[3];
        public float[] BoundingBoxMax { get; set; } = new float[3];
        public int Flags { get; set; } // keep int in JSON
    }

    private sealed class DummyJson
    {
        public int Index { get; set; }
        public float[] Position { get; set; } = new float[3];
        public float[] Forward { get; set; } = new float[3];
        public float[] Upward { get; set; } = new float[3];

        // IMPORTANT: keep INT in JSON
        public int? ReferenceID { get; set; }

        public short? ParentBoneIndex { get; set; } // short
        public short? AttachBoneIndex { get; set; } // short

        public byte[]? ColorRGBA { get; set; } // [R,G,B,A]
        public bool? Flag1 { get; set; }
        public bool? UseUpwardVector { get; set; }
        public int? Unk30 { get; set; }
        public int? Unk34 { get; set; }
    }

    private sealed class BufferLayoutJson
    {
        public int Index { get; set; }
        public List<LayoutMemberJson> Members { get; set; } = new();
    }

    private sealed class LayoutMemberJson
    {
        public string Type { get; set; } = "";
        public string Semantic { get; set; } = "";
        public int Index { get; set; }
        public int SpecialModifier { get; set; }
    }

    // -------- FLVER2 --------

    private sealed class GXListJson
    {
        public int Index { get; set; }
        public int TerminatorID { get; set; } = int.MaxValue;
        public int TerminatorLength { get; set; } = 0;
        public List<GXItemJson> Items { get; set; } = new();
    }

    private sealed class GXItemJson
    {
        public string ID { get; set; } = "0";
        public int Unk04 { get; set; } = 100;
        public byte[] Data { get; set; } = Array.Empty<byte>(); // base64 in JSON
    }

    private sealed class Flver2MaterialJson
    {
        public int Index { get; set; }
        public string Name { get; set; } = "";
        public string MTD { get; set; } = "";
        public int GXIndex { get; set; } = -1;
        public int MaterialIndex { get; set; } = 0; // SoulsFormats Material.Index
        public List<Flver2TextureJson> Textures { get; set; } = new();
    }

    private sealed class Flver2TextureJson
    {
        public string ParamName { get; set; } = "";
        public string Path { get; set; } = "";

        // IMPORTANT: SoulsFormats default is Vector2.One.
        // If JSON ends up omitting or user edits it, keep sane default.
        public float[] TilingScale { get; set; } = new float[] { 1f, 1f };

        public byte TilingTypeU { get; set; }
        public byte TilingTypeV { get; set; }
        public float Unk14 { get; set; }
        public float Unk18 { get; set; }
        public float Unk1C { get; set; }
    }

    private sealed class Flver2MeshJson
    {
        public int Index { get; set; }
        public bool UseBoneWeights { get; set; }
        public int MaterialIndex { get; set; }
        public int NodeIndex { get; set; }
        public List<int> BoneIndices { get; set; } = new();
        public List<FaceSetJson> FaceSets { get; set; } = new();
        public List<VertexBufferJson> VertexBuffers { get; set; } = new();
        public List<VertexJson> Vertices { get; set; } = new();
        public BoundingBoxJson? BoundingBox { get; set; }
    }

    private sealed class BoundingBoxJson
    {
        public float[] Min { get; set; } = new float[3];
        public float[] Max { get; set; } = new float[3];
        public float[]? Unk { get; set; }
    }

    private sealed class FaceSetJson
    {
        public uint Flags { get; set; }
        public bool TriangleStrip { get; set; }
        public bool CullBackfaces { get; set; }
        public short Unk06 { get; set; }
        public List<int> Indices { get; set; } = new();
    }
   
    // FLVER2.VertexBuffer schema (your requested fixes)
    private sealed class VertexBufferJson
    {
        public bool EdgeCompressed { get; set; }
        public int BufferIndex { get; set; }     // stripped value
        public int BufferIndexRaw { get; set; }  // includes 0x6000_0000 when edge-compressed
        public int LayoutIndex { get; set; }

        public int VertexSize { get; set; }
        public int VertexCount { get; set; }
        public int BufferOffset { get; set; }
    }

    private sealed class VertexJson
    {
        public float[] Position { get; set; } = new float[3];
        public float[] Normal { get; set; } = new float[3];

        // in your build NormalW is INT
        public int NormalW { get; set; }

        public List<float[]> Tangents { get; set; } = new();     // each float[4]
        public List<float[]> UVs { get; set; } = new();          // each float[2] or float[3] (back-compat)
        public List<float[]> VertexColors { get; set; } = new(); // each float[4] RGBA

        public int[] BoneIndices { get; set; } = new int[4];
        public float[] BoneWeights { get; set; } = new float[4];
    }

    // -------- FLVER0 --------

    private sealed class Flver0MaterialJson
    {
        public int Index { get; set; }
        public string Name { get; set; } = "";
        public string MTD { get; set; } = "";
        public List<Flver0TextureJson> Textures { get; set; } = new();
        public List<Flver0BufferLayoutJson> Layouts { get; set; } = new();
    }

    private sealed class Flver0TextureJson
    {
        public string? ParamName { get; set; }
        public string Path { get; set; } = "";
    }

    private sealed class Flver0BufferLayoutJson
    {
        public List<LayoutMemberJson> Members { get; set; } = new();
        public int Size { get; set; }
    }

    private sealed class Flver0MeshJson
    {
        public int Index { get; set; }
        public byte Dynamic { get; set; }
        public byte MaterialIndex { get; set; }
        public bool CullBackfaces { get; set; }
        public bool TriangleStrip { get; set; }
        public short NodeIndex { get; set; }
        public short[] BoneIndices { get; set; } = new short[28];
        public int LayoutIndex { get; set; }
        public List<int> Indices { get; set; } = new();
        public List<VertexJson> Vertices { get; set; } = new();
    }

    private enum VertexColorCtorOrder { Unknown, RGBA, ARGB }
    private static VertexColorCtorOrder _vcOrder = VertexColorCtorOrder.Unknown;

    private static VertexColorCtorOrder DetectVertexColorOrder()
    {
        if (_vcOrder != VertexColorCtorOrder.Unknown)
            return _vcOrder;

        var t = typeof(FLVER.VertexColor);

        // Prefer byte ctor detection (most common + matches your symptom)
        var ctorB = t.GetConstructor(new[] { typeof(byte), typeof(byte), typeof(byte), typeof(byte) });
        if (ctorB != null)
        {
            // Use distinct values so we can spot rotation
            byte r = 10, g = 20, b = 30, a = 40;

            // Try RGBA
            var c1 = (FLVER.VertexColor)ctorB.Invoke(new object[] { r, g, b, a });
            var got1 = ReadVertexColorRGBA(c1); // returns 0..1 floats
            if (ToByte(got1[0]) == r && ToByte(got1[1]) == g && ToByte(got1[2]) == b && ToByte(got1[3]) == a)
                return _vcOrder = VertexColorCtorOrder.RGBA;

            // Try ARGB
            var c2 = (FLVER.VertexColor)ctorB.Invoke(new object[] { a, r, g, b });
            var got2 = ReadVertexColorRGBA(c2);
            if (ToByte(got2[0]) == r && ToByte(got2[1]) == g && ToByte(got2[2]) == b && ToByte(got2[3]) == a)
                return _vcOrder = VertexColorCtorOrder.ARGB;

            throw new Exception("Could not detect FLVER.VertexColor(byte,byte,byte,byte) parameter order.");
        }

        // Float ctor fallback (less common)
        var ctorF = t.GetConstructor(new[] { typeof(float), typeof(float), typeof(float), typeof(float) });
        if (ctorF != null)
        {
            float r = 0.1f, g = 0.2f, b = 0.3f, a = 0.4f;

            var c1 = (FLVER.VertexColor)ctorF.Invoke(new object[] { r, g, b, a });
            var got1 = ReadVertexColorRGBA(c1);
            if (Near(got1[0], r) && Near(got1[1], g) && Near(got1[2], b) && Near(got1[3], a))
                return _vcOrder = VertexColorCtorOrder.RGBA;

            var c2 = (FLVER.VertexColor)ctorF.Invoke(new object[] { a, r, g, b });
            var got2 = ReadVertexColorRGBA(c2);
            if (Near(got2[0], r) && Near(got2[1], g) && Near(got2[2], b) && Near(got2[3], a))
                return _vcOrder = VertexColorCtorOrder.ARGB;

            throw new Exception("Could not detect FLVER.VertexColor(float,float,float,float) parameter order.");
        }

        throw new Exception("No supported FLVER.VertexColor ctor found (byte4 or float4).");
    }

    private static byte ToByte(float x) => (byte)Math.Clamp((int)Math.Round(Clamp01(x) * 255f), 0, 255);
    private static bool Near(float a, float b) => Math.Abs(a - b) < 1e-3f;

   

    private static float ReadColorComponent(object value)
    {
        if (value is byte b) return b / 255f;
        if (value is sbyte sb) return Math.Clamp(sb / 127f, -1f, 1f); // unlikely for colors, but safe
        if (value is float f) return f;
        if (value is double d) return (float)d;
        if (value is int i) return i > 1 ? i / 255f : i;
        return 0f;
    }

    private static float[] ReadVertexColorRGBA(FLVER.VertexColor c)
    {
        var t = c.GetType();

        // Try common field/property names in SoulsFormats forks
        object? r = t.GetField("R")?.GetValue(c) ?? t.GetProperty("R")?.GetValue(c);
        object? g = t.GetField("G")?.GetValue(c) ?? t.GetProperty("G")?.GetValue(c);
        object? b = t.GetField("B")?.GetValue(c) ?? t.GetProperty("B")?.GetValue(c);
        object? a = t.GetField("A")?.GetValue(c) ?? t.GetProperty("A")?.GetValue(c);

        float rf = ReadColorComponent(r ?? 0f);
        float gf = ReadColorComponent(g ?? 0f);
        float bf = ReadColorComponent(b ?? 0f);
        float af = ReadColorComponent(a ?? 1f);

        // normalize heuristic + clamp
        return NormalizeColorRGBA(rf, gf, bf, af);
    }

    private static FLVER.VertexColor MakeVertexColor(float r, float g, float b, float a)
    {
        r = Clamp01(NormalizeColorComponent(r));
        g = Clamp01(NormalizeColorComponent(g));
        b = Clamp01(NormalizeColorComponent(b));
        a = Clamp01(NormalizeColorComponent(a));

        var order = DetectVertexColorOrder();
        var t = typeof(FLVER.VertexColor);

        var ctorB = t.GetConstructor(new[] { typeof(byte), typeof(byte), typeof(byte), typeof(byte) });
        if (ctorB != null)
        {
            byte rb = ToByte(r), gb = ToByte(g), bb = ToByte(b), ab = ToByte(a);

            object[] args = order == VertexColorCtorOrder.ARGB
                ? new object[] { ab, rb, gb, bb }   // A,R,G,B
                : new object[] { rb, gb, bb, ab };  // R,G,B,A

            return (FLVER.VertexColor)ctorB.Invoke(args);
        }

        var ctorF = t.GetConstructor(new[] { typeof(float), typeof(float), typeof(float), typeof(float) });
        if (ctorF != null)
        {
            object[] args = order == VertexColorCtorOrder.ARGB
                ? new object[] { a, r, g, b }
                : new object[] { r, g, b, a };

            return (FLVER.VertexColor)ctorF.Invoke(args);
        }

        throw new Exception("Unsupported FLVER.VertexColor ctor.");
    }



    // ---------------------------
    // Dump / Rebuild
    // ---------------------------

    private static void Dump(string inPath, string outJson)
    {
        if (!File.Exists(inPath))
            throw new FileNotFoundException(inPath);

        byte[] bytes = File.ReadAllBytes(inPath);

        FlverDump dump;
        if (TryReadFlver2(bytes, out var flv2))
            dump = ExportFLVER2(flv2!);
        else if (TryReadFlver0(bytes, out var flv0))
            dump = ExportFLVER0(flv0!);
        else
            throw new Exception("Input does not look like a supported FLVER (FLVER0 or FLVER2).");

        SchemaValidator.ValidateOrThrow(dump);

        File.WriteAllText(outJson, JsonSerializer.Serialize(dump, JsonOptions()));
    }

    private static void Rebuild(string inJson, string outFlver)
    {
        if (!File.Exists(inJson))
            throw new FileNotFoundException(inJson);

        var dump = JsonSerializer.Deserialize<FlverDump>(File.ReadAllText(inJson), JsonOptions())
                   ?? throw new Exception("Failed to parse JSON.");

        SchemaValidator.ValidateOrThrow(dump);

        if (dump.FlverKind == "FLVER2")
        {
            try
            {
                ImportFLVER2(dump).Write(outFlver);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("WRITE FAILED (FLVER2):");
                Console.Error.WriteLine(ex);
                throw;
            }
        }
        else if (dump.FlverKind == "FLVER0")
        {
            try
            {
                ImportFLVER0(dump).Write(outFlver);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("WRITE FAILED (FLVER0):");
                Console.Error.WriteLine(ex);
                throw;
            }
        }
        else
        {
            throw new SchemaException($"Unknown FlverKind '{dump.FlverKind}'.");
        }
    }

    // ---------------------------
    // SoulsFormats read helpers
    // ---------------------------

    private static bool TryReadFlver2(byte[] bytes, out FLVER2? model)
    {
        model = null;
        try
        {
            using var ms = new MemoryStream(bytes, writable: false);
            model = FLVER2.Read(ms);
            return true;
        }
        catch { return false; }
    }

    private static bool TryReadFlver0(byte[] bytes, out FLVER0? model)
    {
        model = null;
        try
        {
            using var ms = new MemoryStream(bytes, writable: false);
            model = FLVER0.Read(ms);
            return true;
        }
        catch { return false; }
    }

    // ---------------------------
    // Exporters
    // ---------------------------

    private static FlverDump ExportFLVER2(FLVER2 flv)
    {
        var dump = new FlverDump
        {
            FlverKind = "FLVER2",
            Version = flv.Header.Version,
            BigEndian = flv.Header.BigEndian,
            Unicode = flv.Header.Unicode,
            Header = new HeaderJson
            {
                BoundingBoxMin = V3(flv.Header.BoundingBoxMin),
                BoundingBoxMax = V3(flv.Header.BoundingBoxMax),
                Unk4A = flv.Header.Unk4A,
                Unk4B = flv.Header.Unk4B,
                Unk4C = flv.Header.Unk4C,
                Unk5C = flv.Header.Unk5C,
                Unk5D = flv.Header.Unk5D,
                Unk68 = flv.Header.Unk68,
                SpecialModifier = flv.Header.SpecialModifier,
                Unk74 = flv.Header.Unk74,
            }
        };

        dump.Dummies = flv.Dummies.Select((d, i) => new DummyJson
        {
            Index = i,
            Position = V3(d.Position),
            Forward = V3(d.Forward),
            Upward = V3(d.Upward),
            ReferenceID = d.ReferenceID,
            ParentBoneIndex = d.ParentBoneIndex,
            AttachBoneIndex = d.AttachBoneIndex,

            ColorRGBA = new[] { d.Color.R, d.Color.G, d.Color.B, d.Color.A },
            Flag1 = d.Flag1,
            UseUpwardVector = d.UseUpwardVector,
            Unk30 = d.Unk30,
            Unk34 = d.Unk34,
        }).ToList();

        dump.Nodes = flv.Nodes.Select((n, i) => new NodeJson
        {
            Index = i,
            Name = n.Name,

            ParentIndex = n.ParentIndex,
            FirstChildIndex = n.FirstChildIndex,
            NextSiblingIndex = n.NextSiblingIndex,
            PreviousSiblingIndex = n.PreviousSiblingIndex,

            Translation = V3(n.Translation),
            Rotation = V3(n.Rotation),
            Scale = V3(n.Scale),

            BoundingBoxMin = V3(n.BoundingBoxMin),
            BoundingBoxMax = V3(n.BoundingBoxMax),
            Flags = (int)n.Flags,
        }).ToList();

        dump.GlobalBufferLayouts = flv.BufferLayouts.Select((bl, i) => new BufferLayoutJson
        {
            Index = i,
            Members = bl.Select(m => new LayoutMemberJson
            {
                Type = m.Type.ToString(),
                Semantic = m.Semantic.ToString(),
                Index = m.Index,
                SpecialModifier = m.SpecialModifier,
            }).ToList()
        }).ToList();

        dump.GXLists2 = flv.GXLists.Select((gxl, i) => new GXListJson
        {
            Index = i,
            TerminatorID = gxl.TerminatorID,
            TerminatorLength = gxl.TerminatorLength,
            Items = gxl.Select(item => new GXItemJson
            {
                ID = item.ID ?? "0",
                Unk04 = item.Unk04,
                Data = item.Data ?? Array.Empty<byte>()
            }).ToList()
        }).ToList();

        dump.Materials2 = flv.Materials.Select((m, i) => new Flver2MaterialJson
        {
            Index = i,
            Name = m.Name ?? "",
            MTD = m.MTD ?? "",
            GXIndex = m.GXIndex,
            MaterialIndex = m.Index,
            Textures = m.Textures.Select(t => new Flver2TextureJson
            {
                ParamName = (t.ParamName ?? "").Trim(),
                Path = (t.Path ?? "").Trim(),

                // Keep what the file has; if it's somehow zeroed, keep it.
                TilingScale = V2(t.TilingScale),

                TilingTypeU = (byte)t.TilingTypeU,
                TilingTypeV = (byte)t.TilingTypeV,
                Unk14 = t.Unk14,
                Unk18 = t.Unk18,
                Unk1C = t.Unk1C
            }).ToList()
        }).ToList();

        dump.Meshes2 = flv.Meshes.Select((m, mi) =>
        {
            return new Flver2MeshJson
            {
                Index = mi,
                UseBoneWeights = m.UseBoneWeights,
                MaterialIndex = m.MaterialIndex,
                NodeIndex = m.NodeIndex,
                BoneIndices = m.BoneIndices.ToList(),
                FaceSets = m.FaceSets.Select(fs => new FaceSetJson
                {
                    Flags = (uint)fs.Flags,
                    TriangleStrip = fs.TriangleStrip,
                    CullBackfaces = fs.CullBackfaces,
                    Unk06 = fs.Unk06,
                    Indices = fs.Indices.ToList(),
                }).ToList(),
                VertexBuffers = m.VertexBuffers.Select(vb =>
                {
                    bool edge = vb.EdgeCompressed;

                    int vertexSize = GetIntField(vb, "VertexSize");
                    int vertexCount = GetIntField(vb, "VertexCount");
                    int bufferOffset = GetIntField(vb, "BufferOffset");

                    int raw = edge ? (vb.BufferIndex | 0x6000_0000) : vb.BufferIndex;

                    return new VertexBufferJson
                    {
                        EdgeCompressed = edge,
                        BufferIndex = vb.BufferIndex,
                        BufferIndexRaw = raw,
                        LayoutIndex = vb.LayoutIndex,
                        VertexSize = vertexSize,
                        VertexCount = vertexCount,
                        BufferOffset = bufferOffset
                    };
                }).ToList(),
                Vertices = m.Vertices.Select(ExportVertex).ToList(),
                BoundingBox = m.BoundingBox == null ? null : new BoundingBoxJson
                {
                    Min = V3(m.BoundingBox.Min),
                    Max = V3(m.BoundingBox.Max),
                    Unk = (flv.Header.Version >= 0x2001A) ? V3(m.BoundingBox.Unk) : null
                }
            };
        }).ToList();

        return dump;
    }

    private static FlverDump ExportFLVER0(FLVER0 flv)
    {
        var dump = new FlverDump
        {
            FlverKind = "FLVER0",
            Version = flv.Header.Version,
            BigEndian = flv.Header.BigEndian,
            Unicode = flv.Header.Unicode,
            Header = new HeaderJson
            {
                BoundingBoxMin = V3(flv.Header.BoundingBoxMin),
                BoundingBoxMax = V3(flv.Header.BoundingBoxMax),
                VertexIndexSize = flv.Header.VertexIndexSize,
                Unk4A0 = flv.Header.Unk4A,
                Unk4B0 = flv.Header.Unk4B,
                Unk4C0 = flv.Header.Unk4C,
                Unk5C0 = flv.Header.Unk5C,
            }
        };

        dump.Dummies = flv.Dummies.Select((d, i) => new DummyJson
        {
            Index = i,
            Position = V3(d.Position),
            Forward = V3(d.Forward),
            Upward = V3(d.Upward),
            ReferenceID = d.ReferenceID,
            ParentBoneIndex = d.ParentBoneIndex,
            AttachBoneIndex = d.AttachBoneIndex,

            ColorRGBA = new[] { d.Color.R, d.Color.G, d.Color.B, d.Color.A },
            Flag1 = d.Flag1,
            UseUpwardVector = d.UseUpwardVector,
            Unk30 = d.Unk30,
            Unk34 = d.Unk34,
        }).ToList();

        dump.Nodes = flv.Nodes.Select((n, i) => new NodeJson
        {
            Index = i,
            Name = n.Name,

            ParentIndex = n.ParentIndex,
            FirstChildIndex = n.FirstChildIndex,
            NextSiblingIndex = n.NextSiblingIndex,
            PreviousSiblingIndex = n.PreviousSiblingIndex,

            Translation = V3(n.Translation),
            Rotation = V3(n.Rotation),
            Scale = V3(n.Scale),

            BoundingBoxMin = V3(n.BoundingBoxMin),
            BoundingBoxMax = V3(n.BoundingBoxMax),
            Flags = (int)n.Flags,
        }).ToList();

        dump.Materials0 = flv.Materials.Select((m, i) => new Flver0MaterialJson
        {
            Index = i,
            Name = m.Name ?? "",
            MTD = m.MTD ?? "",
            Textures = m.Textures.Select(t => new Flver0TextureJson
            {
                ParamName = t.ParamName,
                Path = t.Path ?? ""
            }).ToList(),
            Layouts = m.Layouts.Select(l => new Flver0BufferLayoutJson
            {
                Members = l.Select(mem => new LayoutMemberJson
                {
                    Type = mem.Type.ToString(),
                    Semantic = mem.Semantic.ToString(),
                    Index = mem.Index,
                    SpecialModifier = mem.SpecialModifier,
                }).ToList(),
                Size = l.Size
            }).ToList()
        }).ToList();

        dump.Meshes0 = flv.Meshes.Select((m, i) => new Flver0MeshJson
        {
            Index = i,
            Dynamic = m.Dynamic,
            MaterialIndex = m.MaterialIndex,
            CullBackfaces = m.CullBackfaces,
            TriangleStrip = m.TriangleStrip,
            NodeIndex = m.NodeIndex,
            BoneIndices = m.BoneIndices.ToArray(),
            LayoutIndex = m.LayoutIndex,
            Indices = m.Indices.ToList(),
            Vertices = m.Vertices.Select(ExportVertex).ToList()
        }).ToList();

        return dump;
    }

    private static VertexJson ExportVertex(FLVER.Vertex v)
    {
        var j = new VertexJson
        {
            Position = V3(v.Position),
            Normal = V3(v.Normal),
            NormalW = v.NormalW,
            BoneIndices = new[] { v.BoneIndices[0], v.BoneIndices[1], v.BoneIndices[2], v.BoneIndices[3] },
            BoneWeights = new[] { v.BoneWeights[0], v.BoneWeights[1], v.BoneWeights[2], v.BoneWeights[3] },
        };

        // UVs are Vector3 in SoulsFormats -> export XYZ (back-compat: importer accepts float[2] too)
        if (v.UVs != null)
        {
            foreach (var uv in v.UVs)
                j.UVs.Add(new[] { uv.X, uv.Y, uv.Z });
        }

        if (v.Tangents != null)
        {
            foreach (var t in v.Tangents)
                j.Tangents.Add(new[] { t.X, t.Y, t.Z, t.W });
        }

        if (v.Colors != null)
        {
            foreach (var c in v.Colors)
            {
                // c.R/c.G/c.B/c.A could be floats or bytes depending on SoulsFormats implementation;
                // treat them as floats, then normalize.
                j.VertexColors.Add(ReadVertexColorRGBA(c));
            }
        }

        return j;
    }

    // ---------------------------
    // Importers
    // ---------------------------

    private static FLVER2 ImportFLVER2(FlverDump dump)
    {
        var flv = new FLVER2();
        flv.Header.BigEndian = dump.BigEndian;
        flv.Header.Version = dump.Version;
        flv.Header.Unicode = dump.Unicode;

        flv.Header.BoundingBoxMin = V3(dump.Header.BoundingBoxMin);
        flv.Header.BoundingBoxMax = V3(dump.Header.BoundingBoxMax);
        flv.Header.Unk4A = dump.Header.Unk4A ?? flv.Header.Unk4A;
        flv.Header.Unk4B = dump.Header.Unk4B ?? flv.Header.Unk4B;
        flv.Header.Unk4C = dump.Header.Unk4C ?? flv.Header.Unk4C;
        flv.Header.Unk5C = dump.Header.Unk5C ?? flv.Header.Unk5C;
        flv.Header.Unk5D = dump.Header.Unk5D ?? flv.Header.Unk5D;
        flv.Header.Unk68 = dump.Header.Unk68 ?? flv.Header.Unk68;
        flv.Header.SpecialModifier = dump.Header.SpecialModifier ?? flv.Header.SpecialModifier;
        flv.Header.Unk74 = dump.Header.Unk74 ?? flv.Header.Unk74;

        flv.Dummies = dump.Dummies.Select(dj =>
        {
            var d = new FLVER.Dummy();
            d.Position = V3(dj.Position);
            d.Forward = V3(dj.Forward);
            d.Upward = V3(dj.Upward);

            // NOTE: your pasted FLVER.Dummy earlier in the thread suggested ReferenceID is int.
            // Your current tool casted to short; keep as int and only cast if your local SoulsFormatsNEXT truly uses short.
            if (dj.ReferenceID.HasValue)
                d.ReferenceID = checked((short)dj.ReferenceID.Value);

            if (dj.ParentBoneIndex.HasValue) d.ParentBoneIndex = checked((short)dj.ParentBoneIndex.Value);
            if (dj.AttachBoneIndex.HasValue) d.AttachBoneIndex = checked((short)dj.AttachBoneIndex.Value);

            if (dj.ColorRGBA != null)
            {
                if (dj.ColorRGBA.Length != 4)
                    throw new SchemaException("Dummy.ColorRGBA must be byte[4] as [R,G,B,A].");

                d.Color = System.Drawing.Color.FromArgb(
                    dj.ColorRGBA[3], // A
                    dj.ColorRGBA[0], // R
                    dj.ColorRGBA[1], // G
                    dj.ColorRGBA[2]  // B
                );
            }

            if (dj.Flag1.HasValue) d.Flag1 = dj.Flag1.Value;
            if (dj.UseUpwardVector.HasValue) d.UseUpwardVector = dj.UseUpwardVector.Value;
            if (dj.Unk30.HasValue) d.Unk30 = dj.Unk30.Value;
            if (dj.Unk34.HasValue) d.Unk34 = dj.Unk34.Value;

            return d;
        }).ToList();

        flv.Nodes = dump.Nodes.OrderBy(n => n.Index).Select(nj =>
        {
            var n = new FLVER.Node();
            n.Name = nj.Name ?? "";

            n.ParentIndex = checked((short)nj.ParentIndex);
            n.FirstChildIndex = checked((short)nj.FirstChildIndex);
            n.NextSiblingIndex = checked((short)nj.NextSiblingIndex);
            n.PreviousSiblingIndex = checked((short)nj.PreviousSiblingIndex);

            n.Translation = V3(nj.Translation);
            n.Rotation = V3(nj.Rotation);
            n.Scale = V3(nj.Scale);

            n.BoundingBoxMin = V3(nj.BoundingBoxMin);
            n.BoundingBoxMax = V3(nj.BoundingBoxMax);
            n.Flags = (FLVER.Node.NodeFlags)nj.Flags;

            return n;
        }).ToList();

        flv.BufferLayouts = dump.GlobalBufferLayouts
            .OrderBy(b => b.Index)
            .Select(blj =>
            {
                var bl = new FLVER2.BufferLayout();
                foreach (var mj in blj.Members)
                {
                    var type = Enum.Parse<FLVER.LayoutType>(mj.Type, ignoreCase: true);
                    var sem = Enum.Parse<FLVER.LayoutSemantic>(mj.Semantic, ignoreCase: true);
                    bl.Add(new FLVER.LayoutMember(type, sem, mj.Index, mj.SpecialModifier));
                }
                return bl;
            }).ToList();

        flv.GXLists = dump.GXLists2
            .OrderBy(x => x.Index)
            .Select(gxj =>
            {
                var gxl = new FLVER2.GXList
                {
                    TerminatorID = gxj.TerminatorID,
                    TerminatorLength = gxj.TerminatorLength
                };
                foreach (var it in gxj.Items)
                    gxl.Add(new FLVER2.GXItem(it.ID, it.Unk04, it.Data ?? Array.Empty<byte>()));
                return gxl;
            })
            .ToList();

        // ---- Materials (preserve exact index mapping) ----
        if (dump.Materials2 == null) dump.Materials2 = new List<Flver2MaterialJson>();

        int matCount = dump.Materials2.Count == 0 ? 0 : (dump.Materials2.Max(m => m.Index) + 1);
        var mats = new FLVER2.Material[matCount];

        foreach (var mj in dump.Materials2)
        {
            if (mj.Index < 0 || mj.Index >= matCount)
                throw new SchemaException($"Material.Index out of range: {mj.Index} (matCount={matCount}).");

            var m = new FLVER2.Material
            {
                Name = mj.Name ?? "",
                MTD = mj.MTD ?? "",
                GXIndex = mj.GXIndex,
                Index = mj.MaterialIndex
            };

            m.Textures = (mj.Textures ?? new List<Flver2TextureJson>()).Select(tj => new FLVER2.Texture
            {
                ParamName = tj.ParamName ?? "",
                Path = tj.Path ?? "",
                TilingScale = V2_OneDefault(tj.TilingScale),
                TilingTypeU = (FLVER2.Texture.TilingType)tj.TilingTypeU,
                TilingTypeV = (FLVER2.Texture.TilingType)tj.TilingTypeV,
                Unk14 = tj.Unk14,
                Unk18 = tj.Unk18,
                Unk1C = tj.Unk1C
            }).ToList();

            mats[mj.Index] = m;
        }

        // Safety: no gaps
        for (int i = 0; i < mats.Length; i++)
            if (mats[i] == null)
                throw new SchemaException($"Materials2 is missing material at index {i}.");

        flv.Materials = mats.ToList();

        // ---- Meshes (preserve exact index mapping) ----
        if (dump.Meshes2 == null) dump.Meshes2 = new List<Flver2MeshJson>();

        int meshCount = dump.Meshes2.Count == 0 ? 0 : (dump.Meshes2.Max(m => m.Index) + 1);
        var meshes = new FLVER2.Mesh[meshCount];

        foreach (var mj in dump.Meshes2)
        {
            if (mj.Index < 0 || mj.Index >= meshCount)
                throw new SchemaException($"Mesh.Index out of range: {mj.Index} (meshCount={meshCount}).");

            var mesh = new FLVER2.Mesh
            {
                UseBoneWeights = mj.UseBoneWeights,
                MaterialIndex = mj.MaterialIndex,
                NodeIndex = checked((short)mj.NodeIndex),
                BoneIndices = mj.BoneIndices.ToList(),
            };

            mesh.FaceSets = mj.FaceSets.Select(fs => new FLVER2.FaceSet
            {
                Flags = (FLVER2.FaceSet.FSFlags)fs.Flags,
                TriangleStrip = fs.TriangleStrip,
                CullBackfaces = fs.CullBackfaces,
                Unk06 = fs.Unk06,
                Indices = fs.Indices.ToList()
            }).ToList();

            // Preserve original order from dump (critical!)
            var vbsInOrder = mj.VertexBuffers.ToList();

            mesh.VertexBuffers = vbsInOrder.Select(vbj =>
            {
                var vb = new FLVER2.VertexBuffer(vbj.LayoutIndex)
                {
                    EdgeCompressed = vbj.EdgeCompressed,
                    BufferIndex = vbj.BufferIndex,
                    LayoutIndex = vbj.LayoutIndex,
                };
                return vb;
            }).ToList();

            (int uvSlots, int tanSlots, int colSlots) = ComputeMeshSlots(dump, vbsInOrder);

            mesh.Vertices = mj.Vertices
                .Select(vj => ImportVertex(vj, uvSlots, tanSlots, colSlots))
                .ToList();

            static void DebugVertexAlpha(string label, List<FLVER.Vertex> verts)
            {
                if (verts.Count == 0) return;
                float minA = 999f, maxA = -999f;

                foreach (var v in verts)
                {
                    if (v.Colors == null || v.Colors.Count == 0) continue;

                    // Try to read A as float-ish; this works for most forks.
                    // If it prints only 0/1, you're losing precision.
                    var c0 = v.Colors[0];
                    float a = 0f;

                    var aField = c0.GetType().GetField("A");
                    if (aField != null)
                    {
                        var av = aField.GetValue(c0);
                        a = av is byte ab ? ab / 255f : Convert.ToSingle(av);
                    }

                    if (a < minA) minA = a;
                    if (a > maxA) maxA = a;
                }

                Console.WriteLine($"[DBG] {label} Color0 alpha range: {minA:0.###}..{maxA:0.###}");
            }
            DebugVertexAlpha($"mesh {mj.Index}", mesh.Vertices);

            if (mj.BoundingBox != null)
            {
                mesh.BoundingBox = new FLVER2.Mesh.BoundingBoxes
                {
                    Min = V3(mj.BoundingBox.Min),
                    Max = V3(mj.BoundingBox.Max),
                };
                if (mj.BoundingBox.Unk != null)
                    mesh.BoundingBox.Unk = V3(mj.BoundingBox.Unk);
            }

            meshes[mj.Index] = mesh;
        }

        // Safety: no gaps
        for (int i = 0; i < meshes.Length; i++)
            if (meshes[i] == null)
                throw new SchemaException($"Meshes2 is missing mesh at index {i}.");

        flv.Meshes = meshes.ToList();

        flv.Skeletons = dump.Version >= 0x2001A ? new FLVER2.SkeletonSet() : null;
        return flv;
    }

    private static FLVER0 ImportFLVER0(FlverDump dump)
    {
        var flv = new FLVER0();
        flv.Header.BigEndian = dump.BigEndian;
        flv.Header.Version = dump.Version;
        flv.Header.Unicode = dump.Unicode;

        flv.Header.BoundingBoxMin = V3(dump.Header.BoundingBoxMin);
        flv.Header.BoundingBoxMax = V3(dump.Header.BoundingBoxMax);
        if (dump.Header.VertexIndexSize.HasValue) flv.Header.VertexIndexSize = dump.Header.VertexIndexSize.Value;
        if (dump.Header.Unk4A0.HasValue) flv.Header.Unk4A = dump.Header.Unk4A0.Value;
        if (dump.Header.Unk4B0.HasValue) flv.Header.Unk4B = dump.Header.Unk4B0.Value;
        if (dump.Header.Unk4C0.HasValue) flv.Header.Unk4C = dump.Header.Unk4C0.Value;
        if (dump.Header.Unk5C0.HasValue) flv.Header.Unk5C = dump.Header.Unk5C0.Value;

        flv.Dummies = dump.Dummies.Select(dj =>
        {
            var d = new FLVER.Dummy();
            d.Position = V3(dj.Position);
            d.Forward = V3(dj.Forward);
            d.Upward = V3(dj.Upward);

            if (dj.ReferenceID.HasValue)
                d.ReferenceID = checked((short)dj.ReferenceID.Value);

            if (dj.ParentBoneIndex.HasValue) d.ParentBoneIndex = checked((short)dj.ParentBoneIndex.Value);
            if (dj.AttachBoneIndex.HasValue) d.AttachBoneIndex = checked((short)dj.AttachBoneIndex.Value);

            if (dj.ColorRGBA != null)
            {
                if (dj.ColorRGBA.Length != 4)
                    throw new SchemaException("Dummy.ColorRGBA must be byte[4] as [R,G,B,A].");

                d.Color = System.Drawing.Color.FromArgb(
                    dj.ColorRGBA[3], // A
                    dj.ColorRGBA[0], // R
                    dj.ColorRGBA[1], // G
                    dj.ColorRGBA[2]  // B
                );
            }

            if (dj.Flag1.HasValue) d.Flag1 = dj.Flag1.Value;
            if (dj.UseUpwardVector.HasValue) d.UseUpwardVector = dj.UseUpwardVector.Value;
            if (dj.Unk30.HasValue) d.Unk30 = dj.Unk30.Value;
            if (dj.Unk34.HasValue) d.Unk34 = dj.Unk34.Value;

            return d;
        }).ToList();

        flv.Nodes = dump.Nodes.OrderBy(n => n.Index).Select(nj =>
        {
            var n = new FLVER.Node();
            n.Name = nj.Name ?? "";

            n.ParentIndex = checked((short)nj.ParentIndex);
            n.FirstChildIndex = checked((short)nj.FirstChildIndex);
            n.NextSiblingIndex = checked((short)nj.NextSiblingIndex);
            n.PreviousSiblingIndex = checked((short)nj.PreviousSiblingIndex);

            n.Translation = V3(nj.Translation);
            n.Rotation = V3(nj.Rotation);
            n.Scale = V3(nj.Scale);

            n.BoundingBoxMin = V3(nj.BoundingBoxMin);
            n.BoundingBoxMax = V3(nj.BoundingBoxMax);
            n.Flags = (FLVER.Node.NodeFlags)nj.Flags;

            return n;
        }).ToList();

        flv.Materials = dump.Materials0.OrderBy(m => m.Index).Select(mj =>
        {
            var m = new FLVER0.Material
            {
                Name = mj.Name ?? "",
                MTD = mj.MTD ?? "",
            };
            m.Textures = mj.Textures.Select(tj => new FLVER0.Texture(tj.ParamName ?? "", tj.Path ?? "")).ToList();
            m.Layouts = mj.Layouts.Select(lj =>
            {
                var layout = new FLVER0.BufferLayout();
                foreach (var memj in lj.Members)
                {
                    var type = Enum.Parse<FLVER.LayoutType>(memj.Type, ignoreCase: true);
                    var sem = Enum.Parse<FLVER.LayoutSemantic>(memj.Semantic, ignoreCase: true);
                    layout.Add(new FLVER.LayoutMember(type, sem, memj.Index, memj.SpecialModifier));
                }
                return layout;
            }).ToList();
            return m;
        }).ToList();

        flv.Meshes = dump.Meshes0.OrderBy(m => m.Index).Select(mj =>
        {
            var mesh = new FLVER0.Mesh
            {
                Dynamic = mj.Dynamic,
                MaterialIndex = mj.MaterialIndex,
                CullBackfaces = mj.CullBackfaces,
                TriangleStrip = mj.TriangleStrip,
                NodeIndex = mj.NodeIndex,
                LayoutIndex = checked((short)mj.LayoutIndex),
                Indices = mj.Indices.ToList(),
                Vertices = new List<FLVER.Vertex>(mj.Vertices.Count)
            };

            // NOTE: FLVER0 layouts are per-material. UV slots are type-dependent too,
            // but FLVER0 BB usage usually aligns. Keep original cap logic to minimize breakage.
            var layout = flv.Materials[mesh.MaterialIndex].Layouts[mesh.LayoutIndex];
            int uvCap0 = layout.Count(m => m.Semantic == FLVER.LayoutSemantic.UV);
            int tanCap0 = layout.Count(m => m.Semantic == FLVER.LayoutSemantic.Tangent);
            int colCap0 = layout.Count(m => m.Semantic == FLVER.LayoutSemantic.VertexColor);

            foreach (VertexJson vj0 in mj.Vertices)
                mesh.Vertices.Add(ImportVertex(vj0, uvCap0, tanCap0, colCap0));

            for (int i = 0; i < mesh.BoneIndices.Length && i < mj.BoneIndices.Length; i++)
                mesh.BoneIndices[i] = mj.BoneIndices[i];

            return mesh;
        }).ToList();

        return flv;
    }

    private static FLVER.Vertex ImportVertex(VertexJson vj, int uvCap, int tanCap, int colCap)
    {
        var v = new FLVER.Vertex(uvCap, tanCap, colCap);

        v.Position = V3(vj.Position);
        v.Normal = V3(vj.Normal);
        v.NormalW = vj.NormalW;

        // UVs: allow float[2] or float[3]; allow fewer than cap, pad
        v.UVs.Clear();
        int uvCount = vj.UVs?.Count ?? 0;
        if (uvCount > uvCap)
            throw new SchemaException($"Vertex UV count {uvCount} > expected uvCap {uvCap}.");

        if (vj.UVs != null)
        {
            foreach (var uv in vj.UVs)
            {
                if (uv == null || (uv.Length != 2 && uv.Length != 3))
                    throw new SchemaException("Each UV entry must be float[2] or float[3].");

                float z = (uv.Length == 3) ? uv[2] : 0f;
                v.UVs.Add(new System.Numerics.Vector3(uv[0], uv[1], z));
            }
        }
        for (int i = uvCount; i < uvCap; i++)
            v.UVs.Add(new System.Numerics.Vector3(0f, 0f, 0f));


        

        // Tangents: allow fewer than cap, pad
        v.Tangents.Clear();
        int tanCount = vj.Tangents?.Count ?? 0;
        if (tanCount > tanCap)
            throw new SchemaException($"Vertex Tangents count {tanCount} > expected tanCap {tanCap}.");

        if (vj.Tangents != null)
        {
            foreach (var t in vj.Tangents)
            {
                if (t == null || t.Length != 4)
                    throw new SchemaException("Each Tangents entry must be float[4].");
                v.Tangents.Add(new System.Numerics.Vector4(t[0], t[1], t[2], t[3]));
            }
        }
        for (int i = tanCount; i < tanCap; i++)
            v.Tangents.Add(new System.Numerics.Vector4(0f, 0f, 0f, 0f));

        // Colors: allow fewer than cap, pad (WHITE so blends don't get killed)
        // Colors
        v.Colors.Clear();

        int colN = vj.VertexColors?.Count ?? 0;
        if (colN > colCap)
            throw new SchemaException($"VertexColors count {colN} > expected colCap {colCap}.");

        if (vj.VertexColors != null)
        {
            foreach (var c in vj.VertexColors)
            {
                if (c == null || c.Length != 4)
                    throw new SchemaException("VertexColors entries must be float[4] as [R,G,B,A].");

                var rgba = NormalizeColorRGBA(c[0], c[1], c[2], c[3]);

                // IMPORTANT: use MakeVertexColor here (not outside this block)
                v.Colors.Add(MakeVertexColor(rgba[0], rgba[1], rgba[2], rgba[3]));
            }
        }

        // IMPORTANT: pad with white (1,1,1,1). Padding with 0 can kill blends.
        for (int i = colN; i < colCap; i++)
            v.Colors.Add(MakeVertexColor(1f, 1f, 1f, 1f));

        for (int i = 0; i < 4; i++)
        {
            v.BoneIndices[i] = checked((short)vj.BoneIndices[i]);
            v.BoneWeights[i] = vj.BoneWeights[i];
        }

        return v;
    }

    // ---------------------------
    // Slot counting (layout-driven)
    // ---------------------------

    private static (int uvSlots, int tanSlots, int colSlots) ComputeMeshSlots(FlverDump dump, List<VertexBufferJson> vertexBuffersSorted)
    {
        int uvSlots = 0, tanSlots = 0, colSlots = 0;

        foreach (var vb in vertexBuffersSorted)
        {
            if (vb.LayoutIndex < 0 || vb.LayoutIndex >= dump.GlobalBufferLayouts.Count)
                throw new SchemaException($"VertexBuffer LayoutIndex out of range: {vb.LayoutIndex}");

            var layout = dump.GlobalBufferLayouts[vb.LayoutIndex];

            uvSlots += CountUvSlots(layout.Members);
            tanSlots += CountSemanticSlots(layout.Members, "Tangent");
            colSlots += CountSemanticSlots(layout.Members, "VertexColor");
        }

        return (uvSlots, tanSlots, colSlots);
    }

    private static int CountSemanticSlots(IEnumerable<LayoutMemberJson> members, string semanticName)
    {
        int slots = 0;
        foreach (var m in members)
        {
            if (m.SpecialModifier == -32768) continue; // mimic read-side SpeedTree skip
            if (!m.Semantic.Equals(semanticName, StringComparison.OrdinalIgnoreCase)) continue;
            slots += 1;
        }
        return slots;
    }

    private static int CountUvSlots(IEnumerable<LayoutMemberJson> members)
    {
        int slots = 0;
        foreach (var m in members)
        {
            if (m.SpecialModifier == -32768) continue; // mimic read-side SpeedTree skip
            if (!m.Semantic.Equals("UV", StringComparison.OrdinalIgnoreCase)) continue;

            // UV semantic is special: some layout TYPES consume 2 UV queue entries
            slots += m.Type switch
            {
                "Float4" => 2,
                "UByte4Norm" => 2,
                "Short4" => 2,
                "Half4" => 2,
                _ => 1
            };
        }
        return slots;
    }

    // ---------------------------
    // Validator
    // ---------------------------

    private static class SchemaValidator
    {
        public static void ValidateOrThrow(FlverDump dump)
        {
            if (string.IsNullOrWhiteSpace(dump.SchemaVersion))
                throw new SchemaException("Missing SchemaVersion.");

            if (dump.FlverKind != "FLVER2" && dump.FlverKind != "FLVER0")
                throw new SchemaException($"Unsupported FlverKind '{dump.FlverKind}'.");

            foreach (var n in dump.Nodes)
            {
                Require(n.BoundingBoxMin?.Length == 3, "Node.BoundingBoxMin must be float[3].");
                Require(n.BoundingBoxMax?.Length == 3, "Node.BoundingBoxMax must be float[3].");
            }

            foreach (var d in dump.Dummies)
            {
                if (d.ColorRGBA != null)
                    Require(d.ColorRGBA.Length == 4, "Dummy.ColorRGBA must be byte[4] [R,G,B,A].");
            }

            // Validate UV entries are float[2] or float[3]
            foreach (var mesh in dump.Meshes2)
            {
                foreach (var v in mesh.Vertices)
                {
                    foreach (var uv in v.UVs)
                        Require(uv != null && (uv.Length == 2 || uv.Length == 3), "UV entries must be float[2] or float[3].");
                }
            }

            if (dump.FlverKind == "FLVER2")
                ValidateFlver2(dump);
            else
                ValidateFlver0(dump);
        }

        private static void ValidateFlver2(FlverDump dump)
        {
            var layouts = dump.GlobalBufferLayouts.OrderBy(b => b.Index).ToList();
            for (int i = 0; i < layouts.Count; i++)
                Require(layouts[i].Index == i, $"GlobalBufferLayouts must be 0..N-1. Missing/out-of-order at {i}.");

            foreach (var mat in dump.Materials2)
            {
                if (mat.GXIndex != -1)
                    Require(mat.GXIndex >= 0 && mat.GXIndex < dump.GXLists2.Count,
                        $"material[{mat.Index}] GXIndex out of range: {mat.GXIndex} (GXLists2.Count={dump.GXLists2.Count}).");
            }

            foreach (var mesh in dump.Meshes2)
            {
                Require(mesh.MaterialIndex >= 0 && mesh.MaterialIndex < dump.Materials2.Count,
                    $"mesh[{mesh.Index}] MaterialIndex out of range: {mesh.MaterialIndex}");

                foreach (var vb in mesh.VertexBuffers)
                {
                    Require(vb.LayoutIndex >= 0 && vb.LayoutIndex < dump.GlobalBufferLayouts.Count,
                        $"mesh[{mesh.Index}] vertexBuffer LayoutIndex out of range: {vb.LayoutIndex}");

                    int expectedSize = ComputeLayoutSize(dump.GlobalBufferLayouts[vb.LayoutIndex]);
                    Require(vb.VertexSize == expectedSize,
                        $"mesh[{mesh.Index}] VertexSize {vb.VertexSize} != expected layout size {expectedSize} (layout {vb.LayoutIndex}).");

                    Require(vb.VertexCount == mesh.Vertices.Count,
                        $"mesh[{mesh.Index}] VertexCount {vb.VertexCount} != mesh.Vertices.Count {mesh.Vertices.Count}.");

                    int expectedRaw = vb.EdgeCompressed ? (vb.BufferIndex | 0x6000_0000) : vb.BufferIndex;
                    Require(vb.BufferIndexRaw == expectedRaw,
                        $"mesh[{mesh.Index}] BufferIndexRaw {vb.BufferIndexRaw:X8} inconsistent with EdgeCompressed={vb.EdgeCompressed} BufferIndex={vb.BufferIndex}.");
                }

                foreach (var v in mesh.Vertices)
                {
                    foreach (var c in v.VertexColors)
                        Require(c != null && c.Length == 4, "VertexColors entries must be float[4] as [R,G,B,A].");

                    foreach (var t in v.Tangents)
                        Require(t != null && t.Length == 4, "Tangents entries must be float[4].");
                }
            }

            foreach (var mat in dump.Materials2)
            {
                Require(!string.IsNullOrWhiteSpace(mat.Name), $"material[{mat.Index}] Name is empty.");
                // Empty MTD is valid for some placeholder/null materials.
                // Preserve it as an intentional empty string on rebuild instead of rejecting the JSON.
                if (mat.MTD == null)
                    mat.MTD = "";

                foreach (var tx in mat.Textures)
                {
                    Require(!string.IsNullOrWhiteSpace(tx.ParamName), $"material[{mat.Index}] has texture with empty ParamName.");
                    Require(!string.IsNullOrWhiteSpace(tx.Path), $"material[{mat.Index}] has texture '{tx.ParamName}' with empty Path.");

                    Require(tx.TilingScale != null && tx.TilingScale.Length == 2,
                        $"material[{mat.Index}] texture '{tx.ParamName}' TilingScale must be float[2].");
                }
            }
        }

        private static void ValidateFlver0(FlverDump dump)
        {
            foreach (var mesh in dump.Meshes0)
            {
                Require(mesh.MaterialIndex >= 0 && mesh.MaterialIndex < dump.Materials0.Count,
                    $"mesh[{mesh.Index}] MaterialIndex out of range: {mesh.MaterialIndex}");
            }
        }

        private static int ComputeLayoutSize(BufferLayoutJson layout)
        {
            int size = 0;
            foreach (var m in layout.Members)
            {
                if (m.SpecialModifier == -32768) continue;
                size += LayoutTypeSize(m.Type);
            }
            return size;
        }

        private static int LayoutTypeSize(string layoutTypeName)
        {
            return layoutTypeName switch
            {
                "Float2" => 8,
                "Float3" => 12,
                "Float4" => 16,

                "Byte4" => 4,
                "Byte4Norm" => 4,
                "SByte4" => 4,
                "SByte4Norm" => 4,

                "UByte4" => 4,
                "UByte4Norm" => 4,

                "Short2" => 4,
                "Short2Norm" => 4,
                "UShort2" => 4,
                "UShort2Norm" => 4,

                "Short4" => 8,
                "Short4Norm" => 8,
                "UShort4" => 8,
                "UShort4Norm" => 8,

                "Half2" => 4,
                "Half4" => 8,

                "EdgeCompressed" => 0,

                _ => throw new SchemaException($"Unknown LayoutType size mapping for '{layoutTypeName}'. Add it in LayoutTypeSize().")
            };
        }

        private static void Require(bool ok, string message)
        {
            if (!ok) throw new SchemaException(message);
        }
    }

    private sealed class SchemaException : Exception
    {
        public SchemaException(string message) : base(message) { }
    }

    // ---------------------------
    // Reflection helpers (VertexBuffer internal fields)
    // ---------------------------

    private static int GetIntField(object obj, string fieldName)
    {
        var t = obj.GetType();
        var f = t.GetField(fieldName, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        if (f == null)
            throw new Exception($"Missing field '{fieldName}' on type '{t.FullName}'.");
        return (int)f.GetValue(obj)!;
    }

    // ---------------------------
    // JSON options
    // ---------------------------

    private static JsonSerializerOptions JsonOptions()
    {
        return new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
            Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
        };
    }
    // ---------------------------
    // Color helpers (for correct BB blending)
    // ---------------------------

    private static float Clamp01(float x)
    {
        if (x < 0f) return 0f;
        if (x > 1f) return 1f;
        return x;
    }

    // If values look like 0..255, normalize to 0..1
    private static float NormalizeColorComponent(float x)
    {
        // Heuristic: anything > 1.5 is almost certainly byte-space
        if (x > 1.5f) return x / 255f;
        return x;
    }

    private static float[] NormalizeColorRGBA(float r, float g, float b, float a)
    {
        r = NormalizeColorComponent(r);
        g = NormalizeColorComponent(g);
        b = NormalizeColorComponent(b);
        a = NormalizeColorComponent(a);

        return new[] { Clamp01(r), Clamp01(g), Clamp01(b), Clamp01(a) };
    }
    // ---------------------------
    // Vector helpers
    // ---------------------------

    private static float[] V3(System.Numerics.Vector3 v) => new[] { v.X, v.Y, v.Z };
    private static float[] V2(System.Numerics.Vector2 v) => new[] { v.X, v.Y };
    private static System.Numerics.Vector3 V3(float[] a) => new System.Numerics.Vector3(a[0], a[1], a[2]);
    private static System.Numerics.Vector2 V2_OneDefault(float[]? a)
    {
        if (a == null || a.Length != 2)
            return System.Numerics.Vector2.One;

        return new System.Numerics.Vector2(a[0], a[1]);
    }
}