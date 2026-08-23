"""Quantile-regression dynamics model skeleton (plan §2.2).

Requires torch; everything else in trioml is stdlib-only so the gate suite and
dataset tooling run anywhere. The model predicts p10/p50/p90 glucose
trajectories over the full `schema.HORIZON_MINUTES` horizon (6 h, so the gates
can score it at every label horizon up to 6 h) conditioned on history + a
candidate insulin plan, trained with pinball loss weighted toward the low
quantile.

Export path: torch → Core ML (`coremltools`), versioned + checksummed, loaded
by the app only after `gates.promotion_verdict` passes.
"""

from __future__ import annotations

from . import schema

QUANTILES = (0.1, 0.5, 0.9)
# One prediction step per 5-min frame out to the 6-h horizon (72 steps), so the
# backtest/gates can read the trajectory at every LABEL_HORIZONS_MINUTES point.
HORIZON_STEPS = schema.HORIZON_MINUTES // schema.FRAME_INTERVAL_MINUTES
# Extra pinball-loss weight on the low quantile: under-predicting lows is the
# failure mode that doses insulin into a hypo, so p10 must be conservative.
LOW_QUANTILE_LOSS_WEIGHT = 3.0

try:
    import torch
    from torch import nn

    HAS_TORCH = True

    class QuantileTCN(nn.Module):
        """Small temporal-conv net: (batch, channels, history_steps) → (batch, len(QUANTILES), horizon_steps)."""

        def __init__(
            self,
            in_channels: int,
            horizon_steps: int = HORIZON_STEPS,
            hidden: int = 64,
            levels: int = 4,
            kernel_size: int = 3,
        ):
            super().__init__()
            layers: list[nn.Module] = []
            channels = in_channels
            for level in range(levels):
                dilation = 2 ** level
                layers += [
                    nn.Conv1d(
                        channels,
                        hidden,
                        kernel_size,
                        padding=(kernel_size - 1) * dilation,
                        dilation=dilation,
                    ),
                    nn.ReLU(),
                ]
                channels = hidden
            self.tcn = nn.Sequential(*layers)
            self.head = nn.Linear(hidden, len(QUANTILES) * horizon_steps)
            self.horizon_steps = horizon_steps

        def forward(self, x: "torch.Tensor") -> "torch.Tensor":
            features = self.tcn(x)[..., : x.shape[-1]]  # causal crop
            pooled = features[..., -1]  # last-step summary
            out = self.head(pooled)
            return out.view(-1, len(QUANTILES), self.horizon_steps)

    def pinball_loss(predictions: "torch.Tensor", target: "torch.Tensor") -> "torch.Tensor":
        """predictions: (batch, quantile, step); target: (batch, step)."""
        losses = []
        for i, q in enumerate(QUANTILES):
            error = target - predictions[:, i, :]
            loss = torch.maximum(q * error, (q - 1) * error).mean()
            if q == min(QUANTILES):
                loss = loss * LOW_QUANTILE_LOSS_WEIGHT
            losses.append(loss)
        return torch.stack(losses).sum()

except ImportError:  # pragma: no cover - torch-free environments use the rest of trioml
    HAS_TORCH = False
