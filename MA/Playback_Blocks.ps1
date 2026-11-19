<#
Playback_Blocks.ps1 - version 182.
Continuous playback of segmented recordings. Build temporary ffconcat lists, configure FFmpeg/mpv, attach event and extraction controls, and release resources when playback ends.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RecordingPath, [switch]$SemGraficos, [switch]$ApenasFuncoes, [switch]$ShowPlaybackErrors, $TransitionNotice)
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Language.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Events.ps1')
. (Join-Path $PSScriptRoot 'Playback_Cameras.ps1')
. (Join-Path $PSScriptRoot 'Recording_Duration.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Playback_Timeline.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Mpv_Playback.ps1')
. (Join-Path $PSScriptRoot 'Playback_Broadcast.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Vibration_Filters.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Split.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Playback_Settings.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Metadata.ps1')
$ErrorActionPreference = 'Stop'

# Pretty-print playback preference JSON without changing quoted values.
function Format-PlaybackJson {
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

# Load playback preferences from a JSON file.
function Read-PlaybackSettings {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    try {
        $settings = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $settings -or $settings -isnot [pscustomobject]) { throw (Get-UiText 'Expected object') }
        return $settings
    }
    catch { throw (Get-UiText "Não foi possível ler o ficheiro JSON '$Path'.") }
}

# Read a numeric audio/video offset setting.
function Get-OffsetValue {
    param($Settings, [string]$Name)
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $value = 0
    if ($null -eq $property.Value -or $property.Value -is [bool] -or
        -not [int]::TryParse([string]$property.Value, [ref]$value) -or
        $value -lt -3600000 -or $value -gt 3600000) {
        throw (Get-UiText "$Name deve ser um número inteiro entre -3600000 e 3600000 milissegundos.")
    }
    return $value
}

# Resolve the recording-specific offset before falling back to the global preference.
function Get-DefaultOffset {
    param([string]$OffsetPath, [string]$ConfigPath)
    $value = Get-OffsetValue (Read-PlaybackSettings $OffsetPath) 'AudioOffsetMs'
    if($null -eq $value){
        # Capture compensation is already encoded in these media files.
        # A deliberate adjustment saved for this recording still takes precedence.
        $metadata=Read-PlaybackSettings (Join-Path (Split-Path $OffsetPath -Parent) 'metadata.json')
        if($metadata.Synchronization){return 0}
    }
    if ($null -eq $value) { $value = Get-OffsetValue (Read-PlaybackSettings $ConfigPath) 'LastAudioOffsetMs' }
    if ($null -eq $value) { return 0 }
    return $value
}

# Persist the selected synchronization offset for subsequent playback.
function Save-PlaybackOffset {
    param([string]$OffsetPath, [string]$ConfigPath, [int]$OffsetMs)
    # Preserve existing configuration fields when updating the last used offset.
    $config = Read-PlaybackSettings $ConfigPath
    $offset = Read-PlaybackSettings $OffsetPath
    $config | Add-Member NoteProperty LastAudioOffsetMs $OffsetMs -Force
    $offset | Add-Member NoteProperty AudioOffsetMs $OffsetMs -Force
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($OffsetPath, (Format-PlaybackJson ($offset | ConvertTo-Json -Depth 20 -Compress)) + [Environment]::NewLine, $encoding)
    [IO.File]::WriteAllText($ConfigPath, (Format-PlaybackJson ($config | ConvertTo-Json -Depth 20 -Compress)) + [Environment]::NewLine, $encoding)
}

# Read a synchronization-offset editor keystroke.
function Read-OffsetKey { return [Console]::ReadKey($true) }

# Read an editable offset value using the current value as the default.
function Read-OffsetInput {
    param([int]$Default)
    $prompt = 'Video alignment relative to audio in ms (positive advances video; negative delays video)'
    if ([Console]::IsInputRedirected) {
        $text = Read-Host "$prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($text)) { return [string]$Default }
        return $text
    }
    # Display the actual editable value, not just a default in the prompt.
    Microsoft.PowerShell.Utility\Write-Host ((Get-UiText $prompt) + ': ') -NoNewline
    $text = [string]$Default
    Microsoft.PowerShell.Utility\Write-Host $text -NoNewline
    $cursor = $text.Length
    while ($true) {
        $key = Read-OffsetKey
        if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ''; return $text }
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''; throw [OperationCanceledException]::new('Reprodução cancelada.')
        }
        $previous = $text
        $previousCursor = $cursor
        switch ($key.Key) {
            'LeftArrow' { if ($cursor -gt 0) { $cursor-- } }
            'RightArrow' { if ($cursor -lt $text.Length) { $cursor++ } }
            'Home' { $cursor = 0 }
            'End' { $cursor = $text.Length }
            'Backspace' {
                if ($cursor -gt 0) { $text = $text.Remove($cursor - 1, 1); $cursor-- }
            }
            'Delete' { if ($cursor -lt $text.Length) { $text = $text.Remove($cursor, 1) } }
            default {
                if ($key.KeyChar -match '[0-9+-]' -and $text.Length -lt 10) {
                    $text = $text.Insert($cursor, [string]$key.KeyChar); $cursor++
                }
            }
        }
        Write-Host (([string][char]8) * $previousCursor) -NoNewline
        $width = [Math]::Max($previous.Length, $text.Length)
        Microsoft.PowerShell.Utility\Write-Host ($text.PadRight($width)) -NoNewline
        Write-Host (([string][char]8) * ($width - $cursor)) -NoNewline
    }
}

# Request and validate the audio/video synchronization offset.
function Read-PlaybackOffset {
    param([int]$Default)
    do {
        $text = Read-OffsetInput $Default
        $value = 0
        $valid = [int]::TryParse($text, [ref]$value) -and $value -ge -3600000 -and $value -le 3600000
        if (-not $valid) { Write-Host 'Introduza um valor inteiro em milissegundos.' }
    } while (-not $valid)
    return $value
}

# Build the FFmpeg audio filter corresponding to the requested offset.
function Get-OffsetFilter {
    param([int]$OffsetMs)
    if ($OffsetMs -ge 0) { return "asetpts=PTS-STARTPTS,adelay=${OffsetMs}:all=1" }
    $seconds = (-$OffsetMs / 1000.0).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    return "atrim=start=$seconds,asetpts=PTS-STARTPTS"
}

