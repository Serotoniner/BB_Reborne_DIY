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
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SoulsFormats;

#nullable enable

// FxrRoundTripTool
//
// Goal:
// - Keep lossless roundtrip from raw bytes.
// - Support safe JSON-driven rebuild edits without ambiguous float-slot mapping.
// - Separate analysis-only float scans from explicit editable patch targets.
//
// Important design change:
// - FloatScans are now ANALYSIS ONLY.
// - Rebuild no longer writes FloatScans.values back into the file.
// - Editable changes are applied only from explicit Patches.
//
// Why:
// - A scan like bytes [07 00 00 00][00 00 00 00][00 00 20 42][00 00 00 00]
//   may summarize plausible floats as [0, 40, 0], but that does NOT mean those
//   values occupy slots 0,1,2 in sequence. The first 4-byte slot may be a non-float ID.
// - This also means earlier interpretation of neat R/G/B/I tuples must remain tentative
//   until the bytes are known to be real float fields rather than mixed typed payloads.
//
// Commands:
//   info      <input.fxr>
//   dump      <input.fxr>  <output.json>
//   rebuild   <input.json> <output.fxr>
//   verify    <input.fxr>  <temp.json> <rebuilt.fxr>
//   probe     <input.fxr>
//   floatscan <input.fxr> [offsetHexOrDec] [lengthHexOrDec]
//   graph     <input.fxr>
//   compare   <input1.fxr> <input2.fxr> [more.fxrs...]
//   chaindiff <input1.fxr> <input2.fxr> [more.fxrs...] [--pair 11/11] [--key 11/11#1] [--maxchains 24] [--maxwords 16] [--maxchildren 9999] [--noellipsis]
//
// Safe editable JSON path:
//   patches: [
//     { "offset": 21120, "kind": "float32", "valueFloat32": 80.0 }
//   ]

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
                case "info":
                    if (args.Length != 2) return Usage("info requires: <input.fxr>");
                    Info(args[1]);
                    return 0;

                case "dump":
                    if (args.Length != 3) return Usage("dump requires: <input.fxr> <output.json>");
                    Dump(args[1], args[2]);
                    return 0;

                case "rebuild":
                    if (args.Length != 3) return Usage("rebuild requires: <input.json> <output.fxr>");
                    Rebuild(args[1], args[2]);
                    return 0;

                case "verify":
                    if (args.Length != 4) return Usage("verify requires: <input.fxr> <temp.json> <rebuilt.fxr>");
                    Verify(args[1], args[2], args[3]);
                    return 0;

                case "probe":
                    if (args.Length != 2) return Usage("probe requires: <input.fxr>");
                    Probe(args[1]);
                    return 0;

                case "floatscan":
                    if (args.Length < 2 || args.Length > 4) return Usage("floatscan requires: <input.fxr> [offsetHexOrDec] [lengthHexOrDec]");
                    FloatScanCmd(args);
                    return 0;

                case "graph":
                    if (args.Length != 2) return Usage("graph requires: <input.fxr>");
                    GraphCmd(args[1]);
                    return 0;

                case "compare":
                    if (args.Length < 3) return Usage("compare requires: <input1.fxr> <input2.fxr> [more.fxrs...]");
                    CompareCmd(args.Skip(1).ToArray());
                    return 0;

                case "chaindiff":
                    if (args.Length < 3) return Usage("chaindiff requires: <input1.fxr> <input2.fxr> [more.fxrs...] [--pair 11/11] [--key 11/11#1] [--maxchains 24] [--maxwords 16] [--maxchildren 9999] [--noellipsis]");
                    ChainDiffCmd(args.Skip(1).ToArray());
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
@"FxrRoundTripTool

