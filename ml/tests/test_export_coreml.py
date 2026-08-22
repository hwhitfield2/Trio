import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import model

try:
    import coremltools  # noqa: F401

    HAS_COREMLTOOLS = True
except ImportError:
    HAS_COREMLTOOLS = False

if model.HAS_TORCH:
    from test_model import synthetic_samples


@unittest.skipUnless(model.HAS_TORCH and HAS_COREMLTOOLS, "torch + coremltools required")
class ExportCoreMLTests(unittest.TestCase):
    def test_export_refuses_unpromoted_and_exports_promoted(self):
        import export_coreml

        samples = synthetic_samples(180)
        config = model.TrainConfig(epochs=2, patience=2, hidden=16, levels=3)
        trained, report = model.train_model(samples, config)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir = Path(tmpdir)
            model.save_model(trained, report, tmpdir)

            (tmpdir / "dynamics_report.json").write_text(json.dumps({"verdict": {"promote": False}}))
            argv = sys.argv
            sys.argv = ["export_coreml.py", str(tmpdir)]
            try:
                with self.assertRaises(SystemExit):
                    export_coreml.main()
                self.assertFalse((tmpdir / "DynamicsModel.mlpackage").exists())

                (tmpdir / "dynamics_report.json").write_text(json.dumps({"verdict": {"promote": True}}))
                export_coreml.main()
            finally:
                sys.argv = argv

            self.assertTrue((tmpdir / "DynamicsModel.mlpackage").is_dir())
            verification = json.loads((tmpdir / "coreml_verification.json").read_text())
            self.assertEqual(len(verification["cases"]), export_coreml.VERIFICATION_CASES)
            case = verification["cases"][0]
            self.assertEqual(len(case["quantile_deltas"]), len(model.QUANTILES))

    def test_verification_cases_are_deterministic(self):
        import export_coreml

        samples = synthetic_samples(180)
        config = model.TrainConfig(epochs=1, patience=1, hidden=16, levels=3)
        trained, _ = model.train_model(samples, config)
        first = export_coreml.verification_cases(trained)
        second = export_coreml.verification_cases(trained)
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
