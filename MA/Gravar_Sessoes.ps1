<#
Gravar_Sessoes.ps1 - version 288.
Capture entry point. Configure camera/audio, create segmented recordings, monitor capture and finalize metadata. A UI timer coordinates start, update, finish and cleanup callbacks.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
param([switch]$AuthorizeFocus, [switch]$SemGraficos)
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Language.ps1')
. (Join-Path $PSScriptRoot 'Recording_AudioSource.ps1')
. (Join-Path $PSScriptRoot 'Recording_ViewFailure.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Portable_Paths.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Segments.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Log.ps1')
. (Join-Path $PSScriptRoot 'Recording_Duration.ps1')
. (Join-Path $PSScriptRoot 'Recording_Limits.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Instance.ps1')

# Authorization-only mode called by the stop command.
if ($AuthorizeFocus) {
$hostFile = Join-Path $PSScriptRoot 'recording_host.pid'
if (-not (Test-Path -LiteralPath $hostFile -PathType Leaf)) { exit 0 }
try {
    $hostProcessId = [uint32](Get-Content -LiteralPath $hostFile -Raw -ErrorAction Stop).Trim()
    if ($hostProcessId -eq 0 -or $hostProcessId -eq [uint32]::MaxValue) { exit 0 }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RecordingFocusPermission {
    [DllImport("user32.dll")]
    public static extern bool AllowSetForegroundWindow(uint processId);
}
'@ -ErrorAction Stop
    [void][RecordingFocusPermission]::AllowSetForegroundWindow($hostProcessId)
}
catch { Write-Warning 'Não foi possível autorizar a ativação da janela da gravação.' }

    exit 0
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class ToolContext {
    [string]$Tool
    [string]$Type
    [string]$Material
    [Nullable[double]]$HeightMm
    [Nullable[double]]$DiameterMm
    [Nullable[double]]$CornerRadiusMm
    [Nullable[double]]$UsageTimeAtProgramStartMinutes
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class SpindleSpeedContext {
    [Nullable[double]]$ProgrammedRpm
    [Nullable[double]]$AdjustmentPercent
    [Nullable[double]]$AdjustedRpm
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class FeedRateContext {
    [Nullable[double]]$ProgrammedMmPerMin
    [Nullable[double]]$AdjustmentPercent
    [Nullable[double]]$AdjustedMmPerMin
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class MachiningParametersContext {
    [SpindleSpeedContext]$SpindleSpeed
    [FeedRateContext]$FeedRate
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class RecordingContext {
    [string]$Machine
    [string]$Operator
    [string]$Work
    [string]$Part
    [string]$PartMaterial
    [string]$Operation
    [string]$Strategy
    [ToolContext]$Tool
    [MachiningParametersContext]$Parameters
    [string]$Notes
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class LastInputValues {
    [System.Collections.IDictionary]$Values = [ordered]@{}
}

# Typed recording data model: group related context/metadata values before JSON serialization.
class RecordingMetadata {
    [datetime]$StartTime
    [datetime]$EndTime
    [double]$DurationSeconds
    [string]$Duration
    [string]$Mode
    [string]$VideoFile
    [string]$AudioFile
    [RecordingContext]$Context

    # Initialize the metadata object for a newly started recording.
    RecordingMetadata(
        [datetime]$startTime,
        [string]$mode,
        [string]$videoFile,
        [string]$audioFile
    ) {
        $this.StartTime = $startTime
        $this.Mode = $mode
        $this.VideoFile = $videoFile
        $this.AudioFile = $audioFile
    }

    # Finalize the recording end time and duration.
    [void] Finish([datetime]$endTime) {
        $this.EndTime = $endTime

        $timeSpan = $this.EndTime - $this.StartTime

        $this.DurationSeconds = [math]::Round(
            $timeSpan.TotalSeconds,
            3
        )

        $this.Duration = "{0:hh\:mm\:ss\.fff}" -f $timeSpan
    }

    # Attach the operator's machining context to the recording metadata.
    [void] SetContext([RecordingContext]$context) {
        $this.Context = $context
    }
}


# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------

# Read and confirm the context information associated with the recording.
function Confirm-RecordingContext {
    # Clear the console directly, including when called inside a condition.
    # Keep host output off the success stream used for the C/R result.
    try { [Console]::Clear() }
    catch { Clear-Host | Out-Null }
    Write-SectionTitle 'Review context'
    foreach ($entry in $script:contextHistory.Values.GetEnumerator()) {
        Microsoft.PowerShell.Utility\Write-Host ((Get-UiText $entry.Key) + ': ' + $entry.Value)
    }
    Microsoft.PowerShell.Utility\Write-Host ([Environment]::NewLine) -NoNewline
    Write-Host 'C - Confirm entered data'
    Write-Host 'R - Re-enter data'
    Write-Host 'Escape - Exit without saving data'
    while ($true) {
        $key = Read-ContextKey
        if ($key.Key -eq [ConsoleKey]::Escape) { throw [OperationCanceledException]::new('Context input cancelled.') }
        if ($key.Key -eq [ConsoleKey]::C) { return $true }
        if ($key.Key -eq [ConsoleKey]::R) {
            try { [Console]::Clear() }
            catch { Clear-Host | Out-Null }
            return $false
        }
    }
}

# Request orderly capture shutdown, then stop the process if it does not exit in time.
function Stop-RecordingProcess {
    param([Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            try { $Process.StandardInput.WriteLine('q'); $Process.StandardInput.Flush() } catch { }
            if (-not $Process.WaitForExit(5000)) {
                $Process.Kill()
                if (-not $Process.WaitForExit(3000)) { throw 'FFmpeg did not terminate.' }
            }
        }
    } catch { Write-Warning $_.Exception.Message }
}

# Probe camera availability with a bounded FFmpeg process before starting capture.
function Test-RecordingCamera {
    param([string]$FFmpegPath, [string]$CameraUrl, [int]$TimeoutMilliseconds = 15000)
    $probe = New-Object Diagnostics.Process
    $probe.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $probe.StartInfo.FileName = $FFmpegPath
    $probe.StartInfo.Arguments = Join-PreviewArguments @('-nostdin','-hide_banner','-loglevel','error',
        '-progress','pipe:1','-rtsp_transport','tcp',
        '-analyzeduration','1000000','-i',$CameraUrl,
        '-map','0:v:0','-c:v','copy','-frames:v','1','-an','-f','null','-')
    $probe.StartInfo.UseShellExecute = $false
    $probe.StartInfo.CreateNoWindow = $true
    $probe.StartInfo.RedirectStandardOutput = $true
    $probe.StartInfo.RedirectStandardError = $true
    $started = $false
    try {
        $started = $probe.Start()
        if (-not $started) { return $false }
        $progress = $probe.StandardOutput.ReadToEndAsync()
        $errors = $probe.StandardError.ReadToEndAsync()
        if (-not $probe.WaitForExit($TimeoutMilliseconds)) { return $false }
        return ($probe.ExitCode -eq 0 -and $progress.Result -match '(?m)^frame=\s*[1-9][0-9]*\s*$')
    } catch { return $false }
    finally {
        # The probe has no stdin (-nostdin); do not wait for a 'q' it cannot read.
        if ($started -and -not $probe.HasExited) {
            $probe.Kill()
            [void]$probe.WaitForExit(3000)
        }
        $probe.Dispose()
    }
}

# Ask whether recording should continue with audio only when the camera is unavailable.
function Confirm-AudioFallback {
    # Use explicit messages so this fix also works with earlier Language.ps1 files.
    if ($script:UiLanguage -eq 'pt') {
        Microsoft.PowerShell.Utility\Write-Warning 'A câmara não está acessível ou excedeu o tempo limite.'
    }
    else { Microsoft.PowerShell.Utility\Write-Warning 'Camera unavailable or timed out.' }
    if ($script:UiLanguage -eq 'pt') { Write-Host 'S - Sim, gravar apenas áudio'; Write-Host 'N - Não, cancelar a gravação' }
    else { Write-Host 'Y - Yes, record audio only'; Write-Host 'N - No, cancel recording' }
    while ($true) {
        $key = Read-ContextKey
        if ($key.Key -eq [ConsoleKey]::N) { return $false }
        if ($script:UiLanguage -eq 'pt' -and $key.Key -eq [ConsoleKey]::S) { return $true }
        if ($script:UiLanguage -eq 'en' -and $key.Key -eq [ConsoleKey]::Y) { return $true }
    }
}

# Read the operator's choice between camera-plus-audio and audio-only capture.
function Read-RecordingMode {
    if ($script:UiLanguage -eq 'pt') {
        Microsoft.PowerShell.Utility\Write-Host 'Esc - Cancelar a gravação'
        Microsoft.PowerShell.Utility\Write-Host 'Escolha 1 ou 2; Esc para cancelar: ' -NoNewline
    }
    else {
        Microsoft.PowerShell.Utility\Write-Host 'Esc - Cancel recording'
        Microsoft.PowerShell.Utility\Write-Host 'Choose 1 or 2; Esc to cancel: ' -NoNewline
    }
    while ($true) {
        $key = Read-ContextKey
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Microsoft.PowerShell.Utility\Write-Host ''
            return $null
        }
        if ($key.KeyChar -in @('1','2')) {
            Microsoft.PowerShell.Utility\Write-Host ([string]$key.KeyChar)
            return [string]$key.KeyChar
        }
    }
}

# Save asynchronously collected process diagnostics when a destination is available.
function Save-RecordingDiagnostic {
    param($ReadTask, [string]$Path)
    if ($null -eq $ReadTask) { return }
    try {
        if ($ReadTask.Wait(3000)) {
            [IO.File]::WriteAllText($Path, $ReadTask.Result, (New-Object Text.UTF8Encoding($false)))
        }
    }
    catch { Microsoft.PowerShell.Utility\Write-Warning $_.Exception.Message }
}

# Remove empty media output files left by an interrupted or failed capture.
function Remove-EmptyRecordingFiles {
    param([string]$OutputPath)
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) { return }
    Get-ChildItem -LiteralPath $OutputPath -File | Where-Object {
        $_.Length -eq 0 -or ($_.Name -like 'audio_*.wav' -and $_.Length -le 44)
    } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

# Print a consistent section heading in the console workflow.
function Write-SectionTitle {
    param([Parameter(Mandatory = $true)][string]$Title)
    $translatedTitle = Get-UiText $Title
    $separator = '-' * $translatedTitle.Length
    Microsoft.PowerShell.Utility\Write-Host $separator
    Microsoft.PowerShell.Utility\Write-Host $translatedTitle
    Microsoft.PowerShell.Utility\Write-Host $separator
}
# Read a context-entry keystroke used by the console editor.
function Read-ContextKey {
    return [Console]::ReadKey($true)
}

# Calculate the console cursor position for an editable input field.
function Get-ContextInputPosition {
    param([int]$Left, [int]$Top, [int]$Offset, [int]$Width)
    $absolute = $Left + $Offset
    return @{ Left = $absolute % $Width; Top = $Top + [int][Math]::Floor($absolute / $Width) }
}

# Redraw editable console text and restore the logical cursor position.
function Update-ContextInputDisplay {
    param([string]$Text, [int]$Cursor, [hashtable]$Display)
    $width = [Console]::BufferWidth
    $paintLength = [Math]::Max($Display.Length, $Text.Length) + 1
    $end = Get-ContextInputPosition $Display.Left $Display.Top $paintLength $width
    # Reserve buffer rows before painting so wrapping cannot scroll the anchor.
    if ($end.Top -ge [Console]::BufferHeight) {
        [Console]::SetBufferSize($width, $end.Top + 2)
    }
    [Console]::SetCursorPosition($Display.Left, $Display.Top)
    [Console]::Write($Text.PadRight($paintLength))
    $position = Get-ContextInputPosition $Display.Left $Display.Top $Cursor $width
    [Console]::SetCursorPosition($position.Left, $position.Top)
    $Display.Length = $Text.Length
}

# Read a context value with the console's custom text-entry behavior.
function Read-ContextValue {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    if ([Console]::IsInputRedirected) {
        throw (Get-UiText 'O contexto requer uma consola interativa para permitir cancelar com Escape.')
    }
    $text = ''
    if ($null -ne $script:contextHistory -and $script:contextHistory.Values.Contains($Prompt)) {
        $text = [string]$script:contextHistory.Values[$Prompt]
    }
    $displayPrompt = switch ($Prompt) {
        'Tool' { 'Name' }
        'Tool type' { 'Type' }
        'Tool material' { 'Material' }
        'Tool height [mm]' { 'Height [mm]' }
        'Tool diameter [mm]' { 'Diameter [mm]' }
        'Tool corner radius [mm]' { 'RC (corner radius) [mm]' }
        default { $Prompt }
    }
    Microsoft.PowerShell.Utility\Write-Host ((Get-UiText $displayPrompt) + ': ') -NoNewline
    $display = @{ Left = [Console]::CursorLeft; Top = [Console]::CursorTop; Length = 0 }
    $cursor = $text.Length
    Update-ContextInputDisplay -Text $text -Cursor $cursor -Display $display
    while ($true) {
        $key = Read-ContextKey
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Update-ContextInputDisplay -Text $text -Cursor $text.Length -Display $display
            Write-Host ''
            throw [OperationCanceledException]::new('Context input cancelled.')
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            Update-ContextInputDisplay -Text $text -Cursor $text.Length -Display $display
            Write-Host ''
            if ($null -ne $script:contextHistory) { $script:contextHistory.Values[$Prompt] = $text }
            return $text
        }
        if ($key.Key -eq [ConsoleKey]::U -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
            $text = ''; $cursor = 0
        }
        else {
            switch ($key.Key) {
                'LeftArrow' { if ($cursor -gt 0) { $cursor-- } }
                'RightArrow' { if ($cursor -lt $text.Length) { $cursor++ } }
                'Home' { $cursor = 0 }
                'End' { $cursor = $text.Length }
                'Backspace' { if ($cursor -gt 0) { $text = $text.Remove($cursor - 1, 1); $cursor-- } }
                'Delete' { if ($cursor -lt $text.Length) { $text = $text.Remove($cursor, 1) } }
                default {
                    if (-not [char]::IsControl($key.KeyChar)) {
                        $text = $text.Insert($cursor, [string]$key.KeyChar); $cursor++
                    }
                }
            }
        }
        Update-ContextInputDisplay -Text $text -Cursor $cursor -Display $display
    }
}

# Read and parse a numeric context value.
function Read-DoubleValue {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    do {
        $inputValue = Read-ContextValue $Prompt
        if ([string]::IsNullOrWhiteSpace($inputValue)) { return $null }
        $value = 0.0
        $valid = [double]::TryParse($inputValue.Trim().Replace(',', '.'),
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$value)
        $valid = $valid -and -not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)
        if (-not $valid) { Write-Host 'Invalid numeric value. Enter a number or leave blank.' }
    } while (-not $valid)
    return $value
}

# Read a numeric value that must not be negative.
function Read-NonnegativeValue {
    param([string]$Prompt)
    do {
        $value = Read-DoubleValue $Prompt
        $valid = $null -eq $value -or $value -ge 0
        if (-not $valid) { Write-Host 'Enter a non-negative number or leave blank.' }
    } while (-not $valid)
    return $value
}

# Collect programmed, percentage-adjustment and adjusted machining values.
function Read-MachiningParameter {
    param([string]$ProgrammedPrompt, [string]$PercentPrompt, [string]$AdjustedPrompt)
    $programmed = Read-NonnegativeValue $ProgrammedPrompt
    if (-not $script:contextHistory.Values.Contains($PercentPrompt) -or
        [string]::IsNullOrWhiteSpace([string]$script:contextHistory.Values[$PercentPrompt])) {
        $script:contextHistory.Values[$PercentPrompt] = '100'
    }
    $percent = Read-NonnegativeValue $PercentPrompt
    $enteredPercent = $percent
    $calculated = $null
    if ($null -ne $programmed -and $null -ne $percent) {
        $calculated = $programmed * ($percent / 100)
        if ([double]::IsInfinity($calculated) -or [double]::IsNaN($calculated)) {
            throw (Get-UiText 'The programmed value and percentage produce an invalid adjusted speed.')
        }
        $script:contextHistory.Values[$AdjustedPrompt] = $calculated.ToString('G', [Globalization.CultureInfo]::InvariantCulture)
        # Compare with the exact numeric value shown to the operator.
        $calculated = [double]::Parse($script:contextHistory.Values[$AdjustedPrompt], [Globalization.CultureInfo]::InvariantCulture)
    }
    elseif ($null -eq $programmed) {
        Write-Host 'The programmed speed is blank; automatic calculation is unavailable.'
    }
    do {
        $adjusted = Read-NonnegativeValue $AdjustedPrompt
        $valid = $true
        if ($null -ne $programmed -and $programmed -eq 0 -and
            $null -ne $adjusted -and $adjusted -ne 0) {
            Write-Host 'An adjusted speed cannot be nonzero when the programmed speed is zero.'
            $valid = $false
        }
        elseif ($null -ne $programmed -and $programmed -gt 0 -and $null -ne $adjusted -and
            ($null -eq $percent -or $adjusted -ne $calculated)) {
            # Preserve the entered percentage when the displayed calculation is accepted.
            $derived = ($adjusted / $programmed) * 100
            if ([double]::IsInfinity($derived) -or [double]::IsNaN($derived)) {
                Write-Host 'These speeds produce an invalid percentage.'
                $valid = $false
            }
            else { $percent = $derived }
        }
    } while (-not $valid)
    if ($null -eq $percent -and $null -ne $programmed -and $programmed -eq 0 -and $null -ne $adjusted) {
        Write-Host 'The percentage cannot be calculated from a programmed speed of zero; it will remain blank.'
    }
    $script:contextHistory.Values[$PercentPrompt] = ''
    if ($null -ne $percent) {
        $script:contextHistory.Values[$PercentPrompt] = $percent.ToString('G', [Globalization.CultureInfo]::InvariantCulture)
        if ($percent -ne $enteredPercent) { Write-Host ('Adjustment: {0}%' -f $percent) }
    }
    return [pscustomobject]@{ Programmed = $programmed; AdjustmentPercent = $percent; Adjusted = $adjusted }
}

# Load previously entered context values for reuse.
function Read-ContextHistory {
    param([string]$Path)
    $history = [LastInputValues]::new()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $saved -or $saved -isnot [pscustomobject] -or
                $null -eq $saved.Values -or $saved.Values -isnot [pscustomobject]) { throw (Get-UiText 'Invalid history') }
            foreach ($property in $saved.Values.PSObject.Properties) {
                if ($null -eq $property.Value -or $property.Value -is [string]) {
                    $history.Values[$property.Name] = [string]$property.Value
                }
            }
        }
        catch { Write-Warning 'Não foi possível ler os últimos valores. Os campos serão apresentados vazios.' }
    }
    return $history
}

