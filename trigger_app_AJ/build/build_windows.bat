@echo off
REM Build the headless Windows trigger receiver as a single-file .exe.
REM Console (not windowed) so the operator can see log output and the
REM auth token. PyInstaller cannot cross-compile - run on Windows.
REM
REM Run from the trigger_app_AJ/build directory:  build_windows.bat

setlocal
REM Build from trigger_app_AJ/ so the trigger_app_AJ package is importable.
cd /d "%~dp0"
cd ..

where pyinstaller >nul 2>nul
if errorlevel 1 (
    echo pyinstaller not found. Install with: pip install pyinstaller pyautogui
    exit /b 1
)

echo ==^> Cleaning previous build artifacts
if exist dist rmdir /s /q dist
if exist build_intermediate rmdir /s /q build_intermediate
if exist "TMS Trigger Receiver.spec" del "TMS Trigger Receiver.spec"

echo ==^> Building single-file .exe with PyInstaller
REM --paths .. lets PyInstaller resolve `from trigger_app_AJ.* import ...` references.
pyinstaller ^
    --onefile ^
    --console ^
    --noconfirm ^
    --clean ^
    --name "TMS Trigger Receiver" ^
    --icon "build\TMS_PC_icon.ico" ^
    --paths .. ^
    --workpath build_intermediate ^
    --distpath dist ^
    windows\main.py

if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

echo.
echo Done.
echo   EXE: dist\TMS Trigger Receiver.exe
endlocal
