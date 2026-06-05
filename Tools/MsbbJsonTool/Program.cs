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

// MsbbJsonTool
// Usage:
//   MsbbJsonTool dump    <input.msb>  <output.json>
//   MsbbJsonTool rebuild <input.json> <output.msb>
//   MsbbJsonTool verify  <input.msb>  <temp.json> <rebuilt.msb>
//
// Notes:
// - This is for Bloodborne MSBB (.msb) specifically.
// - Indices are NOT stored; names are stored and SoulsFormats resolves indices during Write().
// - Arrays with fixed sizes are validated (DrawGroups/DispGroups/BackreadGroups etc).
// - All variable types are preserved (byte/sbyte/short/int/float).

internal static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1)
                return Usage("Missing command.");

            string cmd = args[0].ToLowerInvariant();

            switch (cmd)
            {
                case "dump":
                    if (args.Length != 3) return Usage("dump requires: <input.msb> <output.json>");
                    Dump(args[1], args[2]);
                    return 0;

                case "rebuild":
                    if (args.Length != 3) return Usage("rebuild requires: <input.json> <output.msb>");
                    Rebuild(args[1], args[2]);
                    return 0;

                case "verify":
                    if (args.Length != 4) return Usage("verify requires: <input.msb> <temp.json> <rebuilt.msb>");
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
@"MsbbJsonTool (Bloodborne MSBB <-> JSON)

Commands:
  dump    <input.msb>  <output.json>
  rebuild <input.json> <output.msb>
  verify  <input.msb>  <temp.json> <rebuilt.msb>
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
        o.Converters.Add(new Vector3Converter());
        o.Converters.Add(new UInt32Array8Converter());
        o.Converters.Add(new ByteArray4Converter());
        return o;
    }

    private static void Dump(string msbPath, string jsonPath)
    {
        MSBB msb = MSBB.Read(msbPath);
        MsbbJson doc = MsbbJson.FromMSBB(msb);

        string json = JsonSerializer.Serialize(doc, JsonOpts);
        File.WriteAllText(jsonPath, json);

        Console.WriteLine($"Dumped: {msbPath}");
        Console.WriteLine($"   To: {jsonPath}");
    }

    private static void Rebuild(string jsonPath, string msbOutPath)
    {
        string json = File.ReadAllText(jsonPath);
        MsbbJson doc = JsonSerializer.Deserialize<MsbbJson>(json, JsonOpts)
            ?? throw new InvalidDataException("Failed to deserialize JSON.");

        doc.ValidateOrThrow();

        MSBB msb = doc.ToMSBB();
        msb.Write(msbOutPath);

        Console.WriteLine($"Rebuilt: {jsonPath}");
        Console.WriteLine($"     To: {msbOutPath}");
    }

    private static void Verify(string msbPath, string tempJsonPath, string rebuiltMsbPath)
    {
        // 1) Read -> Dump
        var original = MSBB.Read(msbPath);
        var dump = MsbbJson.FromMSBB(original);
        dump.ValidateOrThrow();
        File.WriteAllText(tempJsonPath, JsonSerializer.Serialize(dump, JsonOpts));

        // 2) JSON -> Rebuild
        var rebuilt = dump.ToMSBB();
        rebuilt.Write(rebuiltMsbPath);

        // 3) Smoke-test read
        var reread = MSBB.Read(rebuiltMsbPath);

        Console.WriteLine("VERIFY OK:");
        Console.WriteLine($"  Input:   {msbPath}");
        Console.WriteLine($"  Dump:    {tempJsonPath}");
        Console.WriteLine($"  Rebuilt: {rebuiltMsbPath}");
        Console.WriteLine($"  Reread:  success ({reread.Models.GetEntries().Count} models, {reread.Parts.GetEntries().Count} parts, {reread.Regions.GetEntries().Count} regions, {reread.Events.GetEntries().Count} events)");
    }
}

#region JSON schema (DTOs)

public sealed class MsbbJson
{
    public string Schema { get; set; } = "msbb-json-v1";
    public string Game { get; set; } = "Bloodborne";
    //public DateTimeOffset DumpedAtUtc { get; set; } = DateTimeOffset.UtcNow;

    public ModelSection Models { get; set; } = new();
    public EventSection Events { get; set; } = new();
    public RegionSection Regions { get; set; } = new();
    public PartSection Parts { get; set; } = new();

    public static MsbbJson FromMSBB(MSBB msb)
    {
        var doc = new MsbbJson();

        // Models
        foreach (var m in msb.Models.MapPieces) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Objects) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Enemies) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Items) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Players) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Collisions) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Navmeshes) doc.Models.Entries.Add(ModelJson.From(m));
        foreach (var m in msb.Models.Others) doc.Models.Entries.Add(ModelJson.From(m));

        // Regions (BB only supports non-composite shapes)
        foreach (var r in msb.Regions.Regions)
            doc.Regions.Entries.Add(RegionJson.From(r));

        // Parts
        foreach (var p in msb.Parts.MapPieces) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.Objects) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.Enemies) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.Players) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.Collisions) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.Navmeshes) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.DummyObjects) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.DummyEnemies) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.ConnectCollisions) doc.Parts.Entries.Add(PartJson.From(p));
        foreach (var p in msb.Parts.Others) doc.Parts.Entries.Add(PartJson.From(p));

        // Events
        foreach (var e in msb.Events.Sounds) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.SFX) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.Treasures) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.Generators) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.Messages) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.ObjActs) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.SpawnPoints) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.MapOffsets) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.Navmeshes) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.Environments) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.WindSFX) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.PatrolInfo) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.DarkLocks) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.PlatoonInfo) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.MultiSummons) doc.Events.Entries.Add(EventJson.From(e));
        foreach (var e in msb.Events.Others) doc.Events.Entries.Add(EventJson.From(e));

        return doc;
    }

    public MSBB ToMSBB()
    {
        ValidateOrThrow();

        var msb = new MSBB();

        // Models: add into correct typed buckets
        foreach (var mj in Models.Entries)
        {
            MSBB.Model m = mj.ToModel();
            msb.Models.Add(m);
        }

        // Regions
        foreach (var rj in Regions.Entries)
        {
            var r = rj.ToRegion();
            msb.Regions.Add(r);
        }

        // Parts
        foreach (var pj in Parts.Entries)
        {
            MSBB.Part p = pj.ToPart();
            msb.Parts.Add(p);
        }

        // Events
        foreach (var ej in Events.Entries)
        {
            MSBB.Event e = ej.ToEvent();
            msb.Events.Add(e);
        }

        // Important:
        // SoulsFormats will Disambiguate/Reambiguate and compute indices in Write().
        return msb;
    }

    public void ValidateOrThrow()
    {
        if (Schema != "msbb-json-v1")
            throw new InvalidDataException($"Unsupported schema: {Schema}");

        Models.ValidateOrThrow();
        Regions.ValidateOrThrow();
        Parts.ValidateOrThrow();
        Events.ValidateOrThrow();

        // Optional: cross-check references exist (names)
        var modelNames = new HashSet<string>(Models.Entries.Select(e => e.Name));
        var regionNames = new HashSet<string>(Regions.Entries.Select(e => e.Name));
        var partNames = new HashSet<string>(Parts.Entries.Select(e => e.Name));

        // Parts reference models
        foreach (var p in Parts.Entries)
        {
            if (!string.IsNullOrEmpty(p.ModelName) && !modelNames.Contains(p.ModelName))
                throw new InvalidDataException($"Part '{p.Name}' references missing ModelName '{p.ModelName}'.");
        }

        // Events reference parts/regions depending on type
        foreach (var e in Events.Entries)
        {
            if (!string.IsNullOrEmpty(e.PartName) && !partNames.Contains(e.PartName))
                throw new InvalidDataException($"Event '{e.Name}' references missing PartName '{e.PartName}'.");
            if (!string.IsNullOrEmpty(e.RegionName) && !regionNames.Contains(e.RegionName))
                throw new InvalidDataException($"Event '{e.Name}' references missing RegionName '{e.RegionName}'.");
        }
    }
}

