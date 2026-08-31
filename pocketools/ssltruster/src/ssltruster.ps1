[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action = "menu",

    [Parameter(Position = 1)]
    [string]$Value,

    [Alias("y")]
    [switch]$Yes,

    [switch]$Json,

    [Alias("h")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:DataRoot = if ($env:EAP_POCKETOOL_DATA) {
    [IO.Path]::GetFullPath($env:EAP_POCKETOOL_DATA)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\data"))
}
$script:StatePath = Join-Path $script:DataRoot "ssltruster.json"
$script:ProbeRoot = Join-Path $PSScriptRoot "probes"
$script:TestMode = $env:EAP_SSLTRUSTER_TEST_MODE -eq "1"
$script:ProfileId = if ($env:EAP_PROFILE) {
    [string]$env:EAP_PROFILE
}
elseif ($script:TestMode) {
    "test"
}
else {
    "standalone"
}

function New-EmptyState {
    return [ordered]@{
        schemaVersion = 1
        urls = @()
        certificates = @()
    }
}

function Read-SslTrusterState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        return New-EmptyState
    }
    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if ([int]$state.schemaVersion -ne 1) {
            throw "versión de estado no soportada"
        }
        return [ordered]@{
            schemaVersion = 1
            urls = @($state.urls)
            certificates = @($state.certificates)
        }
    }
    catch {
        throw "El estado de SSL Truster no es válido: $($_.Exception.Message)"
    }
}

function Write-SslTrusterState {
    param([Parameter(Mandatory = $true)][object]$State)

    [IO.Directory]::CreateDirectory($script:DataRoot) | Out-Null
    $temporary = "$($script:StatePath).$([Guid]::NewGuid().ToString('N')).tmp"
    $content = $State | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText(
        $temporary,
        $content + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $script:StatePath -Force
}

function ConvertTo-HttpsTarget {
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) {
        throw "La URL no es válida: $Url"
    }
    if ($uri.Scheme -ne "https") {
        throw "SSL Truster sólo admite URLs HTTPS."
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.UserInfo) {
        throw "La URL HTTPS no puede contener credenciales y debe tener hostname."
    }
    $builder = [UriBuilder]::new($uri)
    $builder.Fragment = ""
    $normalized = $builder.Uri.AbsoluteUri
    $origin = "https://$($uri.IdnHost.ToLowerInvariant())"
    if (-not $uri.IsDefaultPort) {
        $origin += ":$($uri.Port)"
    }
    return [pscustomobject]@{
        Url = $normalized
        Origin = $origin
        Uri = $builder.Uri
    }
}

function Test-NoProxyMatch {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    $value = if ($env:NO_PROXY) { $env:NO_PROXY } else { $env:no_proxy }
    if (-not $value) {
        return $false
    }
    $hostName = $Uri.IdnHost.ToLowerInvariant()
    foreach ($rawItem in $value.Split(",")) {
        $item = $rawItem.Trim().ToLowerInvariant()
        if ($item -eq "*") {
            return $true
        }
        $withoutPort = $item.Split(":", 2)[0]
        if ($hostName -eq $withoutPort) {
            return $true
        }
        if ($withoutPort.StartsWith(".") -and $hostName.EndsWith($withoutPort)) {
            return $true
        }
    }
    return $false
}

