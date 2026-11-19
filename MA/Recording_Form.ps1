. (Join-Path $PSScriptRoot 'Recording_AudioListening.ps1')
. (Join-Path $PSScriptRoot 'Visualization_ResizeForm.ps1')
. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Recording_Form.ps1 - version 288.
Recording-window construction and interaction. Embedded C# integrates external player windows without covering them during resize; PowerShell connects controls to the capture controller.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
Native resize integration keeps source windows visible and only updates their geometry.
#>
#Requires -Version 5.1
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Header.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
if(-not ('MachiningMonitor.RecordingWindow' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
 public static class RecordingWindow {
  [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr window,int index);
  [DllImport("user32.dll", EntryPoint="SetWindowLongW")] static extern int SetWindowLong(IntPtr window,int index,int value);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window,int command);
  public static void HideChildTaskbarEntry(IntPtr child) {
   // Only the containing recording form should have a taskbar entry.
   int style=GetWindowLong(child,-20);
   SetWindowLong(child,-20,(style & ~0x00040000) | 0x00000080);
  }
  [StructLayout(LayoutKind.Sequential)] struct ClientRect { public int Left,Top,Right,Bottom; }
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out ClientRect rect);
  public static void ResizeAsync(IntPtr child,int width,int height,bool restore) {
   if(child==IntPtr.Zero || width<=0 || height<=0) return;
   // Never wait for SDL's event thread while Windows minimizes/restores the form.
   if(restore) ShowWindowAsync(child,4);
   ClientRect rect;
   if(GetClientRect(child,out rect) && rect.Right-rect.Left==width && rect.Bottom-rect.Top==height) return;
   SetWindowPos(child,IntPtr.Zero,0,0,width,height,0x4000 | 0x0010 | 0x0004 | 0x0020);
  }
 }
}
'@
}

# Resize the embedded native visualization to fit the recording host panel.
function Update-RecordingVisualizationLayout {
    param([switch]$Restore)
    $u=$script:RecordingUi
    if(-not $u -or $u.Form.IsDisposed -or $u.Form.WindowState -eq 'Minimized' -or $u.VideoHandle -eq [IntPtr]::Zero){return}
    if($u.Mode.DroppedDown){return}
    [MachiningMonitor.RecordingWindow]::ResizeAsync($u.VideoHandle,$u.VideoHost.ClientSize.Width,$u.VideoHost.ClientSize.Height,($Restore.IsPresent -and -not $u.ResizeNoticeActive))
}

# Reparent the external player window into the recording form's video panel.
function Embed-RecordingVisualization {
    param([IntPtr]$Child)
    $u=$script:RecordingUi
    [MachiningMonitor.QualityClock]::Embed($Child,$u.VideoHost.Handle,$u.VideoHost.ClientSize.Width,$u.VideoHost.ClientSize.Height)
    [MachiningMonitor.RecordingWindow]::HideChildTaskbarEntry($Child)
    $u.VideoHandle=$Child; $u.WaitingForImage=$false; $u.Placeholder.Visible=$false
    Update-RecordingSourceWait
    Update-RecordingVisualizationLayout -Restore
}

# Warn the operator before closing a window that is still recording.
function Show-RecordingCloseWarning {
    param($Owner)
    [void][Windows.Forms.MessageBox]::Show($Owner,
        (Get-QualityText 'Cannot close this window while a recording is in progress. Use Stop recording first.' 'Não pode fechar esta janela porque existe uma gravação em curso. Utilize primeiro Parar gravação.'),
        (Get-QualityText 'Recording in progress' 'Gravação em curso'),'OK','Information')
}

