. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Recording_LiveAudioMonitor.ps1')
. (Join-Path $PSScriptRoot 'Recording_ViewWait.ps1')

<#
Recording_ActiveView.ps1 - version 288.
Shared recording controls and layout helpers. Independent source readers are loaded from Recording_IndependentView.ps1.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>

# Measure the status text and size its label without truncation.
function Fit-RecordingViewStatus {
    param($Label)
    $textSize=[Windows.Forms.TextRenderer]::MeasureText($Label.Text,$Label.Font)
    $width=$textSize.Width+16
    if($Label.Width -ne $width){$Label.Width=$width}
    if($Label.Height -ne 30){$Label.Height=30}
    $Label.TextAlign='MiddleCenter'
}
# Position recording controls, preserve fixed button widths and enforce the required minimum width.
function Set-RecordingControlsLayout {
    param($Panel)
    $window=$Panel.FindForm()
    if($window -and ($window.WindowState -eq 'Minimized' -or ($window.PSObject.Properties['ResizeSuppressed'] -and $window.ResizeSuppressed))){return}
    $c=$Panel.Tag
    if(-not $c){return}
    if($c.Mode.DroppedDown){return}
    $warningWidth=([Windows.Forms.TextRenderer]::MeasureText((Get-QualityText 'Warning: not recording' 'Atenção: não está a gravar'),$c.ViewStatus.Font)).Width+16
    $settingsWidth=120;$modeWidth=210;$toggleWidth=52;$eventWidth=140
    $c.Start.SetBounds(12,4,$toggleWidth,30)
    $c.ViewStatus.Location=New-Object Drawing.Point(72,4)
    $eventX=72+$warningWidth+12
    # Place event entry below the capture toggle and reserve its former position for timer/schedule controls.
    $c.Event.SetBounds(12,38,140,30)
    $c.TimerButton.SetBounds($eventX,4,120,30)
    $c.SchedulesButton.SetBounds(($c.TimerButton.Right+8),4,130,30)
    $requiredClientWidth=$c.SchedulesButton.Right+16+$modeWidth+8+$settingsWidth+12
    $form=$Panel.FindForm()
    if($form){
        $minimumWidth=[Math]::Max($script:RecordingUi.MinimumWindowSize.Width,$requiredClientWidth+($form.Width-$form.ClientSize.Width))
        if($form.MinimumSize.Width -ne $minimumWidth){$form.MinimumSize=New-Object Drawing.Size($minimumWidth,$script:RecordingUi.MinimumWindowSize.Height)}
    }
    $settingsX=$Panel.ClientSize.Width-12-$settingsWidth
    $modeX=$settingsX-8-$modeWidth

    $rightY=4
    $c.Mode.SetBounds($modeX,($rightY+2),$modeWidth,28)
    $c.Settings.SetBounds($settingsX,$rightY,$settingsWidth,30)
    $contextWidth=[Math]::Max(160,([Windows.Forms.TextRenderer]::MeasureText($c.ContextButton.Text,$c.ContextButton.Font)).Width+28)
    $c.ContextButton.SetBounds(($Panel.ClientSize.Width-12-$contextWidth),38,$contextWidth,30)
    Fit-RecordingViewStatus $c.ViewStatus
    $c.Stop.Visible=$false
    Set-RecordingInformationLayout $c $Panel.ClientSize.Width
}
# Calculate the red recording indicator's two-second cosine pulse.
function Get-RecordingIndicatorColor {
    param([double]$Seconds,$Background)
    # Two-second cosine pulse. Keep red visible throughout the whole cycle.
    $strength=0.4+0.6*(0.5+0.5*[Math]::Cos([Math]::PI*$Seconds))
    return [Drawing.Color]::FromArgb(
        [int]($Background.R+(255-$Background.R)*$strength),
        [int]($Background.G*(1-$strength)),
        [int]($Background.B*(1-$strength)))
}
# Refresh the recording/view indicator and the start/stop toggle.
function Update-RecordingViewIndicator {
    $u=$script:RecordingUi
    if(-not $u -or $u.Form.IsDisposed -or -not $u.ViewStatus){return}
    Update-RecordingToggle
    $recording=[bool]$u.Running
    if($u.Status){
        # Idle notices include completion, missed recordings and the next pending start.
        $u.Status.Visible=$recording -or [bool]$u.IdleRecordingText
        if(-not $recording){$u.Status.Text=[string]$u.IdleRecordingText} 
    }
    $live=$false
    if($script:activeRenderer -and $script:activePlayer){
        try {$live=(-not $script:activeRenderer.HasExited -and -not $script:activePlayer.HasExited)}catch{}
    }
    $u.ViewStatus.Visible=$recording -or $live
    if($recording){
        $u.ViewStatus.Text=Get-QualityText 'Recording in progress' 'Gravação em curso'
        $u.ViewStatus.ForeColor=[Drawing.Color]::White
        $red=[int](160+95*(0.5+0.5*[Math]::Cos([Math]::PI*$u.PulseClock.Elapsed.TotalSeconds)))
        $u.ViewStatus.BackColor=[Drawing.Color]::FromArgb($red,0,0)
    } elseif($live){
        $u.ViewStatus.Text=Get-QualityText 'Warning: not recording' 'Atenção: não está a gravar'
        $u.ViewStatus.ForeColor=[Drawing.Color]::Red
        $u.ViewStatus.BackColor=$u.ViewStatus.Parent.BackColor
    }
    Fit-RecordingViewStatus $u.ViewStatus
    if($u.ViewStatus.Parent.Tag){Set-RecordingInformationLayout $u.ViewStatus.Parent.Tag $u.ViewStatus.Parent.ClientSize.Width}
    Update-RecordingResizeNotice
}

