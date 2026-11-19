function New-RecordingAudioGrid {
    param($Config)
    . (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Add_CellMouseEnter({param($sender,$eventArgs)
        if($eventArgs.ColumnIndex -lt 0){return}
        $cell=if($eventArgs.RowIndex -lt 0){$sender.Columns[$eventArgs.ColumnIndex].HeaderCell}else{$sender.Rows[$eventArgs.RowIndex].Cells[$eventArgs.ColumnIndex]}
        if($eventArgs.ColumnIndex -ge 0 -and $sender.Columns[$eventArgs.ColumnIndex].Name -eq 'Password'){$cell.ToolTipText='';return}
        $value=[string]$cell.FormattedValue
        $cell.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap($value)
    })
    $grid.SetBounds(12,172,868,158);$grid.Anchor='Top,Left,Right'
    $grid.AllowUserToAddRows=$true;$grid.AllowUserToDeleteRows=$true
    $grid.Add_UserDeletingRow({param($sender,$eventArgs)
        if(-not(Confirm-DeletionAuthorization $sender.FindForm() (Get-QualityText 'Remove audio source' 'Remover fonte de áudio'))){$eventArgs.Cancel=$true}
    })
    $grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false
    $grid.AutoSizeColumnsMode='Fill';$grid.RowHeadersWidth=28
    $enabled=New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $enabled.Name='Enabled';$enabled.HeaderText=Get-QualityText 'Use' 'Usar';$enabled.AutoSizeMode='None';$enabled.Width=50;$enabled.MinimumWidth=50
    [void]$grid.Columns.Add($enabled)
    [void]$grid.Columns.Add('CameraName',(Get-QualityText 'Source name' 'Nome da fonte'))
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
    [void]$grid.Columns.Add('GainDb',(Get-QualityText 'Gain (dB)' 'Ganho (dB)'))
    $grid.Columns['GainDb'].MinimumWidth=85;$grid.Columns['GainDb'].FillWeight=85;$grid.Columns['GainDb'].DefaultCellStyle.NullValue='0'
    $grid.Columns['CameraName'].MinimumWidth=130;$grid.Columns['Url'].MinimumWidth=220
    $grid.Columns['Username'].MinimumWidth=100;$grid.Columns['Password'].MinimumWidth=110
    foreach($column in $grid.Columns){$column.SortMode='NotSortable'}
    foreach($cam in @(Get-RecordingCameras $Config)){
        $endpoint=Get-RecordingCameraEndpoint $cam -ForEditing
        $index=$grid.Rows.Add([bool]$cam.Enabled,[string]$cam.Name,$endpoint.Url,$endpoint.Username,$endpoint.Password,(Get-RecordingGainDb $cam.GainDb))
        $grid.Rows[$index].Tag=@{NeedsPassword=$endpoint.NeedsPassword}
    }
    return ,$grid
}
function Read-RecordingAudioGrid {
    param($Grid)
    [void]$Grid.EndEdit()
    $result=@();$seen=@{}
    foreach($row in $Grid.Rows){
        if($row.IsNewRow){continue}
        $url=([string]$row.Cells['Url'].Value).Trim()
        $name=([string]$row.Cells['CameraName'].Value).Trim()
        if(-not $url -and -not $name){continue}
        $username=[string]$row.Cells['Username'].Value;$password=[string]$row.Cells['Password'].Value
        if($row.Tag -and $row.Tag.NeedsPassword -and $username -and -not $password){throw (Get-QualityText 'Enter the audio password again on this Windows account.' 'Volte a introduzir a palavra-passe do áudio nesta conta do Windows.')}
        $endpoint=Get-RecordingEndpoint $url $username
        if($password -or -not $endpoint.Password){$endpoint.Password=$password}
        $url=$endpoint.Url
        $connectionKey=Join-RecordingEndpoint $endpoint
        if(-not (Test-CameraAddress $url)){throw (Get-QualityText 'Invalid audio RTSP address.' 'Endereço RTSP do áudio inválido.')}
        if($seen.ContainsKey($connectionKey)){throw (Get-QualityText 'Duplicate audio address.' 'Endereço de áudio repetido.')};$seen[$connectionKey]=$true
        if(-not $name){$name='Áudio '+($result.Count+1)}
        $result += [pscustomobject]@{Name=$name;Url=$url;Enabled=([bool]$row.Cells['Enabled'].Value);Username=$endpoint.Username;PasswordProtected=(Protect-RecordingPassword $endpoint.Password);GainDb=(Get-RecordingGainDb $row.Cells['GainDb'].Value)}
    }
    return $result
}function Initialize-RecordingAudioProfiles {
 param($Dialog)
 $s=$Dialog.Tag;$config=$s.Config;$entries=@();$selected=$false
 foreach($p in @($config.AudioRtspProfiles)){
   if(-not $p){continue}
   $use=(-not $selected -and $p.AudioRtspUrl -eq $config.AudioRtspUrl -and [string]$p.AudioRtspUsername -eq [string]$config.AudioRtspUsername)
   if($use){$selected=$true}
   $entries += [pscustomobject]@{Name=$p.Name;Url=$p.AudioRtspUrl;Username=$p.AudioRtspUsername;PasswordProtected=$p.AudioRtspPasswordProtected;GainDb=(Get-RecordingGainDb $p.GainDb);Enabled=$use}
 }
 if(-not $selected -and $config.AudioRtspUrl){
   $entries += [pscustomobject]@{Name=(Get-QualityText 'External audio' 'Áudio externo');Url=$config.AudioRtspUrl;Username=$config.AudioRtspUsername;PasswordProtected=$config.AudioRtspPasswordProtected;GainDb=(Get-RecordingGainDb $config.AudioRtspGainDb);Enabled=$true}
 }
 $grid=New-RecordingAudioGrid ([pscustomobject]@{Cameras=@($entries)})
 $grid.SetBounds(12,122,868,145);$grid.Tag=@{Selecting=$false}
 $grid.Add_CurrentCellDirtyStateChanged({if($this.IsCurrentCellDirty -and $this.CurrentCell.OwningColumn.Name -eq 'Enabled'){[void]$this.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)}})
 $grid.Add_CellValueChanged({param($sender,$e)
   if($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0 -or $sender.Tag.Selecting -or -not [bool]$sender.Rows[$e.RowIndex].Cells[0].Value){return}
   $sender.Tag.Selecting=$true
   try{foreach($row in $sender.Rows){if(-not $row.IsNewRow -and $row.Index -ne $e.RowIndex){$row.Cells[0].Value=$false}}}finally{$sender.Tag.Selecting=$false}
 })
 $label=New-Object Windows.Forms.Label;$label.SetBounds(12,96,868,24);$label.Anchor='Top,Left,Right'
 $label.Text=Get-QualityText 'RTSP audio: select one source; add in the empty row' 'Áudio RTSP: selecione uma fonte; adicione na linha vazia'
 $remove=New-Object Windows.Forms.Button;$remove.SetBounds(12,275,190,28);$remove.Text=Get-QualityText 'Remove audio source' 'Remover fonte de áudio'
 Register-ButtonActionTooltip $remove
 $remove.Add_Click({
   $grid=$this.FindForm().Tag.AudioGrid;[void]$grid.EndEdit();$row=$grid.CurrentRow
   if($row -and -not $row.IsNewRow -and (Confirm-DeletionAuthorization $grid.FindForm() (Get-QualityText 'Remove audio source' 'Remover fonte de áudio'))){$grid.Rows.Remove($row)}
 })
 $s.AudioGrid=$grid;$s.RemoveAudio=$remove;$Dialog.Controls.AddRange(@($label,$grid,$remove))
}