# Refresh the recording form's labels and controls after a language change.
function Update-RecordingFormLanguage {
    $u=$script:RecordingUi
    $u.Form.Text=Get-QualityText 'Machining Monitor - Session recording' 'Machining Monitor - Gravação de sessões'
    $u.ChooseFolder.Text=Get-QualityText 'Choose folder...' 'Escolher pasta…'
    Update-RecordingToggle
    $u.Stop.Text=Get-QualityText 'Stop recording' 'Parar gravação'
    $u.Event.Text=Get-QualityText 'Record event' 'Registar evento'
    $u.ShowVideo.Text=Get-QualityText 'Show video' 'Visualizar vídeo'
    $u.ShowCharts.Text=Get-QualityText 'Show audio charts' 'Visualizar gráficos de áudio'
    if($u.ListenAudio){$u.ListenAudio.Left=$u.ShowCharts.Right+16;$u.ListenAudio.Text=Get-QualityText 'Listen to external audio' 'Ouvir áudio externo'}
    if($u.Viewport.Tag.FitButton){$u.Viewport.Tag.FitButton.Left=[Math]::Max(330,$u.ListenAudio.Right+16)}
    Update-VisualizationSizingLanguage $u.Viewport

    $u.ContextButton.Text=Get-QualityText 'Context/program' 'Contexto/programa'
    $u.Settings.Text=Get-QualityText 'Settings' 'Configuração'
    $u.SchedulesButton.Text=Get-QualityText 'Schedules' 'Agendamentos'
    $u.TimerButton.Text=Get-QualityText 'Timer' 'Temporizador'
    $u.ApplyLanguage.Text=$(if($u.Language.SelectedIndex -eq 1){'Apply'}else{'Aplicar'})
    $u.Placeholder.Text=Get-QualityText 'Select a mode and start recording. Camera and charts appear here.' 'Selecione o modo e inicie a gravação. A câmara e os gráficos aparecem aqui.'
    $headers=if($script:UiLanguage -eq 'pt'){@('Hora','Tempo','Segundos','Classificação','Estado','Alterações','Notas')}else{@('Clock time','Time','Seconds','Rating','State','Changes','Notes')}
    for($i=0;$i -lt $headers.Count;$i++){ $u.List.Columns[$i].Text=$headers[$i] }
    $index=$u.Mode.SelectedIndex
    $u.Mode.Items.Clear()
    [void]$u.Mode.Items.Add((Get-QualityText 'Camera + external audio' 'Câmara + áudio externo'))
    [void]$u.Mode.Items.Add((Get-QualityText 'External audio only' 'Apenas áudio externo'))
    [void]$u.Mode.Items.Add((Get-QualityText 'Camera only' 'Apenas câmara'))
    $u.Mode.SelectedIndex=[Math]::Max(0,$index)
    if($u.ActiveView.Parent.Tag){Set-RecordingControlsLayout $u.ActiveView.Parent}
}

# Re-enumerate DirectShow audio capture devices and preserve the selected hardware identifier when possible.
# Detection failure leaves the existing list intact; an empty initial list can still be rescanned from the dialog.
function Update-RecordingAudioDevices {
    param($Dialog)
    $state=$Dialog.Tag
    $preferred=$state.Config.AudioDevice
    $preferredName=$state.Config.AudioDeviceName
    if($state.Audio.SelectedIndex -ge 0){
        $selected=$state.Devices[$state.Audio.SelectedIndex]
        $preferred=if($selected.AlternativeName){$selected.AlternativeName}else{$selected.Name}
        $preferredName=$selected.Name
    }
    $state.Detect.Enabled=$false;$Dialog.UseWaitCursor=$true
    try{
        $devices=@(Get-AudioDevices $script:RecordingUi.FFmpeg)
        $state.Audio.Items.Clear();$state.Devices=$devices
        foreach($device in $devices){[void]$state.Audio.Items.Add($device.Name)}
        # Prefer stable alternative identifiers; fall back to the readable name or the first available input.
        for($i=0;$i -lt $devices.Count;$i++){
            if($preferred -and ($devices[$i].AlternativeName -eq $preferred -or $devices[$i].Name -eq $preferred)){$state.Audio.SelectedIndex=$i;break}
        }
        if($state.Audio.SelectedIndex -lt 0){
            for($i=0;$i -lt $devices.Count;$i++){if($devices[$i].Name -eq $preferredName){$state.Audio.SelectedIndex=$i;break}}
        }
        if($state.Audio.SelectedIndex -lt 0 -and $devices.Count){$state.Audio.SelectedIndex=0}
    }catch{Show-QualityError $_.Exception.Message}
    finally{$state.Detect.Enabled=$true;$Dialog.UseWaitCursor=$false}
}
# Match playback settings: TopLeft labels begin four pixels below their field top, aligning the visible text.
function Set-RecordingSettingsTextLayout {
    param($Dialog)
    $state=$Dialog.Tag
    for($i=0;$i -lt $state.Fields.Count;$i++){
        $field=$state.Fields[$i];$label=$state.FieldLabels[$i]
        if($i -eq 3){$label.SetBounds(12,($state.Camera.Top-32),($Dialog.ClientSize.Width-32),30);$label.Anchor='Top,Left,Right';continue}
        $preferred=$label.GetPreferredSize((New-Object Drawing.Size($label.Width,0)))
        $height=[Math]::Max(24,$preferred.Height)
        $label.TextAlign=[Drawing.ContentAlignment]::TopLeft
        $label.SetBounds($label.Left,($field.Top+4),$label.Width,$height)
    }
    # ComboBox ignores a requested height; match the refresh button to the actual rendered selector.
    $state.Detect.SetBounds($state.Detect.Left,$state.Audio.Top,$state.Detect.Width,$state.Audio.Height)
}
. (Join-Path $PSScriptRoot 'Recording_AudioSettings.ps1')

