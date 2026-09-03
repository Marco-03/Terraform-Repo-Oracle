#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$VariableFile = "",
    [string]$ProvisioningTestsDirectory = "",
    [ValidateRange(60, 7200)]
    [int]$WaitSeconds = 1800,
    [switch]$ValidateOnly,
    [switch]$Apply,
    [switch]$KeepTestResources,
    [string]$CleanupWorkspace = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$TerraformRoot = $PSScriptRoot
$AutomationDirectory = Join-Path $ProjectRoot ".automation"
$PipelineStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ($ValidateOnly -and ($Apply -or $KeepTestResources -or -not [string]::IsNullOrWhiteSpace($CleanupWorkspace))) {
    throw "ValidateOnly cannot be combined with Apply, KeepTestResources, or CleanupWorkspace."
}
if ($KeepTestResources -and -not $Apply) {
    throw "KeepTestResources requires Apply."
}
if (-not [string]::IsNullOrWhiteSpace($CleanupWorkspace) -and ($Apply -or $KeepTestResources)) {
    throw "CleanupWorkspace cannot be combined with Apply or KeepTestResources."
}
if (-not [string]::IsNullOrWhiteSpace($CleanupWorkspace) -and $CleanupWorkspace -notmatch '^resource-test-[0-9]{14}-[0-9]+$') {
    throw "CleanupWorkspace must use the generated resource-test-YYYYMMDDHHMMSS-PID format."
}

function Write-Step {
    param([string]$Message)
    Write-Host "[terraform-resource-test] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[terraform-resource-test] PASS: $Message" -ForegroundColor Green
}

function Resolve-ExistingFile {
    param([string]$Path, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label was not provided."
    }
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $resolved -or -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
    return $resolved.Path
}

function Resolve-ExistingDirectory {
    param([string]$Path, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label was not provided."
    }
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $resolved -or -not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        throw "$Label does not exist: $Path"
    }
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

function Format-Command {
    param([string]$FilePath, [string[]]$Arguments)

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

function Assert-PowerShellSyntax {
    param([System.IO.FileInfo[]]$Tests)

    foreach ($test in $Tests) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($test.FullName, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) {
            throw "Provisioning test has PowerShell syntax errors: $($test.FullName)`n$($errors -join [Environment]::NewLine)"
        }
    }
}

function Protect-SensitiveFile {
    param([string]$Path)

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) {
                [void]$acl.RemoveAccessRuleAll($rule)
            }
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($accessRule)
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
        catch {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            throw "Could not restrict the temporary test-context file to the current Windows user."
        }
        return
    }

    $chmodPath = Resolve-CommandPath -Name "chmod"
    Invoke-NativeCommand -FilePath $chmodPath -Arguments @("600", $Path) -SuppressOutput
}

function Read-TerraformJsonOutput {
    param([string]$TerraformPath, [string]$Name, [switch]$Sensitive)

    $arguments = @("output", "-json", $Name)
    if ($Sensitive) {
        $json = Invoke-NativeCommand -FilePath $TerraformPath -Arguments $arguments -CaptureOutput -SensitiveOutput
    }
    else {
        $json = Invoke-NativeCommand -FilePath $TerraformPath -Arguments $arguments -CaptureOutput
    }
    try {
        return ($json | ConvertFrom-Json)
    }
    catch {
        throw "Terraform output '$Name' is not valid JSON."
    }
}

function Get-VariableArguments {
    param([string]$Path)

    return @("-var-file=$Path")
}

if ([string]::IsNullOrWhiteSpace($VariableFile)) {
    $VariableFile = Join-Path (Join-Path $ProjectRoot "01-edit") "terraform.tfvars"
}
if ([string]::IsNullOrWhiteSpace($ProvisioningTestsDirectory)) {
    $ProvisioningTestsDirectory = Join-Path (Join-Path $ProjectRoot "02-edit-if-needed") "provisioning-tests"
}

$VariableFile = Resolve-ExistingFile -Path $VariableFile -Label "Terraform variable file"
$ProvisioningTestsDirectory = Resolve-ExistingDirectory -Path $ProvisioningTestsDirectory -Label "Provisioning tests directory"
$terraformPath = Resolve-CommandPath -Name "terraform"
$testHostPath = (Get-Process -Id $PID).Path
$projectScripts = @(Get-ChildItem -LiteralPath $ProvisioningTestsDirectory -Filter "*.ps1" -File | Sort-Object Name)
$preflightTests = @($projectScripts | Where-Object { $_.Name -like "preflight-*.ps1" })
$provisioningTests = @($projectScripts | Where-Object { $_.Name -notlike "preflight-*.ps1" })