# Build media input and mapping arguments for the selected source and synchronization offset.
function Get-PlaybackMediaArguments {
    param([string]$Source, [string]$VideoList, [string]$AudioList, [int]$OffsetMs, [string[]]$CameraLists=@(), [switch]$ForVisualization, [ValidateSet('Horizontal','Vertical')][string]$CameraLayout='Horizontal', [ValidateRange(-60,60)][int]$MixCameraGainDb=0, [ValidateRange(-60,60)][int]$MixSensorGainDb=40)
    $items = @('-nostdin', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $VideoList)
    if ($Source -ne 'C') { $items += @('-f', 'concat', '-safe', '0', '-i', $AudioList) }
    if($Source -ne 'A'){$items=@(Add-PlaybackCameraInputs $items $CameraLists)}
    # Camera audio shares the video recording clock; only external audio may shift.
    $filter = 'asetpts=PTS-STARTPTS'
    if ($Source -ne 'C') { $filter = Get-OffsetFilter $OffsetMs }
    if ($Source -eq 'T') {
        # Negotiate each source before amix: the camera may be 8 kHz mono.
        # Converting after amix cannot restore external high frequencies or L/R.
        $graph = "[0:a:0]asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[cam];[1:a:0]$filter,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[ext];[cam]volume=${MixCameraGainDb}dB[camlisten];[ext]volume=${MixSensorGainDb}dB[extlisten];[camlisten][extlisten]amix=inputs=2:duration=longest:normalize=1,alimiter=limit=0.95:level=0:latency=1,apad[aout]"
    }
    else {
        $inputIndex = 1
        if ($Source -eq 'C') { $inputIndex = 0 }
        $auditionGain=$MixSensorGainDb;$sourceLabel='ext'
        if ($Source -eq 'C') { $auditionGain=$MixCameraGainDb;$sourceLabel='singleSource' }
        # Split before audition gain, so single-source plots retain their physical amplitudes.
        $graph = "[${inputIndex}:a:0]$filter[${sourceLabel}];[${sourceLabel}]asplit=2[singleRaw][singleHear];[singleHear]volume=${auditionGain}dB,alimiter=limit=0.95:level=0:latency=1,apad[aout];[singleRaw]anullsink"
    }
    $videoMap='0:v:0';$codec='copy'
    if($CameraLists.Count -and -not $ForVisualization){
        $graph=ConvertTo-PlaybackCameraGraph ($graph+';[0:v:0]null[cameraout]') $Source $CameraLists -CameraLayout $CameraLayout
        $videoMap='[cameraout]';$codec='libx264'
    }
    $items += @('-filter_complex', $graph, '-map', $videoMap, '-map', '[aout]',
        '-c:v', $codec, '-c:a', 'pcm_s16le', '-shortest', '-f', 'matroska', 'pipe:1')
    return $items
}

# Audio-only playback without plots still observes the external-audio audition gain.
function Get-ExternalPlaybackArguments {
    param([string]$AudioList,[ValidateRange(-60,60)][int]$GainDb=40)
    $graph="[0:a:0]asetpts=PTS-STARTPTS[ext];[ext]volume=${GainDb}dB,alimiter=limit=0.95:level=0:latency=1[aout]"
    return @('-nostdin','-loglevel','error','-f','concat','-safe','0','-i',$AudioList,'-filter_complex',$graph,'-map','[aout]','-c:a','pcm_s16le','-f','matroska','pipe:1')
}
# Per-recording audition gains. They never change source files or analysis amplitudes.
function Read-MixedAudioGains {
    param([string]$Path)
    $data=Read-PlaybackSettings $Path
    $camera=0;$sensor=40
    if ($null -ne $data.MixCameraGainDb) { $camera=[Math]::Max(-60,[Math]::Min(60,[int]$data.MixCameraGainDb)) }
    if ($null -ne $data.MixSensorGainDb) { $sensor=[Math]::Max(-60,[Math]::Min(60,[int]$data.MixSensorGainDb)) }
    return @{Camera=$camera;Sensor=$sensor}
}
function Save-MixedAudioGains {
    param([string]$Path,[int]$Camera,[int]$Sensor)
    $data=Read-PlaybackSettings $Path
    $data | Add-Member NoteProperty MixCameraGainDb $Camera -Force
    $data | Add-Member NoteProperty MixSensorGainDb $Sensor -Force
    [IO.File]::WriteAllText($Path,(Format-PlaybackJson ($data | ConvertTo-Json -Depth 20 -Compress))+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}
# Read the operator's playback audio-source choice.
function Read-PlaybackAudioSource {
    param([ValidateSet('C','S','T')][string]$Default)
    $prompt = "Choose C, S or T [$Default] (Enter accepts)"
    if ([Console]::IsInputRedirected) {
        $text = (Read-Host $prompt).Trim().ToUpperInvariant()
        if ($text.Contains([string][char]27)) { throw [OperationCanceledException]::new('Reprodução cancelada.') }
        if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
        return $text
    }
    Microsoft.PowerShell.Utility\Write-Host ((Get-UiText $prompt) + ': ') -NoNewline
    $text = ''
    while ($true) {
        $key = Read-OffsetKey
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''; throw [OperationCanceledException]::new('Reprodução cancelada.')
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ''
            if ($text.Length -eq 0) { return $Default }
            return $text
        }
        if ($key.Key -eq [ConsoleKey]::Backspace -and $text.Length) {
            Write-Host "`b `b" -NoNewline
            $text = ''
        }
        elseif ($key.KeyChar -match '[cCsStT]' -and $text.Length -eq 0) {
            $text = ([string]$key.KeyChar).ToUpperInvariant()
            Microsoft.PowerShell.Utility\Write-Host $text -NoNewline
        }
    }
}

# Resolve the saved audio-source preference against the sources actually available.
function Get-DefaultPlaybackAudioSource {
    param([string]$ConfigPath, [bool]$HasExternalAudio)
    $settings = Read-PlaybackSettings $ConfigPath
    $property = $settings.PSObject.Properties['LastPlaybackAudioSource']
    if ($null -ne $property -and $property.Value -in @('C','S','T')) {
        if ($HasExternalAudio -or $property.Value -eq 'C') { return $property.Value }
    }
    return 'C'
}

