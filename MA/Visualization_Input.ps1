. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
# A nearly transparent child window receives panel double-clicks above external
# media windows without forwarding playback shortcuts to those windows.
function Initialize-VisualizationInputLayer {
    if('MachiningMonitor.VisualizationInput' -as [type]){return}
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace MachiningMonitor {
 public sealed class VisualizationInput : Control {
  [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h,uint color,byte alpha,uint flags);
  public VisualizationInput() {SetStyle(ControlStyles.StandardClick|ControlStyles.StandardDoubleClick|ControlStyles.UserPaint,true);TabStop=false;}
  protected override CreateParams CreateParams {get {var p=base.CreateParams;p.ExStyle|=0x80000;return p;}}
  protected override void OnHandleCreated(EventArgs e) {base.OnHandleCreated(e);SetLayeredWindowAttributes(Handle,0,1,2);}
  protected override void OnPaint(PaintEventArgs e) {e.Graphics.Clear(Color.Black);}
 }
}
'@
}
function Test-VisualizationInteractionActive {
    param($Viewport)
    if(-not $Viewport){return $false}
    $form=$Viewport.FindForm()
    return $Viewport.Tag.Dragging -or ($form -and $form.PSObject.Properties['InteractiveResize'] -and $form.InteractiveResize) -or
        (([Windows.Forms.Control]::MouseButtons -band [Windows.Forms.MouseButtons]::Left) -ne 0)
}
function Suspend-VisualizationResizeNotice {
    param($Viewport)
    if(-not $Viewport){return}
    $c=$Viewport.Tag;$form=$Viewport.FindForm()
    if($c.State){$c.State.ResizeNoticeActive=$false;if($c.State.ResizeNoticeLabel){$c.State.ResizeNoticeLabel.Visible=$false}}
    elseif($script:RecordingUi -and $script:RecordingUi.Viewport -eq $Viewport){$script:RecordingUi.ResizeNoticeActive=$false;$script:RecordingUi.ResizeStatus.Visible=$false}
    if($form -and $form.PSObject.Methods['RevealResizeContent']){$form.RevealResizeContent()}
}
function Defer-VisualizationResizeNotice {
    param($Viewport)
    if(Test-VisualizationInteractionActive $Viewport){
        $Viewport.Tag.NoticePending=$true
        Suspend-VisualizationResizeNotice $Viewport
        return $true
    }
    if($Viewport){$Viewport.Tag.NoticePending=$false}
    return $false
}
function Initialize-VisualizationInteraction {
    param($Viewport)
    Initialize-VisualizationInputLayer
    $input=New-Object MachiningMonitor.VisualizationInput;$input.Tag=$Viewport
    $Viewport.Tag.InputLayer=$input;$Viewport.Controls.Add($input)
    $tip=New-Object MachiningMonitor.WrappingToolTip;$tip.InitialDelay=700;$tip.ReshowDelay=150;$tip.AutoPopDelay=15000
    $Viewport.Tag.InputTip=$tip
    $input.Add_MouseMove({param($sender,$eventArgs)
        if($sender.Tag.Tag.VideoPan){Move-VisualizationVideoPan $sender.Tag $eventArgs.X $eventArgs.Y;return}
        $c=$sender.Tag.Tag;$text=''
        $sender.Cursor=if(Get-VisualizationPanTarget $sender.Tag $eventArgs.X $eventArgs.Y){[Windows.Forms.Cursors]::Hand}else{[Windows.Forms.Cursors]::Default}
        if($c.Video -and $eventArgs.Y -ge 0 -and $eventArgs.Y -lt $c.Heights.Video){
            $text=Get-QualityText 'Double-click: enlarge to fit the visualization area.' 'Duplo clique: ampliar ajustando à zona de visualização.'
            if((Get-VisualizationZoomPreferences $sender.Tag)){
                $text+=[Environment]::NewLine+(Get-QualityText 'Ctrl + mouse wheel: zoom in/out centered on the pointer position.' 'Ctrl + roda do rato: ampliar/reduzir centrado na posição do rato.')
                $text+=[Environment]::NewLine+(Get-QualityText 'When enlarged, drag with the left mouse button to move the image.' 'Quando ampliada, arraste com o botão esquerdo do rato para deslocar a imagem.')
            }
            $text+=[Environment]::NewLine+(Get-QualityText 'Wheel without Ctrl: scroll vertically. Drag the separators to adjust panel heights.' 'Roda sem Ctrl: deslocar na vertical. Arraste os separadores para ajustar as alturas dos painéis.')
        }
        if($c.InputTip.GetToolTip($sender) -ne $text){$c.InputTip.SetToolTip($sender,$text)}
    })
    $input.Add_MouseLeave({$this.Tag.Tag.InputTip.Hide($this)})
    $input.Add_MouseDown({param($sender,$eventArgs)
        if($eventArgs.Button -eq 'Left' -and $eventArgs.Clicks -eq 1){Start-VisualizationVideoPan $sender.Tag $eventArgs.X $eventArgs.Y}
    })
    $input.Add_MouseUp({param($sender,$eventArgs)
        if($eventArgs.Button -eq 'Left' -and $sender.Tag.Tag.VideoPan){Move-VisualizationVideoPan $sender.Tag $eventArgs.X $eventArgs.Y;Stop-VisualizationVideoPan $sender.Tag}
    })
    $input.Add_MouseCaptureChanged({if(-not $this.Capture){Stop-VisualizationVideoPan $this.Tag}})
    $Viewport.Add_Disposed({$this.Tag.InputTip.Dispose()})
    $input.Add_MouseDoubleClick({param($sender,$eventArgs) if($eventArgs.Button -eq 'Left'){Expand-VisualizationPanel $sender.Tag $eventArgs.Y $eventArgs.X}})
    $input.Add_MouseWheel({
        param($sender,$eventArgs)
        $v=$sender.Tag
        Stop-VisualizationVideoPan $v
        if(([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Control) -ne 0 -and $v.Tag.Video -and $eventArgs.Y -ge 0 -and $eventArgs.Y -lt $v.Tag.Heights.Video){
            if($eventArgs -is [Windows.Forms.HandledMouseEventArgs]){$eventArgs.Handled=$true}
            Set-VisualizationPointerZoom $v $eventArgs.X $eventArgs.Y $eventArgs.Delta
            return
        }
        $lines=[Windows.Forms.SystemInformation]::MouseWheelScrollLines
        $step=if($lines -lt 0){$v.Height}else{[Math]::Max(1,$lines)*24}
        $offset=[Math]::Max(0,(-$v.AutoScrollPosition.Y-$eventArgs.Delta*$step/120))
        $v.AutoScrollPosition=New-Object Drawing.Point(0,([int]$offset))
        if($eventArgs -is [Windows.Forms.HandledMouseEventArgs]){$eventArgs.Handled=$true}
    })
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=50;$timer.Tag=$Viewport
    $Viewport.Tag.InteractionTimer=$timer
    $timer.Add_Tick({
        $v=$this.Tag
        Update-VisualizationVideoZoom $v
        if($v.Tag.NoticePending -and -not (Test-VisualizationInteractionActive $v)){
            $v.Tag.NoticePending=$false
            if($v.Tag.State){Start-PlaybackResizeNotice $v.Tag.State}
            elseif($script:RecordingUi -and $script:RecordingUi.Viewport -eq $v){Start-RecordingResizeNotice}
        }
    })
    $timer.Start()
    $Viewport.Add_Disposed({$this.Tag.InteractionTimer.Stop();$this.Tag.InteractionTimer.Dispose()})
}
function Expand-VisualizationPanel {
    param($Viewport,[int]$ContentY,[int]$ContentX=0)
    $c=$Viewport.Tag;$top=0;$selected=$null
    foreach($key in @('Video','Frequency','History')){
        $visible=if($key -eq 'Video'){$c.Video}else{$c.Charts}
        if(-not $visible){continue}
        if($ContentY -ge $top -and $ContentY -lt $top+$c.Heights[$key]){$selected=$key;break}
        $top+=$c.Heights[$key]
    }
    if(-not $selected){return}
    if($selected -eq 'Video' -and $c.CameraCount -gt 1){
        Switch-VisualizationCameraLayout $Viewport $ContentX $ContentY
        return
    }
    $minimum=if($selected -eq 'Video'){24}elseif($selected -eq 'Frequency'){80}else{56}
    $c.Heights[$selected]=[Math]::Max($minimum,2*[int][Math]::Floor($Viewport.Height/2))
    $c.Manual=$true;$c.Initialized=$true
    Update-VisualizationViewport $Viewport
    $Viewport.AutoScrollPosition=New-Object Drawing.Point(0,$top)
    Update-VisualizationGrips $Viewport
    Save-VisualizationResizeReference $Viewport
}
function Set-VisualizationCameraCount {
    param($Viewport,[int]$Count)
    $c=$Viewport.Tag;$previous=$c.CameraCount
    $c.CameraCount=[Math]::Max(1,$Count)
    if($c.CameraLayout -eq 'Vertical'){
        if($c.CameraCount -le 1){
            $c.CameraLayout='Horizontal'
            if($c.HorizontalVideoHeight){$c.Heights.Video=$c.HorizontalVideoHeight}
        }elseif(-not $c.Manual -or $previous -ne $c.CameraCount){$c.Heights.Video=[Math]::Max(24,2*[int][Math]::Floor($Viewport.Height/2))*$c.CameraCount}
    }
    if($previous -ne $c.CameraCount){Update-VisualizationViewport $Viewport;Save-VisualizationResizeReference $Viewport}
}
function Switch-VisualizationCameraLayout {
    param($Viewport,[int]$ContentX=0,[int]$ContentY=0)
    $c=$Viewport.Tag
    if($c.CameraCount -le 1){return}
    if($c.CameraLayout -eq 'Vertical'){
        $previousCellHeight=[Math]::Max(1,$c.Heights.Video/[double]$c.CameraCount)
        $index=[int][Math]::Floor($ContentY/$previousCellHeight)
    }else{
        $c.HorizontalVideoHeight=$c.Heights.Video
        $index=[int][Math]::Floor($ContentX*$c.CameraCount/[double][Math]::Max(1,$c.Surface.Width))
    }
    $index=[Math]::Min($c.CameraCount-1,[Math]::Max(0,$index))
    $c.CameraLayout='Vertical'
    $cellHeight=[Math]::Max(24,2*[int][Math]::Floor($Viewport.Height/2))
    $c.Heights.Video=$cellHeight*$c.CameraCount
    $c.Manual=$true;$c.Initialized=$true
    Update-VisualizationViewport $Viewport
    $Viewport.AutoScrollPosition=New-Object Drawing.Point(0,($index*$cellHeight))
    Update-VisualizationGrips $Viewport
    Save-VisualizationResizeReference $Viewport
}

function Get-VisualizationZoomPreferences {
    param($Viewport)
    $c=$Viewport.Tag
    if($c.State -and $c.State.Context.Visualization){return $c.State.Context.Visualization}
    return $c.RecordingVisualization
}
function Get-VisualizationPanTarget {
    param($Viewport,[double]$X,[double]$Y)
    $c=$Viewport.Tag;$p=Get-VisualizationZoomPreferences $Viewport
    if(-not $c.Video -or -not $p -or $X -lt 0 -or $Y -lt 0 -or $X -ge $c.Surface.Width -or $Y -ge $c.Heights.Video){return}
    $count=[Math]::Max(1,$c.CameraCount);$w=[double]$c.Surface.Width;$h=[double]$c.Heights.Video
    if($w -le 0 -or $h -le 0){return}
    if($c.CameraLayout -eq 'Vertical'){$h/=$count;$index=[int][Math]::Floor($Y/$h)}else{$w/=$count;$index=[int][Math]::Floor($X/$w)}
    if(-not $p.VideoZoom){return}
    $z=$p.VideoZoom[$index]
    if($z -and $z.Scale -gt 1.000001){return @{Index=$index;Width=$w;Height=$h;Zoom=$z;Preferences=$p}}
}
function Start-VisualizationVideoPan {
    param($Viewport,[double]$X,[double]$Y)
    Stop-VisualizationVideoPan $Viewport
    $target=Get-VisualizationPanTarget $Viewport $X $Y
    if(-not $target){return}
    $c=$Viewport.Tag;$z=$target.Zoom
    $c.VideoPan=@{Index=$target.Index;Width=$target.Width;Height=$target.Height;StartX=$X;StartY=$Y;Left=[double]$z.X;Top=[double]$z.Y;Scale=[double]$z.Scale;Preferences=$target.Preferences;Count=$c.CameraCount;Layout=$c.CameraLayout;SurfaceWidth=$c.Surface.Width;VideoHeight=$c.Heights.Video}
    $c.InputTip.Hide($c.InputLayer);$c.InputLayer.Cursor=[Windows.Forms.Cursors]::SizeAll;$c.InputLayer.Capture=$true
}
function Move-VisualizationVideoPan {
    param($Viewport,[double]$X,[double]$Y)
    $c=$Viewport.Tag;$d=$c.VideoPan
    if(-not $d){return}
    $p=Get-VisualizationZoomPreferences $Viewport
    if(-not $p -or -not $p.VideoZoom){Stop-VisualizationVideoPan $Viewport;return}
    $z=$p.VideoZoom[$d.Index]
    if(-not $c.Video -or -not [object]::ReferenceEquals($p,$d.Preferences) -or -not $z -or $z.Scale -ne $d.Scale -or $c.CameraCount -ne $d.Count -or $c.CameraLayout -ne $d.Layout -or $c.Surface.Width -ne $d.SurfaceWidth -or $c.Heights.Video -ne $d.VideoHeight){Stop-VisualizationVideoPan $Viewport;return}
    $limit=1.0-1.0/$d.Scale
    $left=[Math]::Max(0.0,[Math]::Min($limit,$d.Left-($X-$d.StartX)/($d.Width*$d.Scale)))
    $top=[Math]::Max(0.0,[Math]::Min($limit,$d.Top-($Y-$d.StartY)/($d.Height*$d.Scale)))
    $p.VideoZoom[$d.Index]=@{Scale=$d.Scale;X=$left;Y=$top}
    Update-VisualizationVideoZoom $Viewport
}
function Stop-VisualizationVideoPan {
    param($Viewport)
    $c=$Viewport.Tag
    $c.VideoPan=$null
    if($c.InputLayer){$c.InputLayer.Capture=$false;$c.InputLayer.Cursor=[Windows.Forms.Cursors]::Default}
}
function Set-VisualizationPointerZoom {
    param($Viewport,[double]$X,[double]$Y,[int]$Delta)
    $c=$Viewport.Tag;$state=$c.State
    $p=Get-VisualizationZoomPreferences $Viewport
    if(-not $Delta -or $null -eq $p){return}
    $count=[Math]::Max(1,$c.CameraCount);$w=[double]$c.Surface.Width;$h=[double]$c.Heights.Video
    if($w -le 0 -or $h -le 0){return}
    $index=0
    if($c.CameraLayout -eq 'Vertical'){$h/=$count;$index=[int][Math]::Floor($Y/$h);$Y-=$index*$h}
    else{$w/=$count;$index=[int][Math]::Floor($X/$w);$X-=$index*$w}
    if($index -lt 0 -or $index -ge $count){return}
    if(-not $p.VideoZoom){$p.VideoZoom=@{}}
    $old=$p.VideoZoom[$index];if(-not $old){$old=@{Scale=1.0;X=0.0;Y=0.0}}
    $scale=[Math]::Max(1.0,[Math]::Min(16.0,$old.Scale*[Math]::Pow(1.1,$Delta/120.0)))
    $span=1.0/$scale;$previous=1.0/$old.Scale
    $left=[Math]::Max(0.0,[Math]::Min(1.0-$span,$old.X+($X/$w)*($previous-$span)))
    $top=[Math]::Max(0.0,[Math]::Min(1.0-$span,$old.Y+($Y/$h)*($previous-$span)))
    $p.VideoZoom[$index]=@{Scale=$scale;X=$left;Y=$top}
    Update-VisualizationVideoZoom $Viewport
}
# The producer and its audio/plot clock keep running. Only the decoded camera
# rectangle is cropped and enlarged in mpv; the remaining pixels pass through.
function Get-VisualizationVideoZoomGraph {
    param($Viewport)
    $c=$Viewport.Tag;$p=Get-VisualizationZoomPreferences $Viewport
    if(-not $c.Video -or -not $p.VideoZoom.Count){return ''}
    $count=[Math]::Max(1,$c.CameraCount)
    $width=[Math]::Max(320,2*[int][Math]::Floor($c.Surface.Width/2))
    $height=[Math]::Max(24,2*[int][Math]::Floor($c.Heights.Video/2))
    $cw=$width;$ch=$height
    if($c.CameraLayout -eq 'Vertical'){$ch=[Math]::Max(24,2*[int][Math]::Floor($height/$count/2))}
    else{$cw=2*[int][Math]::Floor($width/$count/2)}
    $graph='';$previous='in';$n=0
    foreach($i in @($p.VideoZoom.Keys | Sort-Object)){
        $z=$p.VideoZoom[$i]
        if($i -ge $count -or $z.Scale -le 1.000001){continue}
        $x=0;$y=0
        if($c.CameraLayout -eq 'Vertical'){$y=$i*$ch}else{$x=$i*$cw}
        $cropW=[Math]::Max(2,2*[int][Math]::Floor($cw/$z.Scale/2))
        $cropH=[Math]::Max(2,2*[int][Math]::Floor($ch/$z.Scale/2))
        $cropX=$x+2*[int][Math]::Floor($cw*$z.X/2)
        $cropY=$y+2*[int][Math]::Floor($ch*$z.Y/2)
        $graph+="[${previous}]split=2[base${n}][cell${n}];[cell${n}]crop=${cropW}:${cropH}:${cropX}:${cropY},scale=${cw}:${ch}:flags=bilinear[zoom${n}];[base${n}][zoom${n}]overlay=${x}:${y}:eval=init:shortest=1[stage${n}];"
        $previous="stage${n}";$n++
    }
    if(-not $n){return ''}
    return $graph+"[${previous}]null[out]"
}
# Sample the displayed texture directly: works on the retained paused frame too.
function Get-VisualizationZoomShader {
    param($Viewport)
    $c=$Viewport.Tag;$p=Get-VisualizationZoomPreferences $Viewport
    $width=[Math]::Max(320,2*[int][Math]::Floor($c.Surface.Width/2))
    $height=[Math]::Max(24,2*[int][Math]::Floor($c.Heights.Video/2))
    $count=[Math]::Max(1,$c.CameraCount);$cw=$width;$ch=$height
    if($c.CameraLayout -eq 'Vertical'){$ch=[Math]::Max(24,2*[int][Math]::Floor($height/$count/2))}
    else{$cw=2*[int][Math]::Floor($width/$count/2)}
    $code="//!HOOK MAIN`n//!BIND HOOKED`nvec4 hook() {`nvec2 pixel = HOOKED_pos * HOOKED_size;`n"
    if($c.Video){foreach($i in @($p.VideoZoom.Keys | Sort-Object)){
        $z=$p.VideoZoom[$i];if($i -ge $count -or $z.Scale -le 1.000001){continue}
        $x=0;$y=0
        if($c.CameraLayout -eq 'Vertical'){$y=$i*$ch}else{$x=$i*$cw}
        $culture=[Globalization.CultureInfo]::InvariantCulture
        $scale=([double]$z.Scale).ToString('0.########',$culture)
        $zx=([double]$z.X).ToString('0.########',$culture)
        $zy=([double]$z.Y).ToString('0.########',$culture)
        $code+="if(pixel.x >= $x.0 && pixel.x < $($x+$cw).0 && pixel.y >= $y.0 && pixel.y < $($y+$ch).0) {`n"
        $code+="vec2 origin = vec2($x.0,$y.0); vec2 cell = vec2($cw.0,$ch.0);`n"
        $code+="vec2 source = origin + cell * vec2($zx,$zy) + (pixel-origin)/$scale;`n"
        $code+="return HOOKED_tex(clamp(source,origin+vec2(0.5),origin+cell-vec2(0.5))/HOOKED_size); }`n"
    }}
    return $code+"return HOOKED_tex(HOOKED_pos); }`n"
}
function Update-VisualizationVideoZoom {
    param($Viewport)
    $c=$Viewport.Tag;$s=$c.State
    if(-not $s){$s=$c.RecordingZoomState}
    if(-not $s -or -not $s.NativeMpv -or -not $s.Clock.Connected -or -not $s.Clock.Ready -or $s.Seeking){return}
    $shader=Get-VisualizationZoomShader $Viewport
    if($c.ZoomShader -eq $shader -and [object]::ReferenceEquals($c.ZoomClock,$s.Clock)){return}
    try {
        if(-not $c.ZoomShaderDirectory){
            $c.ZoomShaderDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ma-zoom-'+[guid]::NewGuid().ToString('N'))
            $null=[IO.Directory]::CreateDirectory($c.ZoomShaderDirectory)
            $Viewport.Add_Disposed({
                foreach($file in [IO.Directory]::GetFiles($this.Tag.ZoomShaderDirectory,'zoom*.glsl')){
                    [IO.File]::Delete($file)
                }
                if([IO.Directory]::Exists($this.Tag.ZoomShaderDirectory)){[IO.Directory]::Delete($this.Tag.ZoomShaderDirectory)}
            })
        }
        # mpv caches shader source by path. Never overwrite a cached shader:
        # each zoom state gets an immutable file, retained until this view closes.
        $c.ZoomShaderSequence=1+[long]$c.ZoomShaderSequence
        $path=Join-Path $c.ZoomShaderDirectory ('zoom'+$c.ZoomShaderSequence+'.glsl')
        [IO.File]::WriteAllText($path,$shader,(New-Object Text.UTF8Encoding($false)))
        # A fresh path reloads the new source and redraws the paused frame too.
        $s.Clock.Command('change-list','glsl-shaders','set',[string]$path)
        $c.ZoomShader=$shader;$c.ZoomClock=$s.Clock
    }catch{$c.ZoomShader=$null}
}
