# Discover each camera as an independent ordered track; keep legacy recordings valid.
function Get-PlaybackCameraTracks {
    param([string]$Folder,[string]$TempDirectory)
    $specs=@();$metadata=$null
    $path=Join-Path $Folder 'metadata.json'
    if(Test-Path -LiteralPath $path){try{$metadata=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop}catch{}}
    if($metadata.Cameras){$specs=@($metadata.Cameras)}
    if(-not $specs.Count){$specs=@([pscustomobject]@{Name='Camera 1';VideoFile='video_%06d.mp4';SegmentList='video_segments.csv'})}
    $tracks=@();$seen=@{}
    foreach($spec in $specs){
        $pattern=[string]$spec.VideoFile
        if($pattern -match '^(video|camera_\d+)_%\d*d\.mp4$'){$kind=$Matches[1]}
        elseif($pattern -eq 'video.mp4'){$kind='video'}
        else{continue}
        if($seen.ContainsKey($kind)){continue};$seen[$kind]=$true
        $files=@(Get-RecordingFiles $Folder $kind 'mp4')
        if(-not $files.Count){
            if(-not $metadata.Cameras){continue}
            throw ((Get-QualityText 'Camera files missing: ' 'Ficheiros da câmara em falta: ')+$spec.Name)
        }
        $csv=Join-Path $Folder ($kind+'_segments.csv')
        $list=Join-Path $TempDirectory ($kind+'.ffconcat')
        Write-PlaybackList $files $csv $list
        $tracks+=[pscustomobject]@{Name=[string]$spec.Name;Files=$files;Csv=$csv;List=$list}
    }
    return $tracks
}
function Add-PlaybackCameraInputs {
    param([string[]]$Items,[string[]]$CameraLists)
    $result=@($Items)
    foreach($list in $CameraLists){$result+=@('-f','concat','-safe','0','-i',$list)}
    return $result
}
# All views share one FFmpeg graph and one player clock: pause, seek and resize
# operate on every camera together. Only the selected audio source is heard.
function ConvertTo-PlaybackCameraGraph {
    param([string]$Graph,[string]$Source,[string[]]$CameraLists,[int]$Width=960,[int]$Height=540,[ValidateSet('Horizontal','Vertical')][string]$CameraLayout='Horizontal')
    if(-not $CameraLists.Count -or $Source -eq 'A' -or $Graph -notmatch '\[0:v:0\]'){return $Graph}
    $match=[regex]::Match($Graph,'\[0:v:0\]setpts=PTS-STARTPTS,scale=(\d+):(\d+)')
    if($match.Success){$Width=[int]$match.Groups[1].Value;$Height=[int]$match.Groups[2].Value}
    $count=$CameraLists.Count+1
    $cell=2*[int][Math]::Floor([Math]::Max(320,$Width)/$count/2)
    $heightEven=2*[int][Math]::Floor([Math]::Max(24,$Height)/2)
    $stack='hstack'
    if($CameraLayout -eq 'Vertical'){
        $cell=2*[int][Math]::Floor([Math]::Max(320,$Width)/2)
        $heightEven=[Math]::Max(24,2*[int][Math]::Floor($Height/$count/2))
        $stack='vstack'
    }
    $nextInput=2;if($Source -eq 'C'){$nextInput=1}
    $prefix='';$labels=''
    for($i=0;$i -lt $count;$i++){
        $input=0;if($i -gt 0){$input=$nextInput+$i-1}
        $prefix+="[${input}:v:0]setpts=PTS-STARTPTS,scale=${cell}:${heightEven}:force_original_aspect_ratio=decrease,pad=${cell}:${heightEven}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25[playcam${i}];"
        $labels+="[playcam${i}]"
    }
    return $prefix+$labels+"${stack}=inputs=${count}[playcameras];"+$Graph.Replace('[0:v:0]','[playcameras]')
}
