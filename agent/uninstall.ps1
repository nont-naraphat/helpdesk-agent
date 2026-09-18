# Helpdesk Agent - Intune Win32 Uninstaller
# ASCII-only comments (SunPassion convention).

$TaskName = "SunPassion-HelpdeskAgent"
$AgentDir = "C:\ProgramData\SunPassion\helpdesk-agent"
$RegPath  = "HKLM:\SOFTWARE\SunPassion\HelpdeskAgent"

try {
    Stop-ScheduledTask    -TaskName $TaskName -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -EA SilentlyContinue
    Start-Sleep -Seconds 2

    Remove-Item -Path $AgentDir -Recurse -Force -EA SilentlyContinue
    Remove-Item -Path $RegPath  -Recurse -Force -EA SilentlyContinue

    Write-Host "Uninstall complete"
    exit 0
} catch {
    Write-Host "Uninstall error: $_"
    exit 1
}
