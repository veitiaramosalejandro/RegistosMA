. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
. (Join-Path $PSScriptRoot 'Visualization_Input.ps1')
# A scrollable composed-media surface with independent panel heights.
function New-VisualizationViewport {
    param($Surface)
    $v=New-Object Windows.Forms.Panel;$v.Dock='Fill';$v.Margin=New-Object Windows.Forms.Padding(0)
    $v.AutoScroll=$true;$v.BackColor=[Drawing.Color]::Black
    $v.Tag=@{Surface=$Surface;Updating=$false;Syncing=$false;Initialized=$false;Manual=$false;ResizeReference=$null;NoticePending=$false;SplittersTransition=$false;InputLayer=$null;Video=$true;Charts=$true;CameraLayout='Horizontal';CameraCount=1;HorizontalVideoHeight=$null;Heights=@{Video=240;Frequency=120;History=80};Grips=@{};GripUpdating=$false;Dragging=$false;Drag=$null;MinimumHeight=0;State=$null}
    $Surface.Dock='None';$Surface.Anchor='Top,Left';$Surface.Location=New-Object Drawing.Point(0,0)
    $v.Controls.Add($Surface);Initialize-VisualizationInteraction $v;$v.Add_ClientSizeChanged({Resize-VisualizationWithWindow $this});$v.Add_Scroll({Update-VisualizationGrips $this})
    Update-VisualizationViewport $v
    return $v
}
# Scale from the most recently displayed proportions, including proportions
# produced by a previous window resize or minimum-height constraint.
function Save-VisualizationResizeReference {
    param($Viewport,$ExactHeights=$null)
    $c=$Viewport.Tag
    if(-not $c.Initialized -or $Viewport.Height -le 0){return}
    $copy=@{}
    foreach($key in $c.Heights.Keys){$copy[$key]=if($ExactHeights){[double]$ExactHeights[$key]}else{[double]$c.Heights[$key]}}
    $c.ResizeReference=@{Available=$Viewport.Height;Heights=$copy}
}
function Resize-VisualizationWithWindow {
    param($Viewport)
    $window=$Viewport.FindForm()
    if($window -and ($window.WindowState -eq 'Minimized' -or ($window.PSObject.Properties['ResizeSuppressed'] -and $window.ResizeSuppressed))){return}
    $c=$Viewport.Tag
    if($c.Updating -or $c.Dragging){return}
    $reference=$c.ResizeReference;$available=$Viewport.Height;$exact=$null
    if($c.Initialized -and $c.CameraLayout -eq 'Vertical' -and $c.CameraCount -gt 1){
        $c.Heights.Video=[Math]::Max(24,2*[int][Math]::Floor($available/2))*$c.CameraCount
        if($reference -and $reference.Available -gt 0 -and $available -gt 0){
            $scale=$available/[double]$reference.Available
            if($c.HorizontalVideoHeight){$c.HorizontalVideoHeight=[Math]::Max(24,2*[int][Math]::Round($c.HorizontalVideoHeight*$scale/2))}
            foreach($key in @('Frequency','History')){
                $minimum=56;if($key -eq 'Frequency'){$minimum=80}
                $c.Heights[$key]=[Math]::Max($minimum,[Math]::Min(4096,2*[int][Math]::Round($reference.Heights[$key]*$scale/2)))
            }
        }
        Update-VisualizationViewport $Viewport;Save-VisualizationResizeReference $Viewport
        return
    }
    if($c.Initialized -and $reference -and $available -gt 0){
        $scale=$available/[double]$reference.Available
        $active=@();if($c.Video){$active+='Video'};if($c.Charts){$active+=@('Frequency','History')}
        $minimum=@{Video=24;Frequency=80;History=56}
        $baseTotal=0.0;$minimumTotal=0.0;$exactTotal=0.0;$exact=@{}
        foreach($key in @('Video','Frequency','History')){
            $exact[$key]=[Math]::Max([double]$minimum[$key],[Math]::Min(4096.0,[double]$reference.Heights[$key]*$scale))
        }
        foreach($key in $active){$baseTotal+=$reference.Heights[$key];$minimumTotal+=$minimum[$key];$exactTotal+=$exact[$key]}
        $exactTarget=[Math]::Max($minimumTotal,$baseTotal*$scale)
        foreach($key in @($active|Sort-Object {$exact[$_]} -Descending)){
            if($exactTotal -le $exactTarget){break}
            $reduce=[Math]::Min($exactTotal-$exactTarget,$exact[$key]-$minimum[$key])
            $exact[$key]-=$reduce;$exactTotal-=$reduce
        }
        # Render even pixel dimensions, but retain fractional heights for the
        # next resize message. One-pixel mouse steps must accumulate instead of
        # repeatedly discarding their fractions and shrinking the composition.
        $total=0
        foreach($key in @('Video','Frequency','History')){
            $c.Heights[$key]=[Math]::Max($minimum[$key],[Math]::Min(4096,2*[int][Math]::Round($exact[$key]/2)))
        }
        foreach($key in $active){$total+=$c.Heights[$key]}
        $target=2*[int][Math]::Floor($exactTarget/2+0.000000001)
        foreach($key in @($active|Sort-Object {$c.Heights[$_]} -Descending)){
            if($total -le $target){break}
            $reduce=[Math]::Min($total-$target,$c.Heights[$key]-$minimum[$key])
            $c.Heights[$key]-=$reduce;$total-=$reduce
        }
        foreach($key in $active){
            if($total -ge $target){break}
            $grow=[Math]::Min($target-$total,4096-$c.Heights[$key])
            $c.Heights[$key]+=$grow;$total+=$grow
        }
    }
    Update-VisualizationViewport $Viewport
    Save-VisualizationResizeReference $Viewport $exact
}
function Get-VisualizationContentHeight {
    param($Viewport)
    $c=$Viewport.Tag;$height=0
    if($c.Video){$height+=$c.Heights.Video}
    if($c.Charts){$height+=$c.Heights.Frequency+$c.Heights.History}
    return $height
}
function Update-VisualizationViewport {
    param($Viewport)
    $c=$Viewport.Tag;if($c.Updating){return};$c.Updating=$true
    try {
        $height=Get-VisualizationContentHeight $Viewport
        if(-not $c.Initialized -or $height -eq 0){$height=[Math]::Max(1,$Viewport.Height)}
        $c.MinimumHeight=$height
        $scroll=$height -gt $Viewport.Height
        $width=[Math]::Max(1,$Viewport.Width-2-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth)
        $c.Surface.Size=New-Object Drawing.Size($width,$height)
        $Viewport.AutoScrollMinSize=New-Object Drawing.Size(0,$height)
        Update-VisualizationGrips $Viewport
        if($c.State -and $c.State.Context -and $c.State.Context.AdaptivePlots){
            $p=$c.State.Context.Visualization
            $p.ShowVideo=$c.Video;$p.ShowCharts=$c.Charts
            $p.VideoPanelHeight=$c.Heights.Video;$p.FrequencyPanelHeight=$c.Heights.Frequency;$p.HistoryPanelHeight=$c.Heights.History
            $p.CameraLayout=$c.CameraLayout
        }
    }finally{$c.Updating=$false}
}
function Fit-VisualizationToWindow {
    param($Viewport)
    $c=$Viewport.Tag;$available=2*[int][Math]::Floor($Viewport.Height/2)
    if($available -le 0){return}
    $c.CameraLayout='Horizontal';$c.HorizontalVideoHeight=$null
    $c.Initialized=$true;$c.Manual=$false
    if($c.Video -and $c.Charts){
        $c.Heights.Video=[Math]::Max(24,[Math]::Min($available-136,2*[int][Math]::Floor(($available*540.0/956)/2)))
        $remaining=$available-$c.Heights.Video
        $c.Heights.Frequency=[Math]::Max(80,[Math]::Min($remaining-56,2*[int][Math]::Floor(($remaining*256.0/416)/2)))
        $c.Heights.History=[Math]::Max(56,$remaining-$c.Heights.Frequency)
    }elseif($c.Video){$c.Heights.Video=[Math]::Max(24,$available)}
    elseif($c.Charts){
        $c.Heights.Frequency=[Math]::Max(80,[Math]::Min($available-56,2*[int][Math]::Floor(($available*256.0/416)/2)))
        $c.Heights.History=[Math]::Max(56,$available-$c.Heights.Frequency)
    }
    $Viewport.AutoScrollPosition=New-Object Drawing.Point(0,0)
    Update-VisualizationViewport $Viewport
    Save-VisualizationResizeReference $Viewport
}
function Set-VisualizationSelection {
    param($Viewport,[bool]$Video,[bool]$Charts)
    $c=$Viewport.Tag;$changed=$c.Video -ne $Video -or $c.Charts -ne $Charts
    $c.Video=$Video;$c.Charts=$Charts
    if($changed -and $c.Initialized){Fit-VisualizationToWindow $Viewport}else{Update-VisualizationViewport $Viewport;if($changed){Save-VisualizationResizeReference $Viewport}}
}
# Grips are siblings of the native video surface, so they remain interactive even
# when the embedded player is disabled for keyboard/mouse playback shortcuts.
function Update-VisualizationGrips {
    param($Viewport)
    $c=$Viewport.Tag;if($c.GripUpdating){return};$c.GripUpdating=$true
    try{
        if($c.InputLayer){
            $c.InputLayer.SetBounds($c.Surface.Left,$c.Surface.Top,$c.Surface.Width,$c.Surface.Height)
            $c.InputLayer.Visible=$c.Initialized -and ($c.Video -or $c.Charts)
            $c.InputLayer.BringToFront()
        }
        $transition=[bool]$c.SplittersTransition -or ($c.State -and $c.State.ResizeNoticeActive)
        $bottom=0
        foreach($key in @('Video','Frequency','History')){
            if(-not $c.Grips.ContainsKey($key)){continue}
            $grip=$c.Grips[$key]
            $visible=if($key -eq 'Video'){$c.Video}else{$c.Charts}
            $boundary=($key -eq 'Video' -and $c.Video -and $c.Charts) -or ($key -eq 'Frequency' -and $c.Charts)
            $grip.Visible=$boundary -and $c.Initialized -and (-not $transition -or (Test-VisualizationInteractionActive $Viewport))
            if($visible){
                $bottom+=$c.Heights[$key]
                $grip.SetBounds(0,($bottom-8+$Viewport.AutoScrollPosition.Y),$c.Surface.Width,8)
                $grip.BringToFront()
            }
        }
        Update-VisualizationMessageLayers $Viewport
    }finally{$c.GripUpdating=$false}
}
function Start-VisualizationHeightDrag {
    param($Grip,[int]$ScreenY)
    $v=$Grip.Tag.Viewport;$c=$v.Tag;$key=$Grip.Tag.Key
    $peer=if($key -eq 'Video' -and $c.Video -and $c.Charts){'Frequency'}elseif($key -eq 'Frequency' -and $c.Charts){'History'}else{$null}
    if(-not $peer){return}
    $c.Drag=@{Key=$key;Peer=$peer;StartY=$ScreenY;Height=$c.Heights[$key];PeerHeight=$c.Heights[$peer];ScrollY=$v.AutoScrollPosition.Y}
    $c.Dragging=$true;Suspend-VisualizationResizeNotice $v;$Grip.Capture=$true
    $Grip.BackColor=[Drawing.Color]::SteelBlue
}
function Move-VisualizationHeightDrag {
    param($Grip,[int]$ScreenY)
    $v=$Grip.Tag.Viewport;$c=$v.Tag;if(-not $c.Dragging -or -not $c.Drag){return}
    $key=$c.Drag.Key
    $peer=$c.Drag.Peer
    $limits=@{Video=24;Frequency=80;History=56}
    $height=$c.Drag.Height+$ScreenY-$c.Drag.StartY+$c.Drag.ScrollY-$v.AutoScrollPosition.Y
    $current=@{};foreach($name in $c.Heights.Keys){$current[$name]=$c.Heights[$name]}
    # Move one boundary only: preserve its two-panel total and every other panel.
    $total=$c.Drag.Height+$c.Drag.PeerHeight
    $lower=[Math]::Max($limits[$key],$total-4096)
    $upper=[Math]::Min(4096,$total-$limits[$peer])
    $c.Heights[$key]=[Math]::Max($lower,[Math]::Min($upper,2*[int][Math]::Round($height/2.0)))
    $c.Heights[$peer]=$total-$c.Heights[$key]
    $c.Manual=$true;$c.Initialized=$true
    foreach($name in $current.Keys){if($c.Heights[$name] -ne $current[$name]){$c.NoticePending=$true;break}}
    Update-VisualizationViewport $v
}
function Stop-VisualizationHeightDrag {
    param($Grip)
    $c=$Grip.Tag.Viewport.Tag
    $c.Dragging=$false;$c.Drag=$null;$Grip.Capture=$false
    Save-VisualizationResizeReference $Grip.Tag.Viewport
    $Grip.BackColor=[Drawing.Color]::FromArgb(50,50,50)
    Update-VisualizationGrips $Grip.Tag.Viewport
}
function Add-VisualizationSizingControls {
    param($Bar,$Viewport)
    $Bar.Height=32
    $tip=New-Object MachiningMonitor.WrappingToolTip;$Viewport.Tag.GripTip=$tip
    foreach($key in @('Video','Frequency')){
        $grip=New-Object Windows.Forms.Panel;$grip.Cursor=[Windows.Forms.Cursors]::HSplit
        $grip.BackColor=[Drawing.Color]::FromArgb(50,50,50);$grip.TabStop=$false
        $grip.Tag=@{Viewport=$Viewport;Key=$key};$Viewport.Tag.Grips[$key]=$grip
        $Viewport.Controls.Add($grip)
        $grip.Add_Paint({
            param($sender,$eventArgs)
            $x=[int]($sender.Width/2)
            $eventArgs.Graphics.DrawLine([Drawing.Pens]::Silver,($x-18),2,($x+18),2)
            $eventArgs.Graphics.DrawLine([Drawing.Pens]::Silver,($x-18),5,($x+18),5)
        })
        $grip.Add_MouseDown({param($sender,$eventArgs) if($eventArgs.Button -eq 'Left'){Start-VisualizationHeightDrag $sender ([Windows.Forms.Cursor]::Position.Y)}})
        $grip.Add_MouseMove({param($sender,$eventArgs) if($sender.Capture){Move-VisualizationHeightDrag $sender ([Windows.Forms.Cursor]::Position.Y)}})
        $grip.Add_MouseUp({param($sender,$eventArgs) if($eventArgs.Button -eq 'Left'){Stop-VisualizationHeightDrag $sender}})
        $grip.Add_MouseCaptureChanged({if(-not $this.Capture -and $this.Tag.Viewport.Tag.Dragging){Stop-VisualizationHeightDrag $this}})
    }
    $Viewport.Add_Disposed({$this.Tag.GripTip.Dispose()})
    $fit=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $fit;$fit.Text=Get-QualityText 'Readjust panels to window' 'Reajustar painéis à janela';$fit.SetBounds(330,2,220,28);$fit.Tag=$Viewport
    $fit.Add_Click({Fit-VisualizationToWindow $this.Tag});$Bar.Controls.Add($fit);$Viewport.Tag.FitButton=$fit
    Update-VisualizationSizingLanguage $Viewport
    Update-VisualizationViewport $Viewport
}
function Get-VisualizationRenderKey {
    param($Size,$Parameters)
    $cameraLayout='Horizontal';if($Parameters.CameraLayout){$cameraLayout=$Parameters.CameraLayout}
    return ('{0}/{1}/{2}/{3}/{4}/{5}/{6}/{7}' -f $Size.Width,$Size.Height,$Parameters.ShowVideo,$Parameters.ShowCharts,$Parameters.VideoPanelHeight,$Parameters.FrequencyPanelHeight,$Parameters.HistoryPanelHeight,$cameraLayout)
}
function Update-RecordingViewChoices {
    $u=$script:RecordingUi;if(-not $u){return}
    $u.ShowVideo.Enabled=$u.Mode.SelectedIndex -ne 1
    $cameraOnly=$u.Mode.SelectedIndex -eq 2
    $u.ShowCharts.Enabled=-not $cameraOnly
    $u.ActiveView.Checked=($u.ShowVideo.Checked -and $u.ShowVideo.Enabled) -or ($u.ShowCharts.Checked -and $u.ShowCharts.Enabled)
    Set-VisualizationSelection $u.Viewport ($u.ShowVideo.Checked -and $u.ShowVideo.Enabled) ($u.ShowCharts.Checked -and $u.ShowCharts.Enabled)
    if($u.ActiveView.Parent.Tag){Set-RecordingControlsLayout $u.ActiveView.Parent}
}
function Update-PlaybackViewChoices {
    param($State)
    if(-not $State.Context){return}
    $State.Viewport.Tag.State=$State
    Set-VisualizationSelection $State.Viewport ($State.ShowVideo.Checked -and $State.ShowVideo.Enabled) ($State.ShowCharts.Checked -and $State.ShowCharts.Enabled)
    if($State.Context.AdaptivePlots){$State.AppliedPlotLayout=$null}else{$State.VideoHost.Visible=$State.ShowVideo.Checked -and $State.ShowVideo.Enabled}
}
function Add-PlaybackViewChoices {
    param($Form)
    $s=$Form.Tag;$s.ShowVideo.Enabled=$s.Context.PlaybackSettings.HasVideo;$s.ShowCharts.Enabled=$s.Context.AdaptivePlots
    $s.ShowVideo.Checked=$s.ShowVideo.Enabled;$s.ShowCharts.Checked=$s.ShowCharts.Enabled
    Update-PlaybackViewChoices $s
    Fit-VisualizationToWindow $s.Viewport
}

