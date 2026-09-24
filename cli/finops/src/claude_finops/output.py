import csv
import io
import json

from rich.console import Console
from rich.table import Table
from rich.text import Text


def safe_text(value):
    text = str(value)
    return "".join(char if char in "\n\t" or (ord(char) >= 32 and not 127 <= ord(char) <= 159) else "?" for char in text)


def linear(value, prefix=""):
    if isinstance(value, dict):
        for key, item in value.items():
            yield from linear(item, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from linear(item, f"{prefix}[{index}]")
        if not value:
            yield f"{prefix}: none"
    else:
        yield f"{prefix}: {safe_text(value) if value is not None else 'unknown'}"


def display(value, *, as_json=False, plain=False, no_color=False):
    if as_json:
        print(json.dumps(value, indent=2, ensure_ascii=True, default=str))
        return
    if plain:
        print("\n".join(linear(value)))
        return
    console = Console(no_color=no_color, highlight=False)
    render(console, value)


def render(console, value, title=""):
    if isinstance(value, dict):
        simple = {k: v for k, v in value.items() if not isinstance(v, (dict, list))}
        if simple:
            table = Table(title=title or None, show_header=False, box=None, padding=(0, 2))
            table.add_column(style="bold")
            table.add_column()
            for key, item in simple.items():
                table.add_row(Text(key.replace("_", " ")), Text(safe_text(item) if item is not None else "unknown"))
            console.print(table)
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                render(console, item, key.replace("_", " "))
    elif isinstance(value, list):
        if not value:
            return
        if all(isinstance(row, dict) for row in value):
            keys = list(dict.fromkeys(key for row in value for key in row if not isinstance(row[key], (dict, list))))
            table = Table(title=title, box=None, padding=(0, 1))
            for key in keys:
                table.add_column(key.replace("_", " "))
            for row in value:
                table.add_row(*(Text(safe_text(row.get(key)) if row.get(key) is not None else "unknown") for key in keys))
            console.print(table)
        else:
            console.print(Text(f"{title}: " + ", ".join(map(safe_text, value))))
    else:
        console.print(Text(safe_text(value)))


def chargeback_csv(rows, month):
    target = io.StringIO(newline="")
    fields = ["month", "scope", "tokens", "cache_read_tokens", "requests", "estimated_cost_usd", "cost_basis"]
    writer = csv.DictWriter(target, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        name = str(row.get("name", row.get("id", "")))
        if name.startswith(("=", "+", "-", "@")):
            name = "'" + name
        writer.writerow(dict(month=month, scope=name, tokens=row.get("total_tokens"),
                             cache_read_tokens=row.get("cache_read_tokens"), requests=row.get("total_requests"),
                             estimated_cost_usd=row.get("estimated_cost"), cost_basis="estimated; not an Azure invoice"))
    return target.getvalue()
