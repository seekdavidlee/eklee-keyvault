<#
.SYNOPSIS
    Resolves a release image from this checkout's GitHub repository.
.DESCRIPTION
    Uses the latest published GitHub Release as the default image version, or
    accepts an operator-entered stable semantic version. The selected public
    GHCR tag is resolved to a digest before it is written to CONTAINER_IMAGE.
.PARAMETER RepositoryPath
    Path to the Git checkout whose origin identifies the only allowed image
    repository.
.PARAMETER Version
    Optional bare stable semantic version. When omitted, the script offers the
    latest published GitHub Release as the default.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory = $false)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-GitHubOrigin {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Origin
    )

    $match = [regex]::Match(
        $Origin,
        '^(?:https://github\.com/|git@github\.com:)(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?<repository>[A-Za-z0-9][A-Za-z0-9._-]{0,99})(?:\.git)?$'
    )
    if (-not $match.Success) {
        throw "Git origin '$Origin' must be a canonical GitHub HTTPS or SSH repository URL."
    }

    $owner = $match.Groups['owner'].Value
    $repository = $match.Groups['repository'].Value
    if ($repository.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $repository = $repository.Substring(0, $repository.Length - 4)
    }

    if ($repository.Contains('..') -or $repository.StartsWith('.') -or $repository.EndsWith('.')) {
        throw "Git origin '$Origin' contains an unsupported repository name."
    }

    $repositoryName = "$($owner.ToLowerInvariant())/$($repository.ToLowerInvariant())"
    if ($repositoryName -ne 'seekdavidlee/eklee-keyvault') {
        throw "Git origin '$Origin' must identify the seekdavidlee/eklee-keyvault repository."
    }

    return [pscustomobject]@{
        Owner = $owner.ToLowerInvariant()
        Repository = $repository.ToLowerInvariant()
        Name = $repositoryName
    }
}

function ConvertTo-StableReleaseVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim() -or
        $Value -notmatch '^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$') {
        throw "Release version '$Value' must be a bare stable MAJOR.MINOR.PATCH value such as 1.0.0."
    }

    return $Value
}

function Get-GitHubOrigin {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $originOutput = & git -C $Path remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Git origin remote: $($originOutput -join ' ')"
    }

    return ConvertFrom-GitHubOrigin -Origin (($originOutput -join [Environment]::NewLine).Trim())
}

function Get-GitHubReleaseListResponse {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository
    )

    $releaseOutput = @(& gh release list --repo $Repository --limit 5 --exclude-drafts --exclude-pre-releases --json tagName 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $releaseOutput
    }
}

function Get-RecentReleaseVersions {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository
    )

    $releaseResponse = Get-GitHubReleaseListResponse -Repository $Repository
    if ($releaseResponse.ExitCode -ne 0) {
        $errorMessage = ($releaseResponse.Output -join ' ').Trim()
        throw "Could not retrieve GitHub Releases for '$Repository': $errorMessage"
    }

    try {
        $releases = @(($releaseResponse.Output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    catch {
        throw "The GitHub Release response for '$Repository' was not valid JSON: $($_.Exception.Message)"
    }

    $releaseVersions = foreach ($release in $releases) {
        if ($null -ne $release) {
            ConvertTo-StableReleaseVersion -Value ([string]$release.tagName)
        }
    }

    return @($releaseVersions)
}

function Read-ManualReleaseVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Prompt = 'Container image release version (for example, 1.0.0)'
    )

    while ($true) {
        try {
            return ConvertTo-StableReleaseVersion -Value (Read-Host $Prompt)
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Read-ReleaseVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository,

        [Parameter(Mandatory = $false)]
        [string]$ExplicitVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        return ConvertTo-StableReleaseVersion -Value $ExplicitVersion
    }

    $releaseVersions = @(Get-RecentReleaseVersions -Repository $Repository)
    if ($releaseVersions.Count -eq 0) {
        Write-Host 'No published stable releases were found. Enter a release version manually.' -ForegroundColor Yellow
        return Read-ManualReleaseVersion
    }

    Write-Host 'Choose a container image release:' -ForegroundColor Cyan
    for ($index = 0; $index -lt $releaseVersions.Count; $index++) {
        Write-Host "$($index + 1). $($releaseVersions[$index])"
    }
    Write-Host 'M. Enter a release version manually'

    while ($true) {
        $selection = (Read-Host 'Selection').Trim()
        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and $selectedIndex -le $releaseVersions.Count) {
            return $releaseVersions[$selectedIndex - 1]
        }

        if ($selection -match '^(?i)m(?:anual)?$') {
            return Read-ManualReleaseVersion
        }

        Write-Warning "Choose a release number from 1 to $($releaseVersions.Count), or enter M for a manual version."
    }
}

