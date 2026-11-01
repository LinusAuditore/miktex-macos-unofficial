#!/bin/bash
# Make the commands without miktex- prefix in bin/ of the engine package
# (fork CI only).
#
# usage: make-links.sh <engine-dir> <links-tsv>
#
# `miktex links install` cannot make them: it writes absolute links into
# the link target directory (outside the engine), and copies mktexlsr,
# texhash, texlinks and updmap. This script runs the first-time setup of
# INTEGRATION.md in a temporary home and data directory (offline: the
# bootstrapping packages are in the engine), lists the links with
# `miktex links list`, and makes each one a relative symbolic link in
# bin/ that points to the program in bin/ or libexec/miktex/. The setup is
# also a smoke test of the engine.
#
# <links-tsv> gets one line per link: name, a tab, the link type that
# `miktex links list` reports, a tab, and the relative target.
#
# The engine must be built with MIKTEX_USER_LINK_TARGET_DIR set to
# /var/empty/miktex-links (see NOTES.md, decision D2).

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: make-links.sh <engine-dir> <links-tsv>" >&2
  exit 2
fi
engine=$(cd "$1" && pwd -P)
out=$2
link_dir=/var/empty/miktex-links

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
data=$work/data
mkdir -p "$work/home" "$work/tmp" "$data/texmfs/config/miktex/config"
: > "$data/texmfs/config/miktex/config/miktexstartup.ini"
touch "$work/start"
sleep 1

# the environment INTEGRATION.md prescribes
run()
{
  env -i \
    HOME="$work/home" \
    PATH="$engine/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="$work/tmp" \
    MIKTEX_USERCONFIG="$data/texmfs/config" \
    MIKTEX_USERDATA="$data/texmfs/data" \
    MIKTEX_USERINSTALL="$data/texmfs/install" \
    MIKTEX_USERSTARTUPFILE="$data/texmfs/config/miktex/config/miktexstartup.ini" \
    "$@"
}

echo "=== first-time setup ==="
run "$engine/bin/initexmf" --disable-installer --set-config-value="[MPM]AutoInstall=1"
run "$engine/bin/miktex" --disable-installer fndb refresh
run "$engine/bin/miktex" --disable-installer fontmaps configure
run "$engine/bin/miktex" --disable-installer languages configure
run "$engine/bin/miktex" --disable-installer fndb refresh

echo "=== links ==="
run "$engine/bin/miktex" --disable-installer links list --template $'{linkType}\t{linkName}\t{target}' \
  > "$work/list"
: > "$work/links"
while IFS=$'\t' read -r type link target; do
  name=${link#"$link_dir"/}
  if [ "$name" = "$link" ] || [ -z "$name" ] || [[ $name == */* ]]; then
    echo "::error::link outside $link_dir: $link"
    exit 1
  fi
  case "$target" in
    "$engine"/bin/*) rel=${target#"$engine"/bin/} ;;
    "$engine"/libexec/miktex/*) rel=../libexec/miktex/${target#"$engine"/libexec/miktex/} ;;
    *)
      echo "::error::link target outside the engine: $name -> $target"
      exit 1
      ;;
  esac
  case "${rel#../libexec/miktex/}" in
    */*)
      echo "::error::unexpected link target: $name -> $target"
      exit 1
      ;;
  esac
  if [ "$rel" = "$name" ]; then
    # the program itself
    continue
  fi
  if [ -L "$engine/bin/$name" ] && [ "$(readlink "$engine/bin/$name")" = "$rel" ]; then
    # the engines are listed twice: as programs and as formats
    continue
  fi
  if [ -e "$engine/bin/$name" ] || [ -L "$engine/bin/$name" ]; then
    echo "::error::bin/$name exists; cannot link it to $rel"
    exit 1
  fi
  if [ ! -x "$target" ]; then
    echo "::error::link target is not a program: $name -> $target"
    exit 1
  fi
  ln -s "$rel" "$engine/bin/$name"
  printf '%s\t%s\t%s\n' "$name" "$type" "$rel" >> "$work/links"
done < "$work/list"
LC_ALL=C sort "$work/links" > "$out"
echo "links: $(wc -l < "$out" | tr -d ' ') ($(cut -f2 "$out" | sort | uniq -c | awk '{ printf "%s%s %s", sep, $1, $2; sep = ", " }'))"

# the setup must not write into the engine or the home directory
changed=$(find "$engine" "$work/home" -newer "$work/start" ! -type l ! -path "$engine/bin" ! -path "$work/home" -print)
if [ -n "$changed" ]; then
  echo "::error::the first-time setup wrote outside the data directory:"
  echo "$changed"
  exit 1
fi
