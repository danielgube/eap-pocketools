[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Source = ".",

    [Alias("o")]
    [string]$Output,

    [Alias("l")]
    [switch]$List,

    [Alias("h")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-ZipMeHelp {
    @"
ZipMe - empaqueta un proyecto sin artefactos reconstruibles

Uso:
  zipme [ruta] [-Output archivo.7z|archivo.zip] [-List]
  zipme --help

Sin argumentos crea <proyecto>.7z dentro del proyecto. Si existe un
.gitignore usa sus reglas; en caso contrario excluye targets, builds,
dependencias descargadas, caches, archivos de IDE y metadatos VCS.

Opciones:
  -Output, -o   Ruta del archivo resultante (.7z o .zip).
  -List, -l     Muestra los archivos seleccionados sin comprimir.
  -Help, -h     Muestra esta ayuda.
"@ | Write-Output
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals(
        $fullPath.TrimEnd("\"),
        $volumeRoot.TrimEnd("\"),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        return $volumeRoot
    }
    return $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [string]::Equals(
        (Get-NormalizedFullPath $Left),
        (Get-NormalizedFullPath $Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][IO.FileSystemInfo]$Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-RelativeProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullName
    )

    $prefix = $Root.TrimEnd("\") + "\"
    if (-not $FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "La ruta queda fuera del proyecto: $FullName"
    }
    return $FullName.Substring($prefix.Length).Replace("\", "/")
}

function Test-PathHasSegment {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][Collections.Generic.HashSet[string]]$Names
    )

    foreach ($segment in $RelativePath.Split("/")) {
        if ($Names.Contains($segment)) {
            return $true
        }
    }
    return $false
}

function Get-ProjectFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][bool]$UseDefaultExclusions
    )

    $alwaysExcluded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    @(".git", ".svn", ".hg") | ForEach-Object {
        [void]$alwaysExcluded.Add($_)
    }

    $defaultDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    @(
        "target", "node_modules", "dist", "build", "out", "bin", "obj",
        ".gradle", ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        "__pycache__", ".tox", ".nox", ".venv", "venv", ".next", ".nuxt",
        ".angular", ".parcel-cache", "coverage", "htmlcov", "TestResults",
        ".idea", ".vscode", ".vs", ".settings", ".metadata", "Servers"
    ) | ForEach-Object { [void]$defaultDirectories.Add($_) }

    $defaultFileNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    @(
        ".project", ".classpath", ".coverage", ".DS_Store", "Thumbs.db"
    ) | ForEach-Object { [void]$defaultFileNames.Add($_) }

    $defaultExtensions = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    @(".class", ".pyc", ".pyo", ".suo", ".user", ".log", ".tmp") |
        ForEach-Object { [void]$defaultExtensions.Add($_) }

    $result = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($Root))

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $children = $directory.GetFileSystemInfos()
        }
        catch {
            throw "No se puede leer $($directory.FullName): $($_.Exception.Message)"
        }

        foreach ($item in $children) {
            if (Test-ReparsePoint $item) {
                continue
            }
            if ($item -is [IO.DirectoryInfo]) {
                if ($alwaysExcluded.Contains($item.Name)) {
                    continue
                }
                if ($UseDefaultExclusions -and $defaultDirectories.Contains($item.Name)) {
                    continue
                }
                $pending.Push($item)
                continue
            }
            if ($UseDefaultExclusions) {
                if ($defaultFileNames.Contains($item.Name)) {
                    continue
                }
                if ($defaultExtensions.Contains($item.Extension)) {
                    continue
                }
            }
            $result.Add([pscustomobject]@{
                FullName = $item.FullName
                Relative = Get-RelativeProjectPath -Root $Root -FullName $item.FullName
            })
        }
    }

    return @($result | Sort-Object { $_.Relative.ToLowerInvariant() })
}

