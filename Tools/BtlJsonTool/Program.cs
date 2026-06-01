// BB Reborne DIY Tool
// Copyright (C) 2026 Greg Pitta
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// See the LICENSE file for details.



using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Text.Json;
using System.Text.Json.Serialization;
using SoulsFormats;

#nullable enable

internal static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1) return Usage("Missing command.");
            string cmd = args[0].ToLowerInvariant();

            switch (cmd)
            {
                case "dump":
                    if (args.Length != 3) return Usage("dump requires: <input.btl> <output.json>");
                    Dump(args[1], args[2]);
                    return 0;

                case "rebuild":
                    if (args.Length != 3) return Usage("rebuild requires: <input.json> <output.btl>");
                    Rebuild(args[1], args[2]);
                    return 0;

                case "verify":
                    if (args.Length != 4) return Usage("verify requires: <input.btl> <temp.json> <rebuilt.btl>");
                    Verify(args[1], args[2], args[3]);
                    return 0;

                default:
                    return Usage($"Unknown command: {cmd}");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static int Usage(string? err = null)
    {
        if (!string.IsNullOrWhiteSpace(err))
            Console.Error.WriteLine("ERROR: " + err);

        Console.Error.WriteLine(
@"BtlJsonTool (BTL <-> JSON)

Commands:
  dump    <input.btl>  <output.json>
  rebuild <input.json> <output.btl>
  verify  <input.btl>  <temp.json> <rebuilt.btl>
");
        return 2;
    }

    private static readonly JsonSerializerOptions JsonOpts = CreateJsonOptions();

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var o = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            AllowTrailingCommas = true,
            ReadCommentHandling = JsonCommentHandling.Skip
        };
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        o.Converters.Add(new Vector3Converter());
        o.Converters.Add(new Rgba8Converter());
        o.Converters.Add(new ByteArrayNumberConverter()); // <-- single converter for all byte[]
        return o;
    }

    private static void Dump(string btlPath, string jsonPath)
    {
        BTL btl = BTL.Read(btlPath);
        var doc = BtlJson.FromBtl(btl);
        doc.ValidateOrThrow();

        File.WriteAllText(jsonPath, JsonSerializer.Serialize(doc, JsonOpts));
        Console.WriteLine($"Dumped: {btlPath}");
        Console.WriteLine($"   To: {jsonPath}");
    }

    private static void Rebuild(string jsonPath, string btlOutPath)
    {
        var doc = JsonSerializer.Deserialize<BtlJson>(File.ReadAllText(jsonPath), JsonOpts)
            ?? throw new InvalidDataException("Failed to deserialize JSON.");

        doc.ValidateOrThrow();

        var btl = doc.ToBtl();
        btl.Write(btlOutPath);

        Console.WriteLine($"Rebuilt: {jsonPath}");
        Console.WriteLine($"     To: {btlOutPath}");
    }

    private static void Verify(string btlPath, string tempJsonPath, string rebuiltBtlPath)
    {
        var original = BTL.Read(btlPath);

        var dump = BtlJson.FromBtl(original);
        dump.ValidateOrThrow();
        File.WriteAllText(tempJsonPath, JsonSerializer.Serialize(dump, JsonOpts));

        var rebuilt = dump.ToBtl();
        rebuilt.Write(rebuiltBtlPath);

        var reread = BTL.Read(rebuiltBtlPath);

        Console.WriteLine("VERIFY OK:");
        Console.WriteLine($"  Input:   {btlPath}");
        Console.WriteLine($"  Dump:    {tempJsonPath}");
        Console.WriteLine($"  Rebuilt: {rebuiltBtlPath}");
        Console.WriteLine($"  Reread:  success (Version={reread.Version}, LongOffsets={reread.LongOffsets}, Lights={reread.Lights.Count})");
    }
}

#region JSON schema

public sealed class BtlJson
{
    public string Schema { get; set; } = "btl-json-v1";

