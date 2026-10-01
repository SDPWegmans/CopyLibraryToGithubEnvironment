<#
.SYNOPSIS
	Wrapper script for CopyLibraryToGithubEnvironment.

.DESCRIPTION
	Sets the required Azure DevOps environment variables (AZDO_ORG_URL, AZDO_PROJECT)
	and runs the CopyLibraryToGithubEnvironment tool, which copies all key/value pairs
	from an Azure DevOps Library variable group into a GitHub repository environment
	as variables (or secrets, for values marked secret).

.PARAMETER InputsPath
	Path to a JSON file providing the Library, Repo, and Environment values.
	Defaults to 'inputs.json' next to this script. Copy 'inputs.json.template'
	to 'inputs.json' and fill in your own values (inputs.json is gitignored).

	Expected JSON shape:
	{
	  "Library": "MyLibrary",
	  "Repo": "owner/repo",
	  "Environment": "Production"
	}

.PARAMETER OrgUrl
	Azure DevOps organization URL, e.g. https://dev.azure.com/my-org.
	Resolution order: -OrgUrl parameter > $env:AZDO_ORG_URL > "OrgUrl" in run.config.json.

.PARAMETER Project
	Azure DevOps project name.
	Resolution order: -Project parameter > $env:AZDO_PROJECT > "Project" in run.config.json.

.PARAMETER ConfigPath
	Path to a JSON config file providing default OrgUrl/Project values.
	Defaults to 'run.config.json' next to this script. Copy 'run.config.json.template'
	to 'run.config.json' and fill in your own values (run.config.json is gitignored).

.EXAMPLE
	.\run.ps1

.EXAMPLE
	.\run.ps1 -InputsPath .\inputs.json -OrgUrl https://dev.azure.com/my-org -Project MyProject
#>

[CmdletBinding()]
param(
	[Parameter()]
	[string]$InputsPath,

	[Parameter()]
	[string]$OrgUrl,

	[Parameter()]
	[string]$Project,

	[Parameter()]
	[string]$ConfigPath,

	[Parameter()]
	[string]$Configuration = "Debug",

	[Parameter()]
	[string]$LogPath
)

$ErrorActionPreference = "Stop"

# --- Resolve OrgUrl / Project: parameter > env var > config file ---------

$scriptRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($LogPath)) {
	$LogPath = Join-Path $scriptRoot "run.log"
}

# Start a fresh log file for this run.
"" | Set-Content -Path $LogPath -Encoding utf8

function Write-Step {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,
		[string]$Color = "Cyan"
	)

	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$line = "[$timestamp] $Message"
	Write-Host $line -ForegroundColor $Color
	Add-Content -Path $LogPath -Value $line
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
	$ConfigPath = Join-Path $scriptRoot "run.config.json"
}

if ([string]::IsNullOrWhiteSpace($InputsPath)) {
	$InputsPath = Join-Path $scriptRoot "inputs.json"
}

Write-Step "Step 1/6: Resolving inputs from '$InputsPath'..."

if (-not (Test-Path $InputsPath)) {
	throw "Could not find inputs file at '$InputsPath'. Copy 'inputs.json.template' to 'inputs.json' and fill in your own values, or pass -InputsPath."
}

try {
	$inputs = Get-Content -Raw -Path $InputsPath | ConvertFrom-Json
}
catch {
	throw "Failed to parse inputs file '$InputsPath': $($_.Exception.Message)"
}

$Library = $inputs.Library
$Repo = $inputs.Repo
$Environment = $inputs.Environment

if ([string]::IsNullOrWhiteSpace($Library)) {
	throw "'Library' is not set in $InputsPath"
}
if ([string]::IsNullOrWhiteSpace($Repo)) {
	throw "'Repo' is not set in $InputsPath"
}
if ([string]::IsNullOrWhiteSpace($Environment)) {
	throw "'Environment' is not set in $InputsPath"
}