function Get-GitIgnoredSelection {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$GitExecutable,
        [Parameter(Mandatory = $true)][string]$TemporaryRoot
    )

    $gitDirectory = Join-Path $TemporaryRoot ("zipme-git-" + [Guid]::NewGuid().ToString("N"))
    try {
        & $GitExecutable init --bare --quiet $gitDirectory 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $raw = & $GitExecutable `
            "--git-dir=$gitDirectory" `
            "--work-tree=$Root" `
            -c core.excludesFile=NUL `
            ls-files --others --exclude-standard -z 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        if ($null -eq $raw) {
            return @()
        }
        return @($raw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
    }
    finally {
        if (Test-Path -LiteralPath $gitDirectory) {
            Remove-Item -LiteralPath $gitDirectory -Recurse -Force
        }
    }
}

function Convert-GitIgnoreGlobToRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $builder = [Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Pattern.Length) {
        $character = $Pattern[$index]
        if ($character -eq "\" -and ($index + 1) -lt $Pattern.Length) {
            $index++
            [void]$builder.Append([Regex]::Escape([string]$Pattern[$index]))
        }
        elseif ($character -eq "*") {
            if (($index + 1) -lt $Pattern.Length -and $Pattern[$index + 1] -eq "*") {
                while (($index + 1) -lt $Pattern.Length -and $Pattern[$index + 1] -eq "*") {
                    $index++
                }
                if (($index + 1) -lt $Pattern.Length -and $Pattern[$index + 1] -eq "/") {
                    $index++
                    [void]$builder.Append("(?:.*/)?")
                }
                else {
                    [void]$builder.Append(".*")
                }
            }
            else {
                [void]$builder.Append("[^/]*")
            }
        }
        elseif ($character -eq "?") {
            [void]$builder.Append("[^/]")
        }
        elseif ($character -eq "[") {
            $closing = $Pattern.IndexOf("]", $index + 1)
            if ($closing -gt ($index + 1)) {
                $content = $Pattern.Substring($index + 1, $closing - $index - 1)
                if ($content.StartsWith("!")) {
                    $content = "^" + $content.Substring(1)
                }
                $content = $content.Replace("\", "\\")
                [void]$builder.Append("[" + $content + "]")
                $index = $closing
            }
            else {
                [void]$builder.Append("\[")
            }
        }
        else {
            [void]$builder.Append([Regex]::Escape([string]$character))
        }
        $index++
    }
    return $builder.ToString()
}

function Get-GitIgnoreRules {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Candidates
    )

    $ignoreFiles = @($Candidates |
        Where-Object { [IO.Path]::GetFileName($_.Relative) -ieq ".gitignore" } |
        Sort-Object {
            ($_.Relative.Split("/").Count * 100000) + $_.Relative.Length
        })
    $rules = [Collections.Generic.List[object]]::new()
    foreach ($ignore in $ignoreFiles) {
        $base = [IO.Path]::GetDirectoryName($ignore.Relative).Replace("\", "/")
        if ($base -eq ".") {
            $base = ""
        }
        foreach ($originalLine in [IO.File]::ReadAllLines($ignore.FullName)) {
            $line = $originalLine.TrimEnd()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($line.StartsWith("\#")) {
                $line = $line.Substring(1)
            }
            elseif ($line.StartsWith("#")) {
                continue
            }
            $negated = $false
            if ($line.StartsWith("\!")) {
                $line = $line.Substring(1)
            }
            elseif ($line.StartsWith("!")) {
                $negated = $true
                $line = $line.Substring(1)
            }
            if (-not $line) {
                continue
            }
            $directoryOnly = $line.EndsWith("/")
            if ($directoryOnly) {
                $line = $line.TrimEnd("/")
            }
            $anchored = $line.StartsWith("/")
            if ($anchored) {
                $line = $line.TrimStart("/")
            }
            if (-not $line) {
                continue
            }
            $hasSlash = $line.Contains("/")
            $glob = Convert-GitIgnoreGlobToRegex $line
            $suffix = if ($directoryOnly) { "(?:/.*$)" } else { "(?:$|/.*$)" }
            if ($anchored -or $hasSlash) {
                $expression = "^" + $glob + $suffix
            }
            else {
                $expression = "(?:^|/)" + $glob + $suffix
            }
            $rules.Add([pscustomobject]@{
                Base = $base
                Expression = $expression
                Negated = $negated
            })
        }
    }
    return @($rules)
}