public sealed class ModelSection
{
    public List<ModelJson> Entries { get; set; } = new();

    public void ValidateOrThrow()
    {
        foreach (var e in Entries)
        {
            if (string.IsNullOrWhiteSpace(e.Type))
                throw new InvalidDataException("Model entry missing 'type'.");
            if (string.IsNullOrWhiteSpace(e.Name))
                throw new InvalidDataException("Model entry missing 'name'.");
            e.SibPath ??= "";
        }
    }
}

public sealed class EventSection
{
    public List<EventJson> Entries { get; set; } = new();
    public void ValidateOrThrow()
    {
        foreach (var e in Entries)
            e.ValidateOrThrow();
    }
}

public sealed class RegionSection
{
    public List<RegionJson> Entries { get; set; } = new();
    public void ValidateOrThrow()
    {
        foreach (var r in Entries)
            r.ValidateOrThrow();
    }
}

public sealed class PartSection
{
    public List<PartJson> Entries { get; set; } = new();
    public void ValidateOrThrow()
    {
        foreach (var p in Entries)
            p.ValidateOrThrow();
    }
}

public sealed class ModelJson
{
    // Discriminator: MapPiece/Object/Enemy/Item/Player/Collision/Navmesh/Other
    public string Type { get; set; } = "";
    public string Name { get; set; } = "";
    public string SibPath { get; set; } = "";

    public static ModelJson From(MSBB.Model m) => new()
    {
        Type = m switch
        {
            MSBB.Model.MapPiece => "MapPiece",
            MSBB.Model.Object => "Object",
            MSBB.Model.Enemy => "Enemy",
            MSBB.Model.Item => "Item",
            MSBB.Model.Player => "Player",
            MSBB.Model.Collision => "Collision",
            MSBB.Model.Navmesh => "Navmesh",
            MSBB.Model.Other => "Other",
            _ => throw new NotSupportedException($"Unsupported model runtime type: {m.GetType()}")
        },
        Name = m.Name,
        SibPath = m.SibPath ?? ""
    };

    public MSBB.Model ToModel()
    {
        MSBB.Model m = Type switch
        {
            "MapPiece" => new MSBB.Model.MapPiece(),
            "Object" => new MSBB.Model.Object(),
            "Enemy" => new MSBB.Model.Enemy(),
            "Item" => new MSBB.Model.Item(),
            "Player" => new MSBB.Model.Player(),
            "Collision" => new MSBB.Model.Collision(),
            "Navmesh" => new MSBB.Model.Navmesh(),
            "Other" => new MSBB.Model.Other(),
            _ => throw new InvalidDataException($"Unknown Model type '{Type}'.")
        };

        m.Name = Name;
        m.SibPath = SibPath ?? "";
        return m;
    }
}

public sealed class RegionJson
{
    public string Name { get; set; } = "Region";
    public Vector3 Position { get; set; }
    public Vector3 Rotation { get; set; }
    public int EntityID { get; set; } = -1;

    // Shape discriminator + parameters
    public ShapeJson Shape { get; set; } = new ShapeJson { Type = "Point" };

    public static RegionJson From(MSBB.Region r) => new()
    {
        Name = r.Name,
        Position = r.Position,
        Rotation = r.Rotation,
        EntityID = r.EntityID,
        Shape = ShapeJson.From(r.Shape)
    };

    public MSBB.Region ToRegion()
    {
        var r = new MSBB.Region
        {
            Name = Name,
            Position = Position,
            Rotation = Rotation,
            EntityID = EntityID,
            Shape = Shape.ToShape()
        };
        return r;
    }

    public void ValidateOrThrow()
    {
        if (string.IsNullOrWhiteSpace(Name))
            throw new InvalidDataException("Region missing 'name'.");
        Shape.ValidateOrThrow(bbNoComposite: true);
    }
}

public sealed class ShapeJson
{
    // Point/Circle/Sphere/Cylinder/Rectangle/Box
    public string Type { get; set; } = "Point";

    // Shared numeric fields (only relevant for some types)
    public float Radius { get; set; }
    public float Height { get; set; }
    public float Width { get; set; }
    public float Depth { get; set; }

    public static ShapeJson From(MSB.Shape s)
    {
        return s switch
        {
            MSB.Shape.Point => new ShapeJson { Type = "Point" },
            MSB.Shape.Circle c => new ShapeJson { Type = "Circle", Radius = c.Radius },
            MSB.Shape.Sphere sp => new ShapeJson { Type = "Sphere", Radius = sp.Radius },
            MSB.Shape.Cylinder cy => new ShapeJson { Type = "Cylinder", Radius = cy.Radius, Height = cy.Height },
            MSB.Shape.Rectangle re => new ShapeJson { Type = "Rectangle", Width = re.Width, Depth = re.Depth },
            MSB.Shape.Box bx => new ShapeJson { Type = "Box", Width = bx.Width, Depth = bx.Depth, Height = bx.Height },
            MSB.Shape.Composite => throw new InvalidDataException("Bloodborne does not support composite region shapes."),
            _ => throw new NotSupportedException($"Unsupported shape: {s.GetType()}")
        };
    }

