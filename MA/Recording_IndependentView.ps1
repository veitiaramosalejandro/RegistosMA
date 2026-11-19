# Independent readers and native surfaces: changing one source or the window
# geometry never restarts the other source. Capture itself is not owned here.
$script:sourceViews=@{}
$script:independentCapturing=$false
$script:viewSelectionKey=$null
$script:viewSelectionPending=$false
$script:viewSelectionStarted=[DateTime]::MinValue
$script:viewSuppressedAt=[DateTime]::MinValue
function Test-RecordingGeometrySuppressed {
    $u=$script:RecordingUi
    if($u.Form.WindowState -eq 'Minimized' -or $u.Form.ResizeSuppressed){
        if($script:viewSuppressedAt -eq [DateTime]::MinValue){$script:viewSuppressedAt=[DateTime]::UtcNow}
        return $true
    }
    if($script:viewSuppressedAt -ne [DateTime]::MinValue){
        if($script:viewSelectionPending){$script:viewSelectionStarted=$script:viewSelectionStarted.Add([DateTime]::UtcNow-$script:viewSuppressedAt)}
        $script:viewSuppressedAt=[DateTime]::MinValue
    }
    return $false
}
function Update-IndependentSelectionTransition {
    $u=$script:RecordingUi
    $video=$u.ShowVideo.Checked -and $u.Mode.SelectedIndex -ne 1
    $audio=$u.ShowCharts.Checked -and $u.Mode.SelectedIndex -ne 2
    $key=[string]$video+'|'+$audio
    if($script:viewSelectionKey -cne $key){
        $script:viewSelectionKey=$key
        $script:viewSelectionPending=$true
        $script:viewSelectionStarted=[DateTime]::UtcNow
    }
    if($script:viewSelectionPending){$u.VideoHost.Visible=$false}
}
function Close-SourcePlayer($Player,$Guard,$Clock=$null,$Surface=$null){
    if($Player){Stop-PlaybackProcess $Player;$Player.Dispose()}
    if($Guard){$Guard.Dispose()}
    if($Clock -is [IDisposable]){$Clock.Dispose()}
    if($Surface){$Surface.Dispose()}
}
function Stop-SourceReader($s){
    if($s.Renderer){Stop-PlaybackProcess $s.Renderer}
    if($s.Monitor){$s.Monitor.Dispose();$s.Monitor=$null}
    if($s.Copy){try{[void]$s.Copy.Wait(1000)}catch{};$s.Copy=$null}
    if($s.Renderer){$s.Renderer.Dispose();$s.Renderer=$null}
    if(($s.Player -and $s.Player -ne $s.Display) -or ($s.PlayerSurface -and $s.PlayerSurface -ne $s.DisplaySurface)){Close-SourcePlayer $s.Player $s.Guard $s.PlayerClock $s.PlayerSurface}
    $s.Player=$null;$s.Guard=$null;$s.PlayerClock=$null;$s.PlayerSurface=$null
}
function Stop-SourceView($s){
    Stop-SourceReader $s
    if($s.Kind -eq 'Video'){$script:RecordingUi.Viewport.Tag.RecordingZoomState=$null}
    Close-SourcePlayer $s.Display $s.DisplayGuard $s.DisplayClock $s.DisplaySurface
    $s.Display=$null;$s.DisplayGuard=$null
    $s.Host.Dispose()
}
function Stop-IndependentRecordingView {
    foreach($s in @($script:sourceViews.Values)){Stop-SourceView $s}
    $script:sourceViews=@{}
    $script:viewSelectionKey=$null;$script:viewSelectionPending=$false
    $script:activeRenderer=$null;$script:activePlayer=$null;$script:activeAudioMonitor=$null
    $script:activeCopy=$null;$script:activeCamera=$null;$script:activeAudioSource=$null
    if($script:RecordingUi){$script:RecordingUi.VideoHandle=[IntPtr]::Zero}
}
function Get-SourceRenderItems($s){
    $u=$script:RecordingUi;$c=$u.Viewport.Tag
    $video=$s.Kind -eq 'Video';$urls=@();if($video){$urls=@($s.Cameras)}
    # Only the graph builder sees this isolated rendering selection. Real UI
    # checkboxes, layout preferences and the sibling reader are untouched.
    $size=$s.TargetBounds.Size
    $fake=@{VideoHost=[pscustomobject]@{ClientSize=$size};Viewport=[pscustomobject]@{Tag=@{Video=$video;Charts=(-not $video);Heights=$c.Heights.Clone();CameraLayout=$c.CameraLayout}}}
    function Set-VisualizationCameraCount {param($Viewport,[int]$Count)}
    $elapsed=0;if($script:independentCapturing){$elapsed=Get-RecordingViewElapsed}
    try{
        $script:RecordingUi=$fake
        $block=600;if($script:independentCapturing -and $script:segmentMinutes){$block=[double]$script:segmentMinutes*60}
        $items=@(Get-LiveVisualizationArguments $script:livePort (Get-DefaultSpectrumChannel $script:configPath) (Get-DefaultWaveformGain $script:configPath) $urls -BlockSeconds $block -ElapsedSeconds $elapsed -PreviewOnly:(!$script:independentCapturing) -CanvasWidth ([Math]::Max(320,$size.Width)) -CanvasHeight ([Math]::Max(160,$size.Height)))
    }finally{$script:RecordingUi=$u}
    if($video){
        # Keep established camera connections alive for the same ten-second
        # recovery window used by the independent availability controller.
        for($i=0;$i -lt $items.Count-1;$i++){if($items[$i] -eq '-timeout'){$items[$i+1]='10000000'}}
        $items=@(Set-RecordingExternalAudioInput $items ([pscustomobject]@{Type='None';InputName=''}))
    }
    elseif(-not $script:independentCapturing){
        $items=@(Set-RecordingExternalAudioInput $items $s.Source (Get-CaptureAudioBufferMilliseconds $script:configPath))
        # The idle reader receives raw input. Capture's UDP tap already has
        # this gain, so apply it here only before recording starts.
        $gain=Get-RecordingAudioGainText (Read-RecordingConfig $script:configPath)
        $graphIndex=[Array]::IndexOf($items,'-filter_complex')
        $graph=[string]$items[$graphIndex+1]
        $items[$graphIndex+1]='[0:a:0]volume='+$gain+'[sourcegain];'+$graph.Replace('[0:a:0]','[sourcegain]')
    }
    if($video -or -not $script:independentCapturing){$items=@(Set-RecordingPreviewSync $items $video)}
    return @(Set-RecordingLiveAudioTrace $items)
}
function Start-SourceReader($s){
    Stop-SourceReader $s
    $s.ReadyHandle=[IntPtr]::Zero
    $items=@(Get-SourceRenderItems $s)
    # Keep SDL's resizable window flag. Embedding removes the native border;
    # -noborder would also make SDL reject later host size changes.
    if($s.Kind -eq 'Video'){
        Initialize-MpvController
        $surface=New-Object Windows.Forms.Panel;$surface.Visible=$false;$surface.Bounds=New-Object Drawing.Rectangle(0,0,$s.TargetBounds.Width,$s.TargetBounds.Height)
        $s.Host.Controls.Add($surface);$s.PlayerSurface=$surface
        $pipe='ma-recording-video-'+[guid]::NewGuid().ToString('N')
        $options=@('--no-config','--load-scripts=no','--terminal=no','--osc=no','--osd-level=0','--input-default-bindings=no','--input-vo-keyboard=no','--input-cursor=no','--force-window=yes','--audio=no','--hwdec=no','--vo=gpu','--gpu-api=d3d11','--video-unscaled=yes','--cache=no','--demuxer-readahead-secs=0','--demuxer-lavf-format=nut',('--wid='+$surface.Handle.ToInt64()),('--input-ipc-server='+$pipe),'-')
        $s.Player=Start-PlaybackProcess (Find-PlaybackExecutable 'mpv.exe') $options -PipeInput
        $surface.Tag=$s.Player.Id
        $surface.Add_ClientSizeChanged({if($this.Tag){[MachiningMonitor.AdaptiveMpvController]::ResizeEmbedded($this.Handle,[int]$this.Tag,$this.ClientSize.Width,$this.ClientSize.Height)}})
        $s.PlayerClock=New-Object MachiningMonitor.AdaptiveMpvController;$s.PlayerClock.Start($pipe)
    }else{
    $window=@('-x',[string]([Math]::Max(320,$s.TargetBounds.Width)),'-y',[string]([Math]::Max(160,$s.TargetBounds.Height)),'-left','-32000','-top','-32000','-window_title',('Machining Monitor - '+$s.Kind))
    $s.Player=Start-PlaybackProcess (Find-PlaybackExecutable 'ffplay.exe') (@('-loglevel','info','-stats','-an','-flags','low_delay','-framedrop','-analyzeduration','1','-probesize','32768','-fpsprobesize','0','-f','nut','-i','pipe:0')+$window) -PipeInput -QualityClock
    # Window creation precedes the first painted frame. Publish a replacement
    # only after its playback clock confirms that video refresh has started.
    $s.PlayerClock=New-Object MachiningMonitor.QualityClock
    $s.PlayerClock.Start($s.Player.StandardError)
    }
    $s.Errors=$s.PlayerClock.Reader
    $s.Guard=New-RecordingEscapeGuard $s.Player.Id
    $s.Renderer=Start-PlaybackProcess $script:ffmpegPath $items -PipeOutput -QualityClock
    $count=0;if($s.Kind -eq 'Video'){$count=$s.Cameras.Count}
    $s.Monitor=New-Object MachiningMonitor.LiveSources284($s.Renderer.StandardError,$count)
    $s.Observed=0
    $s.Copy=$s.Renderer.StandardOutput.BaseStream.CopyToAsync($s.Player.StandardInput.BaseStream)
    $s.Attempt=[DateTime]::UtcNow
    $s.RenderKey=$s.DesiredRenderKey
}
function Test-RecordingSourceGeometryPending($s){
    return $s.Host.Bounds -ne $s.TargetBounds -or (($s.DisplayRenderKey -split '\|',2)[0] -cne ($s.DesiredRenderKey -split '\|',2)[0])
}
function Set-IndependentViewLayout {
    $u=$script:RecordingUi;if(-not $u -or $u.Form.IsDisposed){return}
    if(Test-RecordingGeometrySuppressed){return}
    Update-IndependentSelectionTransition
    $c=$u.Viewport.Tag;$top=0
    foreach($kind in @('Video','Audio')){
        if(-not $script:sourceViews.ContainsKey($kind)){continue}
        $s=$script:sourceViews[$kind]
        $selected=if($kind -eq 'Video'){$u.ShowVideo.Checked -and $u.Mode.SelectedIndex -ne 1}else{$u.ShowCharts.Checked -and $u.Mode.SelectedIndex -ne 2}
        if(-not $selected){$s.Host.Visible=$false;continue}
        $height=if($kind -eq 'Video'){$c.Heights.Video}else{$c.Heights.Frequency+$c.Heights.History}
        $s.TargetBounds=New-Object Drawing.Rectangle(0,$top,[Math]::Max(1,$u.VideoHost.ClientSize.Width),[Math]::Max(1,$height));$top+=$height
        $width=[Math]::Max(320,$s.TargetBounds.Width)
        $key=if($kind -eq 'Video'){"$width/$($c.Heights.Video)/$($c.CameraLayout)"}else{"$width/$($c.Heights.Frequency)/$($c.Heights.History)"}
        if($s.DesiredRenderKey -cne $key){$s.DesiredRenderKey=$key;$s.LayoutChangedAt=[DateTime]::UtcNow}
    }
    $u.Placeholder.Visible=$false;$u.WaitingForImage=$false
    Hide-RecordingSourceWait
    $pending=$script:viewSelectionPending
    foreach($s in $script:sourceViews.Values){if(Test-RecordingSourceGeometryPending $s){$pending=$true}}
    if([bool]$c.SplittersTransition -ne [bool]$pending){$c.SplittersTransition=[bool]$pending;Update-VisualizationGrips $u.Viewport}
    Update-RecordingResizeNotice
}
function Complete-IndependentViewLayout {
    $u=$script:RecordingUi
    if($script:viewSelectionPending -and ([DateTime]::UtcNow-$script:viewSelectionStarted).TotalSeconds -gt 10){throw (New-RecordingViewException)}
    $views=@($script:sourceViews.Values)
    # A changed composition is published as a unit. Until then every existing
    # native surface retains its displayed bounds and its original frame size.
    $group=$script:viewSelectionPending
    foreach($s in $views){if($s.Display -and (Test-RecordingSourceGeometryPending $s)){$group=$true}}
    $ready=@{}
    foreach($s in $views){
        $ready[$s.Kind]=($s.Player -and -not $s.Player.HasExited -and $s.Renderer -and -not $s.Renderer.HasExited -and $s.RenderKey -ceq $s.DesiredRenderKey -and ($s.Player -eq $s.Display -or ($s.ReadyHandle -ne [IntPtr]::Zero -and $s.Monitor.OutputWidth -gt 0 -and $s.PlayerClock.Ready)))
        if($group -and -not $ready[$s.Kind]){return}
    }
    $old=@()
    $u.VideoHost.SuspendLayout()
    try{
        foreach($s in $views){
            if(-not $ready[$s.Kind]){continue}
            if($s.Player -eq $s.Display){
                if($group){$s.Host.Bounds=$s.TargetBounds}
                continue
            }
            $s.Host.Bounds=$s.TargetBounds
            if($s.Kind -eq 'Video'){
                $s.PlayerSurface.Bounds=$s.Host.ClientRectangle;$s.PlayerSurface.Visible=$true;$s.PlayerSurface.BringToFront()
                [MachiningMonitor.AdaptiveMpvController]::ResizeEmbedded($s.PlayerSurface.Handle,$s.Player.Id,$s.Host.Width,$s.Host.Height)
            }else{
                [MachiningMonitor.QualityClock]::Embed($s.ReadyHandle,$s.Host.Handle,$s.Host.Width,$s.Host.Height)
                [MachiningMonitor.RecordingWindow]::HideChildTaskbarEntry($s.ReadyHandle)
            }
            $old+=@{Player=$s.Display;Guard=$s.DisplayGuard;Clock=$s.DisplayClock;Surface=$s.DisplaySurface}
            $s.Display=$s.Player;$s.DisplayGuard=$s.Guard;$s.Handle=$s.ReadyHandle
            $s.DisplayClock=$s.PlayerClock;$s.DisplaySurface=$s.PlayerSurface
            if($s.Kind -eq 'Video'){$u.Viewport.Tag.RecordingZoomState=@{NativeMpv=$true;Clock=$s.DisplayClock;Seeking=$false};Update-VisualizationVideoZoom $u.Viewport}
            $s.DisplayRenderKey=$s.RenderKey;$s.ReflowStarted=[DateTime]::MinValue
            $s.Host.Visible=$true
        }
    }finally{$u.VideoHost.ResumeLayout($true)}
    foreach($item in $old){Close-SourcePlayer $item.Player $item.Guard $item.Clock $item.Surface}
    if($script:viewSelectionPending){$script:viewSelectionPending=$false;$u.VideoHost.Visible=$true}
    Update-RecordingResizeNotice
    $pending=$false
    foreach($s in $views){if($s.DisplayRenderKey -cne $s.DesiredRenderKey -or $s.Host.Bounds -ne $s.TargetBounds){$pending=$true}}
    if([bool]$u.Viewport.Tag.SplittersTransition -ne $pending){$u.Viewport.Tag.SplittersTransition=$pending;Update-VisualizationGrips $u.Viewport}
}
function Get-RecordingSessionConnectionState {
    if(-not ('MachiningMonitor.RecordingSessionConnection' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
 public static class RecordingSessionConnection {
  [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server,int session,int info,out IntPtr data,out int size);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr data);
  public static int Read() {
   IntPtr data=IntPtr.Zero; int size;
   try {
    if(!WTSQuerySessionInformation(IntPtr.Zero,Process.GetCurrentProcess().SessionId,8,out data,out size) || size<4) return -1;
    return Marshal.ReadInt32(data);
   } finally {if(data!=IntPtr.Zero) WTSFreeMemory(data);}
  }
 }
}
'@
    }
    return [MachiningMonitor.RecordingSessionConnection]::Read()
}
function Update-RecordingSessionRecovery {
    $now=[datetime]::UtcNow
    if($script:recordingSessionPoll -and ($now-$script:recordingSessionPoll).TotalSeconds -lt 1){return}
    $script:recordingSessionPoll=$now
    $connection=Get-RecordingSessionConnectionState
    if($connection -lt 0){return}
    if($connection -ne 0){$script:recordingSessionNeedsRecovery=$true;return}
    if(-not $script:recordingSessionNeedsRecovery){return}
    $script:recordingSessionNeedsRecovery=$false
    # SDL can keep decoding while its RDS rendering surface is lost. Replace
    # only the chart view; the capture and the camera reader keep running.
    if($script:sourceViews.ContainsKey('Audio')){
        Stop-SourceView $script:sourceViews.Audio
        $script:sourceViews.Remove('Audio')
    }
}
function Update-IndependentRecordingView {
    param([switch]$Capturing)
    $u=$script:RecordingUi
    if($SemGraficos -or -not $u -or $u.Form.IsDisposed -or $u.Mode.DroppedDown){return}
    Update-RecordingSessionRecovery
    if(Test-RecordingGeometrySuppressed){return}
    Update-IndependentSelectionTransition
    $script:independentCapturing=[bool]$Capturing
    $config=Read-RecordingConfig $script:configPath
    $wanted=@{Video=($u.ShowVideo.Checked -and $u.Mode.SelectedIndex -ne 1);Audio=($u.ShowCharts.Checked -and $u.Mode.SelectedIndex -ne 2)}
    $issues=@()
    foreach($kind in @('Video','Audio')){
        if(-not $wanted[$kind]){
            if($script:sourceViews.ContainsKey($kind)){Stop-SourceView $script:sourceViews[$kind];$script:sourceViews.Remove($kind)}
            continue
        }
        $source=$null;$cameras=@()
        if($kind -eq 'Video'){
            $cameras=@(Get-RecordingCameraUrls $script:configPath)
            Set-VisualizationCameraCount $u.Viewport $cameras.Count
        }
        else{if(-not (Test-RecordingAudioConfigured $config)){throw (New-RecordingViewException -AudioUnavailable)};$source=Select-RecordingAudio $script:configPath $script:ffmpegPath}
        $key=$kind+'|'+$script:UiLanguage+'|'+$Capturing+'|'+($cameras -join '|')
        $sync=Get-CurrentRecordingSyncPlan;$key+='/sync/'+$sync.AudioDelayMs+'/'+($sync.VideoDelayMs -join ',')
        if($kind -eq 'Video'){$key+='|'+$u.Viewport.Tag.CameraLayout}
        if($source){$key+='|'+$source.Type+'|'+$source.InputName+'|'+(Get-DefaultSpectrumChannel $script:configPath)+'|'+(Get-DefaultWaveformGain $script:configPath)}
        if($source -and -not $Capturing){$key+='|'+(Get-RecordingAudioGainText $config)}
        if($script:sourceViews.ContainsKey($kind) -and $script:sourceViews[$kind].Key -cne $key){Stop-SourceView $script:sourceViews[$kind];$script:sourceViews.Remove($kind)}
        if(-not $script:sourceViews.ContainsKey($kind)){
            $hostPanel=New-Object Windows.Forms.Panel;$hostPanel.BackColor=[Drawing.Color]::Black;$hostPanel.Visible=$false
            $u.VideoHost.Controls.Add($hostPanel)
            $s=@{Kind=$kind;Key=$key;Source=$source;Cameras=$cameras;Host=$hostPanel;Renderer=$null;Player=$null;Guard=$null;Display=$null;DisplayGuard=$null;Monitor=$null;Copy=$null;Handle=[IntPtr]::Zero;LastGood=[DateTime]::UtcNow;Attempt=[DateTime]::MinValue;Observed=0;Errors=$null;RenderKey='';DesiredRenderKey='';DisplayRenderKey='';TargetBounds=[Drawing.Rectangle]::Empty;ReadyHandle=[IntPtr]::Zero;LayoutChangedAt=[DateTime]::MinValue;ReflowStarted=[DateTime]::MinValue}
            $script:sourceViews[$kind]=$s
            Set-IndependentViewLayout
            try{Start-SourceReader $s}catch{$s.Attempt=[DateTime]::UtcNow}
        }
        $s=$script:sourceViews[$kind];$now=[DateTime]::UtcNow
        $packets=0;if($s.Monitor){$packets=if($kind -eq 'Video'){$s.Monitor.VideoPackets}else{$s.Monitor.Packets}}
        $alive=$s.Renderer -and -not $s.Renderer.HasExited -and $s.Player -and -not $s.Player.HasExited -and $s.Copy -and -not $s.Copy.IsCompleted
        $freshVideo=$kind -ne 'Video' -or ($s.Monitor -and $s.Monitor.MaxVideoIdleSeconds -lt 1)
        if($alive -and $freshVideo -and $packets -gt $s.Observed){
            $s.Observed=$packets;$s.LastGood=$now
            if($s.Player -ne $s.Display){
                $s.ReadyHandle=if($kind -eq 'Video'){$s.PlayerSurface.Handle}else{[MachiningMonitor.QualityClock]::FindWindow($s.Player.Id)}
            }
            elseif($s.DisplayRenderKey -ceq $s.DesiredRenderKey){$s.Host.Visible=$true}
        }
        $idle=($now-$s.LastGood).TotalSeconds
        # Loss of video clears only its surface; audio charts keep advancing.
        if($kind -eq 'Video' -and $idle -ge 1 -and ($now-$s.ReflowStarted).TotalSeconds -ge 2){$s.Host.Visible=$false}
        if($idle -ge 10){$issues+=$kind;continue}
        $attemptAge=($now-$s.Attempt).TotalSeconds
        # Do not repeatedly tear down a live camera reader while it is waiting
        # for data or a keyframe. Closed readers can still reconnect promptly.
        if(((-not $alive) -and $attemptAge -ge 1) -or ($kind -eq 'Audio' -and $alive -and $idle -ge 3 -and $attemptAge -ge 3)){
            try{Start-SourceReader $s}catch{$s.Attempt=[DateTime]::UtcNow}
        }
        elseif($alive -and $s.RenderKey -cne $s.DesiredRenderKey -and ($now-$s.LayoutChangedAt).TotalMilliseconds -ge 350 -and -not $u.Form.InteractiveResize -and -not $u.Viewport.Tag.Dragging){
            # Like playback management, rebuild the graph at its target size.
            # The old display remains embedded until the replacement is ready;
            # neither the sibling source nor the capture process is restarted.
            $s.ReflowStarted=$now
            try{Start-SourceReader $s}catch{$s.Attempt=[DateTime]::UtcNow}
        }
    }
    Set-IndependentViewLayout
    Complete-IndependentViewLayout
    # Compatibility for status/clock consumers; source lifetimes remain owned
    # exclusively by sourceViews, never by these status aliases.
    $first=$null;foreach($kind in @('Audio','Video')){if($script:sourceViews.ContainsKey($kind)){$first=$script:sourceViews[$kind];break}}
    $script:activeRenderer=if($first){$first.Renderer}else{$null};$script:activePlayer=if($first){$first.Player}else{$null}
    $script:activeCopy=if($first){$first.Copy}else{$null}
    $script:activeAudioMonitor=if($script:sourceViews.Audio){$script:sourceViews.Audio.Monitor}else{$null}
    $script:activeAudioSource=if($script:sourceViews.Audio){$script:sourceViews.Audio.Source}else{[pscustomobject]@{Type='None';InputName=''}}
    $script:activeCamera=if($script:sourceViews.Video){$script:sourceViews.Video.Cameras}else{$null}
    $u.VideoHandle=if($first){$first.Handle}else{[IntPtr]::Zero}
    if($issues.Count){
        foreach($kind in $issues){Stop-SourceView $script:sourceViews[$kind];$script:sourceViews.Remove($kind)}
        throw (New-RecordingViewException -AudioUnavailable:($issues -contains 'Audio') -VideoUnavailable:($issues -contains 'Video'))
    }
}
function Stop-ActiveRecordingView {param([switch]$KeepAudioRecovery,[switch]$PreserveView) Stop-IndependentRecordingView}
function Start-ActiveRecordingView {param([switch]$ReuseCamera) Update-IndependentRecordingView}
function Update-ActiveRecordingView {Update-IndependentRecordingView}
function Update-AdaptiveRecordingVisualization {
    if($script:independentCapturing){
        try{Update-IndependentRecordingView -Capturing}catch{Show-RecordingViewFailure $_.Exception}
    }else{Set-IndependentViewLayout}
}
function Update-RecordingVisualizationLayout {param([switch]$Restore) Set-IndependentViewLayout}
function Start-RecordingResizeNotice {Set-IndependentViewLayout}
function Update-RecordingResizeNotice {
    $u=$script:RecordingUi
    if(-not $u -or -not $u.ResizeStatus -or $u.Form.IsDisposed){return}
    if(Test-RecordingGeometrySuppressed){return}
    if(Test-VisualizationInteractionActive $u.Viewport){
        $u.ResizeStatus.Visible=$false
        $u.ResizeNoticeActive=$false
        if(-not $script:viewSelectionPending){$u.VideoHost.Visible=$true}
        if($u.Form.InteractiveResize){
            foreach($s in $script:sourceViews.Values){
                if($s.Display -and $s.Handle -ne [IntPtr]::Zero){
                    $s.Host.Bounds=$s.TargetBounds
                    [MachiningMonitor.RecordingWindow]::ResizeAsync($s.Handle,$s.Host.Width,$s.Host.Height,$false)
                }
            }
        }
        return
    }
    $pending=$false;$display=$false
    foreach($s in $script:sourceViews.Values){
        if($s.Display){$display=$true;if(Test-RecordingSourceGeometryPending $s){$pending=$true}}
    }
    if($pending -and $display -and -not $script:viewSelectionPending){
        $u.ResizeNoticeActive=$true
        $u.VideoHost.Visible=$false
        $u.ResizeStatus.Text=Get-QualityText 'Resizing - please wait...' 'A redimensionar - aguarde...'
        Update-VisualizationMessageLayers $u.Viewport
        $u.ResizeStatus.Visible=$true;$u.ResizeStatus.BringToFront()
    }else{
        $u.ResizeStatus.Visible=$false;$u.ResizeNoticeActive=$false
        if(-not $script:viewSelectionPending){$u.VideoHost.Visible=$true}
    }
}
function Update-RecordingSourceWait {Hide-RecordingSourceWait}
function Get-HealthyLiveCamera {
    $s=$script:sourceViews.Video
    if($s -and $s.Renderer -and -not $s.Renderer.HasExited -and $s.Monitor -and $s.Monitor.MaxVideoIdleSeconds -lt 1){return $s.Cameras}
    return $null
}
