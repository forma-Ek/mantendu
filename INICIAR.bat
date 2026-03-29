@echo off
title WinAdmin Tool - Iniciando...

echo.
echo  WinAdmin Tool arrancando...
echo  Presiona una tecla para continuar...
pause >nul

set "SCRIPT_DIR=%~dp0"
set "PORT=8080"
set "LOGFILE=%SCRIPT_DIR%winadmin_debug.log"
set "WORKDIR=C:\WinAdminTool"

echo [%date% %time%] === INICIO === > "%LOGFILE%"
echo [%date% %time%] DIR origen: %SCRIPT_DIR% >> "%LOGFILE%"

echo.
echo  =================================================
echo       W I N A D M I N   T O O L  v1.0
echo  =================================================
echo.

:: Verificar ficheros
if not exist "%SCRIPT_DIR%server.ps1" (
    echo  [ERROR] No se encuentra server.ps1
    echo [%date% %time%] ERROR: server.ps1 no encontrado >> "%LOGFILE%"
    pause & exit /b 1
)
echo  [OK] Ficheros encontrados.

:: Crear carpeta de trabajo en C:\
echo  [..] Copiando ficheros a %WORKDIR%...
if not exist "%WORKDIR%" mkdir "%WORKDIR%"
copy /Y "%SCRIPT_DIR%server.ps1" "%WORKDIR%\server.ps1" >nul 2>&1
copy /Y "%SCRIPT_DIR%index.html" "%WORKDIR%\index.html" >nul 2>&1

if not exist "%WORKDIR%\server.ps1" (
    echo  [ERROR] Copia fallida. Ejecuta como Administrador.
    echo [%date% %time%] ERROR: copia fallida >> "%LOGFILE%"
    pause & exit /b 1
)
echo  [OK] Ficheros en %WORKDIR%
echo [%date% %time%] OK: ficheros copiados >> "%LOGFILE%"

:: Desbloquear Zone Identifier
powershell -Command "Unblock-File -Path '%WORKDIR%\server.ps1' -ErrorAction SilentlyContinue" >nul 2>&1
powershell -Command "Unblock-File -Path '%WORKDIR%\index.html' -ErrorAction SilentlyContinue" >nul 2>&1
echo  [OK] Ficheros desbloqueados.
echo [%date% %time%] OK: Unblock-File ejecutado >> "%LOGFILE%"

:: Verificar si servidor ya activo
powershell -ExecutionPolicy Bypass -Command "try{(New-Object Net.WebClient).DownloadString('http://localhost:%PORT%/api/health')|Out-Null;exit 0}catch{exit 1}" >nul 2>&1
if %errorlevel% equ 0 (
    echo  [INFO] Servidor ya activo.
    goto :open_browser
)

:: Lanzar servidor DIRECTAMENTE desde bat (sin PowerShell intermedio)
:: La ventana del servidor sera VISIBLE para poder ver errores
echo  [1/3] Lanzando servidor PowerShell...
echo  NOTA: Se abrira una segunda ventana (el servidor).
echo        Si ves un error en esa ventana, fotografiala y comunicalamela.
echo.
echo [%date% %time%] Lanzando powershell directo... >> "%LOGFILE%"

start "WinAdmin-Servidor" cmd /k "powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\WinAdminTool\server.ps1 -Port %PORT% 2>&1"

echo  [OK] Ventana servidor abierta.
echo [%date% %time%] OK: powershell lanzado >> "%LOGFILE%"

:: Esperar respuesta (max 30s)
echo  [2/3] Esperando servidor (max 30 seg)...
set /a TRIES=0
:wait_loop
    set /a TRIES+=1
    if %TRIES% gtr 30 (
        echo.
        echo  [ERROR] Servidor no respondio en 30s.
        echo  Revisa la segunda ventana de PowerShell que se abrio
        echo  y fotografiala para diagnosticar el problema.
        echo [%date% %time%] ERROR: timeout >> "%LOGFILE%"
        pause & exit /b 1
    )
    echo  Intento %TRIES% de 30...
    timeout /t 1 /nobreak >nul
    powershell -ExecutionPolicy Bypass -Command "try{(New-Object Net.WebClient).DownloadString('http://localhost:%PORT%/api/health')|Out-Null;exit 0}catch{exit 1}" >nul 2>&1
    if %errorlevel% neq 0 goto :wait_loop

echo  [OK] Servidor activo en http://localhost:%PORT%
echo [%date% %time%] OK: servidor OK >> "%LOGFILE%"

:: Abrir navegador
:open_browser
echo  [3/3] Abriendo navegador...

set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if exist "%EDGE%" (
    start "" "%EDGE%" --new-window --proxy-bypass-list="<local>;localhost;127.0.0.1" "http://localhost:%PORT%/"
    goto :started
)

set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME%" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if exist "%CHROME%" (
    start "" "%CHROME%" --new-window --proxy-bypass-list="<local>;localhost;127.0.0.1" "http://localhost:%PORT%/"
    goto :started
)

start "" "http://localhost:%PORT%/"

:started
echo.
echo  =================================================
echo  Servidor ACTIVO en http://localhost:%PORT%
echo.
echo  Hay DOS ventanas abiertas:
echo   1. Esta (INICIAR) - mantener abierta
echo   2. WinAdmin-Servidor - mantener abierta
echo.
echo  Presiona una tecla aqui para DETENER todo.
echo  =================================================
echo.
pause >nul

:: Detener
echo  Deteniendo servidor...
powershell -ExecutionPolicy Bypass -Command "try{(New-Object Net.WebClient).DownloadString('http://localhost:%PORT%/api/stop')}catch{}" >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq WinAdmin-Servidor" >nul 2>&1
echo  Detenido. Hasta pronto.
echo [%date% %time%] === FIN === >> "%LOGFILE%"
timeout /t 2 /nobreak >nul
