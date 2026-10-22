param(
    [switch]$CheckOnly,
    [switch]$ConnectionOnly,
    [switch]$Quiet,
    [switch]$DeferPhysicalReboots,
    [string]$HAHost,
    [string]$User,
    [ValidateRange(1, 65535)]
    [int]$Port,
    [string]$KeyPath,
    [string]$SSHPath,
    [ValidateRange(0, 1000)]
    [int]$VMRebootIndexStart = 0
)
# Ältere Windows-/PowerShell-Versionen verwenden sonst oft TLS 1.0 als Standard.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# GitHub-Update beim Start: Die eingebundene Routine lädt nur benötigte Skriptdateien.
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptUpdatePath = Join-Path $repositoryRoot 'Komponenten\Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $scriptUpdateTemporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Komponenten/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $scriptUpdateTemporaryPath -ErrorAction Stop
        Move-Item -LiteralPath $scriptUpdateTemporaryPath -Destination $scriptUpdatePath -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath ($scriptUpdatePath + '.download') -Force -ErrorAction SilentlyContinue
        Write-Warning 'GitHub-Updater nicht erreichbar; vorhandene Skriptversion wird ausgeführt.'
    }
}
$scriptUpdateLoaded = $false
if (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf) {
    try {
        . $scriptUpdatePath
        $scriptUpdateLoaded = [bool](Get-Command -Name 'Invoke-ServerUpdateScripts' -CommandType Function -ErrorAction SilentlyContinue)
    }
    catch {
        Write-Warning "GitHub-Updater konnte nicht geladen werden; vorhandene Skriptversion wird ausgeführt. Ursache: $($_.Exception.Message)"
    }
}
if ($scriptUpdateLoaded) {
    Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RemainingArguments $args
}
$modulePath = Join-Path (Join-Path $repositoryRoot 'Module') 'HomeAssistant.Updates.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
$invokeParameters = @{}
foreach ($parameterName in $PSBoundParameters.Keys) { $invokeParameters[$parameterName] = $PSBoundParameters[$parameterName] }
Invoke-HomeAssistantUpdates @invokeParameters