# Persist the most recently entered context values.
function Save-ContextHistory {
    param([LastInputValues]$History, [string]$Path)
    $values = [ordered]@{}
    # Use the same order as the prompts, including histories saved by older versions.
    foreach ($prompt in @(
        'Machine', 'Operator', 'Work', 'Part', 'Part material', 'Operation', 'Strategy',
        'Tool', 'Tool type', 'Tool material', 'Tool height [mm]', 'Tool diameter [mm]', 'Tool corner radius [mm]', 'Tool usage time at program start [min]',
        'Programmed spindle speed [rpm]', 'Spindle speed adjustment [%]', 'Adjusted spindle speed [rpm]',
        'Programmed feed rate [mm/min]', 'Feed rate adjustment [%]', 'Adjusted feed rate [mm/min]', 'Notes'
    )) {
        if ($History.Values.Contains($prompt)) { $values[$prompt] = $History.Values[$prompt] }
    }
    $json = Format-Json -Json ([ordered]@{ Values = $values } | ConvertTo-Json -Depth 10 -Compress)
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

# Pretty-print JSON while preserving string contents and escape sequences.
function Format-Json {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $builder = New-Object System.Text.StringBuilder

    $indentLevel = 0
    $inString = $false
    $isEscaped = $false

    for ($i = 0; $i -lt $Json.Length; $i++) {

        $char = $Json[$i]

        if ($inString) {

            [void]$builder.Append($char)

            if ($isEscaped) {
                $isEscaped = $false
            }
            elseif ($char -eq '\') {
                $isEscaped = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }

            continue
        }

        switch ($char) {

            '"' {
                $inString = $true
                [void]$builder.Append($char)
            }

            '{' {
                [void]$builder.Append('{')
                [void]$builder.AppendLine()

                $indentLevel++

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )
            }

            '[' {
                [void]$builder.Append('[')
                [void]$builder.AppendLine()

                $indentLevel++

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )
            }

            '}' {
                [void]$builder.AppendLine()

                $indentLevel--

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )

                [void]$builder.Append('}')
            }

            ']' {
                [void]$builder.AppendLine()

                $indentLevel--

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )

                [void]$builder.Append(']')
            }

            ',' {
                [void]$builder.Append(',')
                [void]$builder.AppendLine()

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )
            }

            ':' {
                [void]$builder.Append(': ')
            }

            default {
                [void]$builder.Append($char)
            }
        }
    }

    return $builder.ToString()
}


