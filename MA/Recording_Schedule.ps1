. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Recording_Schedule.ps1 - version 168.
Scheduling/timing behavior introduced after version 123. Shared runtime state lives in $script:RecordingUi.
Schedule status values are controller data; localization is applied when displaying them.
Comments describe the current behavior.
#>
# Keep stored scheduling states unchanged; translate only their display text.
# Translate display labels, including historical completion messages, without changing stored state values used by the controller.
. (Join-Path $PSScriptRoot 'Deletion_Authorization.ps1')
function Get-RecordingScheduleStatusText {
    param([string]$Status)
    $parts=$Status -split ' — ',2
    $label=switch($parts[0]){
        {$_ -in @('Pendente','Pending')} {Get-QualityText 'Pending' 'Pendente';break}
        {$_ -in @('A iniciar','Starting')} {Get-QualityText 'Starting' 'A iniciar';break}
        {$_ -in @('Em curso','In progress')} {Get-QualityText 'In progress' 'Em curso';break}
        {$_ -in @('Não realizado','Não executada','Not performed')} {Get-QualityText 'Not performed' 'Não realizado';break}
        {$_ -in @('Falhou','Failed')} {Get-QualityText 'Failed' 'Falhou';break}
        {$_ -in @('Terminada','Finished')} {Get-QualityText 'Finished' 'Terminada';break}
        {$_ -in @('Gravação terminada com sucesso','Recording completed successfully')} {Get-QualityText 'Recording completed successfully' 'Gravação terminada com sucesso';break}
        {$_ -in @('A gravação terminou com erro','Recording failed')} {Get-QualityText 'Recording failed' 'A gravação terminou com erro';break}
        default {$parts[0]}
    }
    if($parts.Count -gt 1){return $label+' — '+$parts[1]}
    return $label
}
# Default to one hour after the planned start, the active recording start, or the current time for an idle manual timer.
function Get-DefaultRecordingPlanEnd {
    param([switch]$Scheduled,[datetime]$Start)
    if($Scheduled){return $Start.AddHours(1)}
    $u=$script:RecordingUi
    if($u.Running -and $u.State.RecordingStart){return ([datetime]$u.State.RecordingStart).AddHours(1)}
    return [datetime]::Now.AddHours(1)
}
. (Join-Path $PSScriptRoot 'Recording_Timing.ps1')
. (Join-Path $PSScriptRoot 'Recording_Limits.ps1')
# Manual timer and independent queue of scheduled recordings.
# Duration plans use the actual media start; explicit end-date plans retain their absolute deadlines.
function Get-RecordingPlanEnd {
    param($Plan,[datetime]$Start)
    if($Plan.Seconds){return $Start.AddSeconds([double]$Plan.Seconds)}
    if($Plan.Minutes){return $Start.AddMinutes([double]$Plan.Minutes)}
    return [datetime]$Plan.End
}
# Edit a copy of the plan in a modal dialog. Only Save returns a replacement; cancellation preserves the existing plan.
function Edit-RecordingPlan {
    param([switch]$Scheduled,$Plan)
    $u=$script:RecordingUi
    $d=New-Object Windows.Forms.Form;$d.Text=if($Scheduled){Get-QualityText 'Schedule' 'Agendamento'}else{Get-QualityText 'Timer' 'Temporizador'}
    $d.ClientSize=New-Object Drawing.Size(520,310);$d.StartPosition='CenterParent';$d.FormBorderStyle='FixedDialog';$d.MaximizeBox=$false;$d.MinimizeBox=$false;$d.Font=$u.Form.Font
    $label=New-Object Windows.Forms.Label;$label.SetBounds(16,12,488,24);$label.Text=Get-QualityText 'Start date and time' 'Data e hora de início'
    $start=New-Object Windows.Forms.DateTimePicker;$start.SetBounds(16,40,488,28);$start.Format='Custom';$start.CustomFormat='dd/MM/yyyy HH:mm:ss';$suggestedStart=[datetime]::Now.AddMinutes(5);$start.Value=$suggestedStart.Date.AddHours($suggestedStart.Hour).AddMinutes($suggestedStart.Minute)
    $start.Enabled=[bool]$Scheduled
    if(-not $Scheduled){$label.Text=Get-QualityText 'Applies to a manually started recording' 'Aplicar à gravação iniciada manualmente'}
    $kind=New-Object Windows.Forms.ComboBox;$kind.SetBounds(16,82,488,28);$kind.DropDownStyle='DropDownList';$kind.Items.AddRange(@((Get-QualityText 'End date and time' 'Data e hora de fim'),(Get-QualityText 'Duration (hh:mm:ss)' 'Duração (hh:mm:ss)'),(Get-QualityText 'Duration (seconds)' 'Duração (segundos)')));$kind.SelectedIndex=0
    $end=New-Object Windows.Forms.DateTimePicker;$end.SetBounds(16,122,488,28);$end.Format='Custom';$end.CustomFormat='dd/MM/yyyy HH:mm:ss';$end.Value=Get-DefaultRecordingPlanEnd -Scheduled:$Scheduled -Start $start.Value
    $minutes=New-Object Windows.Forms.TextBox;$minutes.SetBounds(16,122,488,28);$minutes.Text='01:00:00';$minutes.Visible=$false
    # Updating suppresses programmatic ValueChanged events; ManualEnd protects an explicitly chosen end from start-time changes.
    $editor=@{Updating=$true;ManualEnd=$false;Mode=0;DefaultSeconds=3600}
    if($Plan){
        if($Plan.Start){$start.Value=[datetime]$Plan.Start}
        $end.Value=[datetime]$Plan.End
        if($Plan.Seconds -or $Plan.Minutes){
            $seconds=if($Plan.Seconds){$Plan.Seconds}else{$Plan.Minutes*60}
            $minutes.Text=Format-RecordingDuration $seconds;$kind.SelectedIndex=1;$editor.Mode=1;$editor.DefaultSeconds=$seconds
        }else{$editor.ManualEnd=$true}
    }
    $editor.Updating=$false
    # Only a user-driven end change locks the absolute end; synchronization changes run with Updating set.
    $end.Add_ValueChanged({if(-not $editor.Updating){$editor.ManualEnd=$true}})
    $start.Add_ValueChanged({
        if($editor.Updating){return}
        if($kind.SelectedIndex -gt 0){
            try{$seconds=ConvertTo-RecordingDurationSeconds $minutes.Text -SecondsOnly:($kind.SelectedIndex -eq 2)}catch{return}
        }elseif($editor.ManualEnd){return}else{$seconds=$editor.DefaultSeconds}
        $editor.Updating=$true
        try{$end.Value=$start.Value.AddSeconds($seconds)}finally{$editor.Updating=$false}
    })
    # Convert between seconds and clock duration, or recompute the absolute end when returning to date/time mode.
    $kind.Add_SelectedIndexChanged({
        if($editor.Updating){return}
        $previous=[int]$editor.Mode
        $begin=if($Scheduled){$start.Value}elseif($u.Running){[datetime]$u.State.RecordingStart}else{[datetime]::Now}
        if($previous -gt 0){
            try{$value=ConvertTo-RecordingDurationSeconds $minutes.Text -SecondsOnly:($previous -eq 2)}catch{
                Show-QualityError $_.Exception.Message
                $editor.Updating=$true;try{$kind.SelectedIndex=$previous}finally{$editor.Updating=$false};return
            }
        }elseif(-not $editor.ManualEnd){$value=[double]$editor.DefaultSeconds}
        else{$value=[Math]::Max([double]1,($end.Value-$begin).TotalSeconds);$value=[Math]::Round($value)}
        $editor.Updating=$true
        try{
            if($kind.SelectedIndex -eq 0){$end.Value=$begin.AddSeconds($value);$editor.ManualEnd=$false;$editor.DefaultSeconds=$value}
            elseif($kind.SelectedIndex -eq 2){$minutes.Text=[string]$value}
            else{$minutes.Text=Format-RecordingDuration $value}
            $editor.Mode=$kind.SelectedIndex
            $end.Visible=($kind.SelectedIndex -eq 0);$minutes.Visible=($kind.SelectedIndex -gt 0)
        }finally{$editor.Updating=$false}
    })
    $end.Visible=($kind.SelectedIndex -eq 0);$minutes.Visible=($kind.SelectedIndex -gt 0)
    $note=New-Object Windows.Forms.Label;$note.SetBounds(16,160,488,46);$note.Text=Get-QualityText 'Duration counts from the actual recording start. Keep the application open and the computer awake.' 'A duração conta desde o início efetivo. Mantenha a aplicação aberta e o computador ativo.'
    $reuse=New-Object Windows.Forms.CheckBox;$reuse.SetBounds(16,212,488,32);$reuse.Text=Get-QualityText 'Use the last context/program for this recording' 'Utilizar o último contexto/programa nesta gravação'
    if($Plan){$reuse.Checked=[bool]$Plan.UseLastContext}else{$reuse.Checked=$true}
    $ok=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $ok;$ok.SetBounds(270,262,110,32);$ok.Text=Get-QualityText 'Save' 'Guardar'
    $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel;$cancel.SetBounds(392,262,112,32);$cancel.Text=Get-QualityText 'Cancel' 'Cancelar';$cancel.DialogResult='Cancel';$d.CancelButton=$cancel
    # Validate the selected input before returning a new plan; do not mutate the saved queue while editing.
    $ok.Add_Click({
        $now=[datetime]::Now
        $begin=if($Scheduled){$start.Value}elseif($u.Running){$u.State.RecordingStart}else{$now}
                $durationSeconds=$null
        if($kind.SelectedIndex -gt 0){try{$durationSeconds=ConvertTo-RecordingDurationSeconds $minutes.Text -SecondsOnly:($kind.SelectedIndex -eq 2)}catch{Show-QualityError $_.Exception.Message;return}}
        $planEnd=if($durationSeconds){$begin.AddSeconds($durationSeconds)}else{$end.Value}
        if(($Scheduled -and $begin -le $now) -or $planEnd -le $begin -or $planEnd -le $now){Show-QualityError (Get-QualityText 'Check start and end: the end must be in the future and after the start.' 'Verifique o início e o fim: o fim deve estar no futuro e ser posterior ao início.');return}
        $d.Tag=[pscustomobject]@{Start=$(if($Scheduled){$begin}else{$null});End=$planEnd;Seconds=$durationSeconds;Minutes=$null;UseLastContext=$reuse.Checked;Status='Pendente'}
        $d.DialogResult='OK';$d.Close()
    })
    # The manual timer omits the planned start field and provides a separate action to remove the timer.
    if(-not $Scheduled){
        $clear=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $clear;$clear.SetBounds(16,262,240,32);$clear.Text=Get-QualityText 'Remove timer' 'Remover temporizador'
        $clear.Enabled=[bool]$u.ManualTimer
        $clear.Add_Click({if(-not(Confirm-DeletionAuthorization $d (Get-QualityText 'Remove timer' 'Remover temporizador'))){return};$u.ManualTimer=$null;if(-not $u.ActiveSchedule){$u.ActiveEnd=$null};$d.Close()})
        $d.Controls.Add($clear)
    }
    $d.Controls.AddRange(@($label,$start,$kind,$end,$minutes,$note,$reuse,$ok,$cancel))
    # The manual timer omits the planned start field and provides a separate action to remove the timer.
    if(-not $Scheduled){
        $label.Visible=$false;$start.Visible=$false
        foreach($control in @($kind,$end,$minutes,$note,$reuse,$ok,$cancel,$clear)){$control.Top-=70}
        $d.ClientSize=New-Object Drawing.Size(520,240)
    }
    try{if($d.ShowDialog($u.Form) -eq 'OK'){return $d.Tag}}finally{$d.Dispose()}
}
# Configure the manual timer before or during capture. An active scheduled capture owns its own deadline and cannot use this editor.
function Show-RecordingTimer {
    $u=$script:RecordingUi
    if($u.Stopping -or $u.Ready -or $u.ActiveSchedule){return}
    $plan=Edit-RecordingPlan -Plan $u.ManualTimer
    if($plan){$u.ManualTimer=$plan;if($u.Running){$u.ActiveEnd=Get-RecordingPlanEnd $plan $u.State.RecordingStart;Set-RecordingPlanContext $plan}}
}
# Persist queue changes and rebuild the list. Derive duration from start/end when no explicit duration was selected.
function Refresh-RecordingScheduleList {
    $u=$script:RecordingUi
    Save-RecordingSchedules
    if(-not $u.ScheduleList -or $u.ScheduleList.IsDisposed){return}
    $u.ScheduleList.Items.Clear()
    foreach($plan in $u.ScheduleQueue){
        $item=New-Object Windows.Forms.ListViewItem(([datetime]$plan.Start).ToString('dd/MM/yyyy HH:mm:ss'))
        [void]$item.SubItems.Add(([datetime]$plan.End).ToString('dd/MM/yyyy HH:mm:ss'))
        [void]$item.SubItems.Add($(if($plan.Seconds){(Format-RecordingDuration $plan.Seconds)+' / '+$plan.Seconds+' s'}elseif($plan.Minutes){[string]$plan.Minutes+' min'}else{$seconds=([datetime]$plan.End-[datetime]$plan.Start).TotalSeconds;(Format-RecordingDuration $seconds)+' / '+([long][Math]::Round($seconds))+' s'}))
        [void]$item.SubItems.Add((Get-RecordingScheduleStatusText ([string]$plan.Status)));$item.Tag=$plan;[void]$u.ScheduleList.Items.Add($item)
    }
}
# Manage the queue with add, edit, double-click edit and remove actions. Active entries cannot be removed.
function Set-RecordingScheduleColumns {
    param($List)
    if($List.Columns.Count -ne 4){return}
    $dateWidth=[Windows.Forms.TextRenderer]::MeasureText('00/00/0000 00:00:00',$List.Font).Width+12
    $durationWidth=[Windows.Forms.TextRenderer]::MeasureText('00:00:30 / 30 s',$List.Font).Width+12
    $List.Columns[0].Width=$dateWidth;$List.Columns[1].Width=$dateWidth;$List.Columns[2].Width=$durationWidth
    $List.Columns[3].Width=[Math]::Max(120,$List.ClientSize.Width-2*$dateWidth-$durationWidth-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth-4)
}
function Show-RecordingSchedules {
    $u=$script:RecordingUi
    $d=New-Object Windows.Forms.Form;$d.Text=Get-QualityText 'Schedules' 'Agendamentos';$d.ClientSize=New-Object Drawing.Size(800,350);$d.StartPosition='CenterParent';$d.Font=$u.Form.Font;$d.MinimumSize=$d.Size
    $list=New-Object Windows.Forms.ListView; Register-ListTooltipLayout $list;$list.SetBounds(12,12,776,240);$list.Anchor='Top,Bottom,Left,Right';$list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false
    $list.Font=$d.Font
    foreach($title in @((Get-QualityText 'Start' 'Início'),(Get-QualityText 'End' 'Fim'),(Get-QualityText 'Duration' 'Duração'),(Get-QualityText 'Status' 'Estado'))){[void]$list.Columns.Add($title,120)}
    Set-RecordingScheduleColumns $list
    $list.Add_ClientSizeChanged({Set-RecordingScheduleColumns $this})
    $u.ScheduleList=$list
    $add=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $add;$add.SetBounds(12,266,140,32);$add.Text=Get-QualityText 'Add' 'Adicionar'
    $edit=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $edit;$edit.SetBounds(164,266,140,32);$edit.Text=Get-QualityText 'Edit' 'Editar'
    $remove=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $remove;$remove.SetBounds(316,266,140,32);$remove.Text=Get-QualityText 'Remove' 'Remover'
    $add.Add_Click({$plan=Edit-RecordingPlan -Scheduled;if($plan){if(Test-RecordingPlanOverlap $plan){return};$u.ScheduleQueue.Add($plan);Refresh-RecordingScheduleList}})
    $edit.Add_Click({if($list.SelectedItems.Count -eq 0){return};$old=$list.SelectedItems[0].Tag;if($old.Status -ne 'Pendente'){return};$plan=Edit-RecordingPlan -Scheduled -Plan $old;if($plan){if(Test-RecordingPlanOverlap $plan $old){return};$i=$u.ScheduleQueue.IndexOf($old);$u.ScheduleQueue[$i]=$plan;Refresh-RecordingScheduleList}})
    $list.Add_DoubleClick({$edit.PerformClick()})
    $remove.Add_Click({if($list.SelectedItems.Count){$plan=$list.SelectedItems[0].Tag;if($plan -eq $u.ActiveSchedule){return};if(-not(Confirm-DeletionAuthorization $d (Get-QualityText 'Remove schedule' 'Remover agendamento'))){return};$u.ScheduleQueue.Remove($plan);Refresh-RecordingScheduleList}})
    $note=New-Object Windows.Forms.Label;$note.SetBounds(12,310,776,32);$note.Text=Get-QualityText 'Schedules are saved automatically.' 'Os agendamentos são guardados automaticamente.'
    $d.Controls.AddRange(@($list,$add,$edit,$remove,$note));Refresh-RecordingScheduleList
    try{[void]$d.ShowDialog($u.Form)}finally{$u.ScheduleList=$null;$d.Dispose()}
}
# Reject overlapping pending intervals; completed and missed history does not reserve recording time.
function Test-RecordingPlanOverlap {
    param($Plan,$Except)
    foreach($other in $script:RecordingUi.ScheduleQueue){if($other -eq $Except -or $other.Status -ne 'Pendente'){continue};if($Plan.Start -lt $other.End -and $Plan.End -gt $other.Start){Show-QualityError (Get-QualityText 'This schedule overlaps another pending recording.' 'Este agendamento sobrepõe-se a outra gravação pendente.');return $true}}
    return $false
}
# Reset only the active capture state, preserving the manual timer and saved queue. Report an unfinished active plan before clearing it.
function Clear-RecordingSchedule {
    $u=$script:RecordingUi
    if($u.ActiveSchedule -and $u.ActiveSchedule.Status -in @('A iniciar','Em curso')){Complete-RecordingPlan $false ([datetime]::Now) 'Gravação interrompida ou não iniciada.'}
    $u.ActiveSchedule=$null;$u.ActiveEnd=$null;$u.ScheduleObservedRunning=$false;$u.PlanResultReported=$false;$u.PlanContextManaged=$false
    Refresh-RecordingScheduleList
}
# Service due entries and deadlines on the UI thread, then refresh idle text and button colors. Recovery blocks automatic starts until the user answers.
function Update-RecordingSchedule {
    $u=$script:RecordingUi;$now=[datetime]::Now
    if($u.ScheduleRecoveryPending -or $u.ScheduleRecoveryBusy){return}
    foreach($plan in @($u.ScheduleQueue | Sort-Object Start)){
        if($plan.Status -ne 'Pendente' -or $now -lt $plan.Start){continue}
        if($u.Running -or $u.Ready -or $u.ControllerBusy -or $now -ge $plan.End){$plan.Status='Não realizado';Refresh-RecordingScheduleList;continue}
        $plan.Status='A iniciar';$u.ActiveSchedule=$plan
        $u.Start.PerformClick()
        if(-not $u.Ready){$plan.Status='Falhou';$u.ActiveSchedule=$null}
        Refresh-RecordingScheduleList
    }
    if($u.Running -and -not $u.MediaStarted){
        if($u.ActiveSchedule){$u.ActiveEnd=[datetime]$u.ActiveSchedule.End}
        elseif($u.ManualTimer -and -not $u.ManualTimer.Seconds -and -not $u.ManualTimer.Minutes){$u.ActiveEnd=[datetime]$u.ManualTimer.End}
        else{$u.ActiveEnd=$null}
    }
    if($u.Running -and $u.MediaStarted -and -not $u.ScheduleObservedRunning){
        $u.ScheduleObservedRunning=$true;$u.LastRecordingResult=$null;$u.PlanResultReported=$false
        if($u.ActiveSchedule){$u.ActiveSchedule.Status='Em curso';$u.ActiveEnd=Get-RecordingPlanEnd $u.ActiveSchedule $u.State.RecordingStart;Refresh-RecordingScheduleList}
        elseif($u.ManualTimer){$u.ActiveEnd=Get-RecordingPlanEnd $u.ManualTimer $u.State.RecordingStart}
    }
    $activePlan=$u.ManualTimer;if($u.ActiveSchedule){$activePlan=$u.ActiveSchedule}
    $targetSeconds=Get-RecordingPlanSeconds $activePlan
    $u.TargetDurationSeconds=$targetSeconds
    $shouldStop=if($null -ne $targetSeconds){Test-RecordingDurationReached $script:captureLogMonitor $targetSeconds}else{$u.ActiveEnd -and $now -ge $u.ActiveEnd}
    if($u.Running -and $shouldStop -and -not $u.Stopping){
        Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stop.flag') -Value 'stop' -ErrorAction Stop
        $u.Stopping=$true;$u.Stop.Enabled=$false;$u.Event.Enabled=$false
    }
    Save-RecordingSchedules
    $u.IdleRecordingText=Get-RecordingIdleText
    if($u.Status -and -not $u.Running){$u.ScheduleTip.SetToolTip($u.Status,$u.IdleRecordingText)}
    # Missed entries take red priority; an all-pending queue is blue; other nonempty queues remain green.
    if($u.SchedulesButton){
        if($u.ScheduleQueue.Count -gt 0){
            $u.SchedulesButton.UseVisualStyleBackColor=$false
            $u.SchedulesButton.BackColor=if(Get-LastMissedRecordingSchedule){[Drawing.Color]::FromArgb(200,45,45)}elseif(@($u.ScheduleQueue | Where-Object {$_.Status -ne 'Pendente'}).Count -eq 0){[Drawing.Color]::FromArgb(0,120,215)}else{[Drawing.Color]::FromArgb(0,153,76)}
            $u.SchedulesButton.ForeColor=[Drawing.Color]::White
        }else{
            $u.SchedulesButton.BackColor=[Drawing.SystemColors]::Control
            $u.SchedulesButton.ForeColor=[Drawing.SystemColors]::ControlText
            $u.SchedulesButton.UseVisualStyleBackColor=$true
        }
    }
    $u.TimerButton.Text=Get-QualityText 'Timer' 'Temporizador'
    # Blue indicates a configured manual timer; removing it restores the standard appearance.
    if($u.ManualTimer){
        $u.TimerButton.UseVisualStyleBackColor=$false
        $u.TimerButton.BackColor=[Drawing.Color]::FromArgb(0,120,215)
        $u.TimerButton.ForeColor=[Drawing.Color]::White
    }else{
        $u.TimerButton.BackColor=[Drawing.SystemColors]::Control
        $u.TimerButton.ForeColor=[Drawing.SystemColors]::ControlText
        $u.TimerButton.UseVisualStyleBackColor=$true
    }
    $u.TimerButton.Enabled=(-not $u.ActiveSchedule -and -not $u.Stopping -and -not $u.Ready)
    $u.ScheduleTip.SetToolTip($u.TimerButton,$(if($u.ManualTimer){if($u.ManualTimer.Seconds){(Format-RecordingDuration $u.ManualTimer.Seconds)+' / '+$u.ManualTimer.Seconds+' s'}elseif($u.ManualTimer.Minutes){[string]$u.ManualTimer.Minutes+' min'}else{([datetime]$u.ManualTimer.End).ToString('dd/MM/yyyy HH:mm:ss')}}else{Get-QualityText 'No automatic stop' 'Sem paragem automática'}))
}
# Connect controls, load saved entries and defer recovery prompts until the form is shown. Save again when the form closes.
function Initialize-RecordingSchedule {
    $u=$script:RecordingUi
    $u.ScheduleQueue=New-Object 'System.Collections.Generic.List[object]';$u.ManualTimer=$null
    $u.TimerButton.Add_Click({Show-RecordingTimer})
    $u.SchedulesButton.Add_Click({Show-RecordingSchedules})
    $u.ScheduleTip=New-Object MachiningMonitor.WrappingToolTip
    $context=New-Object Windows.Forms.ContextMenuStrip
    $clear=$context.Items.Add((Get-QualityText 'Clear timer' 'Remover temporizador'))
    $clear.Add_Click({$u=$script:RecordingUi;if(-not(Confirm-DeletionAuthorization $u.Form (Get-QualityText 'Remove timer' 'Remover temporizador'))){return};$u.ManualTimer=$null;if(-not $u.ActiveSchedule){$u.ActiveEnd=$null}})
    $u.TimerButton.ContextMenuStrip=$context
    $u.Form.Add_FormClosed({Save-RecordingSchedules;$script:RecordingUi.ScheduleTip.Dispose()})
    $u.ScheduleFile=Join-Path $PSScriptRoot 'recording_schedules.json'
    Read-RecordingSchedules
    $u.ScheduleRecoveryPending=$true
    $u.Form.Add_Shown({Resolve-RecordingScheduleRecovery;Update-RecordingSchedule})
    Clear-RecordingSchedule
}


