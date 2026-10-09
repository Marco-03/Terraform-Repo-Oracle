#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$TerraformPath = "",
    [ValidateRange(1, 60)]
    [int]$ConnectionRetryMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TerraformRoot = $PSScriptRoot
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $TerraformRoot ".."))
$AutomationDirectory = Join-Path $ProjectRoot ".automation"
$TemplateDirectory = Join-Path $TerraformRoot "db-scripts"

function Resolve-CommandPath {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command '$Name' is not available on the Terraform runner."
    }
    return $command.Source
}

function Get-RequiredConfigValue {
    param(
        [object]$Config,
        [string]$Name
    )

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Terraform bootstrap configuration is missing $Name."
    }
    return [string]$property.Value
}

function Assert-Match {
    param(
        [string]$Value,
        [string]$Pattern,
        [string]$Label
    )

    if ($Value -notmatch $Pattern) {
        throw "Terraform bootstrap configuration has an invalid $Label."
    }
}

function Set-PrivateTextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    if ($env:OS -ne "Windows_NT") {
        # BSD chmod on macOS does not support GNU's optional "--" argument.
        & chmod 600 $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to protect generated bootstrap file."
        }
    }
}

function Set-PrivateDirectory {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($env:OS -ne "Windows_NT") {
        & chmod 700 $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to protect the bootstrap working directory."
        }
    }
}

function Expand-SqlTemplate {
    param(
        [string]$TemplateName,
        [hashtable]$Tokens,
        [string]$OutputPath
    )

    $templatePath = Join-Path $TemplateDirectory $TemplateName
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Required SQL bootstrap template is missing."
    }
    $content = Get-Content -LiteralPath $templatePath -Raw
    foreach ($token in $Tokens.Keys) {
        $content = $content.Replace($token, [string]$Tokens[$token])
    }
    if ($content -match '__[A-Z0-9_]+__') {
        throw "SQL bootstrap template has unresolved placeholders."
    }
    Set-PrivateTextFile -Path $OutputPath -Content $content
}

function Invoke-Sqlcl {
    param(
        [string]$SqlPath,
        [string]$WalletDirectory,
        [string]$ScriptPath,
        [string]$LogPath,
        [string]$Label
    )

    $previousTnsAdmin = $env:TNS_ADMIN
    try {
        $env:TNS_ADMIN = $WalletDirectory
        & $SqlPath -s -L /nolog "@$ScriptPath" 1>> $LogPath 2>> $LogPath
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:TNS_ADMIN = $previousTnsAdmin
    }
    if ($exitCode -ne 0) {
        throw "SQLcl $Label failed."
    }
}

function Invoke-SqlclWithConnectionRetry {
    param(
        [string]$SqlPath,
        [string]$WalletDirectory,
        [string]$ScriptPath,
        [string]$LogPath,
        [int]$RetryMinutes
    )

    $deadline = (Get-Date).AddMinutes($RetryMinutes)
    do {
        try {
            Invoke-Sqlcl -SqlPath $SqlPath -WalletDirectory $WalletDirectory -ScriptPath $ScriptPath -LogPath $LogPath -Label "connection/setup"
            return
        }
        catch {
            if ((Get-Date) -ge $deadline) {
                throw
            }
            Start-Sleep -Seconds 20
        }
    } while ($true)
}

function Get-ObjectStorageParAsset {
    param(
        [string]$ParUrl,
        [string]$Prefix,
        [string]$RelativePath,
        [string]$Destination
    )

    $objectName = "{0}{1}" -f $Prefix, $RelativePath
    $encodedObjectName = (($objectName -split "/") | ForEach-Object {
        [System.Uri]::EscapeDataString($_)
    }) -join "/"
    try {
        Invoke-WebRequest -Uri ("{0}{1}" -f $ParUrl, $encodedObjectName) -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Unable to download required Linkurious SQL asset '$RelativePath' through the configured Object Storage PAR."
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "The downloaded Linkurious SQL asset '$RelativePath' is empty."
    }
    if ($env:OS -ne "Windows_NT") {
        & chmod 600 $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to protect the downloaded Linkurious SQL asset."
        }
    }
}

