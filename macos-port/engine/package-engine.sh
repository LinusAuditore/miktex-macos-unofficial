#!/bin/bash
# Make the relocatable MiKTeX engine package from a staged install tree
# (fork CI only).
#
# usage: package-engine.sh <staging-dir> <engine-dir> <closure-tsv>
#
# <staging-dir> is the `cmake --install` tree of a command-line build
# (WITH_UI_QT=FALSE, MIKTEX_MACOS_BUNDLE=FALSE, MIKTEX_SELF_CONTAINED=TRUE).
# The script copies it to <engine-dir>, which must not exist, and then:
#
# - removes what the engine does not ship: static libraries, the test web
#   application, man pages
# - copies the Homebrew dynamic-library closure of all Mach-O files into
#   lib/, changes the references to @rpath/<name> and the install names of
#   the copied libraries to @rpath/<name>
# - deletes every LC_RPATH that does not start with @loader_path or
#   @executable_path (Homebrew libraries can carry Cellar rpaths)
# - signs every Mach-O file again with an ad-hoc signature (required on
#   arm64; install_name_tool invalidates the Homebrew signatures) and
#   verifies it
#
# <closure-tsv> gets one line per copied library: lib/<name>, a tab, and
# the real path of the source file (input for the license collection).
#
# The commands in bin/ that have no miktex- prefix are made by
# make-links.sh; verify-engine.sh checks the result. The script never runs
# a MiKTeX program.

set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: package-engine.sh <staging-dir> <engine-dir> <closure-tsv>" >&2
  exit 2
fi
staging=$1
engine=$2
closure=$3

if [ ! -x "$staging/bin/miktex" ] || [ ! -d "$staging/texmfs/install/miktex/bootstrapping" ]; then
  echo "package-engine.sh: not a self-contained MiKTeX staging tree: $staging" >&2
  exit 1
fi
if [ -n "$(find "$staging" -name '*.app' -prune -print)" ]; then
  echo "package-engine.sh: the staging tree contains an application bundle; build with MIKTEX_MACOS_BUNDLE=FALSE and WITH_UI_QT=FALSE" >&2
  exit 1
fi
if [ -e "$engine" ]; then
  echo "package-engine.sh: $engine exists" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# -R copies symbolic links (the SONAME links in lib/) as links
cp -pR "$staging" "$engine"
engine=$(cd "$engine" && pwd -P)
lib=$engine/lib

echo "=== prune ==="
# mplib installs its static libraries unconditionally
find "$lib" -name '*.a' -print -delete
rm -fv "$engine/bin/miktex-testwebapp"
rm -rfv "$engine/share/man"

is_macho()
{
  case "$(file -b "$1")" in
    Mach-O*) return 0 ;;
    *) return 1 ;;
  esac
}