# Reuse the existing camera validation when possible, otherwise probe the camera before capture.
function Test-RecordingStartCamera {
    param([string]$FFmpegPath,[string]$CameraUrl)
    $validated=$script:validatedLiveCamera
    $script:validatedLiveCamera=$null
    if(@($validated).Count -eq 1 -and $validated -and $validated[0] -ceq $CameraUrl){return $true}
    return Test-RecordingCamera -FFmpegPath $FFmpegPath -CameraUrl $CameraUrl
}
# Check FFmpeg segmentation support and cache the result for repeated starts.
function Assert-CachedRecordingSegmentationSupport {
    param([string]$FFmpegPath)
    $key=$FFmpegPath+'|'+[IO.File]::GetLastWriteTimeUtc($FFmpegPath).Ticks
    if($script:segmentationSupportKey -ceq $key){return}
    Assert-RecordingSegmentationSupport $FFmpegPath
    $script:segmentationSupportKey=$key
}

# Create the start/stop button icons and tooltip resources.
function Initialize-RecordingToggle {
    $u=$script:RecordingUi
    foreach($kind in 'Record','Stop'){
        $bitmap=New-Object Drawing.Bitmap(20,20)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.Clear([Drawing.Color]::Transparent)
            if($kind -eq 'Record'){$graphics.FillEllipse([Drawing.Brushes]::Red,3,3,14,14)}
            else {$graphics.FillRectangle([Drawing.Brushes]::Black,3,3,14,14)}
        } finally {$graphics.Dispose()}
        $u[$kind+'Icon']=$bitmap
    }
    $u.ToggleTip=New-Object MachiningMonitor.WrappingToolTip
    $u.Start.TextImageRelation='ImageBeforeText'
    $u.Start.ImageAlign='MiddleCenter'
    $u.Start.TextAlign='MiddleCenter'
    Update-RecordingToggle
}
# Set the toggle icon, tooltip and enabled state from the capture state.
function Update-RecordingToggle {
    $u=$script:RecordingUi
    if(-not $u -or -not $u.RecordIcon -or $u.ControllerBusy){return}
    $u.Stop.Visible=$false
    if($u.Running){
        $text=Get-QualityText 'Stop recording' 'Parar gravação'
        $image=$u.StopIcon
        $enabled=-not $u.Stopping
    } else {
        $text=Get-QualityText 'Start recording' 'Iniciar gravação'
        $image=$u.RecordIcon
        $enabled=-not $u.Ready
    }
    # Refresh only on a real state change; routine controller ticks are not UI states.
    if($u.Start.Text -cne ''){$u.Start.Text=''}
    if($u.Start.AccessibleName -cne $text){$u.Start.AccessibleName=$text; if($u.ToggleTip){$u.ToggleTip.SetToolTip($u.Start,$text)}}
    if(-not [object]::ReferenceEquals($u.Start.Image,$image)){$u.Start.Image=$image}
    if($u.Start.Enabled -ne $enabled){$u.Start.Enabled=$enabled}
}
# Represent the recording display dimensions as a key for resize comparisons.
function Get-RecordingViewSizeKey {
    $size=$script:RecordingUi.VideoHost.ClientSize
    $c=$script:RecordingUi.Viewport.Tag
    return Get-VisualizationRenderKey $size @{ShowVideo=$c.Video;ShowCharts=$c.Charts;VideoPanelHeight=$c.Heights.Video;FrequencyPanelHeight=$c.Heights.Frequency;HistoryPanelHeight=$c.Heights.History;CameraLayout=$c.CameraLayout}
}
# Return elapsed time used when rebuilding the live visualization.
function Get-RecordingViewElapsed {
    if($script:RecordingUi.Running -and $script:captureLogMonitor -and $script:captureLogMonitor.Ready){return $script:captureLogMonitor.Seconds}
    return 0.0
}
# Rebuild chart-rendering processes for the current capture and drawing dimensions.
function Restart-RecordingCharts {
    if($script:escapeGuard){$script:escapeGuard.Dispose();$script:escapeGuard=$null}
    Stop-PlaybackProcess $script:liveRenderer
    Stop-PlaybackProcess $script:livePlayer
    if($script:liveCopy){try{[void]$script:liveCopy.Wait(1000)}catch{}}
    foreach($p in @($script:liveRenderer,$script:livePlayer)){if($p){$p.Dispose()}}
    $script:liveRenderer=$null;$script:livePlayer=$null;$script:liveCopy=$null
    $script:RecordingUi.VideoHandle=[IntPtr]::Zero
    . $script:startLiveVisualization
}

