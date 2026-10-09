<h1 align="center">💽 DiskPulse</h1>

<p align="center">
  <strong>See where the space went.</strong>
</p>

<p align="center">
  A focused Windows disk dashboard that turns local scans into a clear picture<br>
  of capacity, changes, and the evidence behind every comparison.
</p>

<p align="center">
  <a href="https://github.com/seiya058904/DiskPulse/releases/latest"><strong>⬇️ Download for Windows</strong></a>
  &nbsp;·&nbsp;
  <a href="#get-started">🚀 Get Started</a>
  &nbsp;·&nbsp;
  <a href="#what-diskpulse-shows">📊 Explore the Report</a>
  &nbsp;·&nbsp;
  <a href="#privacy--optional-ai">🔒 Privacy &amp; AI</a>
</p>

<p align="center">
  <sub>WINDOWS &nbsp;·&nbsp; OFFLINE-FIRST &nbsp;·&nbsp; LOCAL HTML REPORTS &nbsp;·&nbsp; AI OPTIONAL</sub><br>
  <sub>LATEST VERIFIED RELEASE: v1.5.1</sub>
</p>

<p align="center">
  <img width="760" alt="DiskPulse — original project artwork" src="https://github.com/user-attachments/assets/4b06b439-eb31-4c4f-9e0e-f17e7529a342" />
</p>

---

> **Disk space is easy to measure. Explaining where it went takes context.**
>
> DiskPulse connects today's scan with trustworthy history, so you can distinguish real changes from missing data, incomplete scans, or a drive that is no longer the same volume.

<a id="what-diskpulse-shows"></a>
## 📊 What DiskPulse Shows

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>💽 Capacity at a Glance</h3>
      <p><sub>FREE SPACE · USAGE · PRESSURE</sub></p>
      <p>Review fixed drives, total and available capacity, utilization, and the current storage picture without digging through folders by hand.</p>
    </td>
    <td width="50%" valign="top">
      <h3>📁 What Changed?</h3>
      <p><sub>GROWTH · RELEASED SPACE · DIRECTORY COMPARISON</sub></p>
      <p>See where space increased or decreased across the drive root and its first two directory levels, compared with a valid earlier scan.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>📈 History & Trends</h3>
      <p><sub>BASELINES · COMPARISON WINDOWS</sub></p>
      <p>Look beyond a single snapshot. Compare eligible history and understand trends or estimates in the context of the data actually available.</p>
    </td>
    <td width="50%" valign="top">
      <h3>🛡️ Evidence You Can Trust</h3>
      <p><sub>SCAN QUALITY · COVERAGE · VOLUME IDENTITY</sub></p>
      <p>Partial coverage, excluded paths, and unknown values are clearly distinguished. A reused drive letter cannot silently turn a different volume into the old one.</p>
    </td>
  </tr>
</table>

> [!NOTE]
> **Your first scan is the starting point, not a change report.** DiskPulse needs a previous, comparable baseline before it can reliably explain what grew or shrank. An incomplete scan does not overwrite a valid complete baseline.

<a id="get-started"></a>
## 🚀 Get Started

### 1. Install

