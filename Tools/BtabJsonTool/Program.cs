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
                    if (args.Length != 3) return Usage("dump requires: <input.btab> <output.json>");
                    Dump(args[1], args[2]);
                    return 0;

                case "rebuild":
                    if (args.Length != 3) return Usage("rebuild requires: <input.json> <output.btab>");
                    Rebuild(args[1], args[2]);
                    return 0;

                case "verify":
                    if (args.Length != 4) return Usage("verify requires: <input.btab> <temp.json> <rebuilt.btab>");
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
@"BtabJsonTool (BTAB <-> JSON)

Commands:
  dump    <input.btab>  <output.json>
  rebuild <input.json>  <output.btab>
  verify  <input.btab>  <temp.json> <rebuilt.btab>
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
        o.Converters.Add(new Vector2Converter());
        return o;
    }

    private static void Dump(string btabPath, string jsonPath)
    {
        BTAB btab = BTAB.Read(btabPath);
        var doc = BtabJson.FromBtab(btab);
        doc.ValidateOrThrow();

        File.WriteAllText(jsonPath, JsonSerializer.Serialize(doc, JsonOpts));
        Console.WriteLine($"Dumped: {btabPath}");
        Console.WriteLine($"   To: {jsonPath}");
    }

    private static void Rebuild(string jsonPath, string btabOutPath)
    {
        var doc = JsonSerializer.Deserialize<BtabJson>(File.ReadAllText(jsonPath), JsonOpts)
            ?? throw new InvalidDataException("Failed to deserialize JSON.");

        doc.ValidateOrThrow();

        BTAB btab = doc.ToBtab();
        btab.Write(btabOutPath);

        Console.WriteLine($"Rebuilt: {jsonPath}");
        Console.WriteLine($"     To: {btabOutPath}");
    }

    private static void Verify(string btabPath, string tempJsonPath, string rebuiltBtabPath)
    {
        var original = BTAB.Read(btabPath);

        var dump = BtabJson.FromBtab(original);
        dump.ValidateOrThrow();
        File.WriteAllText(tempJsonPath, JsonSerializer.Serialize(dump, JsonOpts));

        var rebuilt = dump.ToBtab();
        rebuilt.Write(rebuiltBtabPath);

        var reread = BTAB.Read(rebuiltBtabPath);

        Console.WriteLine("VERIFY OK:");
        Console.WriteLine($"  Input:   {btabPath}");
        Console.WriteLine($"  Dump:    {tempJsonPath}");
        Console.WriteLine($"  Rebuilt: {rebuiltBtabPath}");
        Console.WriteLine($"  Reread:  success (Entries={reread.Entries.Count}, BigEndian={reread.BigEndian}, LongFormat={reread.LongFormat})");
    }
}

#region JSON schema

public sealed class BtabJson
{
    public string Schema { get; set; } = "btab-json-v1";

    public bool BigEndian { get; set; }
    public bool LongFormat { get; set; }

    public List<BtabEntryJson> Entries { get; set; } = new();

    public static BtabJson FromBtab(BTAB btab) => new()
    {
        BigEndian = btab.BigEndian,
        LongFormat = btab.LongFormat,
        Entries = btab.Entries.Select(BtabEntryJson.From).ToList()
    };

    public BTAB ToBtab()
    {
        ValidateOrThrow();

        var btab = new BTAB
        {
            BigEndian = BigEndian,
            LongFormat = LongFormat,
            Entries = Entries.Select(e => e.ToEntry()).ToList()
        };
        return btab;
    }

    public void ValidateOrThrow()
    {
        if (Schema != "btab-json-v1")
            throw new InvalidDataException($"Unsupported schema: {Schema}");

        if (Entries == null)
            throw new InvalidDataException("Entries is null.");

        foreach (var e in Entries)
            e.ValidateOrThrow();
    }
}

public sealed class BtabEntryJson
{
    public string PartName { get; set; } = "";
    public string MaterialName { get; set; } = "";
    public int AtlasId { get; set; }

    public Vector2 UVOffset { get; set; }
    public Vector2 UVScale { get; set; } = Vector2.One;

    public static BtabEntryJson From(BTAB.Entry e) => new()
    {
        PartName = e.PartName ?? "",
        MaterialName = e.MaterialName ?? "",
        AtlasId = e.AtlasID,
        UVOffset = e.UVOffset,
        UVScale = e.UVScale
    };

    public BTAB.Entry ToEntry() => new()
    {
        PartName = PartName ?? "",
        MaterialName = MaterialName ?? "",
        AtlasID = AtlasId,
        UVOffset = UVOffset,
        UVScale = UVScale
    };

    public void ValidateOrThrow()
    {
        if (PartName == null) PartName = "";
        if (MaterialName == null) MaterialName = "";
        // AtlasId: any int32 is acceptable.
        // UVScale/Offset: any float values acceptable (game may clamp, but format doesn't).
    }
}

#endregion

#region JSON converters (Vector2)

public sealed class Vector2Converter : JsonConverter<Vector2>
{
    public override Vector2 Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        // Accept either [x,y] or {"x":..,"y":..}
        if (reader.TokenType == JsonTokenType.StartArray)
        {
            reader.Read(); float x = reader.GetSingle();
            reader.Read(); float y = reader.GetSingle();
            reader.Read();
            return new Vector2(x, y);
        }

        if (reader.TokenType == JsonTokenType.StartObject)
        {
            float x = 0, y = 0;
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
                    default: reader.Skip(); break;
                }
            }
            return new Vector2(x, y);
        }

        throw new JsonException("Invalid Vector2 JSON.");
    }

    public override void Write(Utf8JsonWriter writer, Vector2 value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        writer.WriteNumberValue(value.X);
        writer.WriteNumberValue(value.Y);
        writer.WriteEndArray();
    }
}

#endregion