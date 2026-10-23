#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR/python_engine"

echo "=========================================="
echo " Starting Cosmic-Gen DeepFace Studio Server"
echo "=========================================="

if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
else
    source .venv/bin/activate
fi

python3 server.py