function Update-VisualizationSizingLanguage {
    param($Viewport)
    $c=$Viewport.Tag
    if(-not $c.FitButton){return}
    $c.FitButton.Text=Get-QualityText 'Readjust panels to window' 'Reajustar painéis à janela'
    Update-VisualizationMessageLayers $Viewport
    $texts=@{
        Video=(Get-QualityText 'Drag to resize video and spectrum' 'Arraste para ajustar o vídeo e o espectro')
        Frequency=(Get-QualityText 'Drag to resize spectrum and spectrogram' 'Arraste para ajustar o espectro e o espectrograma')
    }
    foreach($key in $c.Grips.Keys){$c.Grips[$key].AccessibleName=$texts[$key];$c.GripTip.SetToolTip($c.Grips[$key],$texts[$key])}
}

# Messages sit above the entire viewport, outside its scrolling/native children.
function Update-VisualizationMessageLayers {
    param($Viewport)
    $c=$Viewport.Tag;$parent=$Viewport.Parent
    if(-not $parent){return}
    if(-not $c.EmptyLayer){
        $label=New-Object Windows.Forms.Label
        $label.BackColor=[Drawing.Color]::Black;$label.ForeColor=[Drawing.Color]::Silver
        $label.TextAlign='MiddleCenter';$label.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Regular)
        $label.Padding=New-Object Windows.Forms.Padding(24)
        $label.Visible=$false;$c.EmptyLayer=$label;$parent.Controls.Add($label)
    }
    $c.EmptyLayer.Text=Get-QualityText 'To view video or charts, enable the corresponding options above.' 'Para visualizar o vídeo ou os gráficos, ative as respetivas opções em cima.'
    $c.EmptyLayer.Bounds=$Viewport.Bounds
    $c.EmptyLayer.Visible=$c.Initialized -and -not $c.Video -and -not $c.Charts
    if($c.EmptyLayer.Visible){$c.EmptyLayer.BringToFront()}
    if($c.ResizeLayer){
        if($c.ResizeLayer.Parent -eq $Viewport){
            # Cover the whole visible content, including separator positions.
            $layer=$c.ResizeLayer;$layer.Bounds=$Viewport.ClientRectangle
            $previous=$layer.Region;$layer.Region=$null
            if($previous){$previous.Dispose()}
        }else{$c.ResizeLayer.Bounds=$Viewport.Bounds}
        if($c.ResizeLayer.Visible){$c.ResizeLayer.BringToFront()}
    }
}