    public int Version { get; set; } = 16;
    public bool LongOffsets { get; set; } = true;

    public List<BtlLightJson> Lights { get; set; } = new();

    public static BtlJson FromBtl(BTL b) => new()
    {
        Version = b.Version,
        LongOffsets = b.LongOffsets,
        Lights = b.Lights.Select(l => BtlLightJson.From(l, b.Version)).ToList()
    };

    public BTL ToBtl()
    {
        ValidateOrThrow();

        var b = new BTL
        {
            Version = Version,
            LongOffsets = LongOffsets,
            Lights = Lights.Select(l => l.ToLight(Version)).ToList()
        };
        return b;
    }

    public void ValidateOrThrow()
    {
        if (Schema != "btl-json-v1")
            throw new InvalidDataException($"Unsupported schema: {Schema}");

        // SoulsFormats asserts these on read; keep it strict to avoid creating junk.
        if (Version != 1 && Version != 2 && Version != 5 && Version != 6 && Version != 16 && Version != 18)
            throw new InvalidDataException($"Unsupported/unknown BTL Version: {Version} (expected 1,2,5,6,16,18).");

        if (Lights == null)
            throw new InvalidDataException("Lights is null.");

        foreach (var l in Lights)
            l.ValidateOrThrow(Version);
    }
}

public sealed class BtlLightJson
{
    // Fixed blobs
    public byte[] Unk00 { get; set; } = new byte[16];

    public string Name { get; set; } = "";

    public BTL.LightType Type { get; set; } = BTL.LightType.Point;
    public bool Unk1C { get; set; } = true;

    // RGB-only in file; store as RGBA but validate A=255
    public Rgba8 DiffuseColor { get; set; } = new(255, 255, 255, 255);
    public float DiffusePower { get; set; } = 1f;

    public Rgba8 SpecularColor { get; set; } = new(255, 255, 255, 255);
    public bool CastShadows { get; set; }
    public float SpecularPower { get; set; } = 1f;

    public float ConeAngle { get; set; }
    public float Unk30 { get; set; }
    public float Unk34 { get; set; }

    public Vector3 Position { get; set; }
    public Vector3 Rotation { get; set; }

    public int Unk50 { get; set; } = 4;
    public float Unk54 { get; set; }
    public float Radius { get; set; } = 10f;

    public int Unk5C { get; set; } = -1;

    public byte[] Unk64 { get; set; } = new byte[4] { 0, 0, 0, 1 };
    public float Unk68 { get; set; }

    // RGBA in file (alpha is “relative to 100” conceptually, but it’s stored as byte)
    public Rgba8 ShadowColor { get; set; } = new(0, 0, 0, 100);

    public float Unk70 { get; set; }

    public float FlickerIntervalMin { get; set; }
    public float FlickerIntervalMax { get; set; }
    public float FlickerBrightnessMult { get; set; } = 1f;

    public int Unk80 { get; set; } = -1;

    public byte[] Unk84 { get; set; } = new byte[4];

    public float Unk88 { get; set; }
    public float Unk90 { get; set; }
    public float Unk98 { get; set; } = 1f;

    public float NearClip { get; set; } = 1f;

    public byte[] UnkA0 { get; set; } = new byte[4] { 1, 0, 2, 1 };

    public float Sharpness { get; set; } = 1f;
    public float UnkAC { get; set; }

    public float Width { get; set; }
    public float UnkBC { get; set; }

    public byte[] UnkC0 { get; set; } = new byte[4];
    public float UnkC4 { get; set; }

    // Version >= 16 only (Sekiro+)
    public float? UnkC8 { get; set; }
    public float? UnkCC { get; set; }
    public float? UnkD0 { get; set; }
    public float? UnkD4 { get; set; }
    public float? UnkD8 { get; set; }
    public int? UnkDC { get; set; }
    public float? UnkE0 { get; set; }
    public int? UnkE4 { get; set; }