function Get-ContainerImageDigest {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Tag
    )

    $tokenUri = "https://ghcr.io/token?scope=$([uri]::EscapeDataString("repository:$Repository:pull"))"
    try {
        $tokenResponse = Invoke-RestMethod -Uri $tokenUri -UseBasicParsing
    }
    catch {
        throw "Could not obtain a GHCR pull token for '$Repository': $($_.Exception.Message)"
    }

    $token = [string]$tokenResponse.token
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "GHCR did not return a pull token for '$Repository'."
    }

    $manifestUri = "https://ghcr.io/v2/$Repository/manifests/$Tag"
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'
    }
    try {
        $response = Invoke-WebRequest -Uri $manifestUri -Headers $headers -UseBasicParsing
    }
    catch {
        throw "Could not resolve the GHCR image tag '$Repository`:$Tag': $($_.Exception.Message)"
    }

    if ($response.StatusCode -ne 200) {
        throw "GHCR returned status '$($response.StatusCode)' for image tag '$Repository`:$Tag'."
    }

    $headerValue = $response.Headers['docker-content-digest']
    $digestValues = @(
        if ($headerValue -is [System.Collections.IEnumerable] -and $headerValue -isnot [string]) {
            @($headerValue)
        }
        else {
            $headerValue
        }
    )
    if ($digestValues.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$digestValues[0])) {
        throw "GHCR did not return exactly one docker-content-digest header for '$Repository`:$Tag'."
    }

    $digest = ([string]$digestValues[0]).Trim()
    if ($digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "GHCR returned an invalid image digest for '$Repository`:$Tag'."
    }

    return $digest
}

function Set-ContainerImageEnvironment {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ImageReference
    )

    & azd env set CONTAINER_IMAGE $ImageReference
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to set CONTAINER_IMAGE in the azd environment.'
    }
}

function Resolve-ContainerImage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$ExplicitVersion
    )

    $githubRepository = Get-GitHubOrigin -Path $Path
    $releaseVersion = if ([string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        Read-ReleaseVersion -Repository $githubRepository.Name
    }
    else {
        Read-ReleaseVersion -Repository $githubRepository.Name -ExplicitVersion $ExplicitVersion
    }
    $digest = Get-ContainerImageDigest -Repository $githubRepository.Name -Tag $releaseVersion
    $imageReference = "ghcr.io/$($githubRepository.Name)@$digest"

    Set-ContainerImageEnvironment -ImageReference $imageReference

    return $imageReference
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Write-Host 'Resolving the repository release image...' -ForegroundColor Cyan
        $resolveParameters = @{ Path = $RepositoryPath }
        if ($PSBoundParameters.ContainsKey('Version')) {
            $resolveParameters.ExplicitVersion = $Version
        }
        $imageReference = Resolve-ContainerImage @resolveParameters
        Write-Host "CONTAINER_IMAGE set to $imageReference" -ForegroundColor Green
    }
    catch {
        Write-Error "Container image resolution failed: $($_.Exception.Message)"
        exit 1
    }
}
