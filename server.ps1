# =============================================================================
# WinAdmin Tool - server.ps1
# Servidor HTTP local en PowerShell para Windows 10 / Windows 11
# Puerto: 8080  |  Acceso: http://localhost:8080
# =============================================================================
param([int]$Port = 8080)

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# --- Helpers ------------------------------------------------------------------

function Get-FolderSize {
    param([string]$Path)
    try {
        $sum = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        return [long]($sum)
    } catch { return [long]0 }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -le 0)       { return "0 B" }
    if ($Bytes -ge 1073741824) { return "{0:N2} GB" -f ($Bytes / 1073741824) }
    if ($Bytes -ge 1048576)    { return "{0:N2} MB" -f ($Bytes / 1048576) }
    if ($Bytes -ge 1024)       { return "{0:N2} KB" -f ($Bytes / 1024) }
    return "$Bytes B"
}

function Send-Response {
    param($Context, $Data, [int]$Code = 200, [string]$ContentType = "application/json; charset=utf-8", [switch]$AsArray)
    try {
        $body = if ($ContentType -like "*/json*") {
            if ($AsArray) {
                # Garantiza que siempre se serialice como array JSON aunque
                # PowerShell haya desenvuelto el array a un solo elemento o null
                if ($null -eq $Data) {
                    '[]'
                } elseif ($Data -is [System.Array]) {
                    if ($Data.Count -eq 0) { '[]' }
                    else { ConvertTo-Json -InputObject $Data -Depth 10 -Compress }
                } else {
                    ConvertTo-Json -InputObject @($Data) -Depth 10 -Compress
                }
            } else {
                ConvertTo-Json -InputObject $Data -Depth 10 -Compress
            }
        } else { $Data }
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($body)
        $Context.Response.StatusCode = $Code
        $Context.Response.ContentType = $ContentType
        $Context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
        $Context.Response.Headers.Add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        $Context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
        $Context.Response.ContentLength64 = $buffer.Length
        $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $Context.Response.OutputStream.Close()
    } catch { }
}

function Read-Body {
    param($Request)
    try {
        $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } catch { return "" }
}

# --- Modulo 1: Usuarios -------------------------------------------------------

function Get-SystemUsers {
    $usersPath = "C:\Users"
    $excluded  = @("All Users","Default","Default User","Public","defaultuser0","Administrator")

    $users = Get-ChildItem -Path $usersPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $excluded -notcontains $_.Name -and $_.Name -notmatch '^\.' } |
        ForEach-Object {
            [PSCustomObject]@{
                Name              = $_.Name
                Path              = $_.FullName
                LastAccess        = $_.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss")
                LastAccessDisplay = $_.LastWriteTime.ToString("dd/MM/yyyy HH:mm")
                SizeBytes         = -1   # -1 = pendiente de calcular
                SizeDisplay       = "--"
            }
        } |
        Sort-Object LastAccess -Descending

    return @($users)
}

function Get-UserSize {
    param([string]$Username)
    $path = "C:\Users\$Username"
    if (-not (Test-Path $path)) { return @{ error = "Usuario no encontrado" } }
    $size = Get-FolderSize -Path $path
    return @{ username = $Username; sizeBytes = $size; sizeDisplay = (Format-Bytes $size) }
}

function Get-UserFolders {
    param([string]$Username)
    $path = "C:\Users\$Username"
    if (-not (Test-Path $path)) { return @{ error = "Usuario no encontrado" } }

    $folders = Get-ChildItem -Path $path -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $sz = Get-FolderSize -Path $_.FullName
            [PSCustomObject]@{
                Name        = $_.Name
                Path        = $_.FullName
                SizeBytes   = $sz
                SizeDisplay = (Format-Bytes $sz)
            }
        } | Sort-Object SizeBytes -Descending

    return @($folders)
}

# --- Modulo 2: Unidades -------------------------------------------------------

function Get-DriveList {
    $drives = Get-WmiObject -Class Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -in @(2,3,4,5) } |
        ForEach-Object {
            $letter   = $_.DeviceID.Replace(":","")
            $total    = [long]$_.Size
            $free     = [long]$_.FreeSpace
            $used     = $total - $free
            $pct      = if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { 0 }
            $typeMap  = @{ 2="Extraible"; 3="Fijo"; 4="Red"; 5="CD/DVD" }
            [PSCustomObject]@{
                Letter       = $letter
                Label        = if ($_.VolumeName) { $_.VolumeName } else { "Sin etiqueta" }
                Type         = $typeMap[[int]$_.DriveType]
                TotalBytes   = $total
                FreeBytes    = $free
                UsedBytes    = $used
                UsedPercent  = $pct
                TotalDisplay = (Format-Bytes $total)
                FreeDisplay  = (Format-Bytes $free)
                UsedDisplay  = (Format-Bytes $used)
                IsSystem     = ($letter -eq "C")
            }
        }
    return @($drives)
}

function Invoke-FormatDrive {
    param([string]$Drive)
    if ($Drive -eq "C") {
        return @{ success = $false; error = "No se puede formatear la unidad del sistema C:" }
    }
    try {
        # Metodo 1: Shell COM object - abre dialogo nativo de Windows
        $scriptBlock = @"
`$shell = New-Object -ComObject Shell.Application
`$item  = `$shell.Namespace("${Drive}:\").Self
`$item.InvokeVerb("Format")
Start-Sleep -Seconds 30
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptBlock))
        Start-Process powershell.exe -ArgumentList "-NoProfile -EncodedCommand $encoded" -Verb RunAs
        return @{ success = $true; message = "Dialogo de formateo lanzado para $Drive`:" }
    } catch {
        # Metodo 2: Abrir administrador de discos como fallback
        try {
            Start-Process "diskmgmt.msc" -Verb RunAs
            return @{ success = $true; message = "Administrador de discos abierto. Click derecho en $Drive`: y selecciona Formatear." }
        } catch {
            return @{ success = $false; error = $_.Exception.Message }
        }
    }
}

# --- Modulo 3: Limpieza -------------------------------------------------------

function Get-CleanupItem {
    param([string]$Id, [string]$Name, [string]$NameEu, [string]$Path,
          [string]$Category, [string]$CategoryEu, [int]$CatOrder,
          [bool]$RequiresAdmin=$false, [bool]$IsSpecial=$false)
    # Size NOT calculated here -- returned as -1 (pending)
    # Frontend requests sizes individually via /api/cleanup-size
    return [PSCustomObject]@{
        Id           = $Id
        Name         = $Name
        NameEu       = $NameEu
        Path         = $Path
        Category     = $Category
        CategoryEu   = $CategoryEu
        CatOrder     = $CatOrder
        SizeBytes    = [long]-1
        SizeDisplay  = "..."
        RequiresAdmin= $RequiresAdmin
        IsSpecial    = $IsSpecial
    }
}

function Get-SingleItemSize {
    param([string]$Id)
    # Rebuild item list just to get path/special flag
    $all = Get-CleanupPreview
    $item = $all | Where-Object { $_.Id -eq $Id }
    if (-not $item) { return @{ id=$Id; sizeBytes=0; sizeDisplay="0 B" } }

    $sz = [long]0
    switch ($Id) {
        "recycle_bin" {
            try {
                $sh = New-Object -ComObject Shell.Application
                $rb = $sh.Namespace(10)
                $sz = ($rb.Items() | Measure-Object -Property Size -Sum -ErrorAction SilentlyContinue).Sum
                if (-not $sz) { $sz = 0 }
            } catch { $sz = 0 }
        }
        "clipboard"  { $sz = 0 }
        "dns_cache"  { $sz = 0 }
        "run_mru"    { $sz = 0 }
        "chkdsk" {
            try {
                $sz = (Get-ChildItem "C:" -Filter "*.chk" -Force -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum).Sum
                if (-not $sz) { $sz = 0 }
            } catch { $sz = 0 }
        }
        default {
            if ($item.Path -and (Test-Path $item.Path)) {
                $sz = Get-FolderSize $item.Path
            }
        }
    }
    return @{ id=$Id; sizeBytes=[long]$sz; sizeDisplay=(Format-Bytes $sz) }
}

