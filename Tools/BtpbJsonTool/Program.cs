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
                    if (args.Length != 3) return Usage("dump requires: <input.btpb> <output.json>");
                    Dump(args[1], args[2]);
                    return 0;

                case "rebuild":
                    if (args.Length != 3) return Usage("rebuild requires: <input.json> <output.btpb>");
                    Rebuild(args[1], args[2]);
                    return 0;

                case "verify":
                    if (args.Length != 4) return Usage("verify requires: <input.btpb> <temp.json> <rebuilt.btpb>");
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
@"BtpbJsonTool (BTPB <-> JSON)

Commands:
  dump    <input.btpb>  <output.json>
  rebuild <input.json>  <output.btpb>
  verify  <input.btpb>  <temp.json> <rebuilt.btpb>
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
        return o;
    }

    private static void Dump(string btpbPath, string jsonPath)
    {
        BTPB btpb = BTPB.Read(btpbPath);
        var doc = BtpbJson.FromBtpb(btpb);
        doc.ValidateOrThrow();

        File.WriteAllText(jsonPath, JsonSerializer.Serialize(doc, JsonOpts));
        Console.WriteLine($"Dumped: {btpbPath}");
        Console.WriteLine($"   To: {jsonPath}");
    }

    private static void Rebuild(string jsonPath, string btpbOutPath)
    {
        var doc = JsonSerializer.Deserialize<BtpbJson>(File.ReadAllText(jsonPath), JsonOpts)
            ?? throw new InvalidDataException("Failed to deserialize JSON.");

        doc.ValidateOrThrow();

        BTPB btpb = doc.ToBtpb();
        btpb.Write(btpbOutPath);

        Console.WriteLine($"Rebuilt: {jsonPath}");
        Console.WriteLine($"     To: {btpbOutPath}");
    }

    private static void Verify(string btpbPath, string tempJsonPath, string rebuiltBtpbPath)
    {
        var original = BTPB.Read(btpbPath);

        var dump = BtpbJson.FromBtpb(original);
        dump.ValidateOrThrow();
        File.WriteAllText(tempJsonPath, JsonSerializer.Serialize(dump, JsonOpts));

        var rebuilt = dump.ToBtpb();
        rebuilt.Write(rebuiltBtpbPath);

        var reread = BTPB.Read(rebuiltBtpbPath);

        Console.WriteLine("VERIFY OK:");
        Console.WriteLine($"  Input:   {btpbPath}");
        Console.WriteLine($"  Dump:    {tempJsonPath}");
        Console.WriteLine($"  Rebuilt: {rebuiltBtpbPath}");
        Console.WriteLine($"  Reread:  success (Version={reread.Version}, Groups={reread.Groups.Count})");
    }
}

#region JSON schema

public sealed class BtpbJson
{
    public string Schema { get; set; } = "btpb-json-v1";

    public BTPB.BTPBVersion Version { get; set; } = BTPB.BTPBVersion.DarkSouls3;

    public Vector3 Unk1C { get; set; }
    public Vector3 Unk28 { get; set; }

    public List<BtpbGroupJson> Groups { get; set; } = new();

    public static BtpbJson FromBtpb(BTPB b) => new()
    {
        Version = b.Version,
        Unk1C = b.Unk1C,
        Unk28 = b.Unk28,
        Groups = b.Groups.Select(g => BtpbGroupJson.From(g, b.Version)).ToList()
    };

    public BTPB ToBtpb()
    {
        ValidateOrThrow();

        var b = new BTPB
        {
            Version = Version,
            Unk1C = Unk1C,
            Unk28 = Unk28,
            Groups = Groups.Select(g => g.ToGroup(Version)).ToList()
        };
        return b;
    }

    public void ValidateOrThrow()
    {
        if (Schema != "btpb-json-v1")
            throw new InvalidDataException($"Unsupported schema: {Schema}");

        if (Groups == null)
            throw new InvalidDataException("Groups is null.");

        foreach (var g in Groups)
            g.ValidateOrThrow(Version);
    }
}

public sealed class BtpbGroupJson
{
    public string? Name { get; set; } = "";
    public int Flags08 { get; set; }

    public int Unk10 { get; set; }
    public int Unk14 { get; set; }
    public int Unk18 { get; set; }

    public float Unk1C { get; set; }
    public float Unk20 { get; set; }
    public float Unk24 { get; set; }

    public Vector3 Unk28 { get; set; }
    public Vector3 Unk34 { get; set; }

    public List<BtpbProbeJson> Probes { get; set; } = new();

    // DS3-only
    public float? Unk48 { get; set; }
    public float? Unk4C { get; set; }
    public float? Unk50 { get; set; }
    public byte? Unk94 { get; set; }
    public byte? Unk95 { get; set; }
    public byte? Unk96 { get; set; }