    public MSB.Shape ToShape()
    {
        return Type switch
        {
            "Point" => new MSB.Shape.Point(),
            "Circle" => new MSB.Shape.Circle(Radius),
            "Sphere" => new MSB.Shape.Sphere(Radius),
            "Cylinder" => new MSB.Shape.Cylinder(Radius, Height),
            "Rectangle" => new MSB.Shape.Rectangle(Width, Depth),
            "Box" => new MSB.Shape.Box(Width, Depth, Height),
            _ => throw new InvalidDataException($"Unknown shape type '{Type}'.")
        };
    }

    public void ValidateOrThrow(bool bbNoComposite)
    {
        if (string.IsNullOrWhiteSpace(Type))
            throw new InvalidDataException("Shape missing 'type'.");

        if (bbNoComposite && Type == "Composite")
            throw new InvalidDataException("Bloodborne regions cannot be Composite.");
    }
}

public sealed class PartJson
{
    // Discriminator: MapPiece/Object/Enemy/Player/Collision/Navmesh/DummyObject/DummyEnemy/ConnectCollision/Other
    public string Type { get; set; } = "";

    // Common Part fields
    public string Description { get; set; } = "";
    public string Name { get; set; } = "";
    public int InstanceID { get; set; }
    public string ModelName { get; set; } = "";
    public string SibPath { get; set; } = "";
    public Vector3 Position { get; set; }
    public Vector3 Rotation { get; set; }
    public Vector3 Scale { get; set; } = Vector3.One;

    // These MUST remain uint[8]
    public uint[] DrawGroups { get; set; } = new uint[8];
    public uint[] DispGroups { get; set; } = new uint[8];
    public uint[] BackreadGroups { get; set; } = new uint[8];

    // Entity block
    public int EntityID { get; set; } = -1;
    public byte UnkE04 { get; set; }
    public byte UnkE05 { get; set; }
    public byte UnkE06 { get; set; }
    public byte UnkE07 { get; set; }
    public byte LanternID { get; set; }
    public byte LodParamID { get; set; }
    public byte UnkE0E { get; set; }
    public byte UnkE0F { get; set; }

    // Type-specific payloads (only one should be non-null based on Type)
    public GparamConfigJson? Gparam { get; set; }
    public SceneGparamConfigJson? SceneGparam { get; set; }

    // ObjectBase / DummyObject
    public string? CollisionName { get; set; }
    public sbyte? BreakTerm { get; set; }
    public sbyte? NetSyncType { get; set; }
    public bool? CollisionFilter { get; set; }
    public bool? SetMainObjStructureBooleans { get; set; }
    public short[]? AnimIDs { get; set; }                 // length 4
    public short[]? ModelSfxParamRelativeIDs { get; set; } // length 4

    // EnemyBase / DummyEnemy
    public int? ThinkParamID { get; set; }
    public int? NPCParamID { get; set; }
    public int? TalkID { get; set; }
    public int? CharaInitID { get; set; }
    public int? UnkT18 { get; set; }
    public short? UnkT20 { get; set; }
    public string[]? MovePointNames { get; set; } // length 8
    public int? InitAnimID { get; set; }
    public int? DamageAnimID { get; set; }

    // Collision
    public byte? HitFilterID { get; set; }
    public byte? SoundSpaceType { get; set; }
    public short? EnvLightMapSpotIndex { get; set; }
    public float? ReflectPlaneHeight { get; set; }
    public short? MapNameID { get; set; }
    public bool? DisableStart { get; set; }
    public byte? UnkT0B { get; set; }
    public int? DisableBonfireEntityID { get; set; }
    public int? PlayRegionID { get; set; }
    public short? LockCamParamID1 { get; set; }
    public short? LockCamParamID2 { get; set; }

    // ConnectCollision
    public byte[]? MapID { get; set; } // length 4 (bytes)

    public static PartJson From(MSBB.Part p)
    {
        var j = new PartJson
        {
            Type = p switch
            {
                MSBB.Part.MapPiece => "MapPiece",
                MSBB.Part.Object => "Object",
                MSBB.Part.Enemy => "Enemy",
                MSBB.Part.Player => "Player",
                MSBB.Part.Collision => "Collision",
                MSBB.Part.Navmesh => "Navmesh",
                MSBB.Part.DummyObject => "DummyObject",
                MSBB.Part.DummyEnemy => "DummyEnemy",
                MSBB.Part.ConnectCollision => "ConnectCollision",
                MSBB.Part.Other => "Other",
                _ => throw new NotSupportedException($"Unsupported part runtime type: {p.GetType()}")
            },
            Description = p.Description ?? "",
            Name = p.Name,
            InstanceID = p.InstanceID,
            ModelName = p.ModelName ?? "",
            SibPath = p.SibPath ?? "",
            Position = p.Position,
            Rotation = p.Rotation,
            Scale = p.Scale,

            DrawGroups = (uint[])p.DrawGroups.Clone(),
            DispGroups = (uint[])p.DispGroups.Clone(),
            BackreadGroups = (uint[])p.BackreadGroups.Clone(),

            EntityID = p.EntityID,
            UnkE04 = p.UnkE04,
            UnkE05 = p.UnkE05,
            UnkE06 = p.UnkE06,
            UnkE07 = p.UnkE07,
            LanternID = p.LanternID,
            LodParamID = p.LodParamID,
            UnkE0E = p.UnkE0E,
            UnkE0F = p.UnkE0F
        };

        switch (p)
        {
            case MSBB.Part.MapPiece mp:
                j.Gparam = GparamConfigJson.From(mp.Gparam);
                break;

            case MSBB.Part.Object obj:
                FillObjectBase(j, obj);
                break;

            case MSBB.Part.DummyObject dobj:
                FillObjectBase(j, dobj);
                break;

            case MSBB.Part.Enemy e:
                FillEnemyBase(j, e);
                break;

            case MSBB.Part.DummyEnemy de:
                FillEnemyBase(j, de);
                break;

            case MSBB.Part.Collision col:
                j.Gparam = GparamConfigJson.From(col.Gparam);
                j.SceneGparam = SceneGparamConfigJson.From(col.SceneGparam);
                j.HitFilterID = col.HitFilterID;
                j.SoundSpaceType = col.SoundSpaceType;
                j.EnvLightMapSpotIndex = col.EnvLightMapSpotIndex;
                j.ReflectPlaneHeight = col.ReflectPlaneHeight;
                j.MapNameID = col.MapNameID;
                j.DisableStart = col.DisableStart;
                j.UnkT0B = col.UnkT0B;
                j.DisableBonfireEntityID = col.DisableBonfireEntityID;
                j.PlayRegionID = col.PlayRegionID;
                j.LockCamParamID1 = col.LockCamParamID1;
                j.LockCamParamID2 = col.LockCamParamID2;
                break;

            case MSBB.Part.ConnectCollision cc:
                j.CollisionName = cc.CollisionName;
                j.MapID = (byte[])cc.MapID.Clone();
                break;

            // Player/Navmesh/Other have no extra fields
        }

        return j;
    }