function Invoke-WindowsProbe {
    param([Parameter(Mandatory = $true)][object]$Target)

    if ($script:TestMode) {
        $failure = $env:EAP_SSLTRUSTER_TEST_FAIL
        return [pscustomobject]@{
            Name = "Windows"
            Installed = $true
            Success = $failure -ne "Windows"
            Detail = if ($failure -eq "Windows") { "fallo simulado" } else { "HTTP 200" }
            HttpStatus = if ($failure -eq "Windows") { $null } else { 200 }
            RootSubject = "CN=SSL Truster Test Root"
            RootThumbprint = "TESTROOT"
        }
    }

    $request = [Net.HttpWebRequest]::Create($Target.Uri)
    $request.Method = "GET"
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 10
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    $request.UserAgent = "EAP-SSLTruster/1.0"
    if (-not (Test-NoProxyMatch -Uri $Target.Uri)) {
        $proxyValue = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { $env:https_proxy }
        if ($proxyValue) {
            $proxy = [Net.WebProxy]::new($proxyValue, $false)
            $proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
            $request.Proxy = $proxy
        }
        elseif ($null -ne $request.Proxy) {
            $request.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
        }
    }
    else {
        $request.Proxy = $null
    }

    $response = $null
    try {
        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
        }
        catch [Net.WebException] {
            if ($_.Exception.Response -is [Net.HttpWebResponse]) {
                $response = [Net.HttpWebResponse]$_.Exception.Response
            }
            else {
                return [pscustomobject]@{
                    Name = "Windows"
                    Installed = $true
                    Success = $false
                    Detail = $_.Exception.Message
                    HttpStatus = $null
                    RootSubject = $null
                    RootThumbprint = $null
                }
            }
        }
        $leaf = $null
        $root = $null
        if ($null -ne $request.ServicePoint.Certificate) {
            $leaf = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $request.ServicePoint.Certificate
            )
            $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
            try {
                $chain.ChainPolicy.RevocationMode =
                    [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                [void]$chain.Build($leaf)
                if ($chain.ChainElements.Count -gt 0) {
                    $root = $chain.ChainElements[
                        $chain.ChainElements.Count - 1
                    ].Certificate
                }
            }
            finally {
                $chain.Dispose()
                $leaf.Dispose()
            }
        }
        $status = [int]$response.StatusCode
        if ($response.ResponseUri.Scheme -ne "https") {
            return [pscustomobject]@{
                Name = "Windows"
                Installed = $true
                Success = $false
                Detail = "redirección a una URL sin HTTPS"
                HttpStatus = $status
                RootSubject = $null
                RootThumbprint = $null
            }
        }
        return [pscustomobject]@{
            Name = "Windows"
            Installed = $true
            Success = $true
            Detail = "HTTP $status"
            HttpStatus = $status
            RootSubject = if ($null -ne $root) { $root.Subject } else { $null }
            RootThumbprint = if ($null -ne $root) { $root.Thumbprint } else { $null }
        }
    }
    catch {
        return [pscustomobject]@{
            Name = "Windows"
            Installed = $true
            Success = $false
            Detail = $_.Exception.Message
            HttpStatus = $null
            RootSubject = $null
            RootThumbprint = $null
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Invoke-ExternalProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [hashtable]$Environment = @{}
    )

    if ($script:TestMode) {
        $failure = $env:EAP_SSLTRUSTER_TEST_FAIL
        return [pscustomobject]@{
            Name = $Name
            Installed = $true
            Success = $failure -ne $Name
            Detail = if ($failure -eq $Name) { "fallo simulado" } else { "HTTP 200" }
        }
    }

    $saved = @{}
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        foreach ($key in $Environment.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            $newValue = if ($null -eq $Environment[$key]) {
                $null
            }
            else {
                [string]$Environment[$key]
            }
            [Environment]::SetEnvironmentVariable(
                $key, $newValue, "Process"
            )
        }
        $ErrorActionPreference = "Continue"
        $output = @(& $Executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $detail = ($output | ForEach-Object { [string]$_ }) -join " "
        if ($detail.Length -gt 300) {
            $detail = $detail.Substring(0, 300) + "..."
        }
        return [pscustomobject]@{
            Name = $Name
            Installed = $true
            Success = $exitCode -eq 0
            Detail = if ($detail) { $detail } else { "código $exitCode" }
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable(
                $key, $saved[$key], "Process"
            )
        }
    }
}

function New-NotInstalledResult {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [pscustomobject]@{
        Name = $Name
        Installed = $false
        Success = $true
        Detail = "no instalado"
    }
}