# Desired, pending and applied sizes are tracked separately. The resize notice remains
# over the video until the renderer has adopted the requested dimensions.

# Place the state indicator before the recording information text.
function Set-RecordingInformationLayout {
    param($Controls,[int]$Width)
    # Shift recording labels right to leave room for the event button on the second row.
    $Controls.ViewStatus.Location=New-Object Drawing.Point(72,4)
    if($Controls.Status){
        $x=168
        $statusWidth=[Math]::Max(0,$Controls.ContextButton.Left-$x-8)
        if(-not $Controls.Status.Tag){
            $Controls.Status.Tag=@{BaseFont=$Controls.Status.Font;CompactFonts=@{}}
            $Controls.Status.Add_Disposed({foreach($font in $this.Tag.CompactFonts.Values){$font.Dispose()}})
        }
        $fonts=$Controls.Status.Tag;$font=$fonts.BaseFont
        if($Controls.Status.Text -notmatch '[\r\n]' -and $statusWidth -gt 0){
            $size=[double]$font.Size
            while($size -gt 8 -and [Windows.Forms.TextRenderer]::MeasureText($Controls.Status.Text,$font).Width -gt $statusWidth){
                $size=[Math]::Max(8,$size-0.5);$key=$size.ToString([Globalization.CultureInfo]::InvariantCulture)
                if(-not $fonts.CompactFonts.ContainsKey($key)){$fonts.CompactFonts[$key]=New-Object Drawing.Font($fonts.BaseFont.FontFamily,([single]$size),$fonts.BaseFont.Style)}
                $font=$fonts.CompactFonts[$key]
            }
        }
        $Controls.Status.Font=$font
        $height=26
        if($Controls.Status.Text -match '[\r\n]' -and $statusWidth -gt 0){
            $preferred=$Controls.Status.GetPreferredSize((New-Object Drawing.Size($statusWidth,0)))
            $height=[Math]::Max(26,$preferred.Height+4)
        }
        $Controls.Status.SetBounds($x,40,$statusWidth,$height)
        if($Controls.List){
            $top=40+$height+4;$panel=$Controls.Status.Parent
            $Controls.List.SetBounds(12,$top,([Math]::Max(0,$Width-24)),([Math]::Max(24,$panel.ClientSize.Height-$top-12)))
        }
    }
}

# Show the waiting message while the camera or chart image is not yet available.
function Show-RecordingImageWait {
    param([bool]$WithCamera)
    $u=$script:RecordingUi
    if(-not $u.Placeholder -or $u.Form.IsDisposed){return}
    $u.WaitingForImage=$true
    $messages=@()
    if($WithCamera -and $u.ShowVideo.Checked){$messages+=(Get-QualityText 'Waiting for the camera image...' 'A aguardar pela imagem da câmara...')}
    if($u.ShowCharts.Checked){$messages+=(Get-QualityText 'Waiting for audio...' 'A aguardar pelo áudio...')}
    $u.Placeholder.Text=$messages -join [Environment]::NewLine
    if($u.ResizeNoticeActive){
        # Reopening the renderer during a resize is not a new live-view request.
        $u.Placeholder.Visible=$false
        $u.ResizeStatus.Visible=$true
        $u.ResizeStatus.BringToFront()
        $u.ResizeStatus.Refresh()
        return
    }
    $u.Placeholder.Visible=$true
    $u.Placeholder.BringToFront()
    $u.Placeholder.Refresh()
}

. (Join-Path $PSScriptRoot 'Recording_IndependentView.ps1')
