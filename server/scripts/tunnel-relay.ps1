<#
.SYNOPSIS
    在 Windows 上启动 CloudTerminal 中继（--local-relay 模式），并打印手机可用的地址。

.DESCRIPTION
    Agent 进程内启动中继，因此无需 Docker、无需公网端口。脚本只负责：
      * 校验 Node 版本和依赖；
      * 计算本机局域网 IP，给出手机应填写的 ws:// 地址；
      * 以 argv 数组（shell:false）方式启动 Agent。

    脚本绝不打印注册密钥、配对 secret 或其他凭证。配对码由 Agent 自己在
    运行时横幅中显示；注册密钥是进程内随机生成的，仅存在内存里。

.PARAMETER Port
    中继监听端口，默认 8787。

.PARAMETER PublicUrl
    手机直接用另一个入口（例如 Cloudflare Tunnel 或 Tailscale）时，
    传给 Agent 的 --public-url，横幅里会显示这个地址。
    例如 -PublicUrl 'wss://relay.example.com/ws'。

.PARAMETER Root
    允许手机访问的目录，可重复。默认交给 Agent（用户主目录）。

.PARAMETER NoTerminal
    不接管桌面终端（后台 / 服务方式运行时使用）。

.PARAMETER WhatIf
    只打印将要执行的命令和预期地址，不真正启动进程。

.EXAMPLE
    pwsh -File server/scripts/tunnel-relay.ps1

.EXAMPLE
    pwsh -File server/scripts/tunnel-relay.ps1 -Port 8788 -PublicUrl 'wss://relay.example.com/ws'

.EXAMPLE
    pwsh -File server/scripts/tunnel-relay.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8787,

    [string]$PublicUrl,

    [string[]]$Root,

    [switch]$NoTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- 定位仓库 -------------------------------------------------------------
# 脚本位于 server/scripts/，往上两级是 server/，再往上是仓库根目录。
$serverDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $serverDir
$agentEntry = Join-Path $serverDir 'src/agent/main.ts'

function Write-Info([string]$Message) { Write-Host $Message }
function Write-Head([string]$Message) { Write-Host "`n$Message" -ForegroundColor Cyan }

Write-Head 'CloudTerminal 本地中继（--local-relay）'

if (-not (Test-Path -LiteralPath $agentEntry)) {
    throw "找不到 Agent 入口：$agentEntry（请确认脚本仍在 server/scripts/ 下）"
}

# ---- 校验 Node ------------------------------------------------------------
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $nodeExe) {
    throw '未找到 Node.js。请安装 Node.js 24 LTS 后重试：https://nodejs.org/'
}
$nodeVersion = (& $nodeExe --version).TrimStart('v')
$nodeMajor, $nodeMinor = ($nodeVersion -split '\.')[0..1] | ForEach-Object { [int]$_ }
$nodeOk = ($nodeMajor -gt 23) -or ($nodeMajor -eq 23 -and $nodeMinor -ge 6)
if (-not $nodeOk) {
    throw "Node.js 版本过低（当前 $nodeVersion，需要 >= 23.6）。请升级到 Node.js 24 LTS。"
}

# 原生模块 node-pty 必须已安装，否则 Agent 无法创建终端。
$ptyManifest = Join-Path $serverDir 'node_modules/node-pty/package.json'
if (-not (Test-Path -LiteralPath $ptyManifest)) {
    Write-Info "依赖未安装，正在执行 npm ci（位于 $serverDir）..."
    if ($PSCmdlet.ShouldProcess($serverDir, 'npm ci')) {
        Push-Location $serverDir
        try {
            & npm ci
            if ($LASTEXITCODE -ne 0) { throw "npm ci 失败（退出码 $LASTEXITCODE）" }
        }
        finally { Pop-Location }
    }
}

# ---- 计算可用地址 ---------------------------------------------------------
function Get-LanIpv4 {
    # 优先取已启用、非虚拟、有网关的物理网卡的 IPv4。
    try {
        $candidates = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object {
                $_.NetAdapter.Status -eq 'Up' -and
                $_.IPv4DefaultGateway -ne $null -and
                $_.NetAdapter.Virtual -eq $false
            } |
            ForEach-Object { $_.IPv4Address.IPAddress } |
            Where-Object { $_ -and $_ -notlike '169.254.*' }
        return $candidates | Select-Object -First 1
    }
    catch {
        # 回退：不依赖 NetTCPIP 模块的通用方式。
        $fallback = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.IsLoopback } |
            ForEach-Object { $_.Address.IPAddress } |
            Where-Object { $_ -notlike '169.254.*' }
        return $fallback | Select-Object -First 1
    }
}

$lanIp = Get-LanIpv4
$loopbackUrl = "ws://127.0.0.1:$Port/ws"
$lanUrl = if ($lanIp) { "ws://${lanIp}:$Port/ws" } else { $null }
$bannerUrl = if ($PublicUrl) { $PublicUrl } elseif ($lanUrl) { $lanUrl } else { $loopbackUrl }

# ---- 组装 argv（shell:false） --------------------------------------------
$agentArgs = @('src/agent/main.ts', '--local-relay', '--port', "$Port")
foreach ($dir in @($Root)) {
    if ($dir) { $agentArgs += @('--root', $dir) }
}
if ($NoTerminal) { $agentArgs += '--no-terminal' }
if ($PublicUrl) { $agentArgs += @('--public-url', $PublicUrl) }

# ---- 打印 ----------------------------------------------------------------
Write-Info "  仓库根目录 : $repoRoot"
Write-Info "  Agent      : $agentEntry"
Write-Info "  Node       : v$nodeVersion"
Write-Info "  监听端口   : $Port (0.0.0.0)"

Write-Head '手机 / 电脑填写的地址'
if ($lanUrl) { Write-Info "  [推荐] 局域网     : $lanUrl" }
Write-Info   "  [本机自测] 回环   : $loopbackUrl"
if ($PublicUrl) { Write-Info "  [隧道/公网] 对外  : $PublicUrl" }
if (-not $lanUrl) {
    Write-Warning ' 未能识别局域网 IP；手机请改用隧道地址（-PublicUrl）或本机回环地址。'
}

Write-Head '配对提示'
Write-Info '  * 手机填上面的服务器地址（局域网用 ws://，公网隧道用 wss://，结尾必须是 /ws）。'
Write-Info '  * 启动后 Agent 横幅会显示一次性配对码；电脑用注册密钥（本脚本为进程内随机，不显示）。'
Write-Info '  * 保持本窗口运行，手机才能连接；Ctrl-C 退出。'
Write-Info '  * 防火墙需放行与此机同网段客户端访问 TCP 端口。'

# ---- 启动 ----------------------------------------------------------------
Write-Head '启动命令（argv 数组，shell:false）'
$displayArgs = ($agentArgs | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
Write-Info "  & node $displayArgs"

if (-not $PSCmdlet.ShouldProcess($agentEntry, "启动本地中继 (--local-relay, port $Port)")) {
    Write-Head 'WhatIf：未启动进程，以上地址即为预期结果。'
    return
}

Push-Location $serverDir
try {
    # 使用 argv 数组调用，参数不经 shell 拼接，避免注入与转义问题。
    & $nodeExe @agentArgs
    exit $LASTEXITCODE
}
finally { Pop-Location }
