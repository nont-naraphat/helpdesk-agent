@echo off
REM push.bat - commit and push helper (Windows CMD)
REM Usage: push.bat "commit message"

setlocal
set MSG=%~1
if "%MSG%"=="" set MSG=update

git add -A
git commit -m "%MSG%"
git push origin main

echo.
echo Done. Pushed to origin/main.
endlocal
