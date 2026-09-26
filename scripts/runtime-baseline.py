#!/usr/bin/env python3
"""Capture comparable runtime measurements from an isolated Git revision.

Runtime sources come from the revision. The benchmark driver and corpus come
from this checkout, so both sides use the same measurement protocol. No runtime
working-tree changes are included unless supplied with --runtime-patch.
Results include raw samples and provenance.
"""

import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd=ROOT, **kwargs):
    return subprocess.run(command, cwd=cwd, check=True, **kwargs)


def git(*args, repo=ROOT):
    return run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive(repo, revision, destination):
    data = run(["git", "-C", str(repo), "archive", revision], capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as source:
        source.extractall(destination, filter="data")


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new output directory; never overwritten")
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--cpu", type=int, required=True, help="one allowed CPU; workers=1")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--samples", type=int, default=21)
    parser.add_argument("--budget-ms", type=int, default=20)
    parser.add_argument("--runtime-patch", type=Path, help="apply a saved runtime diff to the revision")
    parser.add_argument("--baseline", type=Path, help="prior manifest.json for comparison")
    args = parser.parse_args()
    if args.cpu not in os.sched_getaffinity(0):
        parser.error("CPU is outside the process affinity")
    if min(args.runs, args.samples, args.budget_ms) < 1:
        parser.error("runs, samples, and budget must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / "source"
    source.mkdir()
    revision = git("rev-parse", f"{args.revision}^{{commit}}")
    archive(ROOT, revision, source)
    vendor_revision = git("ls-tree", revision, "vendor/micromeasure").split()[2]
    vendor = source / "vendor/micromeasure"
    vendor.mkdir(parents=True, exist_ok=True)
    archive(ROOT / "vendor/micromeasure", vendor_revision, vendor)

    patch_sha256 = None
    if args.runtime_patch:
        patch_path = args.runtime_patch.resolve()
        shutil.copy2(patch_path, output / "runtime.patch")
        patch_sha256 = digest(patch_path)
        run(["patch", "-p1", "--batch", "--forward", "--input", str(patch_path)], cwd=source, capture_output=True)

    # Overlay only measurement code. Keep a copy of the launcher too.
    shutil.copy2(__file__, output / "runtime-baseline.py")
    # Resolve glob against ROOT even when invoked from another directory.
    overlay = [Path("tools/micabench/main.odin"), *[p.relative_to(ROOT) for p in sorted((ROOT / "benchmarks/mica").glob("*.mica"))]]
    for path in overlay:
        shutil.copy2(ROOT / path, source / path)

    fixtures = source / "benchmarks/mica"
    large = fixtures / "runtime_catalog_1024.mica"
    large.write_text("".join(f"make_identity(:seed_{i})\n" for i in range(1024))
                     + "".join(f"verb unused_{i}(x)\n  return x\nend\n" for i in range(64))
                     + (fixtures / "runtime_identity_lookup.mica").read_text())
    cases = [
        ("empty_task", "harness_empty.mica", "1", 1, "task", ""),
        ("direct_calls", "language_call.mica", "30000", 30000, "call", ""),
        ("callable_calls", "runtime_callable.mica", "30000", 30000, "call", ""),
        ("dynamic_dispatch", "runtime_dynamic_dispatch.mica", "2000", 2000, "dispatch", ""),
        ("identity_lookup", "runtime_identity_lookup.mica", "10000", 10000, "lookup", ""),
        ("identity_lookup_large_catalog", large.name, "10000", 10000, "lookup", ""),
        ("live_eval", "harness_empty.mica", "1", 1, "eval", "return 1"),
        ("live_eval_large_catalog", large.name, "1", 1, "eval", "return 1"),
        ("relation_scan", "relation_scan.mica", "1000", 1000, "row", ""),
        ("relation_commits", "relation_commit.mica", "256", 256, "commit", ""),
    ]
    odin = shutil.which(os.environ.get("ODIN_BIN", "odin"))
    if not odin:
        raise RuntimeError("Odin compiler not found")
    compiler = run([odin, "version"], capture_output=True, text=True).stdout.strip()
    protocol = {
        "version": 1, "cpu": args.cpu, "workers": 1, "runs": args.runs,
        "samples": args.samples, "budget_ms": args.budget_ms, "build_flags": "-o:speed",
        "compiler": compiler, "compiler_sha256": digest(Path(odin)),
        "micromeasure_revision": vendor_revision,
        "harness_sha256": digest(source / "tools/micabench/main.odin"),
        "fixtures": {file: digest(fixtures / file) for _, file, *_ in cases},
        "cases": cases,
        "verification": "Every call must complete and match the probe; checks are timed.",
    }
    manifest = {
        "revision": revision, "runtime_patch_sha256": patch_sha256, "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "machine": platform.node(), "platform": platform.platform(), "protocol": protocol,
        "status": "running", "measurements": [], "summary": [],
        "working_tree_status_excluded": git("status", "--short"),
        "unsupported_before": ["fresh identity creation", "independent program installation and replacement"],
    }
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        # JSON roundtrip converts tuples to arrays before comparison.
        if baseline["protocol"] != json.loads(json.dumps(protocol)) or baseline["machine"] != manifest["machine"]:
            raise RuntimeError("baseline machine or measurement protocol differs")
        if baseline["status"] != "complete":
            raise RuntimeError("baseline is incomplete")
    else:
        baseline = None
    save(output / "manifest.json", manifest)
    (output / "lscpu.txt").write_text(run(["lscpu"], capture_output=True, text=True).stdout)
    (output / "cpuinfo.txt").write_text(Path("/proc/cpuinfo").read_text())
    policy = Path(f"/sys/devices/system/cpu/cpu{args.cpu}/cpufreq")
    save(output / "cpu-frequency.json", {p.name: p.read_text().strip() for p in policy.glob("*") if p.is_file() and p.name in {"scaling_governor", "scaling_min_freq", "scaling_max_freq", "cpuinfo_max_freq"}})
    binary = output / "micabench"
    with (output / "build.log").open("w") as log:
        run([odin, "build", "tools/micabench", "-o:speed", f"-out:{binary}"], cwd=source, stdout=log, stderr=subprocess.STDOUT)
    manifest["binary_sha256"] = digest(binary)

    # Keep runs serial. Rotate case order to distribute thermal/time drift.
    for repeat in range(args.runs):
        ordered = cases[repeat % len(cases):] + cases[:repeat % len(cases)]
        for name, file, expected, units, unit, evaluation in ordered:
            stem = f"{repeat+1:02d}-{name}"
            rss_path = output / f"{stem}.rss-kib"
            command = ["/usr/bin/time", "-f", "%M", "-o", str(rss_path),
                       "taskset", "-c", str(args.cpu), str(binary),
                       "--samples", str(args.samples), "--budget-ms", str(args.budget_ms),
                       "--workers", "1", "--raw-samples", "--verify-result", "--result"]
            if evaluation:
                command.append(f"--eval={evaluation}")
            command.append(str(fixtures / file))
            load_before = list(os.getloadavg())
            with (output / f"{stem}.stdout").open("w") as stdout, (output / f"{stem}.stderr").open("w") as stderr:
                run(command, cwd=source, stdout=stdout, stderr=stderr, timeout=180)
            lines = (output / f"{stem}.stdout").read_text().splitlines()
            result = next(line.split("\t", 2)[2] for line in lines if line.startswith("result\t"))
            if result != expected:
                raise RuntimeError(f"{name}: expected {expected}, got {result}")
            samples = [int(line.split("\t")[3]) for line in lines if line.startswith("sample\t")]
            if len(samples) != args.samples:
                raise RuntimeError(f"{name}: missing samples")
            measurement = {
                "name": name, "run": repeat+1, "command": command, "result": result,
                "samples_ns": samples, "median_ns": statistics.median(samples),
                "min_ns": min(samples), "max_ns": max(samples),
                "peak_rss_kib": int(rss_path.read_text()), "load_before": load_before,
            }
            manifest["measurements"].append(measurement)
            save(output / "manifest.json", manifest)
            print(f"{repeat+1}/{args.runs} {name}: {measurement['median_ns']/1e6:.3f} ms", flush=True)

    for name, _, _, units, unit, _ in cases:
        results = [row for row in manifest["measurements"] if row["name"] == name]
        medians = [row["median_ns"] for row in results]
        summary = {
            "name": name, "median_ns": statistics.median(medians),
            "run_min_ns": min(medians), "run_max_ns": max(medians),
            "units_per_call": units, "unit": unit,
            "ns_per_unit": statistics.median(medians)/units,
            "median_process_peak_rss_kib": statistics.median(row["peak_rss_kib"] for row in results),
        }
        if baseline:
            before = next(row for row in baseline["summary"] if row["name"] == name)
            summary["change_percent"] = (summary["median_ns"] / before["median_ns"] - 1) * 100
        manifest["summary"].append(summary)
    manifest["status"] = "complete"
    save(output / "manifest.json", manifest)
    rows = ["case\tmedian_ns\trun_min_ns\trun_max_ns\tns_per_unit\tunit\tprocess_peak_rss_kib"]
    for row in manifest["summary"]:
        rows.append("\t".join(str(row[key]) for key in ["name", "median_ns", "run_min_ns", "run_max_ns", "ns_per_unit", "unit", "median_process_peak_rss_kib"]))
    (output / "summary.tsv").write_text("\n".join(rows) + "\n")
    print(f"Saved {output / 'manifest.json'}")


if __name__ == "__main__":
    main()