    private static void FillObjectBase(PartJson j, MSBB.Part.ObjectBase obj)
    {
        j.Gparam = GparamConfigJson.From(obj.Gparam);
        j.CollisionName = obj.CollisionName;
        j.BreakTerm = obj.BreakTerm;
        j.NetSyncType = obj.NetSyncType;
        j.CollisionFilter = obj.CollisionFilter;
        j.SetMainObjStructureBooleans = obj.SetMainObjStructureBooleans;
        j.AnimIDs = (short[])obj.AnimIDs.Clone();
        j.ModelSfxParamRelativeIDs = (short[])obj.ModelSfxParamRelativeIDs.Clone();
    }

    private static void FillEnemyBase(PartJson j, MSBB.Part.EnemyBase e)
    {
        j.Gparam = GparamConfigJson.From(e.Gparam);
        j.ThinkParamID = e.ThinkParamID;
        j.NPCParamID = e.NPCParamID;
        j.TalkID = e.TalkID;
        j.CharaInitID = e.CharaInitID;
        j.UnkT18 = e.UnkT18;
        j.CollisionName = e.CollisionName;
        j.UnkT20 = e.UnkT20;
        j.MovePointNames = (string[])e.MovePointNames.Clone();
        j.InitAnimID = e.InitAnimID;
        j.DamageAnimID = e.DamageAnimID;
    }

    public MSBB.Part ToPart()
    {
        MSBB.Part p = Type switch
        {
            "MapPiece" => new MSBB.Part.MapPiece(),
            "Object" => new MSBB.Part.Object(),
            "Enemy" => new MSBB.Part.Enemy(),
            "Player" => new MSBB.Part.Player(),
            "Collision" => new MSBB.Part.Collision(),
            "Navmesh" => new MSBB.Part.Navmesh(),
            "DummyObject" => new MSBB.Part.DummyObject(),
            "DummyEnemy" => new MSBB.Part.DummyEnemy(),
            "ConnectCollision" => new MSBB.Part.ConnectCollision(),
            "Other" => new MSBB.Part.Other(),
            _ => throw new InvalidDataException($"Unknown Part type '{Type}'.")
        };

        // Common fields
        p.Description = Description ?? "";
        p.Name = Name;
        p.InstanceID = InstanceID;
        p.ModelName = ModelName ?? "";
        p.SibPath = SibPath ?? "";
        p.Position = Position;
        p.Rotation = Rotation;
        p.Scale = Scale;

        CopyFixed8(p.DrawGroups, DrawGroups, nameof(DrawGroups));
        CopyFixed8(p.DispGroups, DispGroups, nameof(DispGroups));
        CopyFixed8(p.BackreadGroups, BackreadGroups, nameof(BackreadGroups));

        p.EntityID = EntityID;
        p.UnkE04 = UnkE04;
        p.UnkE05 = UnkE05;
        p.UnkE06 = UnkE06;
        p.UnkE07 = UnkE07;
        p.LanternID = LanternID;
        p.LodParamID = LodParamID;
        p.UnkE0E = UnkE0E;
        p.UnkE0F = UnkE0F;

        // Type specifics
        switch (p)
        {
            case MSBB.Part.MapPiece mp:
                mp.Gparam = (Gparam ?? new GparamConfigJson()).ToGparamConfig();
                break;

            case MSBB.Part.ObjectBase ob:
                ob.Gparam = (Gparam ?? new GparamConfigJson()).ToGparamConfig();
                ob.CollisionName = CollisionName ?? "";
                ob.BreakTerm = BreakTerm ?? 0;
                ob.NetSyncType = NetSyncType ?? 0;
                ob.CollisionFilter = CollisionFilter ?? false;
                ob.SetMainObjStructureBooleans = SetMainObjStructureBooleans ?? false;

                if (AnimIDs is null || AnimIDs.Length != 4)
                    throw new InvalidDataException($"Part '{Name}': AnimIDs must be length 4.");
                if (ModelSfxParamRelativeIDs is null || ModelSfxParamRelativeIDs.Length != 4)
                    throw new InvalidDataException($"Part '{Name}': ModelSfxParamRelativeIDs must be length 4.");

                for (int i = 0; i < 4; i++) ob.AnimIDs[i] = AnimIDs[i];
                for (int i = 0; i < 4; i++) ob.ModelSfxParamRelativeIDs[i] = ModelSfxParamRelativeIDs[i];
                break;

            case MSBB.Part.EnemyBase eb:
                eb.Gparam = (Gparam ?? new GparamConfigJson()).ToGparamConfig();
                eb.ThinkParamID = ThinkParamID ?? -1;
                eb.NPCParamID = NPCParamID ?? -1;
                eb.TalkID = TalkID ?? -1;
                eb.CharaInitID = CharaInitID ?? -1;
                eb.UnkT18 = UnkT18 ?? 0;
                eb.CollisionName = CollisionName ?? "";
                eb.UnkT20 = UnkT20 ?? 0;

                if (MovePointNames is null || MovePointNames.Length != 8)
                    throw new InvalidDataException($"Part '{Name}': MovePointNames must be length 8.");
                for (int i = 0; i < 8; i++) eb.MovePointNames[i] = MovePointNames[i];

                eb.InitAnimID = InitAnimID ?? 0;
                eb.DamageAnimID = DamageAnimID ?? 0;
                break;

            case MSBB.Part.Collision col:
                col.Gparam = (Gparam ?? new GparamConfigJson()).ToGparamConfig();
                col.SceneGparam = (SceneGparam ?? new SceneGparamConfigJson()).ToSceneGparamConfig();
                col.HitFilterID = HitFilterID ?? 0;
                col.SoundSpaceType = SoundSpaceType ?? 0;
                col.EnvLightMapSpotIndex = EnvLightMapSpotIndex ?? 0;
                col.ReflectPlaneHeight = ReflectPlaneHeight ?? 0;
                col.MapNameID = MapNameID ?? -1;
                col.DisableStart = DisableStart ?? false;
                col.UnkT0B = UnkT0B ?? 0;
                col.DisableBonfireEntityID = DisableBonfireEntityID ?? -1;
                col.PlayRegionID = PlayRegionID ?? 0;
                col.LockCamParamID1 = LockCamParamID1 ?? -1;
                col.LockCamParamID2 = LockCamParamID2 ?? -1;
                break;

            case MSBB.Part.ConnectCollision cc:
                cc.CollisionName = CollisionName ?? "";
                if (MapID is null || MapID.Length != 4)
                    throw new InvalidDataException($"Part '{Name}': MapID must be 4 bytes.");
                for (int i = 0; i < 4; i++) cc.MapID[i] = MapID[i];
                break;
        }

        return p;
    }