function Test-IgnoredByRules {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][object[]]$Rules
    )

    $ignored = $false
    foreach ($rule in $Rules) {
        if ($rule.Base) {
            $prefix = $rule.Base + "/"
            if (-not $RelativePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $localPath = $RelativePath.Substring($prefix.Length)
        }
        else {
            $localPath = $RelativePath
        }
        if ([Regex]::IsMatch(
            $localPath,
            $rule.Expression,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )) {
            $ignored = -not $rule.Negated
        }
    }
    return $ignored
}

function Get-SevenZipExecutable {
    if ($env:EAP_ZIPME_7Z -and (Test-Path -LiteralPath $env:EAP_ZIPME_7Z -PathType Leaf)) {
        return (Get-Item -LiteralPath $env:EAP_ZIPME_7Z).FullName
    }
    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    if ($env:EAP_ROOT) {
        $bundled = Join-Path $env:EAP_ROOT "core\tools\7zip\7z.exe"
        if (Test-Path -LiteralPath $bundled -PathType Leaf) {
            return $bundled
        }
    }
    throw "No se encuentra 7z.exe. Ejecuta EAP para reparar sus herramientas core."
}

if ($Help -or $Source -in @("--help", "-h", "help")) {
    Show-ZipMeHelp
    exit 0
}

