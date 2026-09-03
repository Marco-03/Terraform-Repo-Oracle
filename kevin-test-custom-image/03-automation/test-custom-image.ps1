#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ImageOcid = "",
    [string]$ImageName = "",
    [string]$VariableFile = "",
    [string]$PublicEndpointsFile = "",
    [string]$PlatformEndpointsFile = "",
    [string]$SshPrivateKeyPath = "",
    [string]$SshUser = "opc",
    [ValidateRange(60, 7200)]
    [int]$WaitSeconds = 3600,
    [switch]$ValidateOnly,
    [switch]$KeepTestResources,
    [switch]$InspectionMode,
    [string]$InspectionId = "",
    [string]$CleanupInspection = "",
    [string]$CleanupFailedTest = "",
    [string]$ShowInspectionInfo = "",
    [switch]$SuppressCleanupCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$TerraformRoot = $PSScriptRoot
$AutomationDirectory = Join-Path $ProjectRoot ".automation"
$NullOutputPath = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { "NUL" } else { "/dev/null" }

if ($SshUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
    throw "SshUser must be a valid Linux user name."
}
if (-not [string]::IsNullOrWhiteSpace($ImageName) -and $ImageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$') {
    throw "ImageName contains unsupported characters."
}
if ($InspectionMode -and ($ValidateOnly -or $KeepTestResources -or
        -not [string]::IsNullOrWhiteSpace($CleanupInspection) -or
        -not [string]::IsNullOrWhiteSpace($CleanupFailedTest))) {
    throw "InspectionMode cannot be combined with validation, retained resources, or cleanup modes."
}
if (-not [string]::IsNullOrWhiteSpace($InspectionId) -and -not $InspectionMode) {
    throw "InspectionId can only be used with InspectionMode."
}
if (-not [string]::IsNullOrWhiteSpace($CleanupInspection) -and ($ValidateOnly -or $KeepTestResources)) {
    throw "CleanupInspection cannot be combined with ValidateOnly or KeepTestResources."
}
if (-not [string]::IsNullOrWhiteSpace($CleanupFailedTest) -and
    ($ValidateOnly -or $KeepTestResources -or $InspectionMode -or
        -not [string]::IsNullOrWhiteSpace($InspectionId) -or
        -not [string]::IsNullOrWhiteSpace($CleanupInspection) -or
        -not [string]::IsNullOrWhiteSpace($ShowInspectionInfo) -or
        -not [string]::IsNullOrWhiteSpace($ImageOcid))) {
    throw "CleanupFailedTest cannot be combined with build, test, inspection, or other cleanup modes."
}
if (-not [string]::IsNullOrWhiteSpace($ShowInspectionInfo) -and
    ($ValidateOnly -or $KeepTestResources -or $InspectionMode -or
        -not [string]::IsNullOrWhiteSpace($InspectionId) -or
        -not [string]::IsNullOrWhiteSpace($CleanupInspection) -or
        -not [string]::IsNullOrWhiteSpace($CleanupFailedTest) -or
        -not [string]::IsNullOrWhiteSpace($ImageOcid))) {
    throw "ShowInspectionInfo cannot be combined with build, test, inspection, or cleanup modes."
}
if (-not [string]::IsNullOrWhiteSpace($InspectionId) -and $InspectionId -notmatch '^inspection-[0-9]{14}-[0-9]+$') {
    throw "InspectionId must use the generated inspection-YYYYMMDDHHMMSS-PID format."
}
if (-not [string]::IsNullOrWhiteSpace($CleanupInspection) -and $CleanupInspection -notmatch '^inspection-[0-9]{14}-[0-9]+$') {
    throw "CleanupInspection must use the generated inspection-YYYYMMDDHHMMSS-PID format."
}
if (-not [string]::IsNullOrWhiteSpace($CleanupFailedTest) -and $CleanupFailedTest -notmatch '^packer-test-[0-9]{14}-[0-9]+$') {
    throw "CleanupFailedTest must use the generated packer-test-YYYYMMDDHHMMSS-PID format."
}
if (-not [string]::IsNullOrWhiteSpace($ShowInspectionInfo) -and $ShowInspectionInfo -notmatch '^inspection-[0-9]{14}-[0-9]+$') {
    throw "ShowInspectionInfo must use the generated inspection-YYYYMMDDHHMMSS-PID format."
}

function Write-Step {
    param([string]$Message)
    Write-Host "[terraform-test] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[terraform-test] PASS: $Message" -ForegroundColor Green
}

function Get-InspectionReceiptPath {
    param([string]$Id)

    if ($Id -notmatch '^inspection-[0-9]{14}-[0-9]+$') {
        throw "Inspection ID is invalid: $Id"
    }

    return Join-Path $AutomationDirectory "$Id.json"
}

function Assert-NotReparsePoint {
    param(
        [string]$Path,
        [string]$Label,
        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($AllowMissing) {
            return
        }
        throw "$Label does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a symbolic link, junction, or reparse point: $Path"
    }
}

function Assert-NoReparseAncestors {
    param(
        [string]$Path,
        [string]$Label
    )

    $cursor = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label must not use a symbolic link, junction, or reparse-point ancestor: $cursor"
            }
        }

        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or $parent.FullName -eq $cursor) {
            break
        }
        $cursor = $parent.FullName
    }
}

function Test-PathInsideRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if ([string]::Equals($fullPath, $fullRoot, $comparison)) {
        return $true
    }
    return $fullPath.StartsWith(
        $fullRoot + [System.IO.Path]::DirectorySeparatorChar,
        $comparison
    )
}

function Remove-HclComments {
    param([string]$Text)

    $output = New-Object System.Text.StringBuilder
    $inString = $false
    $inLineComment = $false
    $inBlockComment = $false
    $index = 0
    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        $nextCharacter = if (($index + 1) -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($character -eq "`n") {
                $inLineComment = $false
                [void]$output.Append($character)
            }
            else {
                [void]$output.Append(" ")
            }
        }
        elseif ($inBlockComment) {
            if ($character -eq "*" -and $nextCharacter -eq "/") {
                [void]$output.Append("  ")
                $index++
                $inBlockComment = $false
            }
            elseif ($character -eq "`n") {
                [void]$output.Append($character)
            }
            else {
                [void]$output.Append(" ")
            }
        }
        elseif ($inString) {
            [void]$output.Append($character)
            if ($character -eq "\" -and $nextCharacter -ne [char]0) {
                [void]$output.Append($nextCharacter)
                $index++
            }
            elseif ($character -eq '"') {
                $inString = $false
            }
        }
        elseif ($character -eq '"') {
            $inString = $true
            [void]$output.Append($character)
        }
        elseif ($character -eq "#") {
            $inLineComment = $true
            [void]$output.Append(" ")
        }
        elseif ($character -eq "/" -and $nextCharacter -eq "/") {
            [void]$output.Append("  ")
            $index++
            $inLineComment = $true
        }
        elseif ($character -eq "/" -and $nextCharacter -eq "*") {
            [void]$output.Append("  ")
            $index++
            $inBlockComment = $true
        }
        else {
            [void]$output.Append($character)
        }
        $index++
    }

    return $output.ToString()
}

function Assert-TrustedTerraformSourceTree {
    param([string]$Root)

    Assert-NoReparseAncestors -Path $Root -Label "Terraform project"
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer) {
        throw "Terraform project root must be a directory: $Root"
    }

    $terraformFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push([System.IO.DirectoryInfo]$rootItem)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            if ($entry.PSIsContainer -and $entry.Name -in @(".git", ".terraform", ".automation")) {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Terraform generated directory must not be a link or reparse point: $($entry.FullName)"
                }
                continue
            }
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Terraform source tree must not contain links or reparse points: $($entry.FullName)"
            }
            if ($entry.PSIsContainer) {
                $pending.Push([System.IO.DirectoryInfo]$entry)
                continue
            }
            if ($entry.Name.EndsWith(".tf.json", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Terraform JSON configuration is not supported by the trusted runner: $($entry.FullName)"
            }
            if ($entry.Name.EndsWith(".tf", [System.StringComparison]::OrdinalIgnoreCase)) {
                $terraformFiles.Add([System.IO.FileInfo]$entry)
            }
        }
    }

    if ($terraformFiles.Count -eq 0) {
        throw "Terraform project contains no trusted .tf source files."
    }

    $bannedPatterns = [ordered]@{
        '\bprovisioner\s+"' = "provisioner blocks"
        '\blocal-exec\b' = "local-exec"
        '\bremote-exec\b' = "remote-exec"
        '\bdata\s+"external"' = "the external data source"
        '\bdata\s+"terraform_remote_state"' = "terraform_remote_state"
        '\bresource\s+"null_resource"' = "null_resource"
        '\bresource\s+"terraform_data"' = "terraform_data"
        '\bbackend\s+"' = "explicit Terraform backends"
        '\bcloud\s*\{' = "Terraform cloud execution"
    }
    $approvedProviderSources = @("oracle/oci", "hashicorp/random", "hashicorp/local")
    $approvedProviderBlocks = @("oci", "random", "local")

    foreach ($file in $terraformFiles) {
        $text = Remove-HclComments -Text (Get-Content -LiteralPath $file.FullName -Raw)
        foreach ($pattern in $bannedPatterns.Keys) {
            if ($text -match $pattern) {
                throw "Trusted Terraform runner rejects $($bannedPatterns[$pattern]): $($file.FullName)"
            }
        }

        foreach ($providerMatch in [regex]::Matches($text, '\bprovider\s+"([^"]+)"')) {
            if ($providerMatch.Groups[1].Value -notin $approvedProviderBlocks) {
                throw "Terraform provider is not approved: $($providerMatch.Groups[1].Value)"
            }
        }

        foreach ($blockMatch in [regex]::Matches($text, '\b(resource|data)\s+"([^"]+)"')) {
            $mode = $blockMatch.Groups[1].Value
            $resourceType = $blockMatch.Groups[2].Value
            if ($mode -eq "resource" -and $resourceType -notmatch '^(oci_|random_|local_sensitive_file$)') {
                throw "Terraform managed resource uses an unapproved provider type: $resourceType"
            }
            if ($mode -eq "data" -and $resourceType -notmatch '^oci_') {
                throw "Terraform data source uses an unapproved provider type: $resourceType"
            }
        }

        foreach ($sourceMatch in [regex]::Matches($text, '\bsource\s*=\s*"([^"]+)"')) {
            $source = $sourceMatch.Groups[1].Value
            if ($source -in $approvedProviderSources) {
                continue
            }
            if ($source.StartsWith("./") -or $source.StartsWith("../")) {
                $candidate = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $source))
                if (-not (Test-PathInsideRoot -Path $candidate -Root $Root)) {
                    throw "Terraform local module escapes the trusted project root: $source"
                }
                if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                    throw "Terraform local module does not exist: $candidate"
                }
                Assert-NoReparseAncestors -Path $candidate -Label "Terraform local module"
                continue
            }
            throw "Terraform remote or unapproved source is not allowed: $source"
        }
    }
}

