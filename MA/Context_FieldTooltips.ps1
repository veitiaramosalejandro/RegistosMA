. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
function Get-ContextFieldHelp {
    param([string]$Name)
    $texts=@{
        Machine=@('Machine identifier.','Identificação da máquina.')
        Operator=@('Name or identifier of the operator.','Nome ou identificação do operador.')
        Work=@('Name or identifier of the machining program.','Nome ou identificação do programa de maquinagem.')
        Part=@('Name or reference of the part being machined.','Nome ou referência da peça em maquinagem.')
        PartMaterial=@('Material of the workpiece.','Material da peça a maquinar.')
        Operation=@('Machining operation performed in this context/program.','Operação de maquinagem realizada neste contexto/programa.')
        Strategy=@('Description of the machining strategy or toolpath.','Descrição da estratégia de maquinagem ou do percurso da ferramenta.')
        Tool=@('Name or reference identifying the cutting tool.','Nome ou referência que identifica a ferramenta de corte.')
        Type=@('Type of cutting tool, such as an end mill or drill.','Tipo de ferramenta de corte, por exemplo fresa ou broca.')
        Material=@('Cutting material of the tool or its inserts.','Material de corte da ferramenta ou das suas pastilhas.')
        HeightMm=@('Tool height TH, in millimetres.','Altura da ferramenta TH, em milímetros.')
        DiameterMm=@('Tool cutting diameter TD, in millimetres.','Diâmetro de corte da ferramenta TD, em milímetros.')
        CornerRadiusMm=@('Tool corner radius TR, in millimetres.','Raio de canto da ferramenta TR, em milímetros.')
        Flutes=@('Number of cutting teeth or inserts TZ.','Número de dentes ou navalhas de corte TZ.')
        UsageTimeAtProgramStartMinutes=@('Accumulated tool usage time at program start, as hours:minutes:seconds.','Tempo de utilização acumulado da ferramenta no início do programa, em horas:minutos:segundos.')
        ProgrammedRpm=@('Programmed spindle speed, in revolutions per minute (rpm).','Velocidade do fuso programada, em rotações por minuto (rpm).')
        AdjustedRpm=@('Spindle speed after applying the adjustment percentage, in rpm.','Velocidade do fuso após aplicar a percentagem de ajuste, em rpm.')
        ProgrammedMmPerMin=@('Programmed feed rate, in millimetres per minute.','Avanço programado, em milímetros por minuto.')
        AdjustedMmPerMin=@('Feed rate after applying the adjustment percentage, in millimetres per minute.','Avanço após aplicar a percentagem de ajuste, em milímetros por minuto.')
        AdjustmentPercent=@('Percentage of the programmed value: 100% keeps it unchanged; 80% gives 80% of that value.','Percentagem do valor programado: 100% mantém o valor; 80% corresponde a 80% desse valor.')
        StkXY=@('Stock allowance left in the XY plane, in millimetres.','Sobremetal deixado no plano XY, em milímetros.')
        StkZ=@('Stock allowance left along the Z axis, in millimetres.','Sobremetal deixado no eixo Z, em milímetros.')
        IncXY=@('Machining increment in the XY plane, in millimetres.','Incremento de maquinagem no plano XY, em milímetros.')
        IncZ=@('Machining increment along the Z axis, in millimetres.','Incremento de maquinagem no eixo Z, em milímetros.')
        Notes=@('Additional notes about the context/program, tool or machining conditions.','Notas adicionais sobre o contexto/programa, a ferramenta ou as condições de maquinagem.')
        SaveDefaults=@('Also use these values as defaults for future recordings.','Utiliza também estes valores como predefinições para futuras gravações.')
        AbsoluteStart=@('Calendar date and time when this interval starts. Read-only.','Data e hora de início deste intervalo no calendário. Apenas de leitura.')
        AbsoluteEnd=@('Calendar date and time when this interval ends. Read-only.','Data e hora de fim deste intervalo no calendário. Apenas de leitura.')
        StartClock=@('Start relative to the recording, as hours:minutes:seconds.milliseconds. The initial context/program starts at zero.','Início relativo à gravação, em horas:minutos:segundos.milissegundos. O contexto/programa inicial começa em zero.')
        StartSeconds=@('Start relative to the recording, in seconds with millisecond precision.','Início relativo à gravação, em segundos com precisão de milissegundos.')
        EndClock=@('End relative to the recording. A context/program ends at the next context/program or at the recording end.','Fim relativo à gravação. Um contexto/programa termina no contexto/programa seguinte ou no fim da gravação.')
        EndSeconds=@('End relative to the recording, expressed in seconds.','Fim relativo à gravação, expresso em segundos.')
        DurationClock=@('Calculated end minus start, as hours:minutes:seconds.milliseconds.','Diferença calculada entre fim e início, em horas:minutos:segundos.milissegundos.')
        DurationSeconds=@('Calculated interval duration, expressed in seconds.','Duração calculada do intervalo, expressa em segundos.')
        Stock=@('Material allowance left for a later operation, specified separately for XY and Z.','Sobremetal deixado para uma operação posterior, indicado separadamente para XY e Z.')
        Increment=@('Machining step size, specified separately for XY and Z.','Passo de maquinagem, indicado separadamente para XY e Z.')
        SpindleSpeed=@('Programmed spindle speed, adjustment percentage and resulting speed, in rpm.','Rotação programada do fuso, percentagem de ajuste e rotação resultante, em rpm.')
        FeedRate=@('Programmed feed rate, adjustment percentage and resulting feed, in mm/min.','Avanço programado, percentagem de ajuste e avanço resultante, em mm/min.')
    }
    if(-not $texts.ContainsKey($Name)){return ''}
    return (Get-QualityText $texts[$Name][0] $texts[$Name][1])
}
function Set-ContextFieldTooltip {
    param($Control,[string]$Name)
    $form=$Control.FindForm();if(-not $form){return}
    if(-not $form.PSObject.Properties['ContextFieldTips']){
        $tip=New-Object MachiningMonitor.WrappingToolTip;$tip.AutoPopDelay=15000;$tip.InitialDelay=200;$tip.ReshowDelay=50
        $form | Add-Member NoteProperty ContextFieldTips $tip
        # Disabled inputs do not receive the mouse messages used by native tooltips.
        $timer=New-Object Windows.Forms.Timer;$timer.Interval=100;$timer.Tag=$form
        $form | Add-Member NoteProperty ContextHelpTimer $timer
        $form | Add-Member NoteProperty ContextHelpHover $null
        $form | Add-Member NoteProperty ContextHelpSince ([datetime]::UtcNow)
        $form | Add-Member NoteProperty ContextHelpShown $false
        $timer.Add_Tick({
            $f=$this.Tag
            if(-not $f.Visible -or [Windows.Forms.Form]::ActiveForm -ne $f){return}
            $point=$f.PointToClient([Windows.Forms.Cursor]::Position)
            $hit=Find-ContextHelpControl $f $point
            if($hit -and $hit.Enabled){$hit=$null}
            if($f.ContextHelpHover -ne $hit){
                if($f.ContextHelpShown){$f.ContextFieldTips.Hide($f)}
                $f.ContextHelpHover=$hit;$f.ContextHelpSince=[datetime]::UtcNow;$f.ContextHelpShown=$false
            }
            if($hit -and -not $f.ContextHelpShown -and ([datetime]::UtcNow-$f.ContextHelpSince).TotalMilliseconds -ge 200){
                $f.ContextFieldTips.Show($f.ContextFieldTips.GetToolTip($hit),$f,($point.X+14),($point.Y+20),15000)
                $f.ContextHelpShown=$true
            }
        })
        $timer.Start()
        $form.Add_Disposed({$this.ContextHelpTimer.Stop();$this.ContextHelpTimer.Dispose();$this.ContextFieldTips.Dispose()})
    }
    $form.ContextFieldTips.SetToolTip($Control,(Get-ContextFieldHelp $Name))
    foreach($child in $Control.Controls){Set-ContextFieldTooltip $child $Name}
}
function Find-ContextHelpControl {
    param($Parent,[Drawing.Point]$Point)
    $child=$Parent.GetChildAtPoint($Point,[Windows.Forms.GetChildAtPointSkip]::Invisible)
    if($child){
        $inner=New-Object Drawing.Point(($Point.X-$child.Left),($Point.Y-$child.Top))
        $found=Find-ContextHelpControl $child $inner
        if($found){return $found}
    }
    $form=$Parent.FindForm()
    if($form -and $form.ContextFieldTips.GetToolTip($Parent)){return $Parent}
    return $null
}
