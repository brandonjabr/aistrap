#!/usr/bin/env python3
"""AIStrap doctor: verify that an environment can actually use its accelerator.

Run via `aistrap doctor` (or directly with an env's python). It reports the Python and
framework versions, which accelerator each framework sees, runs a short matmul
benchmark, and explains the usual fixes when something is off.

Exit code is 0 when the expected accelerator works, 1 otherwise.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from importlib import metadata

USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if USE_COLOR else text


PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
GPU_KINDS = ("cuda", "rocm", "mps", "xpu")
COLORS = {PASS: "32", WARN: "33", FAIL: "31"}
problems: list[str] = []
report: dict = {"checks": []}


def line(status: str, label: str, detail: str = "") -> None:
    print(f"  {c(COLORS[status], status)}  {label:<22} {detail}")
    report["checks"].append({"status": status, "label": label, "detail": detail})


def version(pkg: str) -> str | None:
    try:
        return metadata.version(pkg)
    except metadata.PackageNotFoundError:
        return None


def nvidia_driver() -> tuple[str | None, str | None]:
    exe = shutil.which("nvidia-smi")
    if not exe:
        return None, None
    try:
        out = subprocess.run([exe], capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return None, None
    drv = cuda = None
    for tok in out.split("|"):
        if "Driver Version:" in tok:
            drv = tok.split("Driver Version:")[1].split()[0]
        if "CUDA Version:" in tok:
            cuda = tok.split("CUDA Version:")[1].split()[0]
    return drv, cuda


def bench(fn, iters: int) -> float:
    fn()  # warm-up / compile
    t0 = time.perf_counter()
    for _ in range(iters):
        fn()
    return time.perf_counter() - t0


# --------------------------------------------------------------------------- torch
def check_torch(expect: str) -> None:
    try:
        import torch
    except Exception as e:  # noqa: BLE001
        line(FAIL, "PyTorch import", repr(e))
        problems.append("PyTorch failed to import.")
        return

    build = torch.version.cuda and f"CUDA {torch.version.cuda}" or (
        getattr(torch.version, "hip", None) and f"ROCm {torch.version.hip}") or "CPU/MPS"
    line(PASS, "PyTorch", f"{torch.__version__} ({build} build)")

    dev, label = "cpu", platform.processor() or "CPU"
    if torch.cuda.is_available():
        dev = "cuda"
        n = torch.cuda.device_count()
        for i in range(n):
            p = torch.cuda.get_device_properties(i)
            line(PASS, f"GPU {i}", f"{p.name}, {p.total_memory / 2**30:.1f} GB, compute {p.major}.{p.minor}")
        label = torch.cuda.get_device_name(0)
        if torch.version.cuda:
            cap = "sm_%d%d" % torch.cuda.get_device_capability(0)
            arches = torch.cuda.get_arch_list()
            if arches and cap not in arches and not any(a.startswith("compute_") for a in arches):
                line(WARN, "Arch support", f"{cap} not in this build ({', '.join(arches)})")
                problems.append(f"This PyTorch build has no kernels for {cap}; run 'aistrap update' for a newer build.")
    elif getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        dev, label = "mps", "Apple GPU (Metal)"
        line(PASS, "Accelerator", "Apple Metal (MPS) available")
    elif hasattr(torch, "xpu") and torch.xpu.is_available():
        dev, label = "xpu", torch.xpu.get_device_name(0)
        line(PASS, "Accelerator", f"Intel XPU: {label}")
    else:
        line(PASS if expect not in GPU_KINDS else FAIL, "Accelerator", "none - running on CPU")

    # ROCm builds expose AMD GPUs through the torch.cuda API
    actual = "rocm" if dev == "cuda" and getattr(torch.version, "hip", None) else dev
    if expect in GPU_KINDS and actual != expect:
        if actual != "cpu":
            line(FAIL, "Expected backend", f"installer set up '{expect}', but PyTorch is using '{actual}'")
        problems.append({
            "cuda": "No CUDA device visible. If the NVIDIA driver was just installed, reboot. "
                    "Check 'nvidia-smi' works; on WSL update the Windows NVIDIA driver.",
            "rocm": "No ROCm device visible. Make sure you're in the 'render' and 'video' groups "
                    "(log out/in after install) and your GPU is ROCm-supported.",
            "mps": "MPS unavailable. Requires Apple Silicon and macOS 14+.",
            "xpu": "No Intel XPU visible. Install Intel's GPU driver packages and re-login.",
        }[expect])

    # quick matmul benchmark
    try:
        size = 4096 if dev != "cpu" else 1024
        dtype = torch.float32
        if dev == "cuda":
            dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        elif dev in ("mps", "xpu"):
            dtype = torch.float16
        a = torch.randn(size, size, device=dev, dtype=dtype)
        b = torch.randn(size, size, device=dev, dtype=dtype)

        def sync():
            if dev == "cuda":
                torch.cuda.synchronize()
            elif dev == "mps":
                torch.mps.synchronize()
            elif dev == "xpu":
                torch.xpu.synchronize()

        def step():
            (a @ b)
            sync()

        iters = 20 if dev != "cpu" else 5
        secs = bench(step, iters)
        tflops = 2 * size**3 * iters / secs / 1e12
        line(PASS, "Matmul benchmark", f"{tflops:,.1f} TFLOPS ({str(dtype).replace('torch.', '')}, {size}x{size}, {label})")
        report["torch_tflops"] = round(tflops, 2)
    except Exception as e:  # noqa: BLE001
        line(FAIL, "Matmul benchmark", repr(e)[:160])
        problems.append("A basic tensor operation failed on the accelerator; see the error above.")


# --------------------------------------------------------------------------- jax / tf / mlx
def check_jax(expect: str) -> None:
    try:
        import jax
        import jax.numpy as jnp
    except Exception as e:  # noqa: BLE001
        line(FAIL, "JAX import", repr(e)[:160])
        problems.append("JAX failed to import.")
        return
    devs = jax.devices()
    kinds = sorted({d.platform for d in devs})
    gpu = any(k in ("gpu", "cuda", "rocm") for k in kinds)
    status = PASS if gpu or expect not in ("cuda",) else FAIL
    line(status, "JAX", f"{jax.__version__} on {', '.join(kinds)} ({len(devs)} device{'s' * (len(devs) > 1)})")
    if status == FAIL:
        problems.append("JAX does not see the GPU. Check the driver supports the installed jax[cudaXX] plugin.")
    x = jnp.ones((2048, 2048), dtype=jnp.float32)
    secs = bench(lambda: (x @ x).block_until_ready(), 10)
    line(PASS, "JAX matmul", f"{2 * 2048**3 * 10 / secs / 1e12:,.1f} TFLOPS (fp32)")


def check_tf(expect: str) -> None:
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    try:
        import tensorflow as tf
    except Exception as e:  # noqa: BLE001
        line(FAIL, "TensorFlow import", repr(e)[:160])
        problems.append("TensorFlow failed to import.")
        return
    gpus = tf.config.list_physical_devices("GPU")
    status = PASS if gpus or expect != "cuda" else FAIL
    line(status, "TensorFlow", f"{tf.__version__}, {len(gpus)} GPU(s)")
    if status == FAIL:
        problems.append("TensorFlow does not see the GPU (TF supports NVIDIA GPUs on Linux/WSL only).")
    kv = version("keras")
    if kv:
        line(PASS, "Keras", kv)


def check_mlx() -> None:
    try:
        import mlx.core as mx
    except Exception:
        return
    a = mx.random.normal((4096, 4096), dtype=mx.float16)
    secs = bench(lambda: mx.eval(a @ a), 20)
    line(PASS, "MLX", f"{version('mlx')} on {mx.default_device()}, {2 * 4096**3 * 20 / secs / 1e12:,.1f} TFLOPS (fp16)")


# --------------------------------------------------------------------------- main
LIBS = [
    "numpy", "pandas", "polars", "scikit-learn", "jupyterlab", "transformers", "datasets",
    "accelerate", "peft", "trl", "diffusers", "sentence-transformers", "bitsandbytes", "timm",
    "xgboost", "lightgbm", "onnxruntime", "gradio", "anthropic", "openai", "mcp", "wandb",
    "mlflow", "mlx-lm", "lightning", "flax", "optax",
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--env", default=os.path.basename(sys.prefix))
    ap.add_argument("--expect", default="", help="cuda | rocm | mps | xpu | cpu")
    ap.add_argument("--json", action="store_true", help="also print a JSON report")
    args = ap.parse_args()
    expect = args.expect or "cpu"

    print(c("1", f"\nAIStrap doctor - env '{args.env}'"))
    line(PASS, "Python", f"{platform.python_version()} ({sys.executable})")
    line(PASS, "Platform", f"{platform.system()} {platform.release()} {platform.machine()}")
    drv, drv_cuda = nvidia_driver()
    if drv:
        line(PASS, "NVIDIA driver", f"{drv} (supports CUDA {drv_cuda})")

    if version("torch"):
        check_torch(expect)
        # torch built for a newer CUDA than the driver supports?
        try:
            import torch
            if drv_cuda and torch.version.cuda:
                built = tuple(int(x) for x in torch.version.cuda.split(".")[:2])
                have = tuple(int(x) for x in drv_cuda.split(".")[:2])
                if built > have:
                    line(WARN, "Driver vs build", f"torch needs CUDA {torch.version.cuda}, driver supports {drv_cuda}")
                    problems.append("Update the NVIDIA driver, or run 'aistrap update' to pick a matching PyTorch build.")
        except Exception:
            pass
    if version("jax"):
        check_jax(expect)
    if version("tensorflow"):
        check_tf(expect)
    if version("mlx"):
        check_mlx()

    found = [(p, version(p)) for p in LIBS]
    found = [f"{p} {v}" for p, v in found if v]
    if found:
        print(c("2", "  libs: " + ", ".join(found)))
    report.update(env=args.env, problems=problems)

    if problems:
        print(c("33", "\n  What to fix:"))
        for p in dict.fromkeys(problems):
            print(f"   - {p}")
    else:
        print(c("32", "  All good."))
    if args.json:
        print(json.dumps(report, indent=2))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