$resolvedSource = Resolve-Path -LiteralPath $Source -ErrorAction Stop
if (-not (Test-Path -LiteralPath $resolvedSource.Path -PathType Container)) {
    throw "La ruta de proyecto no es una carpeta: $Source"
}
$root = Get-NormalizedFullPath $resolvedSource.Path
$volumeRoot = [IO.Path]::GetPathRoot($root)
if ([string]::Equals(
    $root.TrimEnd("\"),
    $volumeRoot.TrimEnd("\"),
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "No se puede empaquetar la raíz de una unidad. Indica una carpeta de proyecto."
}
$projectName = [IO.DirectoryInfo]::new($root).Name
if (-not $projectName) {
    throw "No se puede empaquetar la raíz de una unidad. Indica una carpeta de proyecto."
}

if (-not $Output) {
    $outputPath = Join-Path $root ($projectName + ".7z")
}
else {
    $outputPath = [IO.Path]::GetFullPath($Output)
    if (-not [IO.Path]::GetExtension($outputPath)) {
        $outputPath += ".7z"
    }
}
$extension = [IO.Path]::GetExtension($outputPath).ToLowerInvariant()
if ($extension -notin @(".7z", ".zip")) {
    throw "El archivo de salida debe tener extensión .7z o .zip."
}

$temporaryRoot = if ($env:EAP_POCKETOOL_DATA) {
    $env:EAP_POCKETOOL_DATA
}
else {
    [IO.Path]::GetTempPath()
}
[void][IO.Directory]::CreateDirectory($temporaryRoot)

$rootIgnore = Join-Path $root ".gitignore"
$hasGitIgnore = Test-Path -LiteralPath $rootIgnore -PathType Leaf
$selectionMode = "exclusiones predeterminadas"
$files = @()

if ($hasGitIgnore) {
    $gitCommand = if ($env:EAP_ZIPME_NO_GIT -eq "1") {
        $null
    }
    else {
        Get-Command git.exe -ErrorAction SilentlyContinue
    }
    $gitPaths = $null
    if ($null -ne $gitCommand) {
        $gitPaths = Get-GitIgnoredSelection `
            -Root $root `
            -GitExecutable $gitCommand.Source `
            -TemporaryRoot $temporaryRoot
    }
    if ($null -ne $gitPaths) {
        $forbiddenSegments = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        @(".git", ".svn", ".hg") | ForEach-Object {
            [void]$forbiddenSegments.Add($_)
        }
        $selected = [Collections.Generic.List[object]]::new()
        foreach ($relative in $gitPaths) {
            if ([string]::IsNullOrEmpty($relative)) {
                continue
            }
            $normalized = $relative.Replace("\", "/")
            if (Test-PathHasSegment -RelativePath $normalized -Names $forbiddenSegments) {
                continue
            }
            $fullName = Join-Path $root $normalized.Replace("/", "\")
            if (-not (Test-Path -LiteralPath $fullName -PathType Leaf)) {
                continue
            }
            $item = Get-Item -LiteralPath $fullName
            if (Test-ReparsePoint $item) {
                continue
            }
            $selected.Add([pscustomobject]@{
                FullName = $item.FullName
                Relative = $normalized
            })
        }
        $files = @($selected | Sort-Object { $_.Relative.ToLowerInvariant() })
        $selectionMode = ".gitignore (motor Git)"
    }
    else {
        $candidates = @(Get-ProjectFiles -Root $root -UseDefaultExclusions $false)
        $rules = @(Get-GitIgnoreRules -Root $root -Candidates $candidates)
        $files = @($candidates | Where-Object {
            -not (Test-IgnoredByRules -RelativePath $_.Relative -Rules $rules)
        })
        $selectionMode = ".gitignore (motor integrado)"
    }
}
else {
    $files = @(Get-ProjectFiles -Root $root -UseDefaultExclusions $true)
}

$files = @($files | Where-Object {
    -not (Test-SamePath -Left $_.FullName -Right $outputPath)
})

if ($List) {
    Write-Output "Proyecto: $root"
    Write-Output "Filtro: $selectionMode"
    Write-Output "Archivos incluidos: $($files.Count)"
    foreach ($file in $files) {
        Write-Output $file.Relative
    }
    exit 0
}

if ($files.Count -eq 0) {
    throw "No hay archivos que incluir en el paquete."
}

$outputDirectory = [IO.Path]::GetDirectoryName($outputPath)
[void][IO.Directory]::CreateDirectory($outputDirectory)
$temporaryArchive = Join-Path $outputDirectory (
    ".zipme-" + [Guid]::NewGuid().ToString("N") + $extension
)
$listFile = Join-Path $temporaryRoot (
    "zipme-files-" + [Guid]::NewGuid().ToString("N") + ".txt"
)

try {
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllLines(
        $listFile,
        [string[]]@($files | ForEach-Object { $_.Relative }),
        $encoding
    )
    $sevenZip = Get-SevenZipExecutable
    $archiveType = if ($extension -eq ".zip") { "zip" } else { "7z" }
    Push-Location $root
    try {
        & $sevenZip a "-t$archiveType" -mx=5 -bd -y -scsUTF-8 `
            $temporaryArchive "@$listFile"
        if ($LASTEXITCODE -ne 0) {
            throw "7-Zip terminó con código $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
    Move-Item -LiteralPath $temporaryArchive -Destination $outputPath -Force
}
finally {
    if (Test-Path -LiteralPath $listFile) {
        Remove-Item -LiteralPath $listFile -Force
    }
    if (Test-Path -LiteralPath $temporaryArchive) {
        Remove-Item -LiteralPath $temporaryArchive -Force
    }
}

$sizeMiB = [Math]::Round((Get-Item -LiteralPath $outputPath).Length / 1MB, 2)
Write-Output "Proyecto empaquetado: $outputPath"
Write-Output "Filtro aplicado: $selectionMode"
Write-Output "Archivos incluidos: $($files.Count) · Tamaño: $sizeMiB MiB"
