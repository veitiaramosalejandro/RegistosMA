#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
$directory=Split-Path $RequestPath -Parent
try{
    $request=ConvertFrom-Json ([IO.File]::ReadAllText($RequestPath))
    . (Join-Path $request.Root 'Playback_Blocks.ps1') -RecordingPath $request.Folder -ApenasFuncoes
    $script:AlignmentStatusPath=Join-Path $directory 'status.json'
    $script:AlignmentCancelPath=Join-Path $directory 'cancel'
    $script:AlignmentParent=[Diagnostics.Process]::GetProcessById([int]$request.ParentId)
    Publish-AlignmentStatus 'A preparar a análise / Preparing analysis' 0
    $null=Invoke-RecordingAlignment -Folder $request.Folder -VideoList $request.VideoList -AudioList $request.AudioList -Executable $request.Executable
    Publish-AlignmentStatus 'Análise concluída / Analysis complete' 100 $true $true
}catch{
    $data=@{Text=$_.Exception.Message;Percent=0;Done=$true;Success=$false}
    [IO.File]::WriteAllText((Join-Path $directory 'status.json'),($data | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    exit 1
}
