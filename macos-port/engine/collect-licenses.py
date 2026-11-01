#!/usr/bin/env python3
# Collect the license texts of the MiKTeX engine package into
# <engine-dir>/licenses (fork CI only).
#
# usage: collect-licenses.py --table JSON --repo DIR --build DIR
#          --engine DIR --closure TSV --source-url URL
#          --release-sources TSV --release-dir DIR
#
# The table (macos-port/engine/licenses/components.json) is the controlled
# list of every component that can end up in the package: its SPDX
# expression, the source directories it is compiled from, and its license
# texts (repository files, slices of them, texts fetched from upstream into
# macos-port/engine/licenses/fetched/, or files in a Homebrew keg). The
# script checks the table against what the build really used and fails if
# they disagree:
#
# - a file in compile_commands.json that no component's sources cover, or
#   a component marked as compiled that has no compiled file
# - a library of the Homebrew closure (closure.tsv) or a Homebrew static
#   library linked in build.ninja whose keg is not in the table, a keg in
#   the table that the build does not use, or a keg whose SPDX
#   (sbom.spdx.json, licenseConcluded) differs from the table's spdx_sbom
# - a missing license file, or a slice whose sha256 differs from the table
# - a bootstrapping archive that is not in the table, or whose package has
#   no License field and is not whitelisted
#
# It writes licenses/README.txt, INDEX.tsv (one line per text), sources.tsv
# (where the corresponding source of each copyleft component is), texts/
# (shared license texts), miktex/, bootstrap/, bundled/<id>/ and
# homebrew/<keg>/<version>/. The output is deterministic and has no
# symbolic links.
#
# --release-sources gets one line per source archive the release must
# carry (asset name, URL, sha256): the Homebrew copyleft kegs (from their
# sbom.spdx.json) and the upstream sources the table names (corresponding
# source upstream-<name> with source_download); the workflow
# downloads and verifies them. The formula files of those kegs are copied
# into --release-dir. Run with python3 -I.

import argparse
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import sys
import tarfile

CELLAR = "/opt/homebrew/Cellar/"
COMPILED_KINDS = ("bundled-library", "program", "sub-library", "miktex")

errors = []


def error(msg):
    errors.append(msg)
    print(f"::error::{msg}")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def slice_lines(data, lines):
    if not lines:
        return data
    m = re.fullmatch(r"(\d+)-(\d+)", lines)
    if not m:
        raise ValueError(f"bad line range {lines!r}")
    a, b = int(m.group(1)), int(m.group(2))
    parts = data.splitlines(keepends=True)
    if not 1 <= a <= b <= len(parts):
        raise ValueError(f"line range {lines} outside 1-{len(parts)}")
    return b"".join(parts[a - 1:b])


def keg_of(real):
    m = re.match(r"^/opt/homebrew/Cellar/([^/]+)/([^/]+)/", real)
    return (m.group(1), m.group(2)) if m else None


def sbom_package(keg, version):
    path = os.path.join(CELLAR, keg, version, "sbom.spdx.json")
    with open(path, encoding="utf-8") as f:
        sbom = json.load(f)
    packages = sbom.get("packages", [])
    for p in packages:
        if p.get("name") == keg and "ghcr.io" not in p.get("downloadLocation", ""):
            return p
    return packages[0] if packages else {}


def compiled_files(build, repo):
    with open(os.path.join(build, "compile_commands.json"), encoding="utf-8") as f:
        commands = json.load(f)
    build_real = os.path.realpath(build) + "/"
    repo_real = os.path.realpath(repo) + "/"
    files = set()
    for c in commands:
        path = c["file"]
        if not os.path.isabs(path):
            path = os.path.join(c["directory"], path)
        path = os.path.realpath(path)
        # generated sources (tangled WEB, bison/flex output) belong to the
        # component whose sources generated them; they are checked through it
        if path.startswith(build_real):
            continue
        if not path.startswith(repo_real):
            error(f"compiled file outside the repository: {path}")
            continue
        files.add(path[len(repo_real):])
    return sorted(files)


