#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$script:JobDirectory=Split-Path $RequestPath -Parent
$script:StatusPath=Join-Path $script:JobDirectory 'status.json'
$script:CancelPath=Join-Path $script:JobDirectory 'cancel'
$script:PublishClock=[Diagnostics.Stopwatch]::StartNew()
$script:WorkerTag=@{Label=[pscustomobject]@{Text=''};FileLabel=[pscustomobject]@{Text=''};Percent=[pscustomobject]@{Text=''};Bar=[pscustomobject]@{Value=0};TotalWork=0.0;ProcessedWork=0.0;CompletedWork=0.0;FileDuration=0.0;FileName='';TimeCompleted=$false;CancelRequested=$false;Done=$false;Success=$false;ErrorText=''}
function Publish-ExtractionSnapshot {
    param([switch]$Force)
    if(-not $Force -and $script:PublishClock.ElapsedMilliseconds -lt 100){return}
    $t=$script:WorkerTag
    $data=[ordered]@{WorkerPid=$PID;Label=$t.Label.Text;FileLabel=$t.FileLabel.Text;Percent=$t.Bar.Value;TotalWork=$t.TotalWork;ProcessedWork=$t.ProcessedWork;Done=$t.Done;Success=$t.Success;ErrorText=$t.ErrorText}
    $temp=$script:StatusPath+'.tmp'
    $attempts=1;if($Force){$attempts=20}
    for($attempt=0;$attempt -lt $attempts;$attempt++){
        try{
            [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $data -Depth 8),(New-Object Text.UTF8Encoding($false)))
            [IO.File]::Copy($temp,$script:StatusPath,$true)
            $script:PublishClock.Restart();return
        }catch{if($attempt+1 -lt $attempts){[Threading.Thread]::Sleep(10)}}
    }
}
try{
    $request=ConvertFrom-Json ([IO.File]::ReadAllText($RequestPath))
    $script:ParentProcess=[Diagnostics.Process]::GetProcessById([int]$request.ParentId)
    $script:WorkerTag.Label.Text=if($request.Language -eq 'pt'){'A preparar a extração…'}else{'Preparing extraction...'};Publish-ExtractionSnapshot -Force
    . (Join-Path $request.Root 'Playback_Blocks.ps1') -RecordingPath $request.State.Split.Folder -ApenasFuncoes
    $script:UiLanguage=$request.Language
    function Find-PlaybackExecutable {param([string]$Name) return Find-MonitorExecutable $Name}
    $script:BaseProgress=(Get-Command Update-SplitExportProgress).ScriptBlock
    function Update-SplitExportProgress {
        param($Progress,[double]$Seconds=0,[switch]$Complete)
        $null=& $script:BaseProgress $Progress $Seconds -Complete:$Complete
        Publish-ExtractionSnapshot -Force:$Complete
    }
    function Process-SplitExportInput {
        param($Progress)
        Publish-ExtractionSnapshot
        if([IO.File]::Exists($script:CancelPath) -or $script:ParentProcess.HasExited){throw (Get-QualityText 'Extraction cancelled. Completed recordings were kept.' 'Extração cancelada. As gravações já concluídas foram mantidas.')}
    }
    $metadataPath=Join-Path $request.State.Split.Folder 'metadata.json'
    $metadata=$null;if([IO.File]::Exists($metadataPath)){$metadata=ConvertFrom-Json ([IO.File]::ReadAllText($metadataPath))}
    $request.State.Split | Add-Member NoteProperty Metadata $metadata -Force
    $proxy=[pscustomobject]@{Tag=$script:WorkerTag}
    Process-SplitExportInput $proxy
    Export-SplitParts $request.State @($request.Parts) $request.Destination $proxy -IncludeAnnotations ([bool]$request.IncludeAnnotations) -ReplaceFolders @($request.ReplaceFolders)
    $script:WorkerTag.Success=$true
}catch{$script:WorkerTag.ErrorText=$_.Exception.Message}
finally{$script:WorkerTag.Done=$true;Publish-ExtractionSnapshot -Force}
