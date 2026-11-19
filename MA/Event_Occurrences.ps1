# Atomic event occurrence options shared by the v315 PowerShell editor and the service contract.
function Get-EventOccurrenceOptions {
    @(
        [pscustomobject]@{id='ExecutionStarted';label=(Get-QualityText 'Execution started' 'Início da execução');value=1}
        [pscustomobject]@{id='ExecutionCompleted';label=(Get-QualityText 'Execution completed' 'Execução concluída');value=2}
        [pscustomobject]@{id='ExecutionAborted';label=(Get-QualityText 'Execution aborted' 'Execução abortada');value=3}
        [pscustomobject]@{id='SpindleAdjusted';label=(Get-QualityText 'Spindle adjustment' 'Ajuste de rotação');value=5}
        [pscustomobject]@{id='FeedAdjusted';label=(Get-QualityText 'Feed adjustment' 'Ajuste de avanço');value=6}
        [pscustomobject]@{id='ToolChange';label=(Get-QualityText 'Tool change' 'Troca de ferramenta');value=7}
        [pscustomobject]@{id='ToolMeasurement';label=(Get-QualityText 'Tool measurement' 'Medição de ferramenta');value=16}
        [pscustomobject]@{id='MachineActivityChanged';label=(Get-QualityText 'Machine activity change' 'Alteração de atividade da máquina');value=17}
        [pscustomobject]@{id='MachineStateChanged';label=(Get-QualityText 'Machine state change' 'Alteração de estado da máquina');value=18}
        [pscustomobject]@{id='ToolUsageTimeChanged';label=(Get-QualityText 'Tool usage time change' 'Alteração do tempo de utilização da ferramenta');value=15}
        [pscustomobject]@{id='AlarmRaised';label=(Get-QualityText 'Alarm raised' 'Alarme ativado');value=8}
        [pscustomobject]@{id='AlarmCleared';label=(Get-QualityText 'Alarm cleared' 'Alarme limpo');value=9}
        [pscustomobject]@{id='QualityClassificationChanged';label=(Get-QualityText 'Quality classification' 'Classificação de qualidade');value=10}
        [pscustomobject]@{id='ActualSpindleSpeedChanged';label=(Get-QualityText 'Read spindle speed' 'Rotação lida');value=11}
        [pscustomobject]@{id='ActualFeedRateChanged';label=(Get-QualityText 'Read feed rate' 'Avanço lido');value=12}
        [pscustomobject]@{id='SPowerChanged';label=(Get-QualityText 'Read S power' 'Potência S lida');value=13}
        [pscustomobject]@{id='WPowerChanged';label=(Get-QualityText 'Read W power' 'Potência W lida');value=14}
    )
}

function Get-OccurrenceValueKind {
    param([string]$Occurrence)
    if($Occurrence -in @('ExecutionStarted','ExecutionCompleted','ExecutionAborted','ToolChange','ToolMeasurement','AlarmRaised','AlarmCleared')){return 'None'}
    if($Occurrence -in @('QualityClassificationChanged','MachineStateChanged','MachineActivityChanged')){return 'Enum'}
    return 'Number'
}

function Get-OccurrenceEnumOptions {
    param([string]$Occurrence)
    if($Occurrence -eq 'QualityClassificationChanged'){@(0..5|ForEach-Object{[pscustomobject]@{id=[string]$_;label=(Get-QualityDisplay $_)}});return}
    if($Occurrence -eq 'MachineStateChanged'){@((Get-MachineStates).states|ForEach-Object{[pscustomobject]@{id=$_.id;label=$_.label}});return}
    if($Occurrence -eq 'MachineActivityChanged'){@((Get-MachineActivities).activities|ForEach-Object{[pscustomobject]@{id=$_.id;label=$_.label}});return}
    @()
}

function Test-EventOccurrences {
    param($Item)
    if($null -eq $Item.PSObject.Properties['occurrence']){return}
    if($Item.occurrence -isnot [string] -or [string]::IsNullOrWhiteSpace($Item.occurrence)){throw 'Invalid occurrence / Ocorrência inválida.'}
    if(@(Get-EventOccurrenceOptions | Where-Object id -eq ([string]$Item.occurrence)).Count -ne 1){throw 'Invalid occurrence / Ocorrência inválida.'}
}