function Get-CleanupPreview {
    $items = @()

    # ---- SISTEMA (0) --------------------------------------------------------
    $cat = "Sistema"; $catEu = "Sistema"; $co = 0

    $items += Get-CleanupItem "recycle_bin" "Papelera de reciclaje" "Birziklapen ontzia" '$Recycle.Bin' $cat $catEu $co $false $true

    $items += Get-CleanupItem "user_temp"   "Archivos temporales (usuario)"    "Erabiltzaile aldi baterakoak"    $env:TEMP                                           $cat $catEu $co $false
    $items += Get-CleanupItem "win_temp"    "Archivos temporales (Windows)"    "Windows aldi baterakoak"         "C:\Windows\Temp"                                   $cat $catEu $co $true
    $items += Get-CleanupItem "memdumps"    "Volcados de memoria (minidumps)"  "Memoria hustuketa"               "C:\Windows\Minidump"                               $cat $catEu $co $true
    $items += Get-CleanupItem "chkdsk"      "Fragmentos Chkdsk (*.chk)"        "Chkdsk zatiak"                   "C:\"                                               $cat $catEu $co $true $false


    $items += Get-CleanupItem "clipboard"   "Portapapeles"                     "Arbeleko edukia"                 ""                                                  $cat $catEu $co $false $true
    $items += Get-CleanupItem "thumb_cache" "Cache de miniaturas"              "Miniatura cachea"                "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"       $cat $catEu $co $false
    $items += Get-CleanupItem "recent_docs" "Documentos recientes"             "Azken dokumentuak"               "$env:APPDATA\Microsoft\Windows\Recent"              $cat $catEu $co $false
    $items += Get-CleanupItem "run_mru"     "Historial de Ejecutar (Win+R)"    "Exekutatu historia"              ""                                                  $cat $catEu $co $false $true

    # ---- REGISTROS Y LOGS (1) ------------------------------------------------
    $cat = "Registros y Logs"; $catEu = "Erregistroak eta Logak"; $co = 1

    $items += Get-CleanupItem "cbs_logs"    "Logs CBS de Windows"              "CBS sistema erregistroak"        "C:\Windows\Logs\CBS"                               $cat $catEu $co $true
    $items += Get-CleanupItem "wu_logs"     "Logs de Windows Update"           "Windows Update erregistroak"     "C:\Windows\Logs\WindowsUpdate"                     $cat $catEu $co $true
    $items += Get-CleanupItem "evtlogs"     "Registros de eventos de Windows"  "Windows gertaera-erregistroak"   "C:\Windows\System32\winevt\Logs"                   $cat $catEu $co $true
    $items += Get-CleanupItem "wer"         "Informes de errores de Windows"   "Windows errore-txostenak"        "C:\ProgramData\Microsoft\Windows\WER"              $cat $catEu $co $true
    $items += Get-CleanupItem "drvinst"     "Logs instalacion de drivers"      "Gidari instalazio erregistroak"  "C:\Windows\INF"                                    $cat $catEu $co $true

    # ---- AVANZADO (2) -------------------------------------------------------
    $cat = "Avanzado"; $catEu = "Aurreratua"; $co = 2

    $items += Get-CleanupItem "prefetch"    "Archivos Prefetch"                "Prefetch fitxategiak"            "C:\Windows\Prefetch"                               $cat $catEu $co $true
    $items += Get-CleanupItem "wu_cache"    "Cache de Windows Update"          "Windows Update cachea"           "C:\Windows\SoftwareDistribution\Download"          $cat $catEu $co $true
    $items += Get-CleanupItem "winsxs"     "Logs de WinSxS (backup)"          "WinSxS erregistroak"             "C:\Windows\WinSxS\Backup"                          $cat $catEu $co $true
    $items += Get-CleanupItem "inetcache"   "Cache de Internet Explorer/Edge"  "IE/Edge cachea"                  "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"     $cat $catEu $co $false
    $items += Get-CleanupItem "ie_hist"     "Historial Internet Explorer"      "IE historia"                     "$env:LOCALAPPDATA\Microsoft\Windows\History"       $cat $catEu $co $false
    $items += Get-CleanupItem "ie_cookies"  "Cookies Internet Explorer/Edge"   "IE/Edge cookieak"                "$env:APPDATA\Microsoft\Windows\Cookies"            $cat $catEu $co $false
    $items += Get-CleanupItem "dns_cache"   "Cache DNS"                        "DNS cachea"                      ""                                                  $cat $catEu $co $true $true
    $items += Get-CleanupItem "font_cache"  "Cache de fuentes de Windows"      "Windows letra-tipoen cachea"     "C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache" $cat $catEu $co $true

    # ---- NAVEGADORES (3) ----------------------------------------------------
    $cat = "Navegadores"; $catEu = "Nabigatzaileak"; $co = 3

    # Chrome
    $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
    $items += Get-CleanupItem "chrome_cache"    "Chrome - Cache"              "Chrome - Cachea"            "$chromePath\Cache"                         $cat $catEu $co $false
    $items += Get-CleanupItem "chrome_hist"     "Chrome - Historial"          "Chrome - Historia"          "$chromePath\History"                       $cat $catEu $co $false $true
    $items += Get-CleanupItem "chrome_cookies"  "Chrome - Cookies"            "Chrome - Cookieak"          "$chromePath\Cookies"                       $cat $catEu $co $false $true
    $items += Get-CleanupItem "chrome_logs"     "Chrome - Logs"               "Chrome - Logak"             "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\logs" $cat $catEu $co $false

    # Edge
    $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"
    $items += Get-CleanupItem "edge_cache"      "Edge - Cache"                "Edge - Cachea"              "$edgePath\Cache"                           $cat $catEu $co $false
    $items += Get-CleanupItem "edge_hist"       "Edge - Historial"            "Edge - Historia"            "$edgePath\History"                         $cat $catEu $co $false $true
    $items += Get-CleanupItem "edge_cookies"    "Edge - Cookies"              "Edge - Cookieak"            "$edgePath\Cookies"                         $cat $catEu $co $false $true

    # Firefox
    $ffPath = "$env:APPDATA\Mozilla\Firefox\Profiles"
    $items += Get-CleanupItem "ff_cache"        "Firefox - Cache"             "Firefox - Cachea"           "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles" $cat $catEu $co $false
    $items += Get-CleanupItem "ff_hist"         "Firefox - Historial/Cookies" "Firefox - Historia/Cookieak" "$ffPath"                                  $cat $catEu $co $false $true

    # Filtrar los que la ruta no existe (size=0 y no IsSpecial) para no mostrar basura
    # Pero los mostramos todos para que el usuario sepa que existen
    return @($items)
}

