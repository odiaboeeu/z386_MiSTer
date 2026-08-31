#!/usr/bin/env python3
"""Summarize every Quartus seed sweep in ``seed_sweep/``.

The default table reports the distribution that matters when comparing RTL:
average/best/worst WNS, average/worst TNS, average/maximum ALM use, and each
successful seed's WNS.  Incomplete and failed sweeps remain visible so a
missing result is not mistaken for a good build.
"""

from __future__ import annotations

import argparse
import csv
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class SeedResult:
    seed: int
    status: str
    wns: float | None
    tns: float | None
    alms: int | None


@dataclass(frozen=True)
class SweepResult:
    name: str
    seeds: tuple[SeedResult, ...]
    seed_dirs: int
    has_summary: bool

    @property
    def good(self) -> tuple[SeedResult, ...]:
        return tuple(
            seed for seed in self.seeds
            if seed.status == "ok"
            and seed.wns is not None
            and seed.tns is not None
            and seed.alms is not None
        )

    @property
    def total(self) -> int:
        return len(self.seeds) if self.has_summary else self.seed_dirs

    @property
    def state(self) -> str:
        if not self.has_summary:
            return "incomplete" if self.seed_dirs else "no-results"
        if len(self.good) == len(self.seeds) and self.seeds:
            return "ok"
        return "partial"


def optional_float(value: str | None) -> float | None:
    try:
        return float(value) if value not in (None, "") else None
    except ValueError:
        return None


def optional_int(value: str | None) -> int | None:
    try:
        return int(value) if value not in (None, "") else None
    except ValueError:
        return None


def read_sweep(path: Path) -> SweepResult:
    summary = path / "summary.csv"
    seed_dirs = sum(1 for child in path.glob("seed_[0-9][0-9]") if child.is_dir())
    if not summary.is_file():
        return SweepResult(path.name, (), seed_dirs, False)

    seeds: list[SeedResult] = []
    with summary.open(newline="") as stream:
        for row in csv.DictReader(stream):
            seed = optional_int(row.get("seed"))
            if seed is None:
                continue
            seeds.append(
                SeedResult(
                    seed=seed,
                    status=row.get("status", ""),
                    wns=optional_float(row.get("setup_slack")),
                    tns=optional_float(row.get("setup_tns")),
                    alms=optional_int(row.get("alms")),
                )
            )
    return SweepResult(path.name, tuple(sorted(seeds, key=lambda item: item.seed)),
                       seed_dirs, True)


def read_all(root: Path) -> list[SweepResult]:
    if not root.is_dir():
        raise SystemExit(f"sweep directory does not exist: {root}")
    return [read_sweep(path) for path in sorted(root.iterdir()) if path.is_dir()]


def average(values: Iterable[float | int]) -> float:
    return statistics.fmean(values)


def metric_cells(sweep: SweepResult) -> dict[str, str]:
    good = sweep.good
    if not good:
        return {
            "wns_avg": "-", "wns_worst": "-", "wns_best": "-",
            "tns_avg": "-", "tns_worst": "-", "alm_avg": "-",
            "alm_max": "-", "seed_wns": "-",
        }

    wns = [seed.wns for seed in good if seed.wns is not None]
    tns = [seed.tns for seed in good if seed.tns is not None]
    alms = [seed.alms for seed in good if seed.alms is not None]
    return {
        "wns_avg": f"{average(wns):.3f}",
        "wns_worst": f"{min(wns):.3f}",
        "wns_best": f"{max(wns):.3f}",
        "tns_avg": f"{average(tns):.3f}",
        "tns_worst": f"{min(tns):.3f}",
        "alm_avg": f"{average(alms):.1f}",
        "alm_max": str(max(alms)),
        "seed_wns": ",".join(f"{seed.seed}:{seed.wns:.3f}" for seed in good),
    }


def rows(sweeps: Iterable[SweepResult]) -> list[dict[str, str]]:
    output: list[dict[str, str]] = []
    for sweep in sweeps:
        metrics = metric_cells(sweep)
        output.append({
            "sweep": sweep.name,
            "state": sweep.state,
            "ok/total": f"{len(sweep.good)}/{sweep.total}",
            **metrics,
        })
    return output


FIELDS = (
    "sweep", "state", "ok/total", "wns_avg", "wns_worst", "wns_best",
    "tns_avg", "tns_worst", "alm_avg", "alm_max", "seed_wns",
)


def print_table(items: list[dict[str, str]]) -> None:
    headings = {
        "sweep": "SWEEP", "state": "STATE", "ok/total": "OK/TOTAL",
        "wns_avg": "WNS AVG", "wns_worst": "WNS WORST",
        "wns_best": "WNS BEST", "tns_avg": "TNS AVG",
        "tns_worst": "TNS WORST", "alm_avg": "ALM AVG",
        "alm_max": "ALM MAX", "seed_wns": "WNS BY SEED",
    }
    widths = {
        field: max(len(headings[field]), *(len(item[field]) for item in items))
        for field in FIELDS
    }
    numeric = set(FIELDS[2:-1])

    def line(values: dict[str, str]) -> str:
        cells = []
        for field in FIELDS:
            value = values[field]
            cells.append(value.rjust(widths[field]) if field in numeric
                         else value.ljust(widths[field]))
        return "  ".join(cells).rstrip()

    print(line(headings))
    print("  ".join("-" * widths[field] for field in FIELDS))
    for item in items:
        print(line(item))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path,
        default=Path(__file__).resolve().parent / "seed_sweep",
        help="seed-sweep directory (default: seed_sweep beside this script)",
    )
    parser.add_argument("--csv", action="store_true", help="write CSV instead of a table")
    parser.add_argument("--completed-only", action="store_true",
                        help="hide sweeps without a complete successful summary")
    parser.add_argument("--newest-first", action="store_true", help="reverse chronological order")
    args = parser.parse_args()

    sweeps = read_all(args.root)
    if args.completed_only:
        sweeps = [sweep for sweep in sweeps if sweep.state == "ok"]
    if args.newest_first:
        sweeps.reverse()
    output = rows(sweeps)

    if args.csv:
        writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(output)
    else:
        print_table(output)


if __name__ == "__main__":
    main()