function Add-EventOccurrencesEditor {
    param($Dialog,$Old=$null)
    $label=New-Object Windows.Forms.Label;$label.Text=Get-QualityText 'Occurrence' 'Ocorrência';$label.SetBounds(12,133,468,20);$Dialog.Controls.Add($label)
    $list=New-Object Windows.Forms.ComboBox;$list.DropDownStyle='DropDownList';$list.DisplayMember='label';$list.SetBounds(12,155,468,25);$Dialog.Controls.Add($list)
    foreach($option in Get-EventOccurrenceOptions){$null=$list.Items.Add($option)}
    $selected=[string]$Old.occurrence
    if([string]::IsNullOrWhiteSpace($selected) -and $Old.occurrences){$selected=[string]@($Old.occurrences)[0]}
    for($i=0;$i -lt $list.Items.Count;$i++){if([string]$list.Items[$i].id -eq $selected){$list.SelectedIndex=$i;break}}
    if($list.SelectedIndex -lt 0 -and $list.Items.Count){$list.SelectedIndex=0}
    $Dialog.Tag.Occurrence=$list
    $Dialog.Tag.OccurrenceLabel=$label
    $valueLabel=New-Object Windows.Forms.Label;$valueLabel.Text=Get-QualityText 'Value' 'Valor';$valueLabel.SetBounds(12,187,468,20);$Dialog.Controls.Add($valueLabel)
    $value=New-Object Windows.Forms.TextBox;$value.SetBounds(12,209,468,25);$value.Text=[string]$Old.value;$Dialog.Controls.Add($value)
    $valueCombo=New-Object Windows.Forms.ComboBox;$valueCombo.DropDownStyle='DropDownList';$valueCombo.DisplayMember='label';$valueCombo.SetBounds(12,209,468,25);$Dialog.Controls.Add($valueCombo)
    $Dialog.Tag.Value=$value;$Dialog.Tag.ValueCombo=$valueCombo;$Dialog.Tag.ValueLabel=$valueLabel
    $refreshValue={param($sender,$eventArgs) $kind=Get-OccurrenceValueKind ([string]$sender.SelectedItem.id);$d=$sender.FindForm();$d.Tag.Value.Visible=$kind -eq 'Number';$d.Tag.Value.Enabled=$kind -eq 'Number';$d.Tag.ValueCombo.Visible=$kind -eq 'Enum';$d.Tag.ValueCombo.Enabled=$kind -eq 'Enum';$d.Tag.ValueLabel.Visible=$kind -ne 'None';$d.Tag.ValueCombo.Items.Clear();if($kind -eq 'Enum'){foreach($option in Get-OccurrenceEnumOptions ([string]$sender.SelectedItem.id)){[void]$d.Tag.ValueCombo.Items.Add($option)};$oldValue=[string]$d.Tag.Old.value;for($j=0;$j -lt $d.Tag.ValueCombo.Items.Count;$j++){if([string]$d.Tag.ValueCombo.Items[$j].id -eq $oldValue){$d.Tag.ValueCombo.SelectedIndex=$j;break}};if($d.Tag.ValueCombo.SelectedIndex -lt 0 -and $d.Tag.ValueCombo.Items.Count){$d.Tag.ValueCombo.SelectedIndex=0}}}
    $list.Add_SelectedIndexChanged($refreshValue)
    # Display the override unit explicitly for commanded spindle/feed adjustments.
    $updateUnit={param($sender,$eventArgs) $d=$sender.FindForm();$d.Tag.ValueLabel.Text=if([string]$sender.SelectedItem.id -in @('SpindleAdjusted','FeedAdjusted')){Get-QualityText 'Value (%)' 'Valor (%)'}else{Get-QualityText 'Value' 'Valor'}}
    $list.Add_SelectedIndexChanged($updateUnit)
    $Dialog.Tag.Old=$Old
    if($list.SelectedIndex -ge 0){& $refreshValue $list $null}
    if($list.SelectedIndex -ge 0){& $updateUnit $list $null}
    $help=Get-QualityText 'Select exactly one occurrence for this event.' 'Selecione exatamente uma ocorrência para este evento.'
    $Dialog.Tag.Quality.Tag.SetToolTip($list,$help);$Dialog.Tag.Quality.Tag.SetToolTip($label,$help)
}

function Get-EditedEventOccurrences {
    param($Context)
    if($null -eq $Context.Occurrence.SelectedItem){throw 'Select an occurrence / Selecione uma ocorrência.'}
    return [string]$Context.Occurrence.SelectedItem.id
}

# Format the atomic occurrence and its value using localized names and units.
function Format-EventOccurrenceValue {
    param($Item)
    $option=@(Get-EventOccurrenceOptions|Where-Object id -eq ([string]$Item.occurrence))
    $label=if($option.Count){[string]$option[0].label}else{[string]$Item.occurrence}
    if($null -eq $Item.value -or (Get-OccurrenceValueKind $Item.occurrence) -eq 'None'){return $label}
    $value=$Item.value
    if((Get-OccurrenceValueKind $Item.occurrence) -eq 'Enum'){
        $match=@(Get-OccurrenceEnumOptions $Item.occurrence|Where-Object id -eq ([string]$value))
        if($match.Count){return $label+': '+$match[0].label}
    }
    $text=if($value -is [ValueType]){([double]$value).ToString('0.########',[Globalization.CultureInfo]::CurrentCulture)}else{[string]$value}
    $unit=switch($Item.occurrence){
        'SpindleAdjusted' {'%'}
        'FeedAdjusted' {'%'}
        'SPowerChanged' {'%'}
        'WPowerChanged' {'%'}
        'ActualSpindleSpeedChanged' {' rpm'}
        'ActualFeedRateChanged' {' mm/min'}
        'ToolUsageTimeChanged' {' min'}
        default {''}
    }
    return $label+': '+$text+$unit
}

function Get-EditedEventValue {
    param($Context)
    $kind=Get-OccurrenceValueKind ([string]$Context.Occurrence.SelectedItem.id)
    if($kind -eq 'None'){return $null}
    if($kind -eq 'Enum'){if($null -eq $Context.ValueCombo.SelectedItem){throw 'Select a value / Selecione um valor.'};return [string]$Context.ValueCombo.SelectedItem.id}
    if([string]::IsNullOrWhiteSpace($Context.Value.Text)){throw 'Enter a numeric value / Introduza um valor numérico.'}
    $number=0.0
    if(-not [double]::TryParse($Context.Value.Text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::CurrentCulture,[ref]$number)){throw 'Invalid numeric value / Valor numérico inválido.'}
    if([double]::IsNaN($number) -or [double]::IsInfinity($number)){throw 'Invalid numeric value / Valor numérico inválido.'}
    if([string]$Context.Occurrence.SelectedItem.id -in @('SpindleAdjusted','FeedAdjusted') -and ($number -lt 0 -or $number -gt 150)){throw 'Adjustment must be between 0 and 150 percent / O ajuste deve estar entre 0 e 150 por cento.'}
    return $number
}
