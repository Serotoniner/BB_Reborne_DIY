# BB Reborne DIY Tool

**BB Reborne** is a complete visual overhaul for *Bloodborne*, changing textures, lighting, material properties, map lighting, draw parameters, and other visual data across the entire game, including the DLC and Chalice Dungeons.

The mod requires emulation through **shadPS4 v0.15.1 or newer** and is **not intended for jailbroken PS4 hardware**.

This repository contains the **BB Reborne DIY Tool**, a Windows-based PowerShell tool that generates the mod files locally on the user’s machine.

---

## How does it work?

To be as compliant as possible with copyright law, **BB Reborne DIY Tool does not include any original game assets or original game code**.

Instead, the user provides their own legally obtained dump of *Bloodborne* updated to **patch 1.09**, and the BB Reborne DIY Tool generates the modded files locally by:

1. Reading the user’s game dump.
2. Applying patch/diff data included in this repository.
3. Converting several game file formats to JSON or XML.
4. Applying controlled changes.
5. Rebuilding the modified game files.
6. Upscaling and repairing textures with custom processing scripts.
7. Writing the generated mod files to the output folder.

Because the files are generated locally, this is not an instant process. It requires processing time, disk space, and some involvement from the user. I worked hard to make the process as smooth as possible, but I understand it is less convenient than downloading prebuilt mod files.

The upside is that the tooling created for BB Reborne may be useful for other modding projects. Other modders are welcome to use, adapt, and improve the code under the terms of the GPL license.

---

## Requirements

### Required

* Windows 10 or Windows 11.
* PowerShell 7.
* A legally obtained *Bloodborne* game dump updated to patch **1.09**.
* shadPS4 **v0.15.1 or newer** to run the modded game.
* At least **100 GB of free disk space** for decompression, processing, and generated files.
* A modern GPU capable of running AI upscaling tools.

### Recommended

* **32 GB RAM**.
* A GPU with **16 GB VRAM** for running the modded game comfortably.
* NVIDIA 40/50 series or a strong modern AMD GPU for faster texture generation.
* SSD storage, preferably NVMe.

The texture generation step is the slowest part of the process and can take several hours depending on hardware.

---

## What the tool generates

The tool creates modded files under the selected output folder. The main generated folders are:

```text
BBReborne_flver
BBReborne_map
BBReborne_maplight
BBReborne_param
BBReborne_sparam
BBReborne_GI
BBReborne_textures
BBReborne_menu
BBReborne_obj
BBReborne_sfx
BBReborne_gparam
```

For map files, the tool preserves the original relative path structure. For example:

```text
<GameRoot>\map\m21_00_00_00\m21_00_00_00_000010.flver.dcx
```

becomes:

```text
<OutputRoot>\BBReborne_flver\map\m21_00_00_00\m21_00_00_00_000010.flver.dcx
```

---

## Main processing steps

BB Reborne generation has two major parts:

1. **Global files**
2. **Per-map files**

The **Global** step is required. It generates shared game files that are not tied to one specific map, such as SFX, menu files, global game parameters, object binders, and default drawparam data.

After Global files are generated, the map tab can generate the map-specific files.

---

## Global generation step

The global runner is:

```text
Scripts\Global\00_Run_Global_BBReborne_All.ps1
```

It runs the global patch scripts in a fixed order:

| Step | Script                                           | Output folder      | Description                                                                   |
| ---: | ------------------------------------------------ | ------------------ | ----------------------------------------------------------------------------- |
|   01 | `01_Global_BBReborne_SFX_RemovePlayerLight.ps1`  | `BBReborne_sfx`    | Removes/replaces the player light SFX by patching the common effects archive. |
|   02 | `02_Global_BBReborne_SFX_M25.ps1`                | `BBReborne_sfx`    | Applies the M25-specific SFX patch.                                           |
|   03 | `03_Global_BBReborne_Menu_fe.ps1`                | `BBReborne_menu`   | Applies menu/frontend `fe` changes.                                           |
|   04 | `04_Global_BBReborne_Gparam_GameParam.ps1`       | `BBReborne_gparam` | Applies global `gameparam.parambnd.dcx` patches.                              |
|   05 | `05_Global_BBReborne_Obj_FromDiffs.ps1`          | `BBReborne_obj`    | Applies object FLVER patches from object diffs.                               |
|   06 | `06_Global_BBReborne_Param_DefaultDrawparam.ps1` | `BBReborne_param`  | Applies default drawparam patches.                                            |

The global runner launches each child script in its own PowerShell process and writes logs/summaries under the selected output folder.

The original game files are never modified. Each script copies the required source files into isolated work/output folders before patching.

---

## Map generation steps

The map generation tab can run the following steps per map:

| Step | Output folder        | Description                                     |
| ---: | -------------------- | ----------------------------------------------- |
|   01 | `BBReborne_flver`    | Applies FLVER model patches.                    |
|   02 | `BBReborne_map`      | Applies MSB / MapStudio patches.                |
|   03 | `BBReborne_maplight` | Applies BTL map lighting patches.               |
|   04 | `BBReborne_maplight` | Applies BTPB map lighting patches.              |
|   05 | `BBReborne_param`    | Applies map drawparam / GParamBND patches.      |
|   06 | `BBReborne_sparam`   | Applies loose SParam / Sgparam XML patches.     |
|   07 | `BBReborne_GI`       | Repairs baked GI texture alpha values.          |
|   08 | `BBReborne_textures` | Runs texture upscaling and material-map repair. |

Each map row has step checkboxes, so the user can rerun only selected steps instead of regenerating everything.

