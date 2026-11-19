function Start-SplitPreview {
    param($State,[switch]$Restart)
    if(-not (Test-SplitExtractionReady $State)){return}
    if(-not $State.Split.Preview -and -not $State.Paused){return}
    if($State.Split.Preview -and -not $Restart){Switch-QualityPause $State -ExtractionPreview;return}
    if($null -eq $State.Split.MarkStart -or $null -eq $State.Split.MarkEnd -or $State.Split.MarkEnd -le $State.Split.MarkStart){return}
    # Snapshot both markers; preview never edits or exports the recording.
    $State.Split.Preview=@{Start=[double]$State.Split.MarkStart;End=[double]$State.Split.MarkEnd;Starting=$true}
    Request-QualitySeek $State $State.Split.Preview.Start -CenterTimeline
    $State.SeekPaused=$false
}
function Stop-SplitPreview {
    param($State)
    $State.Split.Preview=$null
    if($null -ne $State.PendingSeek){$State.SeekPaused=$true}
    elseif(-not $State.Paused -and $State.Clock.Ready -and -not $State.Ended){Switch-QualityPause $State -ExtractionPreview}
}
function Update-SplitPreview {
    param($State)
    $preview=$State.Split.Preview;if(-not $preview){return}
    if($null -ne $State.PendingSeek -or $State.Seeking -or -not $State.Clock.Ready){return}
    $position=Get-QualityPosition $State
    if($preview.Starting){
        $preview.Starting=$false
        if($State.Paused -and -not $State.Ended){Switch-QualityPause $State -ExtractionPreview}
    }
    if($State.Ended -or $position -ge $preview.End){Stop-SplitPreview $State}
}
function Start-SplitPartPreview {
    param($State,$Part)
    if(-not (Test-SplitExtractionReady $State)){return}
    $start=[double]$Part.Start;$end=[double]$Part.End
    if([double]::IsNaN($start) -or [double]::IsInfinity($start) -or [double]::IsNaN($end) -or [double]::IsInfinity($end) -or $start -lt 0 -or $end -le $start -or $end -gt $State.Duration){throw (Get-QualityText 'Invalid extraction interval.' 'Intervalo da extração inválido.')}
    $State.Split.Preview=$null
    if(-not $State.Paused){Switch-QualityPause $State -ExtractionPreview}
    $State.Split.MarkStart=$start;$State.Split.MarkEnd=$end
    Update-SplitMarkerButtons $State
    Start-SplitPreview $State -Restart
}
