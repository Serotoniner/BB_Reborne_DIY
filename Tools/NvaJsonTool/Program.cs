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
                    if (args.Length != 3) return Usage("dump requires: <input.nva> <output.json>");
                    Dump(args[1], args[2]);
                    return 0;

                case "rebuild":
                    if (args.Length != 3) return Usage("rebuild requires: <input.json> <output.nva>");
                    Rebuild(args[1], args[2]);
                    return 0;

                case "verify":
                    if (args.Length != 4) return Usage("verify requires: <input.nva> <temp.json> <rebuilt.nva>");
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
@"NvaJsonTool (NVA <-> JSON)

Commands:
  dump    <input.nva>  <output.json>
  rebuild <input.json> <output.nva>
  verify  <input.nva>  <temp.json> <rebuilt.nva>
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

    private static void Dump(string nvaPath, string jsonPath)
    {
        NVA nva = NVA.Read(nvaPath);
        var doc = NvaJson.FromNva(nva);
        doc.ValidateOrThrow();

        File.WriteAllText(jsonPath, JsonSerializer.Serialize(doc, JsonOpts));
        Console.WriteLine($"Dumped: {nvaPath}");
        Console.WriteLine($"   To: {jsonPath}");
    }

    private static void Rebuild(string jsonPath, string nvaOutPath)
    {
        var doc = JsonSerializer.Deserialize<NvaJson>(File.ReadAllText(jsonPath), JsonOpts)
            ?? throw new InvalidDataException("Failed to deserialize JSON.");

        doc.ValidateOrThrow();

        NVA nva = doc.ToNva();
        nva.Write(nvaOutPath);

        Console.WriteLine($"Rebuilt: {jsonPath}");
        Console.WriteLine($"     To: {nvaOutPath}");
    }

    private static void Verify(string nvaPath, string tempJsonPath, string rebuiltNvaPath)
    {
        var original = NVA.Read(nvaPath);

        var dump = NvaJson.FromNva(original);
        dump.ValidateOrThrow();
        File.WriteAllText(tempJsonPath, JsonSerializer.Serialize(dump, JsonOpts));

        var rebuilt = dump.ToNva();
        rebuilt.Write(rebuiltNvaPath);

        var reread = NVA.Read(rebuiltNvaPath);

        Console.WriteLine("VERIFY OK:");
        Console.WriteLine($"  Input:   {nvaPath}");
        Console.WriteLine($"  Dump:    {tempJsonPath}");
        Console.WriteLine($"  Rebuilt: {rebuiltNvaPath}");
        Console.WriteLine($"  Reread:  success (Navmeshes={reread.Navmeshes.Count}, Connectors={reread.Connectors.Count})");
    }
}

#region JSON schema

public sealed class NvaJson
{
    public string Schema { get; set; } = "nva-json-v1";

    public NVA.NVAVersion Version { get; set; } = NVA.NVAVersion.DarkSouls3;

    // Preserve these explicitly so we can round-trip BB vs DS3 vs Sekiro behavior.
    public int NavmeshSectionVersion { get; set; } = 2;
    public int MapNodeSectionVersion { get; set; } = 1;

    public List<NavmeshJson> Navmeshes { get; set; } = new();
    public List<Entry1Json> Entries1 { get; set; } = new();
    public List<Entry2Json> Entries2 { get; set; } = new();
    public List<ConnectorJson> Connectors { get; set; } = new();
    public List<Entry7Json> Entries7 { get; set; } = new();

    public static NvaJson FromNva(NVA nva)
    {
        return new NvaJson
        {
            Version = nva.Version,
            NavmeshSectionVersion = nva.Navmeshes.Version,
            // OldBloodborne doesn't actually have the section, but we can record "1" as the effective version.
            MapNodeSectionVersion = (nva.Version == NVA.NVAVersion.Sekiro) ? 2 : 1,

            Navmeshes = nva.Navmeshes.Select(NavmeshJson.From).ToList(),
            Entries1 = nva.Entries1.Select(Entry1Json.From).ToList(),
            Entries2 = nva.Entries2.Select(Entry2Json.From).ToList(),
            Connectors = nva.Connectors.Select(ConnectorJson.From).ToList(),
            Entries7 = nva.Entries7.Select(Entry7Json.From).ToList(),
        };
    }

    public NVA ToNva()
    {
        ValidateOrThrow();

        var nva = new NVA
        {
            Version = Version,
            Navmeshes = new NVA.NavmeshSection(NavmeshSectionVersion),
            Entries1 = new NVA.Section1(),
            Entries2 = new NVA.Section2(),
            Connectors = new NVA.ConnectorSection(),
            Entries7 = new NVA.Section7(),
        };

        // Set section versions (defaults are fine for 1, but keep explicit for clarity)
        nva.Entries1.Version = 1;
        nva.Entries2.Version = 1;
        nva.Connectors.Version = 1;
        nva.Entries7.Version = 1;

        foreach (var nj in Navmeshes) nva.Navmeshes.Add(nj.ToNavmesh());
        foreach (var e1 in Entries1) nva.Entries1.Add(e1.ToEntry1());
        foreach (var e2 in Entries2) nva.Entries2.Add(e2.ToEntry2());
        foreach (var cj in Connectors) nva.Connectors.Add(cj.ToConnector());
        foreach (var e7 in Entries7) nva.Entries7.Add(e7.ToEntry7());

        // Flattening of connectors and mapnodes is handled by SoulsFormats NVA.Write().
        return nva;
    }