# Parse FFmpeg's DirectShow device listing into selectable audio devices.
function ConvertFrom-DShowDeviceList {
    param([string]$Text)
    $devices = New-Object 'System.Collections.Generic.List[object]'
    $section = ''
    $current = $null
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match 'DirectShow audio devices') { $section = 'audio'; $current = $null; continue }
        if ($line -match 'DirectShow video devices') { $section = 'video'; $current = $null; continue }
        if ($line -match 'Alternative name "(.*)"') {
            if ($null -ne $current) { $current.AlternativeName = $matches[1] }
            continue
        }
        if ($line -match '"(.*)"\s+\((audio|video)\)') {
            $current = $null
            if ($matches[2] -eq 'audio') {
                $current = [pscustomobject]@{ Name = $matches[1]; AlternativeName = $null }
                $devices.Add($current)
            }
            continue
        }
        if ($line -match '\[dshow[^\]]*\]\s+"(.*)"\s*$') {
            $current = $null
            if ($section -eq 'audio') {
                $current = [pscustomobject]@{ Name = $matches[1]; AlternativeName = $null }
                $devices.Add($current)
            }
        }
    }
    return $devices.ToArray()
}

# Load capture settings from the JSON configuration file.
function Read-RecordingConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -isnot [pscustomobject]) { throw (Get-UiText 'Expected JSON object') }
        return $config
    }
    catch { throw (Get-UiText "Não foi possível ler '$Path'. O ficheiro deve conter um objeto JSON válido.") }
}

# Read a textual setting from a configuration object.
function Get-ConfigText {
    param($Config, [string]$Name)
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    if ($property.Value -isnot [string]) { throw (Get-UiText "A propriedade '$Name' do config.json deve ser texto.") }
    return $property.Value.Trim()
}

# Ask whether the selected setting should become a saved preference.
function Confirm-SaveConfig {
    param([string]$Prompt)
    do {
        $answer = (Read-Host ((Get-UiText $Prompt) + $(if ($script:UiLanguage -eq 'pt') { ' [S/N]' } else { ' [Y/N]' }))).Trim().ToLowerInvariant()
    } while ($answer -notin @('s', 'sim', 'y', 'yes', 'n', 'nao', 'não', 'no'))
    return ($answer -in @('s', 'sim', 'y', 'yes'))
}

