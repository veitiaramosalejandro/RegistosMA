# Resolve from the script location, never from the current directory or Windows PATH.
$script:AudioPortableRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:AudioBinRoot=Join-Path $script:AudioPortableRoot 'bin'
function Get-AudioExecutable([string]$Name){
    if($Name -notin @('ffmpeg.exe','ffprobe.exe','ffplay.exe','mediamtx.exe')){throw 'Executavel AudioRTSP invalido.'}
    return (Join-Path $script:AudioBinRoot $Name)
}
