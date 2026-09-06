#!/usr/bin/env python3
"""Build SkillBox's small, versioned discovery catalog from public Git repositories."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile
import urllib.request
from datetime import datetime, timezone


SOURCES = (
    # This repository is maintained by OpenAI, but most Skills inside belong to
    # third-party plugin packages. Repository inclusion means curated, not that
    # every nested Skill was authored by OpenAI.
    ("openai/plugins", "main", "curated"),
    ("anthropics/skills", "main", "official"),
    ("github/awesome-copilot", "main", "curated"),
)


def frontmatter(markdown: str) -> tuple[str, str] | None:
    lines = markdown.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    try:
        closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration:
        return None
    block = lines[1:closing]

    def scalar(key: str) -> str | None:
        for index, line in enumerate(block):
            stripped = line.lstrip()
            if not stripped.startswith(f"{key}:"):
                continue
            raw = stripped.split(":", 1)[1].strip()
            if raw in {"|", ">", "|-", ">-", "|+", ">+"}:
                continuation: list[str] = []
                for following in block[index + 1 :]:
                    if following and not following[0].isspace():
                        break
                    clean = following.strip()
                    if clean:
                        continuation.append(clean)
                return (" " if raw.startswith(">") else "\n").join(continuation) or None
            value = raw.strip("\"'")
            return value or None
        return None

    name = scalar("name")
    description = scalar("description")
    if not name or not description:
        return None
    return name, description


def normalize_name(value: str) -> str:
    return value.strip().lower().replace("_", "-")


def clone_source(root: pathlib.Path, repository: str, revision: str) -> pathlib.Path:
    destination = root / repository.replace("/", "--")
    subprocess.run(
        [
            "git",
            "clone",
            "--depth",
            "1",
            "--filter=blob:none",
            "--no-checkout",
            f"https://github.com/{repository}.git",
            str(destination),
        ],
        check=True,
    )
    subprocess.run(["git", "sparse-checkout", "init", "--no-cone"], cwd=destination, check=True)
    subprocess.run(["git", "sparse-checkout", "set", "**/SKILL.md"], cwd=destination, check=True)
    subprocess.run(["git", "checkout", revision], cwd=destination, check=True)
    return destination


def collect_entries(root: pathlib.Path, repository: str, revision: str, trust: str) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for skill_file in sorted(root.rglob("SKILL.md")):
        if ".git" in skill_file.parts:
            continue
        parsed = frontmatter(skill_file.read_text(encoding="utf-8", errors="replace"))
        if not parsed:
            continue
        name, description = parsed
        relative_path = skill_file.relative_to(root).as_posix()
        if relative_path.startswith((".github/", ".agents/")):
            continue
        if relative_path != "SKILL.md" and normalize_name(skill_file.parent.name) != normalize_name(name):
            continue
        entries.append(
            {
                "repository": repository,
                "revision": revision,
                "path": relative_path,
                "name": name,
                "description": description,
                "trust": trust,
            }
        )
    return entries


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1]
        / "Sources/SkillBoxCore/Resources/trusted-skills-catalog-v1.json",
    )
    arguments = parser.parse_args()

    workspace = pathlib.Path(tempfile.mkdtemp(prefix="skillbox-trusted-catalog-"))
    try:
        entries: list[dict[str, str]] = []
        counts: dict[str, int] = {}
        for repository, revision, trust in SOURCES:
            source_root = clone_source(workspace, repository, revision)
            source_entries = collect_entries(source_root, repository, revision, trust)
            entries.extend(source_entries)
            counts[repository] = len(source_entries)
        supplements = json.loads(pathlib.Path(__file__).with_name("trusted-skill-supplements.json").read_text())
        indexed = {(entry["repository"].lower(), entry["path"]): entry for entry in entries}
        for entry in supplements:
            url = f'https://raw.githubusercontent.com/{entry["repository"]}/{entry["revision"]}/{entry["path"]}'
            with urllib.request.urlopen(url, timeout=20) as response:
                markdown = response.read(512 * 1024).decode("utf-8")
            parsed = frontmatter(markdown)
            if parsed is None or normalize_name(parsed[0]) != normalize_name(entry["name"]):
                raise ValueError(f'Supplement identity could not be verified: {entry["repository"]}')
            indexed[(entry["repository"].lower(), entry["path"])] = {**entry, "description": parsed[1]}
        entries = list(indexed.values())
        entries.sort(key=lambda item: (item["repository"].lower(), item["path"].lower()))
        snapshot = {
            "version": 1,
            "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "entries": entries,
        }
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        temporary_output = arguments.output.with_suffix(".tmp")
        temporary_output.write_text(
            json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        temporary_output.replace(arguments.output)
        print(json.dumps({"entries": len(entries), "bytes": arguments.output.stat().st_size, "sources": counts}))
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


if __name__ == "__main__":
    main()
