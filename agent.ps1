# Helpdesk Agent - Windows Endpoint
# Polls server every 30s, executes assigned commands, posts results.
# Runs as SYSTEM via Scheduled Task (SunPassion-HelpdeskAgent).
#
# Paths:
#   Config : C:\ProgramData\SunPassion\helpdesk-agent\config.json
#   Token  : C:\ProgramData\SunPassion\helpdesk-agent\token.dat
#   Log    : C:\ProgramData\SunPassion\helpdesk-agent\agent.log
#
# ASCII-only comments (SunPassion convention).

$AgentVersion = "1.0.0"
$AgentDir     = "C:\ProgramData\SunPassion\helpdesk-agent"
$ConfigPath   = "$AgentDir\config.json"
$TokenPath    = "$AgentDir\token.dat"
$LogPath      = "$AgentDir\agent.log"
$MaxLogBytes  = 5MB

# ---------------------------------------------------------------- helpers

function Write-Log {
    param($Msg, [string]$Level = "INFO")
    # Rotate log if > 5 MB
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) {
        Move-Item $LogPath "$LogPath.bak" -Force
    }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { Write-Log "config.json not found" "ERROR"; exit 1 }
    return Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Get-MachineGuid {
    try {
        return (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -EA Stop).MachineGuid
    } catch { return $env:COMPUTERNAME }
}

function Get-DeviceBasicInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -EA Stop
        $cs = Get-CimInstance Win32_ComputerSystem  -EA Stop
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
               Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1).IPAddress
        return @{
            hostname      = $env:COMPUTERNAME
            username      = $cs.UserName
            domain        = $cs.Domain
            os_version    = "$($os.Caption) $($os.Version)"
            machine_guid  = Get-MachineGuid
            agent_version = $AgentVersion
        }
    } catch {
        return @{
            hostname      = $env:COMPUTERNAME
            machine_guid  = Get-MachineGuid
            agent_version = $AgentVersion
        }
    }
}

