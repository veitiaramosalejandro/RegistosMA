. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Reference_Selection.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
#Requires -Version 5.1
# Version 243. Complete context snapshots on the playback time axis.
# This module has no import-time UI or recording side effects.
. (Join-Path $PSScriptRoot 'Deletion_Authorization.ps1')
function Copy-RecordingContextValue {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 40 | ConvertFrom-Json)
}
function New-EmptyRecordingContext {
    return [pscustomobject]@{Machine='';Operator='';Work='';Part='';PartMaterial='';Operation='';Strategy='';
        Tool=[pscustomobject]@{Tool='';Type='';Material='';HeightMm=$null;DiameterMm=$null;CornerRadiusMm=$null;Flutes=$null;RemainingUsePercent=$null;UsageTimeAtProgramStartMinutes=$null};
        Parameters=[pscustomobject]@{StkXY=$null;StkZ=$null;IncXY=$null;IncZ=$null;SpindleSpeed=[pscustomobject]@{ProgrammedRpm=$null;AdjustmentPercent=100;AdjustedRpm=$null};
        FeedRate=[pscustomobject]@{ProgrammedMmPerMin=$null;AdjustmentPercent=100;AdjustedMmPerMin=$null}};Notes=''}
}
function Complete-RecordingContextValue {
    param($Value,$Defaults=(New-EmptyRecordingContext))
    if($Value -isnot [pscustomobject]){throw 'Contexto inválido / Invalid context.'}
    foreach($property in $Defaults.PSObject.Properties){
        $p=$Value.PSObject.Properties[$property.Name]
        if($null -eq $p){$Value | Add-Member NoteProperty $property.Name (Copy-RecordingContextValue $property.Value)}
        elseif($property.Value -is [pscustomobject]){
            if($null -eq $p.Value){$p.Value=Copy-RecordingContextValue $property.Value}
            else{Complete-RecordingContextValue $p.Value $property.Value}
        }
    }
}
function Test-RecordingContexts {
    param([AllowEmptyCollection()][object[]]$Entries,[double]$Duration=[double]::MaxValue)
    $ids=@{};$times=@{}
    if(-not $Entries.Count){throw 'É necessário um contexto inicial / An initial context is required.'}
    foreach($e in $Entries){
        if($e -isnot [pscustomobject] -or $e.id -isnot [string] -or [string]::IsNullOrWhiteSpace($e.id) -or $e.timestamp_seconds -isnot [ValueType]){throw 'Registo de contexto inválido / Invalid context entry.'}
        $t=[double]$e.timestamp_seconds
        if([double]::IsNaN($t) -or [double]::IsInfinity($t) -or $t -lt 0 -or ($t -ge $Duration -and $t -ne 0)){throw 'O início do contexto deve estar dentro da gravação / Context start must be inside the recording.'}
        $key=$t.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        if($ids.ContainsKey($e.id) -or $times.ContainsKey($key)){throw 'Já existe um contexto neste instante / A context already exists at this time.'}
        $ids[$e.id]=$true;$times[$key]=$true
        Complete-RecordingContextValue $e.context
        foreach($name in @('Machine','Operator','Work','Part','PartMaterial','Operation','Strategy','Notes')){if($e.context.$name -isnot [string]){throw ('Invalid context field: '+$name)}}
        foreach($name in @('StkXY','StkZ','IncXY','IncZ')){
            $v=$e.context.Parameters.$name
            if($null -ne $v -and ($v -isnot [ValueType] -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or [double]$v -lt 0)){throw 'Invalid context parameter.'}
        }
        foreach($rate in @($e.context.Parameters.SpindleSpeed,$e.context.Parameters.FeedRate)){
            foreach($p in $rate.PSObject.Properties){if($null -ne $p.Value -and ($p.Value -isnot [ValueType] -or [double]::IsNaN([double]$p.Value) -or [double]::IsInfinity([double]$p.Value) -or [double]$p.Value -lt 0)){throw 'Invalid context parameter.'}}
        }
        foreach($name in @('HeightMm','DiameterMm','CornerRadiusMm','Flutes','RemainingUsePercent','UsageTimeAtProgramStartMinutes')){
            $v=$e.context.Tool.$name
            if($null -ne $v -and ($v -isnot [ValueType] -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or $v -lt 0)){throw 'Invalid tool parameter.'}
            if($null -ne $v -and (($name -eq 'Flutes' -and ($v -lt 1 -or $v -ne [Math]::Truncate($v))) -or ($name -eq 'RemainingUsePercent' -and $v -gt 100))){throw 'Invalid tool parameter.'}
        }
    }
    if(-not $times.ContainsKey('0')){throw 'O contexto inicial deve começar em zero / Initial context must start at zero.'}
}
function Read-RecordingContexts {
    param([string]$Folder)
    $path=Join-Path $Folder 'contexts.json'
    if(Test-Path -LiteralPath $path){
        $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if($data.schema_version -ne 1 -or $data.time_reference -ne 'playback_seconds' -or $data.contexts -isnot [array]){throw 'contexts.json inválido / Invalid contexts.json.'}
        $entries=@($data.contexts)
    }else{
        $context=New-EmptyRecordingContext
        $metadataPath=Join-Path $Folder 'metadata.json'
        if(Test-Path -LiteralPath $metadataPath){
            $meta=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if($null -ne $meta.Context){$context=Copy-RecordingContextValue $meta.Context}
        }
        $entries=@([pscustomobject]@{id='initial';timestamp_seconds=0.0;context=$context})
    }
    Test-RecordingContexts $entries
    return @($entries | Sort-Object timestamp_seconds)
}
function Get-RecordingContextAt {
    param([object[]]$Entries,[double]$Seconds)
    return ($Entries | Where-Object {$_.timestamp_seconds -le $Seconds} | Sort-Object timestamp_seconds | Select-PlaybackReference)
}
function Get-RecordingContextsHash {
    param([string]$Folder)
    # Include metadata because it is the implicit initial context of legacy recordings.
    return (@(foreach($name in @('metadata.json','contexts.json','events.json','quality_annotations.json')){
        $p=Join-Path $Folder $name
        if(Test-Path -LiteralPath $p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}else{'-'}
    }) -join ':')
}
# Remove the legacy duplicate only after the timeline on disk has been validated.
function Remove-LegacyMetadataContext {
    param([string]$Folder)
    if(-not (Test-Path -LiteralPath (Join-Path $Folder 'contexts.json'))){return}
    $null=@(Read-RecordingContexts $Folder)
    $path=Join-Path $Folder 'metadata.json'
    if(-not (Test-Path -LiteralPath $path)){return}
    $meta=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if($meta -isnot [pscustomobject]){throw 'Invalid metadata.json'}
    if($meta.PSObject.Properties['Context']){
        $meta.PSObject.Properties.Remove('Context')
        Write-SplitJson $path $meta
    }
}
function Write-RecordingContexts {
    param([string]$Folder,[object[]]$Entries,[double]$Duration=[double]::MaxValue)
    $copy=@(Copy-RecordingContextValue @($Entries))
    Test-RecordingContexts $copy $Duration
    $path=Join-Path $Folder 'contexts.json';$tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $data=[ordered]@{schema_version=1;time_reference='playback_seconds';contexts=@($copy | Sort-Object timestamp_seconds)}
        [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $data -Depth 40),(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($path)){
            try{[IO.File]::Replace($tmp,$path,$path+'.bak')}
            catch [UnauthorizedAccessException]{
                # Match the existing metadata writer on filesystems without Replace permission.
                [IO.File]::Copy($path,$path+'.bak',$true);[IO.File]::Copy($tmp,$path,$true)
            }
        }else{[IO.File]::Move($tmp,$path)}
    }finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
    Remove-LegacyMetadataContext $Folder
}
function Save-PlaybackContexts {
    param($State,[object[]]$Entries,[string]$ExpectedHash)
    $folder=Split-Path $State.Path -Parent
    if((Get-RecordingContextsHash $folder) -ne $ExpectedHash){throw 'A gravação foi alterada fora desta janela. Volte a abrir os contextos / Recording changed outside this window. Reopen contexts.'}
    Test-RecordingContexts $Entries $State.Duration
    # Freeze legacy event intentions against the OLD baseline before changing it.
    $events=@(Read-QualityAnnotations $State.Path)
    if(Test-Path -LiteralPath $State.Path){Save-QualityAnnotations $State.Path $events}
    Write-RecordingContexts $folder $Entries $State.Duration
    $State.ContextEntries=@(Read-RecordingContexts $folder)
    $State.Items=@(Read-QualityAnnotations $State.Path)
    if($State.Split){
        if($null -eq $State.Split.Metadata){$State.Split.Metadata=[pscustomobject]@{}}
        $State.Split.Metadata | Add-Member NoteProperty Context (Copy-RecordingContextValue $State.ContextEntries[0].context) -Force
    }
    $State.DisplayContextId=$null
    Update-QualityList $State
    Update-CurrentMachiningLabels $State (Get-QualityPosition $State)
    $State.Timeline.Invalidate()
}
function Get-SplitRecordingContexts {
    param([object[]]$Entries,[double]$Start,[double]$End,$InitialContext)
    $initial=Get-RecordingContextAt $Entries $Start
    $context=$initial.context;if($null -ne $InitialContext){$context=$InitialContext}
    $result=@([pscustomobject]@{id=[guid]::NewGuid().ToString('N');timestamp_seconds=0.0;context=(Copy-RecordingContextValue $context)})
    foreach($entry in $Entries){
        if($entry.timestamp_seconds -gt $Start -and $entry.timestamp_seconds -lt $End){
            $copy=Copy-RecordingContextValue $entry;$copy.timestamp_seconds=[Math]::Round($entry.timestamp_seconds-$Start,6);$result+=$copy
        }
    }
    return $result
}
# Reuse the validated machining-context form; its save path is redirected to this timeline.
function Update-PlaybackContextDuration {
    param($Dialog)
    $c=$Dialog.Tag
    if(-not $c.ContextDurationClock){return}
    if($c.ContextTimeValid -eq $false){foreach($key in @('ContextDurationClock','ContextDurationSeconds','ContextEndClock','ContextEndSeconds','ContextAbsoluteStart','ContextAbsoluteEnd')){if($c[$key]){$c[$key].Text='-'}};return}
    $start=[double]$c.ContextStart.Value;$end=[double]$c.State.Duration
    foreach($entry in @($c.ContextEntries)){
        if($entry.id -ne $c.ContextEntry.id -and [double]$entry.timestamp_seconds -gt $start){$end=[Math]::Min($end,[double]$entry.timestamp_seconds)}
    }
    $duration=[Math]::Max(0.0,$end-$start)
    $c.ContextDurationClock.Text=Format-AnnotationTime $duration
    $c.ContextDurationSeconds.Text=$duration.ToString('0.###',[Globalization.CultureInfo]::CurrentCulture)
    if($c.ContextEndClock){$c.ContextEndClock.Text=Format-AnnotationTime $end;$c.ContextEndSeconds.Text=$end.ToString('0.###',[Globalization.CultureInfo]::CurrentCulture)}
    if($c.ContextAbsoluteStart){
        $c.ContextAbsoluteStart.Text='-';$c.ContextAbsoluteEnd.Text='-'
        if($null -ne $c.State.RecordingStart){$c.ContextAbsoluteStart.Text=$c.State.RecordingStart.AddSeconds($start).ToString('yyyy-MM-dd HH:mm:ss.fff');$c.ContextAbsoluteEnd.Text=$c.State.RecordingStart.AddSeconds($end).ToString('yyyy-MM-dd HH:mm:ss.fff')}
    }
}
function Sync-PlaybackContextStart {
    param($Dialog,[string]$Source)
    $c=$Dialog.Tag
    if($c.ContextTimeSync){return}
    $c.ContextTimeSync=$true
    try{
        if($Source -eq 'Clock'){
            $time=Convert-AnnotationTime $c.ContextClock.Text 'Clock' $c.State.Duration
            if($time -gt 0 -and $time -ge $c.State.Duration){throw 'Start must precede the end.'}
            $c.ContextStart.Value=[decimal][Math]::Round($time,3)
        }else{$c.ContextClock.Text=Format-AnnotationTime ([double]$c.ContextStart.Value)}
        if($c.ContextStart.Value -gt 0 -and $c.ContextStart.Value -ge $c.State.Duration){throw 'Start must precede the end.'}
        $c.ContextTimeValid=$true;$c.ContextClock.BackColor=[Drawing.SystemColors]::Window
        $c.Save.Enabled=$true
    }catch{$c.ContextTimeValid=$false;$c.ContextClock.BackColor=[Drawing.Color]::MistyRose;$c.Save.Enabled=$false}
    finally{$c.ContextTimeSync=$false;Update-PlaybackContextDuration $Dialog}
}

