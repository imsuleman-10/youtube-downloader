@echo off
echo ========================================
echo    SamTube Backend Starting...
echo ========================================
echo.
cd /d "%~dp0backend"
echo Backend URL: http://192.168.100.10:8000
echo.
echo Phone aur Laptop ek hi WiFi par hone chahiye!
echo Is window ko band mat karein jab tak app use kar rahe hain.
echo.
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
pause
