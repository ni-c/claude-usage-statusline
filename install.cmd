@echo off
rem claude-usage-statusline - https://github.com/ni-c/claude-usage-statusline
rem
rem Installs claude-usage-statusline as the Claude Code status line from cmd.exe,
rem without PowerShell. cmd.exe cannot pipe a download into an interpreter, so this
rem one is downloaded first and then run - which also means you can read it first:
rem
rem   curl -fsSL -o "%TEMP%\install.cmd" https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.cmd
rem   "%TEMP%\install.cmd"
rem   "%TEMP%\install.cmd" --force       replace a status line that is already configured
rem   "%TEMP%\install.cmd" --uninstall   remove it again
rem
rem What it does: downloads statusline.sh from the release this installer belongs to,
rem checks it against the SHA-256 baked in below, puts it in
rem <userprofile>\.claude\claude-usage-statusline\ and sets `statusLine` in
rem <userprofile>\.claude\settings.json. Every other setting is left as it is.
rem CLAUDE_CONFIG_DIR is respected.
rem
rem Claude Code runs the status line through Git Bash on Windows, so this installs the
rem bash implementation and needs Git for Windows and jq on the PATH, both to install
rem and every time the status line runs. install.ps1 needs neither.
rem
rem Two rules hold this file together. It is pure ASCII and CRLF, because cmd.exe reads
rem a batch file in the OEM code page and is unreliable on LF-only line endings. And
rem cmd never holds text that came from somewhere else: an & or a | in a directory name
rem or in settings.json is syntax here, not data, so jq reads and writes settings.json
rem file to file, jq renders every message that contains a path, and this file only ever
rem branches on exit codes and on tokens it chose itself.

setlocal EnableExtensions DisableDelayedExpansion

set "NAME=claude-usage-statusline"
set "REPO=ni-c/claude-usage-statusline"
rem How an installed status line is recognised as ours, on either OS.
set "MARKER=claude-usage-statusline/statusline."

rem Stamped by scripts/stamp-release.sh when a release is built. An installer taken
rem from a checkout has neither and installs only from CLAUDE_STATUSLINE_SOURCE.
rem No other line in this file may begin with either of the two assignments below:
rem the stamp is a one-line substitution and the build fails if it matches twice.
set "VERSION="
set "SHA256="

set "FORCE=0"
set "UNINSTALL=0"
set "WORK="

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--force" goto :arg_force
if /i "%~1"=="--uninstall" goto :arg_uninstall
if /i "%~1"=="-h" goto :arg_help
if /i "%~1"=="--help" goto :arg_help
if "%~1"=="/?" goto :arg_help
goto :arg_unknown

:arg_force
set "FORCE=1"
shift
goto :parse_args

:arg_uninstall
set "UNINSTALL=1"
shift
goto :parse_args

:arg_help
call :usage
exit /b 0

rem %1 keeps the quotes the user typed, so an & inside them stays inside them.
:arg_unknown
call :usage 1>&2
echo %NAME%: unknown option: %1 1>&2
exit /b 2

:args_done

set "CONFIG_DIR=%CLAUDE_CONFIG_DIR%"
if not defined CONFIG_DIR set "CONFIG_DIR=%USERPROFILE%\.claude"
rem Absolute, so the command written into settings.json never depends on a cwd.
for %%i in ("%CONFIG_DIR%") do set "CONFIG_DIR=%%~fi"
set "INSTALL_DIR=%CONFIG_DIR%\%NAME%"
set "TARGET=%INSTALL_DIR%\statusline.sh"
set "SETTINGS=%CONFIG_DIR%\settings.json"
set "BACKUP=%SETTINGS%.before-%NAME%"

rem Forward slashes and single quotes, the same form install.ps1 writes: Git Bash reads
rem a drive-letter path with forward slashes, and the quotes survive whichever shell
rem Claude Code hands the command to. A path that already contains a quote cannot be
rem written that way, so it is refused rather than guessed at - install.ps1 refuses it
rem too; only install.sh escapes it, because it has just the one shell to satisfy.
rem Checked here, before anything is created, so that a refusal changes nothing.
set "TARGET_FWD=%TARGET:\=/%"
set "TARGET_Q=%TARGET_FWD:'=%"
if not "%TARGET_Q%"=="%TARGET_FWD%" goto :err_quote
set "STATUS_CMD=bash '%TARGET_FWD%'"

