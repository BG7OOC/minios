@echo off
rem ============================================================
rem  MiniOS one-click build & run script (ASCII only, safe under
rem  any cmd codepage).
rem ============================================================
setlocal

rem ---- tool paths (edit if needed) ----
set "NASM=%USERPROFILE%‌\AppData\Local\Temp\opencode\toolchain\nasm-2.16.03\nasm.exe"
set "QEMU=%USERPROFILE%‌\qemu\qemu-system-i386.exe"

rem ---- directories ----
set "SRC=%~dp0src"
set "BLD=%~dp0build"

set "FAILED="

if not exist "%NASM%" (
  echo [ERROR] nasm not found: "%NASM%"
  set "FAILED=1"
)
if not exist "%QEMU%" (
  echo [ERROR] qemu-system-i386 not found: "%QEMU%"
  set "FAILED=1"
)
if defined FAILED goto fail

echo [1/3] assembling boot.asm
"%NASM%" -f bin "%SRC%\boot.asm" -o "%BLD%\boot.bin"
if errorlevel 1 goto fail

echo [2/3] assembling kernel.asm
"%NASM%" -f bin "%SRC%\kernel.asm" -o "%BLD%\kernel.bin"
if errorlevel 1 goto fail

echo [3/3] packing minios.img
copy /b "%BLD%\boot.bin" + "%BLD%\kernel.bin" "%BLD%\minios.img" >nul
if errorlevel 1 goto fail

echo.
echo Build OK: "%BLD%\minios.img"
echo Launching QEMU ...
"%QEMU%" -drive format=raw,file="%BLD%\minios.img" -name "MiniOS"
echo.
echo QEMU exited.
goto end

:fail
echo.
echo BUILD FAILED - see messages above.
pause
exit /b 1

:end
endlocal