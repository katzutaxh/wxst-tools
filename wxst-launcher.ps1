#requires -Version 5.1
<#
    Wxst Tools - License Launcher
    ------------------------------------------------------------------
    HWID-locked license gate. Keys are generated offline with
    wxst-keygen.ps1 (keep that script + $Secret private - never ship
    it to customers).

    SECURITY NOTE (read this): the $Secret below lives inside this
    script. Anyone who fully decompiles/reads this file could extract
    it and forge their own keys, including lifetime ones. This design
    stops casual key sharing (a key literally will not run on a
    different PC) but it cannot stop a determined reverse engineer
    forever - no offline check can. If you want that last mile of
    protection, move validation to a small web endpoint you control
    and never ship the secret client-side at all. Happy to build that
    piece too if you want it.
#>

# ============================== CONFIG ==============================
$Secret          = "CHANGE-ME-TO-YOUR-OWN-SECRET-BEFORE-SHIPPING-2026"  # MUST match wxst-keygen.ps1, keep private
$AppName         = "Wxst Tools"
$LicenseDir      = Join-Path $env:LOCALAPPDATA "WxstTools"
$LicenseFile     = Join-Path $LicenseDir "license.dat"
$MinAuthSeconds  = 5

# ============================ ANSI / COLOR ===========================
# Enable virtual terminal (ANSI) processing so 24-bit color + cursor
# tricks work even when launched from an old-style cmd/bat window.
Add-Type -Name Win32 -Namespace Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GetStdHandle_dummy();
[DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction SilentlyContinue

try {
    $stdOut = [Console.Win32]::GetStdHandle(-11)
    $mode = 0
    [Console.Win32]::GetConsoleMode($stdOut, [ref]$mode) | Out-Null
    [Console.Win32]::SetConsoleMode($stdOut, $mode -bor 0x0004) | Out-Null
} catch {}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Esc = [char]27

function Write-Ansi($Text, $R, $G, $B, [switch]$NoNewline) {
    $seq = "$Esc[38;2;$R;$G;${B}m$Text$Esc[0m"
    if ($NoNewline) { Write-Host $seq -NoNewline } else { Write-Host $seq }
}

function Write-AnsiColorName($Text, $ColorName, [switch]$NoNewline) {
    switch ($ColorName) {
        'green' { Write-Ansi $Text 0 220 0 -NoNewline:$NoNewline }
        'red'   { Write-Ansi $Text 220 0 0 -NoNewline:$NoNewline }
        'white' { Write-Ansi $Text 235 235 235 -NoNewline:$NoNewline }
        'gray'  { Write-Ansi $Text 150 150 150 -NoNewline:$NoNewline }
        default { Write-Host $Text -NoNewline:$NoNewline }
    }
}

# ============================== BANNER ===============================
# "WXST TOOLS" - ANSI Shadow style block art
$BannerLines = @(
    '██╗    ██╗██╗  ██╗███████╗████████╗   ████████╗ ██████╗  ██████╗ ██╗     ███████╗',
    '██║    ██║╚██╗██╔╝██╔════╝╚══██╔══╝   ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝',
    '██║ █╗ ██║ ╚███╔╝ ███████╗   ██║         ██║   ██║   ██║██║   ██║██║     ███████╗',
    '██║███╗██║ ██╔██╗ ╚════██║   ██║         ██║   ██║   ██║██║   ██║██║     ╚════██║',
    '╚███╔███╔╝██╔╝ ██╗███████║   ██║         ██║   ╚██████╔╝╚██████╔╝███████╗███████║',
    ' ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝   ╚═╝         ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝'
)

# Dark purple (top) -> light purple/lavender (bottom) gradient
$GradientStops = @(
    @{R=48;  G=10;  B=90},
    @{R=76;  G=20;  B=130},
    @{R=110; G=45;  B=170},
    @{R=145; G=80;  B=205},
    @{R=180; G=125; B=230},
    @{R=215; G=175; B=250}
)

function Show-Banner([switch]$Centered) {
    $width = try { [Console]::WindowWidth } catch { 120 }
    for ($i = 0; $i -lt $BannerLines.Count; $i++) {
        $line = $BannerLines[$i]
        $pad = 0
        if ($Centered) {
            $pad = [Math]::Max(0, [int](($width - $line.Length) / 2))
        }
        $c = $GradientStops[$i]
        Write-Host (' ' * $pad) -NoNewline
        Write-Ansi $line $c.R $c.G $c.B
    }
}

# =============================== HWID =================================
function Get-HWID {
    try {
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        $cpu  = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).ProcessorId
        $disk = (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1).SerialNumber
        $raw  = "$uuid|$cpu|$disk"
    } catch {
        # Fallback if WMI/CIM is unavailable for some reason
        $raw = "$env:COMPUTERNAME|$env:PROCESSOR_IDENTIFIER|$env:USERNAME"
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    $hex = -join ($hash | ForEach-Object { $_.ToString('X2') })
    return $hex.Substring(0, 16)
}

# ========================= LICENSE / KEY LOGIC =========================
$DurationMap = @{
    'D1' = @{ Label = '1 Day';   Add = { param($d) $d.AddDays(1) } }
    'D7' = @{ Label = '7 Day';   Add = { param($d) $d.AddDays(7) } }
    'M1' = @{ Label = '1 Month'; Add = { param($d) $d.AddMonths(1) } }
    'M6' = @{ Label = '6 Month'; Add = { param($d) $d.AddMonths(6) } }
    'LT' = @{ Label = 'Lifetime'; Add = $null }
}

function Get-KeySignature($Hwid, $Dur, $KeyId, $SecretValue) {
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($SecretValue))
    $bytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Hwid|$Dur|$KeyId"))
    $hex = -join ($bytes | ForEach-Object { $_.ToString('X2') })
    return $hex.Substring(0, 12)
}