rem jq first: uninstalling edits settings.json too.
jq --version >NUL 2>&1 || goto :err_jq

set "WORK=%TEMP%\%NAME%-%RANDOM%%RANDOM%"
md "%WORK%" 2>NUL
if not exist "%WORK%\" goto :err_work
set "SETTINGS_TMP=%SETTINGS%.tmp.%RANDOM%"

rem The settings file as JSON, or {} when there is none yet. Anything that is not a
rem JSON object is refused before anything has been touched.
if exist "%SETTINGS%" goto :read_settings
jq -n "{}" >"%WORK%\in.json" || goto :err_work
goto :read_done
:read_settings
jq -e objects "%SETTINGS%" >NUL 2>&1 || goto :err_not_object
copy /b /y "%SETTINGS%" "%WORK%\in.json" >NUL || goto :err_work
:read_done

rem Which status line is configured: none, ours, or somebody else's. The three answers
rem are words this file chose, so they are safe to hold; the configured command itself
rem is not, and never leaves jq. An entry without a .command is not ours either.
rem jq writes to a file and for /f reads the file: a command inside for /f's backquotes
rem would be parsed twice, and the | of the filter would not survive the first pass.
jq -r --arg m "%MARKER%" --arg a none --arg b ours --arg c foreign "if .statusLine == null then $a elif ((.statusLine|objects|.command|strings|contains($m)) // false) then $b else $c end" "%WORK%\in.json" >"%WORK%\state.txt" || goto :err_settings
set "STATE="
for /f "usebackq delims=" %%s in ("%WORK%\state.txt") do if not defined STATE set "STATE=%%s"
if not defined STATE goto :err_settings
rem Compared as a prefix: for /f can leave the CR of jq.exe's CRLF on the token.
set "STATE=%STATE:~0,4%"

if "%UNINSTALL%"=="1" goto :do_uninstall

if "%STATE%"=="fore" if not "%FORCE%"=="1" goto :err_foreign

rem Git Bash before the download: it is what runs the status line, and failing before
rem a network round trip is friendlier.
call :find_bash
if not defined GIT_BASH goto :err_bash

if defined CLAUDE_STATUSLINE_SOURCE goto :fetch_local
if not defined VERSION goto :err_no_release
if not exist "%SystemRoot%\System32\curl.exe" goto :err_curl
rem Absolute paths for curl and certutil: cmd searches the current directory first,
rem and an installer is typically run from Downloads.
"%SystemRoot%\System32\curl.exe" -fsSL --proto =https --tlsv1.2 -o "%WORK%\statusline.sh" "https://github.com/%REPO%/releases/download/v%VERSION%/statusline.sh" || goto :err_download
goto :fetch_done
:fetch_local
copy /b /y "%CLAUDE_STATUSLINE_SOURCE%\statusline.sh" "%WORK%\statusline.sh" >NUL || goto :err_source
:fetch_done

if not defined SHA256 goto :checksum_done
if not exist "%SystemRoot%\System32\certutil.exe" goto :err_certutil
"%SystemRoot%\System32\certutil.exe" -hashfile "%WORK%\statusline.sh" SHA256 >"%WORK%\hash.txt" 2>NUL
rem certutil's first and last line are localised and both contain a colon; the hash is
rem the only line that is nothing but hex and spaces. /c: is required, or findstr would
rem split the pattern at the space into two patterns and match the header as well.
findstr /r /c:"^[0-9a-fA-F ][0-9a-fA-F ]*$" "%WORK%\hash.txt" >"%WORK%\hex.txt"
set "SHA_ACTUAL="
for /f "usebackq delims=" %%h in ("%WORK%\hex.txt") do if not defined SHA_ACTUAL set "SHA_ACTUAL=%%h"
rem Spaces: the grouped format of older Windows versions. The truncation drops a CR
rem for /f may have left, and anything a future certutil might append.
set "SHA_ACTUAL=%SHA_ACTUAL: =%"
set "SHA_ACTUAL=%SHA_ACTUAL:~0,64%"
if "%SHA_ACTUAL:~63,1%"=="" goto :err_certutil
if /i not "%SHA_ACTUAL%"=="%SHA256%" goto :err_checksum
:checksum_done

