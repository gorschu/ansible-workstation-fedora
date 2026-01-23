#!/usr/bin/env bash

set -euo pipefail

sudo dnf copr enable jdxcode/mise && \
  sudo dnf install -y mise
