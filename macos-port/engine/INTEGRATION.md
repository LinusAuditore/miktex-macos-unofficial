# Integrating the MiKTeX engine package

The engine package is an unofficial, command-line-only build of MiKTeX for
Apple Silicon (arm64) macOS, made by the fork
[LinusAuditore/miktex-macos-unofficial](https://github.com/LinusAuditore/miktex-macos-unofficial)
for applications that embed a TeX engine (first of all MarchTeX). It has no
Qt and no user interface. It is not an end-user installer: end users install
the fork's `.dmg`.

This file is part of every engine package and is kept in the fork's
repository as `macos-port/engine/INTEGRATION.md`. "The host" is the
application that embeds the engine.

## Contents

```text
miktex/
├── bin/              programs (miktex-*, miktex, initexmf, mpm, ...) and
│                     relative symbolic links for the commands without
│                     miktex- prefix (pdflatex, lualatex, latexmk, ...)
├── libexec/miktex/   script wrappers (runperl, runpython, ...)
├── lib/              MiKTeX libraries and the Homebrew libraries they need
├── texmfs/install/miktex/bootstrapping/   the packages of the first setup
├── INTEGRATION.md    this file
└── engine-manifest.json
```

- `bin`, `libexec/miktex`, `lib` and `texmfs/install` must keep their names
  and their places relative to each other. The top directory (`miktex`) can
  have any name, and it can be moved as a whole to any path, also a path
  with spaces.
- All load commands and rpaths are relative (`@rpath`, `@loader_path`); the
  only absolute ones point to `/usr/lib` and `/System`.
- Every Mach-O file has an ad-hoc signature, without Team ID and without
  hardened runtime.
- `engine-manifest.json` records the MiKTeX version, the source commits, the
  minimum macOS version (the highest `minos` of all Mach-O files), the
  Homebrew libraries, the SHA-256 of the bootstrapping archives, and every
  command in `bin/`.
- Requirements: macOS 26.0 or later (see `macos.min_version` in the
  manifest), arm64 only.

## Rules

1. **Do not put the engine under `/usr` or `/opt`**, and do not name its top
   directory `usr`. Under `/usr` or `/opt`, MiKTeX treats itself as a shared
   (system-wide) installation.
2. **Run the engine only through `<engine>/bin/`**, by the absolute path of
   a program or link in that directory. The engine finds its installation
   prefix from the path it was started with, without resolving symbolic
   links:
   - a symbolic link in a directory not named `bin` (for example
     `/Library/TeX/texbin/pdflatex` or `Contents/Helpers/pdflatex`) makes
     every program stop with "Cannot derive the path prefix of the running
     executable";
   - a copy of a program outside the engine does not find its libraries;
   - the wrappers in `libexec/miktex` work only through their links in
     `bin/` (they read the script name from the name they were started
     with).
3. **Start every MiKTeX process with the environment below**, also the
   first-time setup, and pass no other variables.
4. **Do not run** `miktexsetup`, `miktex links install`, `initexmf
   --principal=setup`, or `initexmf --portable`/`--shared` options: they
   write absolute links or put state into the engine directory.

## Environment

`<D>` is the host's data directory for MiKTeX, for example
`~/Library/Application Support/<Host>/miktex`. All paths must be absolute.

| Variable | Value |
|---|---|
| `HOME` | the real home directory (required) |
| `PATH` | `<engine>/bin:/usr/bin:/bin:/usr/sbin:/sbin` — `<engine>/bin` must come first: scripts such as latexmk start `pdflatex` by name through `PATH` |
| `MIKTEX_USERCONFIG` | `<D>/texmfs/config` |
| `MIKTEX_USERDATA` | `<D>/texmfs/data` |
| `MIKTEX_USERINSTALL` | `<D>/texmfs/install` |
| `MIKTEX_USERSTARTUPFILE` | `<D>/texmfs/config/miktex/config/miktexstartup.ini` — **the file must exist** (an empty file is enough); if it does not, every MiKTeX program stops with a fatal error |
| `TMPDIR` | optional |

Do not pass any other `MIKTEX_*` variable, `TEXINPUTS` and the other
`*INPUTS` variables, `TEXMF*`, or `FONTCONFIG_*`.

External programs are found only through `PATH`:

- Ghostscript (`gs`), needed for EPS graphics (epstopdf), `ps2pdf` and
  PostScript input of dvisvgm, is not part of macOS or the engine. To use
  a Ghostscript the user installed (e.g. `/opt/homebrew/bin`), append its
  directory **after** `<engine>/bin` and the system directories, never
  before them.
- Script interpreters come from the system: Perl (`/usr/bin/perl`) is part
  of macOS; `/usr/bin/python3` and `/usr/bin/java` are stubs that open an
  installation dialog unless the Command Line Tools or a JDK are
  installed. Commands that run Python or Java scripts (e.g. `arara`,
  `bib2gls`) depend on that.

With this environment, MiKTeX keeps all its state in `<D>`: packages,
format files, the file name database, the font caches, logs, and settings.
The engine directory is never written to, so it can be read-only (for
example inside a signed application bundle).

Remaining contact points with the user's home directory:

- `~/.miktex/texmfs/config/miktex/config/miktex.ini` is read if it exists
  (a MiKTeX installed by the user in `~/.miktex`). If it has
  `[Core]SharedSetup=1`, or `LastAdminMaintenance` without `SharedSetup`,
  the engine behaves as a shared installation. The environment cannot
  prevent this; a host can detect the file and warn;
- per-user configuration files of the scripts, first of all latexmk's
  `~/.latexmkrc` and `~/.config/latexmk/latexmkrc` (they can, for example,
  set the TeX command latexmk runs); a host that wants its own settings
  runs `latexmk -norc -r <its file>`;
- fonts: the system font directories, `~/Library/Fonts`, `~/.fonts`;
- the engine is built with the link directory `/var/empty/miktex-links`,
  which can never exist: it never looks for programs in `~/bin`, and never
  writes links there.

## First-time setup

Run once, with the environment above, before the first typesetting run:

```sh
ENGINE="/path/to/miktex"                  # absolute path
D="$HOME/Library/Application Support/<Host>/miktex"
mkdir -p "$D/texmfs/config/miktex/config"
: > "$D/texmfs/config/miktex/config/miktexstartup.ini"
"$ENGINE/bin/initexmf" --disable-installer --set-config-value="[MPM]AutoInstall=1"
"$ENGINE/bin/miktex" --disable-installer fndb refresh
"$ENGINE/bin/miktex" --disable-installer fontmaps configure
"$ENGINE/bin/miktex" --disable-installer languages configure
"$ENGINE/bin/miktex" --disable-installer fndb refresh
"$ENGINE/bin/miktex" packages check-update     # needs the network
```

- The first `initexmf` installs the bootstrapping packages into
  `$MIKTEX_USERINSTALL`.
- `[MPM]AutoInstall=1`: missing packages are installed automatically while
  typesetting (the engine has no user interface to ask). `kpsewhich` does
  the same: looking up a file of a package that is not installed installs
  it.
- `packages check-update` exits with 0 when there are no updates and with
  **100 when updates are available** (it then lists them); neither is an
  error.
- `packages check-update` records the first update check. Until then, TeX
  programs print "So far, you have not checked for MiKTeX updates." when
  they exit. If the setup runs offline, run it later; if a TeX program ran
  before the first check, run `initexmf --report` after it.
- Do not pass `--user-*` options: the environment is enough, and the
  startup file stays empty, so `<D>` is not written into it.

After the setup, `pdflatex`, `xelatex`, `lualatex` and the other commands
in `<engine>/bin` work; format files are made on first use.

## Moving

- **Moving the engine** needs no new setup, as long as the environment
  stays the same.
- **Moving `<D>`** needs `miktex fndb refresh` and `miktex fontmaps
  configure` (the file name databases are named after the root paths).

## Updates

- `miktex packages update` (and `packages check-update`) can be run by the
  host. When it installs or removes packages, it finishes by refreshing the
  file name database, trying to update the links in the link directory,
  and configuring font maps and languages. With the engine's link directory
  the links step fails in a child process ("Operation not permitted:
  /var/empty/miktex-links", recorded in the log only); the update itself
  succeeds (exit code 0) and the other steps run.
- An update deletes the format files; they are made again on their next
  use, so the first typesetting run after an update takes longer.
- The commands in `bin/` are fixed when the package is made. A command that
  a later package update adds (a new script or format) has no link in
  `bin/` until a new engine package is released.

## Code signing

- The engine is ad-hoc signed. A host that is signed with a Developer ID
  and notarized signs every Mach-O file of the engine again, with hardened
  runtime (`codesign -f -o runtime -s <identity>`): notarization requires
  hardened runtime on every executable.
- Every engine program runs as its own process with its own entitlements;
  the host application's entitlements do not apply to it. Entitlements an
  engine program needs go onto that program when it is signed.
- Under hardened runtime, library validation rejects libraries without the
  same Team ID: sign the libraries in `lib/` with the same identity.
  Otherwise dyld stops the program ("Library not loaded: @rpath/...
  mapping process and mapped file (non-platform) have different Team
  IDs"). This also happens with an ad-hoc signature with `-o runtime`.
- Known exceptions under hardened runtime:
  - `bin/miktex-dvisvgm` loads the Ghostscript library (`libgs`) the user
    installed, at run time, for PostScript and PDF input; library
    validation rejects it unless that program has
    `com.apple.security.cs.disable-library-validation`;
  - `bin/miktex-luatex` and `bin/miktex-luahbtex` (and the commands that
    link to them: `lualatex`, `texlua`, ...): Lua C modules (binary modules
    loaded with `require`) need `dlopen` of code with another Team ID
    (`disable-library-validation`); luaffi (`ffi`) needs executable memory
    (`com.apple.security.cs.allow-unsigned-executable-memory`): without
    it, the process is killed (SIGKILL) when a document or script uses
    `ffi`;
  - `lib/libcrypto.3.dylib` and `lib/libcrypto.4.dylib` read
    `openssl.cnf` from `/opt/homebrew/etc/openssl@3` and
    `/opt/homebrew/etc/openssl@4` if Homebrew is installed.
- biber is installed by the package manager into `$MIKTEX_USERINSTALL`
  and runs as a separate process; it carries its own Developer ID
  signature.
- **App Sandbox is not supported.** Child processes inherit the sandbox;
  installing packages on demand, running scripts (Perl, Python, biber), and
  writing into `<D>` have not been evaluated under it.
- Quarantine: if the archive is downloaded with a browser, unpacking it
  (also with `/usr/bin/tar`) gives every file the quarantine attribute.
  Gatekeeper then blocks each program ("Apple could not verify ...") and
  kills it. Remove the attribute after unpacking:
  `xattr -dr com.apple.quarantine miktex`. An engine embedded in a signed
  and notarized application at build time is not affected.

## Licenses

MiKTeX is free software (GPL-2.0-or-later and others, see `COPYING.md` in
the fork). The package contains third-party components; `licenses/` has
their license texts: `licenses/README.txt` explains the layout, lists every
component with its SPDX expression and has the acknowledgements some
licenses require in the documentation of a product that includes them; a
host that ships the engine should ship `licenses/` with it.

`licenses/sources.tsv` says where the corresponding source of each
component under a copyleft license is: the fork's source archive of the
build (attached to every release by GitHub), or a `source-*` asset of the
engine release (the sources and formula files of the Homebrew libraries,
and upstream sources: the xml2pmx Oberon program and the URW base35 fonts
compiled into dvisvgm). The CI build fails if the license table
(`macos-port/engine/licenses/components.json`) and the build disagree.
