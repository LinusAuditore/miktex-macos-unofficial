#!/usr/bin/env python3
# Write engine-manifest.json, the description of the MiKTeX engine package
# (fork CI only).
#
# usage: make-manifest.py --engine DIR --closure TSV --links TSV --minos TSV
#          --miktex-version V --max-min-version V [--tag T]
#          [--fork-commit C] [--upstream-commit C] [--build KEY=VALUE ...]
#
# TSV inputs: --closure from package-engine.sh, --links from make-links.sh,
# --minos from verify-engine.sh. The manifest records what is in the
# package, measured, not assumed: the minimum macOS version (minos) of
# every Mach-O file, the Homebrew libraries and their kegs, the SHA-256 of
# the bootstrapping archives (downloaded from CTAN at build time), and the
# commands in bin/. Run with python3 -I.

import argparse
import hashlib
import json
import os
import re
import sys


def read_tsv(path, columns):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != columns:
                sys.exit(f"make-manifest.py: {path}: expected {columns} columns: {line!r}")
            rows.append(fields)
    return rows


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--engine", required=True)
    p.add_argument("--closure", required=True)
    p.add_argument("--links", required=True)
    p.add_argument("--minos", required=True)
    p.add_argument("--miktex-version", required=True)
    p.add_argument("--max-min-version", required=True)
    p.add_argument("--tag")
    p.add_argument("--fork-commit")
    p.add_argument("--upstream-commit")
    p.add_argument("--build", action="append", default=[], metavar="KEY=VALUE")
    p.add_argument("--output", required=True)
    args = p.parse_args()
    engine = os.path.realpath(args.engine)

    minos = read_tsv(args.minos, 2)
    if not minos:
        sys.exit("make-manifest.py: no Mach-O files")
    distribution = {}
    for _, v in minos:
        distribution[v] = distribution.get(v, 0) + 1
    effective = max(distribution, key=version_key)
    if version_key(effective) > version_key(args.max_min_version):
        sys.exit(f"make-manifest.py: minos {effective} is higher than {args.max_min_version}")

    kegs = {}
    for rel, real in read_tsv(args.closure, 2):
        m = re.match(r"^/opt/homebrew/Cellar/([^/]+)/([^/]+)/", real)
        if not m:
            sys.exit(f"make-manifest.py: not a Homebrew keg: {real}")
        keg = kegs.setdefault(m.group(1), {"formula": m.group(1), "version": m.group(2), "files": []})
        if keg["version"] != m.group(2):
            sys.exit(f"make-manifest.py: two versions of {m.group(1)}")
        keg["files"].append(rel)

    bootstrapping_dir = os.path.join(engine, "texmfs/install/miktex/bootstrapping")
    bootstrapping = [
        {"file": name, "sha256": sha256(os.path.join(bootstrapping_dir, name))}
        for name in sorted(os.listdir(bootstrapping_dir))
    ]

    links = {name: (listed, target) for name, listed, target in read_tsv(args.links, 3)}
    commands = []
    for name in sorted(os.listdir(os.path.join(engine, "bin"))):
        path = os.path.join(engine, "bin", name)
        if os.path.islink(path):
            target = os.readlink(path)
            if name not in links or links[name][1] != target:
                sys.exit(f"make-manifest.py: bin/{name} is not in {args.links}")
            commands.append({"name": name, "type": "link", "target": target})
        elif os.access(path, os.X_OK):
            commands.append({"name": name, "type": "program"})
    if len(links) != sum(1 for c in commands if c["type"] == "link"):
        sys.exit(f"make-manifest.py: {args.links} lists links that are not in bin/")
    helpers = sorted(os.listdir(os.path.join(engine, "libexec/miktex")))

    build = {}
    for kv in args.build:
        key, sep, value = kv.partition("=")
        if not sep:
            sys.exit(f"make-manifest.py: --build {kv}: expected KEY=VALUE")
        build[key] = value

    manifest = {
        "schema": 1,
        "name": "miktex-engine-unofficial",
        "tag": args.tag or None,
        "miktex": {"version": args.miktex_version},
        "source": {
            "repository": "LinusAuditore/miktex-macos-unofficial",
            "fork_commit": args.fork_commit or None,
            "upstream_commit": args.upstream_commit or None,
        },
        "macos": {
            "arch": "arm64",
            "min_version": effective,
            "min_version_limit": args.max_min_version,
            "macho_count": len(minos),
            "minos_distribution": dict(sorted(distribution.items(), key=lambda kv: version_key(kv[0]))),
        },
        "layout": {
            "bin": "bin",
            "libexec": "libexec/miktex",
            "lib": "lib",
            "distribution_root": "texmfs/install",
        },
        "commands": commands,
        "helpers": helpers,
        "homebrew": [kegs[k] for k in sorted(kegs)],
        "bootstrapping": bootstrapping,
        "build": build,
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{args.output}: {len(commands)} commands, {len(minos)} Mach-O files, minos {effective}")


if __name__ == "__main__":
    main()
