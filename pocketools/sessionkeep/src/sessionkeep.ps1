[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Action = "help",

    [Parameter(DontShow = $true)]
    [string] $Token,

    [Alias("help", "h")]
    [switch] $ShowHelp
)

$ErrorActionPreference = "Stop"
$script:DataRoot = if ($env:EAP_POCKETOOL_DATA) {
    [IO.Path]::GetFullPath($env:EAP_POCKETOOL_DATA)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\data"))
}
$script:StatePath = Join-Path $script:DataRoot "session.json"
$script:StopPath = Join-Path $script:DataRoot "stop-request.json"
$script:StartLockPath = Join-Path $script:DataRoot "start.lock"
$script:WorkerLockPath = Join-Path $script:DataRoot "worker.lock"
$script:HeartbeatSeconds = 10
$script:ActivitySeconds = 240
$script:TestMode = $env:EAP_SESSIONKEEP_TEST_MODE -eq "1"

if ($ShowHelp) {
    $Action = "help"
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [object] $Value
    )
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        $temporary,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-SessionState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if (-not $state.pid -or -not $state.token) {
            return $null
        }
        return $state
    } catch {
        return $null
    }
}

function Get-LiveSession {
    $state = Read-SessionState
    if ($null -eq $state) {
        return $null
    }
    try {
        $process = Get-Process -Id ([int] $state.pid) -ErrorAction Stop
        if ($process.ProcessName -notmatch "^(powershell|pwsh)$") {
            return $null
        }
        return $state
    } catch {
        return $null
    }
}

function Remove-StaleState {
    if ($null -eq (Get-LiveSession)) {
        Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
    }
}

function Show-SessionKeepHelp {
    @"
Session Keep 1.0.1

Mantiene activa la sesión de Windows mediante una instancia oculta y única.

Uso:
  sessionkeep start    Inicia el worker en segundo plano
  sessionkeep stop     Detiene el worker de forma ordenada
  sessionkeep status   Muestra su estado, PID y hora de inicio
  sessionkeep run      Ejecuta el worker en primer plano (diagnóstico)
  sessionkeep --help   Muestra esta ayuda
"@ | Write-Output
}

function Start-SessionKeep {
    [IO.Directory]::CreateDirectory($script:DataRoot) | Out-Null
    $lock = $null
    try {
        try {
            $lock = [IO.File]::Open(
                $script:StartLockPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            throw "Hay otro inicio de Session Keep en curso."
        }
        $active = Get-LiveSession
        if ($null -ne $active) {
            Write-Output "Session Keep ya está activo (PID $($active.pid))."
            return
        }
        Remove-StaleState
        $workerToken = [Guid]::NewGuid().ToString("N")
        $escapedScript = $PSCommandPath.Replace("'", "''")
        $workerCommand = "& '$escapedScript' run -Token '$workerToken'"
        $encodedCommand = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($workerCommand)
        )
        $startParameters = @{
            FilePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            ArgumentList = @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-EncodedCommand", $encodedCommand
            )
            WindowStyle = "Hidden"
            PassThru = $true
        }
        $process = Start-Process @startParameters
        Write-JsonAtomic -Path $script:StatePath -Value ([ordered]@{
            schemaVersion = 1
            pid = $process.Id
            token = $workerToken
            startedAt = [DateTimeOffset]::Now.ToString("o")
            heartbeatAt = [DateTimeOffset]::Now.ToString("o")
        })
        Start-Sleep -Milliseconds 500
        if ($null -eq (Get-LiveSession)) {
            throw "El worker de Session Keep terminó durante el arranque."
        }
        Write-Output "Session Keep iniciado (PID $($process.Id))."
    } finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
        Remove-Item -LiteralPath $script:StartLockPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-SessionKeep {
    $active = Get-LiveSession
    if ($null -eq $active) {
        Remove-StaleState
        Write-Output "Session Keep no está activo."
        return
    }
    Write-JsonAtomic -Path $script:StopPath -Value ([ordered]@{
        schemaVersion = 1
        token = [string] $active.token
        requestedAt = [DateTimeOffset]::Now.ToString("o")
    })
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        if ($null -eq (Get-LiveSession)) {
            Remove-StaleState
            Write-Output "Session Keep detenido."
            return
        }
    }
    throw "Session Keep no respondió a la solicitud de parada en 10 segundos."
}

