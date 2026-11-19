<#
Portable_Paths.ps1 - documented version 123.
Portable executable discovery. Relative paths are anchored to this script folder, so launching from another working directory does not change their meaning.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Relative paths always use the script folder, never the current working directory.
# Expand environment variables and resolve relative paths against the script directory.
function Resolve-MonitorPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Empty path.' }
    if (-not [IO.Path]::IsPathRooted($value)) { $value = Join-Path $PSScriptRoot $value }
    return [IO.Path]::GetFullPath($value)
}
# Check a configured executable path, portable install locations and finally PATH.
function Find-MonitorExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $configPath = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $key = [IO.Path]::GetFileNameWithoutExtension($Name) + 'Path'
        $property = $config.PSObject.Properties[$key]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            if ($property.Value -isnot [string]) { throw "$key must be text." }
            $configured = Resolve-MonitorPath $property.Value
            if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) { throw "Executable not found: $configured" }
            return $configured
        }
    }
    foreach ($relative in @((Join-Path '..\bin' $Name), $Name, (Join-Path 'bin' $Name))) {
        $candidate = Resolve-MonitorPath $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    throw "$Name not found in ../bin, beside the scripts, in MA/bin or on PATH."
}
