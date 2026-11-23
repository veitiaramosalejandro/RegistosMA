<#
Playback_Timeline.ps1 - version 197.
Playback lifecycle and timeline seeking. The UI queues changes; the update loop restarts or adjusts the media session and keeps controls synchronized.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Determine the continuous recording duration from segment timing or media inspection.
function Get-ContinuousDuration {
    param([object[]]$Files, [string]$CsvPath, [string]$FFmpeg)
    $actual=Get-RecordedFilesSeconds $Files ($Files.Count -gt 0 -and $Files[0].Extension -ne '.wav')
    if($null -ne $actual){return $actual}
    if (Test-Path -LiteralPath $CsvPath) {
        try {
            $rows=@(Import-Csv -LiteralPath $CsvPath -Header File,Start,End)
            $names=@($Files | ForEach-Object { $_.Name })
            if ($rows.Count -eq $Files.Count -and @($rows | Where-Object { [IO.Path]::GetFileName($_.File) -notin $names }).Count -eq 0) {
                $first=[double]::Parse($rows[0].Start,[Globalization.CultureInfo]::InvariantCulture)
                $last=[double]::Parse($rows[-1].End,[Globalization.CultureInfo]::InvariantCulture)
                if ($last -gt $first) { return $last-$first }
            }
        } catch { }
    }
    $total=0.0
    foreach ($file in $Files) {
        $probe=$null
        try {
            $probe=Start-PlaybackProcess $FFmpeg @('-hide_banner','-i',$file.FullName) -QualityClock
            $description=$probe.StandardError.ReadToEnd(); $probe.WaitForExit()
            $match=[regex]::Match($description,'Duration:\s*(\d+):(\d+):(\d+\.\d+)')
            if (-not $match.Success) { throw (Get-QualityText 'Unable to determine the recording duration.' 'Não foi possível determinar a duração da gravação.') }
            $total += [int]$match.Groups[1].Value*3600+[int]$match.Groups[2].Value*60+[double]::Parse($match.Groups[3].Value,[Globalization.CultureInfo]::InvariantCulture)
        } finally { if ($null -ne $probe) { $probe.Dispose() } }
    }
    return $total
}
# Trim complete earlier blocks from a standard generated concat list. Keep the current
# block and all following blocks, so playback can continue normally after the seek.
function Get-LocalSeekInput {
    param([string]$Path,[double]$Seconds)
    $unchanged=@{Path=$Path;Seconds=$Seconds;Skipped=0}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $unchanged }
    $lines=@([IO.File]::ReadAllLines($Path,[Text.Encoding]::UTF8))
    # Do not rewrite custom playlists or advanced concat directives.
    if (@($lines | Where-Object {$_ -notmatch '^(?:\s*$|ffconcat version 1\.0$|file\s|duration\s)'}).Count) { return $unchanged }
    $starts=New-Object 'System.Collections.Generic.List[int]'
    $durations=New-Object 'System.Collections.Generic.List[double]'
    for ($i=0;$i -lt $lines.Count;$i++) {
        if ($lines[$i] -match '^file\s') { $starts.Add($i) }
        if ($lines[$i] -match '^duration\s+([0-9.]+)\s*$') {
            $d=0.0
            if (-not [double]::TryParse($Matches[1],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d) -or $d -le 0) { return $unchanged }
            $durations.Add($d)
        }
    }
    if ($starts.Count -lt 2 -or $starts.Count -ne $durations.Count) { return $unchanged }
    $index=0;$prefix=0.0
    while ($index -lt $durations.Count-1 -and $Seconds -ge $prefix+$durations[$index]) {
        $prefix+=$durations[$index];$index++
    }
    if ($index -eq 0 -or $Seconds -ge $prefix+$durations[$index]) { return $unchanged }
    $suffix=Join-Path (Split-Path $Path -Parent) ('seek-'+[guid]::NewGuid().ToString('N')+'.ffconcat')
    # Keep the same directory so relative filenames still resolve correctly. The existing
    # playback-session cleanup already removes all temporary .ffconcat files.
    try { [IO.File]::WriteAllLines($suffix,(@('ffconcat version 1.0')+@($lines[$starts[$index]..($lines.Count-1)])),(New-Object Text.UTF8Encoding($false))) }
    catch { return $unchanged }
    return @{Path=$suffix;Seconds=($Seconds-$prefix);Skipped=$index}
}
# Keep one small, non-sensitive diagnostic beside the installed scripts. Failure to write
# a diagnostic must never interrupt playback (for example in a read-only installation).
function Write-SeekPlanDiagnostic {
    param([double]$Target,[double]$Start,[string[]]$Inputs,[string]$Reason)
    try {
        $lines=@('Machining Monitor 180 - latest seek',('Time: '+[DateTime]::Now.ToString('s')),('TargetSeconds: '+$Target.ToString('R',[Globalization.CultureInfo]::InvariantCulture)),('InputStartSeconds: '+$Start.ToString('R',[Globalization.CultureInfo]::InvariantCulture)),('Mode: '+$(if($Start -gt 0){'block-local fast seek'}else{'decode from start'})),('Fallback: '+$Reason))
        $lines+=@($Inputs)
        [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'Playback_Seek_Diagnostic.txt'),$lines,(New-Object Text.UTF8Encoding($true)))
    } catch { }
}
# Adapt producer arguments to restart decoding at a requested timeline position.
function Get-SeekProducerArguments {
    param([string[]]$Items, [double]$Seconds, [switch]$FastSeek)
    $result=@($Items)
    $filterIndex=[Array]::IndexOf($result,'-filter_complex')
    $mixedFastSeek=$false
    if ($filterIndex -ge 0 -and $result[$filterIndex+1] -match '\bamix=') {
        # Resetting camera timestamps after a seek can shift its alignment with sensor audio.
        # Keep the input time axis and let the resampler fill/trim the initial camera gap.
        $camera='[0:a:0]asetpts=PTS-STARTPTS,aresample=48000'
        if ($result[$filterIndex+1].Contains($camera)) {
            # Fill timestamp discontinuities above 10 ms between camera blocks without
            # stretching the samples or reacting to sub-millisecond timestamp rounding.
            $result[$filterIndex+1]=$result[$filterIndex+1].Replace($camera,'[0:a:0]aresample=48000:async=1:min_hard_comp=0.01:first_pts=0')
            $mixedFastSeek=$true
        }
    }
    if ($Seconds -le 0) { return $result }
    # Keep enough preroll for the full spectrum history and filter settling. Include
    # the audio offset so its delay/trim has completed before the target.
    $inputStart=0.0;$seekReason='';$seekInputs=@()
    if ($FastSeek) {
        $offset=0.0;$preroll=5.0
        $filterIndex=[Array]::IndexOf($result,'-filter_complex')
        if ($filterIndex -ge 0) {
            $graph=$result[$filterIndex+1]
            # A taller history panel contains more rows at the same time per
            # row. Decode enough preceding audio before presenting the target
            # frame; a fixed five-second preroll leaves taller panels blank.
            foreach($spectrum in [regex]::Matches($graph,'showspectrum=([^;\[]+)')){
                $options=$spectrum.Groups[1].Value
                $size=[regex]::Match($options,'(?:^|:)s=(\d+)x(\d+)')
                if(-not $size.Success -or $options -notmatch '(?:^|:)orientation=horizontal(?:$|:)'){continue}
                $overlapMatch=[regex]::Match($options,'(?:^|:)overlap=([0-9.]+)')
                $overlap=0.0
                if($overlapMatch.Success){$overlap=[double]::Parse($overlapMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)}
                # The shared visualization normalizes analysis audio to 48 kHz.
                $fftSize=2*[int]$size.Groups[1].Value
                $hop=[Math]::Max(1.0,[Math]::Floor($fftSize*(1.0-$overlap)+0.000000001))
                $historySeconds=[int]$size.Groups[2].Value*$hop/48000.0
                $preroll=[Math]::Max($preroll,$historySeconds+$fftSize/48000.0+0.5)
            }
            foreach ($match in [regex]::Matches($graph,'adelay=(\d+)')) { $offset=[Math]::Max($offset,[double]$match.Groups[1].Value/1000) }
            foreach ($match in [regex]::Matches($graph,'atrim=start=([0-9.]+)')) { $offset=[Math]::Max($offset,[double]::Parse($match.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)) }
        }
        # The recognized mixed graph preserves camera timestamps, so it can also
        # start near the target. Unknown mixed graphs retain the compatible fallback.
        if ($filterIndex -lt 0 -or $graph -notmatch '\bamix=' -or $mixedFastSeek) {
            $inputStart=[Math]::Max(0.0,$Seconds-$preroll-$offset)
        }
        if ($inputStart -le 0 -and $graph -match '\bamix=' -and -not $mixedFastSeek) { $seekReason='unrecognized mixed graph' }
        # A short audio track can already have ended while video continues.
        # In that case keep output seeking so apad can supply the silent tail.
        for ($i=0; $inputStart -gt 0 -and $i -lt $result.Count-1; $i++) {
            if ($result[$i] -ne '-i' -or -not (Test-Path -LiteralPath $result[$i+1] -PathType Leaf)) { continue }
            if ($i -lt 4 -or $result[$i-4] -ne '-f' -or $result[$i-3] -ne 'concat') { continue }
            $lines=@(Get-Content -LiteralPath $result[$i+1] -Encoding UTF8)
            $files=@($lines | Where-Object { $_ -match '^file\s' })
            if (-not $files.Count) { continue }
            $durations=@($lines | Where-Object { $_ -match '^duration\s' })
            if ($durations.Count -ne $files.Count) { $inputStart=0.0; $seekReason='playlist lacks durations'; break }
            $total=0.0
            foreach ($line in $durations) { $total += [double]::Parse(($line -replace '^duration\s+',''),[Globalization.CultureInfo]::InvariantCulture) }
            if ($inputStart -ge $total) { $inputStart=0.0; $seekReason='target after end of one input' }
        }
        if ($inputStart -gt 0) {
            $startText=$inputStart.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
            $shifted=New-Object 'System.Collections.Generic.List[string]'
            for ($i=0;$i -lt $result.Count;$i++) {
                $item=$result[$i]
                if ($item -eq '-i' -and $i -lt $result.Count-1) {
                    $local=@{Path=$result[$i+1];Seconds=$inputStart;Skipped=0}
                    if ($i -ge 4 -and $result[$i-4] -eq '-f' -and $result[$i-3] -eq 'concat') {
                        $local=Get-LocalSeekInput $result[$i+1] $inputStart
                    }
                    $seekInputs+=('Input '+$seekInputs.Count+': skipped blocks='+$local.Skipped+'; local seek seconds='+$local.Seconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture))
                    $shifted.Add('-seek_timestamp');$shifted.Add('1');$shifted.Add('-ss')
                    $shifted.Add($local.Seconds.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture))
                    $shifted.Add('-i');$shifted.Add($local.Path);$i++
                } else { $shifted.Add($item) }
            }
            $result=$shifted.ToArray()
            $filterIndex=[Array]::IndexOf($result,'-filter_complex')
            if ($filterIndex -ge 0) {
                # Only the recording clock/block overlays use absolute media
                # time; the output and mpv clock remain relative to the seek.
                $graph=$result[$filterIndex+1]
                $graph=[regex]::Replace($graph,'(\[\d+:v:0\])setpts=PTS-STARTPTS','$1setpts=PTS')
                $graph=$graph.Replace('%{pts\:hms}',('%{pts\:hms\:'+$startText+'}'))
                $graph=$graph.Replace('gte(t,',('gte(t+'+$startText+','))
                $graph=$graph.Replace('floor(t/',('floor((t+'+$startText+')/'))
                $result[$filterIndex+1]=$graph
            }
        }
    }
    for ($i=0; $i -lt $result.Count-1; $i++) {
        if ($result[$i] -eq '-c:v' -and $result[$i+1] -eq 'copy') { $result[$i+1]='libx264' }
    }
    Write-SeekPlanDiagnostic $Seconds $inputStart $seekInputs $seekReason
    $time=($Seconds-$inputStart).ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
    return @($result[0..($result.Count-2)]) + @('-ss',$time,$result[-1])
}
# Start a playback session using the selected producer/player configuration.
function Start-QualityPlayback {
    param($Context,[double]$Seconds=0,[bool]$Paused=$true)
    if ($Context.Engine -eq 'mpv') { return Start-MpvPlayback $Context $Seconds $Paused }
    $session=@{Player=$null; Producer=$null; Copy=$null; InputClosed=$false; BaseSeconds=0.0}
    try {
        $arguments=@($Context.PlayerItems)
        $direct=$Context.Direct -and $Seconds -le 0
        $producerItems=@($Context.ProducerItems)
        if ($Context.Direct -and -not $direct) {
            # FFplay input seeking lands on an earlier keyframe. Decode/trim
            # through FFmpeg when seeking so both audio and video start exactly.
            $index=[Array]::IndexOf($arguments,'-i')
            $producerItems=@('-nostdin','-loglevel','error')
            if ($arguments -contains 'concat') { $producerItems += @('-f','concat','-safe','0') }
            $producerItems += @('-i',$arguments[$index+1],'-map','0:v:0?','-map','0:a:0?',
                '-c:v','libx264','-preset','ultrafast','-c:a','pcm_s16le','-f','matroska','pipe:1')
            $arguments=@('-loglevel','info','-stats','-autoexit','-f','matroska','-i','pipe:0')
        }
        $arguments=@($arguments | Where-Object { $_ -ne '-autoexit' })
        $session.Player=Start-PlaybackProcess $Context.PlayerExe $arguments -PipeInput:(!$direct) -QualityClock
        if (-not $direct) {
            $session.BaseSeconds=$Seconds
            $items=@(Get-SeekProducerArguments $producerItems $Seconds -FastSeek)
            $session.Producer=Start-PlaybackProcess $Context.ProducerExe $items -PipeOutput
            $session.Copy=$session.Producer.StandardOutput.BaseStream.CopyToAsync($session.Player.StandardInput.BaseStream)
        }
        return $session
    } catch { Stop-QualityPlayback $session; throw }
}
# Stop the session's media processes and release its clock and stream resources.
function Save-PlaybackProducerDiagnostic($Session){
    if(-not $Session.ProducerErrors -or -not $Session.ProducerLogPath -or $Session.ProducerDiagnosticSaved){return}
    try{
        if($Session.ProducerErrors.Wait(1000)){
            $errors=$Session.ProducerErrors.GetAwaiter().GetResult()
            [IO.File]::AppendAllText($Session.ProducerLogPath,$errors,(New-Object Text.UTF8Encoding($true)))
            $Session.ProducerDiagnosticSaved=$true
        }
    }catch{}
}
function Get-PlaybackPipelineFailure($Session,[string]$Fallback){
    $message=$Fallback
    if($Session.Copy -and $Session.Copy.IsFaulted -and $Session.Producer -and -not $Session.Producer.HasExited){[void]$Session.Producer.WaitForExit(150)}
    if($Session.Producer -and $Session.Producer.HasExited -and $Session.Producer.ExitCode -ne 0){
        $message='O FFmpeg falhou ao preparar a gravação (código '+$Session.Producer.ExitCode+').'
        Save-PlaybackProducerDiagnostic $Session
        if($Session.ProducerErrors -and $Session.ProducerErrors.IsCompleted -and -not $Session.ProducerErrors.IsFaulted){
            $detail=$Session.ProducerErrors.GetAwaiter().GetResult().Trim()
            if($detail){$message+=[Environment]::NewLine+$detail.Substring([Math]::Max(0,$detail.Length-6000))}
        }
    }elseif($Session.Copy -and $Session.Copy.IsFaulted){$message+=[Environment]::NewLine+$Session.Copy.Exception.GetBaseException().Message}
    if($Session.ProducerLogPath){$message+=[Environment]::NewLine+'Diagnóstico FFmpeg: '+$Session.ProducerLogPath}
    return $message
}
function Stop-QualityPlayback {
    param($Session)
    if ($null -eq $Session) { return }
    if ($null -ne $Session.BroadcastCapture) { $Session.BroadcastCapture.SetProcess(0) }
    if ($null -ne $Session.Controller) { $Session.Controller.Dispose(); $Session.Controller=$null }
    foreach ($process in @($Session.Player,$Session.Producer)) {
        if ($null -ne $process) { Stop-PlaybackProcess $process }
    }
    Save-PlaybackProducerDiagnostic $Session
    if ($null -ne $Session.Copy) { try { [void]$Session.Copy.Wait(2000) } catch {} }
    foreach ($process in @($Session.Player,$Session.Producer)) {
        if ($null -ne $process) { $process.Dispose() }
    }
    $Session.Player=$null; $Session.Producer=$null; $Session.Copy=$null
}
# Queue a requested timeline position for the playback loop to apply.
function Request-QualitySeek {
    param($State, [double]$Seconds, [switch]$FromTimeline, [switch]$CenterTimeline)
    if ($null -eq $State.Context -or $State.Duration -le 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return }
    Stop-AnalyzerPlayback
    $State.EventListPinnedId=$null
    $State.PendingSeek=[Math]::Min([Math]::Max(0.0,$Seconds),$State.Duration)
    # The endpoint is a paused player state, not a request to encode an empty
    # tail. Include the final 100 ms (also covers trackbar rounding).
    if ($State.PendingSeek -ge $State.Duration-[Math]::Min(0.1,$State.Duration/2.0)) { $State.PendingSeek=$State.Duration }
    $State.SeekPaused=$State.Paused
    Update-QualityActionAvailability $State
    if ($State.Split) { Update-SplitExtractionAvailability $State }
    if ($FromTimeline) {
        if ($null -ne $State.TimelinePauseSnapshot) { $State.SeekPaused=[bool]$State.TimelinePauseSnapshot }
        $State.TimelinePauseSnapshot=$null
        # A timeline gesture establishes a new editing context. A row chosen
        # earlier must not silently override the newly highlighted annotation.
        foreach ($row in $State.List.SelectedItems) { $row.Selected=$false }
        $State.EnsureCurrentVisible=$true
    }
    if ($null -ne $State.Slider) {
        $State.Slider.Value=[int]($State.PendingSeek/$State.Duration*$State.Slider.Maximum)
    }
    # Reframe the accepted target immediately, even when playback is paused or seeking.
    # A trackbar drag requests its final position on release, avoiding a moving drag target.
    if ($FromTimeline -or $CenterTimeline) { Center-TimelinePosition $State ([double]$State.PendingSeek) }
}
# Restart media playback to apply a pending seek or changed playback settings.
function Restart-QualityPlayback {
    param($State)
    if ($null -eq $State.PendingSeek) { return }
    $target=[double]$State.PendingSeek; $paused=$State.SeekPaused
    $State.PendingSeek=$null; $State.Seeking=$true
    if ($target -ge $State.Duration) {
        if ($State.NativeMpv) {
            if (-not $State.Clock.SetPaused($true,2500)) { throw (Get-QualityText 'Player pause command timed out.' 'O leitor não confirmou o comando de pausa.') }
            $State.PauseToConfirm=$null
        } elseif (-not $State.Paused) { Switch-QualityPause $State }
        $State.Paused=$true; $State.Ended=$true; $State.Seeking=$false
        $State.EnsureCurrentVisible=$true
        Update-QualityLabel $State
        Write-QualityDiagnostic $State 'timeline-end-paused'
        return
    }
    Stop-QualityPlayback $State.Session
    if ($State.Context.Engine -eq 'mpv') {
        $session=Start-QualityPlayback $State.Context $target $paused
        Attach-MpvPlayback $State $session $paused
        return
    }
    $State.Session=Start-QualityPlayback $State.Context $target
    $State.Player=$State.Session.Player
    $State.Clock=New-Object MachiningMonitor.QualityClock
    $State.Clock.Start($State.Player.StandardError)
    $State.BaseSeconds=$State.Session.BaseSeconds
    $State.Handle=[IntPtr]::Zero; $State.Embedded=$false; $State.Paused=$false; $State.Ended=$false
    $State.RestorePaused=$paused
}
# Append playback diagnostic information when diagnostics are enabled.
function Write-QualityDiagnostic {
    param($State,[string]$Event)
    try {
        if (-not $State.DiagnosticPath) { return }
        $line='{0:o} {1} ready={2} connected={3} paused={4}' -f [DateTime]::UtcNow,$Event,$State.Clock.Ready,$State.Clock.Connected,$State.Paused
        [IO.File]::AppendAllText($State.DiagnosticPath,$line+[Environment]::NewLine)
    } catch { }
}
# Run the playback UI update loop until the management window or session closes.
# Preserve the failing operation, not just the generic exception message.
function Write-PlaybackFailureDiagnostic {
    param($State,[Management.Automation.ErrorRecord]$Failure)
    try {
        $path=$State.DiagnosticPath
        if(-not $path){$path=Join-Path ([IO.Path]::GetTempPath()) ('ma-playback-error-'+[guid]::NewGuid().ToString('N')+'.log');$State.DiagnosticPath=$path}
        $process=[Diagnostics.Process]::GetCurrentProcess()
        try {
            $details=@(
                ('Playback failure '+[datetime]::UtcNow.ToString('o')),
                ('64-bit process: '+[Environment]::Is64BitProcess),
                ('Private bytes: '+$process.PrivateMemorySize64),
                ('Working set: '+$process.WorkingSet64),
                ('Managed bytes: '+[GC]::GetTotalMemory($false)),
                ('Handles: '+$process.HandleCount),
                $Failure.Exception.ToString(),
                $Failure.InvocationInfo.PositionMessage,
                $Failure.ScriptStackTrace
            ) -join [Environment]::NewLine
            [IO.File]::AppendAllText($path,([Environment]::NewLine+$details+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
        } finally {$process.Dispose()}
    } catch { }
}
function Wait-QualityPlayback {
    param($Panel)
    $s=$Panel.Tag
    $s.PlaybackError=$null
    $timer=New-Object Windows.Forms.Timer
    $timer.Interval=50
    $timer.Tag=$Panel
    $timer.Add_Tick({
        param($sender,$eventArgs)
        $p=$sender.Tag; $state=$p.Tag
        if ($p.IsDisposed -or -not $p.Enabled -or $state.UpdatingPlayback) { return }
        $state.UpdatingPlayback=$true
        try {
            if ($null -ne $state.PendingSeek) { Restart-QualityPlayback $state }
            Update-QualityPanel $p -NoPump
            if ($p.IsDisposed) { return }
            $session=$state.Session
            if($session.Producer -and $session.Producer.HasExited -and $session.Producer.ExitCode -ne 0){throw (Get-PlaybackPipelineFailure $session 'FFmpeg failed.')}
            if($session.Copy -and $session.Copy.IsFaulted){throw (Get-PlaybackPipelineFailure $session 'Falha na preparação dos dados para o leitor.')}
            if ($session.Player.HasExited) {
                if ($session.Player.ExitCode -ne 0) { throw (Get-PlaybackPipelineFailure $session (Get-UiText 'The player exited with an error.')) }
                $p.Close(); return
            }
            if ($state.Clock.Ready -and $state.Embedded) {
                $state.Seeking=$false
                if ($state.OpeningNoticePending) {
                    $state.TransitionNotice.Hide()
                    $state.OpeningNoticePending=$false
                }
            }
            Update-AnalyzerPlayback $state
            if ($null -ne $session.Copy -and $session.Copy.IsCompleted -and -not $session.InputClosed) {
                [void]$session.Copy.GetAwaiter().GetResult()
                $session.Player.StandardInput.Close(); $session.InputClosed=$true
                if ($session.Producer.HasExited -and $session.Producer.ExitCode -ne 0) {
                    throw (Get-UiText 'FFmpeg failed while preparing playback.')
                }
            }
        } catch {
            Write-PlaybackFailureDiagnostic $state $_
            $state.PlaybackError=$_.Exception.Message
            Write-QualityDiagnostic $state ('playback-error: '+$state.PlaybackError)
            $sender.Stop(); $p.Close()
        } finally { $state.UpdatingPlayback=$false }
    })
    try {
        Write-QualityDiagnostic $s 'message-loop-start'
        $timer.Start()
        # Let Windows dispatch mouse/keyboard messages continuously, including
        # messages exchanged with the embedded mpv window. Avoid polling DoEvents.
        [Windows.Forms.Application]::Run($Panel)
        if ($s.PlaybackError) {
            $message=$s.PlaybackError
            if ($s.DiagnosticPath) { $message += [Environment]::NewLine + $s.DiagnosticPath }
            if ($s.Session.LogPath) { $message += [Environment]::NewLine + $s.Session.LogPath }
            # The caller displays the error once, after the player has been stopped.
            throw $message
        }
    } finally {
        $timer.Stop(); $timer.Dispose()
        Write-QualityDiagnostic $s 'message-loop-stop'
        Stop-PlaybackBroadcast $s
        Stop-QualityPlayback $s.Session
    }
}