# Merge updated values into the existing JSON configuration.
function Save-ConfigValues {
    param([string]$Path, [System.Collections.IDictionary]$Values)
    # Read again so saving one setting preserves all other existing settings.
    $config = Read-RecordingConfig -Path $Path
    foreach ($key in $Values.Keys) {
        $config | Add-Member -MemberType NoteProperty -Name $key -Value $Values[$key] -Force
    }
    $json = Format-Json -Json ($config | ConvertTo-Json -Depth 20 -Compress)
    try {
        [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    catch { throw (Get-UiText "Não foi possível guardar a configuração em '$Path'.") }
    Write-Host 'Configuração guardada.'
}

# Read whether the camera preview is enabled.
function Get-PreviewVideoEnabled {
    param([string]$ConfigPath)
    $config = Read-RecordingConfig -Path $ConfigPath
    $property = $config.PSObject.Properties['PreviewVideo']
    if ($null -eq $property) {
        Save-ConfigValues -Path $ConfigPath -Values @{ PreviewVideo = $true }
        return $true
    }
    if ($property.Value -isnot [bool]) { throw (Get-UiText 'PreviewVideo deve ser true ou false no config.json.') }
    return $property.Value
}

# Quote and join arguments passed to the camera preview process.
function Join-PreviewArguments {
    param([string[]]$Items)
    $quoted = foreach ($item in $Items) {
        '"' + [regex]::Replace([regex]::Replace($item, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }
    return ($quoted -join ' ')
}

# Build the preview window's size and positioning arguments.
function Get-PreviewWindowArguments {
    # Reserve room for the title bar, borders and taskbar. SDL keeps its
    # normal decorated, resizable window because neither -fs nor -noborder is used.
    $width = 800
    $height = 450
    $position = @()
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screen = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position)
        $area = $screen.WorkingArea
        $left = $area.Left + [int][Math]::Floor(($area.Width - $width) / 2)
        $top = $area.Top + [int][Math]::Floor(($area.Height - $height) / 2)
        $position = @('-left', [string]$left, '-top', [string]$top)
    }
    catch { Write-Warning 'Could not determine the screen position. Preview width: 800 pixels.' }
    return @('-x', [string]$width, '-window_title', (Get-UiText 'Machining Monitor - Playback')) + $position
}

# Launch the camera preview and return its process handle.
function Start-RecordingPreview {
    param([string]$CameraUrl, [string]$BasePath)
    $preview = $null
    try {
        $executable = Find-MonitorExecutable 'ffplay.exe'
        $windowArguments = @(Get-PreviewWindowArguments)
        $items = @('-loglevel', 'error', '-autoexit', '-an', '-rtsp_transport', 'tcp',
            '-window_title', (Get-UiText 'Machining Monitor - Recording')) + $windowArguments + @('-i', $CameraUrl)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $executable
        $info.Arguments = Join-PreviewArguments $items
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $preview = New-Object Diagnostics.Process
        $preview.StartInfo = $info
        if (-not $preview.Start()) { throw (Get-UiText 'Não foi possível iniciar o leitor.') }
        Write-Host 'Pré-visualização aberta. Pode fechar a janela sem interromper a gravação.'
        return $preview
    }
    catch {
        if ($null -ne $preview) { $preview.Dispose() }
        Write-Warning ('Não foi possível abrir a pré-visualização: ' + $_.Exception.Message + ' A gravação continua.')
        return $null
    }
}

# Compile Windows focus-management helpers once per process.
function Initialize-RecordingWindowFocus {
    if (-not ('MachiningMonitor.WindowFocus' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
    public static class WindowFocus {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    }
}
'@ -ErrorAction Stop
    }
    $console = [MachiningMonitor.WindowFocus]::GetConsoleWindow()
    if ($console -ne [IntPtr]::Zero -and [MachiningMonitor.WindowFocus]::IsWindowVisible($console)) {
        return $console
    }
    return [MachiningMonitor.WindowFocus]::GetForegroundWindow()
}

# Bring the recording window back into focus when allowed by Windows.
function Restore-RecordingWindowFocus {
    param([IntPtr]$Window)
    if ($Window -eq [IntPtr]::Zero) { return }
    try {
        if ([MachiningMonitor.WindowFocus]::IsWindow($Window)) {
            if ([MachiningMonitor.WindowFocus]::IsIconic($Window)) {
                [void][MachiningMonitor.WindowFocus]::ShowWindowAsync($Window, 9)
            }
            for ($attempt = 0; $attempt -lt 10; $attempt++) {
                [void][MachiningMonitor.WindowFocus]::SetForegroundWindow($Window)
                Start-Sleep -Milliseconds 100
                if ([MachiningMonitor.WindowFocus]::GetForegroundWindow() -eq $Window) { return }
            }
            if ([MachiningMonitor.WindowFocus]::GetForegroundWindow() -ne $Window) {
                Write-Warning 'O Windows não permitiu ativar a janela do batch. Clique nela para preencher o contexto.'
            }
        }
    }
    catch { Write-Warning 'Não foi possível devolver o foco à janela do batch.' }
}

# Close and release the camera preview process.
function Stop-RecordingPreview {
    param($Preview)
    if ($null -eq $Preview) { return }
    try {
        if (-not $Preview.HasExited) {
            [void]$Preview.CloseMainWindow()
            if (-not $Preview.WaitForExit(1000)) {
                $Preview.Kill()
                [void]$Preview.WaitForExit(2000)
            }
        }
    }
    catch { Write-Warning ('Não foi possível fechar a pré-visualização: ' + $_.Exception.Message) }
    finally { $Preview.Dispose() }
}

# Read and validate the DirectShow audio-buffer preference.
function Get-CaptureAudioBufferMilliseconds {
    param([string]$ConfigPath)
    $config=Read-RecordingConfig -Path $ConfigPath
    $property=$config.PSObject.Properties['AudioBufferMilliseconds']
    if ($null -eq $property) { return 50 }
    $value=0
    if ($property.Value -is [bool] -or $null -eq $property.Value -or
        -not [int]::TryParse([string]$property.Value,[ref]$value) -or $value -lt 0 -or $value -gt 2000) {
        throw (Get-UiText 'AudioBufferMilliseconds must be an integer from 0 to 2000; 0 uses the device default.')
    }
    return $value
}
# Read the recording gain preference as a percentage.
function Get-AudioVolumePercent {
    param([string]$ConfigPath)
    $config = Read-RecordingConfig -Path $ConfigPath
    $property = $config.PSObject.Properties['AudioVolumePercent']
    if ($null -eq $property) {
        Save-ConfigValues -Path $ConfigPath -Values @{ AudioVolumePercent = 100 }
        return 100.0
    }
    $percent = 0.0
    if ($null -eq $property.Value -or $property.Value -is [bool] -or
        -not [double]::TryParse([string]$property.Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$percent) -or
        [double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or
        $percent -lt 0 -or $percent -gt 1000) {
        throw (Get-UiText 'AudioVolumePercent deve ser um número entre 0 e 1000. 100 mantém o volume original.')
    }
    return $percent
}

# Read and validate the requested media-segment duration.
function Get-SegmentMinutes {
    param([string]$ConfigPath)
    $config = Read-RecordingConfig -Path $ConfigPath
    $property = $config.PSObject.Properties['SegmentMinutes']
    if ($null -eq $property) {
        Save-ConfigValues -Path $ConfigPath -Values @{ SegmentMinutes = 10 }
        return 10.0
    }
    $minutes = 0.0
    if ($null -eq $property.Value -or $property.Value -is [bool] -or
        -not [double]::TryParse([string]$property.Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$minutes) -or
        [double]::IsNaN($minutes) -or [double]::IsInfinity($minutes) -or
        $minutes -le 0 -or $minutes -gt 1440) {
        throw (Get-UiText 'SegmentMinutes deve ser um número maior que 0 e até 1440 (minutos).')
    }
    return $minutes
}

# Read or request the configured network-camera address.
function Get-CameraUrl {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $config = Read-RecordingConfig -Path $ConfigPath
    $url = Get-ConfigText -Config $config -Name 'CameraUrl'
    $missing = [string]::IsNullOrWhiteSpace($url)
    if ($missing) { $url = (Read-Host 'URL RTSP da câmara').Trim() }
    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('rtsp', 'rtsps') -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or $url -match '["\r\n]') {
        throw (Get-UiText 'URL da câmara inválido. Use rtsp:// ou rtsps:// com o endereço da câmara.')
    }
    if ($missing -and (Confirm-SaveConfig 'Guardar a configuração do vídeo?')) {
        Save-ConfigValues -Path $ConfigPath -Values @{ CameraUrl = $url }
    }
    return $url
}

# Resolve the saved audio device or let the operator select an available device.
function Select-RecordingAudio {
    param([string]$ConfigPath, [string]$FFmpegPath)
    $config = Read-RecordingConfig -Path $ConfigPath
    if((Get-RecordingAudioSourceType $config) -eq 'RTSP'){return (Get-RecordingRtspSource $config)}
    $inputName = Get-ConfigText -Config $config -Name 'AudioDevice'
    if (-not [string]::IsNullOrWhiteSpace($inputName)) {
        if ($inputName -match '["\r\n]') { throw (Get-UiText 'AudioDevice contém caracteres inválidos.') }
        $name = Get-ConfigText -Config $config -Name 'AudioDeviceName'
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $inputName }
        Write-Host ('Entrada de áudio da configuração: {0}' -f $name)
        return [pscustomobject]@{ Type = 'Local'; Name = $name; InputName = $inputName }
    }
    Write-Host 'A detetar entradas de áudio DirectShow...'
    $devices = @(Get-AudioDevices -FFmpeg $FFmpegPath)
    for ($i = 0; $i -lt $devices.Count; $i++) {
        Write-Host ('{0} - {1}' -f ($i + 1), $devices[$i].Name)
    }
    do {
        $choice = Read-Host 'Escolha o número da entrada de áudio'
        $number = 0
        $valid = [int]::TryParse($choice, [ref]$number)
        $valid = $valid -and $number -ge 1 -and $number -le $devices.Count
        if (-not $valid) { Write-Host 'Número inválido. Tente novamente.' }
    } while (-not $valid)
    $device = $devices[$number - 1]
    $inputName = $device.Name
    if (-not [string]::IsNullOrWhiteSpace($device.AlternativeName)) { $inputName = $device.AlternativeName }
    if ($inputName -match '["\r\n]') { throw (Get-UiText 'O nome do dispositivo contém caracteres inválidos.') }
    Write-Host ('Entrada escolhida: {0}' -f $device.Name)
    if (Confirm-SaveConfig 'Guardar a configuração do áudio?') {
        Save-ConfigValues -Path $ConfigPath -Values @{ AudioDevice = $inputName; AudioDeviceName = $device.Name }
    }
    return [pscustomobject]@{ Type = 'Local'; Name = $device.Name; InputName = $inputName }
}

# Ask FFmpeg to enumerate available DirectShow audio inputs.
function Get-AudioDevices {
    param([string]$FFmpeg)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FFmpeg
    $info.Arguments = '-hide_banner -list_devices true -f dshow -i dummy'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardOutput = $true
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $info
    try {
        if (-not $p.Start()) { throw (Get-UiText 'Não foi possível iniciar FFmpeg.') }
        $stderr = $p.StandardError.ReadToEndAsync()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) {
            $p.Kill(); $p.WaitForExit()
            throw (Get-UiText 'A deteção excedeu 30 segundos.')
        }
        $listing = $stderr.GetAwaiter().GetResult()
        [void]$stdout.GetAwaiter().GetResult()
        # The nonzero exit code is expected because dummy is not an input.
        $devices = @(ConvertFrom-DShowDeviceList $listing)
        if ($devices.Count -eq 0) {
            throw (Get-UiText ('Nenhum dispositivo DirectShow encontrado. Verifique os controladores e o suporte dshow.' + [Environment]::NewLine + $listing))
        }
        return $devices
    }
    finally { $p.Dispose() }
}

# ----------------------------------------------------------------------
# Base paths
# ----------------------------------------------------------------------

# Build an additional local UDP audio output for charts without blocking media capture.
function Get-LiveAudioOutputArguments {
    param([int]$InputIndex, [string]$AudioGain, [int]$Port)
    $delay=Get-RecordingAudioDelayFilter
    $clock=Get-RecordingCaptureAudioClockFilter
    return @('-map', "${InputIndex}:a:0", '-filter:a', "$clock,volume=$AudioGain$delay",
        '-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2', '-flush_packets', '1', '-f', 's16le',
        "udp://127.0.0.1:${Port}?pkt_size=1200")
}