function Test-LicenseKey($KeyString, $Hwid) {
    $parts = $KeyString.Trim().ToUpper() -split '-'
    if ($parts.Count -ne 4 -or $parts[0] -ne 'WXST') { return $null }
    $dur   = $parts[1]
    $keyId = $parts[2]
    $sig   = $parts[3]
    if (-not $DurationMap.ContainsKey($dur)) { return $null }
    $expected = Get-KeySignature -Hwid $Hwid -Dur $dur -KeyId $keyId -SecretValue $Secret
    if ($expected -ne $sig) { return $null }
    return @{ Duration = $dur; Label = $DurationMap[$dur].Label; KeyId = $keyId }
}

function Protect-Bytes($Bytes) {
    return [System.Security.Cryptography.ProtectedData]::Protect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
}
function Unprotect-Bytes($Bytes) {
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
}

function Save-LicenseCache($Hwid, $DurCode, $Label, $ExpiryUtc, $MaskedKey) {
    New-Item -ItemType Directory -Path $LicenseDir -Force | Out-Null
    $obj = [PSCustomObject]@{
        Hwid      = $Hwid
        DurCode   = $DurCode
        Label     = $Label
        ExpiryUtc = if ($ExpiryUtc) { $ExpiryUtc.ToString('o') } else { 'LIFETIME' }
        MaskedKey = $MaskedKey
    }
    $json = $obj | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $protected = Protect-Bytes $bytes
    [IO.File]::WriteAllBytes($LicenseFile, $protected)
}

