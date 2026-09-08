# Clash Verge 中间节点选择器
# 仅访问本机 Clash Verge 配置目录；不会上传订阅、节点或代理凭据。

$ErrorActionPreference = 'Stop'

function Get-ClashVergeDataDirectory {
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'io.github.clash-verge-rev.clash-verge-rev'),
        (Join-Path $env:USERPROFILE 'AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev')
    ) | Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    }
    throw '未找到 Clash Verge Rev 数据目录。请先启动 Clash Verge Rev，并确认它已创建配置。'
}

function ConvertFrom-YamlScalar {
    param([string]$Value)
    $Value = $Value.Trim()
    if ($Value.Length -ge 2 -and $Value[0] -eq "'" -and $Value[$Value.Length - 1] -eq "'") {
        return $Value.Substring(1, $Value.Length - 2).Replace("''", "'")
    }
    if ($Value.Length -ge 2 -and $Value[0] -eq '"' -and $Value[$Value.Length - 1] -eq '"') {
        return $Value.Substring(1, $Value.Length - 2)
    }
    return $Value.Trim()
}

function Get-YamlValue {
    param([string[]]$Lines, [string]$Key)
    $keyPattern = [regex]::Escape($Key)
    foreach ($line in $Lines) {
        if ($line -match ("^\s*(?:-\s+)?" + $keyPattern + "\s*:\s*(?<value>[^#\r\n]+?)(?:\s+#.*)?\s*$")) {
            return ConvertFrom-YamlScalar $Matches['value']
        }
        if ($line -match ('(?:^|[,{])\s*' + $keyPattern + '\s*:\s*(?<value>''(?:[^'']|'''')*''|"[^"]*"|[^,}]+)')) {
            return ConvertFrom-YamlScalar $Matches['value']
        }
    }
    return $null
}

function Get-CurrentProfile {
    param([string]$ProfilesPath)
    $lines = Get-Content -LiteralPath $ProfilesPath -Encoding UTF8
    $current = Get-YamlValue -Lines $lines -Key 'current'
    if ([string]::IsNullOrWhiteSpace($current)) { throw 'profiles.yaml 中没有可用的 current 配置。' }
    return @{ Uid = $current; Lines = $lines }
}

function Get-EnhancementName {
    param([string[]]$ProfilesLines, [string]$Uid)
    $inProfile = $false
    foreach ($line in $ProfilesLines) {
        if ($line -match '^\s*-\s+uid:\s*["'']?(.+?)["'']?\s*$') {
            if ($inProfile) { break }
            $inProfile = ($Matches[1].Trim() -eq $Uid)
            continue
        }
        if ($inProfile -and $line -match '^\s+proxies:\s*["'']?(.+?)["'']?\s*$') {
            return $Matches[1].Trim()
        }
    }
    return "$Uid`_proxies"
}

function Get-ProxyNodes {
    param([string]$SubscriptionPath)
    $lines = Get-Content -LiteralPath $SubscriptionPath -Encoding UTF8
    $blocks = New-Object System.Collections.Generic.List[object]
    $block = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s*-\s+(?:\{|name\s*:|type\s*:)') {
            if ($block.Count -gt 0) { $blocks.Add($block.ToArray()); $block.Clear() }
        }
        if ($block.Count -gt 0 -or $line -match '^\s*-\s+(?:\{|name\s*:|type\s*:)') { $block.Add($line) }
    }
    if ($block.Count -gt 0) { $blocks.Add($block.ToArray()) }

    $nodes = foreach ($candidate in $blocks) {
        $name = Get-YamlValue -Lines $candidate -Key 'name'
        $server = Get-YamlValue -Lines $candidate -Key 'server'
        $portText = Get-YamlValue -Lines $candidate -Key 'port'
        $port = 0
        if ($name -and $server -and [int]::TryParse($portText, [ref]$port) -and $port -gt 0 -and $port -le 65535) {
            if ($server -notin @('update.microsoft.com', '1.1.1.1')) {
                [pscustomobject]@{ Name = $name; Server = $server; Port = $port }
            }
        }
    }
    return @($nodes | Sort-Object Name -Unique)
}

function Test-TcpLatency {
    param([string]$Server, [int]$Port, [int]$TimeoutMs = 2500)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $task = $client.ConnectAsync($Server, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) { $watch.Stop(); return [int]$watch.ElapsedMilliseconds }
    } catch { }
    finally { $client.Dispose() }
    return $null
}

function ConvertTo-YamlSingleQuoted {
    param([string]$Value)
    if ($null -eq $Value) { return "''" }
    if ($Value -match "[\r\n]") { throw '输入内容不能包含换行。' }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Read-ExitProxy {
    $raw = (Read-Host '出口地址（例如 socks5://user:pass@1.2.3.4:443）').Trim()
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match "[\r\n]") { throw '出口地址不能为空，且不能包含换行。' }
    $scheme = $null
    if ($raw -match '^(socks5|http|https)://') { $scheme = $Matches[1].ToLowerInvariant() }
    $typeAnswer = if ($scheme) { $scheme } else { (Read-Host '出口类型：1=socks5，2=http（默认 1）').Trim() }
    $type = if ($typeAnswer -in @('2', 'http', 'https')) { 'http' } else { 'socks5' }
    $uriText = if ($scheme) { $raw } else { "${type}://$raw" }
    try { $uri = [Uri]$uriText } catch { throw '无法解析出口地址。IPv6 请使用方括号，例如 [2001:db8::1]:443。' }
    if (-not $uri.Host) { throw '出口地址缺少服务器地址。' }
    $port = if ($uri.IsDefaultPort -or $uri.Port -lt 1) { 443 } else { $uri.Port }
    if ($port -gt 65535) { throw '端口必须在 1 到 65535 之间。' }
    $username = ''; $password = ''
    if ($uri.UserInfo) {
        $parts = $uri.UserInfo.Split(':', 2)
        $username = [Uri]::UnescapeDataString($parts[0])
        if ($parts.Count -gt 1) { $password = [Uri]::UnescapeDataString($parts[1]) }
    }
    $name = (Read-Host '备注名（默认 ExitNode）').Trim()
    if (-not $name) { $name = 'ExitNode' }
    if ($name -match "[\r\n]") { throw '备注名不能包含换行。' }
    return [pscustomobject]@{ Type = $type; Server = $uri.Host; Port = $port; Username = $username; Password = $password; Name = $name }
}

function Remove-NamedProxy {
    param([string[]]$Lines, [string]$Name)
    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count;) {
        if ($Lines[$i] -match '^\s{2,}-\s+') {
            $end = $i + 1
            while ($end -lt $Lines.Count -and $Lines[$end] -notmatch '^\s{2,}-\s+') { $end++ }
            $entry = @($Lines[$i..($end - 1)])
            if ((Get-YamlValue -Lines $entry -Key 'name') -ne $Name) { foreach ($entryLine in $entry) { $result.Add($entryLine) } }
            $i = $end
        } else { $result.Add($Lines[$i]); $i++ }
    }
    return @($result)
}

function Update-EnhancementFile {
    param([string]$Path, [pscustomobject]$ExitProxy, [string]$MiddleName)
    $newEntry = @(
        "  - type: $(ConvertTo-YamlSingleQuoted $ExitProxy.Type)",
        "    name: $(ConvertTo-YamlSingleQuoted $ExitProxy.Name)",
        "    server: $(ConvertTo-YamlSingleQuoted $ExitProxy.Server)",
        "    port: $($ExitProxy.Port)"
    )
    if ($ExitProxy.Username) { $newEntry += "    username: $(ConvertTo-YamlSingleQuoted $ExitProxy.Username)" }
    if ($ExitProxy.Password) { $newEntry += "    password: $(ConvertTo-YamlSingleQuoted $ExitProxy.Password)" }
    if ($MiddleName) { $newEntry += "    dialer-proxy: $(ConvertTo-YamlSingleQuoted $MiddleName)" }
    if (Test-Path -LiteralPath $Path) {
        $original = Get-Content -LiteralPath $Path -Encoding UTF8
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        Copy-Item -LiteralPath $Path -Destination "$Path.$stamp.bak" -Force
    } else { $original = @() }
    $sectionIndices = @{}
    for ($i = 0; $i -lt $original.Count; $i++) {
        if ($original[$i] -match '^(prepend|append|delete):\s*(?:\[\])?\s*$') { $sectionIndices[$Matches[1]] = $i }
    }
    if ($sectionIndices.Count -gt 0 -and $sectionIndices.Count -ne 3) { throw '增强配置的 prepend / append / delete 段不完整，已停止写入以保护原文件。' }
    if ($sectionIndices.Count -eq 3) {
        $prependIndex = $sectionIndices['prepend']; $appendIndex = $sectionIndices['append']; $deleteIndex = $sectionIndices['delete']
        if ($prependIndex -gt $appendIndex -or $appendIndex -gt $deleteIndex) { throw '增强配置段落顺序异常，已停止写入以保护原文件。' }
        $header = if ($prependIndex -gt 0) { @($original[0..($prependIndex - 1)]) } else { @() }
        $prepend = if ($appendIndex -gt $prependIndex + 1) { @($original[($prependIndex + 1)..($appendIndex - 1)]) } else { @() }
        $append = if ($deleteIndex -gt $appendIndex + 1) { @($original[($appendIndex + 1)..($deleteIndex - 1)]) } else { @() }
        $tail = @($original[$deleteIndex..($original.Count - 1)])
    } else {
        $header = @('# Profile Enhancement Proxies for Clash Verge', '')
        $prepend = @(); $append = @(); $tail = @('delete: []')
    }
    $prepend = Remove-NamedProxy -Lines $prepend -Name $ExitProxy.Name
    $append = Remove-NamedProxy -Lines $append -Name $ExitProxy.Name
    $updated = @($header) + @('prepend:') + @($newEntry) + @($prepend) + @('')
    if ($append.Count -gt 0) { $updated += @('append:') + @($append) } else { $updated += 'append: []' }
    $updated += @('') + @($tail)
    $tempPath = "$Path.tmp"
    try { $updated | Set-Content -LiteralPath $tempPath -Encoding UTF8; Move-Item -LiteralPath $tempPath -Destination $Path -Force }
    finally { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force } }
}

try {
    Write-Host ''; Write-Host '============================================================'; Write-Host '  Clash Verge 中间节点选择器'; Write-Host '============================================================'
    $dataDirectory = Get-ClashVergeDataDirectory
    $profilesPath = Join-Path $dataDirectory 'profiles.yaml'
    if (-not (Test-Path -LiteralPath $profilesPath)) { throw '未找到 profiles.yaml。' }
    $profile = Get-CurrentProfile -ProfilesPath $profilesPath
    $subscriptionPath = Join-Path $dataDirectory ("profiles\{0}.yaml" -f $profile.Uid)
    if (-not (Test-Path -LiteralPath $subscriptionPath)) { throw "未找到当前订阅文件：$subscriptionPath" }
    Write-Host "当前订阅：$($profile.Uid)"; Write-Host '正在测试节点 TCP 连接（每个不可达节点最多等待约 2.5 秒）...'
    $nodes = Get-ProxyNodes -SubscriptionPath $subscriptionPath
    if ($nodes.Count -eq 0) { throw '未能从当前订阅中识别出可测速的节点。' }
    $tested = for ($i = 0; $i -lt $nodes.Count; $i++) { $node = $nodes[$i]; [pscustomobject]@{ Index = $i + 1; Latency = Test-TcpLatency -Server $node.Server -Port $node.Port; Name = $node.Name } }
    $shown = @($tested | Sort-Object @{ Expression = { if ($null -eq $_.Latency) { [int]::MaxValue } else { $_.Latency } } }, Name)
    Write-Host ''; Write-Host '编号 | 延迟     | 节点名称'; Write-Host '------------------------------------------------------------'
    foreach ($item in $shown) { $latencyText = if ($null -eq $item.Latency) { '超时' } else { "$($item.Latency) ms" }; Write-Host ('{0,-4} | {1,-8} | {2}' -f $item.Index, $latencyText, $item.Name) }
    Write-Host '------------------------------------------------------------'
    $middleName = ''; $answer = (Read-Host '选择中间节点编号（直接回车则不使用中间节点）').Trim()
    if ($answer) {
        $selectedIndex = 0
        if (-not [int]::TryParse($answer, [ref]$selectedIndex)) { throw '中间节点编号必须是数字。' }
        $selected = $tested | Where-Object Index -eq $selectedIndex | Select-Object -First 1
        if (-not $selected) { throw "未找到编号为 $selectedIndex 的节点。" }
        $middleName = $selected.Name; Write-Host "已选中间节点：$middleName"
    }
    $exitProxy = Read-ExitProxy
    $enhancementName = Get-EnhancementName -ProfilesLines $profile.Lines -Uid $profile.Uid
    $enhancementPath = Join-Path $dataDirectory ("profiles\{0}.yaml" -f $enhancementName)
    Update-EnhancementFile -Path $enhancementPath -ExitProxy $exitProxy -MiddleName $middleName
    Write-Host ''; Write-Host '完成：出口代理已写入 prepend 段。'; Write-Host "配置文件：$enhancementPath"; Write-Host "备份文件：$enhancementPath.bak（另保留一份带时间戳的备份）"; Write-Host '请重启 Clash Verge 使配置生效。'
    exit 0
} catch { Write-Host ''; Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