if ([string]::IsNullOrWhiteSpace($TerraformPath)) {
    $TerraformPath = Resolve-CommandPath -Name "terraform"
}
else {
    $TerraformPath = [System.IO.Path]::GetFullPath($TerraformPath)
}
$SqlPath = Resolve-CommandPath -Name "sql"

New-Item -ItemType Directory -Path $AutomationDirectory -Force | Out-Null
$configJson = & $TerraformPath output -json database_bootstrap_config
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the sensitive Terraform database bootstrap configuration."
}
try {
    $config = $configJson | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Terraform returned an invalid database bootstrap configuration."
}

$enabledProperty = $config.PSObject.Properties["enabled"]
if ($null -eq $enabledProperty -or $enabledProperty.Value -isnot [bool]) {
    throw "Terraform bootstrap configuration has an invalid enabled flag."
}
if (-not [bool]$enabledProperty.Value) {
    Write-Host "[lanl-bootstrap] Data Pump is disabled; no external database bootstrap is required."
    return
}

$walletPath = Get-RequiredConfigValue -Config $config -Name "wallet_path"
$walletDirectory = Get-RequiredConfigValue -Config $config -Name "wallet_directory"
$service = Get-RequiredConfigValue -Config $config -Name "service"
$adminUser = Get-RequiredConfigValue -Config $config -Name "admin_user"
$adminPassword = Get-RequiredConfigValue -Config $config -Name "admin_password"
$workshopUser = Get-RequiredConfigValue -Config $config -Name "workshop_user"
$workshopPassword = Get-RequiredConfigValue -Config $config -Name "workshop_password"
$credentialName = Get-RequiredConfigValue -Config $config -Name "credential_name"
$credentialUsername = Get-RequiredConfigValue -Config $config -Name "credential_username"
$credentialPassword = Get-RequiredConfigValue -Config $config -Name "credential_password"
$encryptionPassword = Get-RequiredConfigValue -Config $config -Name "encryption_password"
$sourceSchema = Get-RequiredConfigValue -Config $config -Name "source_schema"
$targetSchema = Get-RequiredConfigValue -Config $config -Name "target_schema"
$bucketUri = Get-RequiredConfigValue -Config $config -Name "object_storage_bucket_uri"

Assert-Match -Value $service -Pattern '^[A-Za-z][A-Za-z0-9_]*_(high|medium|low)$' -Label "ADB service"
Assert-Match -Value $adminUser -Pattern '^ADMIN$' -Label "ADB administrator"
Assert-Match -Value $workshopUser -Pattern '^GRAPHUSER$' -Label "workshop user"
Assert-Match -Value $sourceSchema -Pattern '^TESTUSER$' -Label "source schema"
Assert-Match -Value $targetSchema -Pattern '^GRAPHUSER$' -Label "target schema"
Assert-Match -Value $adminPassword -Pattern '^[A-Za-z0-9]{12,30}$' -Label "ADB administrator password"
Assert-Match -Value $workshopPassword -Pattern '^[A-Za-z0-9]{12,30}$' -Label "workshop password"
Assert-Match -Value $credentialName -Pattern '^[A-Z][A-Z0-9_]{0,29}$' -Label "Swift credential name"
Assert-Match -Value $encryptionPassword -Pattern '^[A-Za-z0-9_#@.!-]{8,128}$' -Label "Data Pump encryption password"
Assert-Match -Value $bucketUri -Pattern '^https://objectstorage\.[A-Za-z0-9-]+\.oraclecloud\.com/n/[A-Za-z0-9_-]+/b/[A-Za-z0-9._-]+$' -Label "Object Storage bucket URI"
if ($credentialUsername -match "[\r\n]" -or $credentialPassword -match "[\r\n]") {
    throw "Terraform bootstrap configuration has an invalid Swift credential."
}
if (-not (Test-Path -LiteralPath $walletPath -PathType Leaf) -or -not (Test-Path -LiteralPath $walletDirectory -PathType Container)) {
    throw "The Terraform-created ADB wallet is unavailable to the SQLcl bootstrap."
}