    private static void CopyFixed8(uint[] target, uint[] source, string name)
    {
        if (source is null || source.Length != 8)
            throw new InvalidDataException($"{name} must be uint[8].");
        for (int i = 0; i < 8; i++)
            target[i] = source[i];
    }

    public void ValidateOrThrow()
    {
        if (string.IsNullOrWhiteSpace(Type))
            throw new InvalidDataException("Part entry missing 'type'.");
        if (string.IsNullOrWhiteSpace(Name))
            throw new InvalidDataException("Part entry missing 'name'.");

        if (DrawGroups is null || DrawGroups.Length != 8) throw new InvalidDataException($"Part '{Name}': DrawGroups must be uint[8].");
        if (DispGroups is null || DispGroups.Length != 8) throw new InvalidDataException($"Part '{Name}': DispGroups must be uint[8].");
        if (BackreadGroups is null || BackreadGroups.Length != 8) throw new InvalidDataException($"Part '{Name}': BackreadGroups must be uint[8].");

        // Type-specific required arrays
        if (Type is "Object" or "DummyObject")
        {
            if (AnimIDs is null || AnimIDs.Length != 4) throw new InvalidDataException($"Part '{Name}': AnimIDs must be length 4.");
            if (ModelSfxParamRelativeIDs is null || ModelSfxParamRelativeIDs.Length != 4) throw new InvalidDataException($"Part '{Name}': ModelSfxParamRelativeIDs must be length 4.");
        }
        if (Type is "Enemy" or "DummyEnemy")
        {
            if (MovePointNames is null || MovePointNames.Length != 8) throw new InvalidDataException($"Part '{Name}': MovePointNames must be length 8.");
        }
        if (Type is "ConnectCollision")
        {
            if (MapID is null || MapID.Length != 4) throw new InvalidDataException($"Part '{Name}': MapID must be 4 bytes.");
        }
    }
}

public sealed class GparamConfigJson
{
    public int LightSetID { get; set; }
    public int FogParamID { get; set; }
    public int LightScatteringID { get; set; }
    public int EnvMapID { get; set; }

    public static GparamConfigJson From(MSBB.Part.GparamConfig g) => new()
    {
        LightSetID = g.LightSetID,
        FogParamID = g.FogParamID,
        LightScatteringID = g.LightScatteringID,
        EnvMapID = g.EnvMapID
    };

    public MSBB.Part.GparamConfig ToGparamConfig() => new()
    {
        LightSetID = LightSetID,
        FogParamID = FogParamID,
        LightScatteringID = LightScatteringID,
        EnvMapID = EnvMapID
    };
}

public sealed class SceneGparamConfigJson
{
    public int Unk00 { get; set; }
    public int Unk04 { get; set; }
    public int Unk08 { get; set; }
    public int Unk0C { get; set; }
    public int Unk10 { get; set; }
    public int Unk14 { get; set; }
    public sbyte[] EventIDs { get; set; } = new sbyte[4];
    public float Unk40 { get; set; }

    public static SceneGparamConfigJson From(MSBB.Part.SceneGparamConfig s) => new()
    {
        Unk00 = s.Unk00,
        Unk04 = s.Unk04,
        Unk08 = s.Unk08,
        Unk0C = s.Unk0C,
        Unk10 = s.Unk10,
        Unk14 = s.Unk14,
        EventIDs = (sbyte[])s.EventIDs.Clone(),
        Unk40 = s.Unk40
    };

    public MSBB.Part.SceneGparamConfig ToSceneGparamConfig()
    {
        if (EventIDs is null || EventIDs.Length != 4)
            throw new InvalidDataException("SceneGparamConfig.EventIDs must be length 4.");

        var s = new MSBB.Part.SceneGparamConfig
        {
            Unk00 = Unk00,
            Unk04 = Unk04,
            Unk08 = Unk08,
            Unk0C = Unk0C,
            Unk10 = Unk10,
            Unk14 = Unk14,
            Unk40 = Unk40
        };
        for (int i = 0; i < 4; i++) s.EventIDs[i] = EventIDs[i];
        return s;
    }
}

public sealed class EventJson
{
    // Discriminator: Sound/SFX/Treasure/Generator/Message/ObjAct/SpawnPoint/MapOffset/Navmesh/Environment/WindSFX/PatrolInfo/DarkLock/PlatoonInfo/MultiSummon/Other
    public string Type { get; set; } = "";

    // Common Event fields
    public string Name { get; set; } = "";
    public int EventID { get; set; } = -1;

    // References by NAME (indices are derived by SoulsFormats on Write)
    public string PartName { get; set; } = "";
    public string RegionName { get; set; } = "";

    public int EntityID { get; set; } = -1;

    // 4 unknown bytes - preserved explicitly
    public byte UnkE0C { get; set; }
    public byte UnkE0D { get; set; }
    public byte UnkE0E { get; set; }
    public byte UnkE0F { get; set; }

