#!/usr/bin/env sh
set -eu

if [ ! -x /cache/bin/kubectl ]; then
  mkdir -p /cache/bin
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    armv7l)  ARCH=arm ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  wget -qO /cache/bin/kubectl "https://dl.k8s.io/release/$(wget -qO- https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
  chmod +x /cache/bin/kubectl
fi

echo "/cache/bin" >> "$GITHUB_PATH"