function Show-SessionKeepStatus {
    $active = Get-LiveSession
    if ($null -eq $active) {
        Remove-StaleState
        Write-Host "Session Keep: inactivo"
        return $false
    }
    Write-Host "Session Keep: activo"
    Write-Host "PID: $($active.pid)"
    Write-Host "Inicio: $($active.startedAt)"
    Write-Host "Heartbeat: $($active.heartbeatAt)"
    return $true
}

function Test-StopRequested {
    if (-not (Test-Path -LiteralPath $script:StopPath -PathType Leaf)) {
        return $false
    }
    try {
        $request = Get-Content -LiteralPath $script:StopPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        return [string] $request.token -eq $script:WorkerToken
    } catch {
        return $false
    }
}

function Invoke-SessionActivity {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $position = [Windows.Forms.Cursor]::Position
        [Windows.Forms.Cursor]::Position = [Drawing.Point]::new(
            $position.X + 1,
            $position.Y
        )
        Start-Sleep -Milliseconds 200
        [Windows.Forms.Cursor]::Position = $position
        [Windows.Forms.SendKeys]::SendWait("+")
    } catch {
        # SetThreadExecutionState sigue manteniendo la sesión aunque la sesión
        # de escritorio no permita simular entrada (por ejemplo, RDP cerrado).
    }
}

function Run-SessionKeep {
    [IO.Directory]::CreateDirectory($script:DataRoot) | Out-Null
    if ($null -eq (Get-LiveSession)) {
        Remove-Item -LiteralPath $script:WorkerLockPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $Token) {
        $Token = [Guid]::NewGuid().ToString("N")
    }
    $script:WorkerToken = $Token
    $workerLock = $null
    try {
        try {
            $workerLock = [IO.File]::Open(
                $script:WorkerLockPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            throw "Ya existe un worker de Session Keep."
        }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SessionKeepNative {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
}
"@
    $continuous = [Convert]::ToUInt32("80000000", 16)
    $systemRequired = [uint32] 0x00000001
    $displayRequired = [uint32] 0x00000002
    $startedAt = [DateTimeOffset]::Now.ToString("o")
    $nextHeartbeat = [DateTimeOffset]::MinValue
    $nextActivity = [DateTimeOffset]::MinValue
    try {
        [SessionKeepNative]::SetThreadExecutionState(
            $continuous -bor $systemRequired -bor $displayRequired
        ) | Out-Null
        while (-not (Test-StopRequested)) {
            $now = [DateTimeOffset]::Now
            if ($now -ge $nextHeartbeat) {
                Write-JsonAtomic -Path $script:StatePath -Value ([ordered]@{
                    schemaVersion = 1
                    pid = $PID
                    token = $Token
                    startedAt = $startedAt
                    heartbeatAt = $now.ToString("o")
                })
                $nextHeartbeat = $now.AddSeconds($script:HeartbeatSeconds)
            }
            if ($now -ge $nextActivity) {
                if (-not $script:TestMode) {
                    Invoke-SessionActivity
                }
                $nextActivity = $now.AddSeconds($script:ActivitySeconds)
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        [SessionKeepNative]::SetThreadExecutionState($continuous) | Out-Null
        $state = Read-SessionState
        if ($null -ne $state -and [string] $state.token -eq $Token) {
            Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
    }
    } finally {
        if ($null -ne $workerLock) {
            $workerLock.Dispose()
        }
        Remove-Item -LiteralPath $script:WorkerLockPath -Force -ErrorAction SilentlyContinue
    }
}

try {
    switch ($Action.ToLowerInvariant()) {
        "start" { Start-SessionKeep; exit 0 }
        "stop" { Stop-SessionKeep; exit 0 }
        "status" {
            if (Show-SessionKeepStatus) { exit 0 }
            exit 1
        }
        "run" { Run-SessionKeep; exit 0 }
        "help" { Show-SessionKeepHelp; exit 0 }
        "--help" { Show-SessionKeepHelp; exit 0 }
        "-h" { Show-SessionKeepHelp; exit 0 }
        default {
            Write-Error "Acción no válida: $Action"
            Show-SessionKeepHelp
            exit 2
        }
    }
} catch {
    Write-Error "Session Keep: $($_.Exception.Message)"
    exit 2
}