    public static BtpbGroupJson From(BTPB.Group g, BTPB.BTPBVersion v) => new()
    {
        Name = g.Name,
        Flags08 = g.Flags08,
        Unk10 = g.Unk10,
        Unk14 = g.Unk14,
        Unk18 = g.Unk18,
        Unk1C = g.Unk1C,
        Unk20 = g.Unk20,
        Unk24 = g.Unk24,
        Unk28 = g.Unk28,
        Unk34 = g.Unk34,
        Probes = g.Probes.Select(p => BtpbProbeJson.From(p, v)).ToList(),

        Unk48 = v >= BTPB.BTPBVersion.DarkSouls3 ? g.Unk48 : null,
        Unk4C = v >= BTPB.BTPBVersion.DarkSouls3 ? g.Unk4C : null,
        Unk50 = v >= BTPB.BTPBVersion.DarkSouls3 ? g.Unk50 : null,
        Unk94 = v >= BTPB.BTPBVersion.DarkSouls3 ? g.Unk94 : null,
        Unk95 = v >= BTPB.BTPBVersion.DarkSouls3 ? g.Unk95 : null,
        Unk96 = v >= BTPB.BTPBVersion.DarkSouls3 ? g.Unk96 : null,
    };

    public BTPB.Group ToGroup(BTPB.BTPBVersion v)
    {
        ValidateOrThrow(v);

        var g = new BTPB.Group
        {
            Flags08 = Flags08,
            Unk10 = Unk10,
            Unk14 = Unk14,
            Unk18 = Unk18,
            Unk1C = Unk1C,
            Unk20 = Unk20,
            Unk24 = Unk24,
            Unk28 = Unk28,
            Unk34 = Unk34,
            Probes = Probes.Select(p => p.ToProbe(v)).ToList()
        };

        // Name presence is controlled by Flags08 bit0 in SoulsFormats
        if ((Flags08 & 1) != 0)
            g.Name = Name ?? "";
        else
            g.Name = ""; // safe default; it won't be written because Flags08 bit0 is off

        if (v >= BTPB.BTPBVersion.DarkSouls3)
        {
            g.Unk48 = Unk48 ?? 0f;
            g.Unk4C = Unk4C ?? 0f;
            g.Unk50 = Unk50 ?? 0f;
            g.Unk94 = Unk94 ?? 0;
            g.Unk95 = Unk95 ?? 0;
            g.Unk96 = Unk96 ?? 0;
        }

        return g;
    }

    public void ValidateOrThrow(BTPB.BTPBVersion v)
    {
        if (Probes == null)
            throw new InvalidDataException("Group.Probes is null.");

        // If name flag is set, we require a non-null name (empty string is allowed)
        if ((Flags08 & 1) != 0 && Name == null)
            throw new InvalidDataException("Group Name is null but Flags08 bit0 indicates a name is present.");

        foreach (var p in Probes)
            p.ValidateOrThrow(v);

        if (v < BTPB.BTPBVersion.DarkSouls3)
        {
            // Don’t hard-fail on DS3-only fields being present; but you can if you want strictness.
        }
        else
        {
            // Ensure nullable DS3-only fields exist (we’ll default them otherwise)
        }
    }
}

public sealed class BtpbProbeJson
{
    public short[] Coefficients { get; set; } = new short[12];
    public short LightMask { get; set; }
    public short Unk1A { get; set; }

    public Vector3? Position { get; set; } // only for BB/DS3

    public static BtpbProbeJson From(BTPB.Probe p, BTPB.BTPBVersion v) => new()
    {
        Coefficients = (short[])p.Coefficients.Clone(),
        LightMask = p.LightMask,
        Unk1A = p.Unk1A,
        Position = v >= BTPB.BTPBVersion.Bloodborne ? p.Position : null
    };

    public BTPB.Probe ToProbe(BTPB.BTPBVersion v)
    {
        ValidateOrThrow(v);

        var p = new BTPB.Probe
        {
            LightMask = LightMask,
            Unk1A = Unk1A
        };

        // Coefficients has private set; mutate the array contents
        if (p.Coefficients.Length != 12)
            throw new InvalidDataException("Probe.Coefficients length is not 12 (unexpected SoulsFormats behavior).");

        for (int i = 0; i < 12; i++)
            p.Coefficients[i] = Coefficients[i];

        if (v >= BTPB.BTPBVersion.Bloodborne)
            p.Position = Position ?? Vector3.Zero;

        return p;
    }

    public void ValidateOrThrow(BTPB.BTPBVersion v)
    {
        if (Coefficients == null || Coefficients.Length != 12)
            throw new InvalidDataException("Probe.Coefficients must be short[12].");

        if (v < BTPB.BTPBVersion.Bloodborne)
        {
            // DS2 formats: Position is not stored/written.
        }
        else
        {
            // BB/DS3: position exists in file; allow null and default to zero in rebuild.
        }
    }
}

#endregion

#region Vector3 converter

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

#endregion