Download the current Windows installer from **[GitHub Releases](https://github.com/seiya058904/DiskPulse/releases/latest)**.

- **Current verified version:** [v1.5.1](https://github.com/seiya058904/DiskPulse/releases/tag/v1.5.1)
- **Installer:** [DiskPulse-Setup-1.5.1.exe](https://github.com/seiya058904/DiskPulse/releases/download/v1.5.1/DiskPulse-Setup-1.5.1.exe)
- **Checksum:** [SHA-256 file](https://github.com/seiya058904/DiskPulse/releases/download/v1.5.1/DiskPulse-Setup-1.5.1.sha256)

### 2. Run a scan

Launch **DiskPulse** and select the disk-scanning action. The application collects drive and directory-size metadata, then opens a generated **local HTML dashboard** in your browser.

### 3. Compare over time

Run another scan after your storage has changed. Use the dashboard to inspect available comparisons, directory growth, freed space, and scan quality before drawing conclusions.

<p align="center"><code>SCAN &nbsp;→&nbsp; ESTABLISH A BASELINE &nbsp;→&nbsp; COMPARE &nbsp;→&nbsp; UNDERSTAND</code></p>

**Requirements:** Windows with Windows PowerShell 5.1 or newer. The normal installed application does not need Node.js, Python, or an online service.

<a id="privacy--optional-ai"></a>
## 🔒 Privacy First. AI Only If You Want It.

The scanner and HTML dashboard work **locally and offline by default**. DiskPulse is a reporting tool, not an automatic disk cleaner.

| By default | Only if you opt in |
| --- | --- |
| Scan fixed-drive and directory-size metadata | Send a sanitized summary to a configured AI endpoint |
| Save local scan history and reports | Request a supplementary natural-language explanation |
| Display unknown or incomplete results honestly | Configure or remove your AI settings |
| **No file-content reading or automatic deletion** | **No AI account or API key needed for ordinary scans** |

### 🧠 Optional AI Explanation

The optional AI feature can help explain capacity and directory changes in plain language. It is **off until explicitly enabled and configured**; you can also copy analysis data from the dashboard and ask an AI service yourself.

- Run `configure-ai.bat` when using the source distribution to configure, disable, or remove AI settings.
- Configured API keys are stored with **Windows DPAPI protection scoped to the current user**; they are not inserted into generated reports.
- Remote AI endpoints require **HTTPS** (loopback development endpoints are the exception), and HTTP redirects are rejected.
- AI-bound summaries sanitize user-directory paths. **Local reports can still contain real local paths**, so review them before sharing.
- An unavailable AI provider does **not** prevent the local disk report from being generated. AI commentary is supplementary, not a replacement for scan evidence.

> [!IMPORTANT]
> **A trend is only as reliable as its baseline.** DiskPulse separates complete, partial, unavailable, and non-comparable observations. It will not present an unknown change as `0` or treat a newly mounted volume as the old drive merely because the letter matches.

## 🗂️ Files, History & Everyday Use

DiskPulse keeps user history and generated reports under:

```text
%LOCALAPPDATA%\DiskPulse\data\runtime
```

Existing user data is intended to survive ordinary upgrades and uninstall. Avoid deleting that directory if you want to keep your history. The scanner excludes reparse points such as junctions and symbolic links, as well as designated system paths; its report identifies incomplete or inaccessible areas rather than pretending they were scanned.

<details>
<summary><strong>⚙️ For developers — source, commands &amp; verification</strong></summary>

DiskPulse uses **PowerShell, a C# directory scanner, and a browser-rendered HTML/CSS/JavaScript report**. The editable implementation lives in [`src/`](src/). [`check.bat`](check.bat) is a **generated runtime artifact**—do not edit its application logic directly.

### Useful entry points

| File | Purpose |
| --- | --- |
| [`DiskPulse.vbs`](DiskPulse.vbs) | Normal launch without a visible console window |
| [`check.bat`](check.bat) | Diagnostic scan with console progress |
| [`check-profile.bat`](check-profile.bat) | Performance profiling |
| [`configure-ai.bat`](configure-ai.bat) | Optional AI configuration |
| [`src/`](src/) | Canonical scanner, application, persistence, and dashboard sources |

### Build & verify

Run from the repository root in Windows PowerShell:

```powershell
# Regenerate the runtime after changing canonical source
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-check.ps1

# Repository verification
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1

# Include the NSIS installer build when NSIS is available
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1 -IncludeInstaller
```

Installer packaging is maintained in [`build-installer.ps1`](build-installer.ps1) and [`installer/`](installer/). Additional local browser QA is available through [`tests/browser/Invoke-DiskPulseBrowserQA.ps1`](tests/browser/Invoke-DiskPulseBrowserQA.ps1); it is an extended check, not a claim that all browsers have been tested.

- [Product principles](PRODUCT.md) — what the tool should communicate and what it deliberately avoids.
- [Dashboard design](DESIGN.md) — hierarchy, contrast, accessibility, and visual constraints.
- [Repository guidelines](AGENTS.md) — code boundaries, privacy invariants, verification, and release rules.

</details>

---

<p align="center">
  <sub>Know what's full. Understand what changed. Keep the evidence.</sub><br>
  <sub>DiskPulse · A focused Windows storage dashboard.</sub>
</p>