$dumpUris = @($config.dump_uris | ForEach-Object { [string]$_ })
if ($dumpUris.Count -ne 4) {
    throw "Terraform bootstrap configuration must contain exactly four LANL dump paths."
}
for ($index = 0; $index -lt 4; $index++) {
    $expected = "{0:D2}" -f ($index + 1)
    Assert-Match -Value $dumpUris[$index] -Pattern ("^/o/lanl/export_ogma_lanl_[0-9]{{8}}_{0}\.dmp$" -f $expected) -Label "LANL dump path"
}
$resolvedDumpUris = @($dumpUris | ForEach-Object { "{0}{1}" -f $bucketUri, $_ })
$dumpUriCsv = $resolvedDumpUris -join ","

$workspace = (& $TerraformPath workspace show).Trim()
if ($LASTEXITCODE -ne 0 -or $workspace -notmatch '^[A-Za-z0-9_-]+$') {
    throw "Unable to identify the active Terraform workspace for the database bootstrap."
}
$workDirectory = Join-Path $AutomationDirectory ("{0}-lanl-bootstrap-{1}" -f $workspace, [guid]::NewGuid().ToString("N"))
$logPath = Join-Path $workDirectory "sqlcl-bootstrap.log"
$receiptPath = Join-Path $AutomationDirectory ("{0}-lanl-bootstrap.json" -f $workspace)
$succeeded = $false