# Create the helper that controls Escape-key behavior for the embedded live player.
function New-RecordingEscapeGuard {
    param([int]$PlayerProcessId)
    if (-not ('MachiningMonitor.RecordingEscapeGuard' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
namespace MachiningMonitor {
    public sealed class RecordingEscapeGuard : IDisposable {
        private delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
        private readonly uint playerId;
        private readonly HookProc callback;
        private readonly Thread thread;
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private IntPtr hook;
        private uint threadId;
        private int error;
        private int disposed;
        [StructLayout(LayoutKind.Sequential)] private struct Point { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] private struct Message {
            public IntPtr hwnd; public uint message; public UIntPtr wParam;
            public IntPtr lParam; public uint time; public Point point; public uint privateData;
        }
        [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
        [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] private static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
        [DllImport("user32.dll")] private static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
        [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint message, UIntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
        public RecordingEscapeGuard(int processId) {
            playerId = (uint)processId;
            callback = OnKey;
            thread = new Thread(Run); thread.IsBackground = true; thread.Start();
            if (!ready.WaitOne(2000)) { Dispose(); throw new TimeoutException("Escape guard startup timed out"); }
            if (hook == IntPtr.Zero) { Dispose(); throw new Win32Exception(error); }
        }
        // No keyboard data is stored. Block exit/pause/frame-step keys only in this recording player.
        public static bool ShouldBlock(int virtualKey, uint foregroundId, uint targetId) {
            return (virtualKey == 27 || virtualKey == 32 || virtualKey == 80 || virtualKey == 83)
                && targetId != 0 && foregroundId == targetId;
        }
        private IntPtr OnKey(int code, IntPtr message, IntPtr data) {
            if (code >= 0) {
                uint foregroundId; GetWindowThreadProcessId(GetForegroundWindow(), out foregroundId);
                if (ShouldBlock(Marshal.ReadInt32(data), foregroundId, playerId)) return new IntPtr(1);
            }
            return CallNextHookEx(hook, code, message, data);
        }
        private void Run() {
            Message message; threadId = GetCurrentThreadId();
            PeekMessage(out message, IntPtr.Zero, 0, 0, 0);
            hook = SetWindowsHookEx(13, callback, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero) error = Marshal.GetLastWin32Error();
            ready.Set();
            try { if (hook != IntPtr.Zero) while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {} }
            finally { if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); }
        }
        public void Dispose() {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            if (threadId != 0) PostThreadMessage(threadId, 0x0012, UIntPtr.Zero, IntPtr.Zero);
            if (Thread.CurrentThread != thread && thread.Join(2000)) ready.Dispose();
        }
    }
}
'@ -ErrorAction Stop
    }
    return [MachiningMonitor.RecordingEscapeGuard]::new($PlayerProcessId)
}

# Build the FFmpeg audio/video graph for live waveform, spectrum and spectrogram rendering.
function Get-LiveVisualizationArguments {
    param([int]$Port, [ValidateSet('L','R')][string]$Channel, [ValidateRange(1,20)][int]$Gain, [string[]]$CameraUrl, [ValidateRange(0.000001,86400)][double]$BlockSeconds = 600, [switch]$PreviewOnly, [int]$CanvasWidth=960, [int]$CanvasHeight=0, [double]$ElapsedSeconds=0)
    $source = 'A'
    $cameraItems = @()
    $urls=@($CameraUrl | Where-Object {$_})
    Set-VisualizationCameraCount $script:RecordingUi.Viewport $urls.Count
    if($script:RecordingUi.Viewport.Tag.CameraLayout -eq 'Vertical'){$CanvasHeight=$script:RecordingUi.VideoHost.ClientSize.Height}
    foreach($url in $urls){
        $source='S'
        $cameraItems+=@(Get-RecordingCameraInputArguments $url)
    }
    $visualItems = @(Get-VisualizationArguments $source '' '' 0 $Channel $Gain -RecordingTimer:(!$PreviewOnly) -RecordingBlockSeconds $BlockSeconds -CanvasWidth $CanvasWidth -CanvasHeight $CanvasHeight -ShowVideo:($script:RecordingUi.Viewport.Tag.Video) -ShowCharts:($script:RecordingUi.Viewport.Tag.Charts) -VideoPanelHeight $script:RecordingUi.Viewport.Tag.Heights.Video -FrequencyPanelHeight $script:RecordingUi.Viewport.Tag.Heights.Frequency -HistoryPanelHeight $script:RecordingUi.Viewport.Tag.Heights.History)
    $graphIndex = [Array]::IndexOf($visualItems, '-filter_complex')
    $visualItems[$graphIndex+1]=ConvertTo-MultiCameraGraph $visualItems[$graphIndex+1] $urls.Count $CanvasWidth $script:RecordingUi.Viewport.Tag.Heights.Video -CameraLayout $script:RecordingUi.Viewport.Tag.CameraLayout
    if(-not $PreviewOnly -and $ElapsedSeconds -gt 0){
        $offset=$ElapsedSeconds.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
        $visualItems[$graphIndex+1]=$visualItems[$graphIndex+1].Replace('%{pts\:hms}',('%{pts\:hms\:'+$offset+'}')).Replace('floor(t/',('floor((t+'+$offset+')/'))
    }
    # These frames stay on the same computer. Raw YUV avoids H.264
    # encoding/decoding and its CPU spikes; NUT carries timestamps and PCM.
    $renderItems=@('-filter_complex',$visualItems[$graphIndex+1],
        '-map','[vout]','-map','[aout]','-c:v','rawvideo','-threads:v','1',
        '-pix_fmt','yuv420p','-c:a','pcm_s16le','-shortest',
        '-flush_packets','1','-f','nut','pipe:1')
    return @('-nostdin','-loglevel','warning','-nostats','-stats_period','1','-progress','pipe:2') + $cameraItems + @('-f', 's16le', '-ar', '48000', '-ac', '2',
        '-i', "udp://127.0.0.1:${Port}?fifo_size=4096&overrun_nonfatal=1&timeout=10000000") + $renderItems
}

# Build the live player's window arguments for the selected display mode.
function Get-LiveWindowArguments {
    param([bool]$WithVideo)
    $items = @(Get-PlaybackWindowArguments -WithVideo $WithVideo)
    $titleIndex = [Array]::IndexOf($items, '-window_title')
    $items[$titleIndex + 1] = Get-UiText 'Machining Monitor - Recording'
    return $items
}
# Run the guarded application workflow. Catch reports failures; finally releases the resources allocated by this workflow.
try {
    $recordingConsoleSize = $Host.UI.RawUI.WindowSize
    Set-ConsoleFontSize
    Set-ConsoleHeight
    $recordingConsoleSize.Height = 40
    # Retain the columns and use 40 rows after applying font size 14.
    $Host.UI.RawUI.WindowSize = $recordingConsoleSize
} catch {
    Write-Warning ((Get-UiText 'Unable to set the console font size to 14: ') + $_.Exception.Message)
}
# Run the guarded application workflow. Catch reports failures; finally releases the resources allocated by this workflow.
try {
Center-ConsoleWindow
# Language is selected in the form.

$recordingInstance=Enter-RecordingInstance $PSScriptRoot
if (-not $recordingInstance.Acquired) {
    if($recordingInstance.Notified){return}
    throw 'Existe uma versão anterior da janela de gravação em execução nesta instalação. Feche essa janela (incluindo se estiver minimizada) e volte a abrir Gravar_Sessoes.bat.'
}
$basePath = $PSScriptRoot
. (Join-Path $basePath 'Playback_Blocks.ps1') -RecordingPath $basePath -ApenasFuncoes -SemGraficos:$SemGraficos

$stopFile = Join-Path $basePath "stop.flag"
$pidFile = Join-Path $basePath "recording.pid"
. (Join-Path $basePath 'Recordings_Location.ps1')
$recordingsPath = Get-RecordingsDirectory -Graphical
if ([string]::IsNullOrWhiteSpace($recordingsPath)) { return }


$ffmpegPath = Find-MonitorExecutable 'ffmpeg.exe'
$configPath = Join-Path $basePath 'config.json'
. (Join-Path $basePath 'Recording_Cameras.ps1')
. (Join-Path $basePath 'Recording_Form.ps1')
. (Join-Path $basePath 'Recording_Schedule.ps1')
. (Join-Path $basePath 'Recording_ActiveView.ps1')
New-RecordingForm $ffmpegPath -NoWait
# Start callback: read preferences, validate inputs, create unique output paths, start capture and connect the live visualization.
# $script: scope is deliberate: timer callbacks must access the same process handles, paths
# and metadata after this callback returns. Cleanup also runs after a partially failed start.
$script:RecordingStartAction = {
    $script:RecordingUi.MediaStarted=$false
Show-RecordingImageWait ($script:RecordingUi.Mode.SelectedIndex -ne 1)
$script:captureLogMonitor=$null; $script:previewProcess=$null; $script:recordingHostFile=Join-Path $script:basePath "recording_host.pid"
$script:RecordingEndedAt=$null
$script:CompletedRecordingContext=$null
$script:RecordingUi.PlanContextManaged=$false
# Choose the scheduled plan or manual timer before starting capture, so its context choice is saved with the recording.
$script:contextPlan=if($script:RecordingUi.ActiveSchedule){$script:RecordingUi.ActiveSchedule}else{$script:RecordingUi.ManualTimer}
if($script:contextPlan){Set-RecordingPlanContext $script:contextPlan}
# An explicitly prepared context applies once, to the next successful capture.
if($null -ne $script:RecordingUi.PendingRecordingContext){
    $script:CompletedRecordingContext=Copy-SplitObject $script:RecordingUi.PendingRecordingContext
    $script:RecordingUi.PlanContextManaged=$true
}
$script:process=$null; $script:metadata=$null; $script:outputPath=$null
Remove-Item -LiteralPath $script:stopFile -Force -ErrorAction SilentlyContinue
$script:segmentMinutes = Get-SegmentMinutes -ConfigPath $script:configPath
$script:segmentSeconds = ($script:segmentMinutes * 60).ToString('0.########', [Globalization.CultureInfo]::InvariantCulture)
$script:audioVolumePercent = Get-AudioVolumePercent -ConfigPath $script:configPath
$script:captureAudioBufferMs=0
if (-not $SemGraficos) { $script:captureAudioBufferMs=Get-CaptureAudioBufferMilliseconds $script:configPath }
$script:audioGain = Get-RecordingAudioGainText (Read-RecordingConfig $script:configPath)
$script:previewVideoEnabled = Get-PreviewVideoEnabled -ConfigPath $script:configPath
$script:selectedDevice = if($script:RecordingUi.Mode.SelectedIndex -eq 2){[pscustomobject]@{Type='None';InputName='';Name=''}}else{Select-RecordingAudio -ConfigPath $script:configPath -FFmpegPath $script:ffmpegPath}
$script:audio = $script:selectedDevice.InputName
$script:liveChannel = 'R'
$script:liveWaveformGain = 1
$script:livePort = 0
$script:livePlayer = $null
$script:liveRenderer = $null
$script:liveCopy = $null
$script:escapeGuard = $null
$script:liveFinished = $false
$script:liveRendererErrorsTask=$null
$script:livePlayerErrorsTask=$null
if (-not $SemGraficos) {
    $script:liveChannel = Get-DefaultSpectrumChannel $script:configPath
    Save-SpectrumChannel $script:configPath $script:liveChannel
    $script:liveWaveformGain = Get-DefaultWaveformGain $script:configPath
    Save-WaveformGain $script:configPath $script:liveWaveformGain
    $script:portProbe = New-Object Net.Sockets.UdpClient
    try {
        $script:portProbe.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $script:livePort = $script:portProbe.Client.LocalEndPoint.Port
    } finally { $script:portProbe.Dispose() }
}

# ----------------------------------------------------------------------
# Recording mode
# ----------------------------------------------------------------------

Write-Host ""
Write-SectionTitle 'Recording mode:'
Write-Host "1 - Camera + Audio device"
Write-Host "2 - Audio device only"
Write-Host ""

$script:selection = [string]($script:RecordingUi.Mode.SelectedIndex+1)
if ($null -eq $script:selection) { throw [OperationCanceledException]::new('Recording cancelled.') }

if ($script:selection -eq "1") {
    $script:mode = "VIDEO_AUDIO"
}
elseif($script:selection -eq '2') {
    $script:mode = "AUDIO"
}
else {$script:mode='VIDEO'}


# ----------------------------------------------------------------------
# Recording paths
# ----------------------------------------------------------------------

$script:camera = $null
if ($script:mode -ne 'AUDIO') {
    $script:selectedCameras=@(Get-RecordingCameras (Read-RecordingConfig $script:configPath) -Selected)
    $script:camera=@(Get-RecordingCameraUrls $script:configPath)
    if(-not $script:camera.Count){throw 'Selecione pelo menos uma câmara na Configuração.'}
    Assert-CachedRecordingSegmentationSupport $script:ffmpegPath
    if (-not (Test-RecordingCameraSet $script:ffmpegPath $script:camera)) {
        Show-RecordingCameraUnavailable (Get-QualityText 'One or more selected cameras are unavailable. Check the camera settings.' 'Uma ou mais câmaras selecionadas estão indisponíveis. Verifique a configuração das câmaras.')
        if ($script:mode -eq 'VIDEO' -or -not (Confirm-RecordingAudioFallback)) {
            Reset-RecordingForm
            $script:RecordingUi.Status.Text=Get-QualityText 'Recording not started. Change the settings or try again.' 'Gravação não iniciada. Altere a configuração ou tente novamente.'
            return
        }
        $script:mode = 'AUDIO'
        $script:camera = $null
    }
}

$script:startTime = Get-Date

$script:timestamp = $script:startTime.ToString("yyyyMMdd_HHmmss")
$script:outputPath = Join-Path $script:recordingsPath $script:timestamp

# Never reuse a folder when two recordings start within the same second.
$script:pathBase=$script:outputPath; $script:suffix=1
while(Test-Path -LiteralPath $script:outputPath){ $script:outputPath=$script:pathBase+'_'+$script:suffix; $script:suffix++ }
if(-not(Test-Path -LiteralPath $script:recordingsPath -PathType Container)){
    throw (Get-QualityText 'The recordings folder no longer exists. Choose an existing folder before recording.' 'A pasta das gravações já não existe. Escolha uma pasta existente antes de gravar.')
}
New-Item -ItemType Directory -Path $script:outputPath -ErrorAction Stop | Out-Null




# FFmpeg expands %06d into sequential block numbers. Separate CSV lists preserve source
# start/end times, allowing playback to concatenate blocks and diagnostics to detect gaps.
$script:videoPath = Join-Path $script:outputPath "video_%06d.mp4"
$script:audioPath = Join-Path $script:outputPath "audio_%06d.wav"
$script:videoListPath = Join-Path $script:outputPath 'video_segments.csv'
$script:audioListPath = Join-Path $script:outputPath 'audio_segments.csv'
$script:metadataPath = Join-Path $script:outputPath "metadata.json"


# ----------------------------------------------------------------------
# FFmpeg arguments
# ----------------------------------------------------------------------

$syncMode=if($script:mode -eq 'AUDIO'){1}elseif($script:mode -eq 'VIDEO'){2}else{0}
$script:captureSyncPlan=Get-RecordingSyncPlan (Read-RecordingConfig $script:configPath) $syncMode
if ($script:mode -ne "AUDIO") {

    $script:arguments=Join-PlaybackArguments (Get-MultiCameraCaptureArguments $script:camera $script:outputPath ([double]($script:segmentMinutes*60)) $script:audioGain -CameraOnly:($script:mode -eq 'VIDEO'))

    $script:metadataVideoFile = "video_%06d.mp4"
}
else {

    $script:arguments = Join-PlaybackArguments (@(Get-RecordingExternalAudioArguments $script:selectedDevice $script:captureAudioBufferMs) + @(Get-RecordingAudioSegmentArguments 0 ([double]($script:segmentMinutes*60)) $script:outputPath $script:audioGain))

    $script:metadataVideoFile = $null
}


if (-not $SemGraficos -and $script:mode -ne 'VIDEO') {
    # Capture owns the device input; visualization consumes an independent local copy.
    # A second output forwards a copy of the device signal over local UDP.
    # Closing or pausing the charts cannot block the recording output.
    $script:liveInputIndex = 0
    if ($script:mode -ne 'AUDIO') { $script:liveInputIndex = @($script:camera).Count }
    $script:arguments += ' ' + (Join-PlaybackArguments (Get-LiveAudioOutputArguments $script:liveInputIndex $script:audioGain $script:livePort))
}

$script:metadata = [RecordingMetadata]::new(
    $script:startTime,
    $script:mode,
    $script:metadataVideoFile,
    $(if($script:mode -eq 'VIDEO'){$null}else{'audio_%06d.wav'})
)


# ----------------------------------------------------------------------
# Configure FFmpeg process
# ----------------------------------------------------------------------

$script:startInfo = New-Object System.Diagnostics.ProcessStartInfo
$script:startInfo.FileName = $script:ffmpegPath
$script:startInfo.Arguments = '-nostats -loglevel verbose -debug_ts ' + $script:arguments
$script:startInfo.UseShellExecute = $false
$script:startInfo.RedirectStandardInput = $true
$script:startInfo.RedirectStandardOutput = $false
$script:startInfo.RedirectStandardError = $true
$script:startInfo.CreateNoWindow = $true

$script:process = New-Object System.Diagnostics.Process
$script:process.StartInfo = $script:startInfo
$script:ffmpegErrorsTask = $null
$script:captureLogMonitor=$null
$script:ffmpegLogPath = Join-Path $script:outputPath 'ffmpeg.log'
$script:previewProcess = $null
$script:recordingHostFile = Join-Path $script:basePath 'recording_host.pid'
$script:recordingWindow = [IntPtr]::Zero
try { $script:recordingWindow = $script:RecordingUi.Form.Handle }
catch { Write-Warning 'Não foi possível identificar a janela do batch para devolver o foco.' }


    # Start recording
    # ------------------------------------------------------------------

    Write-Host ""
    Write-Host "Starting recording..."
    Write-Host "Output folder: $script:outputPath"
    Write-Host "Block duration: $script:segmentMinutes minutes"
    Write-Host "Recording audio volume: $script:audioVolumePercent percent"
    Write-Host ""

    if ($script:mode -ne "AUDIO") {

        Write-Host $(if($script:mode -eq 'VIDEO'){Get-QualityText 'Mode: Camera only' 'Modo: Apenas câmara'}else{Get-QualityText 'Mode: Camera + external audio' 'Modo: Câmara + áudio externo'})
        Write-Host "Video: camera HEVC/H.265"
        Write-Host "MP4 audio: camera audio converted to AAC"
        if($script:mode -ne 'VIDEO'){Write-Host "WAV audio: $($script:selectedDevice.Name)"}
    }
    else {

        Write-Host (Get-QualityText 'Mode: External audio only' 'Modo: Apenas áudio externo')
        Write-Host "WAV audio: $($script:selectedDevice.Name)"
    }

    Write-Host ""

    $script:startLiveVisualization = {
        if(-not $SemGraficos){
            $script:liveFinished=$true
            $script:livePlayer=$null;$script:liveRenderer=$null;$script:liveCopy=$null
            Update-IndependentRecordingView -Capturing
        }
    }
    $script:startTime=Get-Date
    $script:metadata.StartTime=$script:startTime
    if (-not $script:process.Start()) {
        throw (Get-UiText "Could not start FFmpeg.")
    }
    # Drain stderr concurrently to avoid blocking FFmpeg when its pipe fills.
    $script:cameraCount=0;if($script:mode -ne 'AUDIO'){$script:cameraCount=@($script:camera).Count}
    $script:captureLogMonitor=New-Object MachiningMonitor.CaptureLog164($script:process.StandardError,$script:ffmpegLogPath,$script:cameraCount,10,30,($script:mode -ne 'VIDEO'))
    . $script:startLiveVisualization
    Set-Content -LiteralPath $script:recordingHostFile -Value $PID -Encoding ASCII

    if ($script:mode -ne 'AUDIO' -and $script:previewVideoEnabled -and $SemGraficos) {
        $script:previewProcess = Start-RecordingPreview -CameraUrl $script:camera[0] -BasePath $script:basePath
        if ($null -ne $script:previewProcess) {
            try { $script:escapeGuard = New-RecordingEscapeGuard $script:previewProcess.Id }
            catch {
                Stop-RecordingPreview $script:previewProcess
                $script:previewProcess = $null
                Write-Warning 'Could not protect the recording window from Escape.'
            }
        }
    }

    Set-Content `
        -Path $script:pidFile `
        -Value $script:process.Id `
        -Encoding ASCII

    Write-Host "FFmpeg PID: $($script:process.Id)"
    Write-Host ""
    Write-Host "Use Parar_gravacao.bat to stop recording safely."
    Write-Host ""


    # ------------------------------------------------------------------
    # Wait for recording to finish
    # ------------------------------------------------------------------

    $script:u=$script:RecordingUi
    $script:u.Running=$true; $script:u.PendingRecordingContext=$null; $script:u.Stop.Enabled=$true; $script:u.Event.Enabled=$false
    $script:u.State=@{Path=(Join-Path $script:outputPath 'events.json');Items=@();List=$script:u.List;Timeline=$null;RefreshingList=$false;
        RecordingStart=$script:startTime;Clock=[pscustomobject]@{Ready=$false;Seconds=0.0};Handle=$script:u.Form.Handle;Paused=$true;
        BaseSeconds=0.0;Ended=$false;Duration=0.0;Player=$script:process;LiveRecording=$true}

}
# Capture callback: service stop requests, refresh elapsed time and check media-process health.
$script:RecordingTickAction = {
        Update-RecordingMediaClock
        if($script:selectedDevice.Type -eq 'RTSP' -and -not $script:RecordingUi.Stopping -and $script:captureLogMonitor -and $script:captureLogMonitor.Ready -and $script:captureLogMonitor.ExternalAudioIdleSeconds -gt 10){
            throw (Get-QualityText 'External RTSP audio stopped arriving. Recording stopped; recorded blocks are preserved. Check AudioRTSP and the network before starting again.' 'O áudio externo RTSP deixou de chegar. A gravação foi interrompida e os blocos gravados foram preservados. Verifique o AudioRTSP e a rede antes de iniciar novamente.')
        }

        if ($script:u.LanguageChanged -and -not $script:u.Stopping) {
            $script:u.LanguageChanged=$false
            if($null -ne $script:escapeGuard){ $script:escapeGuard.Dispose(); $script:escapeGuard=$null }
            Stop-PlaybackProcess $script:liveRenderer; Stop-PlaybackProcess $script:livePlayer
            if($null -ne $script:liveCopy){try{[void]$script:liveCopy.Wait(1000)}catch{}}
            Save-RecordingDiagnostic $script:liveRendererErrorsTask (Join-Path $script:outputPath 'visualization_renderer_language.log')
            Save-RecordingDiagnostic $script:livePlayerErrorsTask (Join-Path $script:outputPath 'visualization_player_language.log')
            foreach($script:oldProcess in @($script:liveRenderer,$script:livePlayer)){if($null -ne $script:oldProcess){$script:oldProcess.Dispose()}}
            $script:liveRenderer=$null; $script:livePlayer=$null; $script:liveCopy=$null
            . $script:startLiveVisualization
        }
        if ($script:u.Form.WindowState -ne 'Minimized' -and -not $script:liveFinished -and $null -ne $script:livePlayer -and -not $script:livePlayer.HasExited -and $script:u.VideoHandle -eq [IntPtr]::Zero) {
            $script:child=[MachiningMonitor.QualityClock]::FindWindow($script:livePlayer.Id)
            if($script:child -ne [IntPtr]::Zero){
                Embed-RecordingVisualization $script:child
            }
        }
        # Keep elapsed milliseconds and deadline/countdown information together in the recording status line.
        Update-RecordingClockLabel


        if (-not $script:liveFinished -and $null -ne $script:liveRenderer -and (($script:u.WaitingForImage -and ([DateTime]::UtcNow-$script:liveStartedAt).TotalSeconds -gt 5) -or $script:liveRenderer.HasExited -or ($null -ne $script:livePlayer -and $script:livePlayer.HasExited) -or ($null -ne $script:liveCopy -and $script:liveCopy.IsCompleted))) {
            Stop-PlaybackProcess $script:liveRenderer
            Stop-PlaybackProcess $script:livePlayer
            $script:liveFinished = $true
            $script:u.VideoHandle=[IntPtr]::Zero; $script:u.Placeholder.Visible=$true
            $script:u.Placeholder.Text=Get-QualityText 'Visualization ended. Recording continues.' 'A visualização terminou. A gravação continua.'
            $issue=Get-RecordingViewFailure -Capturing
            if($issue.Kind -eq 'Audio'){throw $issue.Message}
            if($issue.Kind -eq 'Camera'){Show-RecordingCameraUnavailable $issue.Message}
            Write-Warning 'Visualization ended. Recording continues; use Parar_gravacao.bat to stop it.'
        }

        if (Test-Path $script:stopFile) {

            Write-Host ""
            Write-Host "Stop requested. Sending 'q' to FFmpeg..."

            Remove-Item `
                $script:stopFile `
                -Force `
                -ErrorAction SilentlyContinue

            try {
                $script:process.StandardInput.WriteLine("q")
                $script:process.StandardInput.Flush()
            }
            catch {
                Write-Host "Could not send 'q' to FFmpeg."
            }

            $script:RecordingLoopDone=$true
            return
        }


        $script:process.Refresh()
    
}
# Finish callback: finalize capture time, save metadata and report segment diagnostics.
$script:RecordingFinishAction = {

    Stop-RecordingProcess $script:process
    if ($null -ne $script:captureLogMonitor) {
        if ($script:captureLogMonitor.Complete(3000)) {
            try { Add-Content -LiteralPath $script:ffmpegLogPath -Encoding UTF8 -Value (([DateTimeOffset]::Now.ToString('o'))+' [PROCESS_EXIT] code='+$script:process.ExitCode) }
            catch { Write-Warning ('Não foi possível completar o log: '+$_.Exception.Message) }
        }
        if ($script:captureLogMonitor.Failure) { Write-Warning ('Falha na escrita do log: '+$script:captureLogMonitor.Failure) }
    }
    if ($null -ne $script:escapeGuard) { $script:escapeGuard.Dispose(); $script:escapeGuard = $null }
    Stop-PlaybackProcess $script:liveRenderer
    Stop-PlaybackProcess $script:livePlayer
    Stop-RecordingPreview $script:previewProcess

    Remove-Item -LiteralPath $script:recordingHostFile -Force -ErrorAction SilentlyContinue
    $script:previewProcess = $null
    # Form manages focus.
    if($script:selectedDevice.Type -eq 'RTSP' -and -not $script:RecordingUi.Stopping -and -not $script:RecordingLoopDone){
        throw (Get-QualityText 'External RTSP audio ended unexpectedly. Recorded blocks were preserved. Check AudioRTSP and the network before starting again.' 'O áudio externo RTSP terminou inesperadamente. Os blocos gravados foram preservados. Verifique o AudioRTSP e a rede antes de iniciar novamente.')
    }
    if ($script:process.ExitCode -ne 0) {
        if ($script:UiLanguage -eq 'pt') {
            throw "A gravação terminou com erro (código $($script:process.ExitCode)). Consulte: $script:ffmpegLogPath"
        }
        throw "Recording failed (exit code $($script:process.ExitCode)). See: $script:ffmpegLogPath"
    }


    # ------------------------------------------------------------------
    # Finish recording metadata
    # ------------------------------------------------------------------

    $script:durationPlan=$script:RecordingUi.ManualTimer
    if($script:RecordingUi.ActiveSchedule){$script:durationPlan=$script:RecordingUi.ActiveSchedule}
    $script:durationLimit=Get-RecordingPlanSeconds $script:durationPlan
    if($null -ne $script:durationLimit){Complete-RecordingDurationLimit $script:outputPath $script:durationLimit $script:cameraCount $script:ffmpegPath}
    try { Write-RecordingSegmentDiagnostic $script:outputPath ([double]($script:segmentMinutes*60)) ($script:mode -ne 'AUDIO') -CameraOnly:($script:mode -eq 'VIDEO') }
    catch { Write-Warning ('Não foi possível guardar o diagnóstico de segmentos: '+$_.Exception.Message) }
    Update-RecordingMediaClock
    $script:endTime=$script:metadata.StartTime
    $script:mediaDuration=Get-RecordedSessionSeconds $script:outputPath
    if($null -ne $script:mediaDuration){$script:endTime=$script:metadata.StartTime.AddSeconds($script:mediaDuration)}
    elseif($script:captureLogMonitor.Ready){$script:endTime=$script:metadata.StartTime.AddSeconds($script:captureLogMonitor.Seconds)}

    $script:metadata.Finish($script:endTime)
    $script:RecordingEndedAt=$script:endTime

    Write-Host ""
    Clear-Host
    Write-Host "Recording finished."
    Write-Host ""

    Write-Host "Start    : $($script:metadata.StartTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
    Write-Host "End      : $($script:metadata.EndTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
    Write-Host "Duration : $($script:metadata.Duration)"

    Write-Host ""


    Save-BaseRecordingMetadata
    # Success is reported only after process exit validation and base metadata saving have completed.
    Complete-RecordingPlan $true $script:RecordingEndedAt
    $script:RecordingUi.Running=$false
    $script:RecordingUi.Stop.Enabled=$false; $script:RecordingUi.Event.Enabled=$false

}
# Cleanup also handles partial startup: stop media processes, save diagnostics and release resources.
$script:RecordingCleanupAction = {
    Stop-IndependentRecordingView
    $script:independentCapturing=$false


    if ($null -ne $script:escapeGuard) { $script:escapeGuard.Dispose(); $script:escapeGuard = $null }

    Stop-PlaybackProcess $script:liveRenderer
    Stop-PlaybackProcess $script:livePlayer
    if ($null -ne $script:liveCopy) { try { [void]$script:liveCopy.Wait(2000) } catch {} }
    if ($script:outputPath) {
        Save-RecordingDiagnostic $script:liveRendererErrorsTask (Join-Path $script:outputPath 'visualization_renderer.log')
        Save-RecordingDiagnostic $script:livePlayerErrorsTask (Join-Path $script:outputPath 'visualization_player.log')
    }
    foreach ($script:liveProcess in @($script:liveRenderer, $script:livePlayer)) {
        if ($null -ne $script:liveProcess) { $script:liveProcess.Dispose() }
    }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    Stop-RecordingPreview $script:previewProcess
    Remove-Item -LiteralPath $script:recordingHostFile -Force -ErrorAction SilentlyContinue

    Remove-Item `
        $script:pidFile `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        $script:stopFile `
        -Force `
        -ErrorAction SilentlyContinue

    if ($script:process -ne $null) {
        Stop-RecordingProcess $script:process
        if ($null -ne $script:captureLogMonitor) { [void]$script:captureLogMonitor.Complete(3000) }
        if ($null -ne $script:captureLogMonitor) { $script:captureLogMonitor.Dispose() }
        Remove-EmptyRecordingFiles $script:outputPath
        Save-BaseRecordingMetadata
        $script:process.Dispose()
        Remove-EmptyRecordingFiles $script:outputPath
    }
    $script:process=$null
    $script:livePlayer=$null; $script:liveRenderer=$null; $script:liveCopy=$null
    $script:captureLogMonitor=$null
}
# A 50 ms UI timer drives capture; ControllerBusy prevents overlapping ticks.
$script:RecordingControllerTimer=New-Object Windows.Forms.Timer
$script:RecordingControllerTimer.Interval=50
$script:RecordingControllerTimer.Add_Tick({
    $ui=$script:RecordingUi
    Restore-RecordingInstanceWindow $recordingInstance $ui.Form
    Update-RecordingViewIndicator
    if($ui.ControllerBusy -or $ui.Form.IsDisposed){return}
    # Service scheduling before entering the capture-controller busy section; scheduling may request a normal start.
    Update-RecordingSchedule
    # Let the mode popup own the interaction; no idle renderer rebuild/reparent while it is open.
    if(-not $ui.Running -and -not $ui.Ready -and $ui.Mode.DroppedDown){return}
    $ui.ControllerBusy=$true
    try {
        if($ui.Ready -and -not $ui.Running){
            $script:validatedLiveCamera=Get-HealthyLiveCamera
            Stop-ActiveRecordingView
            $ui.Ready=$false
            $ui.Start.Enabled=$false; $ui.Mode.Enabled=$false; $ui.Settings.Enabled=$false
            $ui.List.Items.Clear()
            $script:RecordingLoopDone=$false
            . $script:RecordingStartAction
        }
        if(-not $ui.Running -and -not $ui.Ready){
            try {Update-ActiveRecordingView} catch {
                $viewException=$_.Exception
                $message=$viewException.Message
                Show-RecordingViewFailure $viewException
                $ui.Placeholder.Text=$message; $ui.Status.Text=$message
            }
        }
        Update-AdaptiveRecordingVisualization
        if($ui.Running){
            if(-not $script:process.HasExited){ . $script:RecordingTickAction }
            if($script:process.HasExited -or $script:RecordingLoopDone){
                try { . $script:RecordingFinishAction }
                finally { . $script:RecordingCleanupAction }
                $ui.Running=$false; $ui.Stop.Enabled=$false; $ui.Event.Enabled=$false
                # Timed/scheduled plans apply their stored context choice automatically and skip the interactive context prompt.
                if(-not $ui.PlanContextManaged -and $script:metadata -and (Test-Path -LiteralPath (Join-Path $script:outputPath 'metadata.json'))){
                    Complete-FinishedRecordingContext $script:outputPath $script:recordingsPath
                }
                Reset-RecordingForm
            }
        }
    } catch {
        $failure=$_.Exception.Message
        # Preserve a timed/scheduled failure in the result notice and queue before resetting the form.
        Complete-RecordingPlan $false ([datetime]::Now) $failure
        try { . $script:RecordingCleanupAction } catch {Write-Warning $_.Exception.Message}
        $ui.Running=$false
        Show-QualityError $failure
        Reset-RecordingForm
    } finally {$ui.ControllerBusy=$false; Update-RecordingViewIndicator}
})
$script:RecordingClockTimer=New-Object Windows.Forms.Timer
$script:RecordingClockTimer.Interval=20
$script:RecordingClockTimer.Add_Tick({Update-RecordingClockLabel})
$script:RecordingClockTimer.Start()
$script:RecordingControllerTimer.Start()
[Windows.Forms.Application]::Run($script:RecordingUi.Form)

} catch [System.OperationCanceledException] {
    # Shared chart prompts also serve playback; cancellation here is recording.
    Write-Host (Get-UiText 'Recording cancelled.')
    exit 2
}

catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Machining Monitor','OK','Error')
}
finally {
    Stop-ActiveRecordingView
    if($script:RecordingClockTimer){$script:RecordingClockTimer.Stop();$script:RecordingClockTimer.Dispose()}
    if($script:RecordingControllerTimer){$script:RecordingControllerTimer.Stop();$script:RecordingControllerTimer.Dispose()}
    if ($script:RecordingUi -and -not $script:RecordingUi.Form.IsDisposed) {
        $script:RecordingUi.Running=$false
        $script:RecordingUi.Form.Dispose()
    }
    Exit-RecordingInstance $recordingInstance
}


