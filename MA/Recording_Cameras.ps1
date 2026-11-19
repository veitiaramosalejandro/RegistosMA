# Multi-camera preferences. CameraUrl remains the first selected camera for legacy readers.
. (Join-Path $PSScriptRoot 'Deletion_Authorization.ps1')
. (Join-Path $PSScriptRoot 'Recording_Credentials.ps1')
function Show-RecordingCameraUnavailable {
    param([string]$Message)
    $u=$script:RecordingUi
    if($u.CameraNoticeOpen){return}
    $u.CameraNoticeOpen=$true
    try {
        [void][Windows.Forms.MessageBox]::Show($u.Form,(Get-RecordingVisualizationFailure),
            (Get-QualityText 'Camera unavailable' 'Câmara indisponível'),'OK','Warning')
        $u.ShowVideo.Checked=$false
    } finally {$u.CameraNoticeOpen=$false}
}
function Get-RecordingVisualizationFailure {
    param([string]$Message,[switch]$Capturing)
    # Keep every camera failure notice concise, including failures before preview starts.
    $Message=Get-QualityText 'Video preview unavailable. Check the camera connection and its configuration. Video preview will be disabled. After correcting the issue, you can enable it again.' 'Visualização do vídeo indisponível. Verifique a ligação à câmara e a respetiva configuração. A visualização do vídeo irá ser desativada. Depois de corrigir a situação, pode voltar a ativar.'
    $names=@()
    try {$names=@(Get-RecordingCameras (Read-RecordingConfig $script:configPath) -Selected | ForEach-Object {$_.Name})}catch{}
    if($names.Count){$Message+=[Environment]::NewLine+[Environment]::NewLine+(Get-QualityText 'Selected cameras: ' 'Câmaras selecionadas: ')+($names -join ', ')}
    return $Message
}
function Get-RecordingCameras {
    param($Config,[switch]$Selected)
    $items=@()
    if($Config.PSObject.Properties['Cameras']){$items=@($Config.Cameras)}
    elseif($Config.CameraUrl){$items=@([pscustomobject]@{Name='Câmara 1';Url=[string]$Config.CameraUrl;Enabled=$true})}
    foreach($item in $items){
        if(-not $Selected -or $item.Enabled){$item}
    }
}
function Get-RecordingCameraUrls {
    param([string]$Path)
    $urls=@(Get-RecordingCameras (Read-RecordingConfig $Path) -Selected | ForEach-Object {Join-RecordingEndpoint (Get-RecordingCameraEndpoint $_)})
    foreach($url in $urls){if(-not (Test-CameraAddress $url)){throw 'Endereço RTSP da câmara inválido.'}}
    return $urls
}
function Test-CameraAddress {
    param([string]$Url)
    $uri=$null
    return ($Url -notmatch '["\r\n]' -and [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('rtsp','rtsps') -and $uri.Host)
}
# No network access from this dialog; checking a row selects that camera for the next session.
function New-RecordingCameraGrid {
    param($Config)
    . (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Add_CellMouseEnter({param($sender,$eventArgs)
        if($eventArgs.ColumnIndex -lt 0){return}
        if($eventArgs.RowIndex -lt 0 -and $sender.Columns[$eventArgs.ColumnIndex].Name -eq 'AudioSyncMs'){return}
        $cell=if($eventArgs.RowIndex -lt 0){$sender.Columns[$eventArgs.ColumnIndex].HeaderCell}else{$sender.Rows[$eventArgs.RowIndex].Cells[$eventArgs.ColumnIndex]}
        if($eventArgs.ColumnIndex -ge 0 -and $sender.Columns[$eventArgs.ColumnIndex].Name -eq 'Password'){$cell.ToolTipText='';return}
        $value=[string]$cell.FormattedValue
        $cell.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap($value)
    })
    $grid.SetBounds(12,172,868,158);$grid.Anchor='Top,Left,Right'
    $grid.AllowUserToAddRows=$true;$grid.AllowUserToDeleteRows=$true
    $grid.Add_UserDeletingRow({param($sender,$eventArgs)
        if(-not(Confirm-DeletionAuthorization $sender.FindForm() (Get-QualityText 'Remove camera' 'Remover câmara'))){$eventArgs.Cancel=$true}
    })
    $grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false
    $grid.AutoSizeColumnsMode='Fill';$grid.RowHeadersWidth=28
    $enabled=New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $enabled.Name='Enabled';$enabled.HeaderText=Get-QualityText 'Use' 'Usar';$enabled.AutoSizeMode='None';$enabled.Width=50;$enabled.MinimumWidth=50
    [void]$grid.Columns.Add($enabled)
    [void]$grid.Columns.Add('CameraName',(Get-QualityText 'Camera name' 'Nome da câmara'))
    $grid.Columns['CameraName'].FillWeight=180;$grid.Columns['CameraName'].MinimumWidth=150
    [void]$grid.Columns.Add('Url','URL RTSP');$grid.Columns['Url'].FillWeight=230
    $grid.Columns['Url'].MinimumWidth=240
    [void]$grid.Columns.Add('Username',(Get-QualityText 'Username' 'Utilizador'))
    [void]$grid.Columns.Add('Password',(Get-QualityText 'Password' 'Palavra-passe'))
    $grid.Columns['Username'].FillWeight=120;$grid.Columns['Username'].MinimumWidth=110
    $grid.Columns['Password'].FillWeight=130;$grid.Columns['Password'].MinimumWidth=120
    $grid.Add_CellFormatting({param($sender,$eventArgs)
        if($eventArgs.RowIndex -ge 0 -and $eventArgs.ColumnIndex -ge 0 -and $sender.Columns[$eventArgs.ColumnIndex].Name -eq 'Password' -and [string]$eventArgs.Value){$eventArgs.Value='••••••••';$eventArgs.FormattingApplied=$true}
    })
    $grid.Add_EditingControlShowing({param($sender,$eventArgs)
        if($eventArgs.Control -is [Windows.Forms.TextBox]){$eventArgs.Control.UseSystemPasswordChar=$sender.CurrentCell.OwningColumn.Name -eq 'Password'}
    })
    [void]$grid.Columns.Add('AudioSyncMs',(Get-QualityText 'Offset (ms)' 'Desfasamento (ms)'))
    $grid.Columns['AudioSyncMs'].MinimumWidth=110;$grid.Columns['AudioSyncMs'].FillWeight=110;$grid.Columns['AudioSyncMs'].DefaultCellStyle.NullValue='0'
    $grid.Columns['AudioSyncMs'].HeaderCell.ToolTipText=Get-QualityText 'Positive: video arrives after audio. Negative: video arrives before audio. Range: -5000 to 5000 ms.' 'Positivo: vídeo chega depois do áudio. Negativo: vídeo chega antes do áudio. Intervalo: -5000 a 5000 ms.'
    $grid.Columns['CameraName'].MinimumWidth=130;$grid.Columns['Url'].MinimumWidth=220;$grid.Columns['Username'].MinimumWidth=100;$grid.Columns['Password'].MinimumWidth=110
    foreach($column in $grid.Columns){$column.SortMode='NotSortable'}
    foreach($cam in @(Get-RecordingCameras $Config)){
        $endpoint=Get-RecordingCameraEndpoint $cam -ForEditing
        $index=$grid.Rows.Add([bool]$cam.Enabled,[string]$cam.Name,$endpoint.Url,$endpoint.Username,$endpoint.Password,(Read-RecordingSyncOffset $cam.AudioSyncMs))
        $grid.Rows[$index].Tag=@{NeedsPassword=$endpoint.NeedsPassword}
    }
    return ,$grid
}
function Read-RecordingCameraGrid {
    param($Grid)
    [void]$Grid.EndEdit()
    $result=@();$seen=@{}
    foreach($row in $Grid.Rows){
        if($row.IsNewRow){continue}
        $url=([string]$row.Cells['Url'].Value).Trim()
        $name=([string]$row.Cells['CameraName'].Value).Trim()
        if(-not $url -and -not $name){continue}
        $username=[string]$row.Cells['Username'].Value;$password=[string]$row.Cells['Password'].Value
        if($row.Tag -and $row.Tag.NeedsPassword -and $username -and -not $password){throw (Get-QualityText 'Enter the camera password again on this Windows account.' 'Volte a introduzir a palavra-passe da câmara nesta conta do Windows.')}
        $endpoint=Get-RecordingEndpoint $url $username
        if($password -or -not $endpoint.Password){$endpoint.Password=$password}
        $url=$endpoint.Url
        $connectionKey=Join-RecordingEndpoint $endpoint
        if(-not (Test-CameraAddress $url)){throw (Get-QualityText 'Invalid camera RTSP address.' 'Endereço RTSP da câmara inválido.')}
        if($seen.ContainsKey($connectionKey)){throw (Get-QualityText 'Duplicate camera address.' 'Endereço de câmara repetido.')};$seen[$connectionKey]=$true
        if(-not $name){$name='Câmara '+($result.Count+1)}
        $result += [pscustomobject]@{Name=$name;Url=$url;Enabled=([bool]$row.Cells['Enabled'].Value);Username=$endpoint.Username;PasswordProtected=(Protect-RecordingPassword $endpoint.Password);AudioSyncMs=(Read-RecordingSyncOffset $row.Cells['AudioSyncMs'].Value)}
    }
    return $result
}
function Remove-RecordingCameraRow {
    param($Grid)
    [void]$Grid.EndEdit()
    $row=$Grid.CurrentRow
    if($row -and -not $row.IsNewRow -and (Confirm-DeletionAuthorization $Grid.FindForm() (Get-QualityText 'Remove camera' 'Remover câmara'))){$Grid.Rows.Remove($row)}
}
function Move-RecordingCameraRow {
    param($Grid,[ValidateSet(-1,1)][int]$Direction)
    if(-not $Grid.EndEdit()){return}
    $row=$Grid.CurrentRow
    if(-not $row -or $row.IsNewRow){return}
    $targetIndex=$row.Index+$Direction
    if($targetIndex -lt 0 -or $targetIndex -ge $Grid.Rows.Count){return}
    $target=$Grid.Rows[$targetIndex]
    if($target.IsNewRow){return}
    $columnIndex=$Grid.CurrentCell.ColumnIndex
    for($i=0;$i -lt $Grid.Columns.Count;$i++){
        $value=$row.Cells[$i].Value
        $row.Cells[$i].Value=$target.Cells[$i].Value
        $target.Cells[$i].Value=$value
    }
    $tag=$row.Tag;$row.Tag=$target.Tag;$target.Tag=$tag
    $Grid.ClearSelection()
    $Grid.CurrentCell=$target.Cells[$columnIndex]
    $target.Selected=$true
}
# Reuse the existing video encoder/segment policy for each input independently.
function Get-MultiCameraCaptureArguments {
    param([string[]]$Urls,[string]$Folder,[double]$Seconds,[string]$Gain,[switch]$CameraOnly)
    $items=@()
    $useClock=-not $CameraOnly
    foreach($url in $Urls){$items+=@(Get-RecordingCameraInputArguments $url -SyncClock:$useClock)}
    if(-not $CameraOnly){$items+=@(Get-RecordingExternalAudioArguments $script:selectedDevice $script:captureAudioBufferMs -SyncClock:$useClock)}
    $sync=Get-CurrentRecordingSyncPlan
    for($i=0;$i -lt $Urls.Count;$i++){
        $prefix='video';if($i -gt 0){$prefix='camera_'+($i+1).ToString('00')}
        $args=@(Get-RecordingVideoSegmentArguments $Seconds (Join-Path $Folder ($prefix+'_segments.csv')) (Join-Path $Folder ($prefix+'_%06d.mp4')) $Gain)
        for($j=0;$j -lt $args.Count;$j++){
            if($args[$j] -eq '0:v:0'){$args[$j]="${i}:v:0"}
            if($args[$j] -eq '0:a:0'){$args[$j]="${i}:a:0?"}
        }
        $filterIndex=[Array]::IndexOf($args,'-filter:a')
        $audioClock=if($useClock){Get-RecordingCaptureAudioClockFilter}else{'asetpts=PTS-STARTPTS'}
        if($filterIndex -ge 0){$args[$filterIndex+1]=$audioClock+','+$args[$filterIndex+1]}
        $videoFilter=if($useClock){Get-RecordingCaptureVideoClockFilter}else{'setpts=PTS-STARTPTS'}
        if(-not $CameraOnly -and $i -lt $sync.VideoDelayMs.Count -and $sync.VideoDelayMs[$i] -gt 0){
            $ms=$sync.VideoDelayMs[$i];$secondsDelay=($ms/1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
            $videoFilter+=",tpad=start_duration=${secondsDelay}:start_mode=add:color=black"
            if($filterIndex -ge 0){$args[$filterIndex+1]+=",adelay=${ms}:all=1"}
        }
        if($useClock){$videoFilter+=",fps=fps='if(between(source_fps,1,120),source_fps,25)':start_time=0:round=near"}
        $args=@($args[0..($args.Count-2)])+@('-vf',$videoFilter,$args[-1])
        $items+=$args
    }
    if(-not $CameraOnly){$items+=@(Get-RecordingAudioSegmentArguments $Urls.Count $Seconds $Folder $Gain)}
    return $items
}
# Compose equal-width video cells, retaining the original audio/charts pipeline.
function ConvertTo-MultiCameraGraph {
    param([string]$Graph,[int]$Count,[int]$Width,[int]$Height,[ValidateSet('Horizontal','Vertical')][string]$CameraLayout='Horizontal')
    if($Count -le 1){return $Graph}
    $Graph=$Graph.Replace('[1:a:0]',("[${Count}:a:0]"))
    $cell=2*[int][Math]::Floor([Math]::Max(320,$Width)/$Count/2)
    $heightEven=2*[int][Math]::Floor([Math]::Max(24,$Height)/2)
    $stack='hstack'
    if($CameraLayout -eq 'Vertical'){
        $cell=2*[int][Math]::Floor([Math]::Max(320,$Width)/2)
        $heightEven=[Math]::Max(24,2*[int][Math]::Floor($Height/$Count/2))
        $stack='vstack'
    }
    $prefix='';$labels=''
    for($i=0;$i -lt $Count;$i++){
        $prefix+="[${i}:v:0]setpts=PTS-STARTPTS,scale=${cell}:${heightEven}:force_original_aspect_ratio=decrease,pad=${cell}:${heightEven}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25[cam${i}];"
        $labels+="[cam${i}]"
    }
    return $prefix+$labels+"${stack}=inputs=${Count}[cameras];"+$Graph.Replace('[0:v:0]','[cameras]')
}
# Probe all selected cameras concurrently, with one shared deadline. UI events keep
# the window usable; the controller busy flag prevents capture callback reentry.
function Test-RecordingCameraSet {
    param([string]$FFmpeg,[string[]]$Urls)
    $probes=@();$clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        foreach($url in $Urls){
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$FFmpeg
            $info.Arguments=Join-PreviewArguments @('-nostdin','-hide_banner','-loglevel','error','-progress','pipe:1','-rtsp_transport','tcp','-timeout','3000000','-analyzeduration','500000','-i',$url,'-map','0:v:0','-frames:v','1','-f','null','-')
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $process=New-Object Diagnostics.Process;$process.StartInfo=$info
            try {
                [void]$process.Start()
                $probes+=@{Process=$process;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}
            } catch {$process.Dispose();throw}
        }
        while($clock.ElapsedMilliseconds -lt 4000){
            if(-not @($probes | Where-Object {-not $_.Process.HasExited}).Count){break}
            [Windows.Forms.Application]::DoEvents()
            if($script:RecordingUi.Form.IsDisposed){throw 'A gravação foi cancelada.'}
            Start-Sleep -Milliseconds 20
        }
        foreach($probe in $probes){
            if(-not $probe.Process.HasExited -or $probe.Process.ExitCode -ne 0 -or -not $probe.Output.IsCompleted){return $false}
            if($probe.Output.Result -notmatch 'frame=\s*[1-9]'){return $false}
        }
        return $true
    } finally {
        foreach($probe in $probes){
            try {if(-not $probe.Process.HasExited){$probe.Process.Kill()}} finally {$probe.Process.Dispose()}
        }
    }
}