    // Type-specific payloads
    public int? SoundType { get; set; }
    public int? SoundID { get; set; }

    public int? EffectID { get; set; }          // SFX/WindSFX
    public bool? StartDisabled { get; set; }    // SFX/Treasure

    // Treasure
    public string? TreasurePartName { get; set; }
    public int? ItemLot1 { get; set; }
    public int? ItemLot2 { get; set; }
    public int? ItemLot3 { get; set; }
    public int? UnkT1C { get; set; }
    public int? UnkT20 { get; set; }
    public int? UnkT24 { get; set; }
    public int? UnkT28 { get; set; }
    public int? UnkT2C { get; set; }
    public int? UnkT30 { get; set; }
    public int? UnkT34 { get; set; }
    public int? UnkT38 { get; set; }
    public int? UnkT3C { get; set; }
    public bool? InChest { get; set; }
    public short? UnkT42 { get; set; }
    public int? UnkT44 { get; set; }
    public int? UnkT48 { get; set; }

    // Generator
    public byte? MaxNum { get; set; }
    public sbyte? GenType { get; set; }
    public short? LimitNum { get; set; }
    public short? MinGenNum { get; set; }
    public short? MaxGenNum { get; set; }
    public float? MinInterval { get; set; }
    public float? MaxInterval { get; set; }
    public byte? InitialSpawnCount { get; set; }
    public byte? UnkT11 { get; set; }
    public byte? UnkT12 { get; set; }
    public byte? UnkT13 { get; set; }
    public string[]? SpawnPointNames { get; set; } // length 8
    public string[]? SpawnPartNames { get; set; }  // length 32

    // Message
    public short? MessageID { get; set; }
    public short? UnkT02 { get; set; }
    public bool? Hidden { get; set; }

    // ObjAct
    public int? ObjActEntityID { get; set; }
    public string? ObjActPartName { get; set; }
    public int? ObjActParamID { get; set; }
    public byte? ObjActState { get; set; }   // keep as byte to avoid enum drift
    public int? EventFlagID { get; set; }

    // SpawnPoint
    public string? SpawnPointName { get; set; }

    // MapOffset
    public Vector3? MapOffsetPosition { get; set; }
    public float? MapOffsetDegree { get; set; }

    // Navmesh
    public string? NavmeshRegionName { get; set; }

    // Environment
    public int? Env_UnkT00 { get; set; }
    public float? Env_UnkT04 { get; set; }
    public float? Env_UnkT08 { get; set; }
    public float? Env_UnkT0C { get; set; }
    public float? Env_UnkT10 { get; set; }
    public float? Env_UnkT14 { get; set; }

    // WindSFX
    public string? WindRegionName { get; set; }
    public float? Wind_UnkT08 { get; set; }

    // PatrolInfo
    public int? Patrol_UnkT00 { get; set; }
    public string[]? WalkPointNames { get; set; } // length 32

    // DarkLock: no type data (but it does have 4x int zeros internally; SoulsFormats handles it)

    // PlatoonInfo
    public int? PlatoonIDScriptActivate { get; set; }
    public int? PlatoonState { get; set; }
    public string[]? GroupPartsNames { get; set; } // length 32

    // MultiSummon
    public int? Multi_UnkT00 { get; set; }
    public short? Multi_UnkT04 { get; set; }
    public short? Multi_UnkT06 { get; set; }
    public short? Multi_UnkT08 { get; set; }
    public short? Multi_UnkT0A { get; set; }

    public static EventJson From(MSBB.Event e)
    {
        var j = new EventJson
        {
            Type = e switch
            {
                MSBB.Event.Sound => "Sound",
                MSBB.Event.SFX => "SFX",
                MSBB.Event.Treasure => "Treasure",
                MSBB.Event.Generator => "Generator",
                MSBB.Event.Message => "Message",
                MSBB.Event.ObjAct => "ObjAct",
                MSBB.Event.SpawnPoint => "SpawnPoint",
                MSBB.Event.MapOffset => "MapOffset",
                MSBB.Event.Navmesh => "Navmesh",
                MSBB.Event.Environment => "Environment",
                MSBB.Event.WindSFX => "WindSFX",
                MSBB.Event.PatrolInfo => "PatrolInfo",
                MSBB.Event.DarkLock => "DarkLock",
                MSBB.Event.PlatoonInfo => "PlatoonInfo",
                MSBB.Event.MultiSummon => "MultiSummon",
                MSBB.Event.Other => "Other",
                _ => throw new NotSupportedException($"Unsupported event runtime type: {e.GetType()}")
            },
            Name = e.Name,
            EventID = e.EventID,
            PartName = e.PartName ?? "",
            RegionName = e.RegionName ?? "",
            EntityID = e.EntityID,
            UnkE0C = e.UnkE0C,
            UnkE0D = e.UnkE0D,
            UnkE0E = e.UnkE0E,
            UnkE0F = e.UnkE0F
        };

        switch (e)
        {
            case MSBB.Event.Sound s:
                j.SoundType = s.SoundType;
                j.SoundID = s.SoundID;
                break;

            case MSBB.Event.SFX sfx:
                j.EffectID = sfx.EffectID;
                j.StartDisabled = sfx.StartDisabled;
                break;

            case MSBB.Event.Treasure t:
                j.TreasurePartName = t.TreasurePartName;
                j.ItemLot1 = t.ItemLot1;
                j.ItemLot2 = t.ItemLot2;
                j.ItemLot3 = t.ItemLot3;
                j.UnkT1C = t.UnkT1C;
                j.UnkT20 = t.UnkT20;
                j.UnkT24 = t.UnkT24;
                j.UnkT28 = t.UnkT28;
                j.UnkT2C = t.UnkT2C;
                j.UnkT30 = t.UnkT30;
                j.UnkT34 = t.UnkT34;
                j.UnkT38 = t.UnkT38;
                j.UnkT3C = t.UnkT3C;
                j.InChest = t.InChest;
                j.StartDisabled = t.StartDisabled;
                j.UnkT42 = t.UnkT42;
                j.UnkT44 = t.UnkT44;
                j.UnkT48 = t.UnkT48;
                break;

            case MSBB.Event.Generator g:
                j.MaxNum = g.MaxNum;
                j.GenType = g.GenType;
                j.LimitNum = g.LimitNum;
                j.MinGenNum = g.MinGenNum;
                j.MaxGenNum = g.MaxGenNum;
                j.MinInterval = g.MinInterval;
                j.MaxInterval = g.MaxInterval;
                j.InitialSpawnCount = g.InitialSpawnCount;
                j.UnkT11 = g.UnkT11;
                j.UnkT12 = g.UnkT12;
                j.UnkT13 = g.UnkT13;
                j.SpawnPointNames = (string[])g.SpawnPointNames.Clone();
                j.SpawnPartNames = (string[])g.SpawnPartNames.Clone();
                break;

            case MSBB.Event.Message m:
                j.MessageID = m.MessageID;
                j.UnkT02 = m.UnkT02;
                j.Hidden = m.Hidden;
                break;

            case MSBB.Event.ObjAct oa:
                j.ObjActEntityID = oa.ObjActEntityID;
                j.ObjActPartName = oa.ObjActPartName;
                j.ObjActParamID = oa.ObjActParamID;
                j.ObjActState = (byte)oa.ObjActState;
                j.EventFlagID = oa.EventFlagID;
                break;

            case MSBB.Event.SpawnPoint sp:
                j.SpawnPointName = sp.SpawnPointName;
                break;

            case MSBB.Event.MapOffset mo:
                j.MapOffsetPosition = mo.Position;
                j.MapOffsetDegree = mo.Degree;
                break;

            case MSBB.Event.Navmesh nm:
                j.NavmeshRegionName = nm.NavmeshRegionName;
                break;

            case MSBB.Event.Environment env:
                j.Env_UnkT00 = env.UnkT00;
                j.Env_UnkT04 = env.UnkT04;
                j.Env_UnkT08 = env.UnkT08;
                j.Env_UnkT0C = env.UnkT0C;
                j.Env_UnkT10 = env.UnkT10;
                j.Env_UnkT14 = env.UnkT14;
                break;

            case MSBB.Event.WindSFX w:
                j.EffectID = w.EffectID;
                j.WindRegionName = w.WindRegionName;
                j.Wind_UnkT08 = w.UnkT08;
                break;

            case MSBB.Event.PatrolInfo pi:
                j.Patrol_UnkT00 = pi.UnkT00;
                j.WalkPointNames = (string[])pi.WalkPointNames.Clone();
                break;

            case MSBB.Event.PlatoonInfo pl:
                j.PlatoonIDScriptActivate = pl.PlatoonIDScriptActivate;
                j.PlatoonState = pl.State;
                j.GroupPartsNames = (string[])pl.GroupPartsNames.Clone();
                break;

            case MSBB.Event.MultiSummon ms:
                j.Multi_UnkT00 = ms.UnkT00;
                j.Multi_UnkT04 = ms.UnkT04;
                j.Multi_UnkT06 = ms.UnkT06;
                j.Multi_UnkT08 = ms.UnkT08;
                j.Multi_UnkT0A = ms.UnkT0A;
                break;
        }

        return j;
    }

