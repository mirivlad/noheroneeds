@echo off
setlocal
set "NHN_EXE=%~dp0noheroneeds.exe"
if not "%~1"=="" set "NHN_EXE=%~f1"
if not exist "%NHN_EXE%" set "NHN_EXE=%ProgramW6432%\No Hero Needed\noheroneeds.exe"
if not exist "%NHN_EXE%" set "NHN_EXE=%ProgramFiles%\No Hero Needed\noheroneeds.exe"
if not exist "%NHN_EXE%" (
    echo Game not found. Drop noheroneeds.exe onto this file or place it beside the game.
    pause
    exit /b 1
)
set "NHN_LOG=%TEMP%\noheroneeds-client-%RANDOM%.log"
ver > "%NHN_LOG%.system.txt"
certutil -hashfile "%NHN_EXE%" SHA256 > "%NHN_LOG%.sha256.txt" 2>&1
echo Connect to the same server and reproduce the missing graphics, then close the game.
echo Log: %NHN_LOG%
start "" /wait "%NHN_EXE%" --verbose --log-file "%NHN_LOG%"
echo Log: %NHN_LOG%
if exist "%NHN_LOG%" explorer /select,"%NHN_LOG%"
pause
