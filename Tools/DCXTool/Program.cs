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
using System.Text.Json;
using SoulsFormats;
using SoulsFormats.Compression; // for helpers used by DCX internally

#nullable enable

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
                case "dcx-decompress":
                    return RunDcxDecompress(args.Skip(1).ToArray());

                case "dcx-compress-like":
                    return RunDcxCompressLike(args.Skip(1).ToArray());

                case "dcx-recompress":
                    return RunDcxRecompress(args.Skip(1).ToArray());

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
@"DCXTool

Commands:
  dcx-decompress <input> <outDir> [--recurse] [--overwrite] [--ext .bin] [--no-sidecar]
  dcx-compress-like <rawIn> <templateDcx> <dcxOut> [--overwrite]
  dcx-recompress <dcxIn> <dcxOut> [--overwrite]

Notes:
- dcx-decompress writes the inner bytes (default strips trailing .dcx) and a .dcxinfo.json sidecar (unless --no-sidecar).
- dcx-compress-like uses the template DCX to detect CompressionInfo and compresses rawIn using the same exact settings.
- dcx-recompress is just: Decompress(dcxIn,out comp) then Compress(inner, comp) to dcxOut.
");
        return 2;
    }

    // ---------------------------
    // dcx-decompress
    // ---------------------------

    private sealed class DecompressOpt
    {
        public string Input = "";
        public string OutDir = "";
        public bool Recurse;
        public bool Overwrite;
        public string? ForceExt;
        public bool NoSidecar;
    }

    private static int RunDcxDecompress(string[] args)
    {
        var opt = ParseDecompress(args);

        if (string.IsNullOrWhiteSpace(opt.Input) || string.IsNullOrWhiteSpace(opt.OutDir))
            return Usage("dcx-decompress requires <input> <outDir>.");

        Directory.CreateDirectory(opt.OutDir);

        IEnumerable<string> inputs;
        if (File.Exists(opt.Input))
        {
            inputs = new[] { opt.Input };
        }
        else if (Directory.Exists(opt.Input))
        {
            var so = opt.Recurse ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly;
            inputs = Directory.EnumerateFiles(opt.Input, "*", so);
        }
        else
        {
            throw new FileNotFoundException($"Input path not found: {opt.Input}");
        }

        int seen = 0, dcx = 0, wrote = 0, skipped = 0;

        foreach (string inPath in inputs)
        {
            seen++;

            if (!Path.GetFileName(inPath).EndsWith(".dcx", StringComparison.OrdinalIgnoreCase))
            {
                skipped++;
                continue;
            }

            if (!SoulsFormats.DCX.Is(inPath))
            {
                skipped++;
                continue;
            }

            dcx++;

            byte[] decompressed = SoulsFormats.DCX.Decompress(inPath, out SoulsFormats.DCX.CompressionInfo comp);

            string outPath = GetOutputPath(opt.OutDir, inPath, opt.ForceExt);

            if (!opt.Overwrite && File.Exists(outPath))
            {
                Console.WriteLine($"SKIP (exists): {outPath}");
                skipped++;
                continue;
            }

            File.WriteAllBytes(outPath, decompressed);
            wrote++;

            if (!opt.NoSidecar)
            {
                string sidecar = outPath + ".dcxinfo.json";
                var info = new DcxInfo
                {
                    Input = inPath,
                    Output = outPath,
                    Compression = CompressionDto.From(comp),
                };
                File.WriteAllText(sidecar, JsonSerializer.Serialize(info, JsonOpts));
            }

            Console.WriteLine($"OK: {Path.GetFileName(inPath)} -> {Path.GetFileName(outPath)} [{Describe(comp)}]");
        }

        Console.WriteLine($"Done. Seen={seen} DCX={dcx} Wrote={wrote} Skipped={skipped}");
        return 0;
    }

    private static DecompressOpt ParseDecompress(string[] args)
    {
        var o = new DecompressOpt();
        if (args.Length >= 1) o.Input = args[0];
        if (args.Length >= 2) o.OutDir = args[1];

        for (int i = 2; i < args.Length; i++)
        {
            string a = args[i];
            switch (a)
            {
                case "--recurse": o.Recurse = true; break;
                case "--overwrite": o.Overwrite = true; break;
                case "--no-sidecar": o.NoSidecar = true; break;
                case "--ext":
                    if (i + 1 >= args.Length) throw new ArgumentException("--ext requires a value like .bin");
                    o.ForceExt = args[++i];
                    break;
                default:
                    throw new ArgumentException($"Unknown option: {a}");
            }
        }

        return o;
    }

    private static string GetOutputPath(string outDir, string inPath, string? forceExt)
    {
        string fileName = Path.GetFileName(inPath);

        // strip trailing ".dcx"
        if (fileName.EndsWith(".dcx", StringComparison.OrdinalIgnoreCase))
            fileName = fileName.Substring(0, fileName.Length - 4);

        if (!string.IsNullOrWhiteSpace(forceExt))
        {
            string ext = forceExt!;
            if (!ext.StartsWith(".")) ext = "." + ext;
            fileName = Path.ChangeExtension(fileName, ext);
        }

        return Path.Combine(outDir, fileName);
    }

    // ---------------------------
    // dcx-compress-like
    // ---------------------------

    private static int RunDcxCompressLike(string[] args)
    {
        // dcx-compress-like <rawIn> <templateDcx> <dcxOut> [--overwrite]
        if (args.Length < 3)
            return Usage("dcx-compress-like requires <rawIn> <templateDcx> <dcxOut>.");

        string rawIn = args[0];
        string templateDcx = args[1];
        string dcxOut = args[2];

        bool overwrite = args.Skip(3).Any(a => a.Equals("--overwrite", StringComparison.OrdinalIgnoreCase));

        if (!File.Exists(rawIn))
            throw new FileNotFoundException($"Raw input not found: {rawIn}");
        if (!File.Exists(templateDcx))
            throw new FileNotFoundException($"Template DCX not found: {templateDcx}");
        if (!overwrite && File.Exists(dcxOut))
            throw new IOException($"Output exists (use --overwrite): {dcxOut}");

        // Detect compression from template (we don't even need the decompressed bytes)
        SoulsFormats.DCX.Decompress(templateDcx, out SoulsFormats.DCX.CompressionInfo comp);

        byte[] raw = File.ReadAllBytes(rawIn);
        SoulsFormats.DCX.Compress(raw, comp, dcxOut);

        Console.WriteLine($"OK: {Path.GetFileName(rawIn)} -> {Path.GetFileName(dcxOut)} using [{Describe(comp)}]");
        return 0;
    }

    // ---------------------------
    // dcx-recompress
    // ---------------------------

    private static int RunDcxRecompress(string[] args)
    {
        // dcx-recompress <dcxIn> <dcxOut> [--overwrite]
        if (args.Length < 2)
            return Usage("dcx-recompress requires <dcxIn> <dcxOut>.");

        string dcxIn = args[0];
        string dcxOut = args[1];

        bool overwrite = args.Skip(2).Any(a => a.Equals("--overwrite", StringComparison.OrdinalIgnoreCase));

        if (!File.Exists(dcxIn))
            throw new FileNotFoundException($"Input DCX not found: {dcxIn}");
        if (!overwrite && File.Exists(dcxOut))
            throw new IOException($"Output exists (use --overwrite): {dcxOut}");

        byte[] inner = SoulsFormats.DCX.Decompress(dcxIn, out SoulsFormats.DCX.CompressionInfo comp);
        SoulsFormats.DCX.Compress(inner, comp, dcxOut);

        Console.WriteLine($"OK: {Path.GetFileName(dcxIn)} -> {Path.GetFileName(dcxOut)} [{Describe(comp)}]");
        return 0;
    }

    // ---------------------------
    // Sidecar models (full info)
    // ---------------------------

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true
    };

    private sealed class DcxInfo
    {
        public string Input { get; set; } = "";
        public string Output { get; set; } = "";
        public CompressionDto Compression { get; set; } = new();
    }

    private sealed class CompressionDto
    {
        public SoulsFormats.DCX.Type Type { get; set; } = SoulsFormats.DCX.Type.Unknown;

        // DFLT
        public int? Unk04 { get; set; }
        public int? Unk10 { get; set; }
        public int? Unk14 { get; set; }
        public byte? Unk30 { get; set; }
        public byte? Unk38 { get; set; }

        // KRAK
        public byte? KrakLevel { get; set; }
        public string? OodleCompressorType { get; set; }

        // ZSTD
        public byte? ZstdLevel { get; set; }

        public static CompressionDto From(SoulsFormats.DCX.CompressionInfo c)
        {
            var dto = new CompressionDto { Type = c.Type };

            switch (c.Type)
            {
                case SoulsFormats.DCX.Type.DCX_DFLT:
                    if (c is SoulsFormats.DCX.DcxDfltCompressionInfo d)
                    {
                        dto.Unk04 = d.Unk04;
                        dto.Unk10 = d.Unk10;
                        dto.Unk14 = d.Unk14;
                        dto.Unk30 = d.Unk30;
                        dto.Unk38 = d.Unk38;
                    }
                    break;

                case SoulsFormats.DCX.Type.DCX_KRAK:
                    if (c is SoulsFormats.DCX.DcxKrakCompressionInfo k)
                    {
                        dto.KrakLevel = k.CompressionLevel;
                        dto.OodleCompressorType = k.OodleCompressorType.ToString();
                    }
                    break;

                case SoulsFormats.DCX.Type.DCX_ZSTD:
                    if (c is SoulsFormats.DCX.DcxZstdCompressionInfo z)
                    {
                        dto.ZstdLevel = z.CompressionLevel;
                    }
                    break;
            }

            return dto;
        }
    }

    // ---------------------------
    // Human-readable describe
    // ---------------------------

    private static string Describe(SoulsFormats.DCX.CompressionInfo c)
    {
        return c.Type switch
        {
            SoulsFormats.DCX.Type.Zlib => "Zlib",
            SoulsFormats.DCX.Type.DCP_DFLT => "DCP_DFLT",
            SoulsFormats.DCX.Type.DCP_EDGE => "DCP_EDGE",
            SoulsFormats.DCX.Type.DCX_EDGE => "DCX_EDGE",
            SoulsFormats.DCX.Type.DCX_DFLT => DescribeDflt(c),
            SoulsFormats.DCX.Type.DCX_KRAK => DescribeKrak(c),
            SoulsFormats.DCX.Type.DCX_ZSTD => DescribeZstd(c),
            _ => c.Type.ToString()
        };
    }

    private static string DescribeDflt(SoulsFormats.DCX.CompressionInfo c)
    {
        if (c is SoulsFormats.DCX.DcxDfltCompressionInfo d)
            return $"DCX_DFLT(unk04=0x{d.Unk04:X},unk10=0x{d.Unk10:X},unk14=0x{d.Unk14:X},unk30=0x{d.Unk30:X2},unk38=0x{d.Unk38:X2})";
        return "DCX_DFLT";
    }

    private static string DescribeKrak(SoulsFormats.DCX.CompressionInfo c)
    {
        if (c is SoulsFormats.DCX.DcxKrakCompressionInfo k)
            return $"DCX_KRAK(level={k.CompressionLevel},oodle={k.OodleCompressorType})";
        return "DCX_KRAK";
    }

    private static string DescribeZstd(SoulsFormats.DCX.CompressionInfo c)
    {
        if (c is SoulsFormats.DCX.DcxZstdCompressionInfo z)
            return $"DCX_ZSTD(level={z.CompressionLevel})";
        return "DCX_ZSTD";
    }
}