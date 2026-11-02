# MiKTeX for Apple Silicon (unofficial build)

**This is not an official MiKTeX release.** It is built from the branch
[`mac_port`](https://github.com/LinusAuditore/miktex-macos-unofficial/tree/mac_port) of the
fork LinusAuditore/miktex-macos-unofficial, which ports MiKTeX to native Apple Silicon. The
MiKTeX project does not build, sign or support it. Please report problems
with this build in the fork's
[issue tracker](https://github.com/LinusAuditore/miktex-macos-unofficial/issues), not to the
MiKTeX project. Inside the application it still calls itself MiKTeX
Console, with MiKTeX's version number.

## Security update (26.5-unofficial.2)

This release updates three libraries that the application builds from its
own sources to the versions in TeX Live. They are newer than in MiKTeX
26.5. All users of 26.5-unofficial.1 should update (see
[Updating](#updating)).

- **pplib 2.2**, including TeX Live r80628: a crafted encrypted PDF could
  overflow pplib's key buffers when it was included with lualatex or
  xelatex.
- **xpdf 4.06**, which pdfTeX uses to include PDF files: fixes the
  published CVEs listed in xpdf's CHANGES for 4.05 and 4.06 (for example
  CVE-2024-2971, CVE-2024-3247 and CVE-2025-2574).
- **HarfBuzz 15.0.0**: robustness and memory-safety fixes for malformed
  fonts (upstream NEWS, 14.2.1 to 15.0.0).

Nothing else changed. Documents typeset the same way as with
26.5-unofficial.1.

## Requirements

- A Mac with Apple Silicon
- macOS 26 or later
- Rosetta is not needed

## Installation

If you have used the official MiKTeX for Mac before, remove it first (see
[Uninstallation](#uninstallation)); this build uses the same application
name and the same data directory.

1. Open the disk image and drag **MiKTeX Console** to **Applications**.
   Start it from Applications, not from the disk image.
2. The application is not signed with an Apple Developer ID and not
   notarized, so macOS blocks it. Remove the quarantine attribute in
   Terminal before the first start:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/MiKTeX Console.app"
   ```

   Alternatively, try to open the application once, close the warning,
   then click "Open Anyway" in System Settings > Privacy & Security (within
   about an hour), enter your password and confirm with "Open".
3. Start MiKTeX Console and finish the private setup. MiKTeX links its
   commands (`pdflatex`, `xelatex`, `lualatex`, `latexmk`, `biber`, ...)
   into `~/bin` and adds `~/bin` to `PATH` in `~/.zprofile` (and in
   `~/.bash_profile`, if it exists). Open a new Terminal window to use them.
4. Missing packages are installed from the MiKTeX package repository when a
   document needs them.

## Updating

To update from an earlier build:

1. Quit MiKTeX Console.
2. Open the new disk image and drag **MiKTeX Console** to **Applications**,
   replacing the old one.
3. Remove the quarantine attribute again (step 2 of
   [Installation](#installation)).

Your settings, the installed packages and the commands in `~/bin` are
kept; you do not need to run the setup again.

`~/bin` is appended to `PATH`. If TeX Live or MacTeX is installed, its
`/Library/TeX/texbin` comes first, so `pdflatex` and friends in Terminal
still run TeX Live. To use MiKTeX's commands, put `~/bin` before
`/Library/TeX/texbin` in `PATH`.

## Known limitations

- **Ghostscript** is not included. EPS figures, `pdfcrop`, `ps2pdf` and
  similar tools need it: install Ghostscript (for example with Homebrew)
  so that `gs` is on `PATH`. Applications started from the Finder,
  TeXworks included, do not see `/opt/homebrew/bin` unless you add it to
  their search path.
- **biber** comes from MiKTeX's `biber-darwin-x86_64` package (download of
  about 71 MB). Despite the name, its biber is a universal binary and runs
  natively on Apple Silicon, without Rosetta. biber is an essential
  package, so the first check for updates installs it, as on the other
  platforms; otherwise it is installed when biber runs for the first time.
- **xkeyval** and **tabu** are not installed on the fly: the package index
  of the MiKTeX repository lists no files for them at the moment.
  Documents that need them (xkeyval is loaded by glossaries, for example)
  stop with "File `xkeyval.sty' not found" (or `tabu.sty`) until you run
  `miktex packages install xkeyval` or `miktex packages install tabu`
  once.
- **cm-super** is not installed on the fly (as with MiKTeX on other
  platforms). Documents with `\usepackage[T1]{fontenc}` and microtype can
  fail with "auto expansion is only possible with scalable fonts": add
  `\usepackage{lmodern}`, or install the cm-super package.
- Fonts that fontspec loads by name are not installed on the fly; use the
  file name, or install the font package first.
- **Editors started from the Finder** do not get the `PATH` of
  `~/.zprofile`; set them up to use the commands in `~/bin`. TeXworks,
  started from MiKTeX Console, should find them.
- Packages that run Python (minted, pythontex) need `python3`, which comes
  with Apple's Command Line Tools.
- There is no Java runtime and no xindy, as with MiKTeX on Linux.
- The Dock may show a blank icon for the running MiKTeX Console.

## Uninstallation

1. Quit MiKTeX Console and remove the MiKTeX links from `~/bin`:

   ```sh
   find ~/bin -lname '/Applications/MiKTeX Console.app/*' -delete
   ```

2. Delete `/Applications/MiKTeX Console.app` and
   `~/Library/Application Support/MiKTeX`.
3. Remove the lines from `# >>> MiKTeX >>>` to `# <<< MiKTeX <<<` in
   `~/.zprofile` (and in `~/.bash_profile`).

## Changes from MiKTeX

The source differences are on
[GitHub](https://github.com/MiKTeX/miktex/compare/next...LinusAuditore:miktex-macos-unofficial:mac_port).
Besides build and packaging fixes for Apple Silicon, this build behaves
differently from upstream MiKTeX in these ways:

- Finishing the setup adds the link directory to `PATH` (see above).
- Packages are installed on the fly without asking.
- `mktexlsr`, `texhash`, `updmap` and `texlinks` are symbolic links.
- XeTeX also sees the fonts in `~/Library/Fonts` and the downloadable
  macOS fonts.
- Python scripts fall back to `python3`.
- Packages for `darwin-x86_64` (biber) are used on Apple Silicon.
- pplib, xpdf and HarfBuzz are newer than in MiKTeX 26.5 (synced with
  TeX Live, see [Security update](#security-update-265-unofficial2)).

## Third-party components

Besides MiKTeX, the application bundle contains libraries built by
Homebrew, among them Qt 6, ICU, OpenSSL, curl, Boost, GLib, GMP, MPFR,
FreeType and log4cxx, and libraries built from the sources in this
repository, among them HarfBuzz, cairo, fontconfig, gd, pplib, xpdf and
poppler. They are covered by their own licenses; the Homebrew formulae and
the sources in this repository name them.