    public static BtlLightJson From(BTL.Light l, int version) => new()
    {
        Unk00 = (byte[])l.Unk00.Clone(),
        Name = l.Name ?? "",
        Type = l.Type,
        Unk1C = l.Unk1C,

        DiffuseColor = Rgba8.FromColorRgb(l.DiffuseColor),
        DiffusePower = l.DiffusePower,

        SpecularColor = Rgba8.FromColorRgb(l.SpecularColor),
        CastShadows = l.CastShadows,
        SpecularPower = l.SpecularPower,

        ConeAngle = l.ConeAngle,
        Unk30 = l.Unk30,
        Unk34 = l.Unk34,

        Position = l.Position,
        Rotation = l.Rotation,

        Unk50 = l.Unk50,
        Unk54 = l.Unk54,
        Radius = l.Radius,

        Unk5C = l.Unk5C,
        Unk64 = (byte[])l.Unk64.Clone(),
        Unk68 = l.Unk68,

        ShadowColor = Rgba8.FromColorRgba(l.ShadowColor),

        Unk70 = l.Unk70,

        FlickerIntervalMin = l.FlickerIntervalMin,
        FlickerIntervalMax = l.FlickerIntervalMax,
        FlickerBrightnessMult = l.FlickerBrightnessMult,

        Unk80 = l.Unk80,
        Unk84 = (byte[])l.Unk84.Clone(),

        Unk88 = l.Unk88,
        Unk90 = l.Unk90,
        Unk98 = l.Unk98,

        NearClip = l.NearClip,
        UnkA0 = (byte[])l.UnkA0.Clone(),

        Sharpness = l.Sharpness,
        UnkAC = l.UnkAC,

        Width = l.Width,
        UnkBC = l.UnkBC,

        UnkC0 = (byte[])l.UnkC0.Clone(),
        UnkC4 = l.UnkC4,

        UnkC8 = version >= 16 ? l.UnkC8 : null,
        UnkCC = version >= 16 ? l.UnkCC : null,
        UnkD0 = version >= 16 ? l.UnkD0 : null,
        UnkD4 = version >= 16 ? l.UnkD4 : null,
        UnkD8 = version >= 16 ? l.UnkD8 : null,
        UnkDC = version >= 16 ? l.UnkDC : null,
        UnkE0 = version >= 16 ? l.UnkE0 : null,
        UnkE4 = version >= 16 ? l.UnkE4 : null,
    };

    public BTL.Light ToLight(int version)
    {
        ValidateOrThrow(version);

        var l = new BTL.Light();

        // Unk00 has private set; assign by mutating the array.
        if (l.Unk00.Length != 16)
            throw new InvalidDataException("Light.Unk00 length is not 16 (unexpected SoulsFormats behavior).");
        for (int i = 0; i < 16; i++) l.Unk00[i] = Unk00[i];

        l.Name = Name ?? "";
        l.Type = Type;
        l.Unk1C = Unk1C;

        // RGB-only fields: force alpha to 255.
        l.DiffuseColor = DiffuseColor.ToColorRgb255();
        l.DiffusePower = DiffusePower;

        l.SpecularColor = SpecularColor.ToColorRgb255();
        l.CastShadows = CastShadows;
        l.SpecularPower = SpecularPower;

        l.ConeAngle = ConeAngle;
        l.Unk30 = Unk30;
        l.Unk34 = Unk34;

        l.Position = Position;
        l.Rotation = Rotation;

        l.Unk50 = Unk50;
        l.Unk54 = Unk54;
        l.Radius = Radius;

        l.Unk5C = Unk5C;

        l.Unk64 = (byte[])Unk64.Clone();
        l.Unk68 = Unk68;

        l.ShadowColor = ShadowColor.ToColorRgba();
        l.Unk70 = Unk70;

        l.FlickerIntervalMin = FlickerIntervalMin;
        l.FlickerIntervalMax = FlickerIntervalMax;
        l.FlickerBrightnessMult = FlickerBrightnessMult;

        l.Unk80 = Unk80;
        l.Unk84 = (byte[])Unk84.Clone();

        l.Unk88 = Unk88;
        l.Unk90 = Unk90;
        l.Unk98 = Unk98;

        l.NearClip = NearClip;
        l.UnkA0 = (byte[])UnkA0.Clone();

        l.Sharpness = Sharpness;
        l.UnkAC = UnkAC;

        l.Width = Width;
        l.UnkBC = UnkBC;

        l.UnkC0 = (byte[])UnkC0.Clone();
        l.UnkC4 = UnkC4;

        if (version >= 16)
        {
            l.UnkC8 = UnkC8 ?? 0f;
            l.UnkCC = UnkCC ?? 0f;
            l.UnkD0 = UnkD0 ?? 0f;
            l.UnkD4 = UnkD4 ?? 0f;
            l.UnkD8 = UnkD8 ?? 0f;
            l.UnkDC = UnkDC ?? 0;
            l.UnkE0 = UnkE0 ?? 0f;
            l.UnkE4 = UnkE4 ?? 0;
        }

        return l;
    }