function Invoke-Api {
    param($Method, $Url, $Body = $null)
    $params = @{
        Method      = $Method
        Uri         = $Url
        TimeoutSec  = 20
        ErrorAction = 'Stop'
        ContentType = 'application/json'
    }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------- registration

function Register-Agent {
    param($Config, $Info)
    try {
        $body = $Info.Clone()
        $body.secret = $Config.agent_secret
        $resp = Invoke-Api -Method POST -Url "$($Config.server_url)/api/agent/register" -Body $body
        if ($resp.token) {
            Set-Content -Path $TokenPath -Value $resp.token -Encoding UTF8
            Write-Log "Registered: device_id=$($resp.device_id)"
            return $resp
        }
    } catch { Write-Log "Registration failed: $_" "ERROR" }
    return $null
}

# ---------------------------------------------------------------- collectors

function Get-Sysinfo {
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $bios = Get-CimInstance Win32_BIOS
        $disks = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\' } | ForEach-Object {
            @{ drive   = $_.Name
               free_gb = [math]::Round($_.Free  / 1GB, 2)
               used_gb = [math]::Round($_.Used  / 1GB, 2)
               total_gb= [math]::Round(($_.Free+$_.Used)/1GB,2) }
        }
        $ips = Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
               Where-Object { $_.IPAddress -ne '127.0.0.1' } |
               ForEach-Object { "$($_.InterfaceAlias): $($_.IPAddress)/$($_.PrefixLength)" }
        @{
            hostname       = $env:COMPUTERNAME
            username       = $cs.UserName
            domain         = $cs.Domain
            os             = "$($os.Caption) $($os.Version) [$($os.OSArchitecture)]"
            build          = $os.BuildNumber
            ram_total_gb   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
            ram_free_gb    = [math]::Round($os.FreePhysicalMemory     / 1MB, 2)
            cpu            = "$($cpu.Name) ($($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T @ $($cpu.MaxClockSpeed)MHz)"
            uptime_hours   = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
            last_boot      = $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
            disks          = $disks
            ip_addresses   = $ips
            timezone       = (Get-TimeZone).DisplayName
            bios_serial    = $bios.SerialNumber
        } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-Netinfo {
    try {
        $adapters = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
            $ip = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -EA SilentlyContinue | Select-Object -First 1
            @{ name=$_.Name; mac=$_.MacAddress
               speed_mbps=[math]::Round($_.LinkSpeed/1MB,0)
               ip=$ip.IPAddress; prefix=$ip.PrefixLength }
        }
        $gw  = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        $dns = Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue |
               Where-Object { $_.ServerAddresses } |
               Select-Object -ExpandProperty ServerAddresses | Sort-Object -Unique
        $conn = netstat -an 2>&1 | Select-String 'ESTABLISHED' | Select-Object -First 20 | ForEach-Object { $_.Line.Trim() }
        @{
            adapters         = $adapters
            default_gateway  = $gw
            dns_servers      = $dns
            established_connections = $conn
        } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-EventlogSummary {
    try {
        $cutoff = (Get-Date).AddHours(-24)
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'System','Application'
            Level     = 1,2,3   # Critical, Error, Warning
            StartTime = $cutoff
        } -MaxEvents 100 -EA SilentlyContinue | ForEach-Object {
            @{ time    = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
               level   = $_.LevelDisplayName
               source  = $_.ProviderName
               id      = $_.Id
               message = ($_.Message -split "`n" | Select-Object -First 2) -join ' ' }
        }
        @{ period_hours=24; count=$events.Count; events=$events } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-DefenderStatus {
    try {
        $status = Get-MpComputerStatus -EA Stop
        $threats = Get-MpThreatDetection -EA SilentlyContinue | Select-Object -First 10 | ForEach-Object {
            @{ id=$_.ThreatID; name=$_.ThreatName; severity=$_.SeverityID
               detected=$_.InitialDetectionTime.ToString("yyyy-MM-dd HH:mm:ss") }
        }
        @{
            am_enabled            = $status.AMServiceEnabled
            realtime_enabled      = $status.RealTimeProtectionEnabled
            av_signature_version  = $status.AntivirusSignatureVersion
            av_signature_age_days = $status.AntivirusSignatureAge
            last_scan_type        = $status.LastFullScanSource
            last_quick_scan       = $status.QuickScanStartTime
            last_full_scan        = $status.FullScanStartTime
            threats_detected      = $threats
            engine_version        = $status.AMEngineVersion
        } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-UpdateStatus {
    try {
        $hotfixes = Get-HotFix -EA SilentlyContinue |
                    Sort-Object InstalledOn -Descending |
                    Select-Object -First 20 |
                    ForEach-Object { @{ id=$_.HotFixID; description=$_.Description
                                        installed=$_.InstalledOn } }
        # Check for pending updates via Windows Update COM
        $pending = @()
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $result   = $searcher.Search("IsInstalled=0 and IsHidden=0")
            $pending  = $result.Updates | Select-Object -First 20 | ForEach-Object { $_.Title }
        } catch {}
        @{
            recent_hotfixes  = $hotfixes
            pending_updates  = $pending
            pending_count    = $pending.Count
        } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-PrinterList {
    try {
        $printers = Get-Printer -EA SilentlyContinue | ForEach-Object {
            @{ name=$_.Name; driver=$_.DriverName; port=$_.PortName
               shared=$_.Shared; default=$_.Default; published=$_.Published
               type=$_.Type; status=$_.PrinterStatus }
        }
        @{ printers=$printers; count=$printers.Count } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-ProcessList {
    try {
        $procs = Get-Process -EA SilentlyContinue |
                 Sort-Object CPU -Descending |
                 Select-Object -First 30 |
                 ForEach-Object {
                    @{ name=$_.Name; pid=$_.Id
                       cpu=[math]::Round($_.CPU,2)
                       mem_mb=[math]::Round($_.WorkingSet64/1MB,1)
                       start_time=try{$_.StartTime.ToString("HH:mm:ss")}catch{"—"} }
                 }
        @{ count=(Get-Process -EA SilentlyContinue).Count; top30_by_cpu=$procs } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-WifiInfo {
    try {
        $interfaces = (netsh wlan show interfaces 2>&1) | Out-String
        $profiles   = (netsh wlan show profiles 2>&1) | Out-String
        "=== INTERFACES ===`n$interfaces`n=== PROFILES ===`n$profiles"
    } catch { "ERROR: $_" }
}

function Get-GpResult {
    try {
        $out = gpresult /r /scope computer 2>&1 | Out-String
        $out
    } catch { "ERROR: $_" }
}

function Invoke-Ping {
    param($Target)
    try {
        $results = Test-Connection -ComputerName $Target -Count 5 -EA SilentlyContinue | ForEach-Object {
            @{ seq=$_.Buffers; rtt_ms=$_.ResponseTime; ttl=$_.TimeToLive }
        }
        $latencies = $results | Where-Object { $_.rtt_ms } | ForEach-Object { $_.rtt_ms }
        @{
            target     = $Target
            sent       = 5
            received   = $results.Count
            avg_ms     = if($latencies){[math]::Round(($latencies|Measure-Object -Average).Average,1)}else{"—"}
            min_ms     = if($latencies){($latencies|Measure-Object -Minimum).Minimum}else{"—"}
            max_ms     = if($latencies){($latencies|Measure-Object -Maximum).Maximum}else{"—"}
            results    = $results
        } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

# ---------------------------------------------------------------- file collectors

# getfile is gated by an allowlist that lives in this agent's config.json
# (deployed via Intune). The agent -- not the portal -- decides what may be
# pulled off the machine, so an operator cannot point it at a user's private
# folders. listdir/readfile return metadata and text and are not gated, but
# readfile is size-capped so it stays "read a log/config", not "dump a DB".

$Script:FileAllowlist = @()   # populated from config in the main body

function Test-PathAllowed {
    param($Path)
    if (-not $Script:FileAllowlist -or $Script:FileAllowlist.Count -eq 0) {
        return $false   # empty allowlist = getfile disabled (fail closed)
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch { return $false }
    foreach ($root in $Script:FileAllowlist) {
        try {
            $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
            if ($full -eq $r -or $full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch {}
    }
    return $false
}

function Get-ListDir {
    param($Path)
    try {
        if (-not (Test-Path $Path)) { return "ERROR: path not found: $Path" }
        $items = Get-ChildItem -LiteralPath $Path -Force -EA SilentlyContinue | ForEach-Object {
            @{ name     = $_.Name
               type     = if ($_.PSIsContainer) { "dir" } else { "file" }
               size     = if ($_.PSIsContainer) { $null } else { $_.Length }
               modified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
               attrs    = $_.Attributes.ToString() }
        }
        @{ path = $Path; count = $items.Count; items = $items } | ConvertTo-Json -Depth 5
    } catch { "ERROR: $_" }
}

function Get-ReadFile {
    param($Path, $MaxBytes = 1048576)   # 1 MB text cap
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return "ERROR: not a file: $Path"
        }
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -gt $MaxBytes) {
            return "ERROR: file too large for readfile ($([math]::Round($len/1MB,2)) MB > 1 MB). Use Download File instead."
        }
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -EA Stop
        @{ path = $Path; size = $len; content = $content } | ConvertTo-Json -Depth 3
    } catch { "ERROR: $_" }
}

function Get-FileB64 {
    param($Path, $MaxBytes = 20971520)   # 20 MB cap
    try {
        # Allowlist gate -- enforced here, on the endpoint, not in the portal
        if (-not (Test-PathAllowed $Path)) {
            $roots = ($Script:FileAllowlist -join "; ")
            return (@{ path = $Path; error =
                "REFUSED: path is outside the configured allowlist. Allowed roots: $roots"
            } | ConvertTo-Json -Depth 3)
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return (@{ path = $Path; error = "not a file: $Path" } | ConvertTo-Json)
        }
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -gt $MaxBytes) {
            return (@{ path = $Path; error =
                "file too large ($([math]::Round($len/1MB,2)) MB > 20 MB cap)"
            } | ConvertTo-Json)
        }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $sha   = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        @{ path   = $Path
           size   = $len
           sha256 = $sha
           b64    = [System.Convert]::ToBase64String($bytes) } | ConvertTo-Json -Depth 3
    } catch {
        (@{ path = $Path; error = "$_" } | ConvertTo-Json)
    }
}

function Invoke-Shell {
    param($Script, $TimeoutSecs = 300)
    try {
        $sb  = [ScriptBlock]::Create($Script)
        $job = Start-Job -ScriptBlock { param($s) Invoke-Expression $s 2>&1 | Out-String } -ArgumentList $Script
        if (Wait-Job $job -Timeout $TimeoutSecs) {
            $out = Receive-Job $job 2>&1 | Out-String
            Remove-Job $job -Force
            return $out
        } else {
            Stop-Job  $job
            Remove-Job $job -Force
            return "TIMEOUT: Command did not complete within $TimeoutSecs seconds"
        }
    } catch { "ERROR: $_" }
}

# ---------------------------------------------------------------- command dispatch

function Execute-Command {
    param($Cmd)
    $type    = $Cmd.type
    $payload = $Cmd.payload
    $timeout = $Cmd.timeout

    Write-Log "Executing: type=$type id=$($Cmd.id)"
    switch ($type) {
        "sysinfo"   { return Get-Sysinfo }
        "netinfo"   { return Get-Netinfo }
        "eventlog"  { return Get-EventlogSummary }
        "defender"  { return Get-DefenderStatus }
        "updates"   { return Get-UpdateStatus }
        "printers"  { return Get-PrinterList }
        "processes" { return Get-ProcessList }
        "wifi"      { return Get-WifiInfo }
        "gpresult"  { return Get-GpResult }
        "ping"      { return Invoke-Ping -Target ($payload.target ?? "8.8.8.8") }
        "shell"     { return Invoke-Shell -Script ($payload.script ?? "") -TimeoutSecs ($timeout ?? 300) }
        "listdir"   { return Get-ListDir  -Path ($payload.path ?? "C:\") }
        "readfile"  { return Get-ReadFile -Path ($payload.path ?? "") }
        "getfile"   { return Get-FileB64  -Path ($payload.path ?? "") }
        default     { return "Unknown command type: $type" }
    }
}

# ---------------------------------------------------------------- main loop

Write-Log "Agent starting v$AgentVersion"
$Config = Get-Config
$Info   = Get-DeviceBasicInfo

# Load getfile allowlist (fail closed if absent -> getfile refuses everything)
if ($Config.file_allowlist) {
    $Script:FileAllowlist = @($Config.file_allowlist)
    Write-Log "getfile allowlist: $($Script:FileAllowlist -join '; ')"
} else {
    $Script:FileAllowlist = @()
    Write-Log "getfile allowlist EMPTY -> Download File disabled" "WARN"
}

# Load or create token
$Token    = $null
$DeviceId = $null

if (Test-Path $TokenPath) {
    $Token = (Get-Content $TokenPath -Raw -EA SilentlyContinue).Trim()
    if ($Token) { Write-Log "Loaded existing token" }
}

if (-not $Token) {
    $reg = Register-Agent -Config $Config -Info $Info
    if ($reg) {
        $Token    = $reg.token
        $DeviceId = $reg.device_id
    } else {
        Write-Log "Initial registration failed; will retry..." "WARN"
    }
}
if (-not $DeviceId) {
    $DeviceId = $Info.machine_guid ?? $env:COMPUTERNAME
}

$PollInterval   = [int]($Config.poll_interval ?? 30)
$ConsecErrors   = 0
$MaxConsecErrors = 10

Write-Log "DeviceId=$DeviceId PollInterval=${PollInterval}s"

while ($true) {
    try {
        $url  = "$($Config.server_url)/api/agent/poll?device_id=$([Uri]::EscapeDataString($DeviceId))&token=$([Uri]::EscapeDataString($Token))"
        $resp = Invoke-Api -Method GET -Url $url

        $ConsecErrors = 0  # reset on success

        if ($resp.command) {
            $cmd = $resp.command
            Write-Log "Got command: id=$($cmd.id) type=$($cmd.type)"

            $result  = $null
            $isError = $false

            try {
                $result = Execute-Command -Cmd $cmd
            } catch {
                $result  = "EXECUTION ERROR: $_"
                $isError = $true
                Write-Log "Command error: $_" "ERROR"
            }

            # Post result
            $resultBody = @{
                device_id  = $DeviceId
                token      = $Token
                command_id = $cmd.id
                result     = if($result){$result.ToString()}else{""}
                exit_code  = 0
                error      = $isError
            }
            try {
                Invoke-Api -Method POST -Url "$($Config.server_url)/api/agent/result" -Body $resultBody | Out-Null
                Write-Log "Result posted for id=$($cmd.id) len=$($result.Length)"
            } catch {
                Write-Log "Failed to post result: $_" "WARN"
            }
        }

    } catch {
        $ConsecErrors++
        $statusCode = $null
        try { $statusCode = $_.Exception.Response?.StatusCode?.value__ } catch {}

        if ($statusCode -eq 403) {
            # Token rejected -- re-register
            Write-Log "Token rejected (403), re-registering..." "WARN"
            $Token = $null
            Remove-Item $TokenPath -Force -EA SilentlyContinue
            $reg = Register-Agent -Config $Config -Info $Info
            if ($reg) {
                $Token    = $reg.token
                $DeviceId = $reg.device_id
                Write-Log "Re-registered: device_id=$DeviceId"
            }
        } else {
            Write-Log "Poll failed ($ConsecErrors/${MaxConsecErrors}): $_" "WARN"
            if ($ConsecErrors -ge $MaxConsecErrors) {
                Write-Log "Too many consecutive errors, sleeping 5 min..." "ERROR"
                Start-Sleep -Seconds 300
                $ConsecErrors = 0
            }
        }
    }

    Start-Sleep -Seconds $PollInterval
}