if not exist "%INSTALL_DIR%\" md "%INSTALL_DIR%" 2>NUL
if not exist "%INSTALL_DIR%\" goto :err_mkdir
copy /b /y "%WORK%\statusline.sh" "%TARGET%" >NUL || goto :err_write

rem Keeps refreshInterval and padding from an earlier installation of ours; a foreign
rem entry is replaced whole. refreshInterval keeps the countdown moving while Claude
rem Code is idle. Every string literal comes in through --arg, so the filter contains
rem no quote for cmd to miscount - reordering a clause here must not change that.
rem Unlike install.sh's filter this one is total: a .statusLine that is a JSON string
rem yields false instead of a jq error, and is then replaced like any foreign entry.
if not exist "%CONFIG_DIR%\" md "%CONFIG_DIR%" 2>NUL
if not exist "%CONFIG_DIR%\" goto :err_mkdir_config
jq --arg cmd "%STATUS_CMD%" --arg m "%MARKER%" --arg t command "(if ((.statusLine|objects|.command|strings|contains($m)) // false) then .statusLine else {} end) as $old | .statusLine = ($old + {type: $t, command: $cmd}) | .statusLine.refreshInterval //= 30" "%WORK%\in.json" >"%SETTINGS_TMP%"
rem A filter that yielded an empty stream would leave a zero-byte settings.json.
jq -e objects "%SETTINGS_TMP%" >NUL 2>&1 || goto :err_settings
call :write_settings || goto :err_write_settings

rem Proves the installed line runs here, with this Git Bash and this jq, before
rem claiming success. The output is never captured into a variable: a broken status
rem line prints whatever it likes, quotes included, and cmd would re-parse it.
call :probe
if errorlevel 1 goto :err_probe

set "VSUFFIX="
if defined VERSION set "VSUFFIX= %VERSION%"
set "MSG_A=Installed %NAME%%VSUFFIX% to "
set "MSG_B=%TARGET%"
call :say
echo Claude Code picks up the new status line within a few seconds; restart it if not.
goto :done

:do_uninstall
if "%STATE%"=="none" goto :uninstall_files
if "%STATE%"=="fore" goto :uninstall_foreign
jq "del(.statusLine)" "%WORK%\in.json" >"%SETTINGS_TMP%" || goto :err_settings
jq -e objects "%SETTINGS_TMP%" >NUL 2>&1 || goto :err_settings
call :write_settings || goto :err_write_settings
set "MSG_A=Removed the statusLine entry from "
set "MSG_B=%SETTINGS%"
call :say
goto :uninstall_files
:uninstall_foreign
jq -r --arg a "Left the statusLine entry alone, it belongs to something else: " "$a + ((.statusLine|objects|.command|strings) // (.statusLine|tojson))" "%WORK%\in.json"
:uninstall_files
if not exist "%INSTALL_DIR%\" goto :done
rd /s /q "%INSTALL_DIR%" 2>NUL
set "MSG_A=Removed "
set "MSG_B=%INSTALL_DIR%"
call :say
goto :done

rem Batch has no trap, so the scratch directory and a half-written settings file are
rem cleaned up here. A run killed with Ctrl-C leaves the scratch directory in %TEMP%.
:done
call :cleanup
exit /b 0

:die
call :cleanup
exit /b 1

rem ---------------------------------------------------------------- subroutines

:cleanup
if defined WORK rd /s /q "%WORK%" 2>NUL
if defined SETTINGS_TMP if exist "%SETTINGS_TMP%" del "%SETTINGS_TMP%" 2>NUL
exit /b 0

:usage
echo Usage: install.cmd [--force] [--uninstall]
echo.
echo   --force       replace a status line that another tool configured
echo   --uninstall   remove claude-usage-statusline and its settings entry
exit /b 0