# Build the recording window, event list, visualization host and interaction handlers.
function New-RecordingForm {
    param([string]$FFmpeg,[switch]$NoWait)
    Initialize-QualityClock
    $f=New-Object MachiningMonitor.RecordingResizeForm; $f.StartPosition='CenterScreen'; $f.ShowInTaskbar=$true
    $f.Font=New-Object Drawing.Font('Segoe UI',10)
    $area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $f.ClientSize=New-Object Drawing.Size([Math]::Min(1040,$area.Width-60),[Math]::Min(980,$area.Height-80))
    $f.MinimumSize=New-Object Drawing.Size($f.Width,([Math]::Min(480,$f.Height)))
    $layout=New-Object Windows.Forms.TableLayoutPanel; $layout.Dock='Fill'; $layout.ColumnCount=1; $layout.RowCount=3
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',48)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',168)))
    $f.Controls.Add($layout)
    $top=New-Object Windows.Forms.Panel; $top.Dock='Fill'; $top.Margin=New-Object Windows.Forms.Padding(0)
    $hostPanel=New-Object Windows.Forms.Panel; $hostPanel.Dock='Fill'; $hostPanel.BackColor=[Drawing.Color]::Black; $hostPanel.Margin=New-Object Windows.Forms.Padding(0)
    $bottom=New-Object Windows.Forms.Panel; $bottom.Dock='Fill'; $bottom.Margin=New-Object Windows.Forms.Padding(0)
    $viewport=New-VisualizationViewport $hostPanel
    $viewport.Tag.RecordingVisualization=@{VideoZoom=@{}}
    $mediaPanel=New-Object Windows.Forms.Panel; $mediaPanel.Dock='Fill';$mediaPanel.Margin=New-Object Windows.Forms.Padding(0)
    $mediaPanel.Controls.Add($viewport)
    $viewChoices=New-Object Windows.Forms.Panel;$viewChoices.Dock='Top';$mediaPanel.Controls.Add($viewChoices)
    $layout.Controls.Add($mediaPanel,0,0); $layout.Controls.Add($top,0,1); $layout.Controls.Add($bottom,0,2)
    $placeholder=New-Object Windows.Forms.Label; $placeholder.Dock='Fill'; $placeholder.ForeColor=[Drawing.Color]::Silver; $placeholder.TextAlign='MiddleCenter'; $hostPanel.Controls.Add($placeholder)
    $header=New-RecordingHeader $top $script:recordingsPath
    $language=$header.Language; $applyLanguage=$header.ApplyLanguage
    $mode=New-Object Windows.Forms.ComboBox; $mode.DropDownStyle='DropDownList'; $mode.SetBounds(12,6,385,28)
    $settings=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $settings; $settings.SetBounds(410,4,265,30)
    $contextButton=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $contextButton
    $start=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $start; $start.SetBounds(12,38,210,30)
    $stop=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $stop; $stop.SetBounds(235,38,210,30); $stop.Enabled=$false
    # Dedicated timer and schedule controls replace the former scheduling menu.
    $timerButton=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $timerButton
    $schedulesButton=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $schedulesButton; $schedulesButton.Text=Get-QualityText 'Schedules' 'Agendamentos'
    $event=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $event; $event.SetBounds(458,38,217,30); $event.Enabled=$false
    $activeView=New-Object Windows.Forms.CheckBox; $activeView.SetBounds(12,71,260,28); $activeView.Checked=$false; $activeView.Visible=$false
    $showVideo=New-Object Windows.Forms.CheckBox; $showVideo.Checked=$true
    $showCharts=New-Object Windows.Forms.CheckBox; $showCharts.Checked=$true
    $showVideo.AutoSize=$true;$showCharts.AutoSize=$true
    $showVideo.Location=New-Object Drawing.Point(12,5);$showCharts.Location=New-Object Drawing.Point(160,5)
    $viewChoices.Controls.AddRange(@($showVideo,$showCharts));Add-VisualizationSizingControls $viewChoices $viewport
    $viewStatus=New-Object Windows.Forms.Label; $viewStatus.ForeColor=[Drawing.Color]::Red; $viewStatus.Visible=$false; $viewStatus.TextAlign='MiddleCenter'; $viewStatus.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
    Initialize-PlainResizeNotice
    $resizeStatus=New-Object MachiningMonitor.PlainResizeNotice; $resizeStatus.Dock='None'; $resizeStatus.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold); $resizeStatus.BackColor=[Drawing.Color]::Black; $resizeStatus.ForeColor=[Drawing.Color]::White; $resizeStatus.Visible=$false; $resizeStatus.TextAlign='MiddleCenter'; $viewport.Controls.Add($resizeStatus); $viewport.Tag.ResizeLayer=$resizeStatus; Update-VisualizationMessageLayers $viewport
    $status=New-Object Windows.Forms.Label; $status.SetBounds(208,70,($f.ClientSize.Width-220),26); $status.Visible=$false; $status.TextAlign='MiddleLeft'; $status.AutoEllipsis=$true; $status.Anchor='Top,Left,Right'
    $list=New-Object Windows.Forms.ListView; Register-ListTooltipLayout $list; $list.View='Details'; $list.FullRowSelect=$true; $list.SetBounds(12,70,($f.ClientSize.Width-24),86); $list.Anchor='Top,Bottom,Left,Right'
    foreach($title in @('Hora','Tempo','Segundos','Classificação','Estado','Alterações','Notas')) { [void]$list.Columns.Add($title,105) }
    $widths=@(90,100,70,140,150,300,440)
    for($i=0;$i -lt $widths.Count;$i++){ $list.Columns[$i].Width=$widths[$i] }
    Initialize-EventColumnLayout $list 'recording'
    $bottom.Controls.AddRange(@($mode,$settings,$contextButton,$start,$event,$status,$list,$activeView,$viewStatus,$timerButton,$schedulesButton))
    $script:RecordingUi=@{ShowVideo=$showVideo;ShowCharts=$showCharts;Viewport=$viewport;ContextButton=$contextButton;TimerButton=$timerButton;SchedulesButton=$schedulesButton;MinimumWindowSize=$f.MinimumSize;ResizeStatus=$resizeStatus;ViewStatus=$viewStatus;PulseClock=[Diagnostics.Stopwatch]::StartNew();ActiveView=$activeView;Form=$f;Language=$language;ApplyLanguage=$applyLanguage;VideoHost=$hostPanel;Placeholder=$placeholder;VideoHandle=[IntPtr]::Zero;LanguageChanged=$false;Mode=$mode;Settings=$settings;Start=$start;Stop=$stop;Event=$event;Status=$status;List=$list;FFmpeg=$FFmpeg;Ready=$false;Running=$false;Stopping=$false;State=$null}
    Initialize-RecordingAudioListening $viewChoices
    $bottom.Tag=@{ShowVideo=$showVideo;ShowCharts=$showCharts;Viewport=$viewport;ContextButton=$contextButton;TimerButton=$timerButton;SchedulesButton=$schedulesButton;Mode=$mode;Settings=$settings;ActiveView=$activeView;ViewStatus=$viewStatus;Start=$start;Stop=$stop;Event=$event;Status=$status;List=$list;ResizeStatus=$resizeStatus}
    $bottom.Add_ClientSizeChanged({Set-RecordingControlsLayout $this})
    Set-RecordingControlsLayout $bottom
    $script:RecordingUi.PathLabel=$header.PathLabel
    $script:RecordingUi.ChooseFolder=$header.ChooseFolder
    $header.ChooseFolder.Add_Click({
        $u=$script:RecordingUi
        if($u.Running -or $u.Ready){return}
        try {
            $root=Get-RecordingsDirectory -Graphical -Choose -Owner $u.Form -CurrentPath $script:recordingsPath
            if([string]::IsNullOrWhiteSpace($root)){return}
            $script:recordingsPath=$root; $u.PathLabel.Text=$root
        } catch {Show-QualityError $_.Exception.Message}
    })
    foreach($choice in @($showVideo,$showCharts)){$choice.Add_CheckedChanged({Update-RecordingViewChoices})}
    $mode.Add_SelectedIndexChanged({if(-not $this.DroppedDown){Update-RecordingViewChoices}})
    $mode.Add_DropDownClosed({Update-RecordingViewChoices})
    Update-RecordingViewChoices
    $hostPanel.Add_Resize({
        Start-RecordingResizeNotice
        Update-RecordingVisualizationLayout
    })
    $f.Add_Resize({ Update-RecordingVisualizationLayout -Restore })
    $f.Add_Activated({ Update-RecordingVisualizationLayout -Restore })
    Update-RecordingFormLanguage
    $language.Add_SelectedIndexChanged({
        $script:RecordingUi.ApplyLanguage.Text=$(if($this.SelectedIndex -eq 1){'Apply'}else{'Aplicar'})
    })
    $applyLanguage.Add_Click({
        $script:UiLanguage=$(if($script:RecordingUi.Language.SelectedIndex -eq 0){'pt'}else{'en'})
        Save-ConfigValues $script:UiConfigPath @{Language=$script:UiLanguage}
        Update-RecordingFormLanguage
        if($script:RecordingUi.Running){ $script:RecordingUi.LanguageChanged=$true }
    })
    $contextButton.Add_Click({try {Show-DefaultRecordingContext} catch {Show-QualityError $_.Exception.Message}})
    $settings.Add_Click({try {Show-RecordingSettings} catch {Show-QualityError $_.Exception.Message}})
    $start.Add_Click({
        if($script:RecordingUi.Running){[void](Request-FormRecordingStop); return}
        if($script:RecordingUi.Ready -or $script:RecordingUi.ControllerBusy){return}
        $c=Read-RecordingConfig $script:UiConfigPath
        if($script:RecordingUi.Mode.SelectedIndex -ne 2 -and -not (Test-RecordingAudioConfigured $c)) { Show-RecordingSettings; $c=Read-RecordingConfig $script:UiConfigPath }
        if($script:RecordingUi.Mode.SelectedIndex -ne 2 -and -not (Test-RecordingAudioConfigured $c)) { return }
        if($script:RecordingUi.Mode.SelectedIndex -ne 1 -and -not @(Get-RecordingCameras $c -Selected).Count) { Show-RecordingSettings; $c=Read-RecordingConfig $script:UiConfigPath; if(-not @(Get-RecordingCameras $c -Selected).Count){return} }
        try {
            $root=Get-RecordingsDirectory -Graphical -Owner $script:RecordingUi.Form -CurrentPath $script:recordingsPath
            if([string]::IsNullOrWhiteSpace($root)){return}
            $script:recordingsPath=$root
            $script:RecordingUi.PathLabel.Text=$root
        } catch {Show-QualityError $_.Exception.Message; return}
        $script:RecordingUi.Start.Enabled=$false
        $script:RecordingUi.Status.Text=Get-QualityText 'Starting recording...' 'A iniciar gravação…'
        $script:RecordingUi.Status.Refresh()
        $script:RecordingUi.Ready=$true
        $script:RecordingUi.ChooseFolder.Enabled=$false
    })

    $event.Add_Click({
        $u=$script:RecordingUi;Update-RecordingMediaClock
        if(-not $u.State.Clock.Ready){return}
        $u.State.Duration=$u.State.Clock.Seconds
        Show-QualityEditor $u.State $false
    })
    $f.Add_FormClosing({
        param($sender,$eventArgs)
        $u=$script:RecordingUi
        if($u.Running) {
            $eventArgs.Cancel=$true
            if(-not $u.CloseNoticeOpen){
                $u.CloseNoticeOpen=$true
                try {Show-RecordingCloseWarning $sender} finally {$u.CloseNoticeOpen=$false}
            }
        }
    })
    $f.ResizeSurface=$hostPanel;$f.ResizeOverlay=$resizeStatus
    $f.Add_ResizeStarting({Start-RecordingResizeNotice})
    $f.Add_Shown({param($sender,$eventArgs) Set-MonitorWindowHeight $sender $script:RecordingUi; Fit-VisualizationToWindow $script:RecordingUi.Viewport})
    if($f.GetType().GetEvent('DpiChanged')){
        $f.Add_DpiChanged({param($sender,$eventArgs) $sender.BeginInvoke([Action]{Set-MonitorWindowHeight $script:RecordingUi.Form $script:RecordingUi}) | Out-Null})
    }
    Initialize-RecordingToggle
    $f.Add_FormClosed({
        Stop-RecordingAudioListening; $script:RecordingUi.ListenTimer.Stop();$script:RecordingUi.ListenTimer.Dispose()
        if($script:RecordingUi.ToggleTip){$script:RecordingUi.ToggleTip.Dispose()}
        foreach($icon in @($script:RecordingUi.RecordIcon,$script:RecordingUi.StopIcon)){if($icon){$icon.Dispose()}}
    })
    # Initialize after the form and controls exist; persisted-schedule recovery runs when the form is shown.
    Initialize-RecordingSchedule
    $f.Show()
    if(-not $NoWait){Wait-RecordingFormStart}
}

