. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Recording_Metadata.ps1 - version 243.
Recording-context editing and persistence. Dialogs manage machine, operator, workpiece, tool and machining parameters, including reuse of previous/default context.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Fill missing context fields from defaults while preserving values already present.
function Complete-MetadataContext {
    param($Object,$Defaults)
    foreach ($property in $Defaults.PSObject.Properties) {
        $current=$Object.PSObject.Properties[$property.Name]
        if ($null -eq $current) { $Object | Add-Member NoteProperty $property.Name (Copy-SplitObject $property.Value) }
        elseif ($property.Value -is [pscustomobject]) {
            if ($null -eq $current.Value) { $current.Value=Copy-SplitObject $property.Value }
            elseif ($current.Value -isnot [pscustomobject]) { throw ('Invalid metadata: '+$property.Name) }
            else { Complete-MetadataContext $current.Value $property.Value }
        }
    }
}
# Collect, validate and save the recording-context dialog values.
function Save-RecordingMetadataDialog {
    param($Dialog)
    $c=$Dialog.Tag
    foreach ($rate in $c.Rates) {
        if ($rate.LastRole -eq 'Percent') { Sync-SplitRate $rate.Percent -Normalize }
        if (-not $rate.Valid) { throw $rate.Error }
    }
    foreach ($field in $c.Fields) {
        $value=$field.Input.Text
        if($field.Name -eq 'UsageTimeAtProgramStartMinutes'){$value=Convert-ToolUsageTime $value}
        elseif ($field.Numeric) {
            if ([string]::IsNullOrWhiteSpace($value)) { $value=$null }
            else {
                $number=0.0
                if (-not [double]::TryParse($value.Replace(',','.'),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
                    [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { throw (Get-QualityText 'Enter valid non-negative numeric values.' 'Introduza valores numéricos válidos, iguais ou superiores a zero.') }
                $value=$number
            }
        }
        Test-ToolContextValue $field.Name $value
        $field.Object.($field.Name)=$value
    }
    if($c.ContextEntry){
        if($c.ContextTimeValid -eq $false){throw (Get-QualityText 'Correct the context/program start time.' 'Corrija o tempo de início do contexto/programa.')}
        $entry=Copy-RecordingContextValue $c.ContextEntry
        $entry.timestamp_seconds=[double]$c.ContextStart.Value
        $entry.context=Copy-RecordingContextValue $c.Metadata.Context
        $entries=@($c.ContextEntries | Where-Object {$_.id -ne $entry.id})+@($entry)
        Save-PlaybackContexts $c.State $entries $c.ContextHash
        if($c.SaveDefaults.Checked){
            try { Save-DefaultRecordingContext $entry.context }
            catch { [void][Windows.Forms.MessageBox]::Show($Dialog,
                ((Get-QualityText 'Recording context/program saved, but the default context/program could not be updated: ' 'O contexto/programa da gravação foi guardado, mas não foi possível atualizar o contexto/programa predefinido: ')+$_.Exception.Message),$Dialog.Text,'OK','Warning') }
        }
        return
    }
    $currentHash=$null
    if (Test-Path -LiteralPath $c.Path) { $currentHash=(Get-FileHash -LiteralPath $c.Path -Algorithm SHA256).Hash }
    if ($currentHash -ne $c.OriginalHash) { throw (Get-QualityText 'Metadata changed outside this window. Cancel and reopen the editor.' 'Os metadados foram alterados fora desta janela. Cancele e volte a abrir o editor.') }
    if($c.State.IsDefaultContext){
        if($c.State.IsLiveContext){
            if(-not $script:RecordingUi.Running -or $script:RecordingUi.Stopping){throw (Get-QualityText 'Recording has ended. Edit the context in management.' 'A gravação terminou. Edite o contexto na gestão.')}
            $entries=@(Read-RecordingContexts $c.State.LiveFolder)
            $entries[0].context=Copy-RecordingContextValue $c.Metadata.Context
            Write-RecordingContexts $c.State.LiveFolder $entries
            $script:CompletedRecordingContext=Copy-SplitObject $c.Metadata.Context
            $script:RecordingUi.PlanContextManaged=$true
            if($c.SaveDefaults.Checked){Save-DefaultRecordingContext $c.Metadata.Context}
            return
        }
        if($c.SaveDefaults.Checked){Save-DefaultRecordingContext $c.Metadata.Context}
        $script:RecordingUi.PendingRecordingContext=Copy-SplitObject $c.Metadata.Context
        $c.State.Split.Metadata=Copy-SplitObject $c.Metadata
        return
    }
    $folder=Split-Path $c.Path -Parent
    $entries=@(Read-RecordingContexts $folder)
    $entries[0].context=Copy-RecordingContextValue $c.Metadata.Context
    # Keep in-memory context for the recorder; persist it only in contexts.json.
    Write-RecordingContexts $folder $entries
    $diskMetadata=Copy-SplitObject $c.Metadata
    $diskMetadata.PSObject.Properties.Remove('Context')
    Write-SplitJson $c.Path $diskMetadata
    $c.State.Split.Metadata=Copy-SplitObject $c.Metadata
    $owner=$c.State.VideoHost.FindForm()
    if ($null -ne $owner -and -not $c.State.IsRecordingContext) { $owner.Text=Get-QualityPlaybackTitle $c.State.Split.Folder }
    if($c.SaveDefaults.Checked){
        try { Save-DefaultRecordingContext $c.Metadata.Context }
        catch { [void][Windows.Forms.MessageBox]::Show($Dialog,
            ((Get-QualityText 'Recording context/program saved, but the default context/program could not be updated: ' 'O contexto/programa da gravação foi guardado, mas não foi possível atualizar o contexto/programa predefinido: ')+$_.Exception.Message),$Dialog.Text,'OK','Warning') }
    }
}
# Build the editor for machine, operator, workpiece, tool and machining context.
function New-RecordingMetadataDialog {
    param($State,$InitialContext)
    $path=Join-Path $State.Split.Folder 'metadata.json'
    if($State.IsDefaultContext){$path=Join-Path $PSScriptRoot 'context_defaults.json'}
    $hash=$null; $metadata=[pscustomobject]@{}
    if (Test-Path -LiteralPath $path) {
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if(-not $State.IsDefaultContext){
        $metadata=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $metadata -or $metadata -isnot [pscustomobject]) { throw 'Invalid metadata.json' }
        }
    }
    if($null -eq $InitialContext -and -not $State.IsDefaultContext -and (Test-Path -LiteralPath (Join-Path $State.Split.Folder 'contexts.json'))){
        $InitialContext=Copy-RecordingContextValue (@(Read-RecordingContexts $State.Split.Folder)[0].context)
    }
    $defaults=New-SplitContext $null
    if ($null -ne $InitialContext) { $metadata | Add-Member NoteProperty Context (Copy-SplitObject $InitialContext) -Force }
    if ($null -eq $metadata.Context) { $metadata | Add-Member NoteProperty Context (Copy-SplitObject $defaults) -Force }
    Complete-MetadataContext $metadata.Context $defaults
    $d=New-Object Windows.Forms.Form
    $d.Text=Get-QualityText 'Recording context/program' 'Contexto/programa da gravação'
    $d.ClientSize=New-Object Drawing.Size(960,710); $d.MinimumSize=New-Object Drawing.Size(976,500); $d.StartPosition='CenterParent'
    $panel=New-Object Windows.Forms.Panel; $panel.Dock='Fill'; $panel.AutoScroll=$true; $d.Controls.Add($panel)
    $bottom=New-Object Windows.Forms.Panel; $bottom.Dock='Bottom'; $bottom.Height=76; $d.Controls.Add($bottom)
    $name=New-Object Windows.Forms.Label
    $name.Text=(Get-QualityText 'Recording: ' 'Gravação: ')+[IO.Path]::GetFileName($State.Split.Folder.TrimEnd('\','/'))
    if($State.IsDefaultContext){$name.Text=Get-QualityText 'Context/program for the next recording.' 'Contexto/programa para a próxima gravação.'}
    $name.SetBounds(12,10,936,26); $name.AutoEllipsis=$true; $panel.Controls.Add($name)
    $fields=New-Object 'System.Collections.Generic.List[object]'
    $context=$metadata.Context
    $general=New-SplitEditorSection $panel (Get-UiText 'General data') 12 42 936 168
    $rows=@(@('Machine','Machine'),@('Operator','Operator'),@('Work','Program'),@('Part','Part'),@('PartMaterial','Part material'),@('Operation','Operation'))
    for ($i=0;$i -lt $rows.Count;$i++) {
        $null=Add-SplitEditorField $context $rows[$i][0] (Get-UiText $rows[$i][1]) $general $fields (12+($i%3)*312) (18+[int][Math]::Floor($i/3)*46) 288
    }
    $null=Add-SplitEditorField $context 'Strategy' (Get-UiText 'Strategy') $general $fields 12 110 912
    $tool=New-SplitEditorSection $panel (Get-QualityText 'Tool data' 'Dados da ferramenta') 12 218 412 258
    $rows=@(@('Tool','Name',12,18,188),@('Type','Type',212,18,188),@('Material','Material',12,64,388),@('HeightMm','Height (TH) [mm]',12,110,110),@('DiameterMm','Diameter (TD) [mm]',132,110,120),@('CornerRadiusMm','Corner radius (TR) [mm]',262,110,138),@('Flutes','Teeth/inserts (TZ)',12,156,388),@('UsageTimeAtProgramStartMinutes','Usage time at program start [hh:mm:ss]',12,202,388))
    for ($i=0;$i -lt $rows.Count;$i++) {
        $row=$rows[$i]
        $caption=switch($row[0]){
            'Tool' {Get-QualityText 'Name' 'Nome'}
            'HeightMm' {Get-QualityText 'Height (TH) [mm]' 'Altura (TH) [mm]'}
            'DiameterMm' {Get-QualityText 'Diameter (TD) [mm]' 'Diâmetro (TD) [mm]'}
            'CornerRadiusMm' {Get-QualityText 'Corner radius (TR) [mm]' 'Raio de canto (TR) [mm]'}
            'Flutes' {Get-QualityText 'Teeth/inserts (TZ)' 'Dentes/navalhas (TZ)'}
            default {Get-UiText $row[1]}
        }
        $null=Add-SplitEditorField $context.Tool $row[0] $caption $tool $fields $row[2] $row[3] $row[4] -Numeric:($i -ge 3)
    }
    $parameters=New-SplitEditorSection $panel (Get-UiText 'Machining parameters') 436 218 512 304
    $rates=@()
    $rates+=Add-SplitRateRow $context.Parameters.SpindleSpeed 'ProgrammedRpm' 'AdjustedRpm' (Get-QualityText 'Spindle speed (S)' 'Velocidade de rotação do fuso (S)') $parameters $fields 18
    $rates+=Add-SplitRateRow $context.Parameters.FeedRate 'ProgrammedMmPerMin' 'AdjustedMmPerMin' (Get-QualityText 'Feed rate (F)' 'Avanço (F)') $parameters $fields 112
    foreach($spec in @(@('Stock',12),@((Get-QualityText 'Increment' 'Incremento'),260))){
        $caption=New-Object Windows.Forms.Label
        $caption.Text=$spec[0]; $caption.SetBounds($spec[1],202,236,20); $parameters.Controls.Add($caption)
        $helpName=if($spec[1] -eq 12){'Stock'}else{'Increment'}
        Set-ContextFieldTooltip $caption $helpName
    }
    $stockFields=@(@('StkXY','StkXY [mm]',12),@('StkZ','StkZ [mm]',132),@('IncXY','IncXY [mm]',260),@('IncZ','IncZ [mm]',380))
    foreach($field in $stockFields){
        $null=Add-SplitEditorField $context.Parameters $field[0] $field[1] $parameters $fields $field[2] 222 110 -Numeric
    }
    $notes=Add-SplitEditorField $context 'Notes' (Get-UiText 'Notes') $panel $fields 12 534 936
    $notes.Multiline=$true; $notes.Height=64; $notes.ScrollBars='Vertical'
    $save=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $save; $save.Text=Get-QualityText 'Save' 'Guardar'; $save.SetBounds(12,38,100,30); $bottom.Controls.Add($save)
    $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text=Get-QualityText 'Cancel' 'Cancelar'; $cancel.SetBounds(120,38,100,30); $cancel.DialogResult='Cancel'; $bottom.Controls.Add($cancel); $d.CancelButton=$cancel
    $saveDefaults=New-Object Windows.Forms.CheckBox
    $saveDefaults.Text=Get-QualityText 'Also save as default context/program' 'Guardar também como contexto/programa predefinido'
    $saveDefaults.AutoSize=$true; $saveDefaults.Location=New-Object Drawing.Point(12,10)
    $bottom.Controls.Add($saveDefaults)
    Set-ContextFieldTooltip $saveDefaults 'SaveDefaults'
    $d.Tag=@{SaveDefaults=$saveDefaults;State=$State;Path=$path;OriginalHash=$hash;Metadata=$metadata;Fields=$fields;Rates=$rates;Save=$save;InitialFieldText=@{}}
    foreach($field in $fields){$d.Tag.InitialFieldText[$field.Input]=$field.Input.Text}
    $d.Add_FormClosing({
        param($sender,$eventArgs)
        if($sender.DialogResult -ne 'OK' -and (Test-RecordingContextDiscardConfirmation $sender)){
            if(-not (Confirm-DiscardRecordingContext $sender)){
                $eventArgs.Cancel=$true
                $sender.DialogResult='None'
            }
        }
    })
    $save.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        try { Save-RecordingMetadataDialog $d; $d.DialogResult='OK'; $d.Close() }
        catch { [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
    })
    return $d
}
# Check whether the current context editor requires a discard confirmation.
function Test-RecordingContextDiscardConfirmation {
    param($Dialog)
    if($Dialog.Tag.State.IsRecordingContext){
        if($Dialog.Tag.ContextEntry -and [double]$Dialog.Tag.ContextStart.Value -ne [double]$Dialog.Tag.ContextEntry.timestamp_seconds){return $true}
    foreach($field in $Dialog.Tag.Fields){
            if(-not [string]::IsNullOrWhiteSpace($field.Input.Text)){return $true}
        }
        return $false
    }
    return Test-RecordingContextChanged $Dialog
}
# Compare current context fields with their original values.
function Test-RecordingContextChanged {
    param($Dialog)
    if($Dialog.Tag.ContextEntry -and [double]$Dialog.Tag.ContextStart.Value -ne [double]$Dialog.Tag.ContextEntry.timestamp_seconds){return $true}
    foreach($field in $Dialog.Tag.Fields){
        $initial=$Dialog.Tag.InitialFieldText[$field.Input];$current=$field.Input.Text
        if($initial -ceq $current){continue}
        if($field.Numeric){
            try {
                $before=Read-SplitNumber $initial;$after=Read-SplitNumber $current
                if([object]::Equals($before,$after)){continue}
            } catch {}
        }
        return $true
    }
    return $false
}
# Build the localized message for discarding unsaved context edits.
function Get-DiscardRecordingContextMessage {
    param($Owner)
    if($Owner -and $Owner.Tag.ContextEntry){return Get-QualityText 'Discard these context/program changes?' 'Quer cancelar estas alterações ao contexto/programa?'}
    if($Owner -and $Owner.Tag.State.IsDefaultContext){return Get-QualityText 'Discard the context/program changes? Previously saved values will be kept.' 'Quer cancelar as alterações ao contexto/programa? Serão mantidos os valores guardados anteriormente.'}
    if($Owner -and -not $Owner.Tag.State.IsRecordingContext){
        return Get-QualityText 'Discard the context/program changes? The context/program already saved will be kept.' 'Quer cancelar as alterações ao contexto/programa? Será mantido o contexto/programa já guardado.'
    }
    return Get-QualityText 'Discard this context/program? The context/program for this recording will remain unchanged.' 'Quer cancelar este contexto/programa? O contexto/programa desta gravação permanecerá inalterado.'
}
# Ask the operator before discarding edited recording context.
function Confirm-DiscardRecordingContext {
    param($Owner)
    return ([Windows.Forms.MessageBox]::Show($Owner,(Get-DiscardRecordingContextMessage $Owner),
        (Get-QualityText 'Discard context/program' 'Cancelar contexto/programa'),'YesNo','Warning','Button2') -eq 'Yes')
}
# Retrieve reusable context from saved defaults or previous recordings.
function Get-LastRecordingContext {
    param([string]$DefaultsFolder=$PSScriptRoot,[string]$RecordingsFolder)
    # Migration from the console recorder's last entered values.
    $legacy=Join-Path $DefaultsFolder 'context_defaults.json'
    if(Test-Path -LiteralPath $legacy){
        $saved=Get-Content -LiteralPath $legacy -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if($saved.Values){
            $context=New-SplitContext $null
            $mapping=Get-RecordingContextDefaultMapping
            foreach($key in $mapping.Keys){
                $property=$saved.Values.PSObject.Properties[$key]; if(-not $property){continue}
                $parts=$mapping[$key].Split('.');$target=$context
                for($i=0;$i -lt $parts.Count-1;$i++){$target=$target.($parts[$i])}
                $value=$property.Value
                if($mapping[$key] -match '^Parameters\.|Mm$|Flutes$|Percent$|Minutes$'){$value=Read-SplitNumber ([string]$value)}
                $target.($parts[-1])=$value
            }
            return $context
        }
    }
    $last=Join-Path $DefaultsFolder 'last_recording_context.json'
    if(Test-Path -LiteralPath $last){
        $context=Get-Content -LiteralPath $last -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        Complete-MetadataContext $context (New-SplitContext $null)
        return $context
    }
    return New-SplitContext $null
}

# Ask whether to reuse the previous recording's context.
function Confirm-LastRecordingContext {
    param($Owner)
    return ([Windows.Forms.MessageBox]::Show($Owner,
        (Get-QualityText 'Use the last context/program for this recording? You can review and edit it before saving.' 'Quer utilizar o último contexto/programa nesta gravação? Poderá revê-lo e editá-lo antes de guardar.'),
        (Get-QualityText 'Recording context/program' 'Contexto/programa da gravação'),'YesNo','Question') -eq 'Yes')
}

# Offer the context editor after capture has ended and persist the resulting metadata.
function Complete-FinishedRecordingContext {
    param([string]$Folder,[string]$RecordingsFolder)
    $u=$script:RecordingUi
    if(-not (Confirm-LastRecordingContext $u.Form)){return}
    $context=Get-LastRecordingContext -RecordingsFolder $RecordingsFolder
    $state=@{Split=@{Folder=$Folder;Metadata=$null};VideoHost=$u.VideoHost;IsRecordingContext=$true}
    $dialog=$null
    try {
        $dialog=New-RecordingMetadataDialog $state $context
        if($dialog.ShowDialog($u.Form) -eq 'OK'){
            $script:CompletedRecordingContext=Copy-SplitObject $state.Split.Metadata.Context
        }
    } finally {if($dialog){$dialog.Dispose()}}
}
# Add the recording-information action to the playback window.
function Add-RecordingMetadataControls {
    param($Panel)
    $state=$Panel.Tag
    $button=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $button; $button.Text=Get-QualityText 'Contexts/programs' 'Contextos/programas'
    $button.SetBounds(($state.PlaybackSettingsButton.Right+4),66,116,30); $button.Enabled=$false; $button.Tag=$state
    $state.PlaybackSettingsButton.Parent.Controls.Add($button); $state.MetadataButton=$button
    $button.Add_Click({
        param($sender,$eventArgs)
        $state=$sender.Tag
        if (-not $state.Clock.Ready -or $state.Seeking -or $state.Dragging -or $null -ne $state.PendingSeek) { return }
        $d=$null
        try { Show-PlaybackContexts $state }
        catch { Show-QualityError $_.Exception.Message }
        finally { if ($null -ne $d) { $d.Dispose() } }
    })
}

# Map context properties to their saved default-setting names.
function Get-RecordingContextDefaultMapping {
    return @{
                'Machine'='Machine';'Operator'='Operator';'Work'='Work';'Part'='Part';'Part material'='PartMaterial';'Operation'='Operation';'Strategy'='Strategy';'Notes'='Notes';
                'Tool'='Tool.Tool';'Tool type'='Tool.Type';'Tool material'='Tool.Material';'Tool height [mm]'='Tool.HeightMm';'Tool diameter [mm]'='Tool.DiameterMm';'Tool corner radius [mm]'='Tool.CornerRadiusMm';'Tool flutes'='Tool.Flutes';'Tool remaining use [%]'='Tool.RemainingUsePercent';'Tool usage time at program start [min]'='Tool.UsageTimeAtProgramStartMinutes';
                'Stock StkXY [mm]'='Parameters.StkXY';'Stock StkZ [mm]'='Parameters.StkZ';'Increment IncXY [mm]'='Parameters.IncXY';'Increment IncZ [mm]'='Parameters.IncZ';
                'Programmed spindle speed [rpm]'='Parameters.SpindleSpeed.ProgrammedRpm';'Spindle speed adjustment [%]'='Parameters.SpindleSpeed.AdjustmentPercent';'Adjusted spindle speed [rpm]'='Parameters.SpindleSpeed.AdjustedRpm';
                'Programmed feed rate [mm/min]'='Parameters.FeedRate.ProgrammedMmPerMin';'Feed rate adjustment [%]'='Parameters.FeedRate.AdjustmentPercent';'Adjusted feed rate [mm/min]'='Parameters.FeedRate.AdjustedMmPerMin'
            }
}
# Ask whether the current context should become the default for future recordings.
function Confirm-UpdateDefaultRecordingContext {
    param($Owner)
    return ([Windows.Forms.MessageBox]::Show($Owner,
        (Get-QualityText 'Also update the default context/program with these values?' 'Quer também atualizar o contexto/programa predefinido com estes valores?'),
        (Get-QualityText 'Default recording context/program' 'Contexto/programa predefinido da gravação'),'YesNo','Question','Button2') -eq 'Yes')
}
# Persist selected context fields as defaults for subsequent recordings.
function Save-DefaultRecordingContext {
    param($Context,[string]$DefaultsFolder=$PSScriptRoot)
    $path=Join-Path $DefaultsFolder 'context_defaults.json'
    $saved=[pscustomobject]@{}
    if(Test-Path -LiteralPath $path){$saved=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}
    $values=[ordered]@{}
    $mapping=Get-RecordingContextDefaultMapping
    foreach($key in ($mapping.Keys|Sort-Object)){
        $value=$Context
        foreach($part in $mapping[$key].Split('.')){$value=$value.$part}
        if($null -eq $value){$values[$key]=''}
        elseif($value -is [ValueType]){$values[$key]=[Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture)}
        else{$values[$key]=[string]$value}
    }
    $saved|Add-Member NoteProperty Values ([pscustomobject]$values) -Force
    Write-SplitJson $path $saved
}

# Edit defaults before capture, without creating recording metadata.
function Show-DefaultRecordingContext {
    $u=$script:RecordingUi
    if($u.Stopping){return}
    $state=@{Split=@{Folder=$PSScriptRoot;Metadata=$null};VideoHost=$u.VideoHost;IsDefaultContext=$true;IsRecordingContext=$false}
    if($u.Running){$state.IsLiveContext=$true;$state.LiveFolder=$script:outputPath}
    $dialog=$null
    try {
        $context=if($null -ne $u.PendingRecordingContext){Copy-SplitObject $u.PendingRecordingContext}else{Get-LastRecordingContext}
        if($state.IsLiveContext){
            if(Test-Path -LiteralPath (Join-Path $state.LiveFolder 'contexts.json')){$context=Copy-RecordingContextValue (@(Read-RecordingContexts $state.LiveFolder)[0].context)}
            elseif($null -ne $script:CompletedRecordingContext){$context=Copy-SplitObject $script:CompletedRecordingContext}
            else{$context=New-EmptyRecordingContext}
        }
        $dialog=New-RecordingMetadataDialog $state $context
        [void]$dialog.ShowDialog($u.Form)
    } finally {if($dialog){$dialog.Dispose()}}
}