    public MSBB.Event ToEvent()
    {
        MSBB.Event e = Type switch
        {
            "Sound" => new MSBB.Event.Sound(),
            "SFX" => new MSBB.Event.SFX(),
            "Treasure" => new MSBB.Event.Treasure(),
            "Generator" => new MSBB.Event.Generator(),
            "Message" => new MSBB.Event.Message(),
            "ObjAct" => new MSBB.Event.ObjAct(),
            "SpawnPoint" => new MSBB.Event.SpawnPoint(),
            "MapOffset" => new MSBB.Event.MapOffset(),
            "Navmesh" => new MSBB.Event.Navmesh(),
            "Environment" => new MSBB.Event.Environment(),
            "WindSFX" => new MSBB.Event.WindSFX(),
            "PatrolInfo" => new MSBB.Event.PatrolInfo(),
            "DarkLock" => new MSBB.Event.DarkLock(),
            "PlatoonInfo" => new MSBB.Event.PlatoonInfo(),
            "MultiSummon" => new MSBB.Event.MultiSummon(),
            "Other" => new MSBB.Event.Other(),
            _ => throw new InvalidDataException($"Unknown Event type '{Type}'.")
        };

        e.Name = Name;
        e.EventID = EventID;
        e.PartName = PartName ?? "";
        e.RegionName = RegionName ?? "";
        e.EntityID = EntityID;

        e.UnkE0C = UnkE0C;
        e.UnkE0D = UnkE0D;
        e.UnkE0E = UnkE0E;
        e.UnkE0F = UnkE0F;

        switch (e)
        {
            case MSBB.Event.Sound s:
                s.SoundType = SoundType ?? 0;
                s.SoundID = SoundID ?? 0;
                break;

            case MSBB.Event.SFX sfx:
                sfx.EffectID = EffectID ?? 0;
                sfx.StartDisabled = StartDisabled ?? false;
                break;

            case MSBB.Event.Treasure t:
                t.TreasurePartName = TreasurePartName ?? "";
                t.ItemLot1 = ItemLot1 ?? 0;
                t.ItemLot2 = ItemLot2 ?? 0;
                t.ItemLot3 = ItemLot3 ?? 0;
                t.UnkT1C = UnkT1C ?? 0;
                t.UnkT20 = UnkT20 ?? 0;
                t.UnkT24 = UnkT24 ?? 0;
                t.UnkT28 = UnkT28 ?? 0;
                t.UnkT2C = UnkT2C ?? 0;
                t.UnkT30 = UnkT30 ?? 0;
                t.UnkT34 = UnkT34 ?? 0;
                t.UnkT38 = UnkT38 ?? 0;
                t.UnkT3C = UnkT3C ?? 0;
                t.InChest = InChest ?? false;
                t.StartDisabled = StartDisabled ?? false;
                t.UnkT42 = UnkT42 ?? 0;
                t.UnkT44 = UnkT44 ?? 0;
                t.UnkT48 = UnkT48 ?? 0;
                break;

            case MSBB.Event.Generator g:
                g.MaxNum = MaxNum ?? 0;
                g.GenType = GenType ?? 0;
                g.LimitNum = LimitNum ?? 0;
                g.MinGenNum = MinGenNum ?? 0;
                g.MaxGenNum = MaxGenNum ?? 0;
                g.MinInterval = MinInterval ?? 0;
                g.MaxInterval = MaxInterval ?? 0;
                g.InitialSpawnCount = InitialSpawnCount ?? 0;
                g.UnkT11 = UnkT11 ?? 0;
                g.UnkT12 = UnkT12 ?? 0;
                g.UnkT13 = UnkT13 ?? 0;

                if (SpawnPointNames is null || SpawnPointNames.Length != 8)
                    throw new InvalidDataException($"Generator '{Name}': SpawnPointNames must be length 8.");
                if (SpawnPartNames is null || SpawnPartNames.Length != 32)
                    throw new InvalidDataException($"Generator '{Name}': SpawnPartNames must be length 32.");

                for (int i = 0; i < 8; i++) g.SpawnPointNames[i] = SpawnPointNames[i];
                for (int i = 0; i < 32; i++) g.SpawnPartNames[i] = SpawnPartNames[i];
                break;

            case MSBB.Event.Message m:
                m.MessageID = MessageID ?? 0;
                m.UnkT02 = UnkT02 ?? 0;
                m.Hidden = Hidden ?? false;
                break;

            case MSBB.Event.ObjAct oa:
                oa.ObjActEntityID = ObjActEntityID ?? -1;
                oa.ObjActPartName = ObjActPartName ?? "";
                oa.ObjActParamID = ObjActParamID ?? -1;
                oa.ObjActState = (MSBB.Event.ObjAct.StateType)(ObjActState ?? 0);
                oa.EventFlagID = EventFlagID ?? -1;
                break;

            case MSBB.Event.SpawnPoint sp:
                sp.SpawnPointName = SpawnPointName ?? "";
                break;

            case MSBB.Event.MapOffset mo:
                mo.Position = MapOffsetPosition ?? Vector3.Zero;
                mo.Degree = MapOffsetDegree ?? 0f;
                break;

            case MSBB.Event.Navmesh nm:
                nm.NavmeshRegionName = NavmeshRegionName ?? "";
                break;

            case MSBB.Event.Environment env:
                env.UnkT00 = Env_UnkT00 ?? 0;
                env.UnkT04 = Env_UnkT04 ?? 0;
                env.UnkT08 = Env_UnkT08 ?? 0;
                env.UnkT0C = Env_UnkT0C ?? 0;
                env.UnkT10 = Env_UnkT10 ?? 0;
                env.UnkT14 = Env_UnkT14 ?? 0;
                break;

            case MSBB.Event.WindSFX w:
                w.EffectID = EffectID ?? 0;
                w.WindRegionName = WindRegionName ?? "";
                w.UnkT08 = Wind_UnkT08 ?? 0;
                break;

            case MSBB.Event.PatrolInfo pi:
                pi.UnkT00 = Patrol_UnkT00 ?? 0;
                if (WalkPointNames is null || WalkPointNames.Length != 32)
                    throw new InvalidDataException($"PatrolInfo '{Name}': WalkPointNames must be length 32.");
                for (int i = 0; i < 32; i++) pi.WalkPointNames[i] = WalkPointNames[i];
                break;

            case MSBB.Event.PlatoonInfo pl:
                pl.PlatoonIDScriptActivate = PlatoonIDScriptActivate ?? 0;
                pl.State = PlatoonState ?? 0;
                if (GroupPartsNames is null || GroupPartsNames.Length != 32)
                    throw new InvalidDataException($"PlatoonInfo '{Name}': GroupPartsNames must be length 32.");
                for (int i = 0; i < 32; i++) pl.GroupPartsNames[i] = GroupPartsNames[i];
                break;

            case MSBB.Event.MultiSummon ms:
                ms.UnkT00 = Multi_UnkT00 ?? 0;
                ms.UnkT04 = Multi_UnkT04 ?? 0;
                ms.UnkT06 = Multi_UnkT06 ?? 0;
                ms.UnkT08 = Multi_UnkT08 ?? 0;
                ms.UnkT0A = Multi_UnkT0A ?? 0;
                break;

            // DarkLock / Other: no type data
        }

        return e;
    }