function Invoke-AllProbes {
    param([Parameter(Mandatory = $true)][object]$Target)

    if ($script:TestMode) {
        $names = if ($env:EAP_SSLTRUSTER_TEST_RUNTIMES) {
            @($env:EAP_SSLTRUSTER_TEST_RUNTIMES.Split(",") | ForEach-Object { $_.Trim() })
        }
        else {
            @("Windows", "EAP", "Node", "Java", "Python", "Go")
        }
        $results = foreach ($name in $names) {
            if ($name -eq "Windows") {
                Invoke-WindowsProbe -Target $Target
            }
            else {
                Invoke-ExternalProbe -Name $name -Executable "test" -Arguments @()
            }
        }
        return @($results)
    }

    $results = [Collections.Generic.List[object]]::new()
    $windows = Invoke-WindowsProbe -Target $Target
    $results.Add($windows)
    if (-not $windows.Success) {
        return @($results)
    }

    $pythonProbe = Join-Path $script:ProbeRoot "ssltruster_probe.py"
    $eapPython = if ($env:EAP_ROOT) {
        Join-Path $env:EAP_ROOT "core\tools\python-embed\python.exe"
    }
    else { $null }
    if ($eapPython -and (Test-Path -LiteralPath $eapPython -PathType Leaf)) {
        $results.Add((Invoke-ExternalProbe -Name "EAP" -Executable $eapPython `
            -Arguments @($pythonProbe, $Target.Url) `
            -Environment @{
                PYTHONHTTPSVERIFY = "1"
                SSL_CERT_FILE = $null
                REQUESTS_CA_BUNDLE = $null
            }))
    }
    else {
        $results.Add((New-NotInstalledResult -Name "EAP"))
    }

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $node) {
        $results.Add((Invoke-ExternalProbe -Name "Node" -Executable $node.Source `
            -Arguments @((Join-Path $script:ProbeRoot "ssltruster_probe.js"), $Target.Url) `
            -Environment @{
                NODE_USE_SYSTEM_CA = "1"
                NODE_USE_ENV_PROXY = "1"
                NODE_TLS_REJECT_UNAUTHORIZED = "1"
                NODE_EXTRA_CA_CERTS = $null
            }))
    }
    else {
        $results.Add((New-NotInstalledResult -Name "Node"))
    }

    $java = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($null -ne $java) {
        $javaToolOptions = [string]$env:JAVA_TOOL_OPTIONS
        if (
            $javaToolOptions -notmatch "-Djavax\.net\.ssl\.trustStore=NONE" -or
            $javaToolOptions -notmatch "-Djavax\.net\.ssl\.trustStoreType=Windows-ROOT"
        ) {
            $javaToolOptions = @(
                $javaToolOptions,
                "-Djavax.net.ssl.trustStore=NONE",
                "-Djavax.net.ssl.trustStoreType=Windows-ROOT"
            ) | Where-Object { $_ }
            $javaToolOptions = $javaToolOptions -join " "
        }
        $results.Add((Invoke-ExternalProbe -Name "Java" -Executable $java.Source `
            -Arguments @(
                (Join-Path $script:ProbeRoot "SslTrusterProbe.java"),
                $Target.Url
            ) `
            -Environment @{
                JAVA_TOOL_OPTIONS = $javaToolOptions
            }))
    }
    else {
        $results.Add((New-NotInstalledResult -Name "Java"))
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        $results.Add((Invoke-ExternalProbe -Name "Python" -Executable $python.Source `
            -Arguments @($pythonProbe, $Target.Url) `
            -Environment @{
                PYTHONHTTPSVERIFY = "1"
                SSL_CERT_FILE = $null
                REQUESTS_CA_BUNDLE = $null
            }))
    }
    else {
        $results.Add((New-NotInstalledResult -Name "Python"))
    }

    $go = Get-Command go.exe -ErrorAction SilentlyContinue
    if ($null -ne $go) {
        $results.Add((Invoke-ExternalProbe -Name "Go" -Executable $go.Source `
            -Arguments @("run", (Join-Path $script:ProbeRoot "ssltruster_probe.go"), $Target.Url)))
    }
    else {
        $results.Add((New-NotInstalledResult -Name "Go"))
    }
    return @($results)
}

function Test-ProbesSuccessful {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    return @($Results | Where-Object { $_.Installed -and -not $_.Success }).Count -eq 0
}

function Write-ProbeResults {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    foreach ($result in $Results) {
        if (-not $result.Installed) {
            Write-Host ("{0,-10} -  no instalado" -f $result.Name) -ForegroundColor DarkGray
        }
        elseif ($result.Success) {
            Write-Host ("{0,-10} OK {1}" -f $result.Name, $result.Detail) -ForegroundColor Green
        }
        else {
            Write-Host ("{0,-10} ERROR {1}" -f $result.Name, $result.Detail) -ForegroundColor Red
        }
    }
}

function Invoke-EapTrustCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("status", "enable", "disable")]
        [string]$Command
    )

    if ($script:TestMode) {
        return [pscustomobject]@{
            schemaVersion = 1
            profile = "test"
            enabled = $Command -ne "disable"
        }
    }
    if (-not $env:EAP_ROOT -or -not $env:EAP_PROFILE) {
        throw "Ejecute SSL Truster desde un profile EAP activo."
    }
    $eap = Join-Path $env:EAP_ROOT "eap.cmd"
    if (-not (Test-Path -LiteralPath $eap -PathType Leaf)) {
        throw "No se encuentra eap.cmd en EAP_ROOT."
    }
    $output = @(& $eap trust $Command --profile $env:EAP_PROFILE --json 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { [string]$_ }) -join " ")
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Add-OrUpdateUrl {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][bool]$Success
    )

    $state = Read-SslTrusterState
    $now = [DateTimeOffset]::Now.ToString("o")
    $previous = @($state.urls | Where-Object {
        [string]::Equals($_.url, $Target.Url, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($_.profile, $script:ProfileId, [StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    $windows = @($Results | Where-Object { $_.Name -eq "Windows" }) |
        Select-Object -First 1
    $entry = [ordered]@{
        url = $Target.Url
        origin = $Target.Origin
        profile = $script:ProfileId
        status = if ($Success) { "approved" } else { "error" }
        approvedAt = if ($Success -and $null -eq $previous) {
            $now
        }
        elseif ($null -ne $previous) {
            $previous.approvedAt
        }
        else {
            $null
        }
        checkedAt = $now
        rootSubject = if ($null -ne $windows) { $windows.RootSubject } else { $null }
        rootThumbprint = if ($null -ne $windows) { $windows.RootThumbprint } else { $null }
        checks = @($Results | ForEach-Object {
            [ordered]@{
                name = $_.Name
                installed = [bool]$_.Installed
                success = [bool]$_.Success
                detail = [string]$_.Detail
            }
        })
    }
    $state.urls = @($state.urls | Where-Object {
        -not (
            [string]::Equals($_.url, $Target.Url, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($_.profile, $script:ProfileId, [StringComparison]::OrdinalIgnoreCase)
        )
    }) + @($entry)
    Write-SslTrusterState -State $state
    return [pscustomobject]$entry
}

function Approve-SslUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $target = ConvertTo-HttpsTarget -Url $Url
    if (-not $Json) {
        Write-Host "Comprobando $($target.Url)..."
        Write-Host ""
    }
    $results = Invoke-AllProbes -Target $target
    $success = Test-ProbesSuccessful -Results $results
    if (-not $Json) {
        Write-ProbeResults -Results $results
    }
    if (-not $success) {
        $windowsFailure = @($results | Where-Object {
            $_.Name -eq "Windows" -and -not $_.Success
        }).Count -gt 0
        if ($windowsFailure) {
            throw (
                "Windows no confía en esta URL. Instale primero la CA de " +
                "su organización con 'ssltruster import <archivo>'."
            )
        }
        throw "La URL no funciona en todos los runtimes instalados."
    }
    [void](Invoke-EapTrustCommand -Command "enable")
    $entry = Add-OrUpdateUrl -Target $target -Results $results -Success $true
    if ($Json) {
        $entry | ConvertTo-Json -Depth 12
    }
    else {
        Write-Host ""
        Write-Host "URL aprobada correctamente." -ForegroundColor Green
        Write-Host (
            "Abra una terminal EAP nueva para aplicar la confianza a todos " +
            "los comandos del profile."
        ) -ForegroundColor Yellow
    }
}

function Show-ApprovedUrls {
    $state = Read-SslTrusterState
    $urls = @($state.urls | Where-Object {
        [string]::Equals($_.profile, $script:ProfileId, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object { $_.url.ToLowerInvariant() })
    if ($Json) {
        ConvertTo-Json -InputObject @($urls) -Depth 12
        return
    }
    if ($urls.Count -eq 0) {
        Write-Host "No hay URLs aprobadas."
        return
    }
    $index = 1
    foreach ($entry in $urls) {
        $marker = if ($entry.status -eq "approved") { "OK" } else { "ERROR" }
        $color = if ($entry.status -eq "approved") { "Green" } else { "Red" }
        Write-Host ("[{0}] {1}  {2}" -f $index, $marker, $entry.url) -ForegroundColor $color
        Write-Host ("    Comprobada: {0}" -f $entry.checkedAt) -ForegroundColor DarkGray
        $index++
    }
}

function Recheck-ApprovedUrls {
    $state = Read-SslTrusterState
    $urls = @($state.urls | Where-Object {
        [string]::Equals($_.profile, $script:ProfileId, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($urls.Count -eq 0) {
        if (-not $Json) { Write-Host "No hay URLs aprobadas." }
        if ($Json) { "[]" | Write-Output }
        return
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($saved in $urls) {
        $target = ConvertTo-HttpsTarget -Url ([string]$saved.url)
        if (-not $Json) {
            Write-Host "Comprobando $($target.Url)..."
        }
        $results = Invoke-AllProbes -Target $target
        $success = Test-ProbesSuccessful -Results $results
        if (-not $Json) {
            Write-ProbeResults -Results $results
            Write-Host ""
        }
        $entries.Add((Add-OrUpdateUrl -Target $target -Results $results -Success $success))
    }
    if ($Json) {
        ConvertTo-Json -InputObject @($entries) -Depth 12
    }
}

function Repair-SslTrust {
    [void](Invoke-EapTrustCommand -Command "enable")
    if (-not $Json) {
        Write-Host "Integración con Windows reparada para el profile activo."
        Write-Host ""
    }
    Recheck-ApprovedUrls
}

function Get-CertificateFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "No existe el certificado: $resolved"
    }
    $content = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
    $pemMatch = [regex]::Match(
        $content,
        "-----BEGIN CERTIFICATE-----(?<data>.*?)-----END CERTIFICATE-----",
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($pemMatch.Success) {
        $base64 = $pemMatch.Groups["data"].Value -replace "\s", ""
        $bytes = [Convert]::FromBase64String($base64)
        return [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
    }
    return [Security.Cryptography.X509Certificates.X509Certificate2]::new($resolved)
}

function Import-CompanyCertificate {
    param([Parameter(Mandatory = $true)][string]$Path)

    $certificate = Get-CertificateFromFile -Path $Path
    try {
        $basic = $certificate.Extensions | Where-Object {
            $_.Oid.Value -eq "2.5.29.19"
        } | Select-Object -First 1
        $isCa = $false
        if ($null -ne $basic) {
            $decoded = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new()
            $decoded.CopyFrom($basic)
            $isCa = $decoded.CertificateAuthority
        }
        if (-not $isCa) {
            throw "El archivo no contiene una autoridad certificadora (CA)."
        }
        $storeName = if ($certificate.Subject -eq $certificate.Issuer) {
            "Root"
        }
        else {
            "CA"
        }
        $storeEnum = if ($storeName -eq "Root") {
            [Security.Cryptography.X509Certificates.StoreName]::Root
        }
        else {
            [Security.Cryptography.X509Certificates.StoreName]::CertificateAuthority
        }
        if (-not $Json) {
            Write-Host "Certificado de empresa"
            Write-Host "Sujeto: $($certificate.Subject)"
            Write-Host "Emisor: $($certificate.Issuer)"
            Write-Host "Caduca: $($certificate.NotAfter.ToString('yyyy-MM-dd'))"
            $sha256 = $certificate.GetCertHashString(
                [Security.Cryptography.HashAlgorithmName]::SHA256
            )
            Write-Host "SHA-256: $sha256"
            Write-Host "Destino: CurrentUser\$storeName"
            Write-Host ""
        }
        if (-not $Yes -and -not $script:TestMode) {
            $confirmation = Read-Host "¿Confiar en esta CA para el usuario actual? [s/N]"
            if ($confirmation -notin @("s", "S", "si", "sí", "SI", "SÍ")) {
                throw "Importación cancelada."
            }
        }
        $added = $true
        if (-not $script:TestMode) {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new(
                $storeEnum,
                [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
            )
            try {
                $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $existing = $store.Certificates.Find(
                    [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                    $certificate.Thumbprint,
                    $false
                )
                if ($existing.Count -eq 0) {
                    $store.Add($certificate)
                }
                else {
                    $added = $false
                }
            }
            finally {
                $store.Close()
            }
        }
        $state = Read-SslTrusterState
        if ($added -and @($state.certificates | Where-Object {
            $_.thumbprint -eq $certificate.Thumbprint -and $_.store -eq $storeName
        }).Count -eq 0) {
            $state.certificates += @([ordered]@{
                thumbprint = $certificate.Thumbprint
                sha256 = $certificate.GetCertHashString(
                    [Security.Cryptography.HashAlgorithmName]::SHA256
                )
                subject = $certificate.Subject
                store = $storeName
                importedAt = [DateTimeOffset]::Now.ToString("o")
            })
            Write-SslTrusterState -State $state
        }
        $result = [pscustomobject]@{
            subject = $certificate.Subject
            thumbprint = $certificate.Thumbprint
            store = "CurrentUser\$storeName"
            added = $added
        }
        if ($Json) {
            $result | ConvertTo-Json -Depth 6
        }
        else {
            $message = if ($added) {
                "Certificado instalado correctamente."
            }
            else {
                "El certificado ya estaba instalado."
            }
            Write-Host $message -ForegroundColor Green
        }
    }
    finally {
        $certificate.Dispose()
    }
}

function Show-SslTrusterStatus {
    $state = Read-SslTrusterState
    $trust = Invoke-EapTrustCommand -Command "status"
    $profileUrls = @($state.urls | Where-Object {
        [string]::Equals($_.profile, $script:ProfileId, [StringComparison]::OrdinalIgnoreCase)
    })
    $approved = @($profileUrls | Where-Object { $_.status -eq "approved" }).Count
    $failed = @($profileUrls | Where-Object { $_.status -ne "approved" }).Count
    $result = [pscustomobject]@{
        profile = $trust.profile
        windowsTrustEnabled = [bool]$trust.enabled
        approvedUrls = $approved
        failedUrls = $failed
        managedCertificates = @($state.certificates).Count
    }
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
    }
    else {
        Write-Host "Profile: $($result.profile)"
        $trustLabel = if ($result.windowsTrustEnabled) {
            "activa"
        }
        else {
            "inactiva"
        }
        Write-Host "Confianza Windows: $trustLabel"
        Write-Host "URLs aprobadas: $approved"
        Write-Host "URLs con error: $failed"
        Write-Host "Certificados instalados por SSL Truster: $($result.managedCertificates)"
    }
}

function Show-SslTrusterHelp {
    @"
SSL Truster 1.0.0

Aprueba URLs HTTPS y verifica su funcionamiento sin desactivar TLS.

Uso:
  ssltruster                         Abre el menú interactivo
  ssltruster approve <url>           Aprueba y comprueba una URL
  ssltruster list                    Muestra las URLs guardadas
  ssltruster recheck                 Vuelve a comprobar todas
  ssltruster repair                  Repara la integración y comprueba
  ssltruster import <certificado>    Instala una CA para el usuario actual
  ssltruster status                  Muestra el estado del profile
  ssltruster --help                  Muestra esta ayuda

Opciones:
  -Yes       Confirma una importación no interactiva
  -Json      Devuelve resultados JSON
"@ | Write-Output
}

function Write-PageHeader {
    param([Parameter(Mandatory = $true)][string]$Page)

    $innerWidth = 67
    $label = "SSL Truster > $Page"
    $fill = [Math]::Max(1, $innerWidth - $label.Length - 3)
    Write-Host ("┌─ " + $label + " " + ("─" * $fill) + "┐") -ForegroundColor Cyan
    Write-Host ("└" + ("─" * $innerWidth) + "┘") -ForegroundColor Cyan
    Write-Host ""
}

function Write-ActionRow {
    param(
        [Parameter(Mandatory = $true)][string]$Shortcut,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $innerWidth = 67
    $tail = " $Text"
    $padding = [Math]::Max(
        0,
        $innerWidth - 1 - $Shortcut.Length - $tail.Length
    )
    Write-Host "│ " -NoNewline
    Write-Host $Shortcut -NoNewline -ForegroundColor Yellow
    Write-Host ($tail + (" " * $padding) + "│")
}

function Wait-SslTruster {
    Write-Host ""
    [void](Read-Host "Pulse Intro para continuar")
}

function Invoke-InteractiveMenu {
    while ($true) {
        Clear-Host
        Write-PageHeader -Page "Inicio"
        Write-Host "┌─ Acciones ────────────────────────────────────────────────────────┐"
        Write-ActionRow -Shortcut "[1]" -Text "Aprobar URL"
        Write-ActionRow -Shortcut "[2]" -Text "Ver URLs aprobadas"
        Write-ActionRow -Shortcut "[3]" -Text "Comprobar y reparar"
        Write-ActionRow -Shortcut "[4]" -Text "Instalar certificado de empresa"
        Write-ActionRow -Shortcut "[5]" -Text "Estado"
        Write-ActionRow -Shortcut "[Esc]" -Text "Salir"
        Write-Host "└───────────────────────────────────────────────────────────────────┘"
        $choice = (Read-Host "Opción").Trim()
        if ($choice -in @("Esc", "esc", "q", "Q")) {
            return
        }
        try {
            switch ($choice) {
                "1" {
                    Clear-Host
                    Write-PageHeader -Page "Aprobar URL"
                    $url = Read-Host "URL HTTPS"
                    [void](Approve-SslUrl -Url $url)
                }
                "2" {
                    Clear-Host
                    Write-PageHeader -Page "URLs aprobadas"
                    Show-ApprovedUrls
                }
                "3" {
                    Clear-Host
                    Write-PageHeader -Page "Comprobar y reparar"
                    [void](Repair-SslTrust)
                }
                "4" {
                    Clear-Host
                    Write-PageHeader -Page "Certificado de empresa"
                    $path = Read-Host "Ruta del certificado .cer, .crt o .pem"
                    [void](Import-CompanyCertificate -Path $path)
                }
                "5" {
                    Clear-Host
                    Write-PageHeader -Page "Estado"
                    [void](Show-SslTrusterStatus)
                }
                default {
                    Write-Host "Opción no válida." -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        Wait-SslTruster
    }
}

try {
    if ($Help) {
        $Action = "help"
    }
    switch ($Action.ToLowerInvariant()) {
        "menu" { Invoke-InteractiveMenu; exit 0 }
        "approve" {
            if (-not $Value) { throw "Indique la URL HTTPS que desea aprobar." }
            Approve-SslUrl -Url $Value
            exit 0
        }
        "list" { Show-ApprovedUrls; exit 0 }
        "recheck" { Recheck-ApprovedUrls; exit 0 }
        "repair" { Repair-SslTrust; exit 0 }
        "import" {
            if (-not $Value) { throw "Indique la ruta del certificado." }
            Import-CompanyCertificate -Path $Value
            exit 0
        }
        "status" { Show-SslTrusterStatus; exit 0 }
        "help" { Show-SslTrusterHelp; exit 0 }
        "--help" { Show-SslTrusterHelp; exit 0 }
        "-h" { Show-SslTrusterHelp; exit 0 }
        default { throw "Acción no válida: $Action" }
    }
}
catch {
    if ($Json) {
        [pscustomobject]@{
            success = $false
            error = $_.Exception.Message
        } | ConvertTo-Json -Depth 4
    }
    else {
        Write-Error "SSL Truster: $($_.Exception.Message)" -ErrorAction Continue
    }
    exit 2
}