function Enter-ProjectTerraformLock {
    param([string]$AutomationPath)

    Assert-NoReparseAncestors -Path $AutomationPath -Label "Terraform automation directory"
    New-Item -ItemType Directory -Path $AutomationPath -Force | Out-Null
    Assert-NoReparseAncestors -Path $AutomationPath -Label "Terraform automation directory"
    Assert-NotReparsePoint -Path $AutomationPath -Label "Terraform automation directory"

    $lockPath = Join-Path $AutomationPath "marketplace-private-test.lock"
    Assert-NoReparseAncestors -Path $lockPath -Label "Terraform project lock"
    Assert-NotReparsePoint -Path $lockPath -Label "Terraform project lock" -AllowMissing
    try {
        $stream = New-Object System.IO.FileStream(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        throw "Another Terraform or Marketplace test appears active. If it is not, remove $lockPath."
    }

    try {
        $content = [System.Text.Encoding]::ASCII.GetBytes("$PID`n")
        $stream.Write($content, 0, $content.Length)
        $stream.Flush($true)
    }
    catch {
        $stream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        throw
    }

    return [pscustomobject]@{
        Path = $lockPath
        Stream = $stream
    }
}

function Exit-ProjectTerraformLock {
    param([object]$Lock)

    if ($null -eq $Lock) {
        return
    }
    try {
        if ($null -ne $Lock.Stream) {
            $Lock.Stream.Dispose()
        }
    }
    finally {
        Assert-NoReparseAncestors -Path ([string]$Lock.Path) -Label "Terraform project lock"
        Assert-NotReparsePoint -Path ([string]$Lock.Path) -Label "Terraform project lock" -AllowMissing
        Remove-Item -LiteralPath ([string]$Lock.Path) -Force -ErrorAction SilentlyContinue
    }
}

function Write-InspectionReceipt {
    param(
        [string]$Path,
        [object]$Receipt
    )

    $directory = Split-Path -Parent $Path
    Assert-NoReparseAncestors -Path $directory -Label "Inspection automation directory"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Assert-NoReparseAncestors -Path $directory -Label "Inspection automation directory"
    Assert-NotReparsePoint -Path $directory -Label "Inspection automation directory"
    Assert-NoReparseAncestors -Path $Path -Label "Inspection receipt"
    Assert-NotReparsePoint -Path $Path -Label "Inspection receipt" -AllowMissing
    $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
    $backupPath = ""
    $backupStream = $null
    try {
        $json = ($Receipt | ConvertTo-Json -Depth 6) + [Environment]::NewLine
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backupPath = Join-Path $directory (".{0}.{1}.bak" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
            Assert-NotReparsePoint -Path $backupPath -Label "Inspection receipt backup" -AllowMissing
            $backupStream = New-Object System.IO.FileStream(
                $backupPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $backupStream.Dispose()
            $backupStream = $null
            Assert-NotReparsePoint -Path $backupPath -Label "Inspection receipt backup"
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force
            $backupPath = ""
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ($null -ne $backupStream) {
            $backupStream.Dispose()
        }
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-ExistingFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label was not provided."
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $resolved -or -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
    Assert-NoReparseAncestors -Path $Path -Label $Label
    Assert-NoReparseAncestors -Path $resolved.Path -Label $Label
    Assert-NotReparsePoint -Path $Path -Label $Label
    Assert-NotReparsePoint -Path $resolved.Path -Label $Label

    return $resolved.Path
}

function Resolve-CommandPath {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command is not installed or not on PATH: $Name"
    }

    return $command.Source
}

function Resolve-ApplicationPath {
    param([string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    throw "Required application is not installed or not on PATH: $($Names -join ', ')"
}

function Format-Command {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $displayArguments = @($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    })
    return ((Split-Path -Leaf $FilePath) + " " + ($displayArguments -join " ")).Trim()
}

function Invoke-NativeCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$CaptureOutput,
        [switch]$SuppressOutput,
        [switch]$SensitiveOutput
    )

    Write-Step (Format-Command -FilePath $FilePath -Arguments $Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        if ($CaptureOutput) {
            $commandOutput = @(& $FilePath @Arguments 2>&1)
        }
        elseif ($SuppressOutput) {
            & $FilePath @Arguments *> $null
            $commandOutput = @()
        }
        else {
            & $FilePath @Arguments
            $commandOutput = @()
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        if ($CaptureOutput -and -not $SensitiveOutput -and $commandOutput.Count -gt 0) {
            throw "Command failed with exit code ${exitCode}: $($commandOutput -join [Environment]::NewLine)"
        }
        throw "Command failed with exit code ${exitCode}: $(Format-Command -FilePath $FilePath -Arguments $Arguments)"
    }

    if ($CaptureOutput) {
        return (($commandOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    }
}

function Invoke-TerraformJson {
    param(
        [string]$TerraformPath,
        [string[]]$Arguments,
        [string]$Label
    )

    Write-Step (Format-Command -FilePath $TerraformPath -Arguments $Arguments)
    $stderrPath = Join-Path $AutomationDirectory (".terraform-json-{0}-{1}.stderr" -f $PID, [Guid]::NewGuid().ToString("N"))
    Assert-NoReparseAncestors -Path $stderrPath -Label "$Label diagnostic file"
    Assert-NotReparsePoint -Path $stderrPath -Label "$Label diagnostic file" -AllowMissing
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $commandOutput = @(& $TerraformPath @Arguments 2> $stderrPath)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    try {
        if ($exitCode -ne 0) {
            throw "$Label failed with exit code $exitCode. Terraform diagnostic output was not echoed because state and plan data may be sensitive."
        }
        $json = (($commandOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
        try {
            return ($json | ConvertFrom-Json)
        }
        catch {
            throw "$Label did not return valid JSON."
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RequiredJsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Label
    )

    if ($null -eq $Object) {
        throw "$Label is missing."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Label is missing property '$Name'."
    }
    return $property.Value
}

function Get-OptionalJsonProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-PlanVariableValue {
    param(
        [object]$Plan,
        [string]$Name
    )

    $variables = Get-RequiredJsonProperty -Object $Plan -Name "variables" -Label "Terraform plan"
    $entry = Get-RequiredJsonProperty -Object $variables -Name $Name -Label "Terraform plan variables"
    return Get-RequiredJsonProperty -Object $entry -Name "value" -Label "Terraform plan variable '$Name'"
}

function Test-PlanBooleanValue {
    param(
        [object]$Value,
        [bool]$Expected
    )

    if ($Value -is [bool]) {
        return $Value -eq $Expected
    }

    if ($Value -is [string]) {
        return $Value -ceq $Expected.ToString().ToLowerInvariant()
    }

    return $false
}

function Get-NormalizedPlanResources {
    param([object]$Plan)

    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($change in @(Get-RequiredJsonProperty -Object $Plan -Name "resource_changes" -Label "Terraform plan")) {
        $modeValue = Get-OptionalJsonProperty -Object $change -Name "mode"
        $mode = if ([string]::IsNullOrWhiteSpace([string]$modeValue)) { "managed" } else { [string]$modeValue }
        $changeBody = Get-RequiredJsonProperty -Object $change -Name "change" -Label "Terraform resource change"
        $actions = @(Get-RequiredJsonProperty -Object $changeBody -Name "actions" -Label "Terraform resource change")
        if ($mode -eq "managed") {
            if ($actions.Count -ne 1 -or [string]$actions[0] -ne "create") {
                throw "Fresh custom-image tests accept only create actions for managed resources."
            }
        }
        elseif ($mode -eq "data") {
            if ($actions.Count -ne 1 -or [string]$actions[0] -notin @("read", "no-op")) {
                throw "Custom-image test data sources may only be read."
            }
        }
        else {
            throw "Terraform plan contains an unsupported resource mode: $mode"
        }

        $after = Get-RequiredJsonProperty -Object $changeBody -Name "after" -Label "Terraform resource change"
        if ($null -eq $after) {
            throw "Terraform plan does not expose complete post-apply values."
        }
        $normalized.Add([pscustomobject]@{
            Address = [string](Get-RequiredJsonProperty -Object $change -Name "address" -Label "Terraform resource change")
            Mode = $mode
            Type = [string](Get-RequiredJsonProperty -Object $change -Name "type" -Label "Terraform resource change")
            ProviderName = [string](Get-RequiredJsonProperty -Object $change -Name "provider_name" -Label "Terraform resource change")
            Values = $after
            Unknown = Get-OptionalJsonProperty -Object $changeBody -Name "after_unknown"
        })
    }
    return $normalized.ToArray()
}

function Add-NormalizedStateResources {
    param(
        [object]$Module,
        [System.Collections.Generic.List[object]]$Destination
    )

    if ($null -eq $Module) {
        return
    }
    foreach ($resource in @(Get-OptionalJsonProperty -Object $Module -Name "resources")) {
        if ($null -eq $resource) {
            continue
        }
        $modeValue = Get-OptionalJsonProperty -Object $resource -Name "mode"
        $mode = if ([string]::IsNullOrWhiteSpace([string]$modeValue)) { "managed" } else { [string]$modeValue }
        $Destination.Add([pscustomobject]@{
            Address = [string](Get-RequiredJsonProperty -Object $resource -Name "address" -Label "Terraform state resource")
            Mode = $mode
            Type = [string](Get-RequiredJsonProperty -Object $resource -Name "type" -Label "Terraform state resource")
            ProviderName = [string](Get-RequiredJsonProperty -Object $resource -Name "provider_name" -Label "Terraform state resource")
            Values = Get-RequiredJsonProperty -Object $resource -Name "values" -Label "Terraform state resource"
            Unknown = $null
        })
    }
    foreach ($child in @(Get-OptionalJsonProperty -Object $Module -Name "child_modules")) {
        if ($null -ne $child) {
            Add-NormalizedStateResources -Module $child -Destination $Destination
        }
    }
}

function Get-NormalizedStateResources {
    param([object]$State)

    $resources = New-Object System.Collections.Generic.List[object]
    $values = Get-OptionalJsonProperty -Object $State -Name "values"
    if ($null -ne $values) {
        Add-NormalizedStateResources `
            -Module (Get-OptionalJsonProperty -Object $values -Name "root_module") `
            -Destination $resources
    }
    return $resources.ToArray()
}

function Add-ConfigurationResources {
    param(
        [object]$Module,
        [System.Collections.Generic.List[object]]$Destination
    )

    if ($null -eq $Module) {
        return
    }
    foreach ($resource in @(Get-OptionalJsonProperty -Object $Module -Name "resources")) {
        if ($null -ne $resource) {
            $Destination.Add($resource)
        }
    }
    $moduleCalls = Get-OptionalJsonProperty -Object $Module -Name "module_calls"
    if ($null -ne $moduleCalls) {
        foreach ($property in $moduleCalls.PSObject.Properties) {
            $nested = Get-OptionalJsonProperty -Object $property.Value -Name "module"
            if ($null -ne $nested) {
                Add-ConfigurationResources -Module $nested -Destination $Destination
            }
        }
    }
}

function Get-JsonReferences {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string] -or $Value.GetType().IsPrimitive) {
        return @()
    }

    $references = New-Object System.Collections.Generic.List[string]
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject])) {
        foreach ($item in $Value) {
            foreach ($reference in @(Get-JsonReferences -Value $item)) {
                $references.Add([string]$reference)
            }
        }
        return $references.ToArray()
    }

    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -eq "references") {
            foreach ($reference in @($property.Value)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$reference)) {
                    $references.Add([string]$reference)
                }
            }
        }
        else {
            foreach ($reference in @(Get-JsonReferences -Value $property.Value)) {
                $references.Add([string]$reference)
            }
        }
    }
    return $references.ToArray()
}