Commands:
  info      <input.fxr>
  dump      <input.fxr>  <output.json>
  rebuild   <input.json> <output.fxr>
  verify    <input.fxr>  <temp.json> <rebuilt.fxr>
  probe     <input.fxr>
  floatscan <input.fxr> [offsetHexOrDec] [lengthHexOrDec]
  graph     <input.fxr>
  compare   <input1.fxr> <input2.fxr> [more.fxrs...]
  chaindiff <input1.fxr> <input2.fxr> [more.fxrs...] [--pair 11/11] [--key 11/11#1] [--maxchains 24] [--maxwords 16] [--maxchildren 9999] [--noellipsis]
");
        return 2;
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: true) },
    };

    private static void Info(string path)
    {
        var doc = FxrDumpDoc.ReadFromFile(path);

        Console.WriteLine($"File:              {path}");
        Console.WriteLine($"Schema:            {doc.Schema}");
        Console.WriteLine($"Magic:             {doc.Magic}");
        Console.WriteLine($"DetectedFamily:    {doc.DetectedFamily}");
        Console.WriteLine($"FileSize:          0x{doc.FileSize:X}");
        Console.WriteLine($"HeaderByteCount:   0x{doc.HeaderByteCount:X}");
        Console.WriteLine();

        if (doc.Fxr23 is not null)
        {
            Console.WriteLine("FXR2/3-style leading words:");
            Console.WriteLine($"  ZeroAt0x04:      {doc.Fxr23.ZeroAt04}");
            Console.WriteLine($"  Version16:       {doc.Fxr23.Version16}");
            Console.WriteLine($"  HeaderUnk08:     {doc.Fxr23.HeaderUnk08}");
            Console.WriteLine($"  HeaderUnk0C:     {doc.Fxr23.HeaderUnk0C}");
            Console.WriteLine();
        }

        if (doc.Fxr2Layout is not null)
        {
            Console.WriteLine("FXR2 layout hints:");
            Console.WriteLine($"  RootOffsetA:            0x{doc.Fxr2Layout.RootOffsetA:X}");
            Console.WriteLine($"  RootCountA:             {doc.Fxr2Layout.RootCountA}");
            Console.WriteLine($"  RootOffsetB:            0x{doc.Fxr2Layout.RootOffsetB:X}");
            Console.WriteLine($"  EffectId:               {doc.Fxr2Layout.EffectId}");
            Console.WriteLine($"  FirstDataOffset:        0x{doc.Fxr2Layout.FirstDataOffset:X}");
            Console.WriteLine($"  DescriptorTableStart:   0x{doc.Fxr2Layout.DescriptorTableStart:X}");
            Console.WriteLine();
        }

        if (doc.GraphStats is not null)
        {
            Console.WriteLine("Graph/root-index hints:");
            Console.WriteLine($"  RootIndex entries:       {doc.GraphStats.RootIndexCount}");
            Console.WriteLine($"  Valid unique offsets:    {doc.GraphStats.UniqueValidOffsetCount}");
            Console.WriteLine($"  Graph records:           {doc.GraphStats.RecordCount}");
            Console.WriteLine($"  Strict root edges:       {doc.GraphStats.StrictEdgeCount}");
            Console.WriteLine($"  Loose offset candidates: {doc.GraphStats.LooseOffsetCandidateCount}");
            Console.WriteLine($"  Small enum/count words:  {doc.GraphStats.SmallEnumOrCountWordCount}");
            Console.WriteLine($"  Descriptor chains:       {doc.GraphStats.GraphChainCount}");
            Console.WriteLine($"  Loose payload previews:  {doc.GraphStats.LoosePayloadPreviewCount}");
            Console.WriteLine($"  Recursive loose nodes:   {doc.GraphStats.RecursiveLoosePayloadNodeCount}");
            Console.WriteLine($"  Recursive max depth:     {doc.GraphStats.RecursiveLoosePayloadMaxDepth}");
            Console.WriteLine($"  Root index byte range:   0x{doc.GraphStats.RootIndexOffset:X8}..0x{doc.GraphStats.RootIndexEndOffset:X8}");
            Console.WriteLine();
        }

        if (doc.BSection is not null)
        {
            Console.WriteLine("B-section hints:");
            Console.WriteLine($"  Range:                 0x{doc.BSection.StartOffset:X8}..0x{doc.BSection.EndOffset:X8}");
            Console.WriteLine($"  Records:               {doc.BSection.Records.Count}");
            Console.WriteLine($"  References:            {doc.BSection.References.Count}");
            Console.WriteLine($"  Unique target offsets:  {doc.BSection.UniqueTargetCount}");
            Console.WriteLine();
        }

        Console.WriteLine($"FloatScans (analysis only): {doc.FloatScans.Count}");
        foreach (var scan in doc.FloatScans.Take(16))
        {
            Console.WriteLine($"  0x{scan.StartOffset:X8} size=0x{scan.RegionSize:X} plausible={scan.PlausibleFloatCount} density={scan.PlausibleDensity:F2}");
            Console.WriteLine($"    values: {string.Join(", ", scan.Values.Select(v => v.ToString("0.######", CultureInfo.InvariantCulture)))}");
            Console.WriteLine($"    slotKinds: {string.Join(", ", scan.SlotKinds)}");
        }

        Console.WriteLine();
        Console.WriteLine($"Editable patches: {doc.Patches.Count}");
        foreach (var p in doc.Patches.Take(16))
            Console.WriteLine($"  0x{p.Offset:X8} {p.Kind} {p.DescribeValue()}");
    }

    private static void Dump(string input, string output)
    {
        var doc = FxrDumpDoc.ReadFromFile(input);
        string json = JsonSerializer.Serialize(doc, JsonOpts);
        File.WriteAllText(output, json);

        Console.WriteLine($"Dumped: {input}");
        Console.WriteLine($"   To:  {output}");
    }

    private static void Rebuild(string inputJson, string outputFxr)
    {
        string json = File.ReadAllText(inputJson);
        var doc = JsonSerializer.Deserialize<FxrDumpDoc>(json, JsonOpts)
            ?? throw new InvalidDataException("Failed to deserialize JSON.");

        doc.ValidateOrThrow();

        byte[] bytes = Convert.FromBase64String(doc.RawFileBase64);
        int patchesApplied = ApplyExplicitPatches(doc, bytes);

        File.WriteAllBytes(outputFxr, bytes);

        Console.WriteLine($"Rebuilt: {inputJson}");
        Console.WriteLine($"    To:  {outputFxr}");
        Console.WriteLine($"Explicit patches applied: {patchesApplied}");
    }

    private static void Verify(string inputFxr, string tempJson, string rebuiltFxr)
    {
        var doc = FxrDumpDoc.ReadFromFile(inputFxr);
        File.WriteAllText(tempJson, JsonSerializer.Serialize(doc, JsonOpts));

        byte[] bytes = Convert.FromBase64String(doc.RawFileBase64);
        int patchesApplied = ApplyExplicitPatches(doc, bytes);
        File.WriteAllBytes(rebuiltFxr, bytes);

        byte[] a = File.ReadAllBytes(inputFxr);
        byte[] b = File.ReadAllBytes(rebuiltFxr);

        if (patchesApplied == 0)
        {
            if (a.Length != b.Length)
                throw new InvalidDataException($"VERIFY FAIL: size mismatch {a.Length} != {b.Length}");

            for (int i = 0; i < a.Length; i++)
            {
                if (a[i] != b[i])
                    throw new InvalidDataException($"VERIFY FAIL: first mismatch at 0x{i:X}: {a[i]:X2} != {b[i]:X2}");
            }

            Console.WriteLine("VERIFY OK:");
            Console.WriteLine($"  Input:   {inputFxr}");
            Console.WriteLine($"  Dump:    {tempJson}");
            Console.WriteLine($"  Rebuilt: {rebuiltFxr}");
            Console.WriteLine($"  Match:   byte-identical");
        }
        else
        {
            Console.WriteLine("VERIFY NOTE:");
            Console.WriteLine($"  Input:   {inputFxr}");
            Console.WriteLine($"  Dump:    {tempJson}");
            Console.WriteLine($"  Rebuilt: {rebuiltFxr}");
            Console.WriteLine($"  Explicit JSON patches applied: {patchesApplied}");
            Console.WriteLine("  Byte-identical comparison skipped because the JSON contains explicit changes.");
        }
    }

    private static int ApplyExplicitPatches(FxrDumpDoc doc, byte[] bytes)
    {
        int patches = 0;

        foreach (var patch in doc.Patches)
        {
            patch.ValidateOrThrow(bytes.Length);
            switch (patch.Kind)
            {
                case PatchKind.Float32:
                    {
                        byte[] raw = BitConverter.GetBytes(patch.ValueFloat32 ?? throw new InvalidDataException($"Missing valueFloat32 for patch at 0x{patch.Offset:X8}"));
                        Buffer.BlockCopy(raw, 0, bytes, patch.Offset, 4);
                        patches++;
                        break;
                    }
                case PatchKind.UInt32:
                    {
                        byte[] raw = BitConverter.GetBytes(patch.ValueUInt32 ?? throw new InvalidDataException($"Missing valueUInt32 for patch at 0x{patch.Offset:X8}"));
                        Buffer.BlockCopy(raw, 0, bytes, patch.Offset, 4);
                        patches++;
                        break;
                    }
                case PatchKind.Bytes:
                    {
                        byte[] raw = patch.ValueBytes is null ? throw new InvalidDataException($"Missing valueBytes for patch at 0x{patch.Offset:X8}") : Convert.FromBase64String(patch.ValueBytes);
                        Buffer.BlockCopy(raw, 0, bytes, patch.Offset, raw.Length);
                        patches++;
                        break;
                    }
                default:
                    throw new InvalidDataException($"Unsupported patch kind: {patch.Kind}");
            }
        }

        return patches;
    }

    private static void Probe(string path)
    {
        var doc = FxrDumpDoc.ReadFromFile(path);
        Console.WriteLine($"Probe: {path}");
        Console.WriteLine($"Detected family: {doc.DetectedFamily}");
        Console.WriteLine();
        foreach (var scan in doc.FloatScans.Take(32))
        {
            Console.WriteLine($"0x{scan.StartOffset:X8} preview={scan.Preview}");
            Console.WriteLine($"  values={string.Join(", ", scan.Values.Select(v => v.ToString("0.######", CultureInfo.InvariantCulture)))}");
            Console.WriteLine($"  slotKinds={string.Join(", ", scan.SlotKinds)}");
        }
    }

    private static void FloatScanCmd(string[] args)
    {
        string path = args[1];
        byte[] bytes = File.ReadAllBytes(path);
        int fileSize = bytes.Length;

        int start = 0;
        int length = fileSize;
        if (args.Length >= 3)
            start = ParseIntFlexible(args[2]);
        if (args.Length >= 4)
            length = ParseIntFlexible(args[3]);

        if (start < 0 || start >= fileSize)
            throw new ArgumentOutOfRangeException(nameof(start));
        if (length < 0)
            throw new ArgumentOutOfRangeException(nameof(length));
        if (start + length > fileSize)
            length = fileSize - start;

        var scans = StructuredFloatScanner.ScanRegion(bytes, start, length);
        Console.WriteLine($"FloatScan: {path}");
        Console.WriteLine($"  region: 0x{start:X8} .. 0x{start + length:X8}");
        Console.WriteLine();
        foreach (var scan in scans.Take(64))
        {
            Console.WriteLine($"0x{scan.StartOffset:X8} size=0x{scan.RegionSize:X} plausible={scan.PlausibleFloatCount} density={scan.PlausibleDensity:F2}");
            Console.WriteLine($"  preview:   {scan.Preview}");
            Console.WriteLine($"  values:    {string.Join(", ", scan.Values.Select(v => v.ToString("0.######", CultureInfo.InvariantCulture)))}");
            Console.WriteLine($"  slotKinds: {string.Join(", ", scan.SlotKinds)}");
        }
    }


    private static void GraphCmd(string path)
    {
        var doc = FxrDumpDoc.ReadFromFile(path);

        Console.WriteLine($"Graph: {path}");
        if (doc.Fxr2Layout is null || doc.GraphStats is null)
        {
            Console.WriteLine("No FXR2 graph/root-index hints available.");
            return;
        }

        Console.WriteLine($"  EffectId:                    {doc.Fxr2Layout.EffectId}");
        Console.WriteLine($"  RootOffsetA:                 0x{doc.Fxr2Layout.RootOffsetA:X8}");
        Console.WriteLine($"  RootCountA:                  {doc.Fxr2Layout.RootCountA}");
        Console.WriteLine($"  RootOffsetB:                 0x{doc.Fxr2Layout.RootOffsetB:X8}");
        Console.WriteLine($"  RootIndex valid:             {doc.GraphStats.ValidRootIndexCount}/{doc.GraphStats.RootIndexCount}");
        Console.WriteLine($"  Unique valid offsets:        {doc.GraphStats.UniqueValidOffsetCount}");
        Console.WriteLine($"  Records:                     {doc.GraphStats.RecordCount}");
        Console.WriteLine($"  Strict root-offset edges:    {doc.GraphStats.StrictEdgeCount}");
        Console.WriteLine($"  Loose offset candidates:     {doc.GraphStats.LooseOffsetCandidateCount}");
        Console.WriteLine($"  Small enum/count words:      {doc.GraphStats.SmallEnumOrCountWordCount}");
        Console.WriteLine($"  Descriptor chains:           {doc.GraphStats.GraphChainCount}");
        Console.WriteLine($"  Loose payload previews:      {doc.GraphStats.LoosePayloadPreviewCount}");
        Console.WriteLine($"  Recursive loose nodes:       {doc.GraphStats.RecursiveLoosePayloadNodeCount}");
        Console.WriteLine($"  Recursive loose unique:      {doc.GraphStats.RecursiveLoosePayloadUniqueTargetCount}");
        Console.WriteLine($"  Recursive max depth:         {doc.GraphStats.RecursiveLoosePayloadMaxDepth}");
        if (doc.BSection is not null)
        {
            Console.WriteLine($"  B-section range:             0x{doc.BSection.StartOffset:X8}..0x{doc.BSection.EndOffset:X8}");
            Console.WriteLine($"  B-section refs:              {doc.BSection.References.Count}");
            Console.WriteLine($"  B-section targets:           {doc.BSection.UniqueTargetCount}");
            Console.WriteLine($"  B-section records:           {doc.BSection.Records.Count}");
        }
        Console.WriteLine();

        Console.WriteLine("Record sizes:");
        foreach (var kv in doc.GraphStats.RecordsBySize.OrderByDescending(kv => kv.Value).ThenBy(kv => int.Parse(kv.Key, CultureInfo.InvariantCulture)).Take(16))
            Console.WriteLine($"  size {kv.Key,5}: {kv.Value}");

        Console.WriteLine();
        Console.WriteLine("Record shapes:");
        foreach (var kv in doc.GraphStats.RecordsByShape.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(24))
            Console.WriteLine($"  {kv.Value,5}  {kv.Key}");

        Console.WriteLine();
        Console.WriteLine("Descriptor type-pair groups:");
        foreach (var kv in doc.GraphStats.DescriptorRecordsByTypePair.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(64))
            Console.WriteLine($"  {kv.Key,9}: {kv.Value}");

        if (doc.BSection is not null)
        {
            Console.WriteLine();
            Console.WriteLine("B-section record shapes:");
            foreach (var kv in doc.BSection.RecordsByShape.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(16))
                Console.WriteLine($"  {kv.Value,5}  {kv.Key}");

            Console.WriteLine();
            Console.WriteLine("B-section first-word groups:");
            foreach (var kv in doc.BSection.RecordsByFirstWord.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(16))
                Console.WriteLine($"  {kv.Value,5}  {kv.Key}");

            Console.WriteLine();
            Console.WriteLine("B-section referenced type-pairs:");
            foreach (var kv in doc.BSection.ReferencesByTypePair.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(32))
                Console.WriteLine($"  {kv.Key,9}: {kv.Value}");

            Console.WriteLine();
            Console.WriteLine("First B-section records:");
            foreach (var b in doc.BSection.Records.Take(24))
            {
                Console.WriteLine($"  #{b.Index,4} 0x{b.Offset:X8} size=0x{b.Size:X} refs={b.ReferenceCount} hash={b.PreviewHash64} shape={b.ShapeSignature}");
                if (b.SourceTypePairs.Count > 0)
                    Console.WriteLine($"       source pairs: {string.Join(", ", b.SourceTypePairs.Take(8))}");
                Console.WriteLine($"       words: {string.Join(", ", b.Words.Take(8).Select(DescribeGraphPreviewWord))}");
                Console.WriteLine($"       bytes: {b.PreviewHex}");
            }

            Console.WriteLine();
            Console.WriteLine("First B-section references:");
            foreach (var r in doc.BSection.References.Take(32))
            {
                string pair = string.IsNullOrWhiteSpace(r.TypePair) ? "-" : r.TypePair!;
                string desc = r.DescriptorOffset is null ? "-" : $"0x{r.DescriptorOffset.Value:X8}";
                Console.WriteLine($"  target=0x{r.TargetOffset:X8} from={r.SourceKind} 0x{r.SourceOffset:X8}+slot{r.SourceSlot} pair={pair} desc={desc}");
            }
        }

        Console.WriteLine();
        Console.WriteLine("First descriptor chains:");
        foreach (var chain in doc.GraphChains.Take(32))
        {
            string payload = chain.PayloadIndex is null
                ? $"0x{chain.PayloadOffset:X8} <not in root index>"
                : $"#{chain.PayloadIndex.Value} 0x{chain.PayloadOffset:X8} size=0x{chain.PayloadSize:X}";
            Console.WriteLine($"  desc #{chain.DescriptorIndex,4} 0x{chain.DescriptorOffset:X8} pair={chain.TypePair,-9} -> payload {payload}");
            if (chain.ChildStrictOffsets.Count > 0)
                Console.WriteLine($"       child strict -> {string.Join(", ", chain.ChildStrictOffsets.Take(8).Select(v => $"0x{v:X8}"))}");
            if (chain.ChildLooseOffsetCandidates.Count > 0)
                Console.WriteLine($"       child loose  -> {string.Join(", ", chain.ChildLooseOffsetCandidates.Take(8).Select(v => $"0x{v:X8}"))}");
            foreach (var preview in chain.ChildLoosePayloadPreviews.Take(2))
            {
                Console.WriteLine($"       loose data   0x{preview.TargetOffset:X8} len=0x{preview.PreviewLength:X} hash={preview.PreviewHash64} shape={preview.ShapeSignature}");
                Console.WriteLine($"                    words: {string.Join(", ", preview.Words.Take(8).Select(DescribeGraphPreviewWord))}");
                Console.WriteLine($"                    bytes: {preview.PreviewHex}");
            }
            foreach (var tree in chain.RecursiveLoosePayloadTrees.Take(2))
            {
                PrintLooseTree(tree, 7, maxDepth: 2);
            }
        }

        Console.WriteLine();
        Console.WriteLine("First records:");
        foreach (var rec in doc.GraphRecords.Take(32))
        {
            Console.WriteLine($"  #{rec.Index,4} 0x{rec.Offset:X8} size=0x{rec.Size:X} shape={rec.ShapeSignature}");
            Console.WriteLine($"       first={rec.FirstWordKind}:{rec.FirstWordUInt32} strict={rec.StrictEdges.Count} loose={rec.LooseOffsetCandidates.Count} enum/count={rec.SmallEnumOrCountWords.Count}");
            if (!string.IsNullOrWhiteSpace(rec.DescriptorTypePair))
                Console.WriteLine($"       descriptor pair={rec.DescriptorTypePair} payload=0x{rec.DescriptorPayloadOffset:X8}");
            if (rec.StrictEdges.Count > 0)
                Console.WriteLine($"       strict -> {string.Join(", ", rec.StrictEdges.Take(8).Select(e => $"0x{e.TargetOffset:X8}"))}");
            if (rec.LooseOffsetCandidates.Count > 0)
                Console.WriteLine($"       loose  -> {string.Join(", ", rec.LooseOffsetCandidates.Take(8).Select(e => $"0x{e.TargetOffset:X8}"))}");
            Console.WriteLine($"       {rec.PreviewHex}");
        }
    }

    private static string DescribeGraphPreviewWord(GraphWord w)
    {
        if (w.Kind == "plausibleFloat" && w.Float32Value is not null)
            return w.Float32Value.Value.ToString("0.######", CultureInfo.InvariantCulture);

        if (w.Kind == "smallEnumOrCount")
            return w.UInt32Value.ToString(CultureInfo.InvariantCulture);

        if (w.TargetOffset is not null)
            return $"0x{w.UInt32Value:X8}->{w.Kind}";

        return $"0x{w.UInt32Value:X8}";
    }


    private static void PrintLooseTree(GraphLoosePayloadTreeNode node, int indent, int maxDepth)
    {
        string pad = new string(' ', indent);
        string refs = node.NestedLooseOffsetCandidates.Count == 0
            ? ""
            : $" looseRefs=[{string.Join(", ", node.NestedLooseOffsetCandidates.Take(6).Select(v => $"0x{v:X8}"))}]";
        string strict = node.NestedStrictOffsets.Count == 0
            ? ""
            : $" strictRefs=[{string.Join(", ", node.NestedStrictOffsets.Take(6).Select(v => $"0x{v:X8}"))}]";
        string cycle = node.CycleDetected ? " cycle" : "";
        string trunc = node.Truncated ? " truncated" : "";
        Console.WriteLine($"{pad}tree d{node.Depth} 0x{node.TargetOffset:X8} hash={node.PreviewHash64} sub={node.SubtreeHash64} shape={node.ShapeSignature}{refs}{strict}{cycle}{trunc}");
        Console.WriteLine($"{pad}     words: {string.Join(", ", node.Words.Take(8).Select(DescribeGraphPreviewWord))}");
        if (node.Depth >= maxDepth) return;
        foreach (var child in node.Children.Take(4))
            PrintLooseTree(child, indent + 5, maxDepth);
    }

    private static void CompareCmd(string[] paths)
    {
        var docs = paths.Select(FxrDumpDoc.ReadFromFile).ToList();
        Console.WriteLine("FXR graph comparison report");
        Console.WriteLine();

        foreach (var doc in docs)
        {
            string name = Path.GetFileName(doc.SourcePath);
            Console.WriteLine(name);
            Console.WriteLine($"  EffectId:               {doc.Fxr2Layout?.EffectId}");
            Console.WriteLine($"  FileSize:               {doc.FileSize}");
            Console.WriteLine($"  RootCountA:             {doc.Fxr2Layout?.RootCountA}");
            Console.WriteLine($"  Records:                {doc.GraphStats?.RecordCount}");
            Console.WriteLine($"  Descriptor chains:      {doc.GraphStats?.GraphChainCount}");
            Console.WriteLine($"  Recursive loose nodes:  {doc.GraphStats?.RecursiveLoosePayloadNodeCount}");
            Console.WriteLine($"  Recursive unique nodes: {doc.GraphStats?.RecursiveLoosePayloadUniqueTargetCount}");
            Console.WriteLine($"  Recursive max depth:    {doc.GraphStats?.RecursiveLoosePayloadMaxDepth}");
            Console.WriteLine($"  B-section records:      {doc.BSection?.Records.Count ?? 0}");
            Console.WriteLine($"  B-section refs:         {doc.BSection?.References.Count ?? 0}");
            Console.WriteLine($"  B-section targets:      {doc.BSection?.UniqueTargetCount ?? 0}");
            Console.WriteLine();
        }

        var allPairs = docs
            .SelectMany(d => d.GraphStats?.DescriptorRecordsByTypePair.Keys ?? Enumerable.Empty<string>())
            .Distinct()
            .OrderBy(KeyForPair)
            .ToList();

        Console.WriteLine("Descriptor type-pair matrix:");
        Console.Write("  pair".PadRight(12));
        foreach (var doc in docs)
            Console.Write(Path.GetFileNameWithoutExtension(doc.SourcePath).PadLeft(14));
        Console.WriteLine();
        foreach (string pair in allPairs)
        {
            Console.Write(("  " + pair).PadRight(12));
            foreach (var doc in docs)
            {
                int count = 0;
                doc.GraphStats?.DescriptorRecordsByTypePair.TryGetValue(pair, out count);
                Console.Write(count.ToString(CultureInfo.InvariantCulture).PadLeft(14));
            }
            Console.WriteLine();
        }
        Console.WriteLine();

        var chainMaps = docs.Select(d => BuildChainFingerprintMap(d)).ToList();
        var allFingerprints = chainMaps.SelectMany(m => m.Keys).Distinct().ToList();
        int commonCount = allFingerprints.Count(fp => chainMaps.All(m => m.ContainsKey(fp)));
        Console.WriteLine("Recursive chain fingerprints:");
        Console.WriteLine($"  Total unique fingerprints: {allFingerprints.Count}");
        Console.WriteLine($"  Common to all files:       {commonCount}");
        Console.WriteLine();

        for (int i = 0; i < docs.Count; i++)
        {
            var map = chainMaps[i];
            var others = chainMaps.Where((_, j) => j != i).SelectMany(m => m.Keys).ToHashSet();
            var unique = map.Keys.Where(k => !others.Contains(k)).OrderBy(k => k).ToList();
            Console.WriteLine($"Unique recursive chain fingerprints in {Path.GetFileName(docs[i].SourcePath)}: {unique.Count}");
            foreach (string fp in unique.Take(16))
            {
                var info = map[fp];
                Console.WriteLine($"  {ShortHash(fp)} count={info.Count} pair={info.TypePair} desc=0x{info.FirstDescriptorOffset:X8} payloadShape={info.PayloadShapeSignature}");
                Console.WriteLine($"       looseRoots: {string.Join(", ", info.LooseRootHashes.Take(6))}");
            }
            Console.WriteLine();
        }

        Console.WriteLine("Type-pair recursive subtree hashes by file:");
        foreach (string pair in allPairs)
        {
            Console.WriteLine($"  {pair}");
            foreach (var doc in docs)
            {
                var hashes = doc.GraphChains
                    .Where(c => c.TypePair == pair)
                    .SelectMany(c => c.RecursiveLoosePayloadTrees.Select(t => t.SubtreeHash64))
                    .Distinct()
                    .OrderBy(h => h)
                    .Take(8)
                    .ToList();
                Console.WriteLine($"    {Path.GetFileName(doc.SourcePath),-28} {string.Join(", ", hashes)}");
            }
        }

        Console.WriteLine();
        Console.WriteLine("B-section target hashes by file:");
        var allBHashes = docs
            .SelectMany(d => d.BSection?.Records.Select(r => r.PreviewHash64) ?? Enumerable.Empty<string>())
            .Distinct()
            .OrderBy(h => h)
            .ToList();
        Console.WriteLine($"  Total unique B-section hashes: {allBHashes.Count}");
        Console.WriteLine($"  Common to all files:           {allBHashes.Count(h => docs.All(d => d.BSection?.Records.Any(r => r.PreviewHash64 == h) ?? false))}");
        foreach (string hash in allBHashes.Take(64))
        {
            Console.Write($"  {hash}");
            foreach (var doc in docs)
            {
                var recs = doc.BSection?.Records.Where(r => r.PreviewHash64 == hash).Take(3).ToList() ?? new List<BSectionRecord>();
                string val = recs.Count == 0
                    ? "-"
                    : string.Join("/", recs.Select(r => $"0x{r.Offset:X}"));
                Console.Write(val.PadLeft(24));
            }
            Console.WriteLine();
        }

        Console.WriteLine();
        Console.WriteLine("B-section records by shape:");
        var allBShapes = docs
            .SelectMany(d => d.BSection?.RecordsByShape.Keys ?? Enumerable.Empty<string>())
            .Distinct()
            .OrderBy(v => v)
            .ToList();
        foreach (string shape in allBShapes.Take(48))
        {
            Console.Write($"  {shape}");
            foreach (var doc in docs)
            {
                int count = 0;
                doc.BSection?.RecordsByShape.TryGetValue(shape, out count);
                Console.Write(count.ToString(CultureInfo.InvariantCulture).PadLeft(10));
            }
            Console.WriteLine();
        }

        Console.WriteLine();
        Console.WriteLine("B-section first-word groups:");
        var allBFirstWords = docs
            .SelectMany(d => d.BSection?.RecordsByFirstWord.Keys ?? Enumerable.Empty<string>())
            .Distinct()
            .OrderBy(v => v)
            .ToList();
        foreach (string key in allBFirstWords.Take(48))
        {
            Console.Write(("  " + key).PadRight(28));
            foreach (var doc in docs)
            {
                int count = 0;
                doc.BSection?.RecordsByFirstWord.TryGetValue(key, out count);
                Console.Write(count.ToString(CultureInfo.InvariantCulture).PadLeft(10));
            }
            Console.WriteLine();
        }

        Console.WriteLine();
        Console.WriteLine("B-section referenced source type-pairs:");
        var allBSourcePairs = docs
            .SelectMany(d => d.BSection?.ReferencesByTypePair.Keys ?? Enumerable.Empty<string>())
            .Distinct()
            .OrderBy(KeyForPair)
            .ThenBy(v => v)
            .ToList();
        foreach (string pair in allBSourcePairs)
        {
            Console.Write(("  " + pair).PadRight(12));
            foreach (var doc in docs)
            {
                int count = 0;
                doc.BSection?.ReferencesByTypePair.TryGetValue(pair, out count);
                Console.Write(count.ToString(CultureInfo.InvariantCulture).PadLeft(14));
            }
            Console.WriteLine();
        }
    }

    private static Dictionary<string, CompareChainInfo> BuildChainFingerprintMap(FxrDumpDoc doc)
    {
        var result = new Dictionary<string, CompareChainInfo>(StringComparer.Ordinal);
        foreach (var chain in doc.GraphChains)
        {
            string fp = ChainFingerprint(chain);
            if (!result.TryGetValue(fp, out var info))
            {
                info = new CompareChainInfo
                {
                    TypePair = chain.TypePair,
                    PayloadShapeSignature = chain.PayloadShapeSignature,
                    FirstDescriptorOffset = chain.DescriptorOffset,
                    LooseRootHashes = chain.RecursiveLoosePayloadTrees.Select(t => t.SubtreeHash64).OrderBy(h => h).ToList(),
                };
                result.Add(fp, info);
            }
            info.Count++;
        }
        return result;
    }

    private static string ChainFingerprint(GraphChain chain)
    {
        string treePart = string.Join(";", chain.RecursiveLoosePayloadTrees
            .Select(t => $"{t.ShapeSignature}:{t.SubtreeHash64}")
            .OrderBy(s => s, StringComparer.Ordinal));
        return $"pair={chain.TypePair}|payloadShape={chain.PayloadShapeSignature}|tree={treePart}";
    }

    private static string ShortHash(string text)
    {
        const ulong offsetBasis = 14695981039346656037UL;
        const ulong prime = 1099511628211UL;
        ulong hash = offsetBasis;
        foreach (byte b in Encoding.UTF8.GetBytes(text))
        {
            hash ^= b;
            hash *= prime;
        }
        return "0x" + hash.ToString("X16", CultureInfo.InvariantCulture);
    }

    private static int KeyForPair(string pair)
    {
        int slash = pair.IndexOf('/');
        if (slash <= 0) return int.MaxValue;
        if (int.TryParse(pair.Substring(0, slash), NumberStyles.Integer, CultureInfo.InvariantCulture, out int a) &&
            int.TryParse(pair.Substring(slash + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out int b))
            return a * 10000 + b;
        return int.MaxValue;
    }

    private sealed class CompareChainInfo
    {
        public string TypePair { get; set; } = "";
        public string PayloadShapeSignature { get; set; } = "";
        public int FirstDescriptorOffset { get; set; }
        public int Count { get; set; }
        public List<string> LooseRootHashes { get; set; } = new();
    }


    private static void ChainDiffCmd(string[] args)
    {
        var opt = ParseChainDiffOptions(args);

        // chaindiff needs the recursive tree to be built with the same child/depth
        // budget that it will print. Other commands keep the conservative defaults.
        Fxr2GraphAnalyzer.ConfigureRecursiveLimits(opt.MaxDepth, opt.MaxChildren);

        var docs = opt.Paths.Select(FxrDumpDoc.ReadFromFile).ToList();
        if (docs.Count < 2)
            throw new ArgumentException("chaindiff requires at least two FXR paths.");

        var maps = docs.Select(BuildLogicalChainMap).ToList();
        var orderedKeys = new List<string>();
        var seenKeys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var map in maps)
        {
            foreach (string key in map.Keys)
            {
                if (seenKeys.Add(key))
                    orderedKeys.Add(key);
            }
        }

        if (!string.IsNullOrWhiteSpace(opt.KeyFilter))
            orderedKeys = orderedKeys.Where(k => string.Equals(k, opt.KeyFilter, StringComparison.OrdinalIgnoreCase)).ToList();
        else if (!string.IsNullOrWhiteSpace(opt.PairFilter))
            orderedKeys = orderedKeys.Where(k => k.StartsWith(opt.PairFilter + "#", StringComparison.OrdinalIgnoreCase)).ToList();

        Console.WriteLine("FXR logical chain side-by-side diff");
        Console.WriteLine($"  Files:       {string.Join(", ", docs.Select(d => Path.GetFileName(d.SourcePath)))}");
        Console.WriteLine($"  Pair filter: {opt.PairFilter ?? "<all>"}");
        Console.WriteLine($"  Key filter:  {opt.KeyFilter ?? "<none>"}");
        Console.WriteLine($"  Chains:      {orderedKeys.Count} logical keys before max limit");
        Console.WriteLine($"  Max children: {opt.MaxChildren}");
        Console.WriteLine($"  No ellipsis:  {opt.NoEllipsis}");
        Console.WriteLine();

        int shown = 0;
        foreach (string key in orderedKeys)
        {
            if (shown >= opt.MaxChains)
                break;

            var chains = maps.Select(m => m.TryGetValue(key, out var c) ? c : null).ToList();
            PrintLogicalChainDiff(key, docs, chains, opt);
            shown++;
        }

        if (orderedKeys.Count > shown)
            Console.WriteLine($"Skipped {orderedKeys.Count - shown} additional logical chains because --maxchains={opt.MaxChains}.");
    }

    private static ChainDiffOptions ParseChainDiffOptions(string[] args)
    {
        var opt = new ChainDiffOptions();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (a.Equals("--pair", StringComparison.OrdinalIgnoreCase))
            {
                if (++i >= args.Length) throw new ArgumentException("--pair requires a value.");
                opt.PairFilter = args[i];
            }
            else if (a.StartsWith("--pair=", StringComparison.OrdinalIgnoreCase))
            {
                opt.PairFilter = a.Substring("--pair=".Length);
            }
            else if (a.Equals("--key", StringComparison.OrdinalIgnoreCase))
            {
                if (++i >= args.Length) throw new ArgumentException("--key requires a value.");
                opt.KeyFilter = args[i];
            }
            else if (a.StartsWith("--key=", StringComparison.OrdinalIgnoreCase))
            {
                opt.KeyFilter = a.Substring("--key=".Length);
            }
            else if (a.Equals("--maxchains", StringComparison.OrdinalIgnoreCase))
            {
                if (++i >= args.Length) throw new ArgumentException("--maxchains requires a value.");
                opt.MaxChains = Math.Max(1, int.Parse(args[i], CultureInfo.InvariantCulture));
            }
            else if (a.StartsWith("--maxchains=", StringComparison.OrdinalIgnoreCase))
            {
                opt.MaxChains = Math.Max(1, int.Parse(a.Substring("--maxchains=".Length), CultureInfo.InvariantCulture));
            }
            else if (a.Equals("--maxwords", StringComparison.OrdinalIgnoreCase))
            {
                if (++i >= args.Length) throw new ArgumentException("--maxwords requires a value.");
                opt.MaxWords = Math.Max(1, int.Parse(args[i], CultureInfo.InvariantCulture));
            }
            else if (a.StartsWith("--maxwords=", StringComparison.OrdinalIgnoreCase))
            {
                opt.MaxWords = Math.Max(1, int.Parse(a.Substring("--maxwords=".Length), CultureInfo.InvariantCulture));
            }
            else if (a.Equals("--depth", StringComparison.OrdinalIgnoreCase))
            {
                if (++i >= args.Length) throw new ArgumentException("--depth requires a value.");
                opt.MaxDepth = Math.Max(0, int.Parse(args[i], CultureInfo.InvariantCulture));
            }
            else if (a.StartsWith("--depth=", StringComparison.OrdinalIgnoreCase))
            {
                opt.MaxDepth = Math.Max(0, int.Parse(a.Substring("--depth=".Length), CultureInfo.InvariantCulture));
            }
            else if (a.Equals("--maxchildren", StringComparison.OrdinalIgnoreCase))
            {
                if (++i >= args.Length) throw new ArgumentException("--maxchildren requires a value.");
                opt.MaxChildren = Math.Max(0, int.Parse(args[i], CultureInfo.InvariantCulture));
            }
            else if (a.StartsWith("--maxchildren=", StringComparison.OrdinalIgnoreCase))
            {
                opt.MaxChildren = Math.Max(0, int.Parse(a.Substring("--maxchildren=".Length), CultureInfo.InvariantCulture));
            }
            else if (a.Equals("--noellipsis", StringComparison.OrdinalIgnoreCase))
            {
                opt.NoEllipsis = true;
            }
            else
            {
                opt.Paths.Add(a);
            }
        }

        if (opt.Paths.Count < 2)
            throw new ArgumentException("chaindiff requires at least two FXR input paths.");

        if (!string.IsNullOrWhiteSpace(opt.KeyFilter) && opt.KeyFilter.Contains('#'))
        {
            int hash = opt.KeyFilter.IndexOf('#');
            if (string.IsNullOrWhiteSpace(opt.PairFilter))
                opt.PairFilter = opt.KeyFilter.Substring(0, hash);
        }

        return opt;
    }

    private static Dictionary<string, LogicalChainRef> BuildLogicalChainMap(FxrDumpDoc doc)
    {
        var map = new Dictionary<string, LogicalChainRef>(StringComparer.OrdinalIgnoreCase);
        var pairCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        foreach (var chain in doc.GraphChains.OrderBy(c => c.DescriptorOffset))
        {
            string pair = string.IsNullOrWhiteSpace(chain.TypePair) ? "<none>" : chain.TypePair;
            pairCounts[pair] = pairCounts.TryGetValue(pair, out int n) ? n + 1 : 1;
            string key = $"{pair}#{pairCounts[pair]}";
            map[key] = new LogicalChainRef
            {
                Key = key,
                Pair = pair,
                Occurrence = pairCounts[pair],
                Chain = chain,
            };
        }

        return map;
    }

    private static void PrintLogicalChainDiff(string key, List<FxrDumpDoc> docs, List<LogicalChainRef?> refs, ChainDiffOptions opt)
    {
        Console.WriteLine(new string('=', 120));
        Console.WriteLine($"Logical chain {key}");
        PrintSideBySideHeader(docs, opt);
        PrintSideBySideRow("descriptor", refs.Select(r => r is null ? "-" : $"#{r.Chain.DescriptorIndex} @0x{r.Chain.DescriptorOffset:X8}").ToList(), opt);
        PrintSideBySideRow("payload", refs.Select(r => r is null ? "-" : $"0x{r.Chain.PayloadOffset:X8} idx={FmtNullable(r.Chain.PayloadIndex)} size=0x{r.Chain.PayloadSize:X}").ToList(), opt);
        PrintSideBySideRow("payload shape", refs.Select(r => r?.Chain.PayloadShapeSignature ?? "-").ToList(), opt);
        PrintSideBySideRow("child strict", refs.Select(r => r is null ? "-" : JoinOffsets(r.Chain.ChildStrictOffsets, 6, opt.NoEllipsis)).ToList(), opt);
        PrintSideBySideRow("child loose", refs.Select(r => r is null ? "-" : JoinOffsets(r.Chain.ChildLooseOffsetCandidates, 6, opt.NoEllipsis)).ToList(), opt);
        PrintSideBySideRow("root subhashes", refs.Select(r => r is null ? "-" : JoinStrings(r.Chain.RecursiveLoosePayloadTrees.Select(t => t.SubtreeHash64), 4, opt.NoEllipsis)).ToList(), opt);

        Console.WriteLine();
        Console.WriteLine("Payload record words:");
        var payloadRecords = refs.Select((r, idx) => r is null ? null : docs[idx].GraphRecords.FirstOrDefault(gr => gr.Offset == r.Chain.PayloadOffset)).ToList();
        PrintWordRows("payload", payloadRecords.Select(r => r?.Words).ToList(), opt);

        int maxRoots = refs.Max(r => r?.Chain.RecursiveLoosePayloadTrees.Count ?? 0);
        for (int root = 0; root < maxRoots; root++)
        {
            var nodes = refs.Select(r => (r is not null && root < r.Chain.RecursiveLoosePayloadTrees.Count) ? r.Chain.RecursiveLoosePayloadTrees[root] : null).ToList();
            Console.WriteLine();
            PrintTreeNodeRows($"root{root}", nodes, opt, depth: 0);
        }

        Console.WriteLine();
    }

    private static void PrintTreeNodeRows(string label, List<GraphLoosePayloadTreeNode?> nodes, ChainDiffOptions opt, int depth)
    {
        PrintSideBySideRow(label, nodes.Select(n => n is null ? "-" : $"0x{n.TargetOffset:X8} hash={n.PreviewHash64} sub={n.SubtreeHash64}").ToList(), opt);
        PrintSideBySideRow(label + " shape", nodes.Select(n => n?.ShapeSignature ?? "-").ToList(), opt);
        PrintSideBySideRow(label + " loose", nodes.Select(n => n is null ? "-" : JoinOffsets(n.NestedLooseOffsetCandidates, 6, opt.NoEllipsis)).ToList(), opt);
        PrintSideBySideRow(label + " strict", nodes.Select(n => n is null ? "-" : JoinOffsets(n.NestedStrictOffsets, 6, opt.NoEllipsis)).ToList(), opt);
        PrintWordRows(label, nodes.Select(n => n?.Words).ToList(), opt);

        if (depth >= opt.MaxDepth)
            return;

        int maxChildren = nodes.Max(n => n?.Children.Count ?? 0);
        int limit = Math.Min(maxChildren, opt.MaxChildren);
        for (int child = 0; child < limit; child++)
        {
            var childNodes = nodes.Select(n => (n is not null && child < n.Children.Count) ? n.Children[child] : null).ToList();
            PrintTreeNodeRows(label + $".child{child}", childNodes, opt, depth + 1);
        }

        if (maxChildren > limit)
            PrintSideBySideRow(label + " children", nodes.Select(n => n is null ? "-" : $"{n.Children.Count} children; showing {limit} because --maxchildren={opt.MaxChildren}").ToList(), opt);
    }

    private static void PrintWordRows(string label, List<List<GraphWord>?> wordLists, ChainDiffOptions opt)
    {
        int max = Math.Min(opt.MaxWords, wordLists.Max(w => w?.Count ?? 0));
        for (int i = 0; i < max; i++)
        {
            var cells = wordLists.Select(words =>
            {
                if (words is null || i >= words.Count)
                    return "-";
                return FormatDiffWord(words[i]);
            }).ToList();
            PrintSideBySideRow($"{label}[{i}]", cells, opt);
        }
    }

    private static string FormatDiffWord(GraphWord w)
    {
        string value = w.Kind switch
        {
            "zero" => "0",
            "smallEnumOrCount" => w.UInt32Value.ToString(CultureInfo.InvariantCulture),
            "plausibleFloat" when w.Float32Value is not null => w.Float32Value.Value.ToString("0.######", CultureInfo.InvariantCulture),
            "strictRootOffsetRef" when w.TargetOffset is not null => $"0x{w.TargetOffset.Value:X8}",
            "looseOffsetCandidate" when w.TargetOffset is not null => $"0x{w.TargetOffset.Value:X8}",
            _ => $"0x{w.UInt32Value:X8}",
        };
        return $"0x{w.Offset:X8} {w.Kind} {value}";
    }

    private const int ChainDiffColumnWidth = 42;
    private const int ChainDiffLabelWidth = 22;

    private static void PrintSideBySideHeader(List<FxrDumpDoc> docs, ChainDiffOptions opt)
    {
        if (opt.NoEllipsis)
        {
            Console.WriteLine("".PadRight(ChainDiffLabelWidth) + string.Join(" | ", docs.Select(d => CleanCell(Path.GetFileNameWithoutExtension(d.SourcePath)))));
            Console.WriteLine(new string('-', 120));
            return;
        }

        Console.Write("".PadRight(ChainDiffLabelWidth));
        foreach (var doc in docs)
            Console.Write(TrimCell(Path.GetFileNameWithoutExtension(doc.SourcePath), ChainDiffColumnWidth).PadRight(ChainDiffColumnWidth));
        Console.WriteLine();
        Console.Write("".PadRight(ChainDiffLabelWidth));
        foreach (var _ in docs)
            Console.Write(new string('-', ChainDiffColumnWidth - 1) + " ");
        Console.WriteLine();
    }

    private static void PrintSideBySideRow(string label, List<string> cells, ChainDiffOptions opt)
    {
        if (opt.NoEllipsis)
        {
            Console.Write(CleanCell(label).PadRight(ChainDiffLabelWidth));
            Console.WriteLine(string.Join(" | ", cells.Select(CleanCell)));
            return;
        }

        Console.Write(TrimCell(label, ChainDiffLabelWidth).PadRight(ChainDiffLabelWidth));
        foreach (string cell in cells)
            Console.Write(TrimCell(cell, ChainDiffColumnWidth).PadRight(ChainDiffColumnWidth));
        Console.WriteLine();
    }

    private static string CleanCell(string? value)
    {
        value ??= "";
        return value.Replace("\r", " ").Replace("\n", " ");
    }

    private static string TrimCell(string? value, int width)
    {
        value = CleanCell(value);
        if (value.Length <= width - 1)
            return value;
        return value.Substring(0, Math.Max(0, width - 4)) + "...";
    }

    private static string JoinOffsets(IEnumerable<int> offsets, int max, bool noEllipsis = false)
    {
        var values = offsets.ToList();
        var list = (noEllipsis ? values : values.Take(max)).Select(v => $"0x{v:X8}").ToList();
        if (!noEllipsis && values.Count > max)
            list.Add($"+{values.Count - max}");
        return list.Count == 0 ? "-" : string.Join(",", list);
    }

    private static string JoinStrings(IEnumerable<string> values, int max, bool noEllipsis = false)
    {
        var listAll = values.ToList();
        var list = noEllipsis ? listAll : listAll.Take(max).ToList();
        if (!noEllipsis && listAll.Count > max)
            list.Add($"+{listAll.Count - max}");
        return list.Count == 0 ? "-" : string.Join(", ", list);
    }

    private static string FmtNullable(int? value)
        => value is null ? "-" : value.Value.ToString(CultureInfo.InvariantCulture);

    private sealed class ChainDiffOptions
    {
        public List<string> Paths { get; } = new();
        public string? PairFilter { get; set; }
        public string? KeyFilter { get; set; }
        public int MaxChains { get; set; } = 24;
        public int MaxWords { get; set; } = 16;
        public int MaxDepth { get; set; } = 2;
        public int MaxChildren { get; set; } = 9999;
        public bool NoEllipsis { get; set; } = false;
    }

    private sealed class LogicalChainRef
    {
        public string Key { get; set; } = "";
        public string Pair { get; set; } = "";
        public int Occurrence { get; set; }
        public GraphChain Chain { get; set; } = new();
    }

    private static int ParseIntFlexible(string s)
    {
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            return Convert.ToInt32(s.Substring(2), 16);
        return int.Parse(s, CultureInfo.InvariantCulture);
    }
}

public sealed class FxrDumpDoc
{
    public string Schema { get; set; } = "fxr-roundtrip-v11";
    public string SourcePath { get; set; } = "";
    public string Magic { get; set; } = "";
    public string DetectedFamily { get; set; } = "Unknown";
    public int FileSize { get; set; }
    public int HeaderByteCount { get; set; }
    public Fxr23HeaderInfo? Fxr23 { get; set; }
    public Fxr2LayoutHints? Fxr2Layout { get; set; }
    public List<HeaderWord> HeaderWords { get; set; } = new();
    public List<OffsetCandidate> OffsetCandidates { get; set; } = new();
    public List<RootIndexEntry> RootIndex { get; set; } = new();
    public List<GraphRecord> GraphRecords { get; set; } = new();
    public List<GraphChain> GraphChains { get; set; } = new();
    public GraphStats? GraphStats { get; set; }
    public BSectionAnalysis? BSection { get; set; }
    public List<FloatScanRegion> FloatScans { get; set; } = new();
    public List<EditablePatch> Patches { get; set; } = new();
    public string HeaderHex { get; set; } = "";
    public string RawFileBase64 { get; set; } = "";

    [JsonIgnore]
    public byte[] RawFileBytes { get; private set; } = Array.Empty<byte>();

    public static FxrDumpDoc ReadFromFile(string sourcePath)
    {
        byte[] bytes = File.ReadAllBytes(sourcePath);
        using var br = new BinaryReaderEx(false, bytes);

        if (br.Length < 8)
            throw new InvalidDataException("File too small to be an FXR candidate.");

        string magic = br.GetASCII(0, 4);
        if (magic != "FXR\0")
            throw new InvalidDataException($"Unexpected magic '{magic}'.");

        int fileSize = (int)br.Length;
        int headerBytes = Math.Min(0x100, fileSize);
        byte[] header = br.GetBytes(0, headerBytes);

        var doc = new FxrDumpDoc
        {
            SourcePath = sourcePath,
            Magic = magic,
            FileSize = fileSize,
            HeaderByteCount = headerBytes,
            HeaderHex = BitConverter.ToString(header).Replace("-", " "),
            RawFileBase64 = Convert.ToBase64String(bytes),
            RawFileBytes = bytes,
        };

        short zeroAt04 = br.GetInt16(4);
        short version16 = br.GetInt16(6);
        if (zeroAt04 == 0 && (version16 == 2 || version16 == 4 || version16 == 5))
        {
            doc.DetectedFamily = version16 switch
            {
                2 => "FXR2",
                4 => "FXR3-DS3",
                5 => "FXR3-Sekiro",
                _ => "FXR2/3-Unknown"
            };

            doc.Fxr23 = new Fxr23HeaderInfo
            {
                ZeroAt04 = zeroAt04,
                Version16 = version16,
                HeaderUnk08 = SafeGetInt32(br, 8),
                HeaderUnk0C = SafeGetInt32(br, 12),
            };
        }

        for (int off = 0; off + 4 <= headerBytes; off += 4)
        {
            uint u = br.GetUInt32(off);
            int i = unchecked((int)u);
            float f = br.GetSingle(off);
            bool plausibleFloat = FloatHeuristics.IsPlausibleFloat(f);

            doc.HeaderWords.Add(new HeaderWord
            {
                Offset = off,
                UInt32Value = u,
                Int32Value = i,
                Float32Value = plausibleFloat ? f : null,
                FloatClassification = FloatHeuristics.Classify(f),
                FloatLooksPlausible = plausibleFloat,
            });

            if (LooksLikeOffset((int)u, fileSize))
            {
                doc.OffsetCandidates.Add(new OffsetCandidate
                {
                    Offset = off,
                    Value = (int)u,
                    Aligned4 = (u % 4) == 0,
                    Aligned16 = (u % 16) == 0,
                });
            }
        }

        if (doc.DetectedFamily == "FXR2")
        {
            doc.Fxr2Layout = new Fxr2LayoutHints
            {
                RootOffsetA = SafeGetInt32(br, 0x10),
                RootCountA = SafeGetInt32(br, 0x14),
                RootOffsetB = SafeGetInt32(br, 0x20),
                EffectId = SafeGetInt32(br, 0x38),
                FirstDataOffset = SafeGetInt32(br, 0x50),
                DescriptorTableStart = 0x78,
            };

            var graph = Fxr2GraphAnalyzer.Analyze(bytes, doc.Fxr2Layout);
            doc.RootIndex = graph.RootIndex;
            doc.GraphRecords = graph.GraphRecords;
            doc.GraphChains = graph.GraphChains;
            doc.GraphStats = graph.GraphStats;
            doc.BSection = graph.BSection;
        }

        foreach (var scan in StructuredFloatScanner.ScanRegion(bytes, 0, fileSize))
            doc.FloatScans.Add(scan);

        return doc;
    }

    public void ValidateOrThrow()
    {
        if (string.IsNullOrWhiteSpace(Schema))
            throw new InvalidDataException("Missing schema.");
        if (Magic != "FXR\0")
            throw new InvalidDataException($"Unexpected magic '{Magic}'.");
        if (string.IsNullOrWhiteSpace(RawFileBase64))
            throw new InvalidDataException("Missing raw file bytes.");
        if (RootIndex is null)
            throw new InvalidDataException("RootIndex is null.");
        if (GraphRecords is null)
            throw new InvalidDataException("GraphRecords is null.");
        if (GraphChains is null)
            throw new InvalidDataException("GraphChains is null.");
        if (FloatScans is null)
            throw new InvalidDataException("FloatScans is null.");
        if (Patches is null)
            throw new InvalidDataException("Patches is null.");

        foreach (var scan in FloatScans)
            scan.ValidateOrThrow(FileSize);
        foreach (var patch in Patches)
            patch.ValidateOrThrow(FileSize);
    }

    private static bool LooksLikeOffset(int value, int fileSize)
    {
        if (value <= 0) return false;
        if (value >= fileSize) return false;
        if (value < 0x40) return false;
        if (value < 0x80 && (value % 16) != 0) return false;
        return true;
    }

    private static int SafeGetInt32(BinaryReaderEx br, long offset)
    {
        if (offset + 4 > br.Length)
            return 0;
        return br.GetInt32(offset);
    }
}


internal static class Fxr2GraphAnalyzer
{
    private const uint SmallEnumOrCountMax = 0x100;
    private const int LooseOffsetMin = 0x40;

    private const int DefaultRecursiveLooseMaxDepth = 3;
    private const int DefaultRecursiveLooseMaxChildren = 12;
    private static int RecursiveLooseMaxDepth = DefaultRecursiveLooseMaxDepth;
    private static int RecursiveLooseMaxChildren = DefaultRecursiveLooseMaxChildren;

    public static void ConfigureRecursiveLimits(int maxDepth, int maxChildren)
    {
        RecursiveLooseMaxDepth = Math.Max(DefaultRecursiveLooseMaxDepth, maxDepth);
        RecursiveLooseMaxChildren = Math.Max(DefaultRecursiveLooseMaxChildren, maxChildren);
    }

    public static Fxr2GraphAnalysis Analyze(byte[] bytes, Fxr2LayoutHints layout)
    {
        var rootIndex = new List<RootIndexEntry>();
        var graphRecords = new List<GraphRecord>();
        var graphChains = new List<GraphChain>();

        int fileSize = bytes.Length;
        int rootOffset = layout.RootOffsetA;
        int rootCount = layout.RootCountA;

        var stats = new GraphStats
        {
            RootIndexOffset = rootOffset,
            RootIndexCount = Math.Max(0, rootCount),
            RootIndexEndOffset = rootOffset >= 0 && rootCount >= 0 ? Math.Min(fileSize, rootOffset + rootCount * 8) : 0,
        };

        if (rootOffset < 0 || rootOffset >= fileSize || rootCount <= 0 || rootOffset + rootCount * 8L > fileSize)
        {
            stats.Note = "Root index table did not fit inside file; graph analysis skipped.";
            return new Fxr2GraphAnalysis(rootIndex, graphRecords, graphChains, stats, new BSectionAnalysis());
        }

        for (int i = 0; i < rootCount; i++)
        {
            int entryOffset = rootOffset + i * 8;
            ulong raw = BitConverter.ToUInt64(bytes, entryOffset);
            bool fitsInt = raw <= int.MaxValue;
            int value = fitsInt ? (int)raw : -1;
            bool valid = fitsInt && LooksLikeRootIndexOffset(value, fileSize, rootOffset);

            rootIndex.Add(new RootIndexEntry
            {
                Index = i,
                TableOffset = entryOffset,
                Offset = fitsInt ? value : null,
                RawUInt64Value = raw,
                IsValid = valid,
                Aligned4 = fitsInt && value % 4 == 0,
                Aligned16 = fitsInt && value % 16 == 0,
            });
        }

        stats.ValidRootIndexCount = rootIndex.Count(e => e.IsValid);

        var validOffsets = rootIndex
            .Where(e => e.IsValid && e.Offset is not null)
            .Select(e => e.Offset!.Value)
            .Distinct()
            .OrderBy(v => v)
            .ToList();

        stats.UniqueValidOffsetCount = validOffsets.Count;
        var rootOffsetSet = new HashSet<int>(validOffsets);

        for (int i = 0; i < rootIndex.Count; i++)
        {
            var e = rootIndex[i];
            if (e.Offset is not null && e.IsValid)
                e.DuplicateCount = rootIndex.Count(x => x.Offset == e.Offset);
        }

        for (int i = 0; i < validOffsets.Count; i++)
        {
            int offset = validOffsets[i];
            int next = (i + 1 < validOffsets.Count) ? validOffsets[i + 1] : rootOffset;
            if (next <= offset || next > fileSize)
                continue;

            int size = next - offset;
            var rec = BuildRecord(bytes, offset, size, graphRecords.Count, rootOffsetSet, rootOffset);
            graphRecords.Add(rec);

            Increment(stats.RecordsBySize, size.ToString(CultureInfo.InvariantCulture));
            Increment(stats.RecordsByShape, rec.ShapeSignature);

            if (rec.FirstWordUInt32 <= SmallEnumOrCountMax)
                Increment(stats.RecordsByFirstWordSmallEnum, rec.FirstWordUInt32.ToString(CultureInfo.InvariantCulture));

            if (!string.IsNullOrWhiteSpace(rec.DescriptorTypePair))
                Increment(stats.DescriptorRecordsByTypePair, rec.DescriptorTypePair);

            stats.StrictEdgeCount += rec.StrictEdges.Count;
            stats.LooseOffsetCandidateCount += rec.LooseOffsetCandidates.Count;
            stats.SmallEnumOrCountWordCount += rec.SmallEnumOrCountWords.Count;
        }

        stats.RecordCount = graphRecords.Count;

        var recursiveTargets = new HashSet<int>();
        int recursiveNodeCount = 0;
        int recursiveMaxDepth = 0;

        var recordByOffset = graphRecords.ToDictionary(r => r.Offset, r => r);
        foreach (var rec in graphRecords)
        {
            if (rec.DescriptorPayloadOffset is null || string.IsNullOrWhiteSpace(rec.DescriptorTypePair))
                continue;

            int payloadOffset = rec.DescriptorPayloadOffset.Value;
            recordByOffset.TryGetValue(payloadOffset, out var payload);

            var childLooseTargets = payload is null
                ? new List<int>()
                : payload.LooseOffsetCandidates.Select(e => e.TargetOffset).Distinct().OrderBy(v => v).ToList();

            var recursiveTrees = childLooseTargets
                .Select(target => BuildRecursiveLoosePayloadTree(bytes, target, rootOffsetSet, rootOffset, depth: 0, path: new HashSet<int>()))
                .ToList();

            foreach (var tree in recursiveTrees)
            {
                recursiveNodeCount += CountTreeNodes(tree);
                recursiveMaxDepth = Math.Max(recursiveMaxDepth, MaxTreeDepth(tree));
                CollectTreeTargets(tree, recursiveTargets);
            }

            var chain = new GraphChain
            {
                DescriptorIndex = rec.Index,
                DescriptorOffset = rec.Offset,
                DescriptorSize = rec.Size,
                TypePair = rec.DescriptorTypePair,
                PayloadOffset = payloadOffset,
                PayloadIndex = payload?.Index,
                PayloadSize = payload?.Size ?? 0,
                PayloadShapeSignature = payload?.ShapeSignature ?? "<target-not-in-root-index>",
                PayloadPreviewHex = payload?.PreviewHex ?? "",
                ChildStrictOffsets = payload is null ? new List<int>() : payload.StrictEdges.Select(e => e.TargetOffset).Distinct().OrderBy(v => v).ToList(),
                ChildLooseOffsetCandidates = childLooseTargets,
                ChildLoosePayloadPreviews = childLooseTargets.Select(target => BuildLoosePayloadPreview(bytes, target, rootOffsetSet, rootOffset)).ToList(),
                RecursiveLoosePayloadTrees = recursiveTrees,
            };
            stats.LoosePayloadPreviewCount += chain.ChildLoosePayloadPreviews.Count;
            graphChains.Add(chain);
        }

        var bSection = BuildBSectionAnalysis(bytes, layout, graphRecords, graphChains, rootOffsetSet);

        stats.GraphChainCount = graphChains.Count;
        stats.RecursiveLoosePayloadNodeCount = recursiveNodeCount;
        stats.RecursiveLoosePayloadUniqueTargetCount = recursiveTargets.Count;
        stats.RecursiveLoosePayloadMaxDepth = recursiveMaxDepth;
        return new Fxr2GraphAnalysis(rootIndex, graphRecords, graphChains, stats, bSection);
    }

    private static BSectionAnalysis BuildBSectionAnalysis(byte[] bytes, Fxr2LayoutHints layout, List<GraphRecord> graphRecords, List<GraphChain> graphChains, HashSet<int> rootOffsetSet)
    {
        int start = layout.RootOffsetB;
        int end = layout.RootOffsetA;
        var analysis = new BSectionAnalysis
        {
            StartOffset = start,
            EndOffset = end,
            Size = (start >= 0 && end >= start) ? end - start : 0,
        };

        if (start <= 0 || end <= start || end > bytes.Length)
        {
            analysis.Note = "B-section range did not look valid; expected RootOffsetB < RootOffsetA within the file.";
            return analysis;
        }

        var refs = new List<BSectionReference>();

        foreach (var rec in graphRecords)
        {
            foreach (var edge in rec.LooseOffsetCandidates)
            {
                if (!IsInsideRange(edge.TargetOffset, start, end))
                    continue;

                refs.Add(new BSectionReference
                {
                    SourceKind = "graphRecord",
                    SourceIndex = rec.Index,
                    SourceOffset = rec.Offset,
                    SourceSlot = edge.FromSlot,
                    SourceWordOffset = edge.FromOffset,
                    DescriptorOffset = rec.DescriptorTypePair is null ? null : rec.Offset,
                    TypePair = rec.DescriptorTypePair,
                    PayloadOffset = rec.DescriptorPayloadOffset,
                    TargetOffset = edge.TargetOffset,
                    Depth = 0,
                });
            }
        }

        foreach (var chain in graphChains)
        {
            foreach (var preview in chain.ChildLoosePayloadPreviews)
                CollectBRefsFromWords(refs, preview.Words, "chainLoosePreview", chain.DescriptorIndex, preview.TargetOffset, chain, depth: 0, start, end);

            foreach (var tree in chain.RecursiveLoosePayloadTrees)
                CollectBRefsFromTree(refs, tree, chain, start, end);
        }

        analysis.References = refs
            .OrderBy(r => r.TargetOffset)
            .ThenBy(r => r.SourceOffset)
            .ThenBy(r => r.SourceSlot)
            .ToList();

        var targetOffsets = analysis.References
            .Select(r => r.TargetOffset)
            .Where(t => IsInsideRange(t, start, end))
            .Distinct()
            .OrderBy(t => t)
            .ToList();

        analysis.UniqueTargetCount = targetOffsets.Count;

        // Treat each referenced B-section target as a leaf record. Size is bounded by the next
        // referenced B target or RootOffsetA. This gives stable previews/hashes for comparison;
        // it does not claim to know the real serialized leaf-record length.
        for (int i = 0; i < targetOffsets.Count; i++)
        {
            int offset = targetOffsets[i];
            int next = (i + 1 < targetOffsets.Count) ? targetOffsets[i + 1] : end;
            if (next <= offset)
                next = Math.Min(end, offset + 4);

            int size = Math.Max(0, Math.Min(next, end) - offset);
            var preview = BuildLoosePayloadPreview(bytes, offset, rootOffsetSet, end);
            var sources = analysis.References.Where(r => r.TargetOffset == offset).ToList();
            var bRecord = new BSectionRecord
            {
                Index = i,
                Offset = offset,
                EndOffset = Math.Min(end, offset + size),
                Size = size,
                ReferenceCount = sources.Count,
                PreviewLength = preview.PreviewLength,
                PreviewHash64 = preview.PreviewHash64,
                ShapeSignature = preview.ShapeSignature,
                PreviewHex = preview.PreviewHex,
                PreviewBytesBase64 = preview.PreviewBytesBase64,
                Words = preview.Words,
                SourceTypePairs = sources
                    .Select(r => r.TypePair)
                    .Where(v => !string.IsNullOrWhiteSpace(v))
                    .Select(v => v!)
                    .Distinct(StringComparer.Ordinal)
                    .OrderBy(v => v, StringComparer.Ordinal)
                    .ToList(),
            };
            analysis.Records.Add(bRecord);

            Increment(analysis.RecordsByShape, bRecord.ShapeSignature);
            Increment(analysis.RecordsByHash, bRecord.PreviewHash64);
            if (bRecord.Words.Count > 0)
                Increment(analysis.RecordsByFirstWord, DescribeBSectionFirstWord(bRecord.Words[0]));
        }

        foreach (var reference in analysis.References)
            Increment(analysis.ReferencesBySourceKind, reference.SourceKind);

        foreach (var reference in analysis.References.Where(r => !string.IsNullOrWhiteSpace(r.TypePair)))
            Increment(analysis.ReferencesByTypePair, reference.TypePair!);

        return analysis;
    }

    private static void CollectBRefsFromTree(List<BSectionReference> refs, GraphLoosePayloadTreeNode node, GraphChain chain, int start, int end)
    {
        CollectBRefsFromWords(refs, node.Words, "recursiveLoosePayload", chain.DescriptorIndex, node.TargetOffset, chain, node.Depth, start, end);
        foreach (var child in node.Children)
            CollectBRefsFromTree(refs, child, chain, start, end);
    }

    private static void CollectBRefsFromWords(
        List<BSectionReference> refs,
        List<GraphWord> words,
        string sourceKind,
        int sourceIndex,
        int sourceOffset,
        GraphChain chain,
        int depth,
        int start,
        int end)
    {
        foreach (var word in words)
        {
            if (word.Kind != "looseOffsetCandidate" || word.TargetOffset is null)
                continue;

            int target = word.TargetOffset.Value;
            if (!IsInsideRange(target, start, end))
                continue;

            refs.Add(new BSectionReference
            {
                SourceKind = sourceKind,
                SourceIndex = sourceIndex,
                SourceOffset = sourceOffset,
                SourceSlot = word.Slot,
                SourceWordOffset = word.Offset,
                DescriptorOffset = chain.DescriptorOffset,
                TypePair = chain.TypePair,
                PayloadOffset = chain.PayloadOffset,
                TargetOffset = target,
                Depth = depth,
            });
        }
    }

    private static bool IsInsideRange(int value, int start, int end)
        => value >= start && value < end;

    private static string DescribeBSectionFirstWord(GraphWord word)
    {
        if (word.Kind == "smallEnumOrCount")
            return "enum:" + word.UInt32Value.ToString(CultureInfo.InvariantCulture);
        if (word.Kind == "plausibleFloat" && word.Float32Value is not null)
            return "float:" + word.Float32Value.Value.ToString("0.######", CultureInfo.InvariantCulture);
        if (word.TargetOffset is not null)
            return word.Kind + ":0x" + word.TargetOffset.Value.ToString("X8", CultureInfo.InvariantCulture);
        return word.Kind;
    }

    private static GraphRecord BuildRecord(byte[] bytes, int offset, int size, int index, HashSet<int> rootOffsetSet, int rootTableOffset)
    {
        var words = new List<GraphWord>();
        var strictEdges = new List<GraphEdge>();
        var looseCandidates = new List<GraphEdge>();
        var smallWords = new List<GraphSmallValue>();
        var shapeParts = new List<string>();

        int wordCount = size / 4;
        for (int slot = 0; slot < wordCount; slot++)
        {
            int wordOffset = offset + slot * 4;
            uint u = BitConverter.ToUInt32(bytes, wordOffset);
            int i = unchecked((int)u);
            float f = BitConverter.ToSingle(bytes, wordOffset);

            string kind;
            int? target = null;
            bool isStrictEdge = false;
            bool isLooseCandidate = false;

            if (u == 0)
            {
                kind = "zero";
            }
            else if (u <= int.MaxValue && rootOffsetSet.Contains((int)u))
            {
                kind = "strictRootOffsetRef";
                target = (int)u;
                isStrictEdge = true;
            }
            else if (u <= SmallEnumOrCountMax)
            {
                kind = "smallEnumOrCount";
            }
            else if (u <= int.MaxValue && LooksLikeLooseOffsetCandidate((int)u, bytes.Length, rootTableOffset))
            {
                kind = "looseOffsetCandidate";
                target = (int)u;
                isLooseCandidate = true;
            }
            else if (FloatHeuristics.IsPlausibleFloat(f))
            {
                kind = "plausibleFloat";
            }
            else
            {
                kind = "rawWord";
            }

            var word = new GraphWord
            {
                Slot = slot,
                Offset = wordOffset,
                UInt32Value = u,
                Int32Value = i,
                Float32Value = FloatHeuristics.IsPlausibleFloat(f) ? f : null,
                FloatClassification = FloatHeuristics.Classify(f),
                Kind = kind,
                TargetOffset = target,
            };
            words.Add(word);
            shapeParts.Add(kind);

            if (isStrictEdge && target is not null)
            {
                strictEdges.Add(new GraphEdge
                {
                    FromSlot = slot,
                    FromOffset = wordOffset,
                    TargetOffset = target.Value,
                    Kind = kind,
                });
            }
            else if (isLooseCandidate && target is not null)
            {
                looseCandidates.Add(new GraphEdge
                {
                    FromSlot = slot,
                    FromOffset = wordOffset,
                    TargetOffset = target.Value,
                    Kind = kind,
                });
            }
            else if (kind == "smallEnumOrCount")
            {
                smallWords.Add(new GraphSmallValue
                {
                    Slot = slot,
                    Offset = wordOffset,
                    UInt32Value = u,
                });
            }
        }

        uint firstU32 = size >= 4 ? BitConverter.ToUInt32(bytes, offset) : 0;
        string firstKind = words.Count > 0 ? words[0].Kind : "empty";

        string? descriptorTypePair = null;
        int? descriptorPayloadOffset = null;
        if (LooksLikeDescriptorRecord(words))
        {
            uint a = words[2].UInt32Value;
            uint b = words[3].UInt32Value;
            descriptorTypePair = $"{a}/{b}";
            descriptorPayloadOffset = words[0].TargetOffset;
        }

        return new GraphRecord
        {
            Index = index,
            Offset = offset,
            Size = size,
            EndOffset = offset + size,
            FirstWordUInt32 = firstU32,
            FirstWordKind = firstKind,
            WordCount = wordCount,
            ShapeSignature = string.Join(",", shapeParts),
            DescriptorTypePair = descriptorTypePair,
            DescriptorPayloadOffset = descriptorPayloadOffset,
            PreviewHex = PreviewAt(bytes, offset, Math.Min(size, 64)),
            RawBytesBase64 = Convert.ToBase64String(Slice(bytes, offset, size)),
            Words = words,
            StrictEdges = strictEdges,
            LooseOffsetCandidates = looseCandidates,
            SmallEnumOrCountWords = smallWords,
        };
    }

    private static GraphLoosePayloadPreview BuildLoosePayloadPreview(byte[] bytes, int targetOffset, HashSet<int> rootOffsetSet, int rootTableOffset)
    {
        int available = bytes.Length - targetOffset;
        if (targetOffset < 0 || targetOffset >= bytes.Length || available <= 0)
        {
            return new GraphLoosePayloadPreview
            {
                TargetOffset = targetOffset,
                PreviewLength = 0,
                PreviewHex = "",
                PreviewHash64 = "0x0000000000000000",
                ShapeSignature = "<out-of-range>",
                Words = new List<GraphWord>(),
            };
        }

        if (rootTableOffset > targetOffset)
            available = Math.Min(available, rootTableOffset - targetOffset);

        int previewLength = Math.Min(64, Math.Max(0, available));
        int wordBytes = previewLength - (previewLength % 4);
        var words = new List<GraphWord>();
        var shapeParts = new List<string>();

        for (int slot = 0; slot < wordBytes / 4; slot++)
        {
            int wordOffset = targetOffset + slot * 4;
            uint u = BitConverter.ToUInt32(bytes, wordOffset);
            int i = unchecked((int)u);
            float f = BitConverter.ToSingle(bytes, wordOffset);

            string kind;
            int? refTarget = null;
            if (u == 0)
            {
                kind = "zero";
            }
            else if (u <= int.MaxValue && rootOffsetSet.Contains((int)u) && u > SmallEnumOrCountMax)
            {
                kind = "strictRootOffsetRef";
                refTarget = (int)u;
            }
            else if (u <= SmallEnumOrCountMax)
            {
                kind = "smallEnumOrCount";
            }
            else if (u <= int.MaxValue && LooksLikeLooseOffsetCandidate((int)u, bytes.Length, rootTableOffset))
            {
                kind = "looseOffsetCandidate";
                refTarget = (int)u;
            }
            else if (FloatHeuristics.IsPlausibleFloat(f))
            {
                kind = "plausibleFloat";
            }
            else
            {
                kind = "rawWord";
            }

            words.Add(new GraphWord
            {
                Slot = slot,
                Offset = wordOffset,
                UInt32Value = u,
                Int32Value = i,
                Float32Value = FloatHeuristics.IsPlausibleFloat(f) ? f : null,
                FloatClassification = FloatHeuristics.Classify(f),
                Kind = kind,
                TargetOffset = refTarget,
            });
            shapeParts.Add(kind);
        }

        byte[] previewBytes = Slice(bytes, targetOffset, previewLength);
        return new GraphLoosePayloadPreview
        {
            TargetOffset = targetOffset,
            PreviewLength = previewLength,
            PreviewHex = PreviewAt(bytes, targetOffset, previewLength),
            PreviewBytesBase64 = Convert.ToBase64String(previewBytes),
            PreviewHash64 = Fnv1A64Hex(previewBytes),
            ShapeSignature = string.Join(",", shapeParts),
            Words = words,
        };
    }


    private static GraphLoosePayloadTreeNode BuildRecursiveLoosePayloadTree(
        byte[] bytes,
        int targetOffset,
        HashSet<int> rootOffsetSet,
        int rootTableOffset,
        int depth,
        HashSet<int> path)
    {
        var preview = BuildLoosePayloadPreview(bytes, targetOffset, rootOffsetSet, rootTableOffset);
        var node = new GraphLoosePayloadTreeNode
        {
            TargetOffset = targetOffset,
            Depth = depth,
            PreviewLength = preview.PreviewLength,
            PreviewHash64 = preview.PreviewHash64,
            ShapeSignature = preview.ShapeSignature,
            PreviewHex = preview.PreviewHex,
            PreviewBytesBase64 = preview.PreviewBytesBase64,
            Words = preview.Words,
            NestedStrictOffsets = preview.Words
                .Where(w => w.Kind == "strictRootOffsetRef" && w.TargetOffset is not null)
                .Select(w => w.TargetOffset!.Value)
                .Distinct()
                .OrderBy(v => v)
                .ToList(),
            NestedLooseOffsetCandidates = preview.Words
                .Where(w => w.Kind == "looseOffsetCandidate" && w.TargetOffset is not null)
                .Select(w => w.TargetOffset!.Value)
                .Distinct()
                .OrderBy(v => v)
                .ToList(),
        };

        if (targetOffset < 0 || targetOffset >= bytes.Length)
        {
            node.SubtreeHash64 = ComputeSubtreeHash(node);
            return node;
        }

        if (path.Contains(targetOffset))
        {
            node.CycleDetected = true;
            node.SubtreeHash64 = ComputeSubtreeHash(node);
            return node;
        }

        if (depth >= RecursiveLooseMaxDepth)
        {
            node.Truncated = node.NestedLooseOffsetCandidates.Count > 0;
            node.SubtreeHash64 = ComputeSubtreeHash(node);
            return node;
        }

        var childPath = new HashSet<int>(path) { targetOffset };
        foreach (int child in node.NestedLooseOffsetCandidates.Take(RecursiveLooseMaxChildren))
            node.Children.Add(BuildRecursiveLoosePayloadTree(bytes, child, rootOffsetSet, rootTableOffset, depth + 1, childPath));

        node.Truncated = node.NestedLooseOffsetCandidates.Count > RecursiveLooseMaxChildren;
        node.SubtreeHash64 = ComputeSubtreeHash(node);
        return node;
    }

    private static string ComputeSubtreeHash(GraphLoosePayloadTreeNode node)
    {
        var sb = new StringBuilder();
        sb.Append(node.PreviewHash64).Append('|').Append(node.ShapeSignature).Append('|');
        foreach (int strict in node.NestedStrictOffsets)
            sb.Append("S:").Append(strict.ToString("X8", CultureInfo.InvariantCulture)).Append(';');
        foreach (var child in node.Children.OrderBy(c => c.TargetOffset))
            sb.Append("C:").Append(child.SubtreeHash64).Append('@').Append(child.ShapeSignature).Append(';');
        return Fnv1A64Hex(Encoding.UTF8.GetBytes(sb.ToString()));
    }

    private static int CountTreeNodes(GraphLoosePayloadTreeNode node)
    {
        int count = 1;
        foreach (var child in node.Children)
            count += CountTreeNodes(child);
        return count;
    }

    private static int MaxTreeDepth(GraphLoosePayloadTreeNode node)
    {
        int max = node.Depth;
        foreach (var child in node.Children)
            max = Math.Max(max, MaxTreeDepth(child));
        return max;
    }

    private static void CollectTreeTargets(GraphLoosePayloadTreeNode node, HashSet<int> targets)
    {
        targets.Add(node.TargetOffset);
        foreach (var child in node.Children)
            CollectTreeTargets(child, targets);
    }

    private static string Fnv1A64Hex(byte[] data)
    {
        const ulong offsetBasis = 14695981039346656037UL;
        const ulong prime = 1099511628211UL;
        ulong hash = offsetBasis;
        foreach (byte b in data)
        {
            hash ^= b;
            hash *= prime;
        }
        return "0x" + hash.ToString("X16", CultureInfo.InvariantCulture);
    }

    private static bool LooksLikeDescriptorRecord(List<GraphWord> words)
    {
        if (words.Count < 4) return false;
        if (words[0].Kind != "strictRootOffsetRef") return false;
        if (words[1].Kind != "zero") return false;
        if (words[2].Kind != "smallEnumOrCount") return false;
        if (words[3].Kind != "smallEnumOrCount") return false;
        return true;
    }

    private static bool LooksLikeRootIndexOffset(int value, int fileSize, int rootTableOffset)
    {
        if (value < 0) return false;
        if (value >= fileSize) return false;
        if ((value % 4) != 0) return false;
        // FXR2 root indexes point into the graph/payload area before the root-index table.
        if (rootTableOffset > 0 && value >= rootTableOffset) return false;
        return true;
    }

    private static bool LooksLikeLooseOffsetCandidate(int value, int fileSize, int rootTableOffset)
    {
        if (value < LooseOffsetMin) return false;
        if (value >= fileSize) return false;
        if ((value % 4) != 0) return false;
        if (rootTableOffset > 0 && value >= rootTableOffset) return false;
        return true;
    }

    private static void Increment(Dictionary<string, int> map, string key)
    {
        map[key] = map.TryGetValue(key, out int n) ? n + 1 : 1;
    }

    private static byte[] Slice(byte[] bytes, int offset, int length)
    {
        byte[] result = new byte[length];
        Buffer.BlockCopy(bytes, offset, result, 0, length);
        return result;
    }

    private static string PreviewAt(byte[] bytes, int offset, int length)
    {
        if (offset < 0 || offset >= bytes.Length) return "";
        int len = Math.Min(length, bytes.Length - offset);
        byte[] slice = Slice(bytes, offset, len);
        return BitConverter.ToString(slice).Replace("-", " ");
    }
}

public sealed record Fxr2GraphAnalysis(
    List<RootIndexEntry> RootIndex,
    List<GraphRecord> GraphRecords,
    List<GraphChain> GraphChains,
    GraphStats GraphStats,
    BSectionAnalysis BSection);

internal static class FloatHeuristics
{
    public static bool IsPlausibleFloat(float value)
    {
        if (!float.IsFinite(value)) return false;
        if (value == 0f) return true;
        float abs = Math.Abs(value);
        if (abs < 1e-6f) return false;
        if (abs > 1e6f) return false;
        return true;
    }

    public static string Classify(float value)
    {
        if (float.IsNaN(value)) return "NaN";
        if (float.IsInfinity(value)) return "Infinity";
        if (value == 0f) return "Zero";
        float abs = Math.Abs(value);
        if (abs < 1.17549435E-38f) return "Subnormal";
        if (abs < 1e-6f) return "Tiny";
        if (abs > 1e6f) return "Huge";
        return "Plausible";
    }
}

internal static class StructuredFloatScanner
{
    public static List<FloatScanRegion> ScanRegion(byte[] bytes, int start, int length)
    {
        var results = new List<FloatScanRegion>();
        if (bytes.Length < 16) return results;

        int regionStart = Math.Max(0, start);
        int regionEnd = Math.Min(bytes.Length, start + length);

        for (int off = regionStart; off + 16 <= regionEnd; off += 4)
        {
            var plausibleValues = new List<float>();
            var slotKinds = new List<string>(4);
            int plausible = 0;

            for (int i = 0; i < 4; i++)
            {
                int slotOff = off + i * 4;
                uint rawU32 = BitConverter.ToUInt32(bytes, slotOff);
                float f = BitConverter.ToSingle(bytes, slotOff);
                bool plausibleFloat = FloatHeuristics.IsPlausibleFloat(f);

                if (plausibleFloat)
                {
                    plausible++;
                    plausibleValues.Add(f);
                    slotKinds.Add("plausibleFloat");
                }
                else if (rawU32 == 0)
                {
                    plausibleValues.Add(0f);
                    slotKinds.Add("zero");
                }
                else
                {
                    slotKinds.Add("nonFloatWord");
                }
            }

            if (plausible >= 2)
            {
                results.Add(new FloatScanRegion
                {
                    StartOffset = off,
                    RegionSize = 16,
                    PlausibleFloatCount = plausible,
                    PlausibleDensity = plausible / 4.0,
                    Values = plausibleValues,
                    SlotKinds = slotKinds,
                    Preview = PreviewAt(bytes, off),
                });
            }
        }

        return results;
    }

    private static string PreviewAt(byte[] bytes, int offset)
    {
        if (offset < 0 || offset >= bytes.Length) return "";
        int len = Math.Min(32, bytes.Length - offset);
        byte[] slice = new byte[len];
        Buffer.BlockCopy(bytes, offset, slice, 0, len);
        return BitConverter.ToString(slice).Replace("-", " ");
    }
}

public enum PatchKind
{
    Float32,
    UInt32,
    Bytes,
}

public sealed class EditablePatch
{
    public int Offset { get; set; }
    public PatchKind Kind { get; set; }
    public float? ValueFloat32 { get; set; }
    public uint? ValueUInt32 { get; set; }
    public string? ValueBytes { get; set; }
    public string Note { get; set; } = "";

    public void ValidateOrThrow(int fileSize)
    {
        if (Offset < 0 || Offset >= fileSize)
            throw new InvalidDataException($"Patch offset out of range: 0x{Offset:X8}");

        switch (Kind)
        {
            case PatchKind.Float32:
                if (Offset + 4 > fileSize) throw new InvalidDataException($"Float32 patch out of range at 0x{Offset:X8}");
                if (ValueFloat32 is null) throw new InvalidDataException($"Float32 patch missing value at 0x{Offset:X8}");
                break;
            case PatchKind.UInt32:
                if (Offset + 4 > fileSize) throw new InvalidDataException($"UInt32 patch out of range at 0x{Offset:X8}");
                if (ValueUInt32 is null) throw new InvalidDataException($"UInt32 patch missing value at 0x{Offset:X8}");
                break;
            case PatchKind.Bytes:
                if (ValueBytes is null) throw new InvalidDataException($"Bytes patch missing value at 0x{Offset:X8}");
                byte[] raw = Convert.FromBase64String(ValueBytes);
                if (Offset + raw.Length > fileSize) throw new InvalidDataException($"Bytes patch out of range at 0x{Offset:X8}");
                break;
            default:
                throw new InvalidDataException($"Unsupported patch kind: {Kind}");
        }
    }

    public string DescribeValue()
    {
        return Kind switch
        {
            PatchKind.Float32 => ValueFloat32?.ToString("0.######", CultureInfo.InvariantCulture) ?? "<null>",
            PatchKind.UInt32 => ValueUInt32?.ToString(CultureInfo.InvariantCulture) ?? "<null>",
            PatchKind.Bytes => ValueBytes is null ? "<null>" : $"base64[{Convert.FromBase64String(ValueBytes).Length}]",
            _ => "?",
        };
    }
}

public sealed class Fxr23HeaderInfo
{
    public short ZeroAt04 { get; set; }
    public short Version16 { get; set; }
    public int HeaderUnk08 { get; set; }
    public int HeaderUnk0C { get; set; }
}

public sealed class Fxr2LayoutHints
{
    public int RootOffsetA { get; set; }
    public int RootCountA { get; set; }
    public int RootOffsetB { get; set; }
    public int EffectId { get; set; }
    public int FirstDataOffset { get; set; }
    public int DescriptorTableStart { get; set; }
}

public sealed class HeaderWord
{
    public int Offset { get; set; }
    public uint UInt32Value { get; set; }
    public int Int32Value { get; set; }
    public float? Float32Value { get; set; }
    public string FloatClassification { get; set; } = "";
    public bool FloatLooksPlausible { get; set; }
}

public sealed class OffsetCandidate
{
    public int Offset { get; set; }
    public int Value { get; set; }
    public bool Aligned4 { get; set; }
    public bool Aligned16 { get; set; }
}


public sealed class RootIndexEntry
{
    public int Index { get; set; }
    public int TableOffset { get; set; }
    public ulong RawUInt64Value { get; set; }
    public int? Offset { get; set; }
    public bool IsValid { get; set; }
    public bool Aligned4 { get; set; }
    public bool Aligned16 { get; set; }
    public int DuplicateCount { get; set; } = 1;
}

public sealed class GraphStats
{
    public int RootIndexOffset { get; set; }
    public int RootIndexEndOffset { get; set; }
    public int RootIndexCount { get; set; }
    public int ValidRootIndexCount { get; set; }
    public int UniqueValidOffsetCount { get; set; }
    public int RecordCount { get; set; }
    public int StrictEdgeCount { get; set; }
    public int LooseOffsetCandidateCount { get; set; }
    public int SmallEnumOrCountWordCount { get; set; }
    public int GraphChainCount { get; set; }
    public int LoosePayloadPreviewCount { get; set; }
    public int RecursiveLoosePayloadNodeCount { get; set; }
    public int RecursiveLoosePayloadUniqueTargetCount { get; set; }
    public int RecursiveLoosePayloadMaxDepth { get; set; }
    public Dictionary<string, int> RecordsBySize { get; set; } = new();
    public Dictionary<string, int> RecordsByFirstWordSmallEnum { get; set; } = new();
    public Dictionary<string, int> RecordsByShape { get; set; } = new();
    public Dictionary<string, int> DescriptorRecordsByTypePair { get; set; } = new();
    public string? Note { get; set; }
}

public sealed class GraphRecord
{
    public int Index { get; set; }
    public int Offset { get; set; }
    public int EndOffset { get; set; }
    public int Size { get; set; }
    public int WordCount { get; set; }
    public uint FirstWordUInt32 { get; set; }
    public string FirstWordKind { get; set; } = "";
    public string ShapeSignature { get; set; } = "";
    public string? DescriptorTypePair { get; set; }
    public int? DescriptorPayloadOffset { get; set; }
    public string PreviewHex { get; set; } = "";
    public string RawBytesBase64 { get; set; } = "";
    public List<GraphWord> Words { get; set; } = new();
    public List<GraphEdge> StrictEdges { get; set; } = new();
    public List<GraphEdge> LooseOffsetCandidates { get; set; } = new();
    public List<GraphSmallValue> SmallEnumOrCountWords { get; set; } = new();
}

public sealed class GraphWord
{
    public int Slot { get; set; }
    public int Offset { get; set; }
    public uint UInt32Value { get; set; }
    public int Int32Value { get; set; }
    public float? Float32Value { get; set; }
    public string FloatClassification { get; set; } = "";
    public string Kind { get; set; } = "";
    public int? TargetOffset { get; set; }
}

public sealed class GraphEdge
{
    public int FromSlot { get; set; }
    public int FromOffset { get; set; }
    public int TargetOffset { get; set; }
    public string Kind { get; set; } = "";
}

public sealed class GraphSmallValue
{
    public int Slot { get; set; }
    public int Offset { get; set; }
    public uint UInt32Value { get; set; }
}

public sealed class GraphChain
{
    public int DescriptorIndex { get; set; }
    public int DescriptorOffset { get; set; }
    public int DescriptorSize { get; set; }
    public string TypePair { get; set; } = "";
    public int PayloadOffset { get; set; }
    public int? PayloadIndex { get; set; }
    public int PayloadSize { get; set; }
    public string PayloadShapeSignature { get; set; } = "";
    public string PayloadPreviewHex { get; set; } = "";
    public List<int> ChildStrictOffsets { get; set; } = new();
    public List<int> ChildLooseOffsetCandidates { get; set; } = new();
    public List<GraphLoosePayloadPreview> ChildLoosePayloadPreviews { get; set; } = new();
    public List<GraphLoosePayloadTreeNode> RecursiveLoosePayloadTrees { get; set; } = new();
}

public sealed class GraphLoosePayloadPreview
{
    public int TargetOffset { get; set; }
    public int PreviewLength { get; set; }
    public string PreviewHash64 { get; set; } = "";
    public string ShapeSignature { get; set; } = "";
    public string PreviewHex { get; set; } = "";
    public string PreviewBytesBase64 { get; set; } = "";
    public List<GraphWord> Words { get; set; } = new();
}

public sealed class GraphLoosePayloadTreeNode
{
    public int TargetOffset { get; set; }
    public int Depth { get; set; }
    public int PreviewLength { get; set; }
    public string PreviewHash64 { get; set; } = "";
    public string SubtreeHash64 { get; set; } = "";
    public string ShapeSignature { get; set; } = "";
    public string PreviewHex { get; set; } = "";
    public string PreviewBytesBase64 { get; set; } = "";
    public bool CycleDetected { get; set; }
    public bool Truncated { get; set; }
    public List<int> NestedStrictOffsets { get; set; } = new();
    public List<int> NestedLooseOffsetCandidates { get; set; } = new();
    public List<GraphWord> Words { get; set; } = new();
    public List<GraphLoosePayloadTreeNode> Children { get; set; } = new();
}

public sealed class BSectionAnalysis
{
    public int StartOffset { get; set; }
    public int EndOffset { get; set; }
    public int Size { get; set; }
    public int UniqueTargetCount { get; set; }
    public string? Note { get; set; }
    public List<BSectionRecord> Records { get; set; } = new();
    public List<BSectionReference> References { get; set; } = new();
    public Dictionary<string, int> RecordsByShape { get; set; } = new();
    public Dictionary<string, int> RecordsByHash { get; set; } = new();
    public Dictionary<string, int> RecordsByFirstWord { get; set; } = new();
    public Dictionary<string, int> ReferencesByTypePair { get; set; } = new();
    public Dictionary<string, int> ReferencesBySourceKind { get; set; } = new();
}

public sealed class BSectionRecord
{
    public int Index { get; set; }
    public int Offset { get; set; }
    public int EndOffset { get; set; }
    public int Size { get; set; }
    public int ReferenceCount { get; set; }
    public int PreviewLength { get; set; }
    public string PreviewHash64 { get; set; } = "";
    public string ShapeSignature { get; set; } = "";
    public string PreviewHex { get; set; } = "";
    public string PreviewBytesBase64 { get; set; } = "";
    public List<GraphWord> Words { get; set; } = new();
    public List<string> SourceTypePairs { get; set; } = new();
}

public sealed class BSectionReference
{
    public string SourceKind { get; set; } = "";
    public int SourceIndex { get; set; }
    public int SourceOffset { get; set; }
    public int SourceSlot { get; set; }
    public int SourceWordOffset { get; set; }
    public int? DescriptorOffset { get; set; }
    public string? TypePair { get; set; }
    public int? PayloadOffset { get; set; }
    public int TargetOffset { get; set; }
    public int Depth { get; set; }
}

public sealed class FloatScanRegion
{
    public int StartOffset { get; set; }
    public int RegionSize { get; set; }
    public int PlausibleFloatCount { get; set; }
    public double PlausibleDensity { get; set; }
    public List<float> Values { get; set; } = new();
    public List<string> SlotKinds { get; set; } = new();
    public string Preview { get; set; } = "";

    public void ValidateOrThrow(int fileSize)
    {
        if (StartOffset < 0 || StartOffset >= fileSize)
            throw new InvalidDataException($"FloatScan startOffset out of range: {StartOffset}");
        if (RegionSize <= 0)
            throw new InvalidDataException($"FloatScan regionSize must be > 0 at 0x{StartOffset:X8}");
        if (StartOffset + RegionSize > fileSize)
            throw new InvalidDataException($"FloatScan region exceeds file at 0x{StartOffset:X8}");
        if (Values is null)
            throw new InvalidDataException($"FloatScan values null at 0x{StartOffset:X8}");
        if (SlotKinds is null || SlotKinds.Count != 4)
            throw new InvalidDataException($"FloatScan slotKinds must have 4 entries at 0x{StartOffset:X8}");
    }
}
