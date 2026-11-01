#!/bin/bash
# Acceptance test of the MiKTeX engine package (fork only).
#
# usage: acceptance-test.sh all <archive> <SHA256SUMS>
#        acceptance-test.sh <step> [args]
#
# Runs in a clean, disposable macOS test machine (a VM copy), never on a
# machine with a MiKTeX someone uses: it creates and removes ~/bin, writes
# under ~/acc, ~/Library/Application Support/MarchTeX Test, /tmp/Test Dir,
# /tmp/Moved Dir and /tmp/Quarantine Test, and re-signs the engine. Needs
# the Command Line Tools (otool, vtool) and network access (packages are
# installed on demand), and verify-engine.sh in ~/acc.
#
# Follows INTEGRATION.md: unpacks the archive to a path with a space, runs
# the first-time setup, typesets with pdflatex, xelatex, lualatex and
# latexmk/biber through the links in bin/, installs packages on demand,
# moves the engine, checks the invocation rule, the dependencies and
# minos, a read-only engine, packages update, re-signing (ad-hoc, hardened
# runtime with and without entitlements, luaffi) and quarantine. Every
# check prints a PASS or FAIL line; nothing quarantined is ever run.

ACC=$HOME/acc
ENGINE=${ENGINE:-"/tmp/Test Dir/miktex"}
D=${D:-"$HOME/Library/Application Support/MarchTeX Test/miktex"}
DOCS=$ACC/docs

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; }
hdr() { printf '\n===== %s =====\n' "$*"; }

# the environment of INTEGRATION.md; extra NAME=VALUE pairs before the command
# go through EXTRA (newline separated)
run()
{
  local extra=()
  if [ -n "${EXTRA:-}" ]; then
    while IFS= read -r kv; do extra+=("$kv"); done <<< "$EXTRA"
  fi
  env -i \
    HOME="$HOME" \
    PATH="${RUNPATH:-$ENGINE/bin:/usr/bin:/bin:/usr/sbin:/sbin}" \
    MIKTEX_USERCONFIG="$D/texmfs/config" \
    MIKTEX_USERDATA="$D/texmfs/data" \
    MIKTEX_USERINSTALL="$D/texmfs/install" \
    MIKTEX_USERSTARTUPFILE="$D/texmfs/config/miktex/config/miktexstartup.ini" \
    ${extra[@]+"${extra[@]}"} \
    "$@"
}

# every step that runs the engine first checks that it is there
need_engine()
{
  [ -x "$ENGINE/bin/miktex" ] || { fail "no engine at $ENGINE"; return 1; }
}

machos()
{
  find "$ENGINE" -type f -print0 | while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in Mach-O*) printf '%s\0' "$f" ;; esac
  done
}

step_unpack()  # <archive> <SHA256SUMS>
{
  hdr "1 unpack"
  local archive=$1 sums
  sums=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
  (cd "$(dirname "$archive")" && grep -F "$(basename "$archive")" "$sums" | shasum -a 256 -c -) && pass sha256 || { fail sha256; return 1; }
  rm -rf "/tmp/Test Dir"
  mkdir -p "/tmp/Test Dir"
  /usr/bin/tar -xf "$archive" -C "/tmp/Test Dir" && pass "unpacked with /usr/bin/tar" || { fail unpack; return 1; }
  need_engine || return 1
  # a quarantined program would block on a Gatekeeper dialog: stop here
  local q
  q=$(find "$ENGINE" -print0 | xargs -0 xattr -s 2>/dev/null | grep -c com.apple.quarantine)
  [ "$q" -eq 0 ] && pass "no quarantine attribute" || { fail "$q files carry com.apple.quarantine; not running them"; return 1; }
  local x
  x=$(xattr -lr "$ENGINE" 2>&1)
  [ -z "$x" ] && pass "xattr -lr empty" || { echo "  other extended attributes:"; echo "$x" | head; }
  local n=0 bad=0
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    codesign --verify --strict "$f" 2>/dev/null || { bad=$((bad + 1)); echo "  invalid: $f"; }
  done < <(machos)
  [ $bad -eq 0 ] && [ $n -gt 0 ] && pass "codesign --verify --strict: $n Mach-O files" || fail "$bad of $n signatures invalid"
  bash "$ACC/verify-engine.sh" "$ENGINE" 26.0 "$ACC/minos.tsv" && pass verify-engine.sh || fail verify-engine.sh
}

