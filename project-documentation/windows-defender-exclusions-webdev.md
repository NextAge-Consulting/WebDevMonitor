# Windows Defender Exclusions for PCSoft WebDev Application Servers

## Why This Matters

Windows Defender's real-time protection (MsMpEng) scans **every file read/write** on the server. On a WebDev server running 300+ sessions during business hours, this means Defender is intercepting thousands of I/O operations per second — both from WD session processes generating dynamic pages and from Apache/IIS serving static assets.

WebDevMonitor logs from a production server showed MsMpEng consuming 6-26% CPU, appearing in 16 of 17 NON_WD_SPIKE events. Apache log analysis from another server showed **67% of all HTTP traffic was static asset serving** from `_WEB` directories (CSS, JS, images), which triggers Defender scans on every request regardless of WD process exclusions.

The payoff is real: after applying these exclusions to one busy WebDev server, overall CPU dropped from **10-25% to 4-10%** during business hours. That's headroom for more users on the same hardware.

---

# Part 1: WebDev Server

## Step 0: Check Existing Exclusions

Before making any changes, record what's already excluded:

```powershell
(Get-MpPreference).ExclusionPath
(Get-MpPreference).ExclusionProcess
(Get-MpPreference).ExclusionExtension
```

## What to Exclude

### 1A: WebDev Processes

Exclude the three WebDev executables from Defender scanning. This stops Defender from intercepting I/O on every dynamic page generation across all active sessions.

Version numbers follow the pattern `WD<ver>Session.exe` (e.g., WD280, WD290, WD300, WD310). Find yours:

```powershell
Get-Process WD*Session | Select-Object Path -Unique
```

Then exclude the processes:

```powershell
Add-MpPreference -ExclusionProcess "WD<VER>Session.exe"
Add-MpPreference -ExclusionProcess "WD<VER>AWP.exe"
Add-MpPreference -ExclusionProcess "WD<VER>Admin.exe"
```

Also exclude the WebDev install directory (framework DLLs loaded by every session):

```powershell
Add-MpPreference -ExclusionPath "C:\WEBDEV"
```

**Note:** Recent versions of WebDev Application Server install to `C:\WEBDEV` without a version number. Older versions used `C:\WEBDEV <version>` (e.g., `C:\WEBDEV 28`). Check the parent directory from the path shown by `Get-Process` above.

### 1B: WebDev Project Directories

Each WebDev project has site files (including `_WEB` static assets served by Apache/IIS) and a data directory (session logs, temp files, and potentially HFSQL Classic data files). The process exclusions from 1A don't cover static asset serving — Apache/IIS is the process reading those files, not the WD sessions.

On a busy server, the web server reads from `_WEB` directories thousands of times per day. Each read triggers a Defender scan. In the Apache log analysis above, **67% of all HTTP traffic was static asset serving**.

This command extracts the unique project root directories from the registry across all installed WebDev versions (filtering out PCSoft's built-in management apps):

```powershell
Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\PC SOFT\WEBDEV" -Recurse |
  Get-ItemProperty | Where-Object { $_.PROJECTPATH -and $_.PROJECTPATH -notlike "C:\WEBDEV*" } |
  ForEach-Object { Split-Path (Split-Path $_.PROJECTPATH) } |
  Sort-Object -Unique
```

Exclude each directory listed:

```powershell
# Repeat for each project root shown above
Add-MpPreference -ExclusionPath "<project root>"
```

> **Warning — User-Uploaded Content:** If any WebDev application allows users to upload files (documents, images, etc.) that are then served from the project directory, those uploaded files will **not be scanned by Defender**. This is a real exposure — a malicious file upload would bypass real-time protection entirely. If your application has upload features that write to the project folder, you need to either:
> - Scan uploaded files in application code before writing them
> - Use command-line Defender scan (`Start-MpScan`) on the uploaded file before moving it into the excluded path
> - Store uploads outside the excluded directory and serve them through a separate, non-excluded path
> - Create a more surgical exclusion strategy instead of excluding the entire project directory

---

# Part 2: HFSQL Client/Server (If Running on This Machine)

If the machine is also running HFSQL in Client/Server mode, the database engine (`Manta.exe`) is a separate process that owns all database I/O. This is independent of the WebDev server — it may be on the same machine or a dedicated database server.

The PCSoft antivirus warning applies directly here: Manta.exe should be the **only** process touching the database files.

## What to Exclude

### Process Exclusion

```powershell
Add-MpPreference -ExclusionProcess "Manta.exe"
```

### Data Directory Exclusion

The HFSQL Client/Server data directory is configured in the HFSQL Control Center — it is **not** the same as the `HFPATH` registry key (that's for Classic mode). Check the HFSQL Control Center or server configuration for the actual data path.

```powershell
Add-MpPreference -ExclusionPath "<HFSQL C/S data directory>"
```

---

# Verify & Monitor

## Verify All Exclusions

```powershell
(Get-MpPreference).ExclusionPath
(Get-MpPreference).ExclusionProcess
(Get-MpPreference).ExclusionExtension
```

**Note:** Do not use `Select-Object` for this — PowerShell truncates arrays in table/list format. The above outputs the full list.

## Monitor

Run WebDevMonitor for 1-2 business days and compare MsMpEng CPU in NON_WD_SPIKE events. Expected result: MsMpEng drops from 6-26% to near-zero during business hours.

---

## PCSoft Sources

| Source | URL |
|--------|-----|
| HFSQL Recommendations (antivirus warning) | `help.windev.com/?1000017310` |
| Application Server Modules | `doc.windev.com/?3539018` |
| File Locations After Setup | `doc.pcsoft.fr/?3539051` |
| Registry Configuration | `doc.windev.com/?3539028` |
| File Extensions Reference | `doc.windev.com/?3084013` |