    public void ValidateOrThrow()
    {
        if (Schema != "nva-json-v1")
            throw new InvalidDataException($"Unsupported schema: {Schema}");

        // Section versions must match what SoulsFormats expects.
        if (NavmeshSectionVersion is not (2 or 3 or 4))
            throw new InvalidDataException($"NavmeshSectionVersion must be 2, 3, or 4 (got {NavmeshSectionVersion}).");

        if (Version == NVA.NVAVersion.Sekiro && NavmeshSectionVersion != 4)
            throw new InvalidDataException("Sekiro NVA should use NavmeshSectionVersion=4.");
        if (Version != NVA.NVAVersion.Sekiro && NavmeshSectionVersion == 4)
            throw new InvalidDataException("NavmeshSectionVersion=4 is Sekiro-only in known NVAs.");

        if (MapNodeSectionVersion is not (1 or 2))
            throw new InvalidDataException($"MapNodeSectionVersion must be 1 or 2 (got {MapNodeSectionVersion}).");
        if (Version == NVA.NVAVersion.Sekiro && MapNodeSectionVersion != 2)
            throw new InvalidDataException("Sekiro NVA should use MapNodeSectionVersion=2.");
        if (Version != NVA.NVAVersion.Sekiro && MapNodeSectionVersion != 1)
            throw new InvalidDataException("BB/DS3 NVA should use MapNodeSectionVersion=1.");

        foreach (var n in Navmeshes) n.ValidateOrThrow(NavmeshSectionVersion, MapNodeSectionVersion);
        foreach (var e2 in Entries2) e2.ValidateOrThrow();
        foreach (var c in Connectors) c.ValidateOrThrow();
    }
}

public sealed class NavmeshJson
{
    public Vector3 Position { get; set; }
    public Vector3 Rotation { get; set; }
    public Vector3 Scale { get; set; } = Vector3.One;

    public int NameID { get; set; }
    public int ModelID { get; set; }
    public int Unk38 { get; set; }
    public int VertexCount { get; set; }
    public bool Unk4C { get; set; }

    public List<int> NameReferenceIDs { get; set; } = new();
    public List<MapNodeJson> MapNodes { get; set; } = new();

    public static NavmeshJson From(NVA.Navmesh n) => new()
    {
        Position = n.Position,
        Rotation = n.Rotation,
        Scale = n.Scale,
        NameID = n.NameID,
        ModelID = n.ModelID,
        Unk38 = n.Unk38,
        VertexCount = n.VertexCount,
        Unk4C = n.Unk4C,
        NameReferenceIDs = n.NameReferenceIDs.ToList(),
        MapNodes = n.MapNodes.Select(MapNodeJson.From).ToList(),
    };

    public NVA.Navmesh ToNavmesh()
    {
        var n = new NVA.Navmesh
        {
            Position = Position,
            Rotation = Rotation,
            Scale = Scale,
            NameID = NameID,
            ModelID = ModelID,
            Unk38 = Unk38,
            VertexCount = VertexCount,
            Unk4C = Unk4C,
            NameReferenceIDs = NameReferenceIDs?.ToList() ?? new List<int>(),
            MapNodes = MapNodes?.Select(m => m.ToMapNode()).ToList() ?? new List<NVA.MapNode>(),
        };
        return n;
    }

    public void ValidateOrThrow(int navmeshSectionVersion, int mapNodeSectionVersion)
    {
        if (navmeshSectionVersion < 4)
        {
            if (NameReferenceIDs.Count > 16)
                throw new InvalidDataException("NameReferenceIDs must not exceed 16 for DS3/BB (NavmeshSectionVersion < 4).");
        }

        foreach (var mn in MapNodes)
            mn.ValidateOrThrow(mapNodeSectionVersion);
    }
}

public sealed class MapNodeJson
{
    public Vector3 Position { get; set; }
    public short Section0Index { get; set; }
    public short MainID { get; set; }

    public List<float> SiblingDistances { get; set; } = new();

    // Sekiro only (MapNodeSectionVersion=2)
    public int Unk14 { get; set; }

    public static MapNodeJson From(NVA.MapNode m) => new()
    {
        Position = m.Position,
        Section0Index = m.Section0Index,
        MainID = m.MainID,
        SiblingDistances = m.SiblingDistances.ToList(),
        Unk14 = m.Unk14,
    };

