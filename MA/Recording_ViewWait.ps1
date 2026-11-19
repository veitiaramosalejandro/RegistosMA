# Independent wait overlays for the video and external-audio regions.
function Hide-RecordingSourceWait {
    $u=$script:RecordingUi
    foreach($key in @('CameraWait','AudioWait')){if($u[$key]){$u[$key].Visible=$false}}
}
function Update-RecordingSourceWait {
    $u=$script:RecordingUi
    if(-not $u -or $u.Form.IsDisposed -or $u.Mode.DroppedDown -or $u.VideoHandle -eq [IntPtr]::Zero){return}
    if($script:audioRecovery){Hide-RecordingSourceWait;return}
    $monitor=if(-not $u.Running){$script:activeAudioMonitor}else{$null}
    $pending=@{
        CameraWait=($u.ShowVideo.Checked -and $u.ShowVideo.Enabled -and $monitor -and $monitor.VideoPackets -eq 0)
        AudioWait=($u.ShowCharts.Checked -and $monitor -and $monitor.Packets -eq 0)
    }
    $c=$u.Viewport.Tag;$videoHeight=if($c.Video){[int]$c.Heights.Video}else{0}
    foreach($key in @('CameraWait','AudioWait')){
        if(-not $u[$key]){
            if(-not $pending[$key]){continue}
            $label=New-Object Windows.Forms.Label;$label.BackColor=[Drawing.Color]::Black;$label.ForeColor=[Drawing.Color]::Silver
            $label.TextAlign='MiddleCenter';$label.Font=$u.Placeholder.Font;$label.Visible=$false
            $u.Viewport.Controls.Add($label);$u[$key]=$label
        }
        $label=$u[$key]
        $label.Text=if($key -eq 'CameraWait'){Get-QualityText 'Waiting for the camera image...' 'A aguardar pela imagem da câmara...'}else{Get-QualityText 'Waiting for audio...' 'A aguardar pelo áudio...'}
        $top=$u.VideoHost.Top;$height=$videoHeight
        if($key -eq 'AudioWait'){$top+=$videoHeight;$height=[int]$c.Heights.Frequency+[int]$c.Heights.History}
        $label.SetBounds($u.VideoHost.Left,$top,[Math]::Max(1,$u.VideoHost.Width),[Math]::Max(1,$height))
        if($label.Visible -ne [bool]$pending[$key]){$label.Visible=[bool]$pending[$key];if($label.Visible){$label.BringToFront()}}
    }
}
