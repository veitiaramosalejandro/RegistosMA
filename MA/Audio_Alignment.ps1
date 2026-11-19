. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
#Requires -Version 5.1
# Per-block offsets are applied to a bounded PCM stream of the original WAVs.
# Only the table and small temporary analysis windows are written to disk.
function Get-AlignmentSignature {
    param([string]$Folder)
    $files=@(Get-RecordingFiles $Folder 'video' 'mp4')+@(Get-RecordingFiles $Folder 'audio' 'wav')
    foreach($name in @('video_segments.csv','audio_segments.csv')){$p=Join-Path $Folder $name;if([IO.File]::Exists($p)){$files+=Get-Item -LiteralPath $p}}
    $text=(@($files | ForEach-Object {$_.Name+'|'+$_.Length+'|'+$_.LastWriteTimeUtc.Ticks}) -join "`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
}
function Show-AlignmentAnalysis {
    param($Owner,$Settings,[int]$SeedMs=0,[double]$ReferenceSeconds=0)
    $job=Join-Path ([IO.Path]::GetTempPath()) ('ma-align-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($job)
    $request=@{Root=$PSScriptRoot;Folder=(Split-Path $Settings.OffsetPath -Parent);VideoList=$Settings.VideoList;AudioList=$Settings.RawAudioList;Executable=(Find-PlaybackExecutable 'ffmpeg.exe');ParentId=$PID}
    $requestPath=Join-Path $job 'request.json'
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    $worker=$null;$form=New-Object Windows.Forms.Form;$timer=New-Object Windows.Forms.Timer
    try{
        $form.Text=Get-QualityText 'Automatic alignment — experiment' 'Alinhamento automático — experiência'
        $form.ClientSize=New-Object Drawing.Size(540,150);$form.StartPosition='CenterParent';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false
        $label=New-Object Windows.Forms.Label;$label.SetBounds(12,12,516,44);$label.Text=Get-QualityText 'Preparing analysis...' 'A preparar a análise…'
        $bar=New-Object Windows.Forms.ProgressBar;$bar.SetBounds(12,60,516,22)
        $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel;$cancel.Text=Get-QualityText 'Cancel' 'Cancelar';$cancel.SetBounds(408,104,120,30)
        $form.Controls.AddRange(@($label,$bar,$cancel))
        $form.Tag=@{Job=$job;Finished=$false;Success=$false;Message='';Label=$label;Bar=$bar;Cancel=$cancel;Worker=$null}
        $cancel.Add_Click({param($sender,$eventArgs) $d=$sender.FindForm();[IO.File]::WriteAllText((Join-Path $d.Tag.Job 'cancel'),'');$sender.Enabled=$false;$d.Tag.Label.Text=Get-QualityText 'Cancelling...' 'A cancelar…'})
        $form.Add_FormClosing({param($sender,$eventArgs) if(-not $sender.Tag.Finished){[IO.File]::WriteAllText((Join-Path $sender.Tag.Job 'cancel'),'');$eventArgs.Cancel=$true}})
        $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $worker=Start-PlaybackProcess $exe @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Audio_Alignment_Worker.ps1'),'-RequestPath',$requestPath)
        $form.Tag.Worker=$worker;$timer.Tag=$form;$timer.Interval=200
        $timer.Add_Tick({
            param($sender,$eventArgs)
            $d=$sender.Tag;$statusPath=Join-Path $d.Tag.Job 'status.json';$status=$null
            if([IO.File]::Exists($statusPath)){
                $file=$null;$reader=$null
                try{
                    # Reading progress must not deny the worker write access.
                    $file=New-Object IO.FileStream($statusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    $reader=New-Object IO.StreamReader($file,[Text.Encoding]::UTF8)
                    $status=ConvertFrom-Json ($reader.ReadToEnd());$d.Tag.Label.Text=$status.Text;$d.Tag.Bar.Value=[int]$status.Percent
                }catch{}finally{if($reader){$reader.Dispose()}elseif($file){$file.Dispose()}}
            }
            if($d.Tag.Worker.HasExited){
                $d.Tag.Finished=$true;$d.Tag.Success=($null -ne $status -and $status.Done -and $status.Success -and $d.Tag.Worker.ExitCode -eq 0)
                $d.Tag.Message=$d.Tag.Label.Text;$sender.Stop();$d.Close()
            }
        })
        $timer.Start();[void]$form.ShowDialog($Owner)
        if(-not $form.Tag.Success){[void][Windows.Forms.MessageBox]::Show($Owner,$form.Tag.Message,$form.Text);return $false}
        $m=Read-AlignmentManifest $request.Folder
        if($null -eq $m){throw 'O resultado da análise não pôde ser validado. / Analysis result could not be validated.'}
        Show-AlignmentReport $Owner $m
        return $true
    }finally{
        $timer.Stop();$timer.Dispose()
        if($worker){if(-not $worker.HasExited){[IO.File]::WriteAllText((Join-Path $job 'cancel'),'');if(-not $worker.WaitForExit(3000)){$worker.Kill()}};$worker.Dispose()}
        $form.Dispose()
        foreach($p in @(Get-ChildItem -LiteralPath $job -File)){[IO.File]::Delete($p.FullName)}
        [IO.Directory]::Delete($job)
    }
}
function Show-AlignmentReport {
    param($Owner,$Manifest)
    $d=New-Object Windows.Forms.Form
    try{
        $d.Text=Get-QualityText 'Alignment results' 'Resultados do alinhamento';$d.ClientSize=New-Object Drawing.Size(700,480);$d.StartPosition='CenterParent'
        $note=New-Object Windows.Forms.Label;$note.SetBounds(12,12,676,64)
        $note.Text=Get-QualityText 'Only external audio is shifted. Verify that the manual offset is correct in the reference excerpt found. Review blocks keep that value. One matched excerpt does not prove a constant delay throughout the block. Close, then Apply to use the table.' 'Só o áudio externo é ajustado. Confirme que o valor manual está correto no trecho de referência encontrado. Blocos para revisão usam esse valor. Uma correspondência num trecho não prova atraso constante no bloco. Feche e prima Aplicar para usar a tabela.'
        if($Manifest.ReferenceMode -eq 'Automatic'){$note.Text=Get-QualityText 'Reference and offsets were found automatically. Review blocks have no confirmed result and use 0 ms. Only external audio is shifted. A matched excerpt does not prove a constant delay throughout the block. Review the results, close, then Apply.' 'A referência e os ajustes foram encontrados automaticamente. Blocos para revisão não têm resultado confirmado e usam 0 ms. Só o áudio externo é ajustado. Um trecho confirmado não prova atraso constante no bloco inteiro. Reveja, feche e prima Aplicar.'}
        $text=New-Object Windows.Forms.TextBox;$text.Multiline=$true;$text.ReadOnly=$true;$text.ScrollBars='Both';$text.WordWrap=$false;$text.SetBounds(12,84,676,346);$text.Anchor='Top,Bottom,Left,Right';$text.TabStop=$false
        $lines=@((Get-QualityText 'Block | Start (s) | Offset (ms) | Result' 'Bloco | Início (s) | Desfasamento (ms) | Resultado'))
        if($null -ne $Manifest.ReferenceSeconds){$lines=@((Get-QualityText 'Reference position: ' 'Posição de referência: ')+(Format-AnnotationTime ([double]$Manifest.ReferenceSeconds)),'')+$lines}
        if($null -ne $Manifest.ReferenceCalibration.FoundAt){$lines=@((Get-QualityText 'Confirmed reference excerpt: ' 'Trecho de referência confirmado: ')+(Format-AnnotationTime ([double]$Manifest.ReferenceCalibration.FoundAt))+' – '+(Format-AnnotationTime ([double]$Manifest.ReferenceCalibration.FoundAt+[double]$Manifest.ReferenceCalibration.FoundDuration)),'')+$lines}
        foreach($b in $Manifest.Blocks){
            $status=switch($b.Status){'Automatic'{Get-QualityText 'Automatic' 'Automático'} 'ManualReference'{Get-QualityText 'Manual reference' 'Referência manual'} 'ReviewVariable'{Get-QualityText 'Review: varies inside block' 'Rever: varia dentro do bloco'} 'ReviewShort'{Get-QualityText 'Review: short block' 'Rever: bloco curto'} default{Get-QualityText 'Review: ambiguous sound' 'Rever: som ambíguo'}}
            if($b.Status -eq 'AutomaticReference'){$status=Get-QualityText 'Automatic reference' 'Referência automática'}
            if($Manifest.ReferenceMode -eq 'Automatic' -and $b.Status -like 'Review*'){$status+=Get-QualityText ' — no adjustment (0 ms)' ' — sem ajuste (0 ms)'}
            if($b.Status -eq 'ManualReference' -and ($b.BlockAnalysisStatus -like 'Review*' -or ($null -ne $b.Scan -and -not $b.Scan.Complete))){$status+=Get-QualityText ' — rest of block needs review' ' — restante bloco por confirmar'}
            if($b.Status -in @('Automatic','AutomaticReference') -and $null -ne $b.Scan -and -not $b.Scan.Complete){$status+=Get-QualityText ' — confirmed excerpt' ' — trecho confirmado'}
            $lines+=('{0} | {1:0.000} | {2} | {3}' -f $b.Block,$b.Start,$b.OffsetMs,$status)
            if($null -ne $b.Scan.FoundAt){$lines+='    '+(Get-QualityText 'Matched excerpt: ' 'Trecho encontrado: ')+(Format-AnnotationTime ([double]$b.Scan.FoundAt))+' – '+(Format-AnnotationTime ([double]$b.Scan.FoundAt+[double]$b.Scan.FoundDuration))}
        }
        $text.Text=$lines -join [Environment]::NewLine
        $close=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $close;$close.Text=Get-QualityText 'Close' 'Fechar';$close.SetBounds(588,440,100,28);$close.Anchor='Bottom,Right';$close.DialogResult='OK'
        $d.Controls.AddRange(@($note,$text,$close));$d.AcceptButton=$close;$d.ActiveControl=$close;[void]$d.ShowDialog($Owner)
    }finally{$d.Dispose()}
}
function Read-AlignmentManifest {
    param([string]$Folder)
    $path=Join-Path $Folder 'audio_alignment.json'
    if(-not [IO.File]::Exists($path)){return $null}
    try {
        $m=ConvertFrom-Json ([IO.File]::ReadAllText($path))
        if($m.Version -notin @(1,2) -or $m.Signature -ne (Get-AlignmentSignature $Folder) -or -not @($m.Blocks).Count){return $null}
        $end=0.0
        foreach($b in $m.Blocks){
            $start=[double]$b.Start;$duration=[double]$b.Duration;$offset=[double]$b.OffsetMs
            if([double]::IsNaN($start) -or [double]::IsInfinity($start) -or [double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or [double]::IsNaN($offset) -or [double]::IsInfinity($offset)){return $null}
            if([Math]::Abs($start-$end) -gt 0.001 -or $duration -le 0 -or [Math]::Abs($offset) -gt 20000 -or $offset -ne [int]$offset){return $null}
            $end+=[double]$b.Duration
        }
        return $m
    }catch{return $null}
}
function Set-AlignmentPlaybackList {
    param([string]$Folder,[string]$RawList,[string]$EffectiveList,[bool]$Enabled)
    $m=$null;if($Enabled){$m=Read-AlignmentManifest $Folder;if($null -eq $m){throw (Get-QualityText 'Alignment is missing or outdated. Analyse again.' 'O alinhamento não existe ou está desatualizado. Analise novamente.')}}
    [IO.File]::Copy($RawList,$EffectiveList,$true)
    $sidecar=$EffectiveList+'.alignment.json'
    if($null -eq $m){if([IO.File]::Exists($sidecar)){[IO.File]::Delete($sidecar)};return}
    $files=@(Get-RecordingFiles $Folder 'audio' 'wav');$times=@(Get-AlignmentBlocks $RawList)
    if($files.Count -ne $times.Count){throw 'Lista de blocos de áudio inconsistente. / Audio block list is inconsistent.'}
    $entries=@();for($i=0;$i -lt $files.Count;$i++){$entries+=[pscustomobject]@{Path=$files[$i].FullName;Duration=$times[$i].Duration}}
    Initialize-AlignmentStreamType
    foreach($file in $files){$null=[MachiningMonitor.AlignmentWave235]::Read($file.FullName)}
    $plan=@{Folder=$Folder;Signature=$m.Signature;Files=$entries;Blocks=@($m.Blocks | Select-Object Start,Duration,OffsetMs)}
    [IO.File]::WriteAllText($sidecar,($plan | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
}
function Initialize-AlignmentStreamType {
    if(-not ('MachiningMonitor.AlignmentAudioStream235' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Audio_Alignment_Stream.cs')}
}
function Get-AlignmentInputArguments {
    param([string]$List)
    $path=$List+'.alignment.json'
    if(-not [IO.File]::Exists($path)){return @('-f','concat','-safe','0','-i',$List)}
    Initialize-AlignmentStreamType
    $plan=ConvertFrom-Json ([IO.File]::ReadAllText($path))
    $wave=[MachiningMonitor.AlignmentWave235]::Read([string]$plan.Files[0].Path)
    return @('-f',$wave.Format,'-ar',[string]$wave.Rate,'-ac',[string]$wave.Channels,'-i',('ma-alignment:'+$path+'|0'))
}
function New-AlignmentProcessInputs {
    param([string[]]$Items)
    $result=@($Items);$streams=@()
    try{
        for($i=1;$i -lt $result.Count;$i++){
            if($result[$i-1] -ne '-i' -or -not $result[$i].StartsWith('ma-alignment:')){continue}
            Initialize-AlignmentStreamType
            $parts=$result[$i].Substring(13).Split('|')
            if($parts.Count -ne 2){throw 'Invalid alignment stream reference'}
            $plan=ConvertFrom-Json ([IO.File]::ReadAllText($parts[0]))
            if($plan.Signature -ne (Get-AlignmentSignature $plan.Folder)){throw 'O alinhamento está desatualizado. / Alignment is outdated.'}
            $start=[double]::Parse($parts[1],[Globalization.CultureInfo]::InvariantCulture)
            $stream=[MachiningMonitor.AlignmentAudioStream235]::Create([string[]]@($plan.Files | ForEach-Object {$_.Path}),[double[]]@($plan.Files | ForEach-Object {$_.Duration}),[double[]]@($plan.Blocks | ForEach-Object {$_.Start}),[double[]]@($plan.Blocks | ForEach-Object {$_.Duration}),[int[]]@($plan.Blocks | ForEach-Object {$_.OffsetMs}),$start)
            $streams+=,$stream;$result[$i]=$stream.PipePath
        }
        return @{Items=$result;Streams=$streams}
    }catch{foreach($stream in $streams){$stream.Dispose()};throw}
}
function Close-AlignmentProcessInputs {
    param($Process)
    foreach($stream in @($Process.AlignmentStreams)){if($null -ne $stream){$stream.Dispose()}}
}
function Get-AlignmentBlocks {
    param([string]$List)
    $start=0.0;$index=0
    foreach($line in [IO.File]::ReadAllLines($List)){
        if($line -match '^duration\s+([0-9.]+)'){
            $duration=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
            [pscustomobject]@{Index=$index;Start=$start;Duration=$duration}
            $start+=$duration;$index++
        }
    }
}
function Test-AlignmentCancellation {
    if($script:AlignmentCancelPath -and [IO.File]::Exists($script:AlignmentCancelPath)){throw 'Análise cancelada. / Analysis cancelled.'}
    if($script:AlignmentParent -and $script:AlignmentParent.HasExited){throw 'A janela de origem foi fechada. / Parent window closed.'}
}
function Invoke-AlignmentEncoder {
    param([string]$Executable,[string[]]$Items)
    Test-AlignmentCancellation
    $p=Start-PlaybackProcess $Executable $Items -QualityClock
    try{
        $errorTask=$p.StandardError.ReadToEndAsync();$clock=[Diagnostics.Stopwatch]::StartNew()
        while(-not $p.WaitForExit(100)){
            Test-AlignmentCancellation
            if($clock.Elapsed.TotalMinutes -gt 15){throw 'O processamento de um bloco excedeu 15 minutos. / Block processing timed out.'}
        }
        $message=$errorTask.GetAwaiter().GetResult()
        if($p.ExitCode -ne 0){throw ('FFmpeg: '+$message)}
    }finally{if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};Close-AlignmentProcessInputs $p;$p.Dispose()}
}
function Get-AlignmentInputPlan {
    param([string]$List,[double]$Start)
    if([IO.File]::Exists($List+'.alignment.json')){
        $items=@(Get-AlignmentInputArguments $List)
        $items[-1]=$items[-1].Split('|')[0]+'|'+$Start.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
        return @{Items=$items;Trim=0.0;Temp=$null}
    }
    # Decode from the containing block's beginning and cut decoded samples.
    # This skips earlier blocks without depending on packet seek boundaries.
    $local=Get-LocalSeekInput $List $Start
    return @{Items=@('-f','concat','-safe','0','-i',$local.Path);Trim=$local.Seconds;Temp=$(if($local.Path -ne $List){$local.Path}else{$null})}
}
function Export-AlignmentAudio {
    param([string]$Executable,[string]$List,[double]$Start,[double]$Duration,[string]$Output,[int]$DelayMs=0,[switch]$Analysis,[switch]$ExternalReference,[ValidateSet('L','R')][string]$ReferenceChannel='L')
    $readStart=$Start-$DelayMs/1000.0
    $pad=[Math]::Max(0.0,-$readStart);$readStart=[Math]::Max(0.0,$readStart)
    $plan=Get-AlignmentInputPlan $List $readStart
    try{
        $trim=([double]$plan.Trim).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
        $length=$Duration.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
        $padMs=([int][Math]::Round($pad*1000)).ToString([Globalization.CultureInfo]::InvariantCulture)
        # Fill actual timestamp gaps before trimming; do not stretch audio samples.
        $rate='';if($Analysis){$rate='8000:'}
        $filter="aresample=${rate}async=1:min_hard_comp=0.01:first_pts=0,atrim=start=$trim,asetpts=PTS-STARTPTS,adelay=${padMs}:all=1,apad,atrim=duration=$length"
        # Compare candidate channels separately; reading for playback/extraction
        # continues to preserve every original channel.
        if($Analysis -and $ExternalReference){$channel=0;if($ReferenceChannel -eq 'R'){$channel=1};$filter="pan=mono|c0=c${channel},"+$filter}
        $codec=@('-c:a','flac','-sample_fmt','s32')
        if($Analysis){$codec=@('-ac','1','-ar','8000','-c:a','pcm_f32le','-f','f32le')}
        Invoke-AlignmentEncoder $Executable (@('-nostdin','-v','error','-n')+$plan.Items+@('-map','0:a:0','-vn','-af',$filter,'-t',$length)+$codec+@($Output))
    }finally{if($plan.Temp -and [IO.File]::Exists($plan.Temp)){[IO.File]::Delete($plan.Temp)}}
}
function Publish-AlignmentStatus {
    param([string]$Text,[double]$Percent,[bool]$Done=$false,[bool]$Success=$false)
    if(-not $script:AlignmentStatusPath){return}
    $data=@{Text=$Text;Percent=[int][Math]::Min(100,[Math]::Max(0.0,$Percent));Done=$Done;Success=$Success}
    $json=$data | ConvertTo-Json
    $tmp=$script:AlignmentStatusPath+'.tmp'
    [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
    $attempts=3;if($Done){$attempts=30}
    for($attempt=0;$attempt -lt $attempts;$attempt++){
        try{[IO.File]::Copy($tmp,$script:AlignmentStatusPath,$true);return}
        catch [IO.IOException]{
            if($attempt+1 -ge $attempts){if($Done){throw};return}
            [Threading.Thread]::Sleep(10)
        }
    }
}
function Measure-AlignmentWindow {
    param([string]$Executable,[string]$VideoList,[string]$AudioList,[double]$At,[double]$Duration,[int]$SeedMs,[string]$Directory,[string[]]$Channels)
    $camera=Join-Path $Directory 'camera.f32';$external=Join-Path $Directory 'external.f32'
    if([IO.File]::Exists($camera)){[IO.File]::Delete($camera)}
    Export-AlignmentAudio $Executable $VideoList $At $Duration $camera -Analysis
    $cam=[MachiningMonitor.AudioAlignment234]::Features($camera);$candidates=@()
    foreach($channel in $Channels){
        Test-AlignmentCancellation
        if([IO.File]::Exists($external)){[IO.File]::Delete($external)}
        Export-AlignmentAudio $Executable $AudioList $At $Duration $external -Analysis -ExternalReference -ReferenceChannel $channel
        $m=[MachiningMonitor.AudioAlignment234]::Match($cam,[MachiningMonitor.AudioAlignment234]::Features($external),$SeedMs,10000)
        $candidates+=[pscustomobject]@{Channel=$channel;OffsetMs=$m.OffsetMs;Score=[Math]::Round($m.Score,4);Margin=[Math]::Round($m.Margin,4);Reliable=$m.Reliable}
    }
    $good=@($candidates | Where-Object {$_.Reliable} | Sort-Object @{Expression={$_.Score+$_.Margin};Descending=$true})
    $best=@($candidates | Sort-Object @{Expression={$_.Score+$_.Margin};Descending=$true})[0]
    if($good.Count){$best=$good[0]}
    $conflict=($good.Count -gt 1 -and [Math]::Abs($good[0].OffsetMs-$good[1].OffsetMs) -gt 120)
    return [pscustomobject]@{At=$At;Duration=$Duration;Channel=$best.Channel;OffsetMs=$best.OffsetMs;Score=$best.Score;Margin=$best.Margin;Reliable=($best.Reliable -and -not $conflict);ChannelConflict=$conflict;Candidates=$candidates}
}
function Get-AlignmentScanWindows {
    param($Block)
    $duration=[Math]::Min(90.0,[double]$Block.Duration)
    $last=[double]$Block.Start+[double]$Block.Duration-$duration
    $at=[double]$Block.Start;$step=$duration/2.0
    if($duration -le 0){return}
    while($true){
        [pscustomobject]@{At=$at;Duration=$duration;Kind='Scan'}
        if($at -ge $last-0.0000001){break}
        $at=[Math]::Min($at+$step,$last)
    }
}
function Search-AlignmentBlock {
    param([string]$Executable,[string]$VideoList,[string]$AudioList,$Block,[int]$SeedMs,[string]$Directory,[string[]]$Channels,[Nullable[double]]$PreferredPosition=$null,[double]$ProgressStart=0,[double]$ProgressSpan=0)
    $queue=New-Object 'System.Collections.Generic.List[object]'
    if($null -ne $PreferredPosition){
        foreach($size in @(90.0,180.0)){
            $duration=[Math]::Min($size,[double]$Block.Duration)
            $at=[Math]::Max([double]$Block.Start,[Math]::Min(([double]$PreferredPosition)-$duration/2,$Block.Start+$Block.Duration-$duration))
            $queue.Add([pscustomobject]@{At=$at;Duration=$duration;Kind='Preferred'})
        }
    }
    foreach($w in @(Get-AlignmentScanWindows $Block)){$queue.Add($w)}
    $planned=$queue.Count+2;$tested=@{};$samples=New-Object 'System.Collections.Generic.List[object]';$good=New-Object 'System.Collections.Generic.List[object]'
    $measured=$null;$reason='WeakCommonAudio';$status='ReviewAmbiguous';$found=$null
    for($index=0;$index -lt $queue.Count;$index++){
        Test-AlignmentCancellation;$w=$queue[$index]
        $key=$w.At.ToString('R',[Globalization.CultureInfo]::InvariantCulture)+'/'+$w.Duration.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        if($tested.ContainsKey($key)){continue};$tested[$key]=$true
        $label=('A procurar no bloco / Searching block ')+($Block.Index+1)+' — '+(Format-AnnotationTime $w.At)+' – '+(Format-AnnotationTime ($w.At+$w.Duration))
        Publish-AlignmentStatus $label ($ProgressStart+$ProgressSpan*[Math]::Min(0.99,$index/[double]$planned))
        $sample=Measure-AlignmentWindow $Executable $VideoList $AudioList $w.At $w.Duration $SeedMs $Directory $Channels
        $sample | Add-Member NoteProperty Kind $w.Kind -Force
        $samples.Add($sample)
        if(-not $sample.Reliable){continue}
        $good.Add($sample)
        $ordered=@($good | Sort-Object OffsetMs)
        if($ordered.Count -ge 2){
            if(($ordered[-1].OffsetMs-$ordered[0].OffsetMs) -gt 120){$reason='VariableOrConflictingDelay';$status='ReviewVariable';break}
            $measured=[double]$ordered[[int][Math]::Floor($ordered.Count/2)].OffsetMs
            $reason='Confirmed';$status='Automatic';$found=$sample;break
        }
        # Confirm a candidate immediately with a longer window, before moving on.
        # For a short block already covered in full, use a distinct shorter window.
        $confirm=[Math]::Min(180.0,[double]$Block.Duration)
        if([Math]::Abs($confirm-$w.Duration) -lt 0.001){$confirm=[Math]::Max(20.0,$w.Duration*0.65);$confirm=[Math]::Min($confirm,[double]$Block.Duration)}
        $center=$w.At+$w.Duration/2
        $at=[Math]::Max([double]$Block.Start,[Math]::Min($center-$confirm/2,$Block.Start+$Block.Duration-$confirm))
        $confirmKey=$at.ToString('R',[Globalization.CultureInfo]::InvariantCulture)+'/'+$confirm.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        if(-not $tested.ContainsKey($confirmKey)){$queue.Insert($index+1,[pscustomobject]@{At=$at;Duration=$confirm;Kind='Confirmation'})}
    }
    if($null -eq $measured -and $reason -ne 'VariableOrConflictingDelay'){
        if($good.Count -eq 1){$reason='SingleMatchNotConfirmed'}
        elseif(@($samples | Where-Object {$_.ChannelConflict}).Count){$reason='ChannelConflict'}
        elseif(@($samples | Where-Object {$_.Score -ge 0.28}).Count){$reason='RepetitiveOrAmbiguousAudio'}
        if($Block.Duration -lt 20){$status='ReviewShort'}
    }
    # Report actual temporal coverage, not just the furthest sampled position.
    $covered=[double]$Block.Start
    foreach($s in @($samples | Sort-Object At)){
        if($s.At -gt $covered+0.001){break}
        $covered=[Math]::Max($covered,([double]$s.At+[double]$s.Duration))
    }
    return [pscustomobject]@{Status=$status;MeasuredMs=$measured;Reason=$reason;Samples=$samples.ToArray();ScannedFully=($covered -ge $Block.Start+$Block.Duration-0.001);CoverageEnd=$covered;FoundAt=$(if($found){$found.At}else{$null});FoundDuration=$(if($found){$found.Duration}else{$null})}
}
function Measure-AlignmentReference {
    param([string]$Executable,[string]$VideoList,[string]$AudioList,[double]$Position,$Block,[int]$SeedMs,[string]$Directory,[string[]]$Channels)
    $scan=Search-AlignmentBlock $Executable $VideoList $AudioList $Block $SeedMs $Directory $Channels -PreferredPosition $Position -ProgressStart 0 -ProgressSpan 10
    return [pscustomobject]@{Position=$Position;Status=$scan.Status;MeasuredMs=$scan.MeasuredMs;Reason=$scan.Reason;Samples=$scan.Samples;ScannedFully=$scan.ScannedFully;CoverageEnd=$scan.CoverageEnd;FoundAt=$scan.FoundAt;FoundDuration=$scan.FoundDuration}
}
function Invoke-RecordingAlignment {
    param([string]$Folder,[string]$VideoList,[string]$AudioList,[int]$SeedMs=0,[double]$ReferenceSeconds=0,[string]$Executable)
    if(-not ('MachiningMonitor.AudioAlignment234' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Audio_Alignment.cs')}

    $signature=Get-AlignmentSignature $Folder
    $blocks=@(Get-AlignmentBlocks $VideoList)
    if(-not $blocks.Count){throw 'Não existem blocos de vídeo com durações. / Video block durations missing.'}
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('ma-analysis-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($directory)
    $results=@();$published=$false
    try{
        Initialize-AlignmentStreamType
        $firstAudio=@(Get-RecordingFiles $Folder 'audio' 'wav')[0]
        $channels=@('L');if(([MachiningMonitor.AlignmentWave235]::Read($firstAudio.FullName)).Channels -gt 1){$channels+=,'R'}
        # Manual parameters are retained only for compatibility with old callers.
        # Every block is measured independently against camera audio, with zero bias.
        $scans=@()
        for($i=0;$i -lt $blocks.Count;$i++){
            Test-AlignmentCancellation;$b=$blocks[$i]
            $scan=Search-AlignmentBlock $Executable $VideoList $AudioList $b 0 $directory $channels -ProgressStart (100*$i/$blocks.Count) -ProgressSpan (100.0/$blocks.Count)
            $scans+=,$scan
            $offset=0;if($null -ne $scan.MeasuredMs){$offset=[int][Math]::Round($scan.MeasuredMs)}
            $results+=[pscustomobject]@{Block=($i+1);Start=$b.Start;Duration=$b.Duration;OffsetMs=$offset;MeasuredMs=$scan.MeasuredMs;Status=$scan.Status;Samples=$scan.Samples;Scan=[pscustomobject]@{Complete=$scan.ScannedFully;CoverageEnd=$scan.CoverageEnd;FoundAt=$scan.FoundAt;FoundDuration=$scan.FoundDuration;Reason=$scan.Reason}}
        }
        $confirmed=@($results | Where-Object {$null -ne $_.MeasuredMs})
        if(-not $confirmed.Count){
            $reviewPath=Join-Path $Folder 'audio_alignment_review.json'
            $diagnostic=[ordered]@{Version=238;ReferenceMode='Automatic';SearchMinMs=-10000;SearchMaxMs=10000;Reason='NoConfirmedReference';Blocks=$results}
            $diagnostic | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reviewPath -Encoding UTF8
            throw ('Não foi encontrada uma referência automática confirmada em nenhum bloco. A tabela anterior foi mantida. / No confirmed automatic reference was found in any block. Previous table retained.'+[Environment]::NewLine+'Diagnóstico / Diagnostic: '+$reviewPath)
        }
        $reference=$confirmed[0];$reference.Status='AutomaticReference'
        $referenceIndex=$reference.Block-1;$refScan=$scans[$referenceIndex]
        $calibration=[pscustomobject]@{Position=($refScan.FoundAt+$refScan.FoundDuration/2);Status='AutomaticReference';MeasuredMs=$reference.MeasuredMs;Reason='Confirmed';Samples=$refScan.Samples;ScannedFully=$refScan.ScannedFully;FoundAt=$refScan.FoundAt;FoundDuration=$refScan.FoundDuration}
        Test-AlignmentCancellation
        if($signature -ne (Get-AlignmentSignature $Folder)){throw 'A gravação mudou durante a análise. / Recording changed during analysis.'}
        $manifest=[ordered]@{Version=2;AlgorithmVersion=238;CreatedUtc=[DateTime]::UtcNow.ToString('o');Signature=$signature;ReferenceMode='Automatic';ReferenceBlock=$reference.Block;ReferenceSeconds=$calibration.Position;ReferenceOffsetMs=$reference.OffsetMs;ReferenceCalibration=$calibration;SearchMinMs=-10000;SearchMaxMs=10000;BiasMs=0;HasUnresolvedBlocks=(@($results | Where-Object {$null -eq $_.MeasuredMs}).Count -gt 0);Timeline='Playback concat durations; camera timestamps retained';Blocks=$results}
        $json=$manifest | ConvertTo-Json -Depth 10
        $temp=Join-Path $directory 'manifest.json';[IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
        $target=Join-Path $Folder 'audio_alignment.json'
        # Commit only the complete offset table; retain the prior table on failure.
        if([IO.File]::Exists($target)){
            # Portable folders may not grant the metadata rights File.Replace
            # needs. Keep a backup and restore it if publishing fails.
            [IO.File]::Copy($target,$target+'.bak',$true)
            try{[IO.File]::Copy($temp,$target,$true)}catch{[IO.File]::Copy($target+'.bak',$target,$true);throw}
            [IO.File]::Delete($temp)
        }else{[IO.File]::Move($temp,$target)}
        $published=$true
        return $manifest
    }finally{
        foreach($name in @('camera.f32','external.f32')){$p=Join-Path $directory $name;if([IO.File]::Exists($p)){[IO.File]::Delete($p)}}
        foreach($p in @(Get-ChildItem -LiteralPath $directory -File)){[IO.File]::Delete($p.FullName)}
        [IO.Directory]::Delete($directory)
    }
}