    public void ValidateOrThrow()
    {
        if (string.IsNullOrWhiteSpace(Type))
            throw new InvalidDataException("Event entry missing 'type'.");
        if (string.IsNullOrWhiteSpace(Name))
            throw new InvalidDataException("Event entry missing 'name'.");
    }
}

#endregion

#region JSON converters (Vector3, fixed arrays)

public sealed class Vector3Converter : JsonConverter<Vector3>
{
    public override Vector3 Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        // Accept either [x,y,z] or {"x":..,"y":..,"z":..}
        if (reader.TokenType == JsonTokenType.StartArray)
        {
            reader.Read(); float x = reader.GetSingle();
            reader.Read(); float y = reader.GetSingle();
            reader.Read(); float z = reader.GetSingle();
            reader.Read(); // EndArray
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

// Example strict converters (optional) if you want to enforce length
public sealed class UInt32Array8Converter : JsonConverter<uint[]>
{
    public override uint[] Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
            throw new JsonException("Expected array for uint[8].");

        var list = new List<uint>(8);
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndArray)
                break;

            list.Add(reader.GetUInt32());
        }

        if (list.Count != 8)
            throw new JsonException($"Expected uint[8], got {list.Count}.");

        return list.ToArray();
    }

    public override void Write(Utf8JsonWriter writer, uint[] value, JsonSerializerOptions options)
    {
        if (value is null || value.Length != 8)
            throw new JsonException("Expected uint[8].");

        writer.WriteStartArray();
        for (int i = 0; i < 8; i++)
            writer.WriteNumberValue(value[i]);
        writer.WriteEndArray();
    }
}

public sealed class ByteArray4Converter : JsonConverter<byte[]>
{
    public override byte[] Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartArray)
            throw new JsonException("Expected array for byte[4].");

        var list = new List<byte>(4);
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndArray)
                break;

            // JSON numbers are Int32; enforce 0..255
            int n = reader.GetInt32();
            if ((uint)n > 255) throw new JsonException("byte value out of range.");
            list.Add((byte)n);
        }

        if (list.Count != 4)
            throw new JsonException($"Expected byte[4], got {list.Count}.");

        return list.ToArray();
    }

    public override void Write(Utf8JsonWriter writer, byte[] value, JsonSerializerOptions options)
    {
        if (value is null || value.Length != 4)
            throw new JsonException("Expected byte[4].");

        writer.WriteStartArray();
        for (int i = 0; i < 4; i++)
            writer.WriteNumberValue(value[i]);
        writer.WriteEndArray();
    }
}

#endregion