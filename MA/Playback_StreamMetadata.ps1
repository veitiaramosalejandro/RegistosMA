# RTP metadata track protocol for the MA RTSP publisher.
# Payload framing: ASCII MAM1, big-endian UInt32 JSON length, UTF-8 JSON.
function New-PlaybackStreamMetadata($State){
    $folder=Split-Path $State.Path -Parent;$metadata=$null;$metadataPath=Join-Path $folder 'metadata.json'
    if(Test-Path -LiteralPath $metadataPath){$metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json}
    return @{State=$State;RecordingId=(Split-Path $folder -Leaf);Metadata=$metadata;Contexts=@($State.ContextEntries);Events=@($State.Items | Sort-Object timestamp_seconds,created_at_utc,id);EventIndex=0;Sequence=0;LastPosition=-1.0;LastSnapshot=-1.0;LastPaused=$null;Ended=$false}
}
function Write-PlaybackStreamMetadata($Runtime,$Message){
    if(-not $Runtime.Metadata -or -not $Runtime.Session.CustomRtspServer){return $false}
    $Message.sequence=[int64]$Runtime.Metadata.Sequence;$Runtime.Metadata.Sequence++
    $payload=[Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Depth 30 -Compress))
    $frame=New-Object byte[] (8+$payload.Length);[Text.Encoding]::ASCII.GetBytes('MAM1').CopyTo($frame,0)
    $length=[BitConverter]::GetBytes([UInt32]$payload.Length);if([BitConverter]::IsLittleEndian){[Array]::Reverse($length)}
    $length.CopyTo($frame,4);$payload.CopyTo($frame,8)
    try{$Runtime.Session.CustomRtspServer.SendMetadata($frame);return $true}catch{return $false}
}
function Send-PlaybackStreamSnapshot($Runtime,[double]$Seconds,[string]$Reason){
    $m=$Runtime.Metadata;$state=$m.State;$context=Get-RecordingContextAt $m.Contexts $Seconds
    $parameters=Get-AnnotationParameters $state $Seconds;$quality=Get-CurrentQuality $state $Seconds
    Write-PlaybackStreamMetadata $Runtime ([ordered]@{type='snapshot';reason=$Reason;recordingId=$m.RecordingId;timestampSeconds=$Seconds;metadata=$m.Metadata;context=$context;parameters=$parameters;quality=$quality})
}
function Start-PlaybackStreamMetadata($Runtime,$State){
    if(-not $Runtime.Session.CustomRtspServer){return};$Runtime.Metadata=New-PlaybackStreamMetadata $State;$m=$Runtime.Metadata
    Write-PlaybackStreamMetadata $Runtime ([ordered]@{type='stream_start';recordingId=$m.RecordingId;timeReference='playback_seconds';metadata=$m.Metadata;durationSeconds=[double]$State.Duration})
    Send-PlaybackStreamSnapshot $Runtime 0.0 'start';$m.LastPosition=0.0;$m.LastPaused=[bool]$State.Paused
}
function Update-PlaybackStreamMetadata($Runtime){
    $m=$Runtime.Metadata;if(-not $m -or -not $Runtime.PlaybackState){return};$state=$Runtime.PlaybackState;$position=[Math]::Max(0.0,[double](Get-QualityPosition $state))
    if($m.LastPaused -ne [bool]$state.Paused){Write-PlaybackStreamMetadata $Runtime ([ordered]@{type=if($state.Paused){'stream_pause'}else{'stream_resume'};recordingId=$m.RecordingId;timestampSeconds=$position});$m.LastPaused=[bool]$state.Paused}
    if($state.Paused){return}
    if($position -lt ($m.LastPosition-0.5)){$m.EventIndex=0;while($m.EventIndex -lt $m.Events.Count -and [double]$m.Events[$m.EventIndex].timestamp_seconds -lt $position){$m.EventIndex++};Write-PlaybackStreamMetadata $Runtime ([ordered]@{type='stream_seek';recordingId=$m.RecordingId;timestampSeconds=$position});Send-PlaybackStreamSnapshot $Runtime $position 'seek'}
    while($m.EventIndex -lt $m.Events.Count -and [double]$m.Events[$m.EventIndex].timestamp_seconds -le $position){$event=$m.Events[$m.EventIndex];Write-PlaybackStreamMetadata $Runtime ([ordered]@{type='event';recordingId=$m.RecordingId;timestampSeconds=[double]$event.timestamp_seconds;event=$event});$m.EventIndex++}
    if($m.LastSnapshot -lt 0 -or ($position-$m.LastSnapshot) -ge 1.0){Send-PlaybackStreamSnapshot $Runtime $position 'heartbeat';$m.LastSnapshot=$position}
    $m.LastPosition=$position;if($state.Ended -and -not $m.Ended){Write-PlaybackStreamMetadata $Runtime ([ordered]@{type='stream_end';recordingId=$m.RecordingId;timestampSeconds=[double]$state.Duration});$m.Ended=$true}
}
function Stop-PlaybackStreamMetadata($Runtime){
    if($Runtime.Metadata -and -not $Runtime.Metadata.Ended){$duration=if($Runtime.PlaybackState){[double]$Runtime.PlaybackState.Duration}else{0.0};Write-PlaybackStreamMetadata $Runtime ([ordered]@{type='stream_end';recordingId=$Runtime.Metadata.RecordingId;timestampSeconds=$duration});$Runtime.Metadata.Ended=$true};$Runtime.Metadata=$null
}