function Show-PlaybackContextEditor {
    param($State,$Entry=$null)
    $folder=Split-Path $State.Path -Parent
    $entries=@(Read-RecordingContexts $folder);$hash=Get-RecordingContextsHash $folder
    $time=[Math]::Round([Math]::Max(0,[Math]::Min($State.Duration,(Get-QualityPosition $State))),3)
    if($null -eq $Entry){
        if($time -ge $State.Duration){throw 'Escolha um instante anterior ao fim da gravação / Choose a time before the end.'}
        $current=Get-RecordingContextAt $entries $time
        $Entry=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');timestamp_seconds=$time;context=(Copy-RecordingContextValue $current.context)}
    }else{$Entry=Copy-RecordingContextValue $Entry}
    $d=New-RecordingMetadataDialog $State $Entry.context
    try{
        $d.Text=Get-QualityText 'Context/program from this time' 'Contexto/programa a partir deste momento'
        $d.Tag.ContextEntry=$Entry;$d.Tag.ContextEntries=$entries;$d.Tag.ContextHash=$hash
        $d.Tag.SaveDefaults.Visible=$true
        # Reuse the same top row as the extraction context editor.
        $panel=$d.Controls | Where-Object {$_.Dock -eq 'Fill'} | Select-PlaybackReference -First
        foreach($control in $panel.Controls){if($control.Top -ge 42){$control.Top+=106}}
        $d.ClientSize=New-Object Drawing.Size($d.ClientSize.Width,($d.ClientSize.Height+106))
        $d.MinimumSize=New-Object Drawing.Size($d.MinimumSize.Width,($d.MinimumSize.Height+106))
        $strip=New-ContextEditorTimeStrip $panel $Entry.timestamp_seconds $State.Duration $State.Duration -ContextMode
        $d.Tag.ContextStart=$strip.Times.Start.Seconds;$d.Tag.ContextClock=$strip.Times.Start.Clock
        $d.Tag.ContextEndClock=$strip.Times.End.Clock;$d.Tag.ContextEndSeconds=$strip.Times.End.Seconds
        $d.Tag.ContextAbsoluteStart=$strip.AbsoluteStart;$d.Tag.ContextAbsoluteEnd=$strip.AbsoluteEnd
        $d.Tag.ContextDurationClock=$strip.DurationClock;$d.Tag.ContextDurationSeconds=$strip.DurationSeconds
        $d.Tag.ContextTimeValid=$true;$d.Tag.ContextTimeSync=$false
        $d.Tag.ContextStart.Enabled=$Entry.timestamp_seconds -ne 0;$d.Tag.ContextClock.Enabled=$d.Tag.ContextStart.Enabled
        $d.Tag.ContextClock.Add_TextChanged({param($sender,$eventArgs) Sync-PlaybackContextStart $sender.FindForm() 'Clock'})
        $d.Tag.ContextStart.Add_ValueChanged({param($sender,$eventArgs) Sync-PlaybackContextStart $sender.FindForm() 'Seconds'})
        Update-PlaybackContextDuration $d
        [void]$d.ShowDialog($State.VideoHost.FindForm())
    }finally{$d.Dispose()}
}
function Update-PlaybackContextList {
    param($Dialog)
    $s=$Dialog.Tag.State;$entries=@(Read-RecordingContexts (Split-Path $s.Path -Parent));$list=$Dialog.Tag.List
    $list.Items.Clear()
    for($i=0;$i -lt $entries.Count;$i++){
        $e=$entries[$i];$endSeconds=[double]$s.Duration
        if($i+1 -lt $entries.Count){$endSeconds=[double]$entries[$i+1].timestamp_seconds}
        $hour='-'
        if($null -ne $s.RecordingStart){$hour=$s.RecordingStart.AddSeconds([double]$e.timestamp_seconds).ToString('HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)}
        $time=Format-AnnotationTime $e.timestamp_seconds
        $duration=Format-AnnotationTime ([Math]::Max(0.0,$endSeconds-[double]$e.timestamp_seconds))
        $notes=([string]$e.context.Notes -replace '[\r\n\t]+',' ').Trim()
        $row=New-Object Windows.Forms.ListViewItem($hour)
        foreach($v in @($time,$duration,$e.context.Machine,$e.context.Work,$e.context.Operation,$e.context.Tool.Tool,$e.context.Tool.Type,$notes)){[void]$row.SubItems.Add([string]$v)}
        $row.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap(([string]$e.context.Notes))
        $row.Tag=$e;[void]$list.Items.Add($row)
    }
    $Dialog.Tag.Hash=Get-RecordingContextsHash (Split-Path $s.Path -Parent)
}
# Selection-dependent actions never silently operate on the first of several contexts.
function Initialize-PlaybackContextColumns {
    param($Dialog)
    $Dialog.Tag.ColumnLayoutPath=Join-Path $PSScriptRoot 'context_columns.json'
    try{
        if(Test-Path -LiteralPath $Dialog.Tag.ColumnLayoutPath){
            $saved=Get-Content -LiteralPath $Dialog.Tag.ColumnLayoutPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $widths=@($saved.widths)
            # Map existing seven-column preferences around the new Duration column.
            if($saved.schema_version -eq 1 -and $widths.Count -eq 7 -and $Dialog.Tag.List.Columns.Count -eq 9){
                $widths=@($widths[0],$widths[1],$Dialog.Tag.List.Columns[2].Width)+@($widths[2..6])+@($Dialog.Tag.List.Columns[8].Width)
            }
            if($saved.schema_version -in @(1,2) -and $widths.Count -eq 9){$widths=@(110,$widths[0])+@($widths[2..8])}
            if($saved.schema_version -notin @(1,2,3) -or $widths.Count -ne $Dialog.Tag.List.Columns.Count){return}
            foreach($width in $widths){if($width -isnot [ValueType] -or $width -lt 30 -or $width -gt 3000 -or $width -ne [Math]::Truncate($width)){return}}
            for($i=0;$i -lt $widths.Count;$i++){$Dialog.Tag.List.Columns[$i].Width=[int]$widths[$i]}
        }
    }catch{ }
}
function Save-PlaybackContextColumns {
    param($Dialog)
    $widths=@($Dialog.Tag.List.Columns | ForEach-Object {$_.Width})
    Write-SplitJson $Dialog.Tag.ColumnLayoutPath ([pscustomobject]@{schema_version=3;widths=$widths})
}
function Update-PlaybackContextActions {
    param($Dialog)
    $selected=@($Dialog.Tag.List.SelectedItems)
    $buttons=$Dialog.Tag.ActionButtons
    $buttons.Edit.Enabled=$selected.Count -eq 1
    $buttons.Seek.Enabled=$selected.Count -eq 1
    $buttons.Delete.Enabled=@($selected | Where-Object {$_.Tag.timestamp_seconds -gt 0}).Count -gt 0
}
function Get-PlaybackContextRemovalMessage {
    param($Dialog)
    $selected=@($Dialog.Tag.List.SelectedItems)
    $removable=@($selected | Where-Object {$_.Tag.timestamp_seconds -gt 0} | Sort-Object {$_.Tag.timestamp_seconds})
    $lines=New-Object 'System.Collections.Generic.List[string]'
    if($removable.Count -eq 1){$lines.Add((Get-QualityText 'Delete this context/program change?' 'Pretende eliminar esta mudança de contexto/programa?'))}
    else{$lines.Add((Get-QualityText ('Delete these '+$removable.Count+' context changes?') ('Pretende eliminar estas '+$removable.Count+' mudanças de contexto?')))}
    $lines.Add('')
    foreach($row in @($removable | Select-Object -First 12)){
        $e=$row.Tag;$name=([string]$e.context.Work -replace '[\r\n\t]',' ').Trim()
        if(-not $name){$name=([string]$e.context.Operation -replace '[\r\n\t]',' ').Trim()}
        if(-not $name){$name=Get-QualityText 'Unnamed context/program' 'Contexto/programa sem nome'}
        if($name.Length -gt 100){$name=$name.Substring(0,97)+'...'}
        $lines.Add('  '+(Format-AnnotationTime $e.timestamp_seconds)+' - '+$name)
    }
    if($removable.Count -gt 12){$lines.Add((Get-QualityText ('  ... and '+($removable.Count-12)+' more.') ('  ... e mais '+($removable.Count-12)+'.')))}
    $lines.Add('')
    if(@($selected | Where-Object {$_.Tag.timestamp_seconds -eq 0}).Count){$lines.Add((Get-QualityText 'The selected initial context/program will be kept.' 'O contexto/programa inicial selecionado será mantido.'));$lines.Add('')}
    $lines.Add((Get-QualityText 'Previous contexts/programs will extend to the next remaining context/program, or to the end of the recording.' 'Os contextos/programas anteriores prolongam-se até ao contexto/programa seguinte que permanecer, ou até ao fim da gravação.'))
    $lines.Add((Get-QualityText 'Audio, video and events will be kept.' 'O áudio, o vídeo e os eventos serão mantidos.'))
    return ($lines -join [Environment]::NewLine)
}
function Confirm-PlaybackContextRemoval {
    param($Dialog,[int]$Count)
    if(-not ([Windows.Forms.MessageBox]::Show($Dialog,(Get-PlaybackContextRemovalMessage $Dialog),(Get-QualityText 'Delete contexts/programs' 'Eliminar contextos/programas'),'YesNo','Warning','Button2') -eq 'Yes')){return $false}
    return Confirm-DeletionAuthorization $Dialog 'Eliminar contextos'
}
function Select-PlaybackContextForPosition {
    param($Dialog)
    $s=$Dialog.Tag.State;$time=Get-QualityPosition $s
    if($null -ne $s.List -and $s.List.SelectedItems.Count -eq 1){$time=[double]$s.List.SelectedItems[0].Tag.timestamp_seconds}
    $rows=@($Dialog.Tag.List.Items)
    $entry=Get-RecordingContextAt @($rows | ForEach-Object {$_.Tag}) $time
    if($null -eq $entry){return}
    foreach($row in $rows){
        $row.Selected=$row.Tag.id -eq $entry.id
        if($row.Selected){$row.Focused=$true;$row.EnsureVisible()}
    }
    Update-PlaybackContextActions $Dialog
}
function Show-PlaybackContexts {
    param($State)
    if(-not $State.Clock.Ready -or $State.Seeking -or $State.Dragging -or $null -ne $State.PendingSeek){return}
    if(-not $State.Paused){Switch-QualityPause $State}
    $d=New-Object Windows.Forms.Form
    try{
        $d.Text=Get-QualityText 'Recording contexts/programs' 'Contextos/programas da gravação';$area=[Windows.Forms.Screen]::FromControl($State.VideoHost).WorkingArea;$d.ClientSize=New-Object Drawing.Size(([Math]::Min(1400,$area.Width-40)),370);$d.MinimumSize=New-Object Drawing.Size(976,300);$d.StartPosition='CenterParent';$d.Font=$State.VideoHost.FindForm().Font
        $note=New-Object Windows.Forms.Label;$note.Text=Get-QualityText 'Each context/program remains active until the next one. Select multiple rows to delete several changes.' 'Cada contexto/programa mantém-se até ao seguinte. Selecione várias linhas para eliminar várias mudanças.';$note.SetBounds(12,12,($d.ClientSize.Width-24),28);$note.Anchor='Top,Left,Right';$d.Controls.Add($note)
        $list=New-Object Windows.Forms.ListView; Register-ListTooltipLayout $list;$list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$true;$list.HideSelection=$false;$list.ShowItemToolTips=$false;$list.SetBounds(12,48,($d.ClientSize.Width-24),260);$list.Anchor='Top,Bottom,Left,Right';$d.Controls.Add($list)
        foreach($c in @(@('Clock time','Hora',110),@('Time','Tempo',110),@('Duration','Duração',100),@('Machine','Máquina',160),@('Program','Programa',155),@('Operation','Operação',160),@('Tool','Ferramenta',140),@('Type','Tipo',140),@('Notes','Notas',280))){[void]$list.Columns.Add((Get-QualityText $c[0] $c[1]),$c[2])}
        $d.Tag=@{State=$State;List=$list;Hash=$null;ActionButtons=@{}}
        Initialize-PlaybackContextColumns $d
        $d.Add_FormClosing({param($sender,$eventArgs)
            try{Save-PlaybackContextColumns $sender}catch{Show-QualityError $_.Exception.Message}
        })
        $x=12
        foreach($spec in @(@('Add','Add at current time','Adicionar neste momento',360),@('Edit','Edit','Editar',100),@('Delete','Delete','Eliminar',100),@('Seek','Position','Posicionar',120),@('Close','Close','Fechar',100))){
            $b=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $b;$b.Name=$spec[0];$b.Text=Get-QualityText $spec[1] $spec[2]
            if($spec[0] -eq 'Add'){$b.Text+=' ('+(Format-AnnotationTime (Get-QualityPosition $State))+')'}
            $width=[Math]::Max($spec[3],([Windows.Forms.TextRenderer]::MeasureText($b.Text,$d.Font)).Width+16)
            $b.SetBounds($x,324,$width,32);$b.Anchor='Bottom,Left';$x+=$width+8;$d.Controls.Add($b);$d.Tag.ActionButtons[$spec[0]]=$b
            if($spec[0] -eq 'Edit'){$d.Tag.EditButton=$b}
            $b.Add_Click({param($sender,$eventArgs)
                $dialog=$sender.FindForm();$s=$dialog.Tag.State;$list=$dialog.Tag.List
                $selected=@($list.SelectedItems);$entry=$null
                if($selected.Count -eq 1){$entry=$selected[0].Tag}
                try{
                    Update-PlaybackContextActions $dialog
                    if(-not $sender.Enabled){return}
                    if($sender.Name -in @('Edit','Delete') -and (Get-RecordingContextsHash (Split-Path $s.Path -Parent)) -ne $dialog.Tag.Hash){throw 'A gravação foi alterada fora desta janela. Feche e volte a abrir os contextos / Recording changed. Close and reopen contexts.'}
                    switch($sender.Name){
                        'Close'{$dialog.Close();return}
                        'Add'{Show-PlaybackContextEditor $s}
                        'Edit'{if($entry){Show-PlaybackContextEditor $s $entry}}
                        'Delete'{if($selected.Count -gt 0){
                            $removable=@($selected | Where-Object {$_.Tag.timestamp_seconds -gt 0})
                            if(-not $removable.Count){return}
                            if(Confirm-PlaybackContextRemoval $dialog $removable.Count){
                                $ids=@($removable | ForEach-Object {$_.Tag.id})
                                $entries=@(Read-RecordingContexts (Split-Path $s.Path -Parent) | Where-Object {$_.id -notin $ids})
                                Save-PlaybackContexts $s $entries $dialog.Tag.Hash
                            }
                        }}
                        'Seek'{if($entry){Request-QualitySeek $s ([double]$entry.timestamp_seconds) -CenterTimeline;$dialog.Close();return}}
                    }
                    Update-PlaybackContextList $dialog
                    Update-PlaybackContextActions $dialog
                }catch{Show-QualityError $_.Exception.Message}
            })
        }
        $d.MinimumSize=New-Object Drawing.Size(([Math]::Max($d.MinimumSize.Width,$x+4+($d.Width-$d.ClientSize.Width))),$d.MinimumSize.Height)
        $list.Add_SelectedIndexChanged({param($sender,$eventArgs) Update-PlaybackContextActions $sender.FindForm()})
        # Register once and reuse the same edit action for double-clicks.
        $list.Add_DoubleClick({param($sender,$eventArgs)
            if($sender.SelectedItems.Count -eq 1){$sender.FindForm().Tag.EditButton.PerformClick()}
        })
        Update-PlaybackContextList $d
        Update-PlaybackContextActions $d
        $d.Add_Shown({param($sender,$eventArgs) Select-PlaybackContextForPosition $sender})
        [void]$d.ShowDialog($State.VideoHost.FindForm())
    }finally{$d.Dispose()}
}