# Write only changed JSON, using a temporary file and a previous-version backup. A storage error stops further writes to protect existing data.
function Save-RecordingSchedules {
    $u=$script:RecordingUi
    if(-not $u.ScheduleFile -or $u.ScheduleStorageError){return}
    # Cache the serialized queue so frequent controller ticks do not repeatedly write unchanged data.
    $json=ConvertTo-Json -InputObject @($u.ScheduleQueue.ToArray()) -Depth 8
    if($json -eq $u.SavedScheduleJson){return}
    $temporary=$u.ScheduleFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($true)))
        # Preserve the previous saved queue before replacing the destination with the completed temporary file.
        if([IO.File]::Exists($u.ScheduleFile)){[IO.File]::Copy($u.ScheduleFile,($u.ScheduleFile+'.bak'),$true);[IO.File]::Copy($temporary,$u.ScheduleFile,$true)}else{[IO.File]::Move($temporary,$u.ScheduleFile)}
        $u.SavedScheduleJson=$json
    }catch{
        $u.ScheduleStorageError=$true
        Show-QualityError ((Get-QualityText 'Unable to save schedules: ' 'Não foi possível guardar os agendamentos: ')+$_.Exception.Message)
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
# Load and validate the whole queue before replacing it. Normalize UTC values to local time and recover interrupted states as pending.
function Read-RecordingSchedules {
    $u=$script:RecordingUi
    if(-not [IO.File]::Exists($u.ScheduleFile)){return}
    try{
        $saved=Get-Content -LiteralPath $u.ScheduleFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $loaded=New-Object 'System.Collections.Generic.List[object]'
        foreach($plan in @($saved)){
            if($null -eq $plan){continue}
            $plan.Start=[datetime]$plan.Start;$plan.End=[datetime]$plan.End
            # Windows PowerShell JSON loading can produce UTC DateTime values; comparisons elsewhere use local wall-clock time.
            if($plan.Start.Kind -eq [DateTimeKind]::Utc){$plan.Start=$plan.Start.ToLocalTime()}
            if($plan.End.Kind -eq [DateTimeKind]::Utc){$plan.End=$plan.End.ToLocalTime()}
            if($plan.End -le $plan.Start){throw 'Intervalo de agendamento inválido.'}
            if($plan.Status -in @('A iniciar','Em curso')){$plan.Status='Pendente'}
            if($plan.Status -eq 'Não executada'){$plan.Status='Não realizado'}
            $loaded.Add($plan)
        }
        $u.ScheduleQueue=$loaded
    }catch{
        $u.ScheduleStorageError=$true
        Show-QualityError ((Get-QualityText 'Unable to read saved schedules. The file was preserved: ' 'Não foi possível ler os agendamentos guardados. O ficheiro foi preservado: ')+$_.Exception.Message)
    }
}
# Ask permission to start an interval missed while the application was closed, displaying its original start and fixed end.
function Confirm-RecordingScheduleRecovery {
    param($Plan)
    $message=(Get-QualityText 'A scheduled recording should be in progress. Start now and finish at the scheduled end?' 'Uma gravação agendada deveria estar a decorrer. Pretende iniciá-la agora e terminar à hora programada?')
    $seconds=Get-RecordingPlanSeconds $Plan
    if($null -ne $seconds){$message=(Get-QualityText 'Start the missed recording now with its full duration?' 'Pretende iniciar agora a gravação agendada, com a duração completa?')+' '+(Format-RecordingDuration $seconds)}
    $message+="`r`n"+([datetime]$Plan.Start).ToString('dd/MM/yyyy HH:mm:ss')+' — '+([datetime]$Plan.End).ToString('dd/MM/yyyy HH:mm:ss')
    return ([Windows.Forms.MessageBox]::Show($script:RecordingUi.Form,$message,(Get-QualityText 'Scheduled recording' 'Gravação agendada'),'YesNo','Question') -eq 'Yes')
}
# Handle overdue entries once at startup: expire or decline as not performed; accepted active entries follow their duration or absolute-end rule.
function Resolve-RecordingScheduleRecovery {
    $u=$script:RecordingUi
    if(-not $u.ScheduleRecoveryPending -or $u.ScheduleRecoveryBusy){return}
    $u.ScheduleRecoveryBusy=$true
    try{
        foreach($plan in @($u.ScheduleQueue | Sort-Object Start)){
            if($plan.Status -ne 'Pendente' -or [datetime]::Now -lt $plan.Start){continue}
            if([datetime]::Now -ge $plan.End){$plan.Status='Não realizado';continue}
            if(-not (Confirm-RecordingScheduleRecovery $plan)){$plan.Status='Não realizado';continue}
            if([datetime]::Now -ge $plan.End -or $u.Running -or $u.Ready){$plan.Status='Não realizado';continue}
            $plan.Status='A iniciar';$u.ActiveSchedule=$plan
            $u.Start.PerformClick()
            if(-not $u.Ready){$plan.Status='Falhou';$u.ActiveSchedule=$null}
        }
    }finally{
        $u.ScheduleRecoveryPending=$false;$u.ScheduleRecoveryBusy=$false
        Refresh-RecordingScheduleList
        $u.IdleRecordingText=Get-RecordingIdleText
    if($u.Status -and -not $u.Running){$u.ScheduleTip.SetToolTip($u.Status,$u.IdleRecordingText)}
    }
}