# Save the selected playback audio source in the shared configuration.
function Save-PlaybackAudioSource {
    param([string]$ConfigPath, [ValidateSet('C','S','T')][string]$Source)
    $settings = Read-PlaybackSettings $ConfigPath
    $settings | Add-Member NoteProperty LastPlaybackAudioSource $Source -Force
    [IO.File]::WriteAllText($ConfigPath, (Format-PlaybackJson ($settings | ConvertTo-Json -Depth 20 -Compress)) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

# Read the preferred channel used for the spectrum display.
function Get-DefaultSpectrumChannel {
    param([string]$ConfigPath)
    $settings = Read-PlaybackSettings $ConfigPath
    $property = $settings.PSObject.Properties['LastSpectrumChannel']
    if ($null -ne $property -and $property.Value -in @('L', 'R')) { return $property.Value }
    return 'R'
}

# Persist the spectrum-channel preference.
function Save-SpectrumChannel {
    param([string]$ConfigPath, [ValidateSet('L','R')][string]$Channel)
    $settings = Read-PlaybackSettings $ConfigPath
    $settings | Add-Member NoteProperty LastSpectrumChannel $Channel -Force
    [IO.File]::WriteAllText($ConfigPath, (Format-PlaybackJson ($settings | ConvertTo-Json -Depth 20 -Compress)) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

# Read a constrained chart input while allowing the operator to cancel.
function Read-CancellableChartInput {
    param([string]$Prompt, [string]$AllowedPattern, [int]$MaxLength)
    $promptWithEscape = $Prompt
    if ([Console]::IsInputRedirected) {
        $text = Read-Host $promptWithEscape
        if ($text.Contains([string][char]27)) { throw [OperationCanceledException]::new('Reprodução cancelada.') }
        return $text.Trim()
    }
    Microsoft.PowerShell.Utility\Write-Host ((Get-UiText $promptWithEscape) + ': ') -NoNewline
    $text = ''
    while ($true) {
        $key = Read-OffsetKey
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''; throw [OperationCanceledException]::new('Reprodução cancelada.')
        }
        if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ''; return $text }
        if ($key.Key -eq [ConsoleKey]::Backspace -and $text.Length -gt 0) {
            $text = $text.Substring(0, $text.Length - 1)
            Write-Host "`b `b" -NoNewline
        }
        elseif ($key.KeyChar -match $AllowedPattern -and $text.Length -lt $MaxLength) {
            $character = ([string]$key.KeyChar).ToUpperInvariant()
            $text += $character
            Microsoft.PowerShell.Utility\Write-Host $character -NoNewline
        }
    }
}

# Request the channel to use for the spectrum display.
function Read-SpectrumChannel {
    param([ValidateSet('L','R')][string]$Default)
    Write-Host 'Spectrogram: L - Left / Ambient sound; R - Right / Spindle vibration'
    do {
        $value = (Read-CancellableChartInput "Spectrogram channel [$Default] (Enter accepts)" '[lLrR]' 1).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        if ($value -notin @('L','R')) { Write-Host 'Choose L or R.' }
    } while ($value -notin @('L','R'))
    return $value
}

# Read the saved visual gain used to draw the waveform.
function Get-DefaultWaveformGain {
    param([string]$ConfigPath)
    $settings = Read-PlaybackSettings $ConfigPath
    $property = $settings.PSObject.Properties['LastWaveformGain']
    $gain = 0
    if ($null -ne $property -and [int]::TryParse([string]$property.Value, [ref]$gain) -and $gain -ge 1 -and $gain -le 20) { return $gain }
    return 1
}

# Request and validate waveform display gain.
function Read-WaveformGain {
    param([ValidateRange(1,20)][int]$Default)
    do {
        $text = Read-CancellableChartInput "Spectrum gain (1 to 20; 1 = normal) [$Default]" '[0-9]' 2
        if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
        $gain = 0
        $valid = [int]::TryParse($text, [ref]$gain) -and $gain -ge 1 -and $gain -le 20
        if (-not $valid) { Write-Host 'Enter an integer between 1 and 20.' }
    } while (-not $valid)
    return $gain
}

# Persist waveform display gain without changing the recorded media.
function Save-WaveformGain {
    param([string]$ConfigPath, [ValidateRange(1,20)][int]$Gain)
    $settings = Read-PlaybackSettings $ConfigPath
    $settings | Add-Member NoteProperty LastWaveformGain $Gain -Force
    [IO.File]::WriteAllText($ConfigPath, (Format-PlaybackJson ($settings | ConvertTo-Json -Depth 20 -Compress)) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
# Build the time expression used to identify media blocks during playback.
function Get-PlaybackBlockExpression {
    param([object[]]$Files,[string]$CsvPath,[string]$Folder)
    $number=0
    if ($Files.Count -gt 0 -and $Files[0].BaseName -match '_(\d+)$') { $number=[int]$Matches[1] }
    if ($Files.Count -le 1) { return [string]$number }
    # Match the boundaries used by the concat list, including nonuniform
    # camera segments and missing segment numbers.
    try {
        $rows=@(Import-Csv -LiteralPath $CsvPath -Header File,Start,End -ErrorAction Stop)
        $starts=@{}
        foreach ($r in $rows) { $starts[[IO.Path]::GetFileName($r.File)]=[double]::Parse($r.Start,[Globalization.CultureInfo]::InvariantCulture) }
        if (@($Files | Where-Object { -not $starts.ContainsKey($_.Name) }).Count -eq 0) {
            $origin=$starts[$Files[0].Name]; $previous=$number; $expression=[string]$number
            for ($i=1;$i -lt $Files.Count;$i++) {
                $current=$i
                if ($Files[$i].BaseName -match '_(\d+)$') { $current=[int]$Matches[1] }
                $boundary=($starts[$Files[$i].Name]-$origin).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
                $expression+='+gte(t,'+$boundary+')*'+($current-$previous)
                $previous=$current
            }
            return $expression
        }
    } catch { }
    $seconds=600.0
    try {
        $metadata=Get-Content -LiteralPath (Join-Path $Folder 'metadata.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $minutes=[double]$metadata.SegmentMinutes
        if ($minutes -gt 0 -and $minutes -le 1440) { $seconds=$minutes*60 }
    } catch { }
    return ([string]$number+'+floor(t/'+$seconds.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)+')')
}
# Build the spectrogram filter for the requested drawing dimensions.
function Get-PlaybackSpectrogramFilter {
    param([int]$Width,[int]$Height=112)
    # At the original 900 px width, each row consumes 1800 samples at 48 kHz
    # (37.5 ms; 112 rows = 4.2 seconds). showspectrum derives its FFT length
    # from width, so compensate with overlap instead of changing history speed.
    # Power-of-two FFT dimensions behave consistently in older and newer
    # FFmpeg builds. Reduce only the frequency axis to the viewport width;
    # the history rows and the labels drawn afterwards are never resized.
    $analysisWidth=1024
    while ($analysisWidth -lt $Width) { $analysisWidth*=2 }
    $overlap=0.0
    if ($analysisWidth -gt 900) {
        # The filter truncates a float to obtain its integer sample hop.
        # Aim inside the 1800-sample interval to avoid rounding down to 1799.
        $overlap=1.0-1800.25/(2.0*$analysisWidth)
    }
    $text=$overlap.ToString('0.############',[Globalization.CultureInfo]::InvariantCulture)
    $filter="showspectrum=s=${analysisWidth}x${Height}:orientation=horizontal:slide=rscroll:mode=combined:color=intensity:scale=log:fscale=lin:win_func=hann:overlap=${text}:fps=25"
    if ($Width -ne $analysisWidth) { $filter+=",scale=${Width}:${Height}:flags=area" }
    return $filter
}
# Combine source media, charts, timing overlays and dimensions into FFmpeg arguments.
function Get-VisualizationArguments {
    param([string]$Source, [string]$VideoList, [string]$AudioList, [int]$OffsetMs, [ValidateSet('L','R')][string]$SpectrumChannel = 'R', [ValidateRange(1,20)][int]$WaveformGain = 1, [switch]$RecordingTimer, [ValidateRange(0.000001,86400)][double]$RecordingBlockSeconds = 600, [string]$PlaybackBlockExpression, [int]$CanvasWidth=960, [int]$CanvasHeight=0, [bool]$ShowVideo=$true, [bool]$ShowCharts=$true, [int]$VideoPanelHeight=0, [int]$FrequencyPanelHeight=0, [int]$HistoryPanelHeight=0, [string[]]$CameraLists=@(), [ValidateSet('Horizontal','Vertical')][string]$CameraLayout='Horizontal', [ValidateRange(-60,60)][int]$MixCameraGainDb=0, [ValidateRange(-60,60)][int]$MixSensorGainDb=40, [hashtable]$VideoZoom=@{})
    $CanvasWidth=[Math]::Max(320,2*[int][Math]::Floor($CanvasWidth/2))
    if ($CanvasHeight -le 0) { $CanvasHeight=956; if ($Source -eq 'A') { $CanvasHeight=416 } }
    $minimumHeight=136; if($Source -ne 'A'){$minimumHeight=160}
    $CanvasHeight=[Math]::Max($minimumHeight,2*[int][Math]::Floor($CanvasHeight/2))
    $plotHeight=$CanvasHeight
    if($Source -ne 'A' -and $ShowVideo -and $ShowCharts){
        $plotHeight=[Math]::Min($CanvasHeight-24,[Math]::Max(136,2*[int][Math]::Floor(($CanvasHeight*416.0/956)/2)))
    }
    # Reserve fixed pixel margins for text. Only the analysis viewports change size.
    $frequencyHeight=[Math]::Min($plotHeight-56,[Math]::Max(80,2*[int][Math]::Floor(($plotHeight*256.0/416)/2)))
    $spectrogramHeight=$plotHeight-$frequencyHeight
    if($FrequencyPanelHeight -gt 0){$frequencyHeight=[Math]::Max(80,2*[int][Math]::Floor($FrequencyPanelHeight/2))}
    if($HistoryPanelHeight -gt 0){$spectrogramHeight=[Math]::Max(56,2*[int][Math]::Floor($HistoryPanelHeight/2))}
    if($FrequencyPanelHeight -gt 0 -or $HistoryPanelHeight -gt 0){$plotHeight=$frequencyHeight+$spectrogramHeight}
    $spectrumHeight=$frequencyHeight-64
    $historyHeight=$spectrogramHeight-48
    $frequencyAxisY=$frequencyHeight-26
    $historyAxisY=$spectrogramHeight-20
    $plotWidth=$CanvasWidth-60
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $gridWidth=($plotWidth/6.0).ToString('0.########',$culture)
    $gridHeight=($spectrumHeight/6.0).ToString('0.########',$culture)
    $rightX=[int]($CanvasWidth/2)
    $cameraHeight=[Math]::Max(2,$CanvasHeight-$plotHeight)
    if($VideoPanelHeight -gt 0){$cameraHeight=[Math]::Max(24,2*[int][Math]::Floor($VideoPanelHeight/2))}
    if($VideoPanelHeight -gt 0 -or $FrequencyPanelHeight -gt 0 -or $HistoryPanelHeight -gt 0){
        $CanvasHeight=0
        if($ShowVideo -and $Source -ne 'A'){$CanvasHeight+=$cameraHeight}
        if($ShowCharts){$CanvasHeight+=$plotHeight}
        if($CanvasHeight -eq 0){$CanvasHeight=160}
    }
    # All panels and sound share media timestamps and the same FFplay clock.
    if ($Source -eq 'A') {
        $items = @('-nostdin', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $AudioList)
        $graph = "[0:a:0]asetpts=PTS-STARTPTS[ext];[ext]asplit=2[singleRaw][singleHear];[singleHear]volume=${MixSensorGainDb}dB,alimiter=limit=0.95:level=0:latency=1[heard];[singleRaw]anullsink"
    }
    else {
        $items = @(Get-PlaybackMediaArguments $Source $VideoList $AudioList $OffsetMs -CameraLists $CameraLists -ForVisualization -MixCameraGainDb $MixCameraGainDb -MixSensorGainDb $MixSensorGainDb)
        $filterIndex = [Array]::IndexOf($items, '-filter_complex')
        $graph = $items[$filterIndex + 1].Replace('[aout]', '[heard]')
        $items = @($items[0..($filterIndex - 1)])
    }
    # With charts hidden, avoid spectral analysis entirely; keep the audio clock.
    if(-not $ShowCharts){
        if($ShowVideo -and $Source -ne 'A'){
            $graph += ";[heard]anull[aout];[0:v:0]setpts=PTS-STARTPTS,scale=${CanvasWidth}:${CanvasHeight}:force_original_aspect_ratio=decrease,pad=${CanvasWidth}:${CanvasHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25[vout]"
        }else{
            $graph += ";[heard]asplit=2[aout][blank];[blank]showwaves=s=${CanvasWidth}x${CanvasHeight}:mode=cline:colors=black:rate=25,format=yuv420p[vout]"
        }
        $graph=ConvertTo-PlaybackCameraGraph $graph $Source $CameraLists -CameraLayout $CameraLayout

        return $items + @('-filter_complex',$graph,'-map','[vout]','-map','[aout]',
            '-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-crf','23',
            '-pix_fmt','yuv420p','-c:a','pcm_s16le','-shortest','-f','matroska','pipe:1')
    }
    $fontPath = (Join-Path $env:WINDIR 'Fonts/arial.ttf').Replace('\', '/').Replace(':', '\:')
    if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'Fonts/arial.ttf'))) { throw (Get-UiText 'Arial was not found for chart labels.') }
    # Stereo analysis only; audible channels are unchanged. Mono inputs are duplicated for display.
    # Fixed dimensions and 25 fps bound memory and rendering cost on long recordings.
    if ($Source -eq 'T') {
        # Tap each source before audition gain/mixing. Sensor L/R and camera get distinct traces.
        $graph=$graph.Replace('[cam]volume=','[cam]asplit=2[camhear][camplot];[camhear]volume=')
        $graph=$graph.Replace('[ext]volume=','[ext]asplit=3[exthear][sensorwave][selectaudio];[exthear]volume=')
        $graph+=';[heard]anull[aout];[camplot]pan=mono|c0=0.5*c0+0.5*c1[cammono];[sensorwave][cammono]join=inputs=2:channel_layout=3.0:map=0.0-FL|0.1-FR|1.0-FC[waveaudio]'
    } else {
        $rawPadding='';if ($Source -ne 'A') { $rawPadding='apad,' }
        $graph=$graph.Replace('[singleRaw]anullsink',('[singleRaw]'+$rawPadding+'aresample=48000,aformat=channel_layouts=stereo,asplit=2[waveaudio][selectaudio]'))
        $graph+=';[heard]anull[aout]' 
    }
    $leftLabel = Get-UiText 'L - Ambient sound'
    $rightLabel = Get-UiText 'R - Spindle vibration'
    $spectrumLabel = Get-UiText 'Frequency spectrum'
    $spectrogramLabel = Get-UiText 'Spectrogram'
    if ($Source -eq 'C') { $leftLabel=Get-QualityText 'Camera audio' 'Áudio da câmara'; $rightLabel=$leftLabel }
    $legendLeft=Get-QualityText 'L - Ambient' 'L - Ambiente';$legendRight=Get-QualityText 'R - Vibration' 'R - Vibração'
    if ($Source -eq 'C') { $legendLeft=Get-QualityText 'Camera audio' 'Áudio da câmara';$legendRight='' }
    $legendRightX=48+[int]($plotWidth/3);$legendCameraX=48+[int](2*$plotWidth/3)
    $frequencyColors='0x50d8ff|0xff9840';$leftColor='0x50d8ff';$rightColor='0xff9840'
    if ($Source -eq 'T') { $frequencyColors+='|0x70e080' }
    if ($Source -eq 'C') { $frequencyColors='0x70e080|0x70e080';$leftColor='0x70e080';$rightColor='0x70e080' }
    # The upper panel replaces the old waveform: both stereo channels, same average.
    # Fixed analysis rate/FFT/range, no automatic gain or peak normalization.
    # Keep per-bin averaging, but move real channels away from y=0 using a
    # silent first channel. Crop back and combine colors without image trails.
    $spectrumChannels=2;if($Source -eq 'T'){$spectrumChannels=3}
    $spectrumFullHeight=($spectrumChannels+1)*$spectrumHeight
    $spectrumPan='pan='+($spectrumChannels+1)+'c|c0=0*c0'
    for($channel=0;$channel -lt $spectrumChannels;$channel++){$spectrumPan+='|c'+($channel+1)+'=c'+$channel}
    $graph += ";[waveaudio]volume=volume=$WaveformGain,${spectrumPan},showfreqs=s=${plotWidth}x${spectrumFullHeight}:mode=line:ascale=log:fscale=lin:win_size=8192:win_func=hann:overlap=0.75:rate=25:minamp=0.000001:averaging=8:colors=black|${frequencyColors}:cmode=separate,format=gbrp,split=$spectrumChannels"
    for($channel=0;$channel -lt $spectrumChannels;$channel++){$graph+='[freqslice'+$channel+']'}
    for($channel=0;$channel -lt $spectrumChannels;$channel++){
        $cropY=($channel+1)*$spectrumHeight
        $graph+=';[freqslice'+$channel+']crop='+$plotWidth+':'+$spectrumHeight+':0:'+$cropY+':exact=1[freqtrace'+$channel+']'
    }
    $graph+=';[freqtrace0][freqtrace1]blend=all_mode=or'
    if($spectrumChannels -eq 3){$graph+='[freqpair];[freqpair][freqtrace2]blend=all_mode=or'}
    $graph += ",format=yuv420p,drawgrid=w=${gridWidth}:h=${gridHeight}:t=1:c=white@0.2,pad=${CanvasWidth}:${frequencyHeight}:48:32:black,drawtext=fontfile='$fontPath':text='$spectrumLabel':x=48:y=3:fontsize=14:fontcolor=white,drawtext=fontfile='$fontPath':text='$legendLeft (x$WaveformGain)':x=48:y=18:fontsize=12:fontcolor=${leftColor},drawtext=fontfile='$fontPath':text='$legendRight':x=${legendRightX}:y=18:fontsize=12:fontcolor=${rightColor}[freqbase]"
    if ($Source -eq 'T') {
        $cameraLabel=Get-QualityText 'Camera audio' 'Áudio da câmara'
        $graph=$graph.Replace('[freqbase]',",drawtext=fontfile='$fontPath':text='$cameraLabel (x$WaveformGain)':x=${legendCameraX}:y=18:fontsize=12:fontcolor=0x70e080[freqbase]")
    }
    if ($RecordingTimer) {
        $blockLabel=Get-UiText 'Block'
        $blockSecondsText=$RecordingBlockSeconds.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
        # Media timestamps come from the continuous live audio stream, so the
        # duration does not reset when recording rolls over to another block.
        $elapsedText='%{pts\:hms}'
        # FFmpeg segment filenames start at 000000. Use that same numbering.
        $blockExpression='floor(t/' + $blockSecondsText + ')'
        if ($PlaybackBlockExpression) { $blockExpression=$PlaybackBlockExpression }
        $blockText='%{eif\:' + $blockExpression + '\:d\:6}' 
        $graph=$graph.Replace('[freqbase]',",drawtext=fontfile='$fontPath':text='$blockLabel $blockText | $elapsedText':x=w-tw-12:y=5:fontsize=14:fontcolor=white[freqbase]")
    }
    $axisFilters = @()
    foreach ($tick in 0..6) {
        $frequency = $tick * 4
        $x = 48 + [int]($tick * $plotWidth / 6)
        if ($tick -eq 6) { $x = $CanvasWidth-53 }
        $axisFilters += "drawtext=fontfile='$fontPath':text='$frequency kHz':x=${x}:y=${frequencyAxisY}:fontsize=12:fontcolor=white"

    }
    $dbDivisions=[Math]::Max(1,[Math]::Min(6,[int][Math]::Floor($spectrumHeight/18.0)))
    foreach($tick in 0..$dbDivisions){
        $db=[int][Math]::Round(-120.0*$tick/$dbDivisions)
        $y=32+[int][Math]::Round($spectrumHeight*$tick/[double]$dbDivisions)-6
        $axisFilters += "drawtext=fontfile='$fontPath':text='$db':x=3:y=${y}:fontsize=12:fontcolor=white"
    }
    $graph += ';[freqbase]' + ($axisFilters -join ',') + '[frequency]'
    $channelIndex = 1
    $channelLabel = $rightLabel
    if ($SpectrumChannel -eq 'L') { $channelIndex = 0; $channelLabel = $leftLabel }
    # New rows appear at the top; older rows move down. Frequencies increase to the right.
    $spectrogramFilter=Get-PlaybackSpectrogramFilter $plotWidth $historyHeight
    $graph += ";[selectaudio]pan=mono|c0=c$channelIndex,$spectrogramFilter,format=yuv420p,pad=${CanvasWidth}:${spectrogramHeight}:48:24:black,drawtext=fontfile='$fontPath':text='$spectrogramLabel - $channelLabel':x=48:y=3:fontsize=14:fontcolor=white,drawbox=x=48:y=24:w=${plotWidth}:h=1:color=yellow:t=fill[specbase]"
    $specAxisFilters = @()
    foreach ($tick in 0..6) {
        $frequency = $tick * 4
        $x = 48 + [int]($tick * $plotWidth / 6)
        if ($tick -eq 6) { $x = $CanvasWidth-53 }
        $specAxisFilters += "drawtext=fontfile='$fontPath':text='$frequency kHz':x=${x}:y=${historyAxisY}:fontsize=12:fontcolor=white"
    }
    $graph += ';[specbase]' + ($specAxisFilters -join ',') + '[spec]'
    $graph += ';[frequency][spec]vstack=inputs=2:shortest=1[plots]'

    if (-not $ShowVideo -or $Source -eq 'A') {
        if($ShowCharts){$graph += ';[plots]null[vout]'}
        else{$graph += ';[plots]drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill[vout]'}
    } elseif(-not $ShowCharts){
        $graph += ";[plots]nullsink;[0:v:0]setpts=PTS-STARTPTS,scale=${CanvasWidth}:${CanvasHeight}:force_original_aspect_ratio=decrease,pad=${CanvasWidth}:${CanvasHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25[vout]"
    } else {
        $graph += ";[0:v:0]setpts=PTS-STARTPTS,scale=${CanvasWidth}:${cameraHeight}:force_original_aspect_ratio=decrease,pad=${CanvasWidth}:${cameraHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25[camera];[camera][plots]vstack=inputs=2:shortest=1[vout]"
    }
    $graph=ConvertTo-PlaybackCameraGraph $graph $Source $CameraLists -CameraLayout $CameraLayout

    return $items + @('-filter_complex', $graph, '-map', '[vout]', '-map', '[aout]',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-crf', '23',
        '-pix_fmt', 'yuv420p', '-c:a', 'pcm_s16le', '-shortest', '-f', 'matroska', 'pipe:1')
}
# Calculate player window arguments for video and/or charts.
function Get-PlaybackWindowArguments {
    param([bool]$WithVideo = $true, [bool]$WithGraphs = $true)
    $panelHeight = 416
    if ($WithVideo) { $panelHeight = 956 }
    if (-not $WithGraphs) { $panelHeight = 540 }
    # Both layouts use the full video layout to determine their shared width.
    $widthReferenceHeight = 956
    if (-not $WithGraphs) { $widthReferenceHeight = 540 }
    $width = 720
    $height = [int]($width * $panelHeight / 960)
    $position = @()
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
        $width = [int][Math]::Floor([Math]::Min(960, [Math]::Min($area.Width * 0.85, $area.Height * 0.80 * 960 / $widthReferenceHeight)))
        $height = [int][Math]::Floor($width * $panelHeight / 960)
        $position = @('-left', [string]($area.Left + [int](($area.Width - $width)/2)), '-top', [string]($area.Top + [int](($area.Height - $height)/2)))
    } catch { Write-Warning 'Could not measure the screen; using a 720 pixel window.' }
    return @('-x', [string]$width, '-y', [string]$height, '-window_title', (Get-UiText 'Machining Monitor - Playback')) + $position
}
# Locate a required playback executable using the portable path resolver.
function Find-PlaybackExecutable {
    param([string]$Name)
    # Support the simple folder layout and common nested/portable extractions.
    $parent=Split-Path $PSScriptRoot -Parent
    $directories=@($PSScriptRoot,(Join-Path $PSScriptRoot 'bin'),(Join-Path $parent 'bin'))
    if ($Name -eq 'mpv.exe') {
        $directories+=@((Join-Path $PSScriptRoot 'MA/bin'),(Join-Path $PSScriptRoot 'MA'),
            (Join-Path $parent 'MA/bin'),(Join-Path $PSScriptRoot 'mpv'))
    }
    foreach ($directory in @($directories | Select-Object -Unique)) {
        $local = Join-Path $directory $Name
        if (Test-Path -LiteralPath $local -PathType Leaf) { return (Resolve-Path -LiteralPath $local).Path }
    }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        if ($Name -eq 'mpv.exe') {
            $instruction=Get-UiText 'mpv.exe is missing. Copy mpv.exe from the update ZIP into the same folder as Playback_Blocks.ps1. Updating only the PowerShell scripts is not enough.'
            if ($script:UiLanguage -eq 'pt') { $instruction='Falta o mpv.exe. Copie o mpv.exe do ZIP de atualização para a mesma pasta de Playback_Blocks.ps1. Atualizar apenas os scripts PowerShell não é suficiente.' }
            throw ($instruction + [Environment]::NewLine + ($directories -join [Environment]::NewLine))
        }
        throw (Get-UiText "$Name not found beside the script, in the bin folder or on PATH.")
    }
    return $command.Source
}