step_startup()
{
  hdr "2 startup file"
  need_engine || return 1
  rm -rf "$D"
  mkdir -p "$D/texmfs/config/miktex/config"
  local out rc
  out=$(run "$ENGINE/bin/miktex" --version 2>&1); rc=$?
  echo "$out" | tail -3
  [ $rc -ne 0 ] && pass "missing startup file: exit $rc" || fail "missing startup file accepted"
  : > "$D/texmfs/config/miktex/config/miktexstartup.ini"
  out=$(run "$ENGINE/bin/miktex" --version 2>&1); rc=$?
  echo "$out" | head -2
  [ $rc -eq 0 ] && pass "empty startup file: runs" || fail "empty startup file: exit $rc"
}

step_setup()
{
  hdr "3 first-time setup"
  need_engine || return 1
  touch "$ACC/setup.marker"; sleep 1
  local rc=0
  run "$ENGINE/bin/initexmf" --disable-installer --set-config-value="[MPM]AutoInstall=1" || rc=1
  run "$ENGINE/bin/miktex" --disable-installer fndb refresh || rc=1
  run "$ENGINE/bin/miktex" --disable-installer fontmaps configure || rc=1
  run "$ENGINE/bin/miktex" --disable-installer languages configure || rc=1
  run "$ENGINE/bin/miktex" --disable-installer fndb refresh || rc=1
  # 100: updates are available (checkupdate.cpp)
  run "$ENGINE/bin/miktex" packages check-update; cu=$?
  echo "  check-update exit $cu"
  [ $cu -eq 0 ] || [ $cu -eq 100 ] || rc=1
  [ $rc -eq 0 ] && pass "setup commands" || fail "a setup command failed"
  local changed
  changed=$(find "$HOME" -newer "$ACC/setup.marker" ! -path "$D*" ! -path "$ACC*" ! -path "$HOME/Library/Application Support/MarchTeX Test" -print 2>/dev/null | grep -v -E '/Library/(Caches|Logs|Preferences|Saved Application State|IntelligencePlatform|Containers|Group Containers|Biome|Daemon Containers|Trial|Metadata|IdentityServices|Assistant|Suggestions|Keychains|HTTPStorages|Cookies|DuetExpertCenter|Accounts|Mail|Calendars|Sharing|PersonalizationPortrait|Application Support/(com\.apple|CallHistory|Knowledge|AddressBook|FileProvider|CloudDocs|icdd|Dock))' || true)
  [ -z "$changed" ] && pass "nothing written in HOME outside the data directory" || { fail "written in HOME:"; echo "$changed" | head -20; }
  { [ -e "$HOME/.miktex" ] || [ -e "$HOME/bin" ]; } && fail "~/.miktex or ~/bin exists" || pass "no ~/.miktex, no ~/bin"
  [ -s "$D/texmfs/config/miktex/config/miktexstartup.ini" ] && { fail "startup file not empty"; cat "$D/texmfs/config/miktex/config/miktexstartup.ini"; } || pass "startup file still empty"
  run "$ENGINE/bin/initexmf" --report > "$ACC/report-setup.txt" 2>&1
  sed -n '1,60p' "$ACC/report-setup.txt"
}

