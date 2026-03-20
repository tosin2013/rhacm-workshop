import os
import time
import subprocess

from flask import Flask, jsonify, request

app = Flask(__name__)


@app.route("/health")
def health():
    return jsonify({"status": "healthy"})


@app.route("/gpu")
def gpu_info():
    try:
        result = subprocess.run(
            ["nvidia-smi"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return jsonify(
            {
                "gpu_available": result.returncode == 0,
                "nvidia_smi": result.stdout,
            }
        )
    except FileNotFoundError:
        return jsonify({"gpu_available": False, "error": "nvidia-smi not found"})
    except Exception as exc:
        return jsonify({"gpu_available": False, "error": str(exc)})


@app.route("/predict", methods=["GET", "POST"])
def predict():
    """Run a matrix multiply to exercise the CPU (or GPU when CUDA libs are present)."""
    import numpy as np

    size = int(request.args.get("size", 1024))
    a = np.random.rand(size, size).astype(np.float32)
    b = np.random.rand(size, size).astype(np.float32)

    start = time.time()
    c = np.dot(a, b)
    elapsed = time.time() - start

    return jsonify(
        {
            "operation": "matrix_multiply",
            "size": f"{size}x{size}",
            "elapsed_seconds": round(elapsed, 4),
            "result_checksum": float(c.sum()),
        }
    )


@app.route("/info")
def info():
    return jsonify(
        {
            "hostname": os.uname().nodename,
            "python_version": os.popen("python3 --version").read().strip(),
            "cuda_visible_devices": os.environ.get("CUDA_VISIBLE_DEVICES", "not set"),
            "nvidia_driver": os.environ.get("NVIDIA_DRIVER_CAPABILITIES", "not set"),
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
