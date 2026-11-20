@echo off
rem desinstalador.cmd - desinstalador falso dos testes Pester (so e copiado para %%TEMP%%\NexTuneTeste\prog).
rem Grava os argumentos recebidos em marcador.txt ao lado deste arquivo, apaga a chave recebida em %%1
rem (somente se comecar com HKCU\Software\NexTuneTeste) e sai com o codigo %%2 (ou 0 se nao vier).
>"%~dp0marcador.txt" echo %*
set "CHAVE=%~1"
if /i "%CHAVE:~0,26%"=="HKCU\Software\NexTuneTeste" reg delete "%CHAVE%" /f >nul 2>&1
if "%~2"=="" exit 0
exit %~2