    public NVA.MapNode ToMapNode()
    {
        var m = new NVA.MapNode
        {
            Position = Position,
            Section0Index = Section0Index,
            MainID = MainID,
            SiblingDistances = SiblingDistances?.ToList() ?? new List<float>(),
            Unk14 = Unk14,
        };
        return m;
    }

    public void ValidateOrThrow(int mapNodeSectionVersion)
    {
        if (mapNodeSectionVersion < 2 && SiblingDistances.Count > 16)
            throw new InvalidDataException("MapNode.SiblingDistances must not exceed 16 for BB/DS3 (MapNodeSectionVersion=1).");
    }
}

public sealed class Entry1Json
{
    public int Unk00 { get; set; }

    public static Entry1Json From(NVA.Entry1 e) => new() { Unk00 = e.Unk00 };
    public NVA.Entry1 ToEntry1() => new() { Unk00 = Unk00 };
}

public sealed class Entry2Json
{
    public int Unk00 { get; set; }
    public int Unk08 { get; set; } = -1;
    public List<Entry2RefJson> References { get; set; } = new();

    public static Entry2Json From(NVA.Entry2 e) => new()
    {
        Unk00 = e.Unk00,
        Unk08 = e.Unk08,
        References = e.References.Select(Entry2RefJson.From).ToList()
    };

    public NVA.Entry2 ToEntry2()
    {
        var e = new NVA.Entry2
        {
            Unk00 = Unk00,
            Unk08 = Unk08,
            References = References?.Select(r => r.ToRef()).ToList() ?? new List<NVA.Entry2.Reference>()
        };
        return e;
    }

    public void ValidateOrThrow()
    {
        if (References.Count > 64)
            throw new InvalidDataException("Entry2.References must not exceed 64.");
    }
}

public sealed class Entry2RefJson
{
    public int UnkIndex { get; set; }
    public int NameID { get; set; }

    public static Entry2RefJson From(NVA.Entry2.Reference r) => new() { UnkIndex = r.UnkIndex, NameID = r.NameID };
    public NVA.Entry2.Reference ToRef() => new() { UnkIndex = UnkIndex, NameID = NameID };
}

public sealed class ConnectorJson
{
    public int MainNameID { get; set; }
    public int TargetNameID { get; set; }

    public List<ConnectorPointJson> Points { get; set; } = new();
    public List<ConnectorConditionJson> Conditions { get; set; } = new();

    public static ConnectorJson From(NVA.Connector c) => new()
    {
        MainNameID = c.MainNameID,
        TargetNameID = c.TargetNameID,
        Points = c.Points.Select(ConnectorPointJson.From).ToList(),
        Conditions = c.Conditions.Select(ConnectorConditionJson.From).ToList()
    };

    public NVA.Connector ToConnector()
    {
        var c = new NVA.Connector
        {
            MainNameID = MainNameID,
            TargetNameID = TargetNameID,
            Points = Points?.Select(p => p.ToPoint()).ToList() ?? new List<NVA.ConnectorPoint>(),
            Conditions = Conditions?.Select(x => x.ToCond()).ToList() ?? new List<NVA.ConnectorCondition>(),
        };
        return c;
    }

    public void ValidateOrThrow()
    {
        // No hard caps in this code, but you could add sanity checks if you discover real constraints.
    }
}

public sealed class ConnectorPointJson
{
    public int Unk00 { get; set; }
    public int Unk04 { get; set; }
    public int Unk08 { get; set; }
    public int Unk0C { get; set; }

    public static ConnectorPointJson From(NVA.ConnectorPoint p) => new()
    {
        Unk00 = p.Unk00, Unk04 = p.Unk04, Unk08 = p.Unk08, Unk0C = p.Unk0C
    };

    public NVA.ConnectorPoint ToPoint() => new()
    {
        Unk00 = Unk00, Unk04 = Unk04, Unk08 = Unk08, Unk0C = Unk0C
    };
}

public sealed class ConnectorConditionJson
{
    public int Condition1 { get; set; }
    public int Condition2 { get; set; }

    public static ConnectorConditionJson From(NVA.ConnectorCondition c) => new()
    {
        Condition1 = c.Condition1, Condition2 = c.Condition2
    };

    public NVA.ConnectorCondition ToCond() => new()
    {
        Condition1 = Condition1, Condition2 = Condition2
    };
}

public sealed class Entry7Json
{
    public Vector3 Position { get; set; }
    public int NameID { get; set; }
    public int Unk18 { get; set; }

    public static Entry7Json From(NVA.Entry7 e) => new()
    {
        Position = e.Position,
        NameID = e.NameID,
        Unk18 = e.Unk18
    };

    public NVA.Entry7 ToEntry7() => new()
    {
        Position = Position,
        NameID = NameID,
        Unk18 = Unk18
    };
}

#endregion

#region JSON converters

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