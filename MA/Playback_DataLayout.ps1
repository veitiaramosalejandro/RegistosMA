. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
#Requires -Version 5.1
# Version 200. Playback management only; capture uses its own independent form.
function Get-PlaybackDataExtraHeight {
    param($State)
    $height=0
    for($i=3;$i -lt $State.DataResizeLayout.RowStyles.Count;$i++){
        if($State.DataResizeLayout.RowStyles[$i].SizeType -eq 'Absolute'){$height+=$State.DataResizeLayout.RowStyles[$i].Height}
    }
    return $height
}
function Update-PlaybackDataLayout {
    param($State)
    if($State.DataLayoutUpdating -or -not $State.DataResizeLayout){return}
    $State.DataLayoutUpdating=$true
    try{
        $layout=$State.DataResizeLayout
        $layout.SuspendLayout()
        if($State.DataVisualizationHidden){
            $layout.RowStyles[0].SizeType='Absolute';$layout.RowStyles[0].Height=0
            $layout.RowStyles[2].SizeType='Percent';$layout.RowStyles[2].Height=100
            $State.DataMediaPanel.Visible=$false
            $State.DataVisibilityButton.Text=Get-QualityText 'Restore visualization' 'Restaurar visualização'
        }else{
            $extra=Get-PlaybackDataExtraHeight $State
            $maximum=[Math]::Max(220,$layout.ClientSize.Height-28-$extra-128)
            $height=[Math]::Max(220,[Math]::Min($maximum,[double]$State.DataPreferredHeight))
            $layout.RowStyles[2].SizeType='Absolute';$layout.RowStyles[2].Height=$height
            $layout.RowStyles[0].SizeType='Percent';$layout.RowStyles[0].Height=100
            $State.DataMediaPanel.Visible=$true
            $State.DataVisibilityButton.Text=Get-QualityText 'Hide visualization' 'Ocultar visualização'
        }
    }finally{$layout.ResumeLayout($true);$State.DataLayoutUpdating=$false}
    if($State.List -and -not $State.List.IsDisposed){Request-EventColumnFit $State.List}
}
function Set-PlaybackDataWindowHeight {
    param($Form,$State)
    # Visualization visibility must update even when window geometry cannot be changed.
    if($Form.WindowState -ne 'Normal'){
        if($Form.WindowState -eq 'Maximized'){Update-PlaybackDataLayout $State}
        return
    }
    $area=[Windows.Forms.Screen]::FromControl($Form).WorkingArea
    $extra=Get-PlaybackDataExtraHeight $State
    $visualMinimum=128;if($State.DataVisualizationHidden){$visualMinimum=0}
    $minimum=[Math]::Min($area.Height-24,220+28+$extra+$visualMinimum+($Form.Height-$Form.ClientSize.Height))
    $State.MinimumWindowSize=New-Object Drawing.Size($State.MinimumWindowSize.Width,$minimum)
    $Form.MinimumSize=New-Object Drawing.Size($Form.MinimumSize.Width,$minimum)
    if($Form.WindowState -eq 'Normal'){
        if($Form.Height -gt $area.Height-24){$Form.Height=$area.Height-24}
        $Form.Top=[Math]::Max($area.Top+12,[Math]::Min($Form.Top,$area.Bottom-12-$Form.Height))
    }
    Update-PlaybackDataLayout $State
}
function Set-PlaybackDataHeight {
    param($State,[double]$Height)
    if($State.DataVisualizationHidden){return}
    $maximum=[Math]::Max(220,$State.DataResizeLayout.ClientSize.Height-28-(Get-PlaybackDataExtraHeight $State)-128)
    $State.DataPreferredHeight=[Math]::Max(220,[Math]::Min($maximum,$Height))
    Update-PlaybackDataLayout $State
}
function Add-PlaybackDataLayout {
    param($State,$Layout,$MediaPanel)
    $State.DataResizeLayout=$Layout;$State.DataMediaPanel=$MediaPanel
    $State.DataPreferredHeight=220.0;$State.DataVisualizationHidden=$false
    $bar=New-Object Windows.Forms.Panel;$bar.Dock='Fill';$bar.Margin=New-Object Windows.Forms.Padding(0);$bar.BackColor=[Drawing.SystemColors]::ControlLight;$bar.Cursor='HSplit'
    $bar.Size=New-Object Drawing.Size(([Math]::Max(600,$Layout.ClientSize.Width)),28)
    $label=New-Object Windows.Forms.Label;$label.AutoEllipsis=$true;$label.Text=Get-QualityText 'Drag to resize the visualization area' ('Arraste para ajustar a altura da zona de visualiza' + [char]0x00e7 + [char]0x00e3 + 'o')
    $label.SetBounds(12,5,($bar.ClientSize.Width-260),20);$label.Anchor='Top,Left,Right';$label.Cursor='HSplit';$bar.Controls.Add($label)
    $button=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $button;$button.Cursor=[Windows.Forms.Cursors]::Default;$button.SetBounds(($bar.ClientSize.Width-236),0,224,27);$button.Anchor='Top,Right';$bar.Controls.Add($button);$State.DataVisibilityButton=$button
    $presets=New-Object Windows.Forms.FlowLayoutPanel;$presets.Height=27;$presets.WrapContents=$false;$presets.FlowDirection='LeftToRight';$presets.Anchor='Top,Right';$presets.Margin=New-Object Windows.Forms.Padding(0);$bar.Controls.Add($presets)
    $totalWidth=0
    # Action controls must not inherit the height-resize cursor from their divider parent.
    $presets.Cursor=[Windows.Forms.Cursors]::Default
    foreach($spec in @(@(60.0,'1 min','1 min'),@(10.0,'10 s','10 s'),@(1.0,'1 s','1 s'),@(0.1,'100 ms','100 ms'))){
        $preset=New-Object Windows.Forms.Button;$preset.Text=Get-QualityText $spec[1] $spec[2]
        $preset.Width=[Windows.Forms.TextRenderer]::MeasureText($preset.Text,$preset.Font).Width+18;$preset.Height=27;$preset.Margin=New-Object Windows.Forms.Padding(0,0,4,0)
        $preset.AccessibleDescription=(Get-QualityText 'Set timeline divisions to ' 'Define divisões da linha temporal de ')+$preset.Text+'.'
        $preset.Tag=@{State=$State;Step=[double]$spec[0]};Register-ButtonActionTooltip $preset
        $preset.Add_Click({param($sender,$eventArgs) Set-TimelineScalePreset $sender.Tag.State $sender.Tag.Step})
        $presets.Controls.Add($preset);$totalWidth+=$preset.Width+4
    }
    $presets.Width=$totalWidth;$presets.Left=$button.Left-$totalWidth-8;$presets.Top=0
    $label.Width=[Math]::Max(40,$presets.Left-$label.Left-12)
    $Layout.Controls.Add($bar,0,1);$State.DataDivider=$bar
    foreach($control in @($bar,$label)){
        $control.Add_MouseDown({param($sender,$eventArgs)
            $s=$sender.FindForm().Tag
            if($eventArgs.Button -ne 'Left' -or $s.DataVisualizationHidden){return}
            $s.DataDividerDragging=$true;$s.DataDragY=[Windows.Forms.Cursor]::Position.Y
            $s.DataDragHeight=$s.DataResizeLayout.GetRowHeights()[2];$sender.Capture=$true
        })
        $control.Add_MouseMove({param($sender,$eventArgs)
            $s=$sender.FindForm().Tag
            if($s.DataDividerDragging){Set-PlaybackDataHeight $s ($s.DataDragHeight-([Windows.Forms.Cursor]::Position.Y-$s.DataDragY))}
        })
        $control.Add_MouseUp({param($sender,$eventArgs) $s=$sender.FindForm().Tag;$s.DataDividerDragging=$false;$sender.Capture=$false;Request-EventColumnFit $s.List})
        $control.Add_MouseCaptureChanged({param($sender,$eventArgs) if(-not $sender.Capture){$s=$sender.FindForm().Tag;if($s){$s.DataDividerDragging=$false;Request-EventColumnFit $s.List}}})
    }
    $button.Add_Click({param($sender,$eventArgs)
        $s=$sender.FindForm().Tag;$s.DataVisualizationHidden=-not $s.DataVisualizationHidden
        Set-PlaybackDataWindowHeight $sender.FindForm() $s
    })
    $Layout.Add_ClientSizeChanged({param($sender,$eventArgs) Update-PlaybackDataLayout $sender.FindForm().Tag})
    Update-PlaybackDataLayout $State
}
# Select by stable identity after edits, including edits which reorder timestamps.
function Select-EditedPlaybackEvent {
    param($State,[string]$Id)
    $State.EventListPinnedId=$Id
    foreach($row in $State.List.Items){
        $row.Selected=$row.Tag.id -eq $Id
        if($row.Selected){$row.Focused=$true;$row.EnsureVisible()}
    }
    [void]$State.List.Focus()
}
