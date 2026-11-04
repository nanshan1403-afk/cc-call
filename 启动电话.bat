@echo off
chcp 65001 >nul
rem 外网（4G）要能接，还得另起 cloudflared 隧道（5.5 配的，C:\Users\Administrator\.cloudflared\config.yml）。家里 WiFi 不用。
cd /d D:\克\app\call
python callserver.py
pause
