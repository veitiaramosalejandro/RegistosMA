. (Join-Path $PSScriptRoot 'Recording_Synchronization.ps1')
. (Join-Path $PSScriptRoot 'Recording_Credentials.ps1')
# External audio selection shared by capture, idle view and settings (v281).
function Get-RecordingAudioSourceType {
    param($Config)
    $value=Get-ConfigText $Config 'AudioSourceType'
    if([string]::IsNullOrWhiteSpace($value)){return 'Local'}
    if($value -ieq 'Local'){return 'Local'}
    if($value -ieq 'RTSP'){return 'RTSP'}
    throw (Get-QualityText 'Invalid external audio source. Choose Local or RTSP in Settings.' 'Origem de áudio externo inválida. Escolha Local ou RTSP na Configuração.')
}
function Test-RecordingAudioConfigured {
    param($Config)
    if((Get-RecordingAudioSourceType $Config) -eq 'RTSP'){return -not [string]::IsNullOrWhiteSpace((Get-ConfigText $Config 'AudioRtspUrl'))}
    return -not [string]::IsNullOrWhiteSpace((Get-ConfigText $Config 'AudioDevice'))
}
function Assert-RecordingAudioUrl {
    param([string]$Url)
    $uri=$null
    if($Url -match '[\x00-\x20"\x7f]' -or -not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('rtsp','rtsps') -or -not $uri.Host){
        throw (Get-QualityText 'Invalid external audio URL. Use rtsp://PC_IP:8554/audio.' 'Endereço do áudio externo inválido. Use rtsp://IP_DO_PC:8554/audio.')
    }
}
function Get-RecordingRtspSource {
    param($Config)
    $url=Get-ConfigText $Config 'AudioRtspUrl'
    $endpoint=Get-RecordingEndpoint $url (Get-RecordingCredentialText $Config 'AudioRtspUsername') (Get-RecordingCredentialText $Config 'AudioRtspPasswordProtected')
    $url=Join-RecordingEndpoint $endpoint
    Assert-RecordingAudioUrl $url
    return [pscustomobject]@{Type='RTSP';Name=(Get-QualityText 'External RTSP audio' 'Áudio externo RTSP');InputName=$url}
}
function Get-RecordingExternalAudioArguments {
    param($Source,[int]$BufferMilliseconds=0,[switch]$SyncClock)
    $clock=@('-fflags','nobuffer','-thread_queue_size','1024');if($SyncClock){$clock=@('-use_wallclock_as_timestamps','1','-isync','0')+$clock}
    # Silence is only used inside the video-preview renderer; never as recorded external audio.
    if($Source.Type -eq 'None'){return @('-re','-f','lavfi','-i','anullsrc=r=48000:cl=stereo')}
    if($Source.Type -eq 'RTSP'){
        Assert-RecordingAudioUrl $Source.InputName
        return $clock+@('-rtsp_transport','tcp','-timeout','10000000','-analyzeduration','500000','-probesize','1048576','-i',$Source.InputName)
    }
    return $clock+@('-f','dshow','-audio_buffer_size',[string]$BufferMilliseconds,'-i',('audio='+$Source.InputName))
}
function Get-RecordingAudioSegmentArguments {
    param([int]$InputIndex,[double]$Seconds,[string]$Folder,[string]$Gain)
    $delay=Get-RecordingAudioDelayFilter
    $clock=Get-RecordingCaptureAudioClockFilter
    $duration=$Seconds.ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
    return @('-map',"${InputIndex}:a:0",'-c:a','pcm_s16le','-filter:a',"$clock,volume=$Gain$delay",'-f','segment','-segment_time',$duration,'-segment_time_delta','0','-reset_timestamps','1','-segment_list_type','csv','-segment_list',(Join-Path $Folder 'audio_segments.csv'),(Join-Path $Folder 'audio_%06d.wav'))
}
function Set-RecordingExternalAudioInput {
    param([object[]]$Items,$Source,[int]$BufferMilliseconds=0)
    $inputIndex=[Array]::IndexOf($Items,'-f')
    $filterIndex=[Array]::IndexOf($Items,'-filter_complex')
    if($inputIndex -lt 0 -or $filterIndex -le $inputIndex){throw 'Invalid live audio input layout.'}
    $prefix=@();if($inputIndex -gt 0){$prefix=@($Items[0..($inputIndex-1)])}
    return $prefix+@(Get-RecordingExternalAudioArguments $Source $BufferMilliseconds)+@($Items[$filterIndex..($Items.Count-1)])
}
# Per-source capture/listening gain. Missing values preserve existing recordings.
function Get-RecordingGainDb {
 param($Value)
 if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return 0.0}
 $number=0.0
 if($Value -is [bool] -or -not [double]::TryParse(([string]$Value).Replace(',','.'),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt -20 -or $number -gt 40){throw (Get-QualityText 'Audio source gain must be between -20 and 40 dB. 0 preserves the original level.' 'O ganho da fonte de áudio deve estar entre -20 e 40 dB. 0 mantém o nível original.')}
 return $number
}
function Get-RecordingSourceGainDb {
 param($Config)
 if((Get-RecordingAudioSourceType $Config) -eq 'Local'){return (Get-RecordingGainDb $Config.LocalAudioGainDb)}
 foreach($p in @($Config.AudioRtspProfiles)){
   if($p -and $p.AudioRtspUrl -eq $Config.AudioRtspUrl -and [string]$p.AudioRtspUsername -eq [string]$Config.AudioRtspUsername){return (Get-RecordingGainDb $p.GainDb)}
 }
 return (Get-RecordingGainDb $Config.AudioRtspGainDb)
}
function Get-RecordingAudioGainText {
 param($Config)
 $percent=100.0
 if($Config.PSObject.Properties['AudioVolumePercent']){
   $value=$Config.AudioVolumePercent
   if($value -is [bool] -or $null -eq $value -or -not [double]::TryParse([string]$value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$percent) -or [double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or $percent -lt 0 -or $percent -gt 1000){throw (Get-QualityText 'Invalid recording audio volume.' 'Volume de áudio de gravação inválido.')}
 }
 return (($percent/100)*[Math]::Pow(10,((Get-RecordingSourceGainDb $Config)/20))).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture)
}