# Wait for a start request while allowing the recording form to process UI events.
function Wait-RecordingFormStart {
    $u=$script:RecordingUi; $f=$u.Form
    while(-not $u.Ready -and -not $f.IsDisposed) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    if($f.IsDisposed) { throw [OperationCanceledException]::new('Recording cancelled.') }
    $u.List.Items.Clear()
    $u.Start.Enabled=$false; $u.Mode.Enabled=$false; $u.Settings.Enabled=$false; $u.ContextButton.Enabled=$true
}

# Return controls to their ready state after a recording finishes or a start is cancelled.
function Reset-RecordingForm {
    $script:captureSyncPlan=$null
    $u=$script:RecordingUi
    if($u.Form.IsDisposed){return}
    # Clear capture-specific scheduling state while retaining the queue and configured manual timer.
    Clear-RecordingSchedule
    $u.Running=$false; $u.Ready=$false; $u.Stopping=$false; $u.LanguageChanged=$false
    $u.State=$null; $u.WaitingForImage=$false; $u.VideoHandle=[IntPtr]::Zero
    $u.Start.Enabled=$true; $u.Mode.Enabled=$true; $u.Settings.Enabled=$true; $u.ContextButton.Enabled=$true
    $u.ChooseFolder.Enabled=$true
    $u.Stop.Enabled=$false; $u.Event.Enabled=$false
    $u.Placeholder.Visible=$true
    $u.Placeholder.Text=Get-QualityText 'Ready for a new recording.' 'Pronto para uma nova gravação.'
    # Keep the completion outcome visible after reset; the controller subsequently adds the next/missed schedule notice.
    $u.Status.Text=[string]$u.LastRecordingResult; $u.Status.Visible=[bool]$u.LastRecordingResult
}