rem One line built from MSG_A and MSG_B, rendered by jq so that a path containing an
rem & or a | is never re-parsed by cmd. MSG_B is a path or a hex digest; neither can
rem contain a double quote, which is the only character that would break the call.
:say
jq -rn --arg a "%MSG_A%" --arg b "%MSG_B%" "$a+$b"
exit /b 0

:say_err
jq -rn --arg a "%MSG_A%" --arg b "%MSG_B%" "$a+$b" 1>&2
exit /b 0

rem Git for Windows puts only <Git>\cmd on the PATH, which holds git.exe but not
rem bash.exe - and a bare `bash` on the PATH is usually C:\Windows\System32\bash.exe,
rem the WSL launcher, which would run the script in a place where C:/... is not a
rem path. So Git Bash is located explicitly. What goes into settings.json stays the
rem bare `bash`, because Claude Code runs the command through Git Bash itself; the
rem resolved path is only for the dependency check and for the probe below.
:find_bash
set "GIT_BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "GIT_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined GIT_BASH if exist "%ProgramW6432%\Git\bin\bash.exe" set "GIT_BASH=%ProgramW6432%\Git\bin\bash.exe"
if not defined GIT_BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "GIT_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined GIT_BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "GIT_BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
rem Again a file rather than for /f's backquotes, so nothing has to survive being
rem parsed twice. The registry value and the path of git.exe only ever land inside
rem quotes, so an & in either of them stays data.
if defined GIT_BASH exit /b 0
reg query HKLM\SOFTWARE\GitForWindows /v InstallPath >"%WORK%\reg.txt" 2>NUL
for /f "usebackq tokens=2,*" %%a in ("%WORK%\reg.txt") do if not defined GIT_BASH if exist "%%~b\bin\bash.exe" set "GIT_BASH=%%~b\bin\bash.exe"
if defined GIT_BASH exit /b 0
reg query HKCU\SOFTWARE\GitForWindows /v InstallPath >"%WORK%\reg.txt" 2>NUL
for /f "usebackq tokens=2,*" %%a in ("%WORK%\reg.txt") do if not defined GIT_BASH if exist "%%~b\bin\bash.exe" set "GIT_BASH=%%~b\bin\bash.exe"
if defined GIT_BASH exit /b 0
where git >"%WORK%\git.txt" 2>NUL
for /f "usebackq delims=" %%g in ("%WORK%\git.txt") do if not defined GIT_BASH if exist "%%~dpg..\bin\bash.exe" set "GIT_BASH=%%~dpg..\bin\bash.exe"
exit /b 0

rem Replaces settings.json with SETTINGS_TMP, which sits next to it so that the move is
rem a rename on the same volume and an interrupted run never leaves half a file. A copy
rem of the previous version is kept next to it. An unchanged file is not rewritten, and
rem then no backup is announced either. A symlinked settings.json is replaced, not
rem written through - the same as install.ps1; a file symlink on Windows needs
rem Developer Mode or elevation, so dotfile managers rarely produce one here.
:write_settings
if not exist "%SETTINGS%" goto :ws_move
fc /b "%SETTINGS_TMP%" "%SETTINGS%" >NUL 2>&1
if not errorlevel 1 goto :ws_unchanged
copy /b /y "%SETTINGS%" "%BACKUP%" >NUL || exit /b 1
set "MSG_A=Previous settings saved as "
set "MSG_B=%BACKUP%"
call :say
:ws_move
move /y "%SETTINGS_TMP%" "%SETTINGS%" >NUL || exit /b 1
exit /b 0
:ws_unchanged
del "%SETTINGS_TMP%" 2>NUL
exit /b 0

rem setlocal is cmd's env -u: NO_COLOR and the missing CLAUDE_STATUSLINE_SEGMENTS reach
rem the child only. The two findstr calls together are `test "$probe" = "[ok]"`: the
rem first requires a line that is exactly [ok], the second that no line differs from it.
rem One pipeline would only prove that [ok] appeared somewhere.
:probe
setlocal
set "NO_COLOR=1"
set "CLAUDE_STATUSLINE_SEGMENTS="
jq -nc --arg n ok "{model:{display_name:$n}}" | "%GIT_BASH%" "%TARGET_FWD%" >"%WORK%\probe.txt" 2>&1
findstr /x /c:"[ok]" "%WORK%\probe.txt" >NUL || exit /b 1
findstr /v /x /c:"[ok]" "%WORK%\probe.txt" >NUL && exit /b 1
exit /b 0