Write-Step "Step 2/6: Resolving Azure DevOps org/project from '$ConfigPath'..."

$fileConfig = $null
if (Test-Path $ConfigPath) {
	try {
		$fileConfig = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
	}
	catch {
		Write-Warning "Failed to parse config file '$ConfigPath': $($_.Exception.Message)"
	}
}

if ([string]::IsNullOrWhiteSpace($OrgUrl)) {
	$OrgUrl = $env:AZDO_ORG_URL
}
if ([string]::IsNullOrWhiteSpace($OrgUrl) -and $fileConfig -and $fileConfig.OrgUrl) {
	$OrgUrl = $fileConfig.OrgUrl
}

if ([string]::IsNullOrWhiteSpace($Project)) {
	$Project = $env:AZDO_PROJECT
}
if ([string]::IsNullOrWhiteSpace($Project) -and $fileConfig -and $fileConfig.Project) {
	$Project = $fileConfig.Project
}

# --- Validate prerequisites ---------------------------------------------

if ([string]::IsNullOrWhiteSpace($OrgUrl)) {
	throw "Azure DevOps organization URL is not set. Pass -OrgUrl, set `$env:AZDO_ORG_URL, or add ""OrgUrl"" to $ConfigPath"
}

if ([string]::IsNullOrWhiteSpace($Project)) {
	throw "Azure DevOps project name is not set. Pass -Project, set `$env:AZDO_PROJECT, or add ""Project"" to $ConfigPath"
}

function Test-CommandExists {
	param([string]$Name)
	return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Step "Step 3/6: Verifying Azure CLI and GitHub CLI are installed..."

if (-not (Test-CommandExists "az")) {
	throw "Azure CLI ('az') was not found on PATH. Install it and run 'az login' first."
}

if (-not (Test-CommandExists "gh")) {
	throw "GitHub CLI ('gh') was not found on PATH. Install it and run 'gh auth login' first."
}

Write-Step "Step 4/6: Checking Azure CLI login status..."
$azAccount = az account show 2>$null
if (-not $azAccount) {
	Write-Warning "You are not logged in to Azure CLI. Launching 'az login'..."
	az login | Out-Null
}
else {
	Write-Step "  Azure CLI is logged in." -Color DarkGray
}

Write-Step "Step 5/6: Checking GitHub CLI login status..."
$ghStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
	Write-Warning "You are not logged in to GitHub CLI. Launching 'gh auth login'..."
	gh auth login
}
else {
	Write-Step "  GitHub CLI is logged in." -Color DarkGray
}

# --- Set environment variables for the child process ---------------------

$env:AZDO_ORG_URL = $OrgUrl
$env:AZDO_PROJECT = $Project

# --- Locate the project/executable ---------------------------------------

$projectPath = Join-Path $scriptRoot "CopyLibraryToGithubEnvironment\CopyLibraryToGithubEnvironment.csproj"

if (-not (Test-Path $projectPath)) {
	throw "Could not find project file at '$projectPath'."
}

Write-Step "Step 6/6: Running CopyLibraryToGithubEnvironment (this invokes 'dotnet run', which may restore/build on first use)..." -Color Green
Write-Step "  Azure DevOps org : $OrgUrl" -Color Gray
Write-Step "  Azure DevOps proj: $Project" -Color Gray
Write-Step "  Library          : $Library" -Color Gray
Write-Step "  GitHub repo      : $Repo" -Color Gray
Write-Step "  GitHub env       : $Environment" -Color Gray

# Stream dotnet's own output live to both console and the log file.
& dotnet run --project $projectPath --configuration $Configuration -- $Library $Repo $Environment 2>&1 |
	ForEach-Object {
		Write-Host $_
		Add-Content -Path $LogPath -Value $_
	}

$exitCode = $LASTEXITCODE
Write-Step "Done. Exit code: $exitCode" -Color $(if ($exitCode -eq 0) { "Green" } else { "Red" })

exit $exitCode