    public void ValidateOrThrow(int version)
    {
        if (Unk00 == null || Unk00.Length != 16)
            throw new InvalidDataException($"Light '{Name}': Unk00 must be byte[16].");

        if (Name == null)
            throw new InvalidDataException("Light.Name is null.");

        if (Unk64 == null || Unk64.Length != 4)
            throw new InvalidDataException($"Light '{Name}': Unk64 must be byte[4].");
        if (Unk84 == null || Unk84.Length != 4)
            throw new InvalidDataException($"Light '{Name}': Unk84 must be byte[4].");
        if (UnkA0 == null || UnkA0.Length != 4)
            throw new InvalidDataException($"Light '{Name}': UnkA0 must be byte[4].");
        if (UnkC0 == null || UnkC0.Length != 4)
            throw new InvalidDataException($"Light '{Name}': UnkC0 must be byte[4].");

        // Enforce RGB alpha = 255 so JSON edits can’t sneak alpha into RGB-only fields.
        if (DiffuseColor.A != 255)
            throw new InvalidDataException($"Light '{Name}': DiffuseColor alpha must be 255 (RGB-only in file).");
        if (SpecularColor.A != 255)
            throw new InvalidDataException($"Light '{Name}': SpecularColor alpha must be 255 (RGB-only in file).");

        if (version < 16)
        {
            // If you want strictness, uncomment:
            // if (UnkC8 != null || UnkCC != null || UnkD0 != null || UnkD4 != null || UnkD8 != null || UnkDC != null || UnkE0 != null || UnkE4 != null)
            //     throw new InvalidDataException($"Light '{Name}': Sekiro-only fields present but Version < 16.");
        }
    }
}

#endregion

#region Helpers / converters

public readonly record struct Rgba8(byte R, byte G, byte B, byte A)
{
    public static Rgba8 FromColorRgb(Color c) => new(c.R, c.G, c.B, 255);
    public static Rgba8 FromColorRgba(Color c) => new(c.R, c.G, c.B, c.A);

    public Color ToColorRgba() => Color.FromArgb(A, R, G, B);
    public Color ToColorRgb255() => Color.FromArgb(255, R, G, B);
}

public sealed class Rgba8Converter : JsonConverter<Rgba8>
{
    public override Rgba8 Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        // Accept [r,g,b,a] or {"r":..,"g":..,"b":..,"a":..}
        if (reader.TokenType == JsonTokenType.StartArray)
        {
            reader.Read(); byte r = ReadByte(ref reader);
            reader.Read(); byte g = ReadByte(ref reader);
            reader.Read(); byte b = ReadByte(ref reader);
            reader.Read(); byte a = ReadByte(ref reader);
            reader.Read();
            return new Rgba8(r, g, b, a);
        }