rem ---------------------------------------------------------------- failures

:err_jq
echo %NAME%: jq is required, both here and by the status line itself. 1>&2
echo   winget install jqlang.jq    choco install jq    scoop install jq 1>&2
echo   https://jqlang.org/download/ 1>&2
echo   Or use install.ps1 instead, it needs nothing. 1>&2
goto :die

:err_bash
echo %NAME%: Git for Windows is required: Claude Code runs this status line through 1>&2
echo   Git Bash, and jq has to be on its PATH as well. https://git-scm.com/download/win 1>&2
echo   Or use install.ps1 instead, it needs nothing. 1>&2
goto :die

:err_curl
echo %NAME%: curl.exe is required to download statusline.sh. Windows 10 1803 and 1>&2
echo   newer ship it; on an older Windows, use install.ps1 instead. 1>&2
goto :die

:err_work
echo %NAME%: could not use the temporary directory in %%TEMP%%. Nothing was changed. 1>&2
goto :die

:err_not_object
jq -rn --arg a "%NAME%: " --arg s "%SETTINGS%" --arg b " is not a JSON object. Fix it first; nothing was changed." "$a+$s+$b" 1>&2
goto :die

:err_settings
echo %NAME%: could not read or rewrite the settings as JSON. Nothing was changed. 1>&2
goto :die

rem The configured command is somebody else's text, so jq prints it. An entry without
rem a .command is shown as the JSON of the whole entry, the same as install.sh does.
:err_foreign
jq -r --arg s "%SETTINGS%" --arg a "%NAME%: another status line is configured in " --arg b ":" --arg i "  " --arg c "Re-run with --force to replace it (the old entry is kept in " --arg d ".before-claude-usage-statusline)." "($a+$s+$b), ($i + ((.statusLine|objects|.command|strings) // (.statusLine|tojson))), ($c+$s+$d)" "%WORK%\in.json" 1>&2
goto :die

:err_no_release
echo %NAME%: this installer does not belong to a release. Use the one-liner from the 1>&2
echo   README, or set CLAUDE_STATUSLINE_SOURCE to a checkout to install from there. 1>&2
goto :die

:err_download
set "MSG_A=%NAME%: download failed: "
set "MSG_B=https://github.com/%REPO%/releases/download/v%VERSION%/statusline.sh"
call :say_err
goto :die

:err_source
set "MSG_A=%NAME%: no statusline.sh in "
set "MSG_B=%CLAUDE_STATUSLINE_SOURCE%"
call :say_err
goto :die

:err_certutil
echo %NAME%: could not compute the SHA-256 of the download (certutil printed nothing 1>&2
echo   this installer recognises). Nothing was changed. 1>&2
goto :die

:err_checksum
set "MSG_A=%NAME%: checksum mismatch for statusline.sh: expected %SHA256%, got "
set "MSG_B=%SHA_ACTUAL%. Nothing was changed."
call :say_err
goto :die

:err_mkdir
set "MSG_A=%NAME%: could not create "
set "MSG_B=%INSTALL_DIR%"
call :say_err
goto :die

:err_mkdir_config
set "MSG_A=%NAME%: could not create "
set "MSG_B=%CONFIG_DIR%"
call :say_err
goto :die

:err_write
set "MSG_A=%NAME%: could not write "
set "MSG_B=%TARGET%"
call :say_err
goto :die

:err_write_settings
set "MSG_A=%NAME%: could not write "
set "MSG_B=%SETTINGS%"
call :say_err
goto :die

:err_quote
set "MSG_A=%NAME%: cannot put this path into a command Git Bash parses the same way: "
set "MSG_B=%TARGET%"
call :say_err
goto :die

:err_probe
echo %NAME%: installed, but a test run printed: 1>&2
type "%WORK%\probe.txt" 1>&2
goto :die
