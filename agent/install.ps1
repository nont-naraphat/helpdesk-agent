# Helpdesk Agent - Intune Win32 Installer
# Runs as SYSTEM context during Intune Win32 deployment.
# Edit SERVER_URL and AGENT_SECRET before packaging with IntuneWinAppUtil.
#
# Detection rule: Registry HKLM:\SOFTWARE\SunPassion\HelpdeskAgent  Value: Version = "1.0.0"
# ASCII-only comments (SunPassion convention).

# ---- CONFIGURE BEFORE PACKAGING ----
$SERVER_URL   = "http://192.168.0.101:8097"   # NAS_02 helpdesk-agent server
$AGENT_SECRET = "CHANGE_ME_BEFORE_PACKAGING"  # Must match AGENT_SECRET env in docker-compose
$POLL_INTERVAL = 30                            # seconds

# Download File (getfile) allowlist. The agent will ONLY hand back files that
# live under one of these roots; anything else (user profiles, browser data,
# etc.) is refused by the agent itself. Widening this for a real incident is a
# deliberate, versioned Intune change -- which is exactly the friction you want
# on "pull an arbitrary file off an employee's machine". Keep it tight.
$FILE_ALLOWLIST = @(
    "C:\ProgramData\SunPassion",
    "C:\ProgramData\BH-IT",
    "C:\Windows\Logs",
    "C:\Windows\Temp",
    "C:\Temp"
)
# ------------------------------------

$TaskName  = "SunPassion-HelpdeskAgent"
$AgentDir  = "C:\ProgramData\SunPassion\helpdesk-agent"
$RegPath   = "HKLM:\SOFTWARE\SunPassion\HelpdeskAgent"
$Version   = "1.0.0"

function Write-Log { param($Msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg"
    Write-Host $line
    try { Add-Content -Path "$AgentDir\install.log" -Value $line -EA SilentlyContinue } catch {}
}

try {
    # 1. Create directory
    New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null
    Write-Log "Directory ready: $AgentDir"

    # 2. Write config.json
    $config = @{
        server_url     = $SERVER_URL
        agent_secret   = $AGENT_SECRET
        poll_interval  = $POLL_INTERVAL
        file_allowlist = $FILE_ALLOWLIST
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText("$AgentDir\config.json", $config, [System.Text.Encoding]::UTF8)
    Write-Log "config.json written"

    # 3. Copy agent script
    $src = Join-Path $PSScriptRoot "agent.ps1"
    if (-not (Test-Path $src)) { throw "agent.ps1 not found in package directory: $src" }
    Copy-Item $src "$AgentDir\agent.ps1" -Force
    Write-Log "agent.ps1 copied"

    # 4. Remove old scheduled task if exists
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -EA SilentlyContinue

    # 5. Register new scheduled task
    $action   = New-ScheduledTaskAction `
                    -Execute "powershell.exe" `
                    -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$AgentDir\agent.ps1`""
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
                    -RestartCount 5 `
                    -RestartInterval (New-TimeSpan -Minutes 2) `
                    -MultipleInstances IgnoreNew `
                    -StartWhenAvailable $true
    $principal = New-ScheduledTaskPrincipal `
                    -UserId "SYSTEM" `
                    -LogonType ServiceAccount `
                    -RunLevel Highest

    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force | Out-Null
    Write-Log "Scheduled task registered: $TaskName"

    # 6. Start immediately (first-time registration)
    Start-ScheduledTask -TaskName $TaskName
    Write-Log "Scheduled task started"

    # 7. Write detection registry key
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name "Version"  -Value $Version  -Type String
    Set-ItemProperty -Path $RegPath -Name "Installed" -Value "1"      -Type String
    Set-ItemProperty -Path $RegPath -Name "Server"   -Value $SERVER_URL -Type String
    Write-Log "Registry detection key written"

    Write-Log "Install complete v$Version"
    exit 0

} catch {
    Write-Log "INSTALL FAILED: $_"
    exit 1
}