        if (reader.TokenType == JsonTokenType.StartObject)
        {
            byte r = 0, g = 0, b = 0, a = 255;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject) break;
                if (reader.TokenType != JsonTokenType.PropertyName) continue;
                string prop = reader.GetString() ?? "";
                reader.Read();
                switch (prop)
                {
                    case "r": r = ReadByte(ref reader); break;
                    case "g": g = ReadByte(ref reader); break;
                    case "b": b = ReadByte(ref reader); break;
                    case "a": a = ReadByte(ref reader); break;
                    default: reader.Skip(); break;
                }
            }
            return new Rgba8(r, g, b, a);
        }

        throw new JsonException("Invalid RGBA JSON.");
    }

    public override void Write(Utf8JsonWriter writer, Rgba8 value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        writer.WriteNumberValue(value.R);
        writer.WriteNumberValue(value.G);
        writer.WriteNumberValue(value.B);
        writer.WriteNumberValue(value.A);
        writer.WriteEndArray();
    }

    private static byte ReadByte(ref Utf8JsonReader reader)
    {
        int n = reader.GetInt32();
        if ((uint)n > 255) throw new JsonException("RGBA component out of range (0..255).");
        return (byte)n;
    }
}

public sealed class Vector3Converter : JsonConverter<Vector3>
{
    public override Vector3 Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.StartArray)
        {
            reader.Read(); float x = reader.GetSingle();
            reader.Read(); float y = reader.GetSingle();
            reader.Read(); float z = reader.GetSingle();
            reader.Read();
            return new Vector3(x, y, z);
        }

        if (reader.TokenType == JsonTokenType.StartObject)
        {
            float x = 0, y = 0, z = 0;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject) break;
                if (reader.TokenType != JsonTokenType.PropertyName) continue;
                string prop = reader.GetString() ?? "";
                reader.Read();
                switch (prop)
                {
                    case "x": x = reader.GetSingle(); break;
                    case "y": y = reader.GetSingle(); break;
                    case "z": z = reader.GetSingle(); break;
                    default: reader.Skip(); break;
                }
            }
            return new Vector3(x, y, z);
        }

        throw new JsonException("Invalid Vector3 JSON.");
    }

    public override void Write(Utf8JsonWriter writer, Vector3 value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        writer.WriteNumberValue(value.X);
        writer.WriteNumberValue(value.Y);
        writer.WriteNumberValue(value.Z);
        writer.WriteEndArray();
    }
}

/// <summary>
/// Enforces exact length for byte[] during JSON (supports multiple instances per options).
/// Note: JsonSerializerOptions caches converters by type, so we implement as a factory-like converter.
/// </summary>
public sealed class ByteArrayNumberConverter : JsonConverter<byte[]>
{
    public override byte[] Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        // Accept either [0,1,2,...] or base64 string (fallback)
        if (reader.TokenType == JsonTokenType.String)
        {
            // System.Text.Json default format for byte[] is base64; accept it for compatibility.
            return reader.GetBytesFromBase64();
        }

        if (reader.TokenType != JsonTokenType.StartArray)
            throw new JsonException("Expected byte[] as JSON array or base64 string.");

        var list = new List<byte>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndArray)
                break;

            int n = reader.GetInt32();
            if ((uint)n > 255) throw new JsonException("byte value out of range (0..255).");
            list.Add((byte)n);
        }

        return list.ToArray();
    }

    public override void Write(Utf8JsonWriter writer, byte[] value, JsonSerializerOptions options)
    {
        if (value is null)
        {
            writer.WriteNullValue();
            return;
        }

        writer.WriteStartArray();
        for (int i = 0; i < value.Length; i++)
            writer.WriteNumberValue(value[i]);
        writer.WriteEndArray();
    }
}

#endregion