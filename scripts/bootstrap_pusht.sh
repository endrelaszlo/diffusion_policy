#!/usr/bin/env bash
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${ROOT}/data"

dl() { # dl URL OUT
  [[ -f "$2" && "$FORCE" -ne 1 ]] && return 0
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    echo "Need curl or wget" >&2
    exit 2
  fi
}

mkdir -p "$DATA"

# 1) Training data (README: data/pusht.zip -> unzip)
if [[ "$FORCE" -eq 1 || ! -d "${DATA}/pusht_demo.zarr" ]]; then
  command -v unzip >/dev/null 2>&1 || { echo "Need unzip" >&2; exit 2; }
  dl "https://diffusion-policy.cs.columbia.edu/data/training/pusht.zip" "${DATA}/pusht.zip"
  unzip -o "${DATA}/pusht.zip" -d "$DATA" >/dev/null
  rm -f "${DATA}/pusht.zip"
fi

# 2) Config (README: config.yaml -> image_pusht_diffusion_policy_cnn.yaml)
dl "https://diffusion-policy.cs.columbia.edu/data/experiments/image/pusht/diffusion_policy_cnn/config.yaml" \
   "${ROOT}/image_pusht_diffusion_policy_cnn.yaml"

# 3) Example checkpoint (README: epoch=0550...ckpt)
dl "https://diffusion-policy.cs.columbia.edu/data/experiments/low_dim/pusht/diffusion_policy_cnn/train_0/checkpoints/epoch=0550-test_mean_score=0.969.ckpt" \
   "${DATA}/epoch=0550-test_mean_score=0.969.ckpt"
ln -sf "epoch=0550-test_mean_score=0.969.ckpt" "${DATA}/0550-test_mean_score=0.969.ckpt"