function Assert-ConfigurationReferences {
    param([object]$Plan)

    $configuration = Get-RequiredJsonProperty -Object $Plan -Name "configuration" -Label "Terraform plan"
    $providerConfiguration = Get-RequiredJsonProperty `
        -Object $configuration `
        -Name "provider_config" `
        -Label "Terraform plan configuration"
    $approvedProviders = @(
        "registry.terraform.io/oracle/oci",
        "registry.terraform.io/hashicorp/random",
        "registry.terraform.io/hashicorp/local"
    )
    foreach ($provider in $providerConfiguration.PSObject.Properties) {
        $fullName = [string](Get-RequiredJsonProperty `
            -Object $provider.Value `
            -Name "full_name" `
            -Label "Terraform provider configuration")
        if ($fullName -notin $approvedProviders) {
            throw "Terraform plan uses an unapproved provider: $fullName"
        }
    }

    $configurationResources = New-Object System.Collections.Generic.List[object]
    Add-ConfigurationResources `
        -Module (Get-RequiredJsonProperty -Object $configuration -Name "root_module" -Label "Terraform plan configuration") `
        -Destination $configurationResources

    $requirements = [ordered]@{
        "data.oci_identity_availability_domain.ad" = @(
            "var.ociTenancyOcid"
        )
        "data.oci_core_subnet.public" = @(
            "var.ociPublicSubnetOcid"
        )
        "oci_core_network_security_group.workshop_access" = @(
            "var.ociCompartmentOcid",
            "data.oci_core_subnet.public"
        )
        "oci_core_network_security_group_security_rule.workshop_tcp_ingress" = @(
            "oci_core_network_security_group.workshop_access",
            "var.tester_source_cidr"
        )
        "oci_core_instance.workshop" = @(
            "oci_core_network_security_group.workshop_access",
            "data.oci_identity_availability_domain.ad",
            "var.ociCompartmentOcid",
            "var.ociPublicSubnetOcid",
            "var.instance_image_id"
        )
    }
    foreach ($address in $requirements.Keys) {
        $matches = @($configurationResources | Where-Object {
            [string](Get-OptionalJsonProperty -Object $_ -Name "address") -eq $address
        })
        if ($matches.Count -ne 1) {
            throw "Terraform plan configuration must contain exactly one '$address' block."
        }
        $references = @(Get-JsonReferences -Value (Get-OptionalJsonProperty -Object $matches[0] -Name "expressions"))
        foreach ($requiredReference in $requirements[$address]) {
            $found = @($references | Where-Object {
                $_ -eq $requiredReference -or
                $_.StartsWith("$requiredReference.", [System.StringComparison]::Ordinal) -or
                $_.StartsWith("$requiredReference[", [System.StringComparison]::Ordinal)
            }).Count -gt 0
            if (-not $found) {
                throw "Terraform plan configuration '$address' is missing required reference '$requiredReference'."
            }
        }
    }
}

function Assert-ExactPortSet {
    param(
        [object[]]$Actual,
        [int[]]$Expected,
        [string]$Label
    )

    $actualPorts = @($Actual | ForEach-Object { [int]$_ } | Sort-Object)
    $expectedPorts = @($Expected | ForEach-Object { [int]$_ } | Sort-Object)
    if ($actualPorts.Count -ne $expectedPorts.Count -or
        ($actualPorts -join ",") -ne ($expectedPorts -join ",")) {
        throw "$Label does not match the exact expected TCP ports."
    }
}

function Get-DirectImageExpectation {
    param(
        [object]$Plan,
        [string]$ExpectedImageOcid,
        [int[]]$ExpectedPorts
    )

    $compartmentOcid = [string](Get-PlanVariableValue -Plan $Plan -Name "ociCompartmentOcid")
    $tenancyOcid = [string](Get-PlanVariableValue -Plan $Plan -Name "ociTenancyOcid")
    $subnetOcid = [string](Get-PlanVariableValue -Plan $Plan -Name "ociPublicSubnetOcid")
    $sourceCidr = [string](Get-PlanVariableValue -Plan $Plan -Name "tester_source_cidr")
    if ($compartmentOcid -notmatch '^ocid1\.(compartment|tenancy)\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
        throw "Terraform plan contains an invalid target compartment OCID."
    }
    if ($tenancyOcid -notmatch '^ocid1\.tenancy\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
        throw "Terraform plan contains an invalid tenancy OCID."
    }
    if ($subnetOcid -notmatch '^ocid1\.subnet\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
        throw "Terraform plan contains an invalid public subnet OCID."
    }
    if ($sourceCidr -notmatch '^([^/]+)/32$') {
        throw "tester_source_cidr must be one IPv4 /32 for the trusted custom-image test."
    }
    $parsedSourceIp = $null
    if (-not [System.Net.IPAddress]::TryParse($Matches[1], [ref]$parsedSourceIp) -or
        $parsedSourceIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        "$($parsedSourceIp.ToString())/32" -ne $sourceCidr) {
        throw "tester_source_cidr must be a canonical IPv4 /32."
    }

    if ([string](Get-PlanVariableValue -Plan $Plan -Name "instance_image_id") -ne $ExpectedImageOcid) {
        throw "Terraform plan image does not match ImageOcid."
    }
    $useMarketplace = Get-PlanVariableValue -Plan $Plan -Name "use_marketplace_image"
    $enableNsg = Get-PlanVariableValue -Plan $Plan -Name "enable_test_access_nsg"
    $exposeLogins = Get-PlanVariableValue -Plan $Plan -Name "expose_login_outputs"
    if (-not (Test-PlanBooleanValue -Value $useMarketplace -Expected $false)) {
        throw "Direct custom-image mode must keep use_marketplace_image=false."
    }
    if (-not (Test-PlanBooleanValue -Value $enableNsg -Expected $true)) {
        throw "Direct custom-image mode must create its temporary test NSG."
    }
    if (-not (Test-PlanBooleanValue -Value $exposeLogins -Expected $false)) {
        throw "Direct custom-image mode must keep expose_login_outputs=false."
    }
    if ([int](Get-PlanVariableValue -Plan $Plan -Name "instance_count") -ne 1) {
        throw "Direct custom-image mode must create exactly one VM."
    }
    Assert-ExactPortSet `
        -Actual @(Get-PlanVariableValue -Plan $Plan -Name "allowed_tcp_ports") `
        -Expected $ExpectedPorts `
        -Label "Terraform plan allowed_tcp_ports"

    $planInstances = @(
        Get-NormalizedPlanResources -Plan $Plan |
            Where-Object { $_.Mode -eq "managed" -and $_.Type -eq "oci_core_instance" }
    )
    if ($planInstances.Count -ne 1) {
        throw "Terraform plan must contain exactly one VM."
    }
    $availabilityDomain = [string](Get-RequiredJsonProperty `
        -Object $planInstances[0].Values `
        -Name "availability_domain" `
        -Label "Terraform plan VM")
    if ([string]::IsNullOrWhiteSpace($availabilityDomain)) {
        throw "Terraform plan VM is missing its selected availability domain."
    }

    return [pscustomobject]@{
        CompartmentOcid = $compartmentOcid
        TenancyOcid = $tenancyOcid
        SubnetOcid = $subnetOcid
        SourceCidr = $sourceCidr
        ImageOcid = $ExpectedImageOcid
        AvailabilityDomain = $availabilityDomain
        Ports = @($ExpectedPorts | Sort-Object)
    }
}

function Assert-DirectImageTopology {
    param(
        [object[]]$Resources,
        [object]$Expected,
        [string]$Label,
        [switch]$State
    )

    $approvedManagedTypes = @(
        "oci_core_instance",
        "oci_core_network_security_group",
        "oci_core_network_security_group_security_rule",
        "oci_database_autonomous_database",
        "oci_database_autonomous_database_wallet",
        "random_password",
        "local_sensitive_file"
    )
    $managed = @($Resources | Where-Object { $_.Mode -eq "managed" })
    $unsupportedManaged = @($managed | Where-Object { $_.Type -notin $approvedManagedTypes } | ForEach-Object { $_.Type } | Sort-Object -Unique)
    if ($unsupportedManaged.Count -gt 0) {
        throw "$Label contains unapproved managed resource types: $($unsupportedManaged -join ', ')"
    }

    foreach ($resource in $Resources) {
        $expectedProvider = switch ($resource.Type) {
            "random_password" { "registry.terraform.io/hashicorp/random" }
            "local_sensitive_file" { "registry.terraform.io/hashicorp/local" }
            default { "registry.terraform.io/oracle/oci" }
        }
        if ($resource.ProviderName -ne $expectedProvider) {
            throw "$Label resource '$($resource.Address)' uses an unapproved provider."
        }
    }

    $instances = @($managed | Where-Object { $_.Type -eq "oci_core_instance" })
    $networkGroups = @($managed | Where-Object { $_.Type -eq "oci_core_network_security_group" })
    $networkRules = @($managed | Where-Object { $_.Type -eq "oci_core_network_security_group_security_rule" })
    $passwords = @($managed | Where-Object { $_.Type -eq "random_password" })
    $autonomousDatabases = @($managed | Where-Object { $_.Type -eq "oci_database_autonomous_database" })
    $wallets = @($managed | Where-Object { $_.Type -eq "oci_database_autonomous_database_wallet" })
    $protectedFiles = @($managed | Where-Object { $_.Type -eq "local_sensitive_file" })
    $walletFiles = @($protectedFiles | Where-Object { $_.Address -eq "module.adb.local_sensitive_file.wallet" })
    $datapumpFiles = @($protectedFiles | Where-Object { $_.Address -eq "module.adb.local_sensitive_file.datapump[0]" })
    if ($instances.Count -ne 1 -or $networkGroups.Count -ne 1) {
        throw "$Label must contain exactly one VM and one temporary NSG."
    }
    if ($networkRules.Count -ne $Expected.Ports.Count) {
        throw "$Label must contain exactly one ingress rule per expected TCP port."
    }
    if ($passwords.Count -lt 3) {
        throw "$Label must contain the three required image metadata passwords."
    }
    if ($autonomousDatabases.Count -ne 1 -or $wallets.Count -ne 1 -or $walletFiles.Count -ne 1 -or $datapumpFiles.Count -ne 1 -or $protectedFiles.Count -ne 2) {
        throw "$Label must contain exactly one ADB, ADB wallet, protected wallet file, and protected Data Pump file."
    }
    if ($autonomousDatabases[0].Address -ne "module.adb.oci_database_autonomous_database.pilot" -or
        $wallets[0].Address -ne "module.adb.oci_database_autonomous_database_wallet.pilot") {
        throw "$Label contains an unapproved ADB resource address."
    }
    foreach ($password in $passwords) {
        if ($password.Address -notmatch '^module\.image_metadata\.random_password\.(db_password|app_password|vnc_password|additional(\[.+\])?)$') {
            throw "$Label contains an unapproved random_password resource: $($password.Address)"
        }
    }
    foreach ($requiredPassword in @("db_password", "app_password", "vnc_password")) {
        $passwordCount = @($passwords | Where-Object {
            $_.Address -eq "module.image_metadata.random_password.$requiredPassword"
        }).Count
        if ($passwordCount -ne 1) {
            throw "$Label must contain exactly one random_password.$requiredPassword resource."
        }
    }

    $networkGroupValues = $networkGroups[0].Values
    $instanceValues = $instances[0].Values
    if ([string](Get-RequiredJsonProperty -Object $networkGroupValues -Name "compartment_id" -Label "$Label NSG") -ne $Expected.CompartmentOcid) {
        throw "$Label temporary NSG used a different compartment."
    }
    $tags = Get-RequiredJsonProperty -Object $networkGroupValues -Name "freeform_tags" -Label "$Label NSG"
    if ([string](Get-RequiredJsonProperty -Object $tags -Name "purpose" -Label "$Label NSG tags") -ne "temporary-image-test-access") {
        throw "$Label NSG is not marked as temporary image test access."
    }
    if ([string](Get-RequiredJsonProperty -Object $instanceValues -Name "compartment_id" -Label "$Label VM") -ne $Expected.CompartmentOcid) {
        throw "$Label VM used a different compartment."
    }
    if ([string](Get-RequiredJsonProperty -Object $instanceValues -Name "availability_domain" -Label "$Label VM") -ne
        $Expected.AvailabilityDomain) {
        throw "$Label VM is not attached to the planned availability domain."
    }
    $sourceDetails = @(Get-RequiredJsonProperty -Object $instanceValues -Name "source_details" -Label "$Label VM")
    if ($sourceDetails.Count -ne 1 -or
        [string](Get-RequiredJsonProperty -Object $sourceDetails[0] -Name "source_id" -Label "$Label VM source") -ne $Expected.ImageOcid -or
        [string](Get-RequiredJsonProperty -Object $sourceDetails[0] -Name "source_type" -Label "$Label VM source") -ne "image") {
        throw "$Label VM did not use the exact requested custom image."
    }
    $vnicDetails = @(Get-RequiredJsonProperty -Object $instanceValues -Name "create_vnic_details" -Label "$Label VM")
    if ($vnicDetails.Count -ne 1 -or
        -not (Test-PlanBooleanValue `
            -Value (Get-RequiredJsonProperty -Object $vnicDetails[0] -Name "assign_public_ip" -Label "$Label VM VNIC") `
            -Expected $true) -or
        [string](Get-RequiredJsonProperty -Object $vnicDetails[0] -Name "subnet_id" -Label "$Label VM VNIC") -ne $Expected.SubnetOcid) {
        throw "$Label VM did not use the exact public test VNIC and subnet."
    }

    $actualPorts = New-Object System.Collections.Generic.List[int]
    foreach ($ruleResource in $networkRules) {
        $rule = $ruleResource.Values
        if ([string](Get-RequiredJsonProperty -Object $rule -Name "direction" -Label "$Label ingress rule") -ne "INGRESS" -or
            [string](Get-RequiredJsonProperty -Object $rule -Name "protocol" -Label "$Label ingress rule") -ne "6" -or
            [string](Get-RequiredJsonProperty -Object $rule -Name "source" -Label "$Label ingress rule") -ne $Expected.SourceCidr -or
            [string](Get-RequiredJsonProperty -Object $rule -Name "source_type" -Label "$Label ingress rule") -ne "CIDR_BLOCK" -or
            (Get-RequiredJsonProperty -Object $rule -Name "stateless" -Label "$Label ingress rule") -isnot [bool] -or
            (Get-RequiredJsonProperty -Object $rule -Name "stateless" -Label "$Label ingress rule")) {
            throw "$Label contains an ingress rule outside the restricted TCP /32 policy."
        }
        $tcpOptions = @(Get-RequiredJsonProperty -Object $rule -Name "tcp_options" -Label "$Label ingress rule")
        if ($tcpOptions.Count -ne 1) {
            throw "$Label contains malformed TCP options."
        }
        $ranges = @(Get-RequiredJsonProperty -Object $tcpOptions[0] -Name "destination_port_range" -Label "$Label ingress rule")
        if ($ranges.Count -ne 1) {
            throw "$Label contains malformed TCP destination ports."
        }
        $minimum = [int](Get-RequiredJsonProperty -Object $ranges[0] -Name "min" -Label "$Label ingress port")
        $maximum = [int](Get-RequiredJsonProperty -Object $ranges[0] -Name "max" -Label "$Label ingress port")
        if ($minimum -ne $maximum) {
            throw "$Label contains a multi-port ingress range."
        }
        $actualPorts.Add($minimum)
    }
    Assert-ExactPortSet -Actual $actualPorts.ToArray() -Expected $Expected.Ports -Label "$Label ingress rules"

    if ($State) {
        $networkGroupId = [string](Get-RequiredJsonProperty -Object $networkGroupValues -Name "id" -Label "$Label NSG")
        if ($networkGroupId -notmatch '^ocid1\.networksecuritygroup\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
            throw "$Label NSG is missing its OCID."
        }
        $nsgIds = @(Get-RequiredJsonProperty -Object $vnicDetails[0] -Name "nsg_ids" -Label "$Label VM VNIC")
        if ($nsgIds.Count -ne 1 -or [string]$nsgIds[0] -ne $networkGroupId) {
            throw "$Label VM is not attached only to the temporary test NSG."
        }
        foreach ($ruleResource in $networkRules) {
            if ([string](Get-RequiredJsonProperty `
                -Object $ruleResource.Values `
                -Name "network_security_group_id" `
                -Label "$Label ingress rule") -ne $networkGroupId) {
                throw "$Label ingress rule is attached to a different NSG."
            }
        }
    }
}

function Assert-DirectImagePlan {
    param(
        [string]$TerraformPath,
        [string]$PlanPath,
        [string]$ExpectedImageOcid,
        [int[]]$ExpectedPorts
    )

    $plan = Invoke-TerraformJson `
        -TerraformPath $TerraformPath `
        -Arguments @("show", "-json", $PlanPath) `
        -Label "Terraform plan inspection"
    $expected = Get-DirectImageExpectation `
        -Plan $plan `
        -ExpectedImageOcid $ExpectedImageOcid `
        -ExpectedPorts $ExpectedPorts
    Assert-ConfigurationReferences -Plan $plan
    Assert-DirectImageTopology `
        -Resources @(Get-NormalizedPlanResources -Plan $plan) `
        -Expected $expected `
        -Label "Terraform plan"
    Write-Pass "Terraform plan is restricted to the approved direct custom-image topology"
    return $expected
}

function Assert-DirectImageState {
    param(
        [string]$TerraformPath,
        [object]$Expected
    )

    $state = Invoke-TerraformJson `
        -TerraformPath $TerraformPath `
        -Arguments @("show", "-json") `
        -Label "Terraform state inspection"
    Assert-DirectImageTopology `
        -Resources @(Get-NormalizedStateResources -State $state) `
        -Expected $Expected `
        -Label "Terraform state" `
        -State
    Write-Pass "Terraform state proves the approved VM, temporary NSG, rules, subnet, and image"
}

function Assert-DestroyedTerraformState {
    param([string]$TerraformPath)

    $state = Invoke-TerraformJson `
        -TerraformPath $TerraformPath `
        -Arguments @("show", "-json") `
        -Label "Destroyed Terraform state inspection"
    $managed = @(
        Get-NormalizedStateResources -State $state |
            Where-Object { $_.Mode -eq "managed" }
    )
    if ($managed.Count -gt 0) {
        throw "Terraform destroy left managed resources in state: $($managed.Address -join ', ')"
    }
    Write-Pass "Terraform state contains zero managed resources after destroy"
}

function Assert-TerraformWorkspaceAbsent {
    param(
        [string]$TerraformPath,
        [string]$Workspace
    )

    $workspaceOutput = Invoke-NativeCommand `
        -FilePath $TerraformPath `
        -Arguments @("workspace", "list", "-no-color") `
        -CaptureOutput
    $workspaceNames = @(
        $workspaceOutput -split "`r?`n" |
            ForEach-Object { $_.Trim().TrimStart("*").Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($workspaceNames -contains $Workspace) {
        throw "Terraform workspace '$Workspace' still exists after deletion."
    }
    Write-Pass "Terraform workspace '$Workspace' is absent"
}

function Invoke-FailedTestCleanup {
    param(
        [string]$TerraformPath,
        [string]$Workspace,
        [string]$FallbackVariableFile,
        [int[]]$FallbackPorts
    )

    if ($Workspace -notmatch '^packer-test-[0-9]{14}-[0-9]+$') {
        throw "Failed-test workspace ID is invalid: $Workspace"
    }

    $workspaceOutput = Invoke-NativeCommand `
        -FilePath $TerraformPath `
        -Arguments @("workspace", "list", "-no-color") `
        -CaptureOutput
    $workspaceNames = @(
        $workspaceOutput -split "`r?`n" |
            ForEach-Object { $_.Trim().TrimStart("*").Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($workspaceNames -notcontains $Workspace) {
        throw "Failed-test workspace was not found: $Workspace"
    }

    $receiptPath = Join-Path $AutomationDirectory "$Workspace.failed-test.json"
    $snapshotPath = ""
    $imageOcid = ""
    $cleanupPorts = @($FallbackPorts | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $variableFile = $FallbackVariableFile

    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Assert-NotReparsePoint -Path $receiptPath -Label "Failed-test cleanup receipt"
        try {
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Failed-test cleanup receipt is not valid JSON: $receiptPath"
        }
        if ([int]$receipt.schema_version -ne 1 -or [string]$receipt.workspace_name -ne $Workspace) {
            throw "Failed-test cleanup receipt does not match workspace '$Workspace'."
        }
        $imageOcid = [string]$receipt.image_ocid
        $cleanupPorts = @($receipt.allowed_tcp_ports | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        $snapshotName = [string]$receipt.variable_snapshot
        if ([string]::IsNullOrWhiteSpace($snapshotName) -or
            [System.IO.Path]::GetFileName($snapshotName) -ne $snapshotName) {
            throw "Failed-test cleanup receipt contains an invalid variable snapshot name."
        }
        $snapshotPath = Resolve-ExistingFile `
            -Path (Join-Path $AutomationDirectory $snapshotName) `
            -Label "Failed-test variable snapshot"
        $variableFile = $snapshotPath
    }

    if ($cleanupPorts.Count -eq 0 -or @($cleanupPorts | Where-Object { $_ -lt 1 -or $_ -gt 65535 }).Count -gt 0) {
        throw "Failed-test cleanup has invalid TCP ports."
    }
    $variableFile = Resolve-ExistingFile -Path $variableFile -Label "Terraform variable file"

    $originalWorkspace = (Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "show") -CaptureOutput).Trim()
    $returnWorkspace = if ($originalWorkspace -eq $Workspace) { "default" } else { $originalWorkspace }
    $workspaceSelected = $false
    $destroyed = $false
    try {
        Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "select", $Workspace)
        $workspaceSelected = $true

        $state = Invoke-TerraformJson `
            -TerraformPath $TerraformPath `
            -Arguments @("show", "-json") `
            -Label "Failed-test Terraform state"
        $instances = @(
            Get-NormalizedStateResources -State $state |
                Where-Object { $_.Mode -eq "managed" -and $_.Type -eq "oci_core_instance" }
        )
        if ($instances.Count -gt 1) {
            throw "Failed-test workspace '$Workspace' contains more than one VM. Cleanup stopped for safety."
        }
        if ($instances.Count -eq 1) {
            $sourceDetails = @(Get-RequiredJsonProperty `
                -Object $instances[0].Values `
                -Name "source_details" `
                -Label "Failed-test VM")
            if ($sourceDetails.Count -ne 1) {
                throw "Failed-test VM does not contain exactly one image source."
            }
            $stateImageOcid = [string](Get-RequiredJsonProperty `
                -Object $sourceDetails[0] `
                -Name "source_id" `
                -Label "Failed-test VM source")
            if (-not [string]::IsNullOrWhiteSpace($imageOcid) -and $stateImageOcid -ne $imageOcid) {
                throw "Failed-test receipt image does not match the VM image in Terraform state."
            }
            $imageOcid = $stateImageOcid
        }
        if ($imageOcid -notmatch '^ocid1\.image\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
            throw "Could not recover a valid image OCID for failed-test workspace '$Workspace'."
        }

        $allowedPortsHcl = "[" + ($cleanupPorts -join ",") + "]"
        $variableArguments = @(
            "-var-file=$variableFile",
            "-var=instance_image_id=$imageOcid",
            "-var=use_marketplace_image=false",
            "-var=enable_test_access_nsg=true",
            "-var=expose_login_outputs=false",
            "-var=instance_count=1",
            "-var=allowed_tcp_ports=$allowedPortsHcl",
            "-var=datapump_enabled=false"
        )
        Write-Step "Destroying resources from failed test '$Workspace'"
        Invoke-NativeCommand `
            -FilePath $TerraformPath `
            -Arguments (@("destroy", "-auto-approve", "-input=false") + $variableArguments)
        Assert-DestroyedTerraformState -TerraformPath $TerraformPath
        $destroyed = $true
    }
    finally {
        if ($workspaceSelected) {
            Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "select", $returnWorkspace) -SuppressOutput
        }
    }

    if ($destroyed) {
        Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "delete", $Workspace) -SuppressOutput
        Assert-TerraformWorkspaceAbsent -TerraformPath $TerraformPath -Workspace $Workspace
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($snapshotPath)) {
            Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $AutomationDirectory "$Workspace.tfplan") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $AutomationDirectory "$Workspace.known_hosts") -Force -ErrorAction SilentlyContinue
        Write-Pass "Failed-test resources and workspace '$Workspace' were removed"
    }
}

function Read-PublicEndpoints {
    param([string]$Path)

    try {
        $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Public endpoints file is not valid JSON: $Path"
    }

    if ($null -eq $configuration.public_endpoints) {
        throw "Public endpoints file must contain public_endpoints: $Path"
    }

    $definitions = @($configuration.public_endpoints)
    $validatedDefinitions = @()
    foreach ($definition in $definitions) {
        if ([string]::IsNullOrWhiteSpace([string]$definition.name) -or [string]$definition.name -match '[\r\n\t]') {
            throw "Every public endpoint must have a name."
        }

        $urlTemplate = [string]$definition.url
        if ($urlTemplate -notmatch '^https?://\{host\}:[0-9]+/[^\r\n\t ]*$') {
            throw "Public endpoint URL must look like http://{host}:8080/path: $($definition.name)"
        }

        $resolvedUrl = $urlTemplate.Replace("{host}", "127.0.0.1")
        $uri = $null
        if (-not [Uri]::TryCreate($resolvedUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @("http", "https") -or
            $uri.Host -ne "127.0.0.1" -or
            -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
            $uri.Port -lt 1 -or
            $uri.Port -gt 65535) {
            throw "Public endpoint URL is invalid: $($definition.name)"
        }

        $codes = @($definition.expected_status_codes)
        if ($codes.Count -eq 0) {
            throw "Public endpoint must declare at least one expected status code: $($definition.name)"
        }
        foreach ($code in $codes) {
            if ([int]$code -lt 100 -or [int]$code -gt 599) {
                throw "Public endpoint has an invalid HTTP status code: $($definition.name)"
            }
        }

        $validatedDefinitions += [pscustomobject]@{
            Name = [string]$definition.name
            UrlTemplate = $urlTemplate
            Port = [int]$uri.Port
            ExpectedStatusCodes = @($codes | ForEach-Object { [int]$_ })
        }
    }

    return $validatedDefinitions
}

function Read-SingleTerraformOutput {
    param(
        [string]$TerraformPath,
        [string]$Name
    )

    $json = Invoke-NativeCommand `
        -FilePath $TerraformPath `
        -Arguments @("output", "-json", $Name) `
        -CaptureOutput `
        -SensitiveOutput
    try {
        $value = $json | ConvertFrom-Json
    }
    catch {
        throw "Terraform output '$Name' is not valid JSON."
    }
    $values = @($value)
    if ($values.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {
        throw "Terraform output '$Name' must contain exactly one value."
    }
    return [string]$values[0]
}

function Get-SshArguments {
    param(
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target,
        [string]$RemoteCommand
    )

    return @(
        "-i", $PrivateKeyPath,
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=$KnownHostsPath",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        $Target,
        $RemoteCommand
    )
}

function Get-SshPublicKeyIdentity {
    param([string]$Value)

    $parts = @($Value.Trim() -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^(ssh-|ecdsa-)') {
        return ""
    }
    return "$($parts[0]) $($parts[1])"
}

function Resolve-TestSshPrivateKey {
    param(
        [string]$RequestedPath,
        [string]$TerraformVariableFile
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return Resolve-ExistingFile -Path $RequestedPath -Label "SSH private key"
    }

    $content = Get-Content -LiteralPath $TerraformVariableFile -Raw
    $match = [regex]::Match($content, '(?m)^\s*resUserPublicKey\s*=\s*"([^"]+)"\s*$')
    if (-not $match.Success) {
        throw "Terraform variables must define resUserPublicKey, or pass -SshPrivateKeyPath explicitly."
    }
    $expectedIdentity = Get-SshPublicKeyIdentity -Value $match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($expectedIdentity)) {
        throw "resUserPublicKey is not a supported OpenSSH public key, or pass -SshPrivateKeyPath explicitly."
    }

    $sshDirectory = Join-Path $HOME ".ssh"
    if (Test-Path -LiteralPath $sshDirectory -PathType Container) {
        foreach ($publicKeyFile in @(Get-ChildItem -LiteralPath $sshDirectory -Filter "*.pub" -File | Sort-Object Name)) {
            $candidateIdentity = Get-SshPublicKeyIdentity -Value (Get-Content -LiteralPath $publicKeyFile.FullName -Raw)
            if ($candidateIdentity -ne $expectedIdentity) {
                continue
            }

            $privateKeyPath = $publicKeyFile.FullName.Substring(0, $publicKeyFile.FullName.Length - 4)
            if (Test-Path -LiteralPath $privateKeyPath -PathType Leaf) {
                Write-Step "Selected SSH private key matching resUserPublicKey: $privateKeyPath"
                return $privateKeyPath
            }
        }
    }

    throw "No private key under $sshDirectory matches resUserPublicKey. Pass -SshPrivateKeyPath with the matching private-key path."
}

function Test-SshConnection {
    param(
        [string]$SshPath,
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target
    )

    $arguments = Get-SshArguments `
        -PrivateKeyPath $PrivateKeyPath `
        -KnownHostsPath $KnownHostsPath `
        -Target $Target `
        -RemoteCommand "true"

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $SshPath @arguments *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Wait-ForSsh {
    param(
        [string]$SshPath,
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-SshConnection -SshPath $SshPath -PrivateKeyPath $PrivateKeyPath -KnownHostsPath $KnownHostsPath -Target $Target) {
            return
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "SSH did not become available within $TimeoutSeconds seconds: $Target"
}

function Wait-ForSshShutdown {
    param(
        [string]$SshPath,
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target
    )

    $deadline = (Get-Date).AddSeconds(180)
    do {
        if (-not (Test-SshConnection -SshPath $SshPath -PrivateKeyPath $PrivateKeyPath -KnownHostsPath $KnownHostsPath -Target $Target)) {
            return
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "The test VM did not go offline during the reboot check."
}

function Install-RuntimeFiles {
    param(
        [string]$TerraformPath,
        [string]$ScpPath,
        [string]$SshPath,
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target,
        [string]$AllowedSourceRoot
    )

    try {
        $json = Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("output", "-json", "runtime_files") -CaptureOutput -SensitiveOutput
    }
    catch {
        # Older copied projects do not expose runtime files.
        if ($_.Exception.Message -match 'No output named runtime_files') { return }
        throw
    }
    $files = @($json | ConvertFrom-Json | ForEach-Object { $_ })
    if ($files.Count -eq 0) { return }

    $allowedRoot = [System.IO.Path]::GetFullPath($AllowedSourceRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $remotePaths = @()
    $postRestartCommands = @()
    foreach ($file in $files) {
        $sourcePath = Resolve-ExistingFile -Path ([string]$file.source_path) -Label "Runtime source file"
        $sourceFullPath = [System.IO.Path]::GetFullPath($sourcePath)
        if (-not $sourceFullPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Runtime source file must stay under the project automation directory: $sourceFullPath"
        }
        $targetName = [string]$file.target_name
        if ($targetName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or [string]$file.mode -ne "0600") {
            throw "Runtime file definition is unsafe: $targetName"
        }
        $remotePath = "/home/opc/oci-image-pilot/runtime/$targetName"
        $scpArguments = @(
            "-i", $PrivateKeyPath,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=$KnownHostsPath",
            "-o", "ConnectTimeout=10",
            $sourceFullPath,
            "${Target}:$remotePath"
        )
        Invoke-NativeCommand -FilePath $ScpPath -Arguments $scpArguments -SensitiveOutput
        $extractTo = if ($null -ne $file.PSObject.Properties["extract_to"]) {
            [string]$file.extract_to
        }
        else {
            ""
        }
        $containerUid = if ($null -ne $file.PSObject.Properties["container_uid"]) {
            [string]$file.container_uid
        }
        else {
            ""
        }
        $containerName = if ($null -ne $file.PSObject.Properties["container_name"]) {
            [string]$file.container_name
        }
        else {
            ""
        }
        $containerReadPath = if ($null -ne $file.PSObject.Properties["container_read_path"]) {
            [string]$file.container_read_path
        }
        else {
            ""
        }
        if ([string]::IsNullOrWhiteSpace($extractTo)) {
            if (-not [string]::IsNullOrWhiteSpace($containerUid) -or
                -not [string]::IsNullOrWhiteSpace($containerName) -or
                -not [string]::IsNullOrWhiteSpace($containerReadPath)) {
                throw "A runtime file without extract_to cannot declare container access fields: $targetName"
            }
            $remotePaths += "chmod 0600 $remotePath"
        }
        else {
            if ($extractTo -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $targetName -notmatch '\.zip$') {
                throw "Runtime archive definition is unsafe: $targetName"
            }
            if (-not [string]::IsNullOrWhiteSpace($containerUid) -and $containerUid -notmatch '^[1-9][0-9]{0,8}$') {
                throw "Runtime archive container_uid is unsafe: $targetName"
            }
            if (-not [string]::IsNullOrWhiteSpace($containerUid)) {
                if ($containerName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
                    throw "Runtime archive container_name is unsafe or missing: $targetName"
                }
                if ($containerReadPath -notmatch '^/[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$') {
                    throw "Runtime archive container_read_path is unsafe or missing: $targetName"
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($containerName) -or
                -not [string]::IsNullOrWhiteSpace($containerReadPath)) {
                throw "Runtime archive container fields require container_uid: $targetName"
            }
            $destination = "/home/opc/oci-image-pilot/runtime/$extractTo"
            # scp preserves the local default mode. Lock the archive before extracting it.
            $runtimeCommand = "chmod 0600 $remotePath && rm -rf $destination && install -d -m 0700 $destination && unzip -oq $remotePath -d $destination && chmod -R go-rwx $destination"
            if ($targetName -eq "adb-wallet.zip" -and
                $containerReadPath -eq "/home/adb-wallet/tnsnames.ora") {
                # ADB wallet archives use ?/network/admin in sqlnet.ora. SQLcl
                # can consume the ZIP directly, but host impdp resolves ? under
                # Oracle Home and fails with ORA-28759. During first-boot import,
                # point it at the real host directory. ExecStartPost changes it
                # to the container mount path after Compose starts.
                $runtimeCommand += " && sed -i 's#?/network/admin#$destination#g; s#/home/adb-wallet#$destination#g' $destination/sqlnet.ora"
            }
            if (-not [string]::IsNullOrWhiteSpace($containerUid)) {
                # Podman may finalize the rootless bind mount after systemd returns.
                # Wait for the declared container, then grant the mapped UID access.
                # Do allow setfacl to recalculate the ACL mask: suppressing that
                # recalculation leaves the named Jupyter ACL entry ineffective.
                $waitForContainer = "bash -lc 'for attempt in {1..60}; do if podman inspect --format={{.State.Running}} $containerName 2>/dev/null | grep -qx true; then exit 0; fi; sleep 2; done; exit 1'"
                # Run both find and setfacl in Podman's user namespace. Running
                # only setfacl there can leave the ACL mask empty on a rootless
                # bind mount, which makes the named container UID ineffective.
                $containerAcl = "podman unshare setfacl -m u:${containerUid}:rx $destination && podman unshare find $destination -type d -exec setfacl -m u:${containerUid}:rx {} + && podman unshare find $destination -type f -exec setfacl -m u:${containerUid}:r {} +"
                $containerReadCheck = "podman exec --user $containerUid $containerName test -r $containerReadPath"
                # Verify twice after the service restart so a late rootless
                # mount initialization cannot silently reset the ACL mask.
                $containerPathSetup = if ($targetName -eq "adb-wallet.zip" -and
                    $containerReadPath -eq "/home/adb-wallet/tnsnames.ora") {
                    "sed -i 's#$destination#/home/adb-wallet#g' $destination/sqlnet.ora && "
                }
                else {
                    ""
                }
                # Compose starts the Jupyter container before this ExecStartPost
                # hook grants it access to the fresh wallet.  Its entrypoint has
                # a short wait to cover normal timing, but a slow rootless mount
                # must not leave it permanently in baseline mode.  Once the ACL
                # has been verified, restart only that container so its entrypoint
                # always gets one run with a usable wallet.  Reapply the ACL after
                # the restart because Podman can reset it while remounting.
                $restartContainerAfterAcl = if ($targetName -eq "adb-wallet.zip" -and
                    $containerName -eq "oci-image-pilot-jupyter") {
                    " && podman restart $containerName >/dev/null && $waitForContainer && sleep 2 && $containerAcl && $containerReadCheck"
                }
                else {
                    ""
                }
                $postRestartCommands += "$waitForContainer && ${containerPathSetup}sleep 3 && $containerAcl && $containerReadCheck && sleep 2 && $containerReadCheck$restartContainerAfterAcl"
            }
            $remotePaths += $runtimeCommand
        }
    }

    # Restarting runs ExecStartPre again, so the image reads the fresh Terraform
    # metadata and newly staged protected files before Compose starts.
    $runtimeCommands = ($remotePaths -join " && ")
    if ($postRestartCommands.Count -gt 0) {
        # Rootless Podman can reset bind-mount ACL masks during any later boot
        # or service restart. Persist the verified access commands as an
        # ExecStartPost hook instead of repairing permissions only once.
        # Executable helpers must stay outside runtime/: the verifier requires
        # every protected runtime file to have mode 0600.
        $runtimeAccessScriptDirectory = "/home/opc/.local/libexec/oci-image-pilot"
        $runtimeAccessScriptPath = "$runtimeAccessScriptDirectory/grant-container-access.sh"
        $runtimeAccessDropInDirectory = "/home/opc/.config/systemd/user/oci-image-pilot.service.d"
        $runtimeAccessDropInPath = "$runtimeAccessDropInDirectory/runtime-container-access.conf"
        $runtimeAccessScript = "#!/usr/bin/env bash`nset -Eeuo pipefail`n" +
            ($postRestartCommands -join "`n") + "`n"
        $runtimeAccessDropIn = "[Service]`nExecStartPost=$runtimeAccessScriptPath`n"
        $runtimeAccessScriptBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($runtimeAccessScript)
        )
        $runtimeAccessDropInBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($runtimeAccessDropIn)
        )
        $runtimeCommands += " && rm -f /home/opc/oci-image-pilot/runtime/grant-container-access.sh"
        $runtimeCommands += " && install -d -m 0700 $runtimeAccessScriptDirectory"
        $runtimeCommands += " && printf %s '$runtimeAccessScriptBase64' | base64 -d > $runtimeAccessScriptPath"
        $runtimeCommands += " && chmod 0700 $runtimeAccessScriptPath"
        $runtimeCommands += " && install -d -m 0700 $runtimeAccessDropInDirectory"
        $runtimeCommands += " && printf %s '$runtimeAccessDropInBase64' | base64 -d > $runtimeAccessDropInPath"
        $runtimeCommands += " && chmod 0600 $runtimeAccessDropInPath"
        $runtimeCommands += " && systemctl --user daemon-reload"
    }
    # First boot can include a long Data Pump import. Start the unit without
    # tying the SSH staging command to the first systemd attempt; the unit's
    # restart policy may recover a transient import/start failure. The
    # acceptance phase below waits for the final active state.
    $runtimeCommands += " && systemctl --user restart --no-block oci-image-pilot.service"
    $arguments = Get-SshArguments -PrivateKeyPath $PrivateKeyPath -KnownHostsPath $KnownHostsPath -Target $Target -RemoteCommand $runtimeCommands
    Invoke-NativeCommand -FilePath $SshPath -Arguments $arguments -SensitiveOutput
    Write-Pass "Protected runtime files were staged and the image service was restarted"
}

function Invoke-RemoteVerification {
    param(
        [string]$SshPath,
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target,
        [int]$TimeoutSeconds
    )

    # For a oneshot unit, "active" is reached only after the Data Pump import,
    # Compose startup, and ExecStartPost wallet ACL restoration finish. Use the
    # same acceptance timeout here so a legitimate first-boot import is not
    # limited to the previous three-minute service wait.
    $serviceWaitAttempts = [Math]::Max(90, [int][Math]::Ceiling($TimeoutSeconds / 2.0))
    $remoteCommand = "bash -lc 'for ((attempt=1; attempt<=$serviceWaitAttempts; attempt++)); do if systemctl --user is-active --quiet oci-image-pilot.service; then exec /home/opc/oci-image-pilot/tests/run-tests.sh --wait $TimeoutSeconds --expect-source oci; fi; sleep 2; done; systemctl --user status oci-image-pilot.service --no-pager -l >&2; exit 1'"
    $arguments = Get-SshArguments `
        -PrivateKeyPath $PrivateKeyPath `
        -KnownHostsPath $KnownHostsPath `
        -Target $Target `
        -RemoteCommand $remoteCommand
    Invoke-NativeCommand -FilePath $SshPath -Arguments $arguments
}

function Invoke-RemoteBaselineToolVerification {
    param(
        [string]$SshPath,
        [string]$PrivateKeyPath,
        [string]$KnownHostsPath,
        [string]$Target
    )

    # Prove the launcher can load SQLcl as the same opc user that performs the
    # protected first-boot import, not merely that its files exist.
    $remoteCommand = 'command -v sql >/dev/null 2>&1 && command -v impdp >/dev/null 2>&1 && test -x /usr/local/bin/sql && test -x /opt/sqlcl/bin/sql && test -x /usr/local/bin/impdp && rpm -q jdk-21-headless >/dev/null 2>&1 && rpm -q jdk-26-headless >/dev/null 2>&1 && rpm -q oracle-instantclient-basic >/dev/null 2>&1 && rpm -q oracle-instantclient-tools >/dev/null 2>&1 && /usr/local/bin/sql -version >/dev/null 2>&1 && /usr/local/bin/impdp help=y >/dev/null 2>&1'
    $arguments = Get-SshArguments `
        -PrivateKeyPath $PrivateKeyPath `
        -KnownHostsPath $KnownHostsPath `
        -Target $Target `
        -RemoteCommand $remoteCommand
    try {
        Invoke-NativeCommand -FilePath $SshPath -Arguments $arguments
    }
    catch {
        throw "The test VM does not meet the required SQLcl, JDK 26, and Oracle Data Pump baseline: $($_.Exception.Message)"
    }
    Write-Pass "SQLcl, Oracle Data Pump, JDK 21, and JDK 26 baseline verified on the test VM"
}

function Get-HttpStatus {
    param(
        [string]$CurlPath,
        [string]$NullOutputPath,
        [string]$Url
    )

    # Do not use the curl subprocess here. On macOS a successful curl probe can
    # still leave the outer PowerShell polling loop sleeping without advancing.
    # Windows PowerShell 5.1 does not always load System.Net.Http by default.
    if ($null -eq ("System.Net.Http.HttpClientHandler" -as [type])) {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    }
    # HttpClient gives the runner the status code directly and bypasses proxies.
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = $null
    $response = $null
    try {
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        return [string][int]$response.StatusCode
    }
    catch {
        return "000"
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        if ($null -ne $client) {
            $client.Dispose()
        }
        $handler.Dispose()
    }
}

function Wait-ForPublicEndpoints {
    param(
        [string]$CurlPath,
        [string]$NullOutputPath,
        [string]$PublicIp,
        [object[]]$Definitions,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    foreach ($definition in $Definitions) {
        $url = $definition.UrlTemplate.Replace("{host}", $PublicIp)
        $allowedCodes = @($definition.ExpectedStatusCodes | ForEach-Object { [string][int]$_ })

        do {
            $status = Get-HttpStatus -CurlPath $CurlPath -NullOutputPath $NullOutputPath -Url $url
            if ($allowedCodes -contains $status) {
                Write-Pass "$($definition.name) is externally reachable at $url"
                break
            }
            Start-Sleep -Seconds 10
        } while ((Get-Date) -lt $deadline)

        if ($allowedCodes -notcontains $status) {
            throw "$($definition.name) did not return an expected HTTP status at $url. Last status: $status"
        }
    }
}

function Invoke-InspectionCleanup {
    param(
        [string]$TerraformPath,
        [string]$Id
    )

    $receiptPath = Get-InspectionReceiptPath -Id $Id
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "Inspection receipt was not found: $receiptPath"
    }
    Assert-NotReparsePoint -Path $receiptPath -Label "Inspection receipt"

    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Inspection receipt is not valid JSON: $receiptPath"
    }

    if ([int]$receipt.schema_version -ne 1 -or [string]$receipt.workspace_name -ne $Id) {
        throw "Inspection receipt does not match inspection '$Id'."
    }

    $imageOcid = [string]$receipt.image_ocid
    if ($imageOcid -notmatch '^ocid1\.image\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
        throw "Inspection receipt contains an invalid image OCID."
    }

    $snapshotFileName = [string]$receipt.variable_snapshot
    if ([string]::IsNullOrWhiteSpace($snapshotFileName) -or
        [System.IO.Path]::GetFileName($snapshotFileName) -ne $snapshotFileName) {
        throw "Inspection receipt contains an invalid variable snapshot name."
    }
    $snapshotPath = Resolve-ExistingFile `
        -Path (Join-Path $AutomationDirectory $snapshotFileName) `
        -Label "Inspection variable snapshot"

    $inspectionPorts = @($receipt.allowed_tcp_ports | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if ($inspectionPorts.Count -eq 0 -or @($inspectionPorts | Where-Object { $_ -lt 1 -or $_ -gt 65535 }).Count -gt 0) {
        throw "Inspection receipt contains invalid TCP ports."
    }
    $allowedPortsHcl = "[" + ($inspectionPorts -join ",") + "]"
    $variableArguments = @(
        "-var-file=$snapshotPath",
        "-var=instance_image_id=$imageOcid",
        "-var=use_marketplace_image=false",
        "-var=enable_test_access_nsg=true",
        "-var=expose_login_outputs=false",
        "-var=instance_count=1",
        "-var=allowed_tcp_ports=$allowedPortsHcl",
        "-var=datapump_enabled=false"
    )

    $originalWorkspace = (Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "show") -CaptureOutput).Trim()
    $returnWorkspace = if ($originalWorkspace -eq $Id) { "default" } else { $originalWorkspace }
    $workspaceSelected = $false
    $destroyed = $false

    try {
        Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "select", $Id)
        $workspaceSelected = $true
        Write-Step "Destroying inspection VM and temporary NSG for '$Id'"
        $destroyArguments = @("destroy", "-auto-approve", "-input=false") + $variableArguments
        Invoke-NativeCommand -FilePath $TerraformPath -Arguments $destroyArguments
        Assert-DestroyedTerraformState -TerraformPath $TerraformPath
        $destroyed = $true
    }
    finally {
        if ($workspaceSelected) {
            Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "select", $returnWorkspace) -SuppressOutput
        }
    }

    if ($destroyed) {
        Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "delete", $Id) -SuppressOutput
        Assert-TerraformWorkspaceAbsent -TerraformPath $TerraformPath -Workspace $Id
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $AutomationDirectory "$Id.tfplan") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $AutomationDirectory "$Id.known_hosts") -Force -ErrorAction SilentlyContinue
        Write-Pass "Inspection resources and workspace '$Id' were removed"
    }
}

function Show-InspectionWorkspaceInfo {
    param(
        [string]$TerraformPath,
        [string]$Id
    )

    $receiptPath = Get-InspectionReceiptPath -Id $Id
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "Inspection receipt was not found: $receiptPath"
    }

    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Inspection receipt is not valid JSON: $receiptPath"
    }
    if ([int]$receipt.schema_version -ne 1 -or [string]$receipt.workspace_name -ne $Id) {
        throw "Inspection receipt does not match inspection '$Id'."
    }
    $imageOcid = [string]$receipt.image_ocid
    if ($imageOcid -notmatch '^ocid1\.image\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
        throw "Inspection receipt contains an invalid image OCID."
    }

    $originalWorkspace = (Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "show") -CaptureOutput).Trim()
    $workspaceSelected = $false
    try {
        Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "select", $Id)
        $workspaceSelected = $true

        $state = Invoke-TerraformJson `
            -TerraformPath $TerraformPath `
            -Arguments @("show", "-json") `
            -Label "Inspection Terraform state"
        $instances = @(
            Get-NormalizedStateResources -State $state |
                Where-Object { $_.Mode -eq "managed" -and $_.Type -eq "oci_core_instance" }
        )
        if ($instances.Count -ne 1) {
            throw "Inspection '$Id' does not contain exactly one VM."
        }
        $sourceDetails = @(Get-RequiredJsonProperty `
            -Object $instances[0].Values `
            -Name "source_details" `
            -Label "Inspection VM")
        if ($sourceDetails.Count -ne 1 -or
            [string](Get-RequiredJsonProperty -Object $sourceDetails[0] -Name "source_id" -Label "Inspection VM source") -ne $imageOcid) {
            throw "Inspection '$Id' does not use the image recorded in its receipt."
        }

        $publicIp = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "test_instance_public_ips"
        $dashboardUrl = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "dashboard_url"
        $jupyterUrl = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "jupyter_url"
        $dashboardUser = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "dashboard_user"
        $dashboardPassword = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "vnc_password"
        $databaseUser = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "database_user"
        $databasePassword = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "app_user_password"
        $jupyterPassword = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "jupyter_password"
        $sshCommand = Read-SingleTerraformOutput -TerraformPath $TerraformPath -Name "ssh_command"

        $receipt.status = "ready"
        $receipt.public_ip = $publicIp
        Write-InspectionReceipt -Path $receiptPath -Receipt $receipt

        Write-Host ""
        Write-Host "INSPECTION LOGIN INFO" -ForegroundColor Green
        Write-Host "Inspection ID: $Id"
        if (-not [string]::IsNullOrWhiteSpace([string]$receipt.image_name)) {
            Write-Host "Image name: $($receipt.image_name)"
        }
        Write-Host "Image OCID: $imageOcid"
        Write-Host "Public IP: $publicIp"
        Write-Host "Runtime service dashboard: $dashboardUrl"
        Write-Host "JupyterLab: $jupyterUrl"
        Write-Host "Dashboard username: $dashboardUser"
        Write-Host "Dashboard password: $dashboardPassword"
        Write-Host "Database username: $databaseUser"
        Write-Host "Database password: $databasePassword"
        Write-Host "JupyterLab password: $jupyterPassword"
        Write-Host "SSH: $sshCommand"
        Write-Host "Treat the displayed login values as sensitive."
    }
    finally {
        if ($workspaceSelected) {
            Invoke-NativeCommand -FilePath $TerraformPath -Arguments @("workspace", "select", $originalWorkspace) -SuppressOutput
        }
    }
}

$terraformPath = Resolve-CommandPath -Name "terraform"
if (-not [string]::IsNullOrWhiteSpace($ShowInspectionInfo)) {
    $terraformLock = Enter-ProjectTerraformLock -AutomationPath $AutomationDirectory
    $locationPushed = $false
    try {
        Assert-TrustedTerraformSourceTree -Root $ProjectRoot
        Push-Location $TerraformRoot
        $locationPushed = $true
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("init", "-input=false")
        Show-InspectionWorkspaceInfo -TerraformPath $terraformPath -Id $ShowInspectionInfo
    }
    finally {
        try {
            if ($locationPushed) {
                Pop-Location
            }
        }
        finally {
            Exit-ProjectTerraformLock -Lock $terraformLock
        }
    }
    return
}
if (-not [string]::IsNullOrWhiteSpace($CleanupInspection)) {
    $terraformLock = Enter-ProjectTerraformLock -AutomationPath $AutomationDirectory
    $locationPushed = $false
    try {
        Assert-TrustedTerraformSourceTree -Root $ProjectRoot
        Push-Location $TerraformRoot
        $locationPushed = $true
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("init", "-input=false")
        Invoke-InspectionCleanup -TerraformPath $terraformPath -Id $CleanupInspection
    }
    finally {
        try {
            if ($locationPushed) {
                Pop-Location
            }
        }
        finally {
            Exit-ProjectTerraformLock -Lock $terraformLock
        }
    }
    return
}

if ([string]::IsNullOrWhiteSpace($VariableFile)) {
    $VariableFile = Join-Path (Join-Path $ProjectRoot "01-edit") "terraform.tfvars"
}
if ([string]::IsNullOrWhiteSpace($PublicEndpointsFile)) {
    $gitPath = Resolve-CommandPath -Name "git"
    $terraformRepositoryRoot = (Invoke-NativeCommand `
        -FilePath $gitPath `
        -Arguments @("-C", $ProjectRoot, "rev-parse", "--show-toplevel") `
        -CaptureOutput).Trim()
    $workspaceRoot = Split-Path -Parent $terraformRepositoryRoot
    $demoRepositoryRoot = Join-Path $workspaceRoot "demo-code"
    $demoImageBuildRoot = Join-Path $demoRepositoryRoot "imagebuild"

    $projectName = Split-Path -Leaf $ProjectRoot
    if ($projectName -eq "custom-image" -and
        (Split-Path -Leaf (Split-Path -Parent $ProjectRoot)) -eq "pilot-test-template") {
        $projectName = "automated-build"
    }

    $candidate = Join-Path $demoImageBuildRoot $projectName
    $candidate = Join-Path $candidate "01-image-build"
    $candidate = Join-Path $candidate "01-edit"
    $candidate = Join-Path $candidate "public-endpoints.json"
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Could not find paired demo-code endpoint catalog at '$candidate'. Pass PublicEndpointsFile explicitly for a nonstandard layout."
    }
    $PublicEndpointsFile = $candidate
}
$VariableFile = Resolve-ExistingFile -Path $VariableFile -Label "Terraform variable file"
$PublicEndpointsFile = Resolve-ExistingFile -Path $PublicEndpointsFile -Label "Public endpoints file"
if ([string]::IsNullOrWhiteSpace($PlatformEndpointsFile)) {
    $demoProjectRoot = Split-Path -Parent (Split-Path -Parent $PublicEndpointsFile)
    $PlatformEndpointsFile = Join-Path (Join-Path (Join-Path $demoProjectRoot "03-automation") "dashboard") "public-endpoints.json"
}
$PlatformEndpointsFile = Resolve-ExistingFile -Path $PlatformEndpointsFile -Label "Platform endpoints file"
$publicEndpoints = @(
    @(Read-PublicEndpoints -Path $PublicEndpointsFile) +
    @(Read-PublicEndpoints -Path $PlatformEndpointsFile)
)
$endpointNames = @($publicEndpoints | ForEach-Object { $_.Name })
if (@($endpointNames | Sort-Object -Unique).Count -ne $endpointNames.Count) {
    throw "Application and platform endpoint names must be unique."
}
$portCandidates = @(22)
$portCandidates += @($publicEndpoints | ForEach-Object { [int]$_.Port })
$automatedTestPorts = @($portCandidates | Sort-Object -Unique)
$allowedPortsHcl = "[" + ($automatedTestPorts -join ",") + "]"
Write-Pass "Restricted test ports derived from SSH and public endpoints: $($automatedTestPorts -join ', ')"

if (Get-Content -LiteralPath $VariableFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '<[^>]+>' }) {
    throw "Terraform variable file still contains placeholder values: $VariableFile"
}

$terraformLock = Enter-ProjectTerraformLock -AutomationPath $AutomationDirectory
$locationPushed = $false
try {
    Assert-TrustedTerraformSourceTree -Root $ProjectRoot
    Push-Location $TerraformRoot
    $locationPushed = $true
    Invoke-NativeCommand -FilePath $terraformPath -Arguments @("init", "-input=false")
    if (-not [string]::IsNullOrWhiteSpace($CleanupFailedTest)) {
        Invoke-FailedTestCleanup `
            -TerraformPath $terraformPath `
            -Workspace $CleanupFailedTest `
            -FallbackVariableFile $VariableFile `
            -FallbackPorts $automatedTestPorts
        return
    }
    Invoke-NativeCommand -FilePath $terraformPath -Arguments @("fmt", "-check", "-recursive", $ProjectRoot)
    Invoke-NativeCommand -FilePath $terraformPath -Arguments @("validate")
    Write-Pass "Terraform initialization, formatting, and validation completed"

    if ($ValidateOnly) {
        Write-Pass "Validation-only mode created no OCI resources"
        return
    }

    if ($ImageOcid -notmatch '^ocid1\.image\.[A-Za-z0-9.-]+\.[A-Za-z0-9]+$') {
        throw "ImageOcid must be a complete OCI image OCID."
    }
      $SshPrivateKeyPath = Resolve-TestSshPrivateKey `
          -RequestedPath $SshPrivateKeyPath `
          -TerraformVariableFile $VariableFile
      $sshPath = Resolve-CommandPath -Name "ssh"
      $scpPath = Resolve-CommandPath -Name "scp"
      if (-not $InspectionMode) {
          $curlPath = Resolve-ApplicationPath -Names @("curl.exe", "curl")
      }

    New-Item -ItemType Directory -Path $AutomationDirectory -Force | Out-Null
    if ($InspectionMode) {
        if ([string]::IsNullOrWhiteSpace($InspectionId)) {
            $InspectionId = "inspection-{0}-{1}" -f (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss"), $PID
        }
        $workspaceName = $InspectionId
    }
    else {
        $workspaceName = "packer-test-{0}-{1}" -f (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss"), $PID
    }
    $planPath = Join-Path $AutomationDirectory "$workspaceName.tfplan"
    $knownHostsPath = Join-Path $AutomationDirectory "$workspaceName.known_hosts"
    $receiptPath = if ($InspectionMode) { Get-InspectionReceiptPath -Id $InspectionId } else { "" }
    $failedTestReceiptPath = if ($InspectionMode) { "" } else { Join-Path $AutomationDirectory "$workspaceName.failed-test.json" }
    $variableSnapshotPath = Join-Path $AutomationDirectory "$workspaceName.tfvars"
    Assert-NoReparseAncestors -Path $planPath -Label "Terraform plan file"
    Assert-NotReparsePoint -Path $planPath -Label "Terraform plan file" -AllowMissing
    Assert-NoReparseAncestors -Path $knownHostsPath -Label "SSH known-hosts file"
    Assert-NotReparsePoint -Path $knownHostsPath -Label "SSH known-hosts file" -AllowMissing
    Assert-NoReparseAncestors -Path $variableSnapshotPath -Label "Terraform variable snapshot"
    Assert-NotReparsePoint -Path $variableSnapshotPath -Label "Terraform variable snapshot" -AllowMissing
    if (-not $InspectionMode) {
        Assert-NoReparseAncestors -Path $failedTestReceiptPath -Label "Failed-test cleanup receipt"
        Assert-NotReparsePoint -Path $failedTestReceiptPath -Label "Failed-test cleanup receipt" -AllowMissing
    }
    if ((Test-Path -LiteralPath $variableSnapshotPath) -or
        ($InspectionMode -and (Test-Path -LiteralPath $receiptPath)) -or
        (-not $InspectionMode -and (Test-Path -LiteralPath $failedTestReceiptPath))) {
        throw "Workspace '$workspaceName' already has local automation files. Clean it up or use a new run."
    }
    Copy-Item -LiteralPath $VariableFile -Destination $variableSnapshotPath
    $effectiveVariableFile = $variableSnapshotPath
    $originalWorkspace = (Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "show") -CaptureOutput).Trim()
    $workspaceCreated = $false
    $applyStarted = $false
    $testsPassed = $false
    $inspectionReady = $false
    $destroyed = $false
    $publicIp = ""
    $inspectionDatabaseUser = ""
    $inspectionDatabasePassword = ""
    $inspectionDashboardPassword = ""

    $variableArguments = @(
        "-var-file=$effectiveVariableFile",
        "-var=instance_image_id=$ImageOcid",
        "-var=use_marketplace_image=false",
        "-var=enable_test_access_nsg=true",
        "-var=expose_login_outputs=false",
        "-var=instance_count=1",
        "-var=allowed_tcp_ports=$allowedPortsHcl"
    )

    try {
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "new", $workspaceName)
        $workspaceCreated = $true

        if ($InspectionMode) {
            $inspectionReceipt = [ordered]@{
                schema_version = 1
                inspection_id = $InspectionId
                workspace_name = $workspaceName
                image_ocid = $ImageOcid
                image_name = $ImageName
                created_utc = (Get-Date).ToUniversalTime().ToString("o")
                status = "provisioning"
                public_ip = ""
                variable_snapshot = (Split-Path -Leaf $variableSnapshotPath)
                allowed_tcp_ports = @($automatedTestPorts)
            }
            Write-InspectionReceipt -Path $receiptPath -Receipt $inspectionReceipt
        }
        else {
            $failedTestReceipt = [ordered]@{
                schema_version = 1
                workspace_name = $workspaceName
                image_ocid = $ImageOcid
                variable_snapshot = (Split-Path -Leaf $variableSnapshotPath)
                allowed_tcp_ports = @($automatedTestPorts)
            }
            Write-InspectionReceipt -Path $failedTestReceiptPath -Receipt $failedTestReceipt
        }

        $planArguments = @("plan", "-input=false", "-out=$planPath") + $variableArguments
        Invoke-NativeCommand -FilePath $terraformPath -Arguments $planArguments
        $terraformExpectation = Assert-DirectImagePlan `
            -TerraformPath $terraformPath `
            -PlanPath $planPath `
            -ExpectedImageOcid $ImageOcid `
            -ExpectedPorts $automatedTestPorts

        $applyStarted = $true
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("apply", "-input=false", $planPath)
        Assert-DirectImageState -TerraformPath $terraformPath -Expected $terraformExpectation

        $publicIpJson = Invoke-NativeCommand `
            -FilePath $terraformPath `
            -Arguments @("output", "-json", "test_instance_public_ips") `
            -CaptureOutput
        $publicIps = @($publicIpJson | ConvertFrom-Json)
        if ($publicIps.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$publicIps[0])) {
            throw "Terraform did not return exactly one test VM public IP."
        }

        $publicIp = [string]$publicIps[0]
        $parsedPublicIp = $null
        if (-not [System.Net.IPAddress]::TryParse($publicIp, [ref]$parsedPublicIp) -or
            $parsedPublicIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Terraform returned an invalid IPv4 address for the test VM."
        }

        $target = "${SshUser}@${publicIp}"
        Write-Step "Waiting for SSH before staging protected runtime files on $target"
        Wait-ForSsh `
            -SshPath $sshPath `
            -PrivateKeyPath $SshPrivateKeyPath `
            -KnownHostsPath $knownHostsPath `
            -Target $target `
            -TimeoutSeconds $WaitSeconds
        Install-RuntimeFiles `
            -TerraformPath $terraformPath `
            -ScpPath $scpPath `
            -SshPath $sshPath `
            -PrivateKeyPath $SshPrivateKeyPath `
            -KnownHostsPath $knownHostsPath `
            -Target $target `
            -AllowedSourceRoot (Join-Path $TerraformRoot ".automation")

        if ($InspectionMode) {
            $inspectionReceipt.status = "ready"
            $inspectionReceipt.public_ip = $publicIp
            Write-InspectionReceipt -Path $receiptPath -Receipt $inspectionReceipt
            $inspectionReady = $true
            $inspectionDatabaseUser = Read-SingleTerraformOutput `
                -TerraformPath $terraformPath `
                -Name "database_user"
            $inspectionDatabasePassword = Read-SingleTerraformOutput `
                -TerraformPath $terraformPath `
                -Name "app_user_password"
            $inspectionDashboardPassword = Read-SingleTerraformOutput `
                -TerraformPath $terraformPath `
                -Name "vnc_password"
            Write-Pass "Inspection VM was deployed with fresh Terraform metadata"
        }
        else {
            Write-Step "Waiting for first boot on $target"
            Invoke-RemoteVerification `
                -SshPath $sshPath `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target `
                -TimeoutSeconds $WaitSeconds
            Invoke-RemoteBaselineToolVerification `
                -SshPath $sshPath `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target
            Wait-ForPublicEndpoints `
                -CurlPath $curlPath `
                -NullOutputPath $NullOutputPath `
                -PublicIp $publicIp `
                -Definitions $publicEndpoints `
                -TimeoutSeconds $WaitSeconds
            Write-Pass "Initial boot verification completed"

            Write-Step "Rebooting the test VM"
            $rebootArguments = Get-SshArguments `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target `
                -RemoteCommand "sudo systemctl reboot"
            try {
                Invoke-NativeCommand -FilePath $sshPath -Arguments $rebootArguments -SuppressOutput
            }
            catch {
                Write-Step "SSH disconnected while the reboot command was being processed"
            }

            Wait-ForSshShutdown `
                -SshPath $sshPath `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target
            Wait-ForSsh `
                -SshPath $sshPath `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target `
                -TimeoutSeconds $WaitSeconds

            Invoke-RemoteVerification `
                -SshPath $sshPath `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target `
                -TimeoutSeconds $WaitSeconds
            Invoke-RemoteBaselineToolVerification `
                -SshPath $sshPath `
                -PrivateKeyPath $SshPrivateKeyPath `
                -KnownHostsPath $knownHostsPath `
                -Target $target
            Wait-ForPublicEndpoints `
                -CurlPath $curlPath `
                -NullOutputPath $NullOutputPath `
                -PublicIp $publicIp `
                -Definitions $publicEndpoints `
                -TimeoutSeconds $WaitSeconds

            $testsPassed = $true
            Write-Pass "Clean boot, metadata, every Compose service, every endpoint, and reboot persistence passed"

            if (-not $KeepTestResources) {
                Write-Step "Destroying the isolated test VM and temporary NSG"
                $destroyArguments = @("destroy", "-auto-approve", "-input=false") + $variableArguments
                Invoke-NativeCommand -FilePath $terraformPath -Arguments $destroyArguments
                Assert-DestroyedTerraformState -TerraformPath $terraformPath
                $destroyed = $true
                Write-Pass "Terraform test resources were destroyed"
            }
            else {
                Write-Step "Test resources were kept because -KeepTestResources was supplied"
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $knownHostsPath -Force -ErrorAction SilentlyContinue

        if ($workspaceCreated) {
            Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "select", $originalWorkspace) -SuppressOutput

            if ($destroyed -or -not $applyStarted) {
                Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "delete", $workspaceName) -SuppressOutput
                Assert-TerraformWorkspaceAbsent -TerraformPath $terraformPath -Workspace $workspaceName
                Remove-Item -LiteralPath $variableSnapshotPath -Force -ErrorAction SilentlyContinue
                if (-not $InspectionMode) {
                    Remove-Item -LiteralPath $failedTestReceiptPath -Force -ErrorAction SilentlyContinue
                }
            }
            elseif (-not $destroyed) {
                Write-Warning "Terraform workspace '$workspaceName' was preserved for inspection. Its state contains generated secrets."
                if ($InspectionMode) {
                    Write-Warning "Run the printed CleanupInspection command when the inspection is finished."
                }
                else {
                    Write-Warning "Run the paired demo-code build script with -CleanupFailedTest '$workspaceName' after diagnosing the failure."
                }
            }
        }

        if (-not $workspaceCreated -or -not $applyStarted) {
            Remove-Item -LiteralPath $variableSnapshotPath -Force -ErrorAction SilentlyContinue
            if ($InspectionMode) {
                Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
            }
            else {
                Remove-Item -LiteralPath $failedTestReceiptPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($InspectionMode) {
        if (-not $inspectionReady) {
            throw "Inspection VM deployment did not complete."
        }

        Write-Host ""
        Write-Host "INSPECTION VM DEPLOYED" -ForegroundColor Green
        Write-Host "Inspection ID: $InspectionId"
        if (-not [string]::IsNullOrWhiteSpace($ImageName)) {
            Write-Host "Image name: $ImageName"
        }
        Write-Host "Image OCID: $ImageOcid"
        Write-Host "Public IP: $publicIp"
        foreach ($definition in $publicEndpoints) {
            Write-Host ("{0}: {1}" -f $definition.Name, $definition.UrlTemplate.Replace("{host}", $publicIp))
        }
        Write-Host "Dashboard username: opc"
        Write-Host "Dashboard password: $inspectionDashboardPassword"
        Write-Host "Database username: $inspectionDatabaseUser"
        Write-Host "Database password: $inspectionDatabasePassword"
        Write-Host "JupyterLab password: $inspectionDashboardPassword"
        Write-Host ("SSH: ssh -i `"{0}`" {1}@{2}" -f $SshPrivateKeyPath, $SshUser, $publicIp)
        Write-Host "First-boot configuration may continue for several minutes before the URLs respond."
        Write-Host "Acceptance tests, reboot, and automatic cleanup: SKIPPED FOR INSPECTION"
        Write-Host "Terraform generated fresh metadata for this VM. Treat the displayed login values as sensitive."
        if (-not $SuppressCleanupCommand) {
            Write-Host "Cleanup command:"
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                Write-Host ("powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"{0}`" -CleanupInspection `"{1}`"" -f $PSCommandPath, $InspectionId)
            }
            else {
                Write-Host ("pwsh -NoProfile -File `"{0}`" -CleanupInspection `"{1}`"" -f $PSCommandPath, $InspectionId)
            }
        }
        return
    }

    if (-not $testsPassed) {
        throw "Custom image verification did not complete."
    }

    Write-Host ""
    Write-Host "CUSTOM IMAGE TEST PASSED" -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($ImageName)) {
        Write-Host "Image name: $ImageName"
    }
    Write-Host "Image OCID: $ImageOcid"
    Write-Host "Terraform deployment: PASS"
    Write-Host "Metadata and protected runtime configuration: PASS"
    Write-Host "All Compose services and declared endpoints: PASS"
    Write-Host "Service-specific checks: PASS"
    Write-Host "Reboot persistence: PASS"
    Write-Host ("Cleanup: " + $(if ($KeepTestResources) { "SKIPPED BY REQUEST" } else { "PASS" }))
}
finally {
    try {
        if ($locationPushed) {
            Pop-Location
        }
    }
    finally {
        Exit-ProjectTerraformLock -Lock $terraformLock
    }
}
