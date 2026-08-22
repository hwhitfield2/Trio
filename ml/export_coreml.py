#!/usr/bin/env python3
"""Convert a gate-passing dynamics model to Core ML (plan §7, item 15).

Takes the artifact directory train_dynamics.py wrote (dynamics_model.pt +
dynamics_model.json + dynamics_report.json), refuses to export a candidate
whose gate verdict was not `promote` (an unvalidated set of weights never
doses — and never even ships), and produces:

- ``DynamicsModel.mlpackage`` — the Core ML program, with the torch weights
  checksum and training provenance stamped into its metadata;
- ``coreml_verification.json`` — seeded synthetic input/output pairs from the
  torch model. Linux cannot run Core ML predictions, so parity is proven on
  the Mac/app side by replaying these through the compiled model and demanding
  near-equality before the artifact is trusted (mirrors how export_model.py
  verifies the sklearn shadow forecaster in-process).

    pip install torch coremltools
    python3 ml/export_coreml.py ml/output
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from trioml import features
from trioml import model as model_module

VERIFICATION_CASES = 8
VERIFICATION_SEED = 99
# Core ML mlprogram runs float32 with op reassociation; parity means "equal
# within float noise", not bit-equal.
VERIFICATION_TOLERANCE_MGDL = 0.5


def verification_cases(net) -> list[dict]:
    """Seeded synthetic inputs + torch outputs; PHI-free by construction."""
    import torch

    generator = torch.Generator().manual_seed(VERIFICATION_SEED)
    cases = []
    for _ in range(VERIFICATION_CASES):
        history = torch.rand(
            1, len(features.HISTORY_CHANNELS), features.HISTORY_STEPS, generator=generator
        ) * 2 - 1
        plan = torch.rand(
            1, len(features.PLAN_CHANNELS), features.HORIZON_STEPS, generator=generator
        )
        with torch.no_grad():
            output = net(history, plan)
        cases.append({
            "history": history[0].tolist(),
            "plan": plan[0].tolist(),
            "quantile_deltas": output[0].tolist(),
        })
    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("artifact_dir", help="directory train_dynamics.py wrote")
    args = parser.parse_args()

    if not model_module.HAS_TORCH:
        raise SystemExit("torch is required: pip install torch")
    import torch

    try:
        import coremltools as ct
    except ImportError:
        raise SystemExit("coremltools is required: pip install coremltools")

    artifact_dir = Path(args.artifact_dir)
    report_path = artifact_dir / "dynamics_report.json"
    if not report_path.exists():
        raise SystemExit(f"{report_path} not found — run train_dynamics.py first")
    report = json.loads(report_path.read_text())
    verdict = report.get("verdict", {})
    if not verdict.get("promote"):
        raise SystemExit(f"gate verdict is not promote ({verdict}); refusing to export")

    net, meta = model_module.load_model(artifact_dir)

    history = torch.zeros(1, len(features.HISTORY_CHANNELS), features.HISTORY_STEPS)
    plan = torch.zeros(1, len(features.PLAN_CHANNELS), features.HORIZON_STEPS)
    traced = torch.jit.trace(net, (history, plan))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="history", shape=history.shape),
            ct.TensorType(name="plan", shape=plan.shape),
        ],
        outputs=[ct.TensorType(name="quantile_deltas")],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = (
        "Trio dynamics model: p10/p50/p90 glucose deltas (normalized) over the "
        "4-h horizon, conditioned on 6-h history + insulin plan. Shadow/gated use only."
    )
    mlmodel.user_defined_metadata["weights_sha256"] = meta["weights_sha256"]
    mlmodel.user_defined_metadata["schema"] = meta["schema"]
    mlmodel.user_defined_metadata["quantiles"] = json.dumps(meta["quantiles"])
    mlmodel.user_defined_metadata["glucose_scale"] = str(features.GLUCOSE_SCALE)

    package_path = artifact_dir / "DynamicsModel.mlpackage"
    mlmodel.save(str(package_path))

    verification = {
        "weights_sha256": meta["weights_sha256"],
        "tolerance_mgdl": VERIFICATION_TOLERANCE_MGDL,
        "glucose_scale": features.GLUCOSE_SCALE,
        "cases": verification_cases(net),
    }
    verification_path = artifact_dir / "coreml_verification.json"
    verification_path.write_text(json.dumps(verification))

    print(f"wrote {package_path}")
    print(f"wrote {verification_path} ({VERIFICATION_CASES} cases)")
    print("next: compile on macOS/device and replay the verification cases "
          "before the app trusts this artifact")


if __name__ == "__main__":
    main()