write_docs()
{
  mkdir -p "$DOCS"
  cat > "$DOCS/t-pdf.tex" <<'EOF'
\documentclass{article}
\usepackage{tikz}
\usepackage{hyperref}
\begin{document}
Hello from \href{https://miktex.org}{MiKTeX}, pdf\TeX.
\tikz \draw[thick] (0,0) circle (1) -- (2,1);
\end{document}
EOF
  cat > "$DOCS/t-unicode.tex" <<'EOF'
\documentclass{article}
\usepackage{fontspec}
\setmainfont{Times New Roman}
\usepackage{tikz}
\usepackage{hyperref}
\begin{document}
Unicode: Grüße, naïve café, Ελληνικά, \href{https://miktex.org}{link}.
\tikz \fill[blue!40] (0,0) rectangle (2,1);
\end{document}
EOF
  cat > "$DOCS/t-biber.tex" <<'EOF'
\documentclass{article}
\usepackage[backend=biber]{biblatex}
\addbibresource{t-biber.bib}
\begin{document}
Knuth wrote \cite{knuth}.
\printbibliography
\end{document}
EOF
  cat > "$DOCS/t-biber.bib" <<'EOF'
@book{knuth, author = {Donald E. Knuth}, title = {The {\TeX}book}, publisher = {Addison-Wesley}, year = {1984}}
EOF
  cat > "$DOCS/t-ondemand.tex" <<'EOF'
\documentclass{article}
\usepackage{lipsum}
\begin{document}
\lipsum[1]
\end{document}
EOF
}

typeset()  # <dir> <program> <doc>
{
  local dir=$1 prog=$2 doc=$3 out rc
  (cd "$dir" && rm -f "$doc.pdf" && run "$prog" -interaction=nonstopmode -halt-on-error "$doc.tex" > "$doc.$(basename "$prog").out" 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ -s "$dir/$doc.pdf" ]; then
    pass "$(basename "$prog") $doc: $(grep -m1 -o 'Output written on .*' "$dir/$doc.log")"
  else
    fail "$(basename "$prog") $doc: exit $rc"; tail -15 "$dir/$doc.$(basename "$prog").out"
  fi
  grep -m1 -o 'preloaded format=[^ ]*' "$dir/$doc.log" || true
  grep -h 'So far, you have not checked' "$dir/$doc.$(basename "$prog").out" && fail "update check message" || true
}

step_typeset()  # [label]
{
  hdr "4 typeset ${1:-}"
  need_engine || return 1
  write_docs
  local w=$ACC/run-${1:-first}
  rm -rf "$w"; mkdir -p "$w"; cp "$DOCS"/* "$w/"
  typeset "$w" pdflatex t-pdf
  typeset "$w" xelatex t-unicode
  typeset "$w" lualatex t-unicode
  (cd "$w" && run latexmk -pdf -interaction=nonstopmode t-biber.tex > t-biber.latexmk.out 2>&1) \
    && [ -s "$w/t-biber.pdf" ] && grep -q 'entry{knuth}' "$w/t-biber.bbl" && pass "latexmk + biber: $(grep -m1 -o 'Output written on .*' "$w/t-biber.log")" \
    || { fail "latexmk + biber"; tail -25 "$w/t-biber.latexmk.out"; }
  grep -m3 -E 'Running .(pdflatex|biber)|biber' "$w/t-biber.latexmk.out" | head -5
  typeset "$w" pdflatex t-ondemand
  grep -i -m3 'install' "$w/t-ondemand.pdflatex.out" || true
  # dynamic libraries really loaded: nothing from /opt/homebrew or /usr/local
  local libs
  local loaded libs n
  loaded=$(cd "$w" && EXTRA=DYLD_PRINT_LIBRARIES=1 run "$ENGINE/bin/miktex-pdftex" --version 2>&1 >/dev/null)
  libs=$(grep -E '/opt/homebrew|/usr/local' <<< "$loaded" || true)
  n=$(grep -cF "$ENGINE/lib/" <<< "$loaded" || true)
  [ -z "$libs" ] && [ "$n" -gt 0 ] && pass "DYLD_PRINT_LIBRARIES: $n libraries from the engine's lib/, none from /opt/homebrew or /usr/local (miktex-pdftex)" || { fail "dyld: $n from the engine; others:"; echo "$libs"; }
}

step_redemand()
{
  hdr "4b remove a package, typeset again"
  # not kpsewhich: with AutoInstall=1 it installs a missing file itself
  need_engine || return 1
  local L="$D/texmfs/install/tex/latex/lipsum/lipsum.sty"
  [ -e "$L" ] || { fail "lipsum is not installed before the removal"; return 1; }
  run "$ENGINE/bin/miktex" packages remove lipsum 2>&1 | tail -2
  [ ! -e "$L" ] && pass "lipsum removed (file gone)" || fail "lipsum.sty still there"
  local w=$ACC/run-redemand; rm -rf "$w"; mkdir -p "$w"; write_docs; cp "$DOCS"/t-ondemand.tex "$w/"
  typeset "$w" pdflatex t-ondemand
  [ -e "$L" ] && pass "lipsum installed again on demand" || fail "lipsum not installed again"
}

step_coexist()
{
  hdr "5 coexistence with ~/bin stubs"
  need_engine || return 1
  mkdir -p "$HOME/bin"
  for s in miktex pdflatex mpm initexmf; do
    printf '#!/bin/sh\necho "stub %s $*" >> "%s/stub-called.txt"\nexit 1\n' "$s" "$ACC" > "$HOME/bin/$s"
    chmod +x "$HOME/bin/$s"
  done
  rm -f "$ACC/stub-called.txt"
  grep -i 'linktarget\|LinkTarget' "$ACC/report-setup.txt" || run "$ENGINE/bin/initexmf" --report 2>&1 | grep -i 'link'
  # force a format rebuild: remove the pdflatex format
  [ -n "$(find "$D" -name 'pdflatex.fmt' -print -delete)" ] || fail "no pdflatex.fmt to delete"
  touch "$ACC/coexist.marker"; sleep 1
  local w=$ACC/run-coexist; rm -rf "$w"; mkdir -p "$w"; write_docs; cp "$DOCS"/* "$w/"
  RUNPATH="$ENGINE/bin:$HOME/bin:/usr/bin:/bin" typeset "$w" pdflatex t-pdf
  [ -n "$(find "$D" -name pdflatex.fmt -newer "$ACC/coexist.marker")" ] && pass "pdflatex.fmt rebuilt" || fail "pdflatex.fmt not rebuilt"
  [ ! -e "$ACC/stub-called.txt" ] && pass "engine did not call the ~/bin stubs" || { fail "stubs called:"; cat "$ACC/stub-called.txt"; }
  rm -f "$ACC/stub-called.txt"
  (cd "$w" && rm -f t-biber.pdf t-biber.aux t-biber.bbl t-biber.fdb_latexmk && RUNPATH="$HOME/bin:$ENGINE/bin:/usr/bin:/bin" run latexmk -pdf -interaction=nonstopmode t-biber.tex > coexist-badpath.out 2>&1)
  [ -e "$ACC/stub-called.txt" ] && pass "with ~/bin first in PATH, latexmk calls the stub pdflatex (PATH rule is needed): $(head -1 "$ACC/stub-called.txt")" || fail "stub not called with ~/bin first"
  rm -f "$ACC/stub-called.txt"
  (cd "$w" && rm -f t-biber.pdf t-biber.fdb_latexmk && RUNPATH="$ENGINE/bin:$HOME/bin:/usr/bin:/bin" run latexmk -pdf -interaction=nonstopmode t-biber.tex > coexist-goodpath.out 2>&1) && [ -s "$w/t-biber.pdf" ] && [ ! -e "$ACC/stub-called.txt" ] \
    && pass "with <engine>/bin first, latexmk works and no stub is called" || fail "engine-first PATH"
  rm -rf "$HOME/bin"
}

step_move()  # <new parent>
{
  hdr "6 move"
  need_engine || return 1
  local newparent=${1:-"/tmp/Moved Dir"}
  local fmt_before
  fmt_before=$(find "$D" -name '*.fmt' -exec stat -f '%m %N' {} \; | sort)
  rm -rf "$newparent"; mkdir -p "$newparent"
  mv "$ENGINE" "$newparent/miktex"
  ENGINE="$newparent/miktex"
  local dangling
  dangling=$(find "$ENGINE/bin" -type l ! -exec test -e {} \; -print)
  [ -z "$dangling" ] && pass "no dangling links after the move" || { fail dangling; echo "$dangling" | head; }
  touch "$ACC/move.marker"; sleep 1
  step_typeset moved
  local fmt_after
  fmt_after=$(find "$D" -name '*.fmt' -exec stat -f '%m %N' {} \; | sort)
  # pdflatex.fmt was rebuilt in step 5 already; compare the others
  [ "$fmt_before" = "$fmt_after" ] && pass "format files unchanged" || { fail "formats changed (before/after):"; diff <(echo "$fmt_before") <(echo "$fmt_after"); }
  [ -z "$(find "$D/texmfs/install" -newer "$ACC/move.marker" -name '*.tpm' -print)" ] && pass "no bootstrapping or installation again (no new tpm files)" || fail "packages installed after the move"
  local hits
  hits=$(grep -rlF "$newparent" "$D" 2>/dev/null | grep -v '/log/' || true)
  [ -z "$hits" ] && pass "data directory does not contain the new engine path (except logs)" || { fail "files with the new path:"; echo "$hits"; }
  hits=$(grep -rlF "/tmp/Test Dir" "$D" 2>/dev/null | grep -v '/log/' || true)
  [ -z "$hits" ] && pass "data directory does not contain the old engine path (except logs)" || { fail "old path in:"; echo "$hits"; }
  echo "ENGINE now: $ENGINE"
}

step_invocation()
{
  hdr "7 invocation through a link in a directory not named bin"
  need_engine || return 1
  local d=$ACC/texbin; rm -rf "$d"; mkdir -p "$d"
  ln -s "$ENGINE/bin/miktex-pdftex" "$d/pdflatex"
  local out
  out=$(RUNPATH="$d:/usr/bin:/bin" run "$d/pdflatex" --version 2>&1)
  echo "$out" | tail -3
  echo "$out" | grep -q 'Cannot derive the path prefix' && pass "fatal error as predicted" || fail "no 'Cannot derive' error"
}

step_deps()
{
  hdr "8 dependencies and minos"
  need_engine || return 1
  local bad=0 n=0
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    if otool -L "$f" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|/Users/|/private/'; then bad=1; echo "  $f"; fi
    if otool -l "$f" | grep -A2 LC_RPATH | grep -Eq 'path (/opt/homebrew|/usr/local|/Users/|/private/)'; then bad=1; echo "  rpath $f"; fi
  done < <(machos)
  [ $bad -eq 0 ] && [ $n -gt 0 ] && pass "otool -L / LC_RPATH: no external paths in $n Mach-O files" || fail "external paths (or no Mach-O files: $n)"
  echo "minos (vtool -show-build):"
  while IFS= read -r -d '' f; do vtool -arch arm64 -show-build "$f" 2>/dev/null | awk '$1 == "minos" { print $2; exit }'; done < <(machos) | sort -V | uniq -c
  echo "load commands outside @rpath/@loader_path (system only):"
  while IFS= read -r -d '' f; do otool -L "$f" | tail -n +2 | awk '{ print $1 }'; done < <(machos) | grep -v '^@' | sort | uniq -c
}

sign_all()  # codesign args...
{
  need_engine || return 1
  local bad=0
  while IFS= read -r -d '' f; do
    codesign -f "$@" "$f" 2>/dev/null || { bad=1; echo "  cannot sign $f"; }
  done < <(machos)
  return $bad
}

step_resign()
{
  hdr "9a ad-hoc re-sign"
  sign_all -s - && pass "re-signed ad-hoc" || { fail "re-sign"; exit 1; }
  step_typeset resigned
}

step_runtime()
{
  hdr "9b hardened runtime"
  sign_all -s - -o runtime && pass "signed ad-hoc with runtime" || { fail "sign with runtime"; exit 1; }
  local out rc
  # expected: dyld refuses the libraries (library validation, no Team ID)
  out=$(cd "$ACC" && run "$ENGINE/bin/miktex-pdftex" --version 2>&1); rc=$?
  echo "$out" | grep -m1 'Reason' | cut -c1-200
  [ $rc -ne 0 ] && grep -q 'different Team IDs' <<< "$out" && pass "runtime without entitlements: dyld refuses the libraries (exit $rc, 'different Team IDs'), as INTEGRATION.md says" || fail "runtime without entitlements: exit $rc"
  write_docs
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>\n' > "$ACC/dlv.plist"
  hdr "9c hardened runtime + disable-library-validation"
  sign_all -s - -o runtime --entitlements "$ACC/dlv.plist" && pass "signed with runtime + disable-library-validation" || { fail "sign with entitlements"; exit 1; }
  local w=$ACC/run-runtime-dlv; rm -rf "$w"; mkdir -p "$w"; cp "$DOCS"/* "$w/"
  typeset "$w" pdflatex t-pdf
  typeset "$w" lualatex t-unicode
  cat > "$w/ffi.lua" <<'EOF'
local ok, ffi = pcall(require, "ffi")
if not ok or not ffi then print("FFI-UNAVAILABLE " .. tostring(ffi)) os.exit(2) end
ffi.cdef("int getpid(void);")
print("FFI-OK pid=" .. ffi.C.getpid())
EOF
  hdr "9d back to plain ad-hoc"
  sign_all -s - && pass "re-signed ad-hoc" || { fail "re-sign ad-hoc"; exit 1; }
}

step_readonly()
{
  hdr "10 read-only engine"
  need_engine || return 1
  local img=$ACC/engine.dmg mnt=$ACC/mnt
  hdiutil detach -quiet -force "$mnt" 2>/dev/null
  rm -f "$img"; hdiutil create -quiet -srcfolder "$ENGINE" -volname "Engine RO" -format UDRO "$img" && pass "image created" || { fail "image"; return 1; }
  mkdir -p "$mnt"; hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mnt" "$img" && pass "attached read-only" || { fail attach; return 1; }
  touch "$mnt/x" 2>/dev/null && fail "the image is writable" || pass "the engine cannot be written to"
  local saveE=$ENGINE saveD=$D
  ENGINE=$mnt D="$HOME/Library/Application Support/MarchTeX RO/miktex"
  rm -rf "$D"; mkdir -p "$D/texmfs/config/miktex/config"; : > "$D/texmfs/config/miktex/config/miktexstartup.ini"
  step_setup
  local w=$ACC/run-ro; rm -rf "$w"; mkdir -p "$w"; write_docs; cp "$DOCS"/* "$w/"
  typeset "$w" pdflatex t-pdf
  typeset "$w" lualatex t-unicode
  ENGINE=$saveE D=$saveD
  hdiutil detach -quiet "$mnt"
}

step_update()
{
  hdr "12 packages update (repair of a changed MiKTeX package)"
  need_engine || return 1
  # with every package up to date, update does nothing; a changed file of
  # a MiKTeX package makes check-update report it and update reinstall it
  local m="$D/texmfs/install/miktex/config/package-manifests.ini" rel f
  rel=$(awk '/^\[miktex-dvips\]/{p=1;next} p&&/^\[/{exit} p&&/^run\[\]=/{sub(/^run\[\]=/,""); print; exit}' "$m")
  f="$D/texmfs/install/${rel#texmf/}"
  [ -n "$rel" ] && [ -f "$f" ] || { fail "no file of miktex-dvips found ('$rel')"; return 1; }
  printf '%% changed for the update test\n' >> "$f"
  run "$ENGINE/bin/miktex" packages check-update > "$ACC/cu.out" 2>&1; local cu=$?
  grep -q miktex-dvips "$ACC/cu.out" && [ $cu -eq 100 ] && pass "check-update reports miktex-dvips (exit 100)" || { fail "check-update exit $cu"; cat "$ACC/cu.out"; }
  local lg="$D/texmfs/data/miktex/log/miktex.log" lines
  lines=$(wc -l < "$lg" | tr -d ' ')
  touch "$ACC/update.marker"; sleep 1
  local fmts_before
  fmts_before=$(find "$D" -name '*.fmt' | wc -l | tr -d ' ')
  run "$ENGINE/bin/miktex" packages update > "$ACC/update.out" 2>&1; local rc=$?
  [ $rc -eq 0 ] && pass "packages update: exit 0" || { fail "packages update: exit $rc"; tail -20 "$ACC/update.out"; }
  grep -q 'Installing package miktex-dvips' "$ACC/update.out" && pass "miktex-dvips reinstalled" || fail "miktex-dvips not reinstalled"
  [ -f "$f" ] && ! grep -q 'changed for the update test' "$f" && pass "changed file restored" || fail "changed file not restored"
  grep -i -E 'warn|error' "$ACC/update.out" && fail "warning or error on the terminal (above)" || pass "no warning or error on the terminal"
  # only the log lines this update wrote (the whole file if it was rotated)
  local new
  if [ "$(wc -l < "$lg" | tr -d ' ')" -ge "$lines" ]; then new=$(tail -n +$((lines + 1)) "$lg"); else new=$(cat "$lg"); fi
  grep -q 'Installing links in target directory /var/empty/miktex-links' <<< "$new" && grep -q 'Operation not permitted: path="/var/empty/miktex-links"' <<< "$new" \
    && pass "links step failed in the log only (Operation not permitted)" || fail "links step not found in this update's log"
  grep -q 'command line: miktex --disable-installer --verbose fontmaps configure' <<< "$new" && grep -q 'command line: miktex --disable-installer --verbose languages configure' <<< "$new" \
    && pass "fontmaps and languages configured after the links step" || fail "fontmaps/languages not run by this update"
  [ -z "$(ls -A /var/empty)" ] && pass "/var/empty still empty" || fail "/var/empty not empty"
  [ ! -e "$HOME/bin" ] && pass "no ~/bin" || fail "~/bin exists"
  local fmts_after
  fmts_after=$(find "$D" -name '*.fmt' | wc -l | tr -d ' ')
  [ "$fmts_after" -lt "$fmts_before" ] && pass "the update deleted the format files ($fmts_before -> $fmts_after)" || echo "  formats before $fmts_before, after $fmts_after"
  local w=$ACC/run-after-update; rm -rf "$w"; mkdir -p "$w"; write_docs; cp "$DOCS"/* "$w/"
  typeset "$w" pdflatex t-pdf
  typeset "$w" lualatex t-unicode
  [ -n "$(find "$D" -name pdflatex.fmt -newer "$ACC/update.marker")" ] && pass "pdflatex.fmt made again after the update" || fail "pdflatex.fmt not made again"
}

step_ffi()
{
  hdr "9e luaffi under hardened runtime"
  need_engine || return 1
  local w=$ACC/run-ffi; rm -rf "$w"; mkdir -p "$w"
  cat > "$w/ffi.lua" <<'EOF2'
local ok, ffi = pcall(require, "ffi")
if not ok or not ffi then print("FFI-UNAVAILABLE " .. tostring(ffi)) os.exit(2) end
ffi.cdef("int getpid(void);")
print("FFI-OK pid=" .. ffi.C.getpid())
EOF2
  printf 'print("PLAIN-OK")\n' > "$w/plain.lua"
  local plist=$ACC/dlv.plist jit=$ACC/dlv-jit.plist out rc
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>\n' > "$plist"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>\n' > "$jit"
  sign_all -s - -o runtime --entitlements "$plist" || { fail "sign with runtime"; exit 1; }
  out=$(cd "$w" && run "$ENGINE/bin/texlua" plain.lua 2>&1); rc=$?
  [ $rc -eq 0 ] && [ "$out" = PLAIN-OK ] && pass "runtime+dlv: texlua without ffi runs" || fail "runtime+dlv: plain texlua exit $rc"
  out=$(cd "$w" && run "$ENGINE/bin/texlua" ffi.lua 2>&1); rc=$?
  [ $rc -eq 137 ] && pass "runtime+dlv: ffi killed (SIGKILL, exit 137), as INTEGRATION.md says" || fail "runtime+dlv: ffi exit $rc: $out"
  codesign -f -s - -o runtime --entitlements "$jit" "$ENGINE/bin/miktex-luatex" 2>/dev/null || { fail "sign miktex-luatex"; exit 1; }
  out=$(cd "$w" && run "$ENGINE/bin/texlua" ffi.lua 2>&1); rc=$?
  [ $rc -eq 0 ] && [[ $out == FFI-OK* ]] && pass "runtime+dlv+allow-unsigned-executable-memory on miktex-luatex: ffi works" || fail "with entitlement: ffi exit $rc: $out"
  sign_all -s - || { fail "re-sign ad-hoc"; exit 1; }
  out=$(cd "$w" && run "$ENGINE/bin/texlua" ffi.lua 2>&1); rc=$?
  [ $rc -eq 0 ] && pass "plain ad-hoc again: ffi works" || fail "ad-hoc: ffi exit $rc"
  # nothing may keep runtime or entitlements
  bash "$ACC/verify-engine.sh" "$ENGINE" 26.0 > "$ACC/verify-after-resign.txt" 2>&1 && pass "verify-engine.sh after the re-sign tests (plain ad-hoc everywhere)" || { fail "verify-engine.sh after re-sign"; grep error "$ACC/verify-after-resign.txt" | head; }
}

step_quarantine()  # <archive>
{
  hdr "extra: quarantine (nothing quarantined is run)"
  need_engine || return 1
  local q="/tmp/Quarantine Test"; rm -rf "$q"; mkdir -p "$q"
  cp "$1" "$q/engine.tar.xz"
  xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" "$q/engine.tar.xz"
  /usr/bin/tar -xf "$q/engine.tar.xz" -C "$q"
  local n total
  n=$(find "$q/miktex" -print0 | xargs -0 xattr -s 2>/dev/null | grep -c com.apple.quarantine)
  total=$(find "$q/miktex" | wc -l | tr -d ' ')
  [ "$n" -eq "$total" ] && pass "/usr/bin/tar passes quarantine to all $total unpacked entries" || { [ "$n" -gt 0 ] && pass "quarantine on $n of $total entries" || fail "no quarantine after unpacking"; }
  local a b
  a=$(spctl --assess --type execute "$q/miktex/bin/miktex" 2>&1)
  b=$(spctl --assess --type execute "$ENGINE/bin/miktex" 2>&1)
  echo "  spctl, quarantined: $a"
  echo "  spctl, not quarantined: $b"
  echo "  (spctl rejects ad-hoc tools either way; the Gatekeeper dialog seen in the first round is the evidence that quarantined programs are blocked)"
  xattr -dr -s com.apple.quarantine "$q/miktex" 2>/dev/null; xattr -dr com.apple.quarantine "$q/miktex"
  n=$(find "$q/miktex" -print0 | xargs -0 xattr -s 2>/dev/null | grep -c com.apple.quarantine)
  [ "$n" -eq 0 ] && pass "xattr -dr removes it from every entry" || fail "$n entries keep quarantine"
  rm -rf "$q"
}

step_all()  # <archive> <SHA256SUMS>
{
  local archive=$1 sums=$2
  rm -rf "$ACC"/run-* "$ACC"/*.marker "$ACC"/stub-called.txt
  step_unpack "$archive" "$sums" || exit 1
  step_startup || exit 1
  step_setup
  step_typeset first
  step_redemand
  step_coexist
  step_invocation
  step_move "/tmp/Moved Dir"   # sets ENGINE
  step_deps
  # the shipped signatures: the read-only image and the update first
  step_readonly
  step_update
  step_resign
  step_runtime
  step_ffi
  step_quarantine "$archive"
  hdr "13 update-check message"
  local n total
  total=$(ls "$ACC"/run-*/*.out 2>/dev/null | wc -l | tr -d ' ')
  n=$(grep -l "So far, you have not checked" "$ACC"/run-*/*.out 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && [ "$total" -gt 0 ] && pass "no typesetting output has the update-check message ($total outputs)" || fail "$n of $total outputs have the message"
  hdr "summary"
  echo "ENGINE: $ENGINE"
}

step="$1"; shift
"step_$step" "$@"