try {
    Set-PrivateDirectory -Path $workDirectory
    Set-PrivateTextFile -Path $logPath -Content ""

    $tokens = @{
        "__WALLET_PATH__"              = $walletPath
        "__SERVICE__"                  = $service
        "__ADMIN_USER__"               = $adminUser
        "__ADMIN_PASSWORD__"           = $adminPassword
        "__WORKSHOP_USER__"            = $workshopUser
        "__WORKSHOP_PASSWORD__"        = $workshopPassword
        "__CREDENTIAL_NAME__"          = $credentialName
        "__CREDENTIAL_USERNAME_SQL__"  = $credentialUsername.Replace("'", "''")
        "__CREDENTIAL_PASSWORD_SQL__"  = $credentialPassword.Replace("'", "''")
        "__OBJECT_STORAGE_BUCKET_URI__" = $bucketUri
        "__DUMP_URI_CSV__"             = $dumpUriCsv
        "__SOURCE_SCHEMA__"            = $sourceSchema
        "__TARGET_SCHEMA__"            = $targetSchema
        "__ENCRYPTION_PASSWORD__"      = $encryptionPassword
    }

    $setupSql = Join-Path $workDirectory "01-create-graphuser.sql"
    $importSql = Join-Path $workDirectory "02-import-and-postprocess-lanl.sql"
    Expand-SqlTemplate -TemplateName "01-create-graphuser.sql.tmpl" -Tokens $tokens -OutputPath $setupSql
    Expand-SqlTemplate -TemplateName "02-import-and-postprocess-lanl.sql.tmpl" -Tokens $tokens -OutputPath $importSql

    Write-Host "[lanl-bootstrap] Waiting for the new ADB, then preparing GRAPHUSER."
    Invoke-SqlclWithConnectionRetry -SqlPath $SqlPath -WalletDirectory $walletDirectory -ScriptPath $setupSql -LogPath $logPath -RetryMinutes $ConnectionRetryMinutes
    Write-Host "[lanl-bootstrap] Importing the four LANL objects and applying post-processing."
    Invoke-Sqlcl -SqlPath $SqlPath -WalletDirectory $walletDirectory -ScriptPath $importSql -LogPath $logPath -Label "LANL import/post-processing"

    $expectedGraphCount = 0
    $linkuriousEnabled = $config.PSObject.Properties["linkurious_demo_enabled"]
    if ($null -ne $linkuriousEnabled -and [bool]$linkuriousEnabled.Value) {
        $parUrl = Get-RequiredConfigValue -Config $config -Name "linkurious_demo_par_url"
        $prefix = Get-RequiredConfigValue -Config $config -Name "linkurious_demo_prefix"
        Assert-Match -Value $parUrl -Pattern '^https://objectstorage\.[A-Za-z0-9-]+\.oraclecloud\.com/p/[A-Za-z0-9_-]+/n/[A-Za-z0-9_-]+/b/[A-Za-z0-9._-]+/o/$' -Label "Linkurious Object Storage PAR"
        Assert-Match -Value $prefix -Pattern '^[A-Za-z0-9][A-Za-z0-9._/-]*/$' -Label "Linkurious Object Storage prefix"
        if ($prefix.Contains("..")) {
            throw "Terraform bootstrap configuration has an unsafe Linkurious Object Storage prefix."
        }

        $flowsSql = Join-Path $workDirectory "10-fix_flows_column_shift.sql"
        $graphsSql = Join-Path $workDirectory "11-create_graphs.sql"
        Get-ObjectStorageParAsset -ParUrl $parUrl -Prefix $prefix -RelativePath "scripts/10-fix_flows_column_shift.sql" -Destination $flowsSql
        Get-ObjectStorageParAsset -ParUrl $parUrl -Prefix $prefix -RelativePath "scripts/11-create_graphs.sql" -Destination $graphsSql
        foreach ($script in @($flowsSql, $graphsSql)) {
            $runSql = Join-Path $workDirectory ((Split-Path -Leaf $script) + ".runner.sql")
            $runTokens = @{
                "__WALLET_PATH__"       = $walletPath
                "__SERVICE__"           = $service
                "__WORKSHOP_USER__"     = $workshopUser
                "__WORKSHOP_PASSWORD__" = $workshopPassword
                "__KARIN_SQL_PATH__"    = $script
            }
            Expand-SqlTemplate -TemplateName "03-run-karin-sql.sql.tmpl" -Tokens $runTokens -OutputPath $runSql
            Write-Host "[lanl-bootstrap] Applying the approved Linkurious database setup script."
            Invoke-Sqlcl -SqlPath $SqlPath -WalletDirectory $walletDirectory -ScriptPath $runSql -LogPath $logPath -Label "Linkurious database setup"
        }
        $expectedGraphCount = 2
    }

    $verifySql = Join-Path $workDirectory "04-verify-lanl.sql"
    $verifyTokens = @{
        "__WALLET_PATH__"          = $walletPath
        "__SERVICE__"              = $service
        "__WORKSHOP_USER__"        = $workshopUser
        "__WORKSHOP_PASSWORD__"    = $workshopPassword
        "__EXPECTED_GRAPH_COUNT__" = $expectedGraphCount
    }
    Expand-SqlTemplate -TemplateName "04-verify-lanl.sql.tmpl" -Tokens $verifyTokens -OutputPath $verifySql
    Invoke-Sqlcl -SqlPath $SqlPath -WalletDirectory $walletDirectory -ScriptPath $verifySql -LogPath $logPath -Label "LANL readiness verification"

    $receipt = [ordered]@{
        schema_version = 1
        workspace      = $workspace
        completed_utc  = (Get-Date).ToUniversalTime().ToString("o")
        graph_count    = $expectedGraphCount
        flows_sql_sha256 = if (Test-Path -LiteralPath (Join-Path $workDirectory "10-fix_flows_column_shift.sql")) { (Get-FileHash -LiteralPath (Join-Path $workDirectory "10-fix_flows_column_shift.sql") -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" }
        graphs_sql_sha256 = if (Test-Path -LiteralPath (Join-Path $workDirectory "11-create_graphs.sql")) { (Get-FileHash -LiteralPath (Join-Path $workDirectory "11-create_graphs.sql") -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" }
    }
    Set-PrivateTextFile -Path $receiptPath -Content ($receipt | ConvertTo-Json -Depth 3)
    $succeeded = $true
    Write-Host "[lanl-bootstrap] ADB is ready for the workshop VM."
}
catch {
    throw "LANL ADB bootstrap failed. A protected SQLcl log was retained in the Terraform .automation directory for diagnosis."
}
finally {
    $env:TNS_ADMIN = $null
    if ($succeeded -and (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
