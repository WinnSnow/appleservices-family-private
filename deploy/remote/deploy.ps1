<#
.SYNOPSIS
  Deploys the appleservices stack (self-hosted anisette + Go tools) to a Linux host.

.DESCRIPTION
  Non-interactive password SSH via SSH_ASKPASS_REQUIRE=force (OpenSSH 8.4+).
  Uploads this repository as a tarball, then runs deploy/remote/setup.sh.

.EXAMPLE
  .\deploy.ps1 -Server 203.0.113.10 -User root -Password secret

.EXAMPLE
  .\deploy.ps1 -Server 203.0.113.10 -User root -PasswordFile .\pw.txt -AnisettePort 6969
#>
[CmdletBinding(DefaultParameterSetName = "Plain")]
param(
  [Parameter(Mandatory = $true)][string]$Server,
  [string]$User = "root",
  [Parameter(Mandatory = $true, ParameterSetName = "Plain")][string]$Password,
  [Parameter(Mandatory = $true, ParameterSetName = "File")][string]$PasswordFile,
  [int]$SshPort = 22,
  [int]$AnisettePort = 6969,
  [ValidateSet("all","docker","app","verify")][string]$Mode = "all",
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [switch]$KeepArchive
)

$ErrorActionPreference = "Stop"
$script:Askpass = $null
$script:PwFile = $null
$script:Archive = $null
$CRLF = [string]([char]13) + [string]([char]10)

function Get-SecretPassword {
  if ($PSCmdlet.ParameterSetName -eq "File") {
    $p = (Resolve-Path $PasswordFile).Path
    return (Get-Content -Raw -LiteralPath $p).TrimEnd()
  }
  return $Password
}

function Initialize-Askpass {
  param([string]$Secret)
  $dir = Join-Path $env:TEMP ("appsvc-askpass-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $script:PwFile = Join-Path $dir "pw.txt"
  [System.IO.File]::WriteAllText($script:PwFile, $Secret, (New-Object System.Text.UTF8Encoding($false)))
  $script:Askpass = Join-Path $dir "askpass.cmd"
  $line1 = "@echo off"
  $line2 = "powershell -NoProfile -ExecutionPolicy Bypass -Command " + [char]34 + "[Console]::Out.Write((Get-Content -Raw -LiteralPath " + [char]39 + $script:PwFile + [char]39 + "))" + [char]34
  [System.IO.File]::WriteAllText($script:Askpass, ($line1 + $CRLF + $line2 + $CRLF), (New-Object System.Text.ASCIIEncoding))
  $env:SSH_ASKPASS = $script:Askpass
  $env:SSH_ASKPASS_REQUIRE = "force"
  if (-not $env:DISPLAY) { $env:DISPLAY = ":0" }
}

function Remove-Askpass {
  foreach ($p in @($script:PwFile, $script:Askpass)) {
    if ($p -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
  }
  if ($script:Askpass) {
    $d = Split-Path -Parent $script:Askpass
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue
  Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
}

function New-SshCommon {
  return @(
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "PreferredAuthentications=password,keyboard-interactive",
    "-o", "PubkeyAuthentication=no",
    "-o", "NumberOfPasswordPrompts=1",
    "-o", "ConnectTimeout=15",
    "-o", "LogLevel=ERROR"
  )
}

function Invoke-Remote {
  param([string]$Command)
  $sshArgs = New-SshCommon
  $sshArgs += @("-p", "$SshPort", ("{0}@{1}" -f $User, $Server), $Command)
  & ssh @sshArgs
  if ($LASTEXITCODE -ne 0) { throw "ssh failed with exit $LASTEXITCODE" }
}

function Send-File {
  param([string]$Local, [string]$Remote)
  $scpArgs = New-SshCommon
  $scpArgs += @("-P", "$SshPort", $Local, ("{0}@{1}:{2}" -f $User, $Server, $Remote))
  & scp @scpArgs
  if ($LASTEXITCODE -ne 0) { throw "scp failed with exit $LASTEXITCODE" }
}

$Secret = Get-SecretPassword
if (-not $Secret) { throw "password is empty" }

try {
  Initialize-Askpass -Secret $Secret

  Write-Host "[1/5] probing TCP $Server port $SshPort" -ForegroundColor Cyan
  $probe = Test-NetConnection -ComputerName $Server -Port $SshPort -WarningAction SilentlyContinue
  if (-not $probe.TcpTestSucceeded) { throw "cannot reach $Server on port $SshPort" }

  Write-Host "[2/5] verifying ssh login" -ForegroundColor Cyan
  Invoke-Remote -Command "id -un; uname -s; uname -m; command -v sudo || true"

  Write-Host "[3/5] packaging repository" -ForegroundColor Cyan
  $script:Archive = Join-Path $env:TEMP ("appsvc-" + [guid]::NewGuid().ToString("N") + ".tar.gz")
  & tar -czf $script:Archive -C $RepoRoot --exclude=.git --exclude=state --exclude=bin --exclude=data .
  if ($LASTEXITCODE -ne 0) { throw "tar packaging failed" }
  $sizeMb = [math]::Round((Get-Item $script:Archive).Length / 1MB, 2)
  Write-Host "      archive size: $sizeMb MB"

  Write-Host "[4/5] uploading archive" -ForegroundColor Cyan
  Invoke-Remote -Command "mkdir -p /opt/appsvc/src /tmp/appsvc-upload"
  Send-File -Local $script:Archive -Remote "/tmp/appsvc-upload/app.tar.gz"

  Write-Host "[5/5] running setup with mode=$Mode" -ForegroundColor Cyan
  $remoteScript = "set -e" + $CRLF +
    "cd /tmp/appsvc-upload" + $CRLF +
    "tar -xzf app.tar.gz -C /opt/appsvc/src" + $CRLF +
    "chmod +x /opt/appsvc/src/deploy/remote/setup.sh" + $CRLF +
    "cd /opt/appsvc/src" + $CRLF +
    ("ANISETTE_PORT={0} bash deploy/remote/setup.sh {1}" -f $AnisettePort, $Mode)
  Invoke-Remote -Command $remoteScript

  Write-Host ""
  Write-Host "Done." -ForegroundColor Green
  Write-Host "  anisette endpoint : http://127.0.0.1:$AnisettePort (loopback only)"
  Write-Host "  binaries          : /opt/appsvc/bin"
  Write-Host "  state (0700)      : /opt/appsvc/state"
  Write-Host ""
  Write-Host "Next, on the server:"
  Write-Host "  /opt/appsvc/bin/login -dir /opt/appsvc/state/A -twofactor sms -anisette http://127.0.0.1:$AnisettePort"
}
catch {
  Write-Host ""
  Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Remote hints: docker compose -f /opt/anisette/docker-compose.yml logs --tail 40" -ForegroundColor Yellow
  exit 1
}
finally {
  Remove-Askpass
  if (-not $KeepArchive -and $script:Archive -and (Test-Path $script:Archive)) { Remove-Item $script:Archive -Force -ErrorAction SilentlyContinue }
}