# dependencies of a Mach-O file, one per line, without its install name
deps()
{
  local id
  id=$(otool -D "$1" | tail -n +2)
  otool -L "$1" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/ (compatibility version .*//' \
    | { if [ -n "$id" ]; then grep -v -F -x -- "$id"; else cat; fi; } || true
}

rpaths()
{
  otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'
}

# queue: <file><TAB><directory that @loader_path stands for>; a copied
# library resolves its references relative to its Homebrew location
queue=$work/queue
: > "$queue"
: > "$work/copied"
while IFS= read -r -d '' f; do
  if is_macho "$f"; then
    printf '%s\t%s\n' "$f" "$(dirname "$f")" >> "$queue"
  fi
done < <(find "$engine" -type f -print0)

echo "=== Homebrew closure ==="
rounds=0
while [ -s "$queue" ]; do
  rounds=$((rounds + 1))
  if [ $rounds -gt 50 ]; then
    echo "::error::the dependency closure does not converge"
    exit 1
  fi
  mv "$queue" "$work/current"
  : > "$queue"
  while IFS=$'\t' read -r f origin; do
    changes=()
    while IFS= read -r dep; do
      src=
      case "$dep" in
        /usr/lib/* | /System/*)
          continue
          ;;
        /opt/homebrew/*)
          src=$dep
          ;;
        @rpath/*)
          leaf=${dep#@rpath/}
          case "$origin" in
            "$engine"/*)
              # built by MiKTeX, or already copied
              if [ -e "$lib/$leaf" ]; then
                continue
              fi
              ;;
          esac
          while IFS= read -r rp; do
            case "$rp" in
              @loader_path*) rp=$origin${rp#@loader_path} ;;
              @executable_path*) continue ;;
            esac
            if [ -e "$rp/$leaf" ]; then
              src=$rp/$leaf
              break
            fi
          done < <(rpaths "$f")
          if [ -z "$src" ]; then
            if [ -e "$lib/$leaf" ]; then
              continue
            fi
            echo "::error::cannot resolve $dep of ${f#"$engine"/}"
            exit 1
          fi
          ;;
        @loader_path/*)
          src=$origin/${dep#@loader_path/}
          case "$origin" in
            "$engine"/*)
              if [ -e "$src" ]; then
                continue
              fi
              echo "::error::missing $dep of ${f#"$engine"/}"
              exit 1
              ;;
          esac
          ;;
        *)
          # /usr/local (Intel Homebrew), build directories, @executable_path
          echo "::error::unexpected dependency $dep of ${f#"$engine"/}"
          exit 1
          ;;
      esac
      if [ ! -e "$src" ]; then
        echo "::error::missing $dep of ${f#"$engine"/}"
        exit 1
      fi
      # keep the name the library is referenced by (e.g. libicuuc.78.dylib,
      # not the real libicuuc.78.1.dylib)
      name=$(basename "$src")
      real=$(realpath "$src")
      case "$real" in
        /opt/homebrew/*) ;;
        *)
          echo "::error::$dep of ${f#"$engine"/} resolves outside Homebrew: $real"
          exit 1
          ;;
      esac
      known=$(awk -F '\t' -v n="lib/$name" '$1 == n { print $2 }' "$work/copied")
      if [ -z "$known" ]; then
        if [ -e "$lib/$name" ]; then
          echo "::error::lib/$name exists; cannot copy $real"
          exit 1
        fi
        cp "$real" "$lib/$name"
        chmod 0644 "$lib/$name"
        printf 'lib/%s\t%s\n' "$name" "$real" >> "$work/copied"
        printf '%s\t%s\n' "$lib/$name" "$(dirname "$real")" >> "$queue"
        echo "+ lib/$name <- $real"
      elif [ "$known" != "$real" ]; then
        echo "::error::two libraries named $name: $known and $real"
        exit 1
      fi
      if [ "$dep" != "@rpath/$name" ]; then
        changes+=(-change "$dep" "@rpath/$name")
      fi
    done < <(deps "$f")
    if [ ${#changes[@]} -gt 0 ]; then
      install_name_tool "${changes[@]}" "$f" 2> >(grep -v 'invalidate the code signature' >&2)
    fi
  done < "$work/current"
done

echo "=== install names and rpaths ==="
while IFS=$'\t' read -r rel real; do
  install_name_tool -id "@rpath/${rel#lib/}" "$engine/$rel" 2> >(grep -v 'invalidate the code signature' >&2)
done < "$work/copied"
machos=$work/machos
: > "$machos"
while IFS= read -r -d '' f; do
  if is_macho "$f"; then
    printf '%s\n' "$f" >> "$machos"
  fi
done < <(find "$engine" -type f -print0)
while IFS= read -r f; do
  args=()
  keep=0
  while IFS= read -r rp; do
    case "$rp" in
      @loader_path*)
        # a copied library can carry a relative rpath into another keg
        # (e.g. @loader_path/../../../../opt/x/lib); keep only those that
        # lead into the package
        real=$(realpath "$(dirname "$f")${rp#@loader_path}" 2>/dev/null || true)
        case "$real" in
          "$engine" | "$engine"/*)
            keep=$((keep + 1))
            ;;
          *)
            echo "- rpath $rp: ${f#"$engine"/}"
            args+=(-delete_rpath "$rp")
            ;;
        esac
        ;;
      *)
        echo "- rpath $rp: ${f#"$engine"/}"
        args+=(-delete_rpath "$rp")
        ;;
    esac
  done < <(rpaths "$f")
  # a copied library that refers to its siblings by @rpath must find them
  # by itself
  if [ $keep -eq 0 ] && deps "$f" | grep '^@rpath/' > /dev/null; then
    case "$f" in
      "$lib"/*)
        echo "+ rpath @loader_path: ${f#"$engine"/}"
        args+=(-add_rpath @loader_path)
        ;;
    esac
  fi
  if [ ${#args[@]} -gt 0 ]; then
    install_name_tool "${args[@]}" "$f" 2> >(grep -v 'invalidate the code signature' >&2)
  fi
done < "$machos"

echo "=== ad-hoc signature ==="
while IFS= read -r f; do
  if ! codesign --force --sign - "$f" 2> "$work/codesign.err"; then
    cat "$work/codesign.err" >&2
    echo "::error::cannot sign ${f#"$engine"/}"
    exit 1
  fi
done < "$machos"
while IFS= read -r f; do
  if ! codesign --verify --strict "$f"; then
    echo "::error::invalid signature: ${f#"$engine"/}"
    exit 1
  fi
done < "$machos"

LC_ALL=C sort "$work/copied" > "$closure"
echo "Mach-O files: $(wc -l < "$machos" | tr -d ' '), Homebrew libraries: $(wc -l < "$closure" | tr -d ' ')"