# Quote argument values for the external process command line.
function Join-PlaybackArguments {
    param([string[]]$Items)
    $quoted = foreach ($item in $Items) {
        '"' + [regex]::Replace([regex]::Replace($item, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }
    return ($quoted -join ' ')
}

# Find and order the recording's audio or video segment files.
function Get-RecordingFiles {
    param([string]$Folder, [string]$Kind, [string]$Extension)
    $pattern = '^' + $Kind + '_[0-9]+\.' + $Extension + '$'
    $files = @(Get-ChildItem -LiteralPath $Folder -File |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object @{ Expression = { [long]([regex]::Match($_.BaseName, '[0-9]+$').Value) } })
    if ($files.Count -gt 0) { return $files }
    $legacy = Join-Path $Folder ($Kind + '.' + $Extension)
    if (Test-Path -LiteralPath $legacy -PathType Leaf) { return Get-Item -LiteralPath $legacy }
    return @()
}

# Write an ffconcat playlist from segment files and recorded timing information.
function Write-PlaybackList {
    param([object[]]$Files, [string]$CsvPath, [string]$ListPath)
    $timings = @{}
    if (Test-Path -LiteralPath $CsvPath -PathType Leaf) {
        try {
            $entries = @(Import-Csv -LiteralPath $CsvPath -Header File, Start, End)
            for ($index = 0; $index -lt $entries.Count; $index++) {
                $row = $entries[$index]
                $start = [double]::Parse($row.Start, [Globalization.CultureInfo]::InvariantCulture)
                $end = [double]::Parse($row.End, [Globalization.CultureInfo]::InvariantCulture)
                # B-frames can make End precede the next segment's actual boundary.
                # Use successive starts to preserve the continuous recording timeline.
                if ($index + 1 -lt $entries.Count) {
                    $end = [double]::Parse($entries[$index + 1].Start, [Globalization.CultureInfo]::InvariantCulture)
                }
                if ($end -gt $start) { $timings[[IO.Path]::GetFileName($row.File)] = $end - $start }
            }
        }
        catch { Write-Warning 'Lista de tempos incompleta; serão usadas as durações dos ficheiros.' }
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('ffconcat version 1.0')
    foreach ($file in $Files) {
        # Concat escaping: close quote, escape apostrophe, reopen quote.
        $escaped = $file.FullName.Replace('\', '/').Replace("'", "'\''")
        $lines.Add("file '$escaped'")
        $actual=Get-RecordedFileSeconds $file ($file.Extension -ne '.wav')
        if($null -ne $actual -and $actual -gt 0){$timings[$file.Name]=$actual}
        if (-not $timings.ContainsKey($file.Name)) {
            # Concat input seeking requires a duration for every segment,
            # including legacy/extracted recordings without a segment CSV.
            $timings[$file.Name]=Get-ContinuousDuration @($file) ($CsvPath+'.probe') (Find-PlaybackExecutable 'ffmpeg.exe')
        }
        if ($timings.ContainsKey($file.Name)) {
            $duration = $timings[$file.Name].ToString('0.########', [Globalization.CultureInfo]::InvariantCulture)
            $lines.Add("duration $duration")
        }
    }
    [IO.File]::WriteAllLines($ListPath, $lines.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

# Launch a media process with the required redirected streams and optional playback clock.
function Start-PlaybackProcess {
    param([string]$Executable, [string[]]$Items, [switch]$PipeInput, [switch]$PipeOutput, [switch]$QualityClock)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = Join-PlaybackArguments $Items
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $PipeInput.IsPresent
    $info.RedirectStandardOutput = $PipeOutput.IsPresent
    $info.RedirectStandardError = $QualityClock.IsPresent
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    # .NET Framework creates an AutoFlush StreamWriter for stdin at Start().
    # A BOM-enabled console encoding inserts its preamble before binary media.
    $previousInputEncoding=$null
    try {
        if($PipeInput){
            $binaryEncoding=New-Object Text.UTF8Encoding($false)
            if($info.PSObject.Properties['StandardInputEncoding']){$info.StandardInputEncoding=$binaryEncoding}
            else{$previousInputEncoding=[Console]::InputEncoding;[Console]::InputEncoding=$binaryEncoding}
        }
        if (-not $process.Start()) { $process.Dispose(); throw (Get-UiText "Não foi possível iniciar $Executable.") }
    } finally {if($null -ne $previousInputEncoding){[Console]::InputEncoding=$previousInputEncoding}}
    return $process
}

# Terminate a remaining playback process with a bounded wait.
function Stop-PlaybackProcess {
    param($Process)
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) {
        $Process.Kill()
        if (-not $Process.WaitForExit(2000)) { Write-Warning 'O processo de reprodução demorou a terminar.' }
    }
}

# Keep the interface responsive while producer output is copied to the player; stop leftovers on exit.
function Wait-PlaybackPipeline {
    param($Player, $Producer, $CopyTask)
    while (-not $CopyTask.IsCompleted -and -not $Player.HasExited) {
        if ($null -ne $qualityPanel) { Update-QualityPanel $qualityPanel }
        Start-Sleep -Milliseconds 100
    }
    # Escape can close ffplay while FFmpeg still writes into the pipe.
    # Terminate the producer before waiting for it or for the copy operation.
    if ($Player.HasExited) {
        Stop-PlaybackProcess $Producer
        return
    }
    try { [void]$CopyTask.GetAwaiter().GetResult() }
    catch {
        if ($Player.WaitForExit(2000)) {
            Stop-PlaybackProcess $Producer
            return
        }
        throw
    }
    try { $Player.StandardInput.Close() }
    catch { if (-not $Player.HasExited) { throw } }
    while (-not $Player.HasExited) {
        if ($null -ne $qualityPanel) { Update-QualityPanel $qualityPanel }
        Start-Sleep -Milliseconds 50
    }
    if (-not $Producer.WaitForExit(2000)) {
        Stop-PlaybackProcess $Producer
        return
    }
    if ($Producer.ExitCode -ne 0) { throw (Get-UiText 'FFmpeg terminou com erro ao preparar a reprodução.') }
}

# Import-only mode returns before media discovery or process startup; recording reuses the function definitions this way.
# Below this guard the script owns a playback session. The finally block closes processes,
# stream-copy work, UI resources and the temporary playlists even after cancellation/errors.
if ($ApenasFuncoes) { return }
$ownsBroadcastApplication=$null -eq (Get-ApplicationBroadcast)
if($ownsBroadcastApplication){Start-ApplicationBroadcast}
$tempDirectory = $null
$player = $null
$producer = $null
$copyTask = $null
$qualityPanel = $null
$session = $null
# Run the guarded application workflow. Catch reports failures; finally releases the resources allocated by this workflow.
try {
    $folder = (Resolve-Path -LiteralPath $RecordingPath).Path
    # Validate existing annotations before starting media processes.
    $null = @(Read-QualityAnnotations (Join-Path $folder 'events.json'))
    $videos = @(Get-RecordingFiles $folder 'video' 'mp4')
    $audios = @(Get-RecordingFiles $folder 'audio' 'wav')
    if ($videos.Count -eq 0 -and $audios.Count -eq 0) { throw (Get-UiText 'Não foram encontrados ficheiros de áudio ou vídeo.') }
    $ffplay = Find-PlaybackExecutable 'mpv.exe'

    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('machining-playback-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempDirectory)
    $cameraTracks=@(Get-PlaybackCameraTracks $folder $tempDirectory)
    $cameraLists=@($cameraTracks | Select-Object -Skip 1 | ForEach-Object {$_.List})
    $videoList = Join-Path $tempDirectory 'video.ffconcat'
    $audioList = Join-Path $tempDirectory 'audio.ffconcat'
    if ($videos.Count) { Write-PlaybackList $videos (Join-Path $folder 'video_segments.csv') $videoList }
    if ($audios.Count) { Write-PlaybackList $audios (Join-Path $folder 'audio_segments.csv') $audioList }
    $configPath = Join-Path $PSScriptRoot 'config.json'
    $offsetPath = Join-Path $folder 'playback.json'
    $mix=Read-MixedAudioGains $offsetPath
    $source = 'A'
    $offsetMs = 0
    if ($videos.Count) {
        $source = Get-DefaultPlaybackAudioSource $configPath ($audios.Count -gt 0)
        $offsetMs = Get-DefaultOffset $offsetPath $configPath
    }
    $waveformGain = 1
    $spectrumChannel = 'R'
    if (-not $SemGraficos) {
        $spectrumChannel = Get-DefaultSpectrumChannel $configPath
        $waveformGain = Get-DefaultWaveformGain $configPath
    }
    $videoWindowArguments = @(Get-PlaybackWindowArguments -WithVideo ($source -ne 'A') -WithGraphs (-not $SemGraficos))
    Write-Host 'Reprodução contínua dos blocos. Escape fecha o leitor.'
    if ($SemGraficos -and -not $cameraLists.Count -and ($source -eq 'A' -or ($source -eq 'C' -and $offsetMs -eq 0))) {
        $list = $audioList
        if ($source -eq 'C') { $list = $videoList }
        $items = @('-loglevel', 'info', '-autoexit', '-f', 'concat', '-safe', '0', '-i', $list)
        if ($source -eq 'A') { $items += @('-x', '320', '-y', '180') }
        else { $items += $videoWindowArguments }
        $items += '-stats'
        $context=@{Direct=$true; PlayerExe=$ffplay; PlayerItems=$items; ProducerExe=(Find-PlaybackExecutable 'ffmpeg.exe')}
    }
    else {
        $ffmpeg = Find-PlaybackExecutable 'ffmpeg.exe'
        if ($SemGraficos) {
            $items = @(Get-PlaybackMediaArguments $source $videoList $audioList $offsetMs -CameraLists $cameraLists -MixCameraGainDb $mix.Camera -MixSensorGainDb $mix.Sensor)
        } else {
            Write-Host 'Spectrum: L blue; R orange, fixed axes and averaging. Spectrogram: low to high frequencies left to right; history moves down. Space: pause; Escape: close.'
            $blockFiles=$videos; $blockCsv=Join-Path $folder 'video_segments.csv'
            if ($source -eq 'A') { $blockFiles=$audios; $blockCsv=Join-Path $folder 'audio_segments.csv' }
            $blockExpression=Get-PlaybackBlockExpression $blockFiles $blockCsv $folder
            $items = @(Get-VisualizationArguments $source $videoList $audioList $offsetMs $spectrumChannel $waveformGain -RecordingTimer -PlaybackBlockExpression $blockExpression -CameraLists $cameraLists -MixCameraGainDb $mix.Camera -MixSensorGainDb $mix.Sensor)
        }
        $playerItems = @('-loglevel', 'info', '-autoexit', '-f', 'matroska', '-i', 'pipe:0') + $videoWindowArguments
        $playerItems += '-stats'
        $context=@{Direct=$false; PlayerExe=$ffplay; PlayerItems=$playerItems; ProducerExe=$ffmpeg; ProducerItems=$items}
    }
    $durationFiles=$videos; $durationCsv=Join-Path $folder 'video_segments.csv'
    if ($source -eq 'A') { $durationFiles=$audios; $durationCsv=Join-Path $folder 'audio_segments.csv' }
    $duration=Get-ContinuousDuration $durationFiles $durationCsv (Find-PlaybackExecutable 'ffmpeg.exe')
    $qualityPanel=New-QualityPanel $null $folder -DurationSeconds $duration -DeferShow
    Set-VisualizationCameraCount $qualityPanel.Tag.Viewport $cameraTracks.Count
    # Always use a producer so original/filtered comparison also works without plots.
    if ($context.Direct) {
        $list=$audioList; if ($source -eq 'C') { $list=$videoList }
        $directItems=@('-nostdin','-loglevel','error','-f','concat','-safe','0','-i',$list)
        $directItems+=@('-filter_complex','[0:a:0]anull[aout]','-map','0:v:0?','-map','[aout]','-c:v','libx264','-preset','ultrafast','-c:a','pcm_s16le','-f','matroska','pipe:1')
        if ($source -eq 'A') { $directItems=@(Get-ExternalPlaybackArguments $audioList $mix.Sensor) }
        elseif ($source -eq 'C') { $directItems=@(Get-PlaybackMediaArguments C $videoList $audioList 0 -MixCameraGainDb $mix.Camera) }
        $context.Direct=$false; $context.ProducerItems=$directItems
    }
    # Retain the original producer arguments so switching filters starts from a clean graph
    # instead of repeatedly stacking a new filter chain on the previously modified arguments.
    $context.UnfilteredItems=@($context.ProducerItems)
    $context.Vibration=New-VibrationSettings $folder
    $context.RecordingFolder=$folder
    $context.ProducerItems=@(Set-VibrationArguments $context.UnfilteredItems $context.Vibration)
    $context.SensorAvailable=$source -ne 'C'
    $qualityPanel.Tag.Context=$context
    Add-VibrationControls $qualityPanel
    Add-SplitControls $qualityPanel $folder $videoList $audioList ($videos.Count -gt 0) ($audios.Count -gt 0) $offsetMs
    $qualityPanel.Tag.Split.CameraTracks=$cameraTracks
    $context.AdaptivePlots=(-not $SemGraficos) -or $source -ne 'A'; $context.PlotCamera=$source -ne 'A'
    if ($context.AdaptivePlots) {
        $context.Visualization=@{Source=$source;VideoList=$videoList;AudioList=$audioList;OffsetMs=$offsetMs;SpectrumChannel=$spectrumChannel;WaveformGain=$waveformGain;RecordingTimer=$true;PlaybackBlockExpression=$blockExpression;CameraLists=$cameraLists;MixCameraGainDb=$mix.Camera;MixSensorGainDb=$mix.Sensor}
    }
    $context.PlaybackSettings=@{Source=$source;OffsetMs=$offsetMs;SpectrumChannel=$spectrumChannel;WaveformGain=$waveformGain;ConfigPath=$configPath;OffsetPath=$offsetPath;HasVideo=($videos.Count -gt 0);HasAudio=($audios.Count -gt 0);VideoList=$videoList;AudioList=$audioList;CameraLists=$cameraLists;MixCameraGainDb=$mix.Camera;MixSensorGainDb=$mix.Sensor}
    Add-PlaybackSettingsControls $qualityPanel
    Add-RecordingMetadataControls $qualityPanel
    Add-PlaybackViewChoices $qualityPanel
    if($SemGraficos -and $context.AdaptivePlots){
        $qualityPanel.Tag.ShowCharts.Checked=$false;$qualityPanel.Tag.ShowCharts.Enabled=$false
        Update-PlaybackViewChoices $qualityPanel.Tag;Fit-VisualizationToWindow $qualityPanel.Tag.Viewport
    }
    Initialize-PlaybackStartupLayout $qualityPanel
    $qualityPanel.Show()
    if($context.AdaptivePlots){Set-NativePlotRendering $context $qualityPanel.Tag.VideoHost.ClientSize}
    $context.Engine='mpv'; $context.WindowHandle=$qualityPanel.Tag.VideoHost.Handle; $context.Duration=$duration
    $qualityPanel.Tag.Context=$context
    $session=Start-QualityPlayback $context
    Attach-MpvPlayback $qualityPanel.Tag $session $true
    if ($null -ne $TransitionNotice) {
        $qualityPanel.Tag.TransitionNotice=$TransitionNotice
        $qualityPanel.Tag.OpeningNoticePending=$true
        $qualityPanel.Tag.ReturnNoticeText=Get-QualityText 'Please wait, loading recordings...' 'Aguarde, a carregar a lista de gravações…'
        $qualityPanel.Add_FormClosing({
            param($sender,$eventArgs)
            if (-not $eventArgs.Cancel) { $sender.Tag.TransitionNotice.Show($sender.Tag.ReturnNoticeText) }
        })
    }
    Wait-QualityPlayback $qualityPanel
}
catch [OperationCanceledException] { Write-Host 'Reprodução cancelada.' }
catch {
    if ($null -ne $TransitionNotice) { $TransitionNotice.Hide() }
    if ($ShowPlaybackErrors) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Machining Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
    } else { Write-Host ('Erro: ' + $_.Exception.Message) -ForegroundColor Red }
    exit 1
}
finally {
    if ($null -ne $qualityPanel -and $null -ne $qualityPanel.Tag.Context) { Stop-PlaybackBroadcast $qualityPanel.Tag }
    if($ownsBroadcastApplication){Stop-ApplicationBroadcast}
    if ($null -ne $session) { Stop-QualityPlayback $session }
    if ($null -ne $qualityPanel) { $qualityPanel.Close(); $qualityPanel.Dispose() }
    foreach ($process in @($producer, $player)) {
        if ($null -ne $process) {
            Stop-PlaybackProcess $process
        }
    }
    if ($null -ne $producer) { $producer.StandardOutput.Close() }
    if ($null -ne $player -and $player.StartInfo.RedirectStandardInput) {
        try { $player.StandardInput.Close() } catch {}
    }
    if ($null -ne $copyTask) {
        try { [void]$copyTask.Wait(2000) } catch {}
    }
    foreach ($process in @($producer, $player)) { if ($null -ne $process) { $process.Dispose() } }
    if ($null -ne $tempDirectory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $tempDirectory -Filter '*.ffconcat' -File)) { [IO.File]::Delete($file.FullName) }
        [IO.Directory]::Delete($tempDirectory)
    }
}
