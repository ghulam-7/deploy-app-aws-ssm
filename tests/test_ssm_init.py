from pathlib import Path
import subprocess
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "manifest" / "manifest.yaml"


def _render(tmp_path: Path, image: str) -> subprocess.CompletedProcess[str]:
    script = (ROOT / "ssm-script" / "ssm-init.sh").read_text().replace("\r\n", "\n")
    renderer = script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    return subprocess.run(
        [
            sys.executable, "-c", renderer, str(MANIFEST),
            str(tmp_path / "rendered.yaml"), image, "sha256:" + "a" * 64, "default",
        ],
        capture_output=True, text=True, check=False,
    )


def test_renders_pipeline_digest_and_keeps_all_resources(tmp_path: Path) -> None:
    result = _render(tmp_path, "docker.io/ghulam6703/tapestry:13")

    assert result.returncode == 0, result.stderr
    documents = list(yaml.safe_load_all((tmp_path / "rendered.yaml").read_text()))
    assert [doc["kind"] for doc in documents] == ["Deployment", "Service", "Ingress"]
    assert documents[0]["spec"]["template"]["spec"]["containers"][0]["image"] == (
        "docker.io/ghulam6703/tapestry@sha256:" + "a" * 64
    )


def test_rejects_pipeline_image_from_another_repository(tmp_path: Path) -> None:
    result = _render(tmp_path, "docker.io/other/app:13")

    assert result.returncode != 0
    assert "no container matching" in result.stderr
