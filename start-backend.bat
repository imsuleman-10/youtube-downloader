@echo off
echo Starting SAM-DL Backend...
cd /d %~dp0backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