Some maps do not use every step. The tool greys out steps when no matching patch/input data exists, and **Check files** reports which expected outputs are missing.

---

## Included conversion tools

BB Reborne uses several custom command-line tools to make binary game files editable in a safer and more reviewable way.

Most of these tools follow the same basic pattern:

```text
dump    binary game file -> JSON or XML
rebuild JSON/XML         -> binary game file
```

This allows the repository to store small patch/diff files rather than full game assets.

### FLVER

**FlverJsonTool**

Used for model files.

```text
.flver / .flver.dcx -> JSON
JSON -> .flver / .flver.dcx
```

Used by:

```text
BBReborne_flver
BBReborne_obj
```

### MSB / MapStudio

**MsbbJsonTool**

Used for map layout / MapStudio files.

```text
.msb / .msb.dcx -> JSON
JSON -> .msb / .msb.dcx
```

Used by:

```text
BBReborne_map
```

### BTL

**BtlJsonTool**

Used for map lighting data.

```text
.btl / .btl.dcx -> JSON
JSON -> .btl / .btl.dcx
```

Used by:

```text
BBReborne_maplight
```

### BTPB

**BtpbJsonTool**

Used for additional map lighting / baked lighting data.

```text
.btpb / .btpb.dcx -> JSON
JSON -> .btpb / .btpb.dcx
```

Used by:

```text
BBReborne_maplight
```

### BTAB

**BtabJsonTool**

Used for BTAB binary table data.

```text
.btab / .btab.dcx -> JSON
JSON -> .btab / .btab.dcx
```

### FXR

**FxrJsonTool**

Used for effect-related files.

```text
.fxr / .fxr.dcx -> JSON
JSON -> .fxr / .fxr.dcx
```

### NVA

**NvaJsonTool**

Used for navigation-related binary files.

```text
.nva / .nva.dcx -> JSON
JSON -> .nva / .nva.dcx
```

### DCX

**DCXTool / WitchyBND**

Used to decompress and recompress DCX-wrapped files.

```text
*.dcx -> decompressed file
decompressed file -> *.dcx
```

### GParam / Drawparam XML

GParam files are converted to XML through WitchyBND and patched as XML.

Used by:

```text
BBReborne_param
BBReborne_sparam
```

The tool handles both:

```text
*.gparambnd.dcx
*.gparam.dcx
```

depending on whether the file is a binder-style drawparam or a loose SParam/Sgparam file.

---

## Texture processing

The texture pipeline performs several stages:

1. Extract texture archives with WitchyBND.
2. Upscale diffuse/albedo textures with Real-ESRGAN.
3. Process normal, reflectance, specular, mask, and other data textures with linear-safe methods.
4. Repair height/normal blue-channel data when needed.
5. Repair reflectance and specular maps.
6. Repair low-resolution `_l` texture variants before repack.
7. Repack the processed texture archive.

The texture output is written under:

```text
BBReborne_textures
```

Texture generation is the most expensive step. The tool supports CPU and GPU throttle settings to avoid overloading the system.

---

## First run

1. Download or clone this repository.
2. If downloaded as a ZIP, right-click the ZIP, open **Properties**, and click **Unblock** before extracting if Windows shows that option.
3. Extract the tool folder.
4. Run the launcher:

```text
Launch-BBReborneDIYTool.cmd
```

or run manually:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -STA -File ".\BBReborneDIYTool.ps1"
```

5. In the **Setup** tab:

   * Select your game dump folder.
   * Run **Setup required tools**.
   * Confirm the tool reports:

```text
✓ tools set   ✓ settings saved
```

6. In the **Mod files** tab:

   * Run the **Global** step first.
   * Run M21 to calibrate the ETA
   * Then generate the map files.
   * Use **Check files** to verify expected outputs.
   * Use **Patch** for individual maps or **Run all patches** for the full map generation process.
   * Use the step checkboxes to rerun only specific map steps when needed.

---

## PowerShell permissions

If Windows blocks the downloaded scripts, run this from PowerShell:

```powershell
Unblock-File -Path "C:\Path\To\BBReborneDIYTool\*" -Recurse
```

The included launcher also attempts to unblock the tool folder before starting the main script.

The tool launches PowerShell with:

```powershell
-ExecutionPolicy Bypass
```

This applies only to the current process and does not permanently change the user’s system execution policy.

---

## Output and logs

Generated files go into the selected output folder.

Logs are written under:

```text
<OutputRoot>\_logs
```

Map runs write logs to:

```text
<OutputRoot>\_logs\maps\<MapCode>\<timestamp>
```

Each map run includes a summary file:

```text
map_run_summary.json
```

This helps identify failed steps, skipped steps, elapsed time, and generated outputs.

---

## Notes about legality

This repository does not provide original *Bloodborne* assets.

The user must provide their own game dump. The tool only provides patch data, conversion scripts, and processing logic needed to generate the modded files locally.

This project is intended for preservation, research, modding, and personal use.

---

## License

This project is released under the GPL license.

You may use, modify, and adapt the code, including for other modding projects, as long as you follow the GPL license terms, keep derivative code free under compatible terms, and **give proper credit**.

---

## Credits

BB Reborne DIY Tool uses or integrates several external tools, including:

* SoulsFormatsNext
* WitchyBND
* Microsoft DirectXTex / texconv
* ImageMagick
* Real-ESRGAN NCNN Vulkan
* Git
* PowerShell 7

Additional custom JSON/XML tools were created for BB Reborne to support dump/rebuild workflows for FLVER, MSB, BTL, BTPB, BTAB, FXR, NVA, DCX, and drawparam-related files.

Special thanks to the Bloodborne modding and emulation communities.
