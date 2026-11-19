<#
Vibration_Rpm.ps1 - documented version 123.
RPM-derived filter suggestions. Fundamental frequency is RPM/60; cutoff, band and notch-width suggestions are bounded before updating the dialog.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Convert RPM to fundamental frequency and derive suggested cutoffs, band and notch width.
# f0 = RPM / 60 Hz. Suggested cutoff is 2*f0, upper band edge is 200*f0 and notch width
# is 0.1*f0; bounds keep suggestions in the supported range. These are playback settings.
function Set-VibrationRpmDefaults {
    param($Settings,[double]$RPM)
    if ([double]::IsNaN($RPM) -or [double]::IsInfinity($RPM) -or $RPM -lt 1 -or $RPM -gt 120000) { return }
    $f0=$RPM/60.0
    $Settings.RPM=$RPM
    $Settings.Cutoff=[Math]::Max(1.0,[Math]::Round(2*$f0,2))
    $Settings.Low=$Settings.Cutoff
    $Settings.High=[Math]::Min(23999.0,[Math]::Max($Settings.Low+1,[Math]::Round(200*$f0,2)))
    $Settings.Width=[Math]::Min(1000.0,[Math]::Max(1.0,[Math]::Round(0.1*$f0,2)))
}
# Refresh RPM-derived filter suggestions and explanatory text while preventing recursive updates.
function Update-VibrationDialogValues {
    param($Dialog,[switch]$FromRpm)
    $data=$Dialog.Tag
    if ($null -eq $data -or $data.Updating) { return }
    $data.Updating=$true
    try {
        $numbers=$data.Numbers; $rpm=[double]$numbers.RPM.Value
        if ($FromRpm -and $rpm -ge 1) {
            $derived=New-VibrationSettings
            Set-VibrationRpmDefaults $derived $rpm
            foreach ($key in @('Cutoff','Low','High','Width')) { $numbers[$key].Value=[decimal]$derived[$key] }
        }
        $culture=[Globalization.CultureInfo]::CurrentCulture
        $lines=@()
        if ($rpm -ge 1) {
            $f0=$rpm/60.0; $count=[int]$numbers.Harmonics.Value
            $effective=[Math]::Min($count,[int]([Math]::Ceiling(24000/$f0)-1))
            $lines+=(Get-QualityText 'Current RPM: ' 'RPM atuais: ')+$rpm.ToString('0.##',$culture)+'; f0 = '+$f0.ToString('0.###',$culture)+' Hz.'
            $lines+=(Get-QualityText 'Notch centres: ' 'Centros do notch: ')+$f0.ToString('0.###',$culture)+' - '+($effective*$f0).ToString('0.###',$culture)+' Hz ('+$effective+'/'+$count+(Get-QualityText ' harmonics); width ' ' harmónicos); largura ')+$numbers.Width.Value.ToString('0.##',$culture)+' Hz.'
        } else {
            $lines+=Get-QualityText 'Enter RPM >= 1 to calculate the suggested values.' 'Introduza RPM >= 1 para calcular os valores sugeridos.'
        }
        $lines+=(Get-QualityText 'High-pass: ' 'Passa-alto: ')+$numbers.Cutoff.Value.ToString('0.##',$culture)+(Get-QualityText ' Hz; band: ' ' Hz; banda: ')+$numbers.Low.Value.ToString('0.##',$culture)+' - '+$numbers.High.Value.ToString('0.##',$culture)+' Hz.'
        $reference=$data.State.Context.Vibration.ProgrammedRpm
        if($data.ContainsKey('ContextRpm')){$reference=$data.ContextRpm}
        if ($null -ne $reference) { $lines+=(Get-QualityText 'Recording reference: ' 'Referência da gravação: ')+([double]$reference).ToString('0.##',$culture)+' rpm.' }
        $active=@()
        foreach ($row in @(@('HighPass','High-pass','Passa-alto'),@('BandPass','Band-pass','Passa-banda'),@('Notch','Notch','Notch'))) {
            if ($data.Checks[$row[0]].Checked) { $active+=Get-QualityText $row[1] $row[2] }
        }
        if (-not $data.Checks.Enabled.Checked) { $lines+=Get-QualityText 'Playback: original signal.' 'Reprodução: sinal original.' }
        elseif ($active.Count -eq 0) { $lines+=Get-QualityText 'No filter selected: the signal will not be attenuated.' 'Nenhum filtro selecionado: o sinal não será atenuado.' }
        else { $lines+=(Get-QualityText 'Selected filters: ' 'Filtros selecionados: ')+($active -join ', ')+'.' }
        $channels=@(); foreach ($channel in @('L','R')) { if ($data.Checks['Filter'+$channel].Checked) { $channels+=$channel } }
        $lines+='Canais selecionados: '+($channels -join ', ')+'. Parâmetros comuns aos canais selecionados.'
        $lines+=Get-QualityText 'Changing RPM resets cutoff/band/width suggestions; harmonic count stays editable. Apply to update playback. Filters attenuate gradually, not at a hard boundary.' 'Alterar RPM recalcula cortes/banda/largura; o número de harmónicos mantém-se editável. Aplique para atualizar a reprodução. A atenuação dos filtros é gradual.'
        $data.Note.Text=$lines -join [Environment]::NewLine
    } finally { $data.Updating=$false }
}
