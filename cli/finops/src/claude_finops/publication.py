"""Fail closed before any live SVG is written to the documentation tree."""

from datetime import datetime
import json
from hashlib import sha256
import re
from xml.etree import ElementTree

from .redaction import privacy_problems


def validate_capture(svg, entry):
    problems = []
    name = entry.get("file", "")
    if not re.fullmatch(r"[a-z0-9-]+\.svg", name):
        problems.append("unsafe capture filename")
    if entry.get("source") not in {"live", "example"}:
        problems.append("missing live/example provenance")
    if entry.get("source") == "live" and entry.get("redaction") is not True:
        problems.append("live image requires display redaction")
    if entry.get("backend") not in {"Turnstile", "Direct", "AUM service", "Example"}:
        problems.append("missing backend")
    if not re.fullmatch(r"[a-f0-9]{40}", entry.get("commit", "")):
        problems.append("missing source commit")
    try:
        stamp = datetime.fromisoformat(entry["captured_at"].replace("Z", "+00:00"))
        if stamp.utcoffset() is None or stamp.utcoffset().total_seconds() != 0:
            problems.append("capture time must be UTC")
    except (ValueError, KeyError, AttributeError):
        problems.append("missing UTC capture time")
    try:
        root = ElementTree.fromstring(svg)
        text = " ".join(root.itertext()).replace("\xa0", " ")
        problems += privacy_problems(text)
        problems += privacy_problems(svg)
    except ElementTree.ParseError:
        problems.append("invalid SVG")
    return sorted(set(problems))


def validate_manifest(folder):
    path = folder / "manifest.json"
    if not path.exists():
        return ["missing docs image manifest"]
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        entries = document["images"]
        if not isinstance(entries, list):
            raise ValueError()
    except (ValueError, KeyError):
        return ["invalid docs image manifest"]
    problems, seen = [], set()
    for item in entries:
        name = item.get("file", "")
        if name in seen:
            problems.append("duplicate manifest entry: " + name)
        seen.add(name)
        if not re.fullmatch(r"[a-z0-9-]+\.svg", name):
            problems.append("unsafe filename")
            continue
        image = folder / name
        if not image.exists():
            problems.append("missing image: " + name)
        else:
            problems += [name + ": " + p for p in validate_capture(image.read_text(encoding="utf-8"), item)]
    for image in folder.iterdir():
        if image.suffix.lower() not in {".svg", ".png", ".jpg", ".jpeg", ".webp"}:
            continue
        if image.name not in seen:
            problems.append("image has no manifest: " + image.name)
    return problems


def validate_portal_manifest(folder):
    path = folder / "manifest.json"
    if not path.exists():
        return ["missing live portal manifest"]
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        entries = document["images"]
    except (ValueError, KeyError):
        return ["invalid portal manifest"]
    problems, seen = [], set()
    if document.get("auth_blocked"):
        problems.append("portal sign-in was required; do not claim complete portal capture")
    if not entries:
        problems.append("no live portal images")
    for entry in entries:
        name, text_file = entry.get("file", ""), entry.get("text_file", "")
        if not re.fullmatch(r"[a-z0-9-]+\.png", name) or not re.fullmatch(r"[a-z0-9-]+\.txt", text_file):
            problems.append("unsafe portal evidence filename")
            continue
        if name in seen:
            problems.append("duplicate portal image")
        seen.add(name)
        image, transcript = folder / name, folder / text_file
        if entry.get("source") != "live" or entry.get("redaction") is not True:
            problems.append(name + ": must be live and redacted")
        if not re.fullmatch(r"[a-f0-9]{40}", entry.get("commit", "")):
            problems.append(name + ": source commit missing")
        if not image.exists() or not transcript.exists():
            problems.append(name + ": image or redacted DOM evidence missing")
            continue
        if sha256(image.read_bytes()).hexdigest() != entry.get("sha256"):
            problems.append(name + ": image hash does not match provenance")
        problems += [name + ": " + issue for issue in privacy_problems(transcript.read_text(encoding="utf-8"))]
    for image in folder.glob("*.png"):
        if image.name not in seen:
            problems.append("portal image has no manifest: " + image.name)
    required = {"gateway-overview.png", "gateway-named-values.png", "gateway-apis.png",
                "insights-overview.png", "workspace-overview.png", "workspace-logs.png",
                "turnstile-overview.png"}
    problems += ["required portal flow missing: " + name for name in sorted(required - seen)]
    return problems