function Invoke-Cleanup {
    param([string[]]$Items)
    $allItems   = Get-CleanupPreview
    $adminCmds  = @()
    $normalCmds = @()

    foreach ($id in $Items) {
        $item = $allItems | Where-Object { $_.Id -eq $id }
        if (-not $item) { continue }

        switch ($id) {
            "recycle_bin"  { $normalCmds += "Clear-RecycleBin -Force -ErrorAction SilentlyContinue" }
            "clipboard"    { $normalCmds += "cmd /c echo off | clip" }
            "dns_cache"    { $adminCmds  += "ipconfig /flushdns" }
            "run_mru"      { $normalCmds += "Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' -Recurse -Force -ErrorAction SilentlyContinue" }
            "chrome_hist"  { $normalCmds += "Remove-Item -Path '$($item.Path)' -Force -ErrorAction SilentlyContinue" }
            "chrome_cookies" { $normalCmds += "Remove-Item -Path '$($item.Path)' -Force -ErrorAction SilentlyContinue" }
            "edge_hist"    { $normalCmds += "Remove-Item -Path '$($item.Path)' -Force -ErrorAction SilentlyContinue" }
            "edge_cookies" { $normalCmds += "Remove-Item -Path '$($item.Path)' -Force -ErrorAction SilentlyContinue" }
            "ff_hist"      { $normalCmds += "Get-ChildItem '$($item.Path)' -Recurse -Filter 'places.sqlite' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue; Get-ChildItem '$($item.Path)' -Recurse -Filter 'cookies.sqlite' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue" }
            "chkdsk"       { $adminCmds  += "Get-ChildItem 'C:\' -Filter '*.chk' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue" }
            default {
                if ($item.IsSpecial) { continue }
                if (-not $item.Path -or -not (Test-Path $item.Path)) { continue }
                $cmd = "Remove-Item -Path '$($item.Path)\*' -Recurse -Force -ErrorAction SilentlyContinue"
                if ($item.RequiresAdmin) { $adminCmds += $cmd } else { $normalCmds += $cmd }
            }
        }
    }

    if ($normalCmds.Count -gt 0) {
        $block = $normalCmds -join "; "
        try { Invoke-Expression $block 2>$null } catch {}
    }
    if ($adminCmds.Count -gt 0) {
        $block = $adminCmds -join "; "
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -Command `"$block`"" -Verb RunAs -Wait
    }

    return @{ success = $true; message = "Limpieza completada" }
}

# --- Modulo 4: Busqueda PST ---------------------------------------------------

function Search-Files {
    param(
        [string]$Drive    = "C",
        [string[]]$Exts   = @(".pst"),
        [long]$MinSize    = 0,
        [int]$TimeoutSec  = 120
    )
    if (-not (Test-Path "${Drive}:\")) {
        return @{ error = "Unidad $Drive no encontrada" }
    }

    Write-Log "Search-Files START drive=$Drive exts=$($Exts -join ',') minsize=$MinSize"

    $cap      = 2000
    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $rawCount = 0

    foreach ($ext in $Exts) {
        if ($results.Count -ge $cap) { break }
        if ([datetime]::UtcNow -gt $deadline) { Write-Log "  Timeout global"; break }

        $cleanExt = $ext.TrimStart('*')
        if (-not $cleanExt.StartsWith('.')) { $cleanExt = ".$cleanExt" }
        $filter = "*$cleanExt"
        Write-Log "  Buscando: $filter en ${Drive}:\"

        # Get-ChildItem -Filter is filesystem-level fast (same as Win32 FindFirstFile)
        # -ErrorAction SilentlyContinue skips Access Denied folders automatically
        try {
            Get-ChildItem -Path "${Drive}:\" -Filter $filter -Recurse -Force `
                          -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $rawCount++
                if ($rawCount -le 3) { Write-Log "  RAW[$rawCount]: $($_.FullName)" }
                if ($results.Count -lt $cap -and $_.Length -ge $MinSize) {
                    $results.Add([PSCustomObject]@{
                        Name         = $_.Name
                        Ext          = $_.Extension.ToLower()
                        Path         = $_.FullName
                        SizeBytes    = $_.Length
                        SizeDisplay  = (Format-Bytes $_.Length)
                        LastModified = $_.LastWriteTime.ToString("dd/MM/yyyy HH:mm")
                    })
                }
            }
        } catch {
            Write-Log "  Error en $filter : $_"
        }

        Write-Log "  Tras $filter : raw=$rawCount matched=$($results.Count)"
    }

    Write-Log "Search-Files END raw=$rawCount matched=$($results.Count)"
    return @($results | Sort-Object SizeBytes -Descending)
}

function Search-PstFiles {
    param([string]$Drive = "C")
    return Search-Files -Drive $Drive -Exts @(".pst",".ost",".msg",".eml") -MinSize 0
}

