#!/bin/bash
# Verify the MiKTeX engine package (fork CI only).
#
# usage: verify-engine.sh <engine-dir> [<max-min-version> [<minos-tsv>]]
#
# Checks every Mach-O file: arm64 only; no load command or LC_RPATH that
# points outside the package (Homebrew, /usr/local, home, temporary or
# build directories); every @rpath and @loader_path dependency exists in
# the package; the libraries in lib/ have the install name @rpath/<name>;
# a valid ad-hoc signature without Team ID and without hardened runtime.
# Checks that every symbolic link is relative and resolves inside the
# package, that the miktex- programs and the links exist in bin/, and that
# nothing the engine does not ship is left (static libraries, application
# bundles, man pages).
#
# Prints the distribution of minimum macOS versions (minos) of the Mach-O
# files; the highest one is the effective minimum system version. If
# <max-min-version> (e.g. 26.0) is given, it must not be higher. If
# <minos-tsv> is given, it gets one line per Mach-O file: the path
# relative to the package, a tab, and its minos.
#
# The script never runs a MiKTeX program, so it also works on a machine
# that cannot run the package.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "usage: verify-engine.sh <engine-dir> [<max-min-version> [<minos-tsv>]]" >&2
  exit 2
fi
engine=$(cd "$1" && pwd -P)
max_min_version=${2:-}
minos_out=${3:-}
if [ -n "$max_min_version" ] && ! [[ $max_min_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "verify-engine.sh: <max-min-version> must look like 26.0: $max_min_version" >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bad=0
fail()
{
  echo "::error::$*"
  bad=1
}

# whether a path exists and its real path is inside the package
inside()
{
  local real
  real=$(realpath "$1" 2>/dev/null) || return 1
  case "$real" in
    "$engine" | "$engine"/*) return 0 ;;
    *) return 1 ;;
  esac
}

for d in bin lib libexec/miktex texmfs/install/miktex/bootstrapping; do
  if [ ! -d "$engine/$d" ]; then
    fail "missing directory: $d"
  fi
done
for f in bin/miktex bin/initexmf bin/miktex-pdftex bin/miktex-xetex bin/miktex-luatex \
  bin/pdflatex bin/xelatex bin/lualatex bin/latexmk bin/mktexlsr; do
  if [ ! -x "$engine/$f" ]; then
    fail "missing program: $f"
  fi
done
leftovers=$(find "$engine" \( -name '*.a' -o -name '*.app' -o -path "$engine/share/man" \
  -o -name miktex-testwebapp -o -name '._*' -o -name .DS_Store \) -print)
if [ -n "$leftovers" ]; then
  fail "files the engine does not ship:"
  echo "$leftovers"
fi

# symbolic links: relative, inside the package, not dangling
while IFS= read -r -d '' l; do
  rel=${l#"$engine"/}
  target=$(readlink "$l")
  case "$target" in
    /*)
      fail "absolute link: $rel -> $target"
      continue
      ;;
  esac
  if [ ! -e "$l" ]; then
    fail "dangling link: $rel -> $target"
    continue
  fi
  case "$(realpath "$l")" in
    "$engine"/*) ;;
    *) fail "link outside the package: $rel -> $target" ;;
  esac
done < <(find "$engine" -type l -print0)

count=0
: > "$work/minos"
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in
    Mach-O*) ;;
    *) continue ;;
  esac
  count=$((count + 1))
  rel=${f#"$engine"/}
  dir=$(dirname "$f")
  # commands that fail on a bad file must not stop the script (set -e):
  # every problem is reported through fail
  archs=$(lipo -archs "$f" 2>&1) || true
  if [ "$archs" != arm64 ]; then
    fail "not arm64-only ($archs): $rel"
  fi
  id=$(otool -D "$f" | tail -n +2) || true
  case "$rel" in
    lib/*)
      # a MiKTeX library is named after its SONAME link
      if [[ $id != @rpath/* ]] || [ ! -e "$engine/lib/${id#@rpath/}" ] \
        || [ "$(realpath "$engine/lib/${id#@rpath/}")" != "$f" ]; then
        fail "install name '$id': $rel"
      fi
      ;;
  esac
  # a program has no loader above it: its own rpaths must find its
  # libraries; a library may also rely on the rpaths of the program that
  # loads it, which all lead to lib/
  if otool -h "$f" | awk 'NR == 4 { exit !($5 == 2) }'; then
    executable=1
  else
    executable=
  fi
  rpaths=$(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }') || true
  while IFS= read -r rp; do
    case "$rp" in
      '') ;;
      @loader_path*)
        if ! inside "$dir${rp#@loader_path}"; then
          fail "rpath $rp leads outside the package or nowhere: $rel"
        fi
        ;;
      *) fail "rpath $rp: $rel" ;;
    esac
  done <<< "$rpaths"
  while IFS= read -r dep; do
    case "$dep" in
      "$id") ;;
      /usr/lib/* | /System/Library/*) ;;
      @rpath/*)
        found=
        while IFS= read -r rp; do
          case "$rp" in
            @loader_path*) rp=$dir${rp#@loader_path} ;;
            *) continue ;;
          esac
          if [ -e "$rp/${dep#@rpath/}" ] && inside "$rp/${dep#@rpath/}"; then
            found=1
            break
          fi
        done <<< "$rpaths"
        if [ -z "$found" ] && { [ -n "$executable" ] || [ ! -e "$engine/lib/${dep#@rpath/}" ]; }; then
          fail "unresolved $dep: $rel"
        fi
        ;;
      @loader_path/*)
        if ! inside "$dir/${dep#@loader_path/}"; then
          fail "unresolved $dep: $rel"
        fi
        ;;
      *)
        fail "load command outside the package: $dep: $rel"
        ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/ (compatibility version .*//')
  if ! codesign --verify --strict "$f" 2> "$work/codesign.err"; then
    fail "invalid signature: $rel"
    cat "$work/codesign.err"
  fi
  info=$(codesign -dv "$f" 2>&1) || true
  flags=$(sed -n 's/^CodeDirectory .* flags=0x[0-9a-f]*(\([^)]*\)).*/\1/p' <<< "$info")
  if [ "$flags" != adhoc ]; then
    fail "signature flags '$flags', expected adhoc: $rel"
  fi
  if ! grep -q '^TeamIdentifier=not set' <<< "$info"; then
    fail "Team ID: $rel"
  fi
  minos=$(vtool -arch arm64 -show-build "$f" 2>/dev/null | awk '$1 == "minos" { print $2; exit }') || minos=
  if [ -z "$minos" ]; then
    fail "no minimum macOS version (minos): $rel"
  else
    printf '%s\t%s\n' "$rel" "$minos" >> "$work/minos"
  fi
done < <(find "$engine" -type f -print0)

echo "Mach-O files: $count"
echo "symbolic links: $(find "$engine" -type l | wc -l | tr -d ' ') (bin: $(find "$engine/bin" -type l | wc -l | tr -d ' '))"
echo "minos distribution:"
cut -f2 "$work/minos" | sort -V | uniq -c
effective=$(cut -f2 "$work/minos" | sort -V | tail -1)
echo "effective minimum macOS version: $effective"
if [ -z "$effective" ]; then
  fail "no minimum macOS version (minos) found"
elif [ -n "$max_min_version" ] \
  && [ "$(printf '%s\n%s\n' "$max_min_version" "$effective" | sort -V | tail -1)" != "$max_min_version" ]; then
  fail "effective minimum macOS version $effective is higher than $max_min_version"
fi
if [ -n "$minos_out" ]; then
  LC_ALL=C sort "$work/minos" > "$minos_out"
fi

exit $bad
