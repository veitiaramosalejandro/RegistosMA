. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Vibration_Filters.ps1 - version 174.
Playback-only audio filtering. Build high-pass, band-pass and harmonic notch filters for selected channels and let the operator compare the original and filtered signals.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Vibration_Rpm.ps1')
. (Join-Path $PSScriptRoot 'Recording_Contexts.ps1')
# Create filter settings using saved preferences and the recording's machining context.
function New-VibrationSettings {
    param([string]$RecordingFolder)
    $settings=@{Enabled=$false; FilterL=$false; FilterR=$false; HighPass=$false; BandPass=$false; Notch=$false; Low=500.0; High=10000.0; Cutoff=200.0; RPM=6000.0; Harmonics=6; Width=10.0; ProgrammedRpm=$null;LoadWarning=$null}
    if (-not $RecordingFolder) { return $settings }
    # Use this recording's programmed speed, never another recording's defaults
    # or AdjustedRpm: the user explicitly selected programmed spindle speed.
    $settings.RPM=0.0
    $path=Join-Path $RecordingFolder 'metadata.json'
    try {
        $metadata=[pscustomobject]@{Context=(Get-RecordingContextAt @(Read-RecordingContexts $RecordingFolder) 0).context}
        $rpm=0.0
        $valid=[double]::TryParse([string]$metadata.Context.Parameters.SpindleSpeed.ProgrammedRpm,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$rpm)
        if ($valid -and -not [double]::IsNaN($rpm) -and -not [double]::IsInfinity($rpm) -and $rpm -ge 1 -and $rpm -le 120000) {
            Set-VibrationRpmDefaults $settings $rpm
            $settings.ProgrammedRpm=$rpm
        }
    } catch {}
    $savedPath=Join-Path $RecordingFolder 'vibration_filters.json'
    if(Test-Path -LiteralPath $savedPath){
        try{
            $saved=Get-Content -LiteralPath $savedPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if($saved.SchemaVersion -ne 1){throw 'Unsupported filter settings version.'}
            $loaded=@{};foreach($key in $settings.Keys){$loaded[$key]=$settings[$key]}
            foreach($key in @('Enabled','FilterL','FilterR','HighPass','BandPass','Notch')){
                if($saved.Settings.$key -isnot [bool]){throw ('Invalid filter flag: '+$key)}
                $loaded[$key]=$saved.Settings.$key
            }
            foreach($key in @('Low','High','Cutoff','RPM','Harmonics','Width')){
                $value=0.0
                if(-not [double]::TryParse([string]$saved.Settings.$key,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)){throw ('Invalid filter value: '+$key)}
                $min=1;$max=23999;if($key -eq 'RPM'){$min=0;$max=120000};if($key -eq 'Harmonics'){$max=100};if($key -eq 'Width'){$max=1000}
                if($value -lt $min -or $value -gt $max -or ($key -eq 'Harmonics' -and $value -ne [Math]::Floor($value))){throw ('Filter value out of range: '+$key)}
                $loaded[$key]=$value
            }
            if($loaded.Enabled -and -not $loaded.FilterL -and -not $loaded.FilterR){throw 'No filter channel selected.'}
            [void](Get-VibrationChain $loaded)
            $settings=$loaded
        }catch{$settings.LoadWarning=Get-QualityText 'Saved filters could not be read. Playback uses the original signal.' 'Não foi possível ler os filtros guardados. A reprodução usa o sinal original.'}
    }
    return $settings
}
function Save-RecordingVibrationSettings {
    param([string]$Folder,$Settings)
    if(-not (Test-Path -LiteralPath $Folder -PathType Container)){throw (Get-QualityText 'Recording folder not found.' 'Pasta da gravação não encontrada.')}
    [void](Get-VibrationChain $Settings)
    $values=[ordered]@{}
    foreach($key in @('Enabled','FilterL','FilterR','HighPass','BandPass','Notch','Low','High','Cutoff','RPM','Harmonics','Width')){$values[$key]=$Settings[$key]}
    $path=Join-Path $Folder 'vibration_filters.json';$temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temp,([ordered]@{SchemaVersion=1;Settings=$values}|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($path)){
            [IO.File]::Copy($path,$path+'.bak',$true)
            [IO.File]::Copy($temp,$path,$true)
        }else{[IO.File]::Move($temp,$path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
# Build the enabled high-pass, band-pass and harmonic-notch audio filter chain.
function Get-VibrationChain {
    param($Settings)
    if (-not $Settings.Enabled) { return 'anull' }
    $s=$Settings; $culture=[Globalization.CultureInfo]::InvariantCulture
    $required=@();if($s.HighPass){$required+=$s.Cutoff};if($s.BandPass){$required+=@($s.Low,$s.High)};if($s.Notch){$required+=@($s.RPM,$s.Width,$s.Harmonics)}
    if(-not $required.Count){throw (Get-QualityText 'Select at least one filter.' 'Selecione pelo menos um filtro.')}
    foreach ($value in $required) {
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) { throw (Get-QualityText 'Enter valid positive RPM and filter values before enabling filtered playback.' 'Introduza RPM e parâmetros positivos válidos antes de ativar a reprodução filtrada.') }
    }
    if (($s.HighPass -and $s.Cutoff -ge 24000) -or ($s.BandPass -and ($s.High -ge 24000 -or $s.Low -ge $s.High)) -or ($s.Notch -and ($s.Harmonics -gt 100 -or $s.RPM -gt 120000 -or $s.Width -gt 1000))) {
        throw (Get-QualityText 'Invalid range: use 0 < low < high < 24000 Hz.' 'Intervalo inválido: use 0 < inferior < superior < 24000 Hz.')
    }
    $filters=@()
    if ($s.HighPass) { $filters+=('highpass=f='+$s.Cutoff.ToString($culture)+':p=2') }
    if ($s.BandPass) { $filters+=('highpass=f='+$s.Low.ToString($culture)+':p=2'); $filters+=('lowpass=f='+$s.High.ToString($culture)+':p=2') }
    if ($s.Notch) {
        for ($i=1; $i -le $s.Harmonics; $i++) {
            $f=$s.RPM/60.0*$i
            if ($f -ge 24000) { break }
            $filters+=('bandreject=f='+$f.ToString('0.########',$culture)+':t=h:w='+$s.Width.ToString($culture))
        }
    }
    if ($filters.Count -eq 0) { return 'anull' }
    return $filters -join ','
}
# Apply the selected channel/filter settings to the producer's original FFmpeg arguments.
function Set-VibrationArguments {
    param([string[]]$Items,$Settings)
    if (-not $Settings.Enabled) { return $Items }
    $result=@($Items); $index=[Array]::IndexOf($result,'-filter_complex')
    if ($index -lt 0) { throw 'Missing playback audio graph.' }
    $graph=$result[$index+1]; $chain=Get-VibrationChain $Settings
    $rightLabel=Get-UiText 'R - Spindle vibration'
    $filteredLabel=Get-QualityText 'R - Filtered vibration' 'R - Vibração filtrada'
    if ($Settings.FilterR) { $graph=$graph.Replace($rightLabel,$filteredLabel) }
    if ($Settings.FilterL) { $graph=$graph.Replace((Get-UiText 'L - Ambient sound'),(Get-QualityText 'L - Filtered sound' 'L - Som filtrado')) }
    if (-not $Settings.FilterL -and -not $Settings.FilterR) { throw 'Selecione pelo menos um canal: L ou R.' }
    # Run before the common sound/plot split, so charts represent audible audio.
    $target='aout'; if ($graph.Contains('[heard]')) { $target='heard' }
    if ($graph.Contains('[ext]')) { $target='ext' }
    $marker='['+$target+']'
    $position=$graph.IndexOf($marker)
    $graph=$graph.Remove($position,$marker.Length).Insert($position,'[vibraw]')
    $left='anull'; $right='anull'
    if ($Settings.FilterL) { $left=$chain }; if ($Settings.FilterR) { $right=$chain }
    $graph+=';[vibraw]aresample=48000,aformat=channel_layouts=stereo,channelsplit=channel_layout=stereo[vibleft][vibright];[vibleft]'+$left+'[vibleftfiltered];[vibright]'+$right+'[vibfiltered];[vibleftfiltered][vibfiltered]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR'+$marker
    $result[$index+1]=$graph
    return $result
}
function Update-VibrationParametersFromContext {
    param($Dialog)
    $data=$Dialog.Tag;$state=$data.State
    $folder=$state.Context.RecordingFolder;if(-not $folder){$folder=$state.Split.Folder}
    $metadata=$state.Split.Metadata
    if($folder){
        $path=Join-Path $folder 'metadata.json'
        if(Test-Path -LiteralPath $path){$metadata=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop}
    }
    if($folder){$metadata=[pscustomobject]@{Context=(Get-RecordingContextAt @(Read-RecordingContexts $folder) (Get-QualityPosition $state)).context}}
    $rpm=0.0
    if(-not [double]::TryParse([string]$metadata.Context.Parameters.SpindleSpeed.ProgrammedRpm,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$rpm) -or [double]::IsNaN($rpm) -or [double]::IsInfinity($rpm) -or $rpm -lt 1 -or $rpm -gt 120000){throw (Get-QualityText 'The recording context/program has no valid programmed spindle RPM.' 'O contexto/programa da gravação não tem RPM programadas do fuso válidas.')}
    $derived=New-VibrationSettings;Set-VibrationRpmDefaults $derived $rpm
    $data.Updating=$true
    try{
        foreach($key in @('RPM','Cutoff','Low','High','Width')){$data.Numbers[$key].Value=[decimal]$derived[$key]}
        $data.ContextRpm=$rpm
    }finally{$data.Updating=$false}
    Update-VibrationDialogValues $Dialog
}
function Apply-VibrationDialogSettings {
    param($Dialog,[switch]$Save)
    $data=$Dialog.Tag;$state=$data.State;$settings=New-VibrationSettings
    $settings.ProgrammedRpm=$state.Context.Vibration.ProgrammedRpm
    if($data.ContainsKey('ContextRpm')){$settings.ProgrammedRpm=$data.ContextRpm}
    foreach($key in $data.Checks.Keys){$settings[$key]=$data.Checks[$key].Checked}
    foreach($key in $data.Numbers.Keys){$settings[$key]=[double]$data.Numbers[$key].Value}
    $items=@(Set-VibrationArguments $state.Context.UnfilteredItems $settings)
    $position=Get-QualityPosition $state
    if($Save){
        $folder=$state.Context.RecordingFolder
        if(-not $folder){$folder=$state.Split.Folder}
        Save-RecordingVibrationSettings $folder $settings
    }
    $state.Context.ProducerItems=$items;$state.Context.Vibration=$settings
    $state.FilterButton.Text=Get-QualityText 'Filters' 'Filtros'
    if($settings.Enabled){$state.FilterButton.Text=Get-QualityText 'Filters *' 'Filtros *'}
    Request-QualitySeek $state ([Math]::Min($position,[Math]::Max(0,$state.Duration-0.101)))
    $Dialog.DialogResult='OK';$Dialog.Close()
}
# Apply is session-only; Apply and save stores preferences in this recording.
function Show-VibrationDialog {
    param($State)
    if (-not $State.Clock.Ready -or $State.Seeking) { return }
    $dialog=New-Object Windows.Forms.Form
    try {
        $dialog.Text=Get-QualityText 'Filters - L / R' 'Filtros - L / R'
        $dialog.ClientSize=New-Object Drawing.Size(520,655); $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
        $s=$State.Context.Vibration; $checks=@{}; $numbers=@{}
        $rows=@(@('Enabled','Filtered signal (off = original)','Sinal filtrado (desligado = original)'),@('HighPass','High-pass','Passa-alto'),@('BandPass','Band-pass','Passa-banda'),@('Notch','Harmonic notch','Notch harmónico'))
        $y=12
        foreach ($channel in @('L','R')) {
            $check=New-Object Windows.Forms.CheckBox; $check.Text='Canal '+$channel; $check.SetBounds(12,$y,490,24); $check.Checked=$s['Filter'+$channel]; $dialog.Controls.Add($check); $checks['Filter'+$channel]=$check; $y+=29
        }
        foreach ($row in $rows) {
            $control=New-Object Windows.Forms.CheckBox; $control.Text=Get-QualityText $row[1] $row[2]; $control.SetBounds(12,$y,490,24); $control.Checked=$s[$row[0]]; $dialog.Controls.Add($control); $checks[$row[0]]=$control; $y+=29
        }
        $fromContext=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $fromContext;$fromContext.Text=Get-QualityText 'Update from recording context/program' 'Atualizar a partir do contexto/programa';$fromContext.SetBounds(12,$y,488,30);$dialog.Controls.Add($fromContext);$y+=40
        $fromContext.Add_Click({param($sender,$eventArgs) $d=$sender.FindForm();try{Update-VibrationParametersFromContext $d}catch{[void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text,'OK','Warning')}})
        $rows=@(@('Cutoff','High-pass cutoff (Hz)','Corte passa-alto (Hz)',23999),@('Low','Band lower limit (Hz)','Limite inferior da banda (Hz)',23999),@('High','Band upper limit (Hz)','Limite superior da banda (Hz)',23999),@('RPM','Spindle RPM','RPM do spindle',120000),@('Harmonics','Number of harmonics','Número de harmónicos',100),@('Width','Notch width (Hz)','Largura do notch (Hz)',1000))
        foreach ($row in $rows) {
            $label=New-Object Windows.Forms.Label; $label.Text=Get-QualityText $row[1] $row[2]; $label.SetBounds(12,$y,320,24); $dialog.Controls.Add($label)
            $number=New-Object Windows.Forms.NumericUpDown; $number.Minimum=1; $number.Maximum=$row[3]; if ($row[0] -ne 'Harmonics') { $number.DecimalPlaces=2; $number.Increment=0.1 }; if ($row[0] -eq 'RPM') { $number.Minimum=0 }; $number.Value=$s[$row[0]]; $number.SetBounds(350,$y,150,24); $dialog.Controls.Add($number); $numbers[$row[0]]=$number; $y+=29
        }
        $note=New-Object Windows.Forms.Label; $note.SetBounds(12,404,490,200); $dialog.Controls.Add($note)
        $apply=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $apply; $apply.Text=Get-QualityText 'Apply' 'Aplicar'; $apply.SetBounds(155,612,95,30); $dialog.Controls.Add($apply)
        $save=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $save;$save.Text=Get-QualityText 'Apply and save' 'Aplicar e guardar';$save.SetBounds(260,612,135,30);$dialog.Controls.Add($save)
        $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text=Get-QualityText 'Cancel' 'Cancelar'; $cancel.SetBounds(405,612,95,30); $cancel.DialogResult='Cancel'; $dialog.Controls.Add($cancel); $dialog.CancelButton=$cancel
        $dialog.Tag=@{State=$State;Checks=$checks;Numbers=$numbers;Note=$note;Updating=$false}
        $numbers.RPM.Add_ValueChanged({ param($sender,$eventArgs) Update-VibrationDialogValues $sender.FindForm() -FromRpm })
        foreach ($key in @('Cutoff','Low','High','Width','Harmonics')) {
            $numbers[$key].Add_ValueChanged({ param($sender,$eventArgs) Update-VibrationDialogValues $sender.FindForm() })
        }
        foreach ($check in $checks.Values) { $check.Add_CheckedChanged({ param($sender,$eventArgs) Update-VibrationDialogValues $sender.FindForm() }) }
        Update-VibrationDialogValues $dialog
        if($s.LoadWarning){$note.Text=$s.LoadWarning+[Environment]::NewLine+$note.Text}
        $apply.Add_Click({
            param($sender,$eventArgs)
            $d=$sender.FindForm()
            try{Apply-VibrationDialogSettings $d}catch{[void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text)}
        })
        $save.Add_Click({param($sender,$eventArgs) $d=$sender.FindForm();try{Apply-VibrationDialogSettings $d -Save}catch{[void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text)}})
        [void]$dialog.ShowDialog($State.VideoHost.FindForm())
    } finally { $dialog.Dispose() }
}
# Add original/filtered comparison and filter configuration controls to playback.
function Add-VibrationControls {
    param($Panel)
    $state=$Panel.Tag; $annotations=$state.PositionButton.Parent
    $button=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $button; $button.Text=Get-QualityText 'Filters' 'Filtros'; $button.SetBounds(632,66,96,30); $button.Tag=$state
    if($state.Context.Vibration.Enabled){$button.Text=Get-QualityText 'Filters *' 'Filtros *'}
    $annotations.Controls.Add($button); $state.FilterButton=$button
    $button.Add_Click({ param($sender,$eventArgs) Show-VibrationDialog $sender.Tag })
}