function Read-LicenseCache {
    if (-not (Test-Path $LicenseFile)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($LicenseFile)
        $plain = Unprotect-Bytes $bytes
        $json = [System.Text.Encoding]::UTF8.GetString($plain)
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Mask-Key($KeyString) {
    $k = $KeyString.Trim()
    if ($k.Length -le 10) { return $k }
    return "$($k.Substring(0,9))****$($k.Substring($k.Length-4))"
}

# =============================== SCREENS ================================
function Show-HeaderScreen {
    Clear-Host
    Show-Banner
    Write-Host ""
    $hwid = Get-HWID
    Write-AnsiColorName "PC Name : " 'gray'; Write-Host $env:COMPUTERNAME
    Write-AnsiColorName "Account : " 'gray'; Write-Host $env:USERNAME
    Write-AnsiColorName "OS      : " 'gray'; Write-Host ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)
    Write-AnsiColorName "HWID    : " 'gray'; Write-AnsiColorName $hwid 'white'
    Write-Host ""
    Write-Host ""
    Write-Host ""
    Write-Host ""
    return $hwid
}

function Invoke-KeyPrompt($Hwid) {
    while ($true) {
        Write-AnsiColorName "[" 'white' -NoNewline
        Write-AnsiColorName "+" 'green' -NoNewline
        Write-AnsiColorName "] key: " 'white' -NoNewline
        $inputKey = Read-Host

        $result = Test-LicenseKey -KeyString $inputKey -Hwid $Hwid
        if (-not $result) {
            Write-AnsiColorName "[" 'white' -NoNewline
            Write-AnsiColorName "!" 'red' -NoNewline
            Write-AnsiColorName "] Invalid key for this PC. Try again." 'red'
            continue
        }

        # ---- authorizing animation (>=5s), plus flashes between * and + in red
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $toggle = $true
        while ($sw.Elapsed.TotalSeconds -lt $MinAuthSeconds) {
            $sym = if ($toggle) { '*' } else { '+' }
            Write-Host "`r" -NoNewline
            Write-AnsiColorName "[" 'white' -NoNewline
            Write-Ansi $sym 220 0 0 -NoNewline
            Write-AnsiColorName "] authorizing" 'white' -NoNewline
            Write-Host ("." * (1 + ([int]($sw.Elapsed.TotalSeconds * 2) % 3))) -NoNewline
            Write-Host "   " -NoNewline
            Start-Sleep -Milliseconds 250
            $toggle = -not $toggle
        }
        Write-Host "`r" -NoNewline
        Write-Host (' ' * 60) -NoNewline
        Write-Host "`r" -NoNewline

        $expiry = $null
        if ($result.Duration -ne 'LT') {
            $expiry = (& $DurationMap[$result.Duration].Add ([DateTime]::UtcNow))
        }
        $masked = Mask-Key $inputKey
        Save-LicenseCache -Hwid $Hwid -DurCode $result.Duration -Label $result.Label -ExpiryUtc $expiry -MaskedKey $masked

        Write-AnsiColorName "[" 'white' -NoNewline
        Write-AnsiColorName "+" 'green' -NoNewline
        Write-AnsiColorName "] Success, your license has been authorized(" 'white' -NoNewline
        Write-AnsiColorName $result.Label 'green' -NoNewline
        Write-AnsiColorName ")" 'white'
        Start-Sleep -Seconds 2
        return @{ Label = $result.Label; ExpiryUtc = $expiry; MaskedKey = $masked }
    }
}

function Get-TimeLeftText($ExpiryUtcString) {
    if ($ExpiryUtcString -eq 'LIFETIME') { return "Lifetime (never expires)" }
    $expiry = [DateTime]::Parse($ExpiryUtcString, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    $remaining = $expiry - [DateTime]::UtcNow
    if ($remaining.TotalSeconds -le 0) { return $null }
    if ($remaining.TotalDays -ge 1) { return "{0}d {1}h remaining" -f [int]$remaining.Days, $remaining.Hours }
    if ($remaining.TotalHours -ge 1) { return "{0}h {1}m remaining" -f [int]$remaining.Hours, $remaining.Minutes }
    return "{0}m remaining" -f [int]$remaining.TotalMinutes
}

function Show-MainMenu($Hwid, $Label, $ExpiryUtcString, $MaskedKey) {
    Clear-Host
    Show-Banner -Centered
    Write-Host ""
    $width = try { [Console]::WindowWidth } catch { 120 }
    $lines = @(
        "Username: $env:USERNAME@$env:COMPUTERNAME",
        "License : $MaskedKey  ($Label)"
    )
    $timeLeft = Get-TimeLeftText $ExpiryUtcString
    $lines += "Status  : $timeLeft"

    foreach ($l in $lines) {
        $pad = [Math]::Max(0, [int](($width - $l.Length) / 2))
        Write-Host (' ' * $pad) -NoNewline
        Write-Host $l
    }
    Write-Host ""
    $menu = "----------------------------------------"
    $pad = [Math]::Max(0, [int](($width - $menu.Length) / 2))
    Write-Host (' ' * $pad) -NoNewline
    Write-Host $menu
    $opt = "[1] Options coming soon...   [Q] Quit"
    $pad = [Math]::Max(0, [int](($width - $opt.Length) / 2))
    Write-Host (' ' * $pad) -NoNewline
    Write-Host $opt
    Write-Host ""

    while ($true) {
        $choice = Read-Host "wxst>"
        switch ($choice.Trim().ToUpper()) {
            'Q' { return }
            default { Write-Host "Not implemented yet." }
        }
    }
}

# ================================ MAIN ==================================
$hwid = Show-HeaderScreen
$cache = Read-LicenseCache
$needsKey = $true

if ($cache -and $cache.Hwid -eq $hwid) {
    if ($cache.ExpiryUtc -eq 'LIFETIME') {
        $needsKey = $false
    } else {
        $t = Get-TimeLeftText $cache.ExpiryUtc
        if ($t) { $needsKey = $false }
    }
}

if ($needsKey) {
    $auth = Invoke-KeyPrompt -Hwid $hwid
    Show-MainMenu -Hwid $hwid -Label $auth.Label -ExpiryUtcString $(if ($auth.ExpiryUtc) { $auth.ExpiryUtc.ToString('o') } else { 'LIFETIME' }) -MaskedKey $auth.MaskedKey
} else {
    Show-MainMenu -Hwid $hwid -Label $cache.Label -ExpiryUtcString $cache.ExpiryUtc -MaskedKey $cache.MaskedKey
}