def homebrew_static_libraries(build):
    found = set()
    with open(os.path.join(build, "build.ninja"), encoding="utf-8") as f:
        for line in f:
            for m in re.finditer(r"(/opt/homebrew/[^\s$:]+\.a)\b", line):
                found.add(os.path.realpath(m.group(1)))
    return sorted(found)


def bootstrap_licenses(engine):
    result = {}
    d = os.path.join(engine, "texmfs/install/miktex/bootstrapping")
    for name in sorted(os.listdir(d)):
        with open(os.path.join(d, name), "rb") as f:
            data = lzma.decompress(f.read(), format=lzma.FORMAT_ALONE)
        licenses = []
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            for m in t.getmembers():
                if m.name.endswith(".tpm"):
                    tpm = t.extractfile(m).read().decode("utf-8")
                    licenses += re.findall(r'<TPM:License\s+type="([^"]*)"', tpm)
        result[name] = licenses
    return result


class Output:
    def __init__(self, root):
        self.root = root
        self.index = []
        self.content = {}

    def put(self, rel, data, entry_id, kind, spdx, what):
        rel = rel.replace(" ", "_")
        if rel in self.content:
            if self.content[rel] != data:
                base, ext = os.path.splitext(rel)
                n = 2
                while f"{base}.{n}{ext}" in self.content and self.content[f"{base}.{n}{ext}"] != data:
                    n += 1
                rel = f"{base}.{n}{ext}"
        if rel not in self.content:
            self.content[rel] = data
            path = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)
        self.index.append((entry_id, kind, spdx, rel, what))
        return rel


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--table", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--engine", required=True)
    p.add_argument("--closure", required=True)
    p.add_argument("--source-url", required=True, help="the fork's source archive of this build")
    p.add_argument("--release-sources", required=True)
    p.add_argument("--release-dir", required=True)
    args = p.parse_args()
    repo = os.path.realpath(args.repo)
    engine = os.path.realpath(args.engine)

    with open(args.table, encoding="utf-8") as f:
        table = json.load(f)
    entries = table["components"]
    ids = [e["id"] for e in entries]
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        error(f"table: duplicate id {dup}")
    by_id = {e["id"]: e for e in entries}

    # Homebrew: the dynamic closure and the static libraries really linked
    used_kegs = {}
    with open(args.closure, encoding="utf-8") as f:
        for line in f:
            rel, real = line.rstrip("\n").split("\t")
            kv = keg_of(real)
            if not kv:
                error(f"{rel} is neither in the Cellar nor built by MiKTeX: {real}")
                continue
            used_kegs.setdefault(kv, []).append(rel)
    for real in homebrew_static_libraries(args.build):
        kv = keg_of(real)
        if not kv:
            error(f"static library outside the Cellar: {real}")
            continue
        used_kegs.setdefault(kv, []).append("static: " + os.path.basename(real))
    keg_versions = {}
    for (keg, version), files in sorted(used_kegs.items()):
        if keg in keg_versions and keg_versions[keg] != version:
            error(f"two versions of keg {keg}")
        keg_versions[keg] = version
        e = by_id.get(keg)
        if not e or e["kind"] != "homebrew":
            error(f"keg {keg} {version} ({', '.join(files)}) is not in the table")
            continue
        concluded = sbom_package(keg, version).get("licenseConcluded", "")
        if concluded != e["spdx_sbom"]:
            error(f"keg {keg} {version}: sbom licenseConcluded '{concluded}' differs from the table's '{e['spdx_sbom']}'")
    for e in entries:
        if e["kind"] == "homebrew" and e["in_package"] and e["id"] not in keg_versions:
            error(f"keg {e['id']} is in the table but not used by the build")

    # compiled sources: every file belongs to a component (longest prefix)
    prefixes = sorted(((s, e["id"]) for e in entries for s in e.get("sources", [])), key=lambda x: -len(x[0]))
    hits = {}
    for path in compiled_files(args.build, repo):
        owner = next((i for s, i in prefixes if path.startswith(s)), None)
        if owner is None:
            error(f"compiled file not covered by the table: {path}")
            continue
        hits[owner] = hits.get(owner, 0) + 1
    for e in entries:
        if e["kind"] in COMPILED_KINDS and e["in_package"] and e.get("compiled", True) and e.get("sources") and not hits.get(e["id"]):
            error(f"{e['id']}: marked as compiled, but no compiled file is in its sources")

    # bootstrapping archives
    boot = bootstrap_licenses(engine)
    archives = {e.get("archive"): e for e in entries if e["kind"] == "bootstrap"}
    for name, licenses in boot.items():
        e = archives.get(name)
        if not e:
            error(f"bootstrapping archive {name} is not in the table")
        elif not licenses and not e.get("whitelist_reason"):
            error(f"bootstrapping archive {name} has no License field and is not whitelisted")
        elif licenses and e.get("tpm_license") and sorted(set(licenses)) != sorted(e["tpm_license"].split()):
            error(f"bootstrapping archive {name}: License {licenses} differs from the table's {e['tpm_license']}")
    for name in archives:
        if name not in boot:
            error(f"bootstrapping archive {name} is in the table but not in the package")

    # texts
    out_dir = os.path.join(engine, "licenses")
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    out = Output(out_dir)
    generic = {e["id"][len("text-"):]: e for e in entries if e["kind"] == "license-text"}
    needed_generic = set()

    def read_text(e, t):
        f = t["file"]
        if f.startswith("keg:"):
            version = keg_versions.get(e["id"])
            if not version:
                return None
            path = os.path.join(CELLAR, e["id"], version, f[len("keg:"):])
        else:
            path = os.path.join(repo, f)
        if not os.path.isfile(path):
            error(f"{e['id']}: missing license file {f}")
            return None
        with open(path, "rb") as fh:
            data = fh.read()
        try:
            data = slice_lines(data, t.get("lines", ""))
        except ValueError as ex:
            error(f"{e['id']}: {f}: {ex}")
            return None
        # whole files of a keg change with its version; slices of them, and
        # all other texts, must stay as the table records them
        if t.get("sha256") or not f.startswith("keg:"):
            if sha256(data) != t.get("sha256"):
                error(f"{e['id']}: {f} {t.get('lines', '')}: sha256 {sha256(data)} differs from the table")
        return data

    for e in sorted(entries, key=lambda x: x["id"]):
        if not e["in_package"] or e["kind"] == "license-text":
            continue
        if e["kind"] == "homebrew":
            base = f"homebrew/{e['id']}/{keg_versions.get(e['id'], 'unknown')}"
        elif e["kind"] in ("miktex", "bootstrap"):
            base = f"{e['kind']}/{e['id']}"
        else:
            base = f"bundled/{e['id']}"
        for t in e["texts"]:
            data = read_text(e, t)
            if data is None:
                continue
            name = os.path.basename(t["file"])
            if t.get("lines"):
                name += f".lines-{t['lines']}"
            out.put(f"{base}/{name}", data, e["id"], e["kind"], e["spdx"], t["what"])
        needed_generic.update(e.get("generic_texts", []))
    # a license text can need another one (LGPL-3.0 builds on GPL-3.0)
    while True:
        more = {x for s in needed_generic if s in generic for x in generic[s].get("generic_texts", [])}
        if more <= needed_generic:
            break
        needed_generic |= more
    for spdx_id in sorted(needed_generic):
        g = generic.get(spdx_id)
        if not g:
            error(f"generic text {spdx_id} is not in the table")
            continue
        for t in g["texts"]:
            data = read_text(g, t)
            if data is not None:
                out.put(f"texts/{spdx_id}.txt", data, g["id"], g["kind"], g["spdx"], t["what"])

    # where the corresponding source of each copyleft component is
    release_sources = []
    os.makedirs(args.release_dir, exist_ok=True)
    sources = []

    def add_source(e, how):
        if how == "none":
            return
        if how == "fork":
            sources.append((e["id"], e["spdx"], "fork source archive", args.source_url, ""))
        elif how == "homebrew":
            version = keg_versions.get(e["id"])
            if not version:
                return
            pkg = sbom_package(e["id"], version)
            url = pkg.get("downloadLocation", "")
            checksum = next((c["checksumValue"] for c in pkg.get("checksums", []) if c.get("algorithm") == "SHA256"), "")
            if not url.startswith("https://") or not re.fullmatch(r"[0-9a-f]{64}", checksum):
                error(f"keg {e['id']} {version}: no source URL and sha256 in sbom.spdx.json")
                return
            asset = f"source-{e['id']}-{os.path.basename(url)}"
            release_sources.append((asset, url, checksum))
            formula = os.path.join(CELLAR, e["id"], version, ".brew", f"{e['id']}.rb")
            formula_asset = f"source-{e['id']}-{version}.rb"
            if os.path.isfile(formula):
                shutil.copyfile(formula, os.path.join(args.release_dir, formula_asset))
            else:
                error(f"keg {e['id']} {version}: formula file missing: {formula}")
            sources.append((e["id"], e["spdx"], "release asset (Homebrew source and formula)", f"{asset}, {formula_asset}", checksum))
        elif how.startswith("upstream-"):
            d = e.get("source_download") or {}
            if not d.get("url") or not re.fullmatch(r"[0-9a-f]{64}", d.get("sha256", "")):
                error(f"{e['id']}: source_download needs url and sha256")
                return
            asset = f"source-{e['id']}-{os.path.basename(d['url'])}"
            release_sources.append((asset, d["url"], d["sha256"]))
            sources.append((e["id"], e["spdx"], "release asset (upstream source)", asset, d["sha256"]))
        else:
            error(f"{e['id']}: unknown corresponding_source {how}")

    for e in sorted(entries, key=lambda x: x["id"]):
        if not e["in_package"] or e["kind"] == "license-text":
            continue
        how = e.get("corresponding_source", "none")
        for h in how if isinstance(how, list) else [how]:
            add_source(e, h)
    with open(args.release_sources, "w", encoding="utf-8") as f:
        for row in sorted(release_sources):
            f.write("\t".join(row) + "\n")

    index_rows = sorted(set(out.index))
    with open(os.path.join(out_dir, "INDEX.tsv"), "w", encoding="utf-8") as f:
        f.write("component\tkind\tspdx\tfile\tdescription\n")
        for row in index_rows:
            f.write("\t".join(c.replace("\t", " ").replace("\n", " ") for c in row) + "\n")
    with open(os.path.join(out_dir, "sources.tsv"), "w", encoding="utf-8") as f:
        f.write("component\tspdx\twhere\tlocation\tsha256\n")
        for row in sorted(sources):
            f.write("\t".join(row) + "\n")
    with open(os.path.join(out_dir, "README.txt"), "w", encoding="utf-8") as f:
        f.write(README)
        f.write("\nComponents:\n\n")
        for e in sorted(entries, key=lambda x: x["id"]):
            if e["in_package"] and e["kind"] != "license-text":
                f.write(f"  {e['id']}: {e['name']}\n    {e['spdx']}\n")
        acknowledgements = [e for e in sorted(entries, key=lambda x: x["id"]) if e["in_package"] and e.get("acknowledgement")]
        if acknowledgements:
            f.write("\nAcknowledgements (required by the licenses of these components):\n\n")
            for e in acknowledgements:
                f.write(f"  {e['id']}: {e['acknowledgement']}\n")

    if errors:
        print(f"collect-licenses.py: {len(errors)} problem(s)", file=sys.stderr)
        sys.exit(1)
    print(f"licenses: {len(out.content)} files, {len(index_rows)} index lines, {len(sources)} source entries, {len(release_sources)} release source archives")


README = """Licenses of the MiKTeX engine package

MiKTeX is free software. This package also contains third-party
components; this directory has their license texts.

- INDEX.tsv: one line per text: component, kind, SPDX expression of the
  component, file (relative to this directory), description
- sources.tsv: where the corresponding source of each component under a
  copyleft license is: the fork's source archive of this build, or a
  release asset (Homebrew sources with their formula files, upstream
  sources)
- texts/: full texts of licenses that several components use
- miktex/, bootstrap/: MiKTeX and the packages of the first setup
- bundled/<component>/: components built from the fork's sources
- homebrew/<formula>/<version>/: libraries from Homebrew

Files named <file>.lines-<a>-<b> are the lines a to b of a source file
that carry the component's notice.
"""

if __name__ == "__main__":
    main()