function Copy-PstFiles {
    param([string[]]$Files, [string]$Destination)
    if (-not (Test-Path $Destination)) {
        try { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
        catch { return @{ success = $false; error = "No se pudo crear la carpeta destino: $_" } }
    }
    $results = @()
    foreach ($f in $Files) {
        try {
            Copy-Item -Path $f -Destination $Destination -Force -ErrorAction Stop
            $results += @{ file = $f; success = $true }
        } catch {
            $results += @{ file = $f; success = $false; error = $_.Exception.Message }
        }
    }
    return @{ success = $true; results = $results }
}

# --- Modulo: Gestion de Usuarios Locales ------------------------------------

function Get-LocalUsersFull {
    $users = Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object {
        $u = $_
        $groups = @()
        try {
            $groups = (Get-LocalGroup -ErrorAction SilentlyContinue | Where-Object {
                (Get-LocalGroupMember $_ -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$($u.Name)" })
            } | Select-Object -ExpandProperty Name)
        } catch {}
        $isAdmin = $groups -contains "Administradores" -or $groups -contains "Administrators"
        [PSCustomObject]@{
            Name          = $u.Name
            FullName      = $u.FullName
            Enabled       = $u.Enabled
            LastLogon     = if ($u.LastLogon) { $u.LastLogon.ToString("dd/MM/yyyy HH:mm") } else { "Nunca" }
            LastLogonSort = if ($u.LastLogon) { $u.LastLogon.ToString("yyyyMMddHHmmss") } else { "00000000000000" }
            PasswordRequired = $u.PasswordRequired
            PasswordExpires  = if ($u.PasswordExpires) { $u.PasswordExpires.ToString("dd/MM/yyyy") } else { "Nunca" }
            Groups        = ($groups -join ", ")
            IsAdmin       = $isAdmin
            Description   = $u.Description
        }
    } | Sort-Object LastLogonSort -Descending
    return @($users)
}

function New-LocalUserAction {
    param([string]$Username, [string]$FullName, [string]$Password,
          [string]$Description, [bool]$IsAdmin=$false, [bool]$NoPassword=$false)
    $script = if ($NoPassword) {
        "New-LocalUser -Name '$Username' -FullName '$FullName' -Description '$Description' -NoPassword -ErrorAction Stop"
    } else {
        "New-LocalUser -Name '$Username' -FullName '$FullName' -Description '$Description' -Password (ConvertTo-SecureString '$Password' -AsPlainText -Force) -ErrorAction Stop"
    }
    if ($IsAdmin) {
        $script += "; Add-LocalGroupMember -Group 'Administradores' -Member '$Username' -ErrorAction SilentlyContinue"
        $script += "; Add-LocalGroupMember -Group 'Administrators' -Member '$Username' -ErrorAction SilentlyContinue"
    } else {
        $script += "; Add-LocalGroupMember -Group 'Usuarios' -Member '$Username' -ErrorAction SilentlyContinue"
        $script += "; Add-LocalGroupMember -Group 'Users' -Member '$Username' -ErrorAction SilentlyContinue"
    }
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Usuario '$Username' creado correctamente" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Remove-LocalUserAction {
    param([string]$Username)
    $script = "Remove-LocalUser -Name '$Username' -ErrorAction Stop"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Usuario '$Username' eliminado" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Set-LocalUserEnabledAction {
    param([string]$Username, [bool]$Enable)
    $cmd = if ($Enable) { "Enable-LocalUser" } else { "Disable-LocalUser" }
    $script = "$cmd -Name '$Username' -ErrorAction Stop"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; enabled=$Enable }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Set-LocalUserPasswordAction {
    param([string]$Username, [string]$NewPassword)
    $script = "Set-LocalUser -Name '$Username' -Password (ConvertTo-SecureString '$NewPassword' -AsPlainText -Force) -ErrorAction Stop"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Contrasena actualizada para '$Username'" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

# --- Modulo: Copia de Datos ------------------------------------------------------

$global:DataCopyProgressFile = "$env:TEMP\mantendu_copy_progress.json"
$global:DataCopyJob           = $null

function Get-DataCopyPreview {
    param([string[]]$Paths)
    $fileCount = [long]0
    $totalSize = [long]0
    foreach ($p in $Paths) {
        $p = $p.TrimEnd('\')
        if (Test-Path $p -PathType Container) {
            $items = Get-ChildItem -Path $p -Recurse -File -Force -ErrorAction SilentlyContinue
            $fileCount += ($items | Measure-Object).Count
            $totalSize  += ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        } elseif (Test-Path $p -PathType Leaf) {
            $item = Get-Item $p -ErrorAction SilentlyContinue
            if ($item) { $fileCount++; $totalSize += $item.Length }
        }
    }
    return @{
        FileCount    = [long]$fileCount
        TotalBytes   = [long]$totalSize
        TotalDisplay = Format-Bytes $totalSize
    }
}

function Start-DataCopyJob {
    param([string[]]$SourcePaths, [string]$DestPath)

    # Build flat file list with relative paths
    $fileList = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($p in $SourcePaths) {
        $p = $p.TrimEnd('\')
        if (Test-Path $p -PathType Container) {
            $baseDir = Split-Path $p -Parent
            Get-ChildItem -Path $p -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Substring($baseDir.Length).TrimStart('\')
                $fileList.Add(@{ Src = $_.FullName; Rel = $rel })
            }
        } elseif (Test-Path $p -PathType Leaf) {
            $fileList.Add(@{ Src = $p; Rel = Split-Path $p -Leaf })
        }
    }

    $total = $fileList.Count
    $pf    = $global:DataCopyProgressFile

    # Init progress file
    @{ status='running'; total=$total; copied=0; errors=0; currentFile=''; pct=0; done=$false; errorList=@() } |
        ConvertTo-Json -Depth 3 | Set-Content $pf -Encoding UTF8

    $job = Start-Job -ScriptBlock {
        param($files, $dest, $pf)
        $total  = $files.Count
        $copied = 0; $errors = 0; $errList = @()
        foreach ($f in $files) {
            $destFile = Join-Path $dest $f.Rel
            $destDir  = Split-Path $destFile -Parent
            try {
                if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $f.Src -Destination $destFile -Force -ErrorAction Stop
                $copied++
            } catch {
                $errors++
                $errList += @{ file = $f.Src; error = $_.Exception.Message }
            }
            $pct = if ($total -gt 0) { [math]::Round($copied / $total * 100) } else { 100 }
            @{ status='running'; total=$total; copied=$copied; errors=$errors;
               currentFile=$f.Src; pct=$pct; done=$false; errorList=$errList } |
               ConvertTo-Json -Depth 3 -Compress | Set-Content $pf -Encoding UTF8
        }
        $pct = if ($total -gt 0) { [math]::Round($copied / $total * 100) } else { 100 }
        @{ status='done'; total=$total; copied=$copied; errors=$errors;
           currentFile=''; pct=$pct; done=$true; errorList=$errList } |
           ConvertTo-Json -Depth 3 -Compress | Set-Content $pf -Encoding UTF8
    } -ArgumentList ([object[]]$fileList), $DestPath, $pf

    $global:DataCopyJob = $job
    return @{ success=$true; total=$total }
}

function Get-DataCopyProgress {
    try {
        if (Test-Path $global:DataCopyProgressFile) {
            $raw = Get-Content $global:DataCopyProgressFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw) { return $raw | ConvertFrom-Json }
        }
        return @{ status='idle' }
    } catch { return @{ status='error'; error=$_.Exception.Message } }
}

function Stop-DataCopyJob {
    try {
        if ($global:DataCopyJob) {
            Stop-Job  $global:DataCopyJob -ErrorAction SilentlyContinue
            Remove-Job $global:DataCopyJob -Force -ErrorAction SilentlyContinue
            $global:DataCopyJob = $null
        }
        if (Test-Path $global:DataCopyProgressFile) { Remove-Item $global:DataCopyProgressFile -Force -ErrorAction SilentlyContinue }
        return @{ success=$true }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Get-DataCopyVerification {
    param([string[]]$SourcePaths, [string]$DestPath)
    $items = @()
    foreach ($p in $SourcePaths) {
        $p = $p.TrimEnd('\')
        if (Test-Path $p -PathType Container) {
            $baseDir = Split-Path $p -Parent
            Get-ChildItem -Path $p -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $rel      = $_.FullName.Substring($baseDir.Length).TrimStart('\')
                $destFile = Join-Path $DestPath $rel
                $exists   = Test-Path $destFile -PathType Leaf
                $sizeOk   = $false
                if ($exists) {
                    $di = Get-Item $destFile -ErrorAction SilentlyContinue
                    $sizeOk = $di -and ($di.Length -eq $_.Length)
                }
                $items += @{ file=$rel; srcBytes=$_.Length; ok=$sizeOk; exists=$exists }
            }
        } elseif (Test-Path $p -PathType Leaf) {
            $rel      = Split-Path $p -Leaf
            $destFile = Join-Path $DestPath $rel
            $src      = Get-Item $p -ErrorAction SilentlyContinue
            $exists   = Test-Path $destFile -PathType Leaf
            $sizeOk   = $false
            if ($exists -and $src) {
                $di = Get-Item $destFile -ErrorAction SilentlyContinue
                $sizeOk = $di -and ($di.Length -eq $src.Length)
            }
            $items += @{ file=$rel; srcBytes=if($src){$src.Length}else{0}; ok=$sizeOk; exists=$exists }
        }
    }
    $ok     = ($items | Where-Object { $_.ok  }).Count
    $failed = ($items | Where-Object { -not $_.ok }).Count
    return @{ total=$items.Count; ok=$ok; failed=$failed; items=$items }
}

# --- Modulo: Impresoras ----------------------------------------------------------

function Get-PrintersInfo {
    $printers = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
        $p = $_
        $jobCount = 0
        try {
            $jobCount = (Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue | Measure-Object).Count
        } catch {}
        [PSCustomObject]@{
            Name        = [string]$p.Name
            PortName    = [string]$p.PortName
            DriverName  = [string]$p.DriverName
            Default     = [bool]$p.Default
            Shared      = [bool]$p.Shared
            ShareName   = [string]$p.ShareName
            Status      = [int]$p.PrinterStatus
            WorkOffline = [bool]$p.WorkOffline
            JobCount    = [int]$jobCount
            Location    = [string]$p.Location
            Comment     = [string]$p.Comment
        }
    } | Sort-Object { -([int]$_.Default) }
    return @($printers)
}

function Get-PrinterJobsInfo {
    param([string]$PrinterName)
    try {
        $jobs = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{
                Id        = [int]$_.Id
                Document  = [string]$_.DocumentName
                Status    = [string]$_.JobStatus
                Owner     = [string]$_.UserName
                Pages     = [int]$_.TotalPages
                Submitted = if ($_.TimeSubmitted) { $_.TimeSubmitted.ToString("dd/MM/yyyy HH:mm:ss") } else { "—" }
                SizeBytes = [long]$_.Size
                SizeDisp  = Format-Bytes ([long]$_.Size)
            }
        }
        return @($jobs)
    } catch { return @() }
}

function Set-DefaultPrinterAction {
    param([string]$PrinterName)
    try {
        $net = New-Object -ComObject WScript.Network
        $net.SetDefaultPrinter($PrinterName)
        return @{ success=$true; message="Impresora predeterminada: '$PrinterName'" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Remove-PrinterAction {
    param([string]$PrinterName)
    $script = "Remove-Printer -Name '$PrinterName' -ErrorAction Stop"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Impresora '$PrinterName' eliminada" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Clear-PrintQueueAction {
    param([string]$PrinterName)
    $script = "Get-PrintJob -PrinterName '$PrinterName' -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Cola de '$PrinterName' vaciada" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Remove-PrintJobAction {
    param([string]$PrinterName, [int]$JobId)
    $script = "Remove-PrintJob -PrinterName '$PrinterName' -ID $JobId -ErrorAction Stop"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Trabajo $JobId cancelado" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Add-PrinterTCPIPAction {
    param([string]$PrinterName, [string]$IpAddress, [string]$DriverName)
    $portName = "IP_$IpAddress"
    $script = "Add-PrinterPort -Name '$portName' -PrinterHostAddress '$IpAddress' -ErrorAction SilentlyContinue; " +
              "Add-Printer -Name '$PrinterName' -DriverName '$DriverName' -PortName '$portName' -ErrorAction Stop"
    try {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -Command `"$script`"" -Verb RunAs -Wait
        return @{ success=$true; message="Impresora '$PrinterName' añadida correctamente" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Get-PrinterDriversInfo {
    try {
        $drivers = Get-PrinterDriver -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty Name -Unique |
                   Sort-Object
        return @($drivers)
    } catch { return @() }
}

# --- Modulo: Servicios -----------------------------------------------------------

function Get-ServicesInfo {
    $svcs = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Name        = [string]$_.Name
            DisplayName = [string]$_.DisplayName
            Status      = [string]$_.State          # Running, Stopped, Paused
            StartType   = [string]$_.StartMode      # Auto, Manual, Disabled
            Account     = [string]$_.StartName
            Description = [string]$_.Description
            PathName    = [string]$_.PathName
        }
    } | Sort-Object DisplayName
    return @($svcs)
}

function Start-ServiceAction {
    param([string]$ServiceName)
    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
        return @{ success=$true; message="Servicio '$ServiceName' iniciado" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Stop-ServiceAction {
    param([string]$ServiceName)
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        return @{ success=$true; message="Servicio '$ServiceName' detenido" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Restart-ServiceAction {
    param([string]$ServiceName)
    try {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        return @{ success=$true; message="Servicio '$ServiceName' reiniciado" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

function Set-ServiceStartTypeAction {
    param([string]$ServiceName, [string]$StartType)
    # StartType values: Automatic, Manual, Disabled, AutomaticDelayed
    try {
        if ($StartType -eq 'AutomaticDelayed') {
            $script = "Set-Service -Name '$ServiceName' -StartupType Automatic -ErrorAction Stop; " +
                      "Start-Process sc.exe -ArgumentList 'config $ServiceName start= delayed-auto' -Wait -NoNewWindow"
            Invoke-Expression $script
        } else {
            Set-Service -Name $ServiceName -StartupType $StartType -ErrorAction Stop
        }
        return @{ success=$true; message="Tipo de inicio de '$ServiceName' cambiado a '$StartType'" }
    } catch { return @{ success=$false; error=$_.Exception.Message } }
}

# --- Modulo 5: Explorador de ficheros -------------------------------------------

function Get-BrowsePath {
    param([string]$Path)
    if (-not $Path) { $Path = "C:\Users" }
    # Solo quitar backslash final si NO es raíz de unidad (C:\, D:\, etc.)
    if ($Path -notmatch '^[A-Za-z]:\\$') { $Path = $Path.TrimEnd("\") }

    if (-not (Test-Path $Path)) {
        return @{ error = "Ruta no encontrada: $Path" }
    }

    # Parent path: para raíz de unidad no hay parent
    $parent = ""
    if ($Path -notmatch '^[A-Za-z]:\\$') {
        $parent = Split-Path -Parent $Path
        if (-not $parent) { $parent = "" }
    }

    # List items
    $items = @()

    # Folders first
    $dirs = Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            [PSCustomObject]@{
                Name         = $_.Name
                FullPath     = $_.FullName
                Type         = "folder"
                SizeBytes    = -1
                SizeDisplay  = "--"
                Modified     = $_.LastWriteTime.ToString("dd/MM/yyyy HH:mm")
                ModifiedSort = $_.LastWriteTime.ToString("yyyyMMddHHmmss")
            }
        } | Sort-Object Name

    # Files
    $files = Get-ChildItem -Path $Path -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            [PSCustomObject]@{
                Name         = $_.Name
                FullPath     = $_.FullName
                Type         = "file"
                SizeBytes    = $_.Length
                SizeDisplay  = (Format-Bytes $_.Length)
                Modified     = $_.LastWriteTime.ToString("dd/MM/yyyy HH:mm")
                ModifiedSort = $_.LastWriteTime.ToString("yyyyMMddHHmmss")
            }
        } | Sort-Object Name

    $items = @($dirs) + @($files)

    return @{
        currentPath = $Path
        parentPath  = $parent
        items       = $items
        itemCount   = $items.Count
    }
}

function Move-ToRecycleBin {
    param([string[]]$Paths)
    $results = @()
    $shell = New-Object -ComObject Shell.Application

    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) {
            $results += @{ path=$p; success=$false; error="No encontrado" }
            continue
        }
        try {
            # Use Shell namespace to send to recycle bin
            $item = $shell.Namespace(0).ParseName($p)
            if ($item) {
                $item.InvokeVerb("delete")
                $results += @{ path=$p; success=$true }
            } else {
                # Fallback: Remove-Item to recycle bin via Shell FileOperation
                $fo = New-Object -ComObject Shell.Application
                $folder = Split-Path -Parent $p
                $file   = Split-Path -Leaf $p
                $ns = $fo.Namespace($folder)
                if ($ns) {
                    $fi = $ns.ParseName($file)
                    if ($fi) {
                        $fi.InvokeVerb("delete")
                        $results += @{ path=$p; success=$true }
                    } else {
                        throw "No se pudo acceder al elemento"
                    }
                }
            }
        } catch {
            # Last resort: use PowerShell recycle bin via Microsoft.VisualBasic
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $p,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
                $results += @{ path=$p; success=$true }
            } catch {
                # If still fails, try with directory
                try {
                    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        $p,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                    )
                    $results += @{ path=$p; success=$true }
                } catch {
                    $results += @{ path=$p; success=$false; error=$_.Exception.Message }
                }
            }
        }
    }
    return @{ results=$results; total=$Paths.Count; ok=($results | Where-Object { $_.success }).Count }
}

# --- Modulo 5: Red ------------------------------------------------------------

function Get-NetworkAdapters {
    $result = @()
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop
        foreach ($a in $adapters) {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            $ipAddr   = ($ipConfig.IPv4Address | Select-Object -First 1)
            $gw       = ($ipConfig.IPv4DefaultGateway | Select-Object -First 1)
            $dns      = @()
            try {
                $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($dnsObj -and $dnsObj.ServerAddresses) {
                    $dns = @($dnsObj.ServerAddresses)
                }
            } catch { }
            $dhcp = $false
            try {
                $dhcpObj = Get-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                $dhcp = ($dhcpObj.Dhcp -eq 'Enabled')
            } catch { }
            $mask = ""
            if ($ipAddr) {
                try {
                    $prefixLen = [int]$ipAddr.PrefixLength
                    $maskBits  = ([math]::Pow(2,32) - [math]::Pow(2, 32 - $prefixLen))
                    $b1 = [int](($maskBits -shr 24) -band 255)
                    $b2 = [int](($maskBits -shr 16) -band 255)
                    $b3 = [int](($maskBits -shr  8) -band 255)
                    $b4 = [int]( $maskBits           -band 255)
                    $mask = "$b1.$b2.$b3.$b4"
                } catch { }
            }
            $speed = 0
            try { $speed = [long]($a.LinkSpeed / 1000000) } catch { }
            $result += @{
                Name          = [string]$a.Name
                Description   = [string]$a.InterfaceDescription
                Status        = [string]$a.Status
                MacAddress    = [string]$a.MacAddress
                IPAddress     = if ($ipAddr) { [string]$ipAddr.IPAddress } else { "" }
                SubnetMask    = $mask
                Gateway       = if ($gw) { [string]$gw.NextHop } else { "" }
                DnsServers    = $dns
                DhcpEnabled   = $dhcp
                LinkSpeedMbps = $speed
            }
        }
    } catch {
        return @(@{ error = $_.Exception.Message })
    }
    return $result
}

function Invoke-FlushDns {
    try {
        Clear-DnsClientCache -ErrorAction Stop
        return @{ success = $true; message = "Cache DNS vaciada" }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Invoke-ReleaseIP {
    param([string]$AdapterName)
    try {
        $out = & ipconfig /release $AdapterName 2>&1
        return @{ success = $true; output = [string]($out -join "`n") }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Invoke-RenewIP {
    param([string]$AdapterName)
    try {
        $out = & ipconfig /renew $AdapterName 2>&1
        return @{ success = $true; output = [string]($out -join "`n") }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Invoke-PingTest {
    param([string]$TargetHost, [int]$Count = 4)
    try {
        $results = @()
        $pings = Test-Connection -ComputerName $TargetHost -Count $Count -ErrorAction SilentlyContinue
        if ($pings) {
            $seq = 1
            foreach ($p in $pings) {
                $results += @{
                    Seq     = $seq
                    Address = [string]$p.Address
                    Latency = [int]$p.ResponseTime
                    Success = $true
                }
                $seq++
            }
            # If fewer results than requested, fill missing with timeout
            while ($seq -le $Count) {
                $results += @{ Seq=$seq; Address=$TargetHost; Latency=0; Success=$false }
                $seq++
            }
        } else {
            for ($i = 1; $i -le $Count; $i++) {
                $results += @{ Seq=$i; Address=$TargetHost; Latency=0; Success=$false }
            }
        }
        return @{ results = $results }
    } catch {
        return @{ error = $_.Exception.Message }
    }
}

# --- Modulo 6: Monitor de Rendimiento ----------------------------------------

function Get-PerfSnapshot {
    # ============================================================
    # Uses Get-CimInstance (WS-Man, much faster than WMI/DCOM).
    # Static data (CPU name, net adapters) cached globally.
    # Slow queries (disk raw, net raw) cached every tick but only
    # delta-computed when elapsed time > 0.1s.
    # ============================================================
    try {
        $tickStart  = [datetime]::UtcNow
        $elapsedSec = if ($global:PerfLastTick) { ($tickStart - $global:PerfLastTick).TotalSeconds } else { 0 }
        $global:PerfLastTick = $tickStart

        # -- CPU % via CIM (instant, no sampling delay) -----------------------
        $cpuPct     = 0
        $cpuLogical = 1
        try {
            $cpuCim = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
            $cpuPct = [math]::Round(($cpuCim | Measure-Object -Property LoadPercentage -Average).Average, 1)
            $cpuLogical = ($cpuCim | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        } catch { }

        # CPU static (cached forever) ----------------------------------------
        if (-not $global:CpuStatic) {
            try {
                $c = $cpuCim | Select-Object -First 1
                if ($c) {
                    $global:CpuStatic = @{
                        Name    = [string]$c.Name.Trim()
                        Cores   = [int]$c.NumberOfCores
                        Logical = [int]$c.NumberOfLogicalProcessors
                        Freq    = [int]$c.CurrentClockSpeed
                    }
                }
            } catch { }
        }
        $cpuName  = if ($global:CpuStatic) { $global:CpuStatic.Name  } else { "CPU" }
        $cpuCores = if ($global:CpuStatic) { $global:CpuStatic.Cores } else { 0 }
        $cpuFreq  = if ($global:CpuStatic) { $global:CpuStatic.Freq  } else { 0 }

        # -- RAM via CIM (instant) --------------------------------------------
        $ramTotalGB = 0; $ramUsedGB = 0; $ramFreeGB = 0; $ramUsedPct = 0
        $uptimeStr  = "-"
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $ramTotalBytes = [long]$os.TotalVisibleMemorySize * 1024
            $ramFreeBytes  = [long]$os.FreePhysicalMemory  * 1024
            $ramUsedBytes  = $ramTotalBytes - $ramFreeBytes
            $ramUsedPct    = if ($ramTotalBytes -gt 0) { [math]::Round($ramUsedBytes / $ramTotalBytes * 100, 1) } else { 0 }
            $ramTotalGB    = [math]::Round($ramTotalBytes / 1073741824, 2)
            $ramUsedGB     = [math]::Round($ramUsedBytes  / 1073741824, 2)
            $ramFreeGB     = [math]::Round($ramFreeBytes  / 1073741824, 2)
            $uptime        = (Get-Date) - $os.LastBootUpTime
            $uptimeStr     = "{0}d {1:D2}h {2:D2}m" -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes
        } catch { }

        # -- PROCESSES via Get-Process (no WMI at all) ------------------------
        $procCount = 0; $threadCount = 0; $handleCount = 0
        try {
            $psProcs     = Get-Process -ErrorAction SilentlyContinue
            $procCount   = $psProcs.Count
            $threadCount = ($psProcs | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
            $handleCount = ($psProcs | Measure-Object -Property HandleCount -Sum).Sum

            # Snapshot for next delta (store but do not compute top list - not needed without Procesos tab)
            $curSnap = @{}
            foreach ($p in $psProcs) {
                try { $curSnap[[int]$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch { }
            }
            $global:ProcSnapshot     = $curSnap
            $global:ProcSnapshotTime = $tickStart
        } catch { }

        # -- DISK I/O via CIM raw delta ----------------------------------------
        $diskItems = @()
        try {
            $diskRaw  = Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne '_Total' }
            $prevDisk = $global:DiskRaw
            $curDisk  = @{}
            foreach ($d in $diskRaw) { $curDisk[$d.Name] = $d }
            $global:DiskRaw = $curDisk

            foreach ($name in $curDisk.Keys) {
                $cur = $curDisk[$name]
                $readBps = 0; $writeBps = 0
                if ($prevDisk -and $prevDisk.ContainsKey($name) -and $elapsedSec -gt 0.1) {
                    $prev     = $prevDisk[$name]
                    $readBps  = [math]::Max(0, [long](([long]$cur.DiskReadBytesPerSec  - [long]$prev.DiskReadBytesPerSec)  / $elapsedSec))
                    $writeBps = [math]::Max(0, [long](([long]$cur.DiskWriteBytesPerSec - [long]$prev.DiskWriteBytesPerSec) / $elapsedSec))
                }
                $diskItems += @{
                    Name             = "Disco $name"
                    ReadBytesPerSec  = $readBps
                    WriteBytesPerSec = $writeBps
                    ReadPct          = [math]::Min([math]::Round($readBps  / 104857600 * 100, 0), 100)
                    WritePct         = [math]::Min([math]::Round($writeBps / 104857600 * 100, 0), 100)
                }
            }
        } catch { }

        # -- NETWORK I/O via CIM raw delta ------------------------------------
        $netItems = @()
        try {
            $netRaw  = Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue
            $prevNet = $global:NetRaw
            $curNet  = @{}
            foreach ($n in $netRaw) { $curNet[$n.Name] = $n }
            $global:NetRaw = $curNet

            # Friendly name map - cached, refresh every 30 ticks
            $global:NetNameTick = [int]$global:NetNameTick + 1
            if (-not $global:NetNameMap -or $global:NetNameTick -ge 30) {
                $global:NetNameMap  = @{}
                $global:NetNameTick = 0
                try {
                    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
                        $global:NetNameMap[$_.InterfaceDescription] = $_.Name
                    }
                } catch { }
            }

            $skipPattern = 'Loopback|isatap|Teredo|6to4|WAN Miniport|Bluetooth|RAS Async|Virtual|VMware|VirtualBox|Hyper-V'
            foreach ($name in $curNet.Keys) {
                if ($name -match $skipPattern) { continue }
                $cur = $curNet[$name]
                $recvBps = 0; $sentBps = 0
                if ($prevNet -and $prevNet.ContainsKey($name) -and $elapsedSec -gt 0.1) {
                    $prev    = $prevNet[$name]
                    $recvBps = [math]::Max(0, [long](([long]$cur.BytesReceivedPerSec - [long]$prev.BytesReceivedPerSec) / $elapsedSec))
                    $sentBps = [math]::Max(0, [long](([long]$cur.BytesSentPerSec     - [long]$prev.BytesSentPerSec)     / $elapsedSec))
                }
                $friendly = if ($global:NetNameMap -and $global:NetNameMap[$name]) { $global:NetNameMap[$name] } else { $name }
                $netItems += @{
                    Name    = [string]$friendly
                    Desc    = [string]$name
                    RecvBps = $recvBps
                    SentBps = $sentBps
                }
            }
        } catch { }

        $elapsed = [math]::Round(([datetime]::UtcNow - $tickStart).TotalMilliseconds)
        Write-Log "PerfSnapshot OK en $($elapsed)ms"

        return @{
            CpuPct        = $cpuPct
            CpuName       = $cpuName
            CpuCores      = $cpuCores
            CpuLogical    = $cpuLogical
            CpuFreqMhz    = $cpuFreq
            RamTotalGB    = $ramTotalGB
            RamUsedGB     = $ramUsedGB
            RamFreeGB     = $ramFreeGB
            ModifiedGB    = 0
            StandbyGB     = 0
            RamUsedPct    = $ramUsedPct
            UptimeDisplay = $uptimeStr
            ProcessCount  = $procCount
            ThreadCount   = [int]$threadCount
            HandleCount   = [int]$handleCount
            Disks         = @($diskItems)
            TopProcesses  = @()
            Network       = @($netItems)
        }
    } catch {
        Write-Log "PerfSnapshot ERROR: $($_.Exception.Message)"
        return @{ error = $_.Exception.Message }
    }
}

# --- Modulo 7: Task Manager -- Kill Process ------------------------------------

function Stop-ProcessById {
    param([int]$Pid)
    try {
        $proc = Get-Process -Id $Pid -ErrorAction Stop
        $name = $proc.Name
        Stop-Process -Id $Pid -Force -ErrorAction Stop
        return @{ success = $true; pid = $Pid; name = $name }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# --- Modulo 8: Event Viewer ---------------------------------------------------

function Get-EventLogData {
    param(
        [string]$LogName    = "System",
        [int[]]$Level       = @(2),
        [int]$Days          = 1,
        [int]$MaxEvents     = 500,
        [int[]]$Ids         = @(),
        [bool]$CountOnly    = $false
    )
    try {
        $filter = @{
            LogName   = $LogName
            StartTime = (Get-Date).AddDays(-$Days)
        }
        if ($Level -and $Level.Count -gt 0 -and -not ($Ids.Count -gt 0)) {
            $filter['Level'] = $Level
        }
        if ($Ids -and $Ids.Count -gt 0) {
            $filter['Id'] = $Ids
        }

        $rawEvents = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents `
                               -ErrorAction SilentlyContinue
        if (-not $rawEvents) { return @() }

        $events = @($rawEvents | ForEach-Object {
                [PSCustomObject]@{
                    Id              = [int]$_.Id
                    Level           = [int]$_.Level
                    LogName         = [string]$_.LogName
                    ProviderName    = [string]$_.ProviderName
                    MachineName     = [string]$_.MachineName
                    TaskDisplayName = [string]$_.TaskDisplayName
                    TimeCreated     = $_.TimeCreated.ToString("dd/MM/yyyy HH:mm:ss")
                    Message         = if ($_.Message) { [string]$_.Message.Substring(0, [Math]::Min(1000, $_.Message.Length)) } else { "" }
                }
            })

        return $events
    } catch {
        Write-Log "Get-EventLogData ERROR: $($_.Exception.Message)"
        return @{ error = $_.Exception.Message }
    }
}

# --- HTTP Server --------------------------------------------------------------

$LogFile = "C:\WinAdminTool\server_debug.log"
function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "HH:mm:ss.fff"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Set-Content -Path $LogFile -Value "=== WinAdmin Server Log $(Get-Date) ===" -ErrorAction SilentlyContinue
Write-Log "Iniciando servidor en puerto $Port..."
Write-Log "PSVersion: $($PSVersionTable.PSVersion)"
Write-Log "Usuario: $env:USERNAME"

# Reserva URL ACL para HttpListener
Write-Log "Registrando URL ACL..."
try {
    $r = & netsh http add urlacl url="http://localhost:$Port/" user="Everyone" 2>&1
    Write-Log "netsh: $r"
} catch { Write-Log "netsh error (no critico): $_" }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$global:Running = $true

try {
    Write-Log "Llamando listener.Start()..."
    $listener.Start()
    Write-Log "Servidor iniciado correctamente."
    Write-Host ""
    Write-Host "  WinAdmin Tool - Servidor ACTIVO en http://localhost:$Port" -ForegroundColor Cyan
    Write-Host ""

    while ($global:Running -and $listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        if (-not $ctx) { continue }

        $req  = $ctx.Request
        $path = $req.Url.LocalPath
        $meth = $req.HttpMethod

        Write-Host "  -> $meth $path" -ForegroundColor DarkGray

        # OPTIONS preflight
        if ($meth -eq "OPTIONS") {
            $ctx.Response.Headers.Add("Access-Control-Allow-Origin","*")
            $ctx.Response.Headers.Add("Access-Control-Allow-Methods","GET,POST,OPTIONS")
            $ctx.Response.Headers.Add("Access-Control-Allow-Headers","Content-Type")
            $ctx.Response.StatusCode = 200
            $ctx.Response.OutputStream.Close()
            continue
        }

        try {
            switch ($path) {
                # -- Salud --------------------------------------
                "/api/health" {
                    Send-Response $ctx @{ status = "ok"; version = "1.0" }
                }
                # -- Servir index.html --------------------------
                "/" {
                    $htmlPath = Join-Path $ScriptDir "index.html"
                    if (Test-Path $htmlPath) {
                        $html = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
                        Send-Response $ctx $html 200 "text/html; charset=utf-8"
                    } else {
                        Send-Response $ctx "<h1>index.html no encontrado</h1>" 404 "text/html"
                    }
                }
                # -- Modulo 1 -----------------------------------
                "/api/users" {
                    Send-Response $ctx (Get-SystemUsers) -AsArray
                }
                "/api/user-size" {
                    $user = $req.QueryString["username"]
                    Send-Response $ctx (Get-UserSize $user)
                }
                "/api/user-folders" {
                    $user = $req.QueryString["username"]
                    Send-Response $ctx (Get-UserFolders $user) -AsArray
                }
                # -- Modulo 2 -----------------------------------
                "/api/drives" {
                    Send-Response $ctx (Get-DriveList) -AsArray
                }
                "/api/format" {
                    $body = Read-Body $req | ConvertFrom-Json
                    $result = Invoke-FormatDrive -Drive $body.drive -FileSystem $body.filesystem -Label $body.label
                    Send-Response $ctx $result
                }
                # -- Modulo 3 -----------------------------------
                "/api/cleanup-preview" {
                    Send-Response $ctx (Get-CleanupPreview) -AsArray
                }
                "/api/cleanup" {
                    $body   = Read-Body $req | ConvertFrom-Json
                    $result = Invoke-Cleanup -Items $body.items
                    Send-Response $ctx $result
                }
                # -- Modulo 4 -----------------------------------
                "/api/scan-files" {
                    $drive   = $req.QueryString["drive"]
                    if (-not $drive) { $drive = "C" }
                    $extsRaw = $req.QueryString["exts"]
                    $minSize = [long]($req.QueryString["minsize"] -replace '[^\d]','')
                    if (-not $extsRaw) { $extsRaw = ".pst" }
                    $extList = $extsRaw -split ',' |
                               Where-Object { $_ -match '^\.' } |
                               ForEach-Object { $_.Trim() }
                    Write-Log "scan-files: drive=$drive exts=$($extList -join ',') minsize=$minSize"
                    $t0  = [datetime]::UtcNow
                    $res = Search-Files -Drive $drive -Exts $extList -MinSize $minSize -TimeoutSec 90
                    Write-Log "scan-files: devueltos $($res.Count) en $(([datetime]::UtcNow-$t0).TotalSeconds)s"
                    Send-Response $ctx $res -AsArray
                }
                "/api/scan-pst" {
                    $drive = $req.QueryString["drive"]
                    if (-not $drive) { $drive = "C" }
                    Send-Response $ctx (Search-PstFiles -Drive $drive) -AsArray
                }
                "/api/copy-pst" {
                    $body   = Read-Body $req | ConvertFrom-Json
                    $result = Copy-PstFiles -Files $body.files -Destination $body.destination
                    Send-Response $ctx $result
                }
                # -- Cleanup size individual --
                "/api/cleanup-size" {
                    $id = $req.QueryString["id"]
                    Send-Response $ctx (Get-SingleItemSize -Id $id)
                }
                # -- Usuarios locales --
                "/api/local-users" {
                    Send-Response $ctx (Get-LocalUsersFull) -AsArray
                }
                "/api/local-user-create" {
                    $b = Read-Body $req | ConvertFrom-Json
                    $r = New-LocalUserAction -Username $b.username -FullName $b.fullname `
                         -Password $b.password -Description $b.description `
                         -IsAdmin ([bool]$b.isAdmin) -NoPassword ([bool]$b.noPassword)
                    Send-Response $ctx $r
                }
                "/api/local-user-delete" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Remove-LocalUserAction -Username $b.username)
                }
                "/api/local-user-toggle" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Set-LocalUserEnabledAction -Username $b.username -Enable ([bool]$b.enable))
                }
                "/api/local-user-password" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Set-LocalUserPasswordAction -Username $b.username -NewPassword $b.password)
                }
                # -- Explorador --
                "/api/browse" {
                    $path = $req.QueryString["path"]
                    if ($path) { $path = [System.Uri]::UnescapeDataString($path) }
                    Send-Response $ctx (Get-BrowsePath -Path $path)
                }
                "/api/recycle" {
                    $body  = Read-Body $req | ConvertFrom-Json
                    $paths = @($body.paths)
                    Send-Response $ctx (Move-ToRecycleBin -Paths $paths)
                }
                # -- Modulo 5 -- Red ----------------------------
                "/api/network" {
                    Send-Response $ctx (Get-NetworkAdapters) -AsArray
                }
                "/api/flush-dns" {
                    Send-Response $ctx (Invoke-FlushDns)
                }
                "/api/release-ip" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Invoke-ReleaseIP -AdapterName $b.adapter)
                }
                "/api/renew-ip" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Invoke-RenewIP -AdapterName $b.adapter)
                }
                "/api/ping" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Invoke-PingTest -TargetHost $b.host -Count ([int]$b.count))
                }
                # -- Modulo 6 -- Monitor de Rendimiento --------
                "/api/perf" {
                    Send-Response $ctx (Get-PerfSnapshot)
                }
                # -- Modulo 7 -- Task Manager: Kill Process ----
                "/api/kill-process" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Stop-ProcessById -Pid ([int]$b.pid))
                }
             # -- Stop ---------------------------------------
                "/api/evlog" {
                    $logName   = $req.QueryString["log"];    if (-not $logName)  { $logName = "System" }
                    $levelRaw  = $req.QueryString["level"];  if (-not $levelRaw) { $levelRaw = "2" }
                    $days      = [int]($req.QueryString["days"]      -replace '[^\d]',''); if ($days -lt 1) { $days = 1 }
                    $maxEv     = [int]($req.QueryString["maxevents"] -replace '[^\d]',''); if ($maxEv -lt 1) { $maxEv = 500 }
                    $idsRaw    = $req.QueryString["ids"]
                    $countOnly = $req.QueryString["countonly"] -eq "1"
                    $levelArr  = @($levelRaw -split ',' | Where-Object {$_ -match '^\d+$'} | ForEach-Object {[int]$_})
                    $idsArr    = @($idsRaw   -split ',' | Where-Object {$_ -match '^\d+$'} | ForEach-Object {[int]$_})
                    $result    = Get-EventLogData -LogName $logName -Level $levelArr -Days $days -MaxEvents $maxEv -Ids $idsArr -CountOnly $countOnly
                    if ($result -is [hashtable] -and $result.error) {
                        Send-Response $ctx $result
                    } else {
                        Send-Response $ctx $result -AsArray
                    }
                }
                # -- Modulo Copia de Datos ------------------------------
                "/api/datacopy-preview" {
                    $b = Read-Body $req | ConvertFrom-Json
                    $paths = @($b.paths)
                    Send-Response $ctx (Get-DataCopyPreview -Paths $paths)
                }
                "/api/datacopy-start" {
                    $b = Read-Body $req | ConvertFrom-Json
                    $sources = @($b.sources)
                    $dest    = [string]$b.dest
                    Send-Response $ctx (Start-DataCopyJob -SourcePaths $sources -DestPath $dest)
                }
                "/api/datacopy-progress" {
                    Send-Response $ctx (Get-DataCopyProgress)
                }
                "/api/datacopy-cancel" {
                    Send-Response $ctx (Stop-DataCopyJob)
                }
                "/api/datacopy-verify" {
                    $b = Read-Body $req | ConvertFrom-Json
                    $sources = @($b.sources)
                    $dest    = [string]$b.dest
                    Send-Response $ctx (Get-DataCopyVerification -SourcePaths $sources -DestPath $dest)
                }
                # -- Modulo Servicios -----------------------------------
                "/api/services" {
                    Send-Response $ctx (Get-ServicesInfo) -AsArray
                }
                "/api/service-start" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Start-ServiceAction -ServiceName $b.service)
                }
                "/api/service-stop" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Stop-ServiceAction -ServiceName $b.service)
                }
                "/api/service-restart" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Restart-ServiceAction -ServiceName $b.service)
                }
                "/api/service-starttype" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Set-ServiceStartTypeAction -ServiceName $b.service -StartType $b.startType)
                }
                # -- Modulo Impresoras ----------------------------------
                "/api/printers" {
                    Send-Response $ctx (Get-PrintersInfo) -AsArray
                }
                "/api/printer-jobs" {
                    $pn = $req.QueryString["printer"]
                    if ($pn) { $pn = [System.Uri]::UnescapeDataString($pn) }
                    Send-Response $ctx (Get-PrinterJobsInfo -PrinterName $pn) -AsArray
                }
                "/api/printer-set-default" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Set-DefaultPrinterAction -PrinterName $b.printer)
                }
                "/api/printer-delete" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Remove-PrinterAction -PrinterName $b.printer)
                }
                "/api/printer-clear-queue" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Clear-PrintQueueAction -PrinterName $b.printer)
                }
                "/api/printer-cancel-job" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Remove-PrintJobAction -PrinterName $b.printer -JobId ([int]$b.jobId))
                }
                "/api/printer-add" {
                    $b = Read-Body $req | ConvertFrom-Json
                    Send-Response $ctx (Add-PrinterTCPIPAction -PrinterName $b.name -IpAddress $b.ip -DriverName $b.driver)
                }
                "/api/printer-drivers" {
                    Send-Response $ctx (Get-PrinterDriversInfo) -AsArray
                }
                "/api/stop" {
                    Send-Response $ctx @{ message = "Servidor detenido" }
                    $global:Running = $false
                    $listener.Stop()
                }
                default {
                    Send-Response $ctx @{ error = "Endpoint no encontrado: $path" } 404
                }
            }
        } catch {
            Write-Host "  [ERROR] $path -> $_" -ForegroundColor Red
            try { Send-Response $ctx @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} catch {
    Write-Log "ERROR CRITICO al iniciar servidor: $_"
    Write-Log "Tipo de error: $($_.Exception.GetType().FullName)"
    Write-Log "Mensaje: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "ERROR: No se pudo iniciar el servidor." -ForegroundColor Red
    Write-Host "Revisa C:\WinAdminTool\server_debug.log" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Presiona Enter para cerrar"
} finally {
    try { $listener.Stop() } catch { }
    Write-Log "Servidor detenido."
    Write-Host "Servidor WinAdmin detenido." -ForegroundColor Yellow
}
