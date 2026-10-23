@echo off
title Cosmic-Gen DeepFace Studio Engine
echo ==========================================
echo  Starting Cosmic-Gen DeepFace Studio Server
echo ==========================================

cd /d "%~dp0\python_engine"

if not exist ".venv" (
    echo Creating virtual environment...
    python -m venv .venv
    call .venv\Scripts\activate.bat
    python -m pip install --upgrade pip
    pip install -r requirements.txt
) else (
    call .venv\Scripts\activate.bat
)

python server.py
pause
