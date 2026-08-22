"""Quantile-regression dynamics model (plan §2.2).

Requires torch; everything else in trioml is stdlib-only so the gate suite and
dataset tooling run anywhere. The model predicts p10/p50/p90 glucose
trajectories over the 4-h horizon conditioned on 6 h of history
(``trioml.features`` samples) plus an insulin plan — the delivered plan during
training, a candidate plan at controller time — trained with pinball loss
weighted toward the low quantile.

Predictions are glucose *deltas* from "now": with two weeks of personal data
the residual formulation is what lets a small model start from persistence and
learn corrections, instead of relearning the current glucose level.

Export path: torch → Core ML (``coremltools``), versioned + checksummed, loaded
by the app only after ``gates.promotion_verdict`` passes.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from pathlib import Path

from . import features

QUANTILES = (0.1, 0.5, 0.9)
# Extra pinball-loss weight on the low quantile: under-predicting lows is the
# failure mode that doses insulin into a hypo, so p10 must be conservative.
LOW_QUANTILE_LOSS_WEIGHT = 3.0

try:
    import torch
    from torch import nn

    HAS_TORCH = True

    class QuantileTCN(nn.Module):
        """History TCN + plan encoder → ordered quantile trajectories.

        history: (batch, HISTORY_CHANNELS, HISTORY_STEPS)
        plan:    (batch, PLAN_CHANNELS, HORIZON_STEPS)
        output:  (batch, len(QUANTILES), HORIZON_STEPS), p10 ≤ p50 ≤ p90 by
                 construction (offsets through softplus), as normalized deltas.
        """

        def __init__(
            self,
            in_channels: int = len(features.HISTORY_CHANNELS),
            plan_channels: int = len(features.PLAN_CHANNELS),
            horizon_steps: int = features.HORIZON_STEPS,
            hidden: int = 32,
            levels: int = 5,
            kernel_size: int = 3,
        ):
            super().__init__()
            self.convs = nn.ModuleList()
            # Left-pad amounts per level: explicit causal padding (instead of
            # symmetric padding + crop) keeps the graph free of dynamic-shape
            # ops so the Core ML conversion stays a straight trace.
            self.causal_pads: list[int] = []
            channels = in_channels
            for level in range(levels):
                dilation = 2 ** level
                self.convs.append(nn.Conv1d(channels, hidden, kernel_size, dilation=dilation))
                self.causal_pads.append((kernel_size - 1) * dilation)
                channels = hidden
            self.plan_encoder = nn.Sequential(
                nn.Conv1d(plan_channels, hidden, kernel_size, padding=kernel_size // 2),
                nn.ReLU(),
            )
            self.head = nn.Sequential(
                nn.Linear(2 * hidden, hidden),
                nn.ReLU(),
                nn.Linear(hidden, len(QUANTILES) * horizon_steps),
            )
            self.horizon_steps = horizon_steps

        def forward(self, history: "torch.Tensor", plan: "torch.Tensor") -> "torch.Tensor":
            hist_features = history
            for pad, conv in zip(self.causal_pads, self.convs):
                hist_features = nn.functional.relu(conv(nn.functional.pad(hist_features, (pad, 0))))
            pooled = hist_features[..., -1]  # last-step summary
            plan_pooled = self.plan_encoder(plan).mean(dim=-1)
            out = self.head(torch.cat([pooled, plan_pooled], dim=-1))
            out = out.view(-1, len(QUANTILES), self.horizon_steps)
            median = out[:, 1, :]
            low = median - nn.functional.softplus(out[:, 0, :])
            high = median + nn.functional.softplus(out[:, 2, :])
            return torch.stack([low, median, high], dim=1)

    def pinball_loss(
        predictions: "torch.Tensor",
        target: "torch.Tensor",
        mask: "torch.Tensor",
    ) -> "torch.Tensor":
        """predictions: (batch, quantile, step); target/mask: (batch, step).

        Steps with mask 0 (CGM gap — no label) contribute nothing.
        """
        weight = mask.sum().clamp(min=1.0)
        losses = []
        for i, q in enumerate(QUANTILES):
            error = target - predictions[:, i, :]
            loss = (torch.maximum(q * error, (q - 1) * error) * mask).sum() / weight
            if q == min(QUANTILES):
                loss = loss * LOW_QUANTILE_LOSS_WEIGHT
            losses.append(loss)
        return torch.stack(losses).sum()

    @dataclass
    class TrainConfig:
        hidden: int = 32
        levels: int = 5
        kernel_size: int = 3
        epochs: int = 200
        batch_size: int = 64
        learning_rate: float = 1e-3
        weight_decay: float = 1e-4
        val_fraction: float = 0.15
        patience: int = 15
        seed: int = 7

    def _tensors(samples: list[dict]) -> tuple["torch.Tensor", ...]:
        history = torch.tensor(
            [s["history"] for s in samples], dtype=torch.float32
        ).transpose(1, 2)  # (batch, channels, steps)
        plan = torch.tensor(
            [s["plan"] for s in samples], dtype=torch.float32
        ).transpose(1, 2)
        target = torch.tensor([s["target"] for s in samples], dtype=torch.float32)
        mask = torch.tensor([s["target_mask"] for s in samples], dtype=torch.float32)
        return history, plan, target, mask

    def train_model(
        samples: list[dict],
        config: TrainConfig | None = None,
    ) -> tuple["QuantileTCN", dict]:
        """Trains on samples (chronological order expected), returns (model, report).

        The newest ``val_fraction`` of samples is the early-stopping split —
        chronological, never random: adjacent CGM frames are heavily
        correlated and a random split would leak the future into training.
        """
        config = config or TrainConfig()
        if len(samples) < 10:
            raise ValueError(f"{len(samples)} samples is not enough to train on")
        torch.manual_seed(config.seed)

        val_count = max(1, int(len(samples) * config.val_fraction))
        train_samples = samples[:-val_count]
        val_samples = samples[-val_count:]
        train_tensors = _tensors(train_samples)
        val_tensors = _tensors(val_samples)

        model = QuantileTCN(
            hidden=config.hidden,
            levels=config.levels,
            kernel_size=config.kernel_size,
        )
        optimizer = torch.optim.Adam(
            model.parameters(),
            lr=config.learning_rate,
            weight_decay=config.weight_decay,
        )

        best_val = float("inf")
        best_state = {k: v.clone() for k, v in model.state_dict().items()}
        best_epoch = 0
        epochs_run = 0
        n_train = train_tensors[0].shape[0]

        for epoch in range(config.epochs):
            epochs_run = epoch + 1
            model.train()
            order = torch.randperm(n_train)
            for start in range(0, n_train, config.batch_size):
                index = order[start: start + config.batch_size]
                history, plan, target, mask = (t[index] for t in train_tensors)
                optimizer.zero_grad()
                loss = pinball_loss(model(history, plan), target, mask)
                loss.backward()
                optimizer.step()

            model.eval()
            with torch.no_grad():
                history, plan, target, mask = val_tensors
                val_loss = pinball_loss(model(history, plan), target, mask).item()
            if val_loss < best_val:
                best_val = val_loss
                best_state = {k: v.clone() for k, v in model.state_dict().items()}
                best_epoch = epoch + 1
            elif epoch + 1 - best_epoch >= config.patience:
                break

        model.load_state_dict(best_state)
        model.eval()
        report = {
            "config": asdict(config),
            "train_samples": len(train_samples),
            "val_samples": len(val_samples),
            "epochs_run": epochs_run,
            "best_epoch": best_epoch,
            "best_val_pinball": best_val,
            "parameters": sum(p.numel() for p in model.parameters()),
        }
        return model, report

    class QuantileForecaster:
        """Inference wrapper: samples in, absolute-glucose trajectories out."""

        def __init__(self, model: "QuantileTCN"):
            self.model = model
            self.model.eval()

        def predict(self, sample: dict, plan: list[list[float]] | None = None) -> dict[str, list[float]]:
            """Returns {"p10": [...], "p50": [...], "p90": [...]} in mg/dL per
            5-min step. ``plan`` overrides the sample's delivered insulin with a
            candidate plan (the controller's question: "what if I gave this?")."""
            history = torch.tensor([sample["history"]], dtype=torch.float32).transpose(1, 2)
            plan_tensor = torch.tensor(
                [plan if plan is not None else sample["plan"]], dtype=torch.float32
            ).transpose(1, 2)
            with torch.no_grad():
                deltas = self.model(history, plan_tensor)[0]
            now = sample["now_glucose"]
            result = {}
            for i, quantile in enumerate(QUANTILES):
                trajectory = [
                    min(max(now + delta * features.GLUCOSE_SCALE, 20.0), 500.0)
                    for delta in deltas[i].tolist()
                ]
                result[f"p{int(quantile * 100)}"] = trajectory
            return result

        def predict_horizon(self, sample: dict, horizon_minutes: int) -> dict[str, float]:
            step = features.horizon_step(horizon_minutes)
            return {k: v[step] for k, v in self.predict(sample).items()}

    def save_model(model: "QuantileTCN", report: dict, directory: str | Path) -> dict:
        """Writes weights + metadata; the checksum is what promotion pins."""
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        weights_path = directory / "dynamics_model.pt"
        torch.save(model.state_dict(), weights_path)
        checksum = hashlib.sha256(weights_path.read_bytes()).hexdigest()
        meta = {
            "schema": "trioml.dynamics.v1",
            "quantiles": list(QUANTILES),
            "history_channels": list(features.HISTORY_CHANNELS),
            "plan_channels": list(features.PLAN_CHANNELS),
            "horizon_steps": features.HORIZON_STEPS,
            "weights_sha256": checksum,
            "training": report,
        }
        (directory / "dynamics_model.json").write_text(json.dumps(meta, indent=2))
        return meta

    def load_model(directory: str | Path) -> tuple["QuantileTCN", dict]:
        """Loads and checksum-verifies a saved model; mismatch is a hard error."""
        directory = Path(directory)
        meta = json.loads((directory / "dynamics_model.json").read_text())
        weights_path = directory / "dynamics_model.pt"
        checksum = hashlib.sha256(weights_path.read_bytes()).hexdigest()
        if checksum != meta["weights_sha256"]:
            raise ValueError(
                f"weights checksum {checksum} != recorded {meta['weights_sha256']}; refusing to load"
            )
        config = TrainConfig(**meta["training"]["config"])
        model = QuantileTCN(
            hidden=config.hidden,
            levels=config.levels,
            kernel_size=config.kernel_size,
        )
        model.load_state_dict(torch.load(weights_path, weights_only=True))
        model.eval()
        return model, meta

except ImportError:  # pragma: no cover - torch-free environments use the rest of trioml
    HAS_TORCH = False