if (Get-Content -LiteralPath $VariableFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '<[^>]+>' }) {
    throw "Terraform variable file still contains placeholder values: $VariableFile"
}
if ([string]::IsNullOrWhiteSpace($CleanupWorkspace)) {
    Assert-PowerShellSyntax -Tests $projectScripts

    foreach ($preflightTest in $preflightTests) {
        Write-Step "Running project preflight '$($preflightTest.Name)'"
        Invoke-NativeCommand -FilePath $testHostPath -Arguments @(
            "-NoProfile",
            "-File", $preflightTest.FullName,
            "-ProjectRoot", $ProjectRoot
        )
        Write-Pass "Project preflight '$($preflightTest.Name)' completed"
    }
}

$variableArguments = Get-VariableArguments -Path $VariableFile

Push-Location $TerraformRoot
try {
    Invoke-NativeCommand -FilePath $terraformPath -Arguments @("init", "-input=false")
    Invoke-NativeCommand -FilePath $terraformPath -Arguments @("fmt", "-check", "-recursive", $ProjectRoot)
    Invoke-NativeCommand -FilePath $terraformPath -Arguments @("validate")
    Write-Pass "Terraform initialization, formatting, and validation completed"

    if (-not [string]::IsNullOrWhiteSpace($CleanupWorkspace)) {
        $originalWorkspace = (Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "show") -CaptureOutput).Trim()
        $returnWorkspace = if ($originalWorkspace -eq $CleanupWorkspace) { "default" } else { $originalWorkspace }
        try {
            Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "select", $CleanupWorkspace)
            Invoke-NativeCommand -FilePath $terraformPath -Arguments (@("destroy", "-auto-approve", "-input=false") + $variableArguments)
        }
        finally {
            Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "select", $returnWorkspace) -SuppressOutput
        }
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "delete", $CleanupWorkspace) -SuppressOutput
        Write-Host ""
        Write-Host "RESOURCE TEST RESOURCES CLEANED" -ForegroundColor Green
        Write-Host "Workspace: $CleanupWorkspace"
        Write-Host "Cleanup: PASS"
        return
    }

    if ($provisioningTests.Count -eq 0) {
        if ($ValidateOnly) {
            Write-Warning "No active provisioning tests were found. Copy the .ps1.example file to a .ps1 file and implement a real resource check before applying."
        }
        else {
            throw "No active provisioning tests were found in $ProvisioningTestsDirectory. Terraform-only mode will not claim success without a real test."
        }
    }

    if ($ValidateOnly) {
        Write-Host ""
        Write-Host "TERRAFORM-ONLY CONFIGURATION VALIDATED" -ForegroundColor Green
        Write-Host "Packer: SKIPPED"
        Write-Host "Compute image VM: SKIPPED"
        Write-Host "Project preflight files: $($preflightTests.Count)"
        Write-Host "Provisioning test files: $($provisioningTests.Count)"
        Write-Host "OCI resources created: 0"
        return
    }

    if (-not $Apply) {
        throw "Terraform-only execution creates OCI resources. Review the plan inputs, then rerun with -Apply."
    }

    New-Item -ItemType Directory -Path $AutomationDirectory -Force | Out-Null
    $workspaceName = "resource-test-{0}-{1}" -f (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss"), $PID
    $planPath = Join-Path $AutomationDirectory "$workspaceName.tfplan"
    $contextPath = Join-Path $AutomationDirectory "$workspaceName.test-context.json"
    $originalWorkspace = (Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "show") -CaptureOutput).Trim()
    $workspaceCreated = $false
    $applyStarted = $false
    $testsPassed = $false
    $destroyed = $false
    $resourceSummary = @()

    try {
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "new", $workspaceName)
        $workspaceCreated = $true

        Invoke-NativeCommand -FilePath $terraformPath -Arguments (@("plan", "-input=false", "-out=$planPath") + $variableArguments)
        $planJson = Invoke-NativeCommand -FilePath $terraformPath -Arguments @("show", "-json", $planPath) -CaptureOutput
        try {
            $plan = $planJson | ConvertFrom-Json
        }
        catch {
            throw "Terraform plan JSON could not be parsed."
        }
        $projectCreates = @($plan.resource_changes | Where-Object {
            [string]$_.address -like "module.workshop_resources.*" -and @($_.change.actions) -contains "create"
        })
        if ($projectCreates.Count -eq 0) {
            throw "Terraform-only plan creates no project resources. Add enabled resources under 02-edit-if-needed/workshop before applying."
        }
        Write-Pass "Plan contains $($projectCreates.Count) project resource creation(s)"

        $applyStarted = $true
        Invoke-NativeCommand -FilePath $terraformPath -Arguments @("apply", "-input=false", $planPath)

        $resourceSummary = @(Read-TerraformJsonOutput -TerraformPath $terraformPath -Name "workshop_resource_summary")
        $resourceSummary = @($resourceSummary | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($resourceSummary.Count -eq 0) {
            throw "The workshop module must export at least one safe workshop_resource_summary entry."
        }

        $testContext = Read-TerraformJsonOutput -TerraformPath $terraformPath -Name "workshop_test_context" -Sensitive
        if ($null -eq $testContext -or @($testContext.PSObject.Properties).Count -eq 0) {
            throw "The workshop module must export the values required by provisioning tests through workshop_test_context."
        }
        $testContextJson = $testContext | ConvertTo-Json -Depth 20 -Compress
        [System.IO.File]::WriteAllText($contextPath, $testContextJson)
        Protect-SensitiveFile -Path $contextPath

        foreach ($test in $provisioningTests) {
            Write-Step "Running provisioning test '$($test.Name)'"
            Invoke-NativeCommand -FilePath $testHostPath -Arguments @(
                "-NoProfile",
                "-File", $test.FullName,
                "-TestContextFile", $contextPath,
                "-ProjectRoot", $ProjectRoot,
                "-WaitSeconds", [string]$WaitSeconds
            )
            Write-Pass "Provisioning test '$($test.Name)' completed"
        }
        $testsPassed = $true

        if (-not $KeepTestResources) {
            Write-Step "Destroying Terraform-only test resources"
            Invoke-NativeCommand -FilePath $terraformPath -Arguments (@("destroy", "-auto-approve", "-input=false") + $variableArguments)
            $destroyed = $true
            Write-Pass "Terraform-only test resources were destroyed"
        }
        else {
            Write-Step "Resources were kept because -KeepTestResources was supplied"
        }
    }
    finally {
        Remove-Item -LiteralPath $contextPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue

        if ($workspaceCreated) {
            Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "select", $originalWorkspace) -SuppressOutput
            if ($destroyed -or -not $applyStarted) {
                Invoke-NativeCommand -FilePath $terraformPath -Arguments @("workspace", "delete", $workspaceName) -SuppressOutput
            }
            else {
                Write-Warning "Terraform workspace '$workspaceName' was preserved. Its state contains generated secrets."
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    Write-Warning "Cleanup command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -CleanupWorkspace `"$workspaceName`" -VariableFile `"$VariableFile`""
                }
                else {
                    Write-Warning "Cleanup command: pwsh -NoProfile -File `"$PSCommandPath`" -CleanupWorkspace `"$workspaceName`" -VariableFile `"$VariableFile`""
                }
            }
        }
    }

    if (-not $testsPassed) {
        throw "Terraform-only resource verification did not complete."
    }

    $PipelineStopwatch.Stop()
    Write-Host ""
    Write-Host "RESOURCE PROVISIONING TEST PASSED" -ForegroundColor Green
    Write-Host "Template: Terraform-only resource test (no Packer or Compute image VM)"
    foreach ($entry in $resourceSummary) {
        Write-Host "Resource: $entry"
    }
    Write-Host "Terraform deployment: PASS"
    Write-Host "Project preflight checks: $($preflightTests.Count) PASS"
    Write-Host "Provisioning tests: $($provisioningTests.Count) PASS"
    Write-Host ("Cleanup: " + $(if ($KeepTestResources) { "SKIPPED BY REQUEST" } else { "PASS" }))
    Write-Host ("Total elapsed time: {0:hh\:mm\:ss}" -f $PipelineStopwatch.Elapsed)
}
finally {
    Pop-Location
}
