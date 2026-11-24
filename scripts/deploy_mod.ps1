<#
.SYNOPSIS
    将 Civ5AgentBridge/mod 部署到游戏 MODS/Civ5AgentBridge 目录。
.DESCRIPTION
    默认检查目标路径是否为指向仓库 mod/ 的 NTFS 目录联接（Junction）；
    若需改用物理拷贝模式（例如游戏版本不识别联接时），可传入 -ForceCopy。
    修改 .modinfo 入口或文件清单后，可传入 -ClearCache 清理游戏缓存数据库。
#>
param(
    [switch]$ForceCopy,
    [switch]$ClearCache
)

$ErrorActionPreference = "Stop"

# 计算仓库根目录、Mod 源码目录与游戏根目录
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Civ5UserRoot = Split-Path -Parent $RepoRoot
$SourceModDir = Join-Path $RepoRoot "mod"
$TargetModDir = Join-Path $Civ5UserRoot "MODS\Civ5AgentBridge"

<#
.SYNOPSIS
    检查指定路径是否为重解析点（如 NTFS 目录联接）。
.PARAMETER Path
    待检查的目录路径。
#>
function Test-IsReparsePoint {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

<#
.SYNOPSIS
    清理游戏 cache 目录下的 Civ5*.db 缓存文件，确保 modinfo 变更生效。
.PARAMETER UserRoot
    文明5用户数据根目录。
#>
function Clear-Civ5ModCache {
    param([string]$UserRoot)
    $cacheDir = Join-Path $UserRoot "cache"
    if (-not (Test-Path $cacheDir)) {
        return
    }
    $dbFiles = Get-ChildItem -Path $cacheDir -Filter "Civ5*.db" -File -ErrorAction SilentlyContinue
    foreach ($file in $dbFiles) {
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Host "[Cache] 已清理缓存: $($file.Name)"
    }
}

if (-not (Test-Path $SourceModDir)) {
    throw "未找到 Mod 源码目录: $SourceModDir"
}

if ($ForceCopy) {
    # 若当前为目录联接，先移除联接点再创建实体目录，避免覆盖源码自身
    if (Test-IsReparsePoint -Path $TargetModDir) {
        (Get-Item -LiteralPath $TargetModDir -Force).Delete()
        Write-Host "[Deploy] 已移除原有目录联接: $TargetModDir"
    }
    if (-not (Test-Path $TargetModDir)) {
        New-Item -ItemType Directory -Path $TargetModDir -Force | Out-Null
    }

    # 使用 robocopy /MIR 单向镜像同步（robocopy 返回码 < 8 均为正常）
    & robocopy $SourceModDir $TargetModDir /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy 同步失败，退出码: $LASTEXITCODE"
    }
    Write-Host "[Deploy] 已镜像同步 Mod 文件到: $TargetModDir"
}
else {
    if (Test-IsReparsePoint -Path $TargetModDir) {
        Write-Host "[Deploy] 当前已处于目录联接模式，Mod 源码与游戏目录实时同步，无需拷贝。"
    }
    elseif (Test-Path $TargetModDir) {
        Write-Warning "[Deploy] 目标路径已是普通实体目录。如需覆盖同步请使用 -ForceCopy。"
    }
    else {
        New-Item -ItemType Junction -Path $TargetModDir -Target $SourceModDir | Out-Null
        Write-Host "[Deploy] 已建立目录联接: $TargetModDir -> $SourceModDir"
    }
}

if ($ClearCache) {
    Clear-Civ5ModCache -UserRoot $Civ5UserRoot
}