# Ask the operator to confirm stopping the current recording.
function Confirm-StopRecording {
    param($Owner)
    return ([Windows.Forms.MessageBox]::Show($Owner,
        (Get-QualityText 'Stop the current recording?' 'Quer terminar a gravação em curso?'),
        (Get-QualityText 'Stop recording' 'Parar gravação'),'YesNo','Question','Button2') -eq 'Yes')
}
# Convert a confirmed UI stop request into the capture controller's stop signal.
function Request-FormRecordingStop {
    param($Owner)
    $u=$script:RecordingUi
    if(-not $u.Running -or $u.Stopping){return $false}
    if(-not $Owner){$Owner=$u.Form}
    if(-not (Confirm-StopRecording $Owner)){return $false}
    $u.Stopping=$true; $u.Stop.Enabled=$false; $u.Event.Enabled=$false
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stop.flag') -Value 'stop'
    return $true
}

# Persist the current recording metadata, including elapsed time and completed context.
function Save-BaseRecordingMetadata {
    if(-not $outputPath -or -not $metadata) { return }
    $actualDuration=Get-RecordedSessionSeconds $outputPath
    if($null -ne $actualDuration){
        if($script:captureLogMonitor -and $script:captureLogMonitor.Ready){Update-RecordingMediaClock}
        $script:RecordingEndedAt=$metadata.StartTime.AddSeconds($actualDuration)
    }elseif($script:captureLogMonitor -and $script:captureLogMonitor.Ready){
        Update-RecordingMediaClock
        $script:RecordingEndedAt=$metadata.StartTime.AddSeconds($script:captureLogMonitor.Seconds)
    }elseif(-not $script:RecordingEndedAt){$script:RecordingEndedAt=$metadata.StartTime}
    $metadata.Finish($script:RecordingEndedAt)
    $data=[ordered]@{
        StartTime=$metadata.StartTime.ToString('yyyy-MM-ddTHH:mm:ss.fffK'); EndTime=$metadata.EndTime.ToString('yyyy-MM-ddTHH:mm:ss.fffK')
        DurationSeconds=$metadata.DurationSeconds; Duration=$metadata.Duration; Mode=$metadata.Mode
        VideoFile=$metadata.VideoFile; AudioFile=$metadata.AudioFile; SegmentMinutes=$segmentMinutes
        VideoSegmentation=$(if($mode -ne 'AUDIO'){'H264_ForcedKeyframes_MinDuration'}else{$null})
        Synchronization=$script:captureSyncPlan; RecordingScriptVersion=168; AudioVolumePercent=$audioVolumePercent; AudioBufferMilliseconds=$captureAudioBufferMs
        AudioSourceType=$script:selectedDevice.Type
        VideoFiles=@(Get-ChildItem -LiteralPath $outputPath -Filter 'video_*.mp4' -File | Sort-Object Name | Select-Object -ExpandProperty Name)
        Cameras=@(if($mode -ne 'AUDIO'){
            for($i=0;$i -lt $script:selectedCameras.Count;$i++){
                $prefix='video';if($i -gt 0){$prefix='camera_'+($i+1).ToString('00')}
                [ordered]@{Name=$script:selectedCameras[$i].Name;VideoFile=($prefix+'_%06d.mp4');SegmentList=($prefix+'_segments.csv');Files=@(Get-ChildItem -LiteralPath $outputPath -Filter ($prefix+'_*.mp4') -File | Sort-Object Name | Select-Object -ExpandProperty Name)}
            }
        })
        AudioFiles=@(Get-ChildItem -LiteralPath $outputPath -Filter 'audio_*.wav' -File | Sort-Object Name | Select-Object -ExpandProperty Name)
        Context=$script:CompletedRecordingContext
    }
    $data.Remove('Context')
    if(-not (Test-Path -LiteralPath (Join-Path $outputPath 'contexts.json'))){
        $context=$script:CompletedRecordingContext
        if($null -eq $context){$context=New-EmptyRecordingContext}
        Write-RecordingContexts $outputPath @([pscustomobject]@{id='initial';timestamp_seconds=0.0;context=(Copy-RecordingContextValue $context)})
    }
    [IO.File]::WriteAllText((Join-Path $outputPath 'metadata.json'),($data | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
}

# Offer audio-only recording through the graphical interface if camera validation fails.
function Confirm-RecordingAudioFallback {
    return ([Windows.Forms.MessageBox]::Show($script:RecordingUi.Form,
        (Get-QualityText 'Camera unavailable. Record audio only?' 'Câmara indisponível. Gravar apenas áudio?'),
        'Machining Monitor','YesNo','Warning') -eq 'Yes')
}



