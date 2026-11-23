# One ordered HTTPS queue per manager; commands are routed through the service.
function Initialize-PlaybackAnalyzer {
    if(-not ('MachiningMonitor.PlaybackAnalyzerClient' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Playback_AnalyzerClient.cs')}
}
function Prepare-PlaybackAnalyzer {
    $r=Get-ApplicationBroadcast
    if(-not $r -or -not $r.Config.AnalyzerEnabled -or -not $r.Config.Enabled){return}
    $c=$r.Config
    if(-not $c.ServiceApiKey -or -not $c.MachineId){return}
    $endpoint='https://'+$c.AnalyzerHost+':'+$c.AnalyzerPort
    $identity=$endpoint+'|'+$c.MachineId+'|'+$c.ServiceApiKey+'|'+$c.ServiceCertificateSha256
    if($r.AnalyzerIdentity -and $r.AnalyzerIdentity -ne $identity){Close-PlaybackAnalyzer}
    if(-not $r.AnalyzerClient){
        Initialize-PlaybackAnalyzer
        $r.AnalyzerClient=New-Object MachiningMonitor.PlaybackAnalyzerClient($endpoint,$c.ServiceApiKey,$c.ServiceCertificateSha256,([guid]$c.MachineId))
        $r.AnalyzerEndpoint=$endpoint;$r.AnalyzerIdentity=$identity
    }
}
function New-PlaybackAudioToken($Session){
    $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
    $Session.Token=[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $Session.TokenUser='session_'+[guid]::NewGuid().ToString('N');$Session.TokenExpires=[datetime]::UtcNow.AddMinutes(30)
    $Session.Auth.SetToken($Session.TokenUser,$Session.Token,$Session.TokenExpires)
}
function Set-AnalysisPlayerPaused($State,[bool]$Paused){
    # Temporary analysis startup hold: do not invoke the public pause toggle,
    # which intentionally ends a session on a user pause.
    if([bool]$State.Paused -eq $Paused){return}
    if($State.NativeMpv){
        if(-not $State.Clock.SetPaused($Paused,1000)){throw 'O leitor não confirmou a sincronização com a análise.'}
    }else{
        [MachiningMonitor.QualityClock]::Pause($State.Handle)
        if(-not $State.Clock.WaitForPlaybackState($Paused,1000,$State.Handle)){throw 'O leitor não confirmou a sincronização com a análise.'}
    }
    $State.Paused=$Paused
}
function Set-AnalyzerDiagnostic([string]$Message){$r=Get-ApplicationBroadcast;if($r){$r.AnalyzerStatus=$Message}}
function Disable-PlaybackAnalysis($State,[string]$Reason){
    $r=Get-ApplicationBroadcast;if(-not $r){return}
    $resumePending=[bool]($r.AnalysisHolding -or $r.AnalysisArmed)
    if($r.AnalysisId -and $r.AnalysisId -ne [guid]::Empty){Stop-AnalyzerPlayback}
    if($r.AnalyzerClient -and $Reason -eq 'disconnected'){$r.AnalyzerClient.ClearResync()}
    $r.AnalysisUnavailable=$Reason;$r.AnalysisProbeRequested=$false;$r.AnalysisResumeWithoutHold=$false;$r.AnalysisFault='';$r.AnalysisArmed=$false;$r.AnalysisHolding=$false
    if($resumePending -and $State -and $State.Clock -and $State.Clock.Ready -and $State.Paused -and -not $State.Ended){Set-AnalysisPlayerPaused $State $false}
}
function Restore-PlaybackAnalysis($State){
    $r=Get-ApplicationBroadcast
    if(-not $r -or -not $r.AnalysisUnavailable -or -not $r.AnalyzerClient){return $false}
    # A resume is an explicit opportunity to recheck the service. Do not rely
    # only on the background probe interval, which could leave the old status
    # visible for the whole pause.
    if(-not $r.AnalysisProbeRequested){$r.AnalyzerClient.RefreshPreparation();$r.AnalysisProbeRequested=$true;return $false}
    if(-not $r.AnalyzerClient.PrepareReady -or $r.AnalyzerClient.Failure){return $false}
    $r.AnalysisUnavailable='';$r.AnalysisProbeRequested=$false
    if(-not $State.Paused -and $State.Clock -and $State.Clock.Ready){
        # Recovery during playback must never pause a reader that the user
        # allowed to continue without analysis.
        $r.AnalysisResumeWithoutHold=$true
    }
    return $true
}
function Get-AnalyzerConnectionStatus {
    $r=Get-ApplicationBroadcast
    if(-not $r){return 'Gestor não iniciado.'}
    if(-not $r.Config.AnalyzerEnabled){return 'Análise através do serviço desativada.'}
    if($r.AnalysisFault){return ('Análise pausada: '+$r.AnalysisFault)}
    if($r.AnalyzerClient -and $r.AnalyzerClient.Failure){return $r.AnalyzerClient.Failure}
    if($r.AnalyzerClient -and $r.AnalyzerClient.HasAcknowledgement){return 'Pedidos confirmados pelo serviço e pelo Analyzer.'}
    if($r.AnalyzerClient -and $r.AnalyzerClient.Ready){return 'Ligação HTTPS/TLS ao serviço e Analyzer preparada.'}
    return 'A preparar a ligação ao serviço e ao Analyzer.'
}
function Stop-AnalyzerPlayback {
    $r=Get-ApplicationBroadcast
    if(-not $r){return}
    if(-not $r.AnalysisId -or $r.AnalysisId -eq [guid]::Empty){$r.AnalysisHolding=$false;$r.AnalysisArmed=$false;return}
    $r.LastStoppedId=$r.AnalysisId
    if($r.Session){$r.Session.Capture.SetProcess(0)}
    try{if($r.AnalyzerClient){$r.AnalyzerClient.StopAnalysis([guid]$r.Config.MachineId,$r.AnalysisId)}}
    finally{$r.AnalysisId=[guid]::Empty;$r.AnalysisHolding=$false;$r.AnalysisResumeWithoutHold=$false;if($r.Session -and $r.Session.Token){$r.RevokeAudio=$true;$r.RevokeAfterStop=$r.LastStoppedId;$r.RevokeDeadline=[datetime]::UtcNow.AddSeconds(1)}}
}
function Close-PlaybackAnalyzer {
    $r=Get-ApplicationBroadcast;if(-not $r){return}
    Stop-AnalyzerPlayback
    if($r.AnalyzerClient){$r.AnalyzerClient.Dispose();$r.AnalyzerClient=$null}
    $r.AnalyzerEndpoint='';$r.AnalyzerIdentity=''
}
function Update-AnalyzerPlayback($State){
    $r=Get-ApplicationBroadcast;if(-not $r){return};$c=$r.Config
    $trace='cfg='+[bool]$c.AnalyzerEnabled+' unavailable='+$r.AnalysisUnavailable+' paused='+[bool]$State.Paused+' client='+[bool]$r.AnalyzerClient+' ready='+($(if($r.AnalyzerClient){$r.AnalyzerClient.PrepareReady}else{'-'}))+' failure='+($(if($r.AnalyzerClient){$r.AnalyzerClient.Failure}else{'-'}))
    if($r.AnalyzerTraceKey -ne $trace){$r.AnalyzerTraceKey=$trace;Write-QualityDiagnostic $State ('analyzer-state '+$trace)}
    if(-not $c.AnalyzerEnabled){
        if(-not $r.AnalysisUnavailable){Disable-PlaybackAnalysis $State 'disabled'}
        return
    }
    # Create the persistent client as soon as analysis is enabled. This is
    # needed when the recording was opened while analysis was disabled: on
    # resume there must already be a client probing the Analyzer so the status
    # can change without reopening the recording.
    Prepare-PlaybackAnalyzer
    # The service can change from disabled (409) to enabled-but-unreachable
    # (503), or the reverse, while the recording remains open. Keep the user
    # message aligned with the latest probe instead of retaining the first
    # reason forever.
    if($r.AnalyzerClient){
        $failure=[string]$r.AnalyzerClient.Failure
        if($failure -match 'HTTP 409|desativada no serviço' -and $r.AnalysisUnavailable -ne 'disabled'){Disable-PlaybackAnalysis $State 'disabled';return}
        if($failure -match 'HTTP 503|Sem ligação ao Analyzer|Falha na ligação HTTPS/TLS' -and $r.AnalysisUnavailable -ne 'disconnected'){Disable-PlaybackAnalysis $State 'disconnected';return}
    }
    if($r.AnalysisUnavailable){
        # The background client keeps probing the service. Clear a temporary
        # refusal as soon as preparation succeeds, without reopening playback.
        if(-not (Restore-PlaybackAnalysis $State)){return}
    }
    if(-not $r.Session){
        Stop-AnalyzerPlayback
        if($State.Clock -and $State.Clock.Ready -and -not $State.Paused){Set-AnalysisPlayerPaused $State $true}
        $r.AnalysisFault='Emissão de áudio indisponível. Volte à lista e reveja a configuração da emissão.'
        return
    }
    if(-not $r.AnalyzerClient){return}
    if($r.AnalyzerClient.Failure -match 'HTTP 409|desativada no serviço'){
        Disable-PlaybackAnalysis $State 'disabled';return
    }
    if($r.AnalyzerClient.Failure -match 'HTTP 503|Sem ligação ao Analyzer|Falha na ligação HTTPS/TLS'){
        Disable-PlaybackAnalysis $State 'disconnected';return
    }
    if($r.AnalyzerClient.NeedsResync){
        $reason=$r.AnalyzerClient.Failure;$r.AnalysisFault=$reason
        $continuePlayback=[bool]$r.AnalysisResumeWithoutHold
        Stop-AnalyzerPlayback
        if(-not $continuePlayback -and -not $State.Paused){Set-AnalysisPlayerPaused $State $true}
        $r.AnalyzerClient.ClearResync()
        Set-AnalyzerDiagnostic ('Análise interrompida para evitar dessincronização. '+$reason+' Retome após restabelecer a ligação.')
        return
    }
    $startRequested=[bool]$r.AnalysisArmed
    if($startRequested -and -not $State.Clock.Ready){return}
    $r.AnalysisArmed=$false
    if($r.AnalysisHolding){
        if($State.Seeking -or $null -ne $State.PendingSeek -or $State.Ended){Stop-AnalyzerPlayback;return}
        if(-not $r.AnalysisId -or $r.AnalysisId -eq [guid]::Empty){
            if(-not $r.AnalyzerClient.Ready -or $r.RevokeAudio){return}
            $startRequested=$true;$r.AnalysisHolding=$false
        }elseif($r.AnalyzerClient.HasStarted($r.AnalysisId)){
            if(-not $r.Session.Capture.CaptureReady){return}
            Set-AnalysisPlayerPaused $State $false;$r.AnalysisHolding=$false
        }else{return}
    }
    $position=Get-QualityPosition $State
    $playing=$State.Clock -and $State.Clock.Ready -and (-not $State.Paused -or $startRequested) -and -not $State.Ended
    if(-not $playing -or $State.Seeking -or $null -ne $State.PendingSeek){Stop-AnalyzerPlayback;return}
    if($r.AnalysisId -and $r.AnalysisId -ne [guid]::Empty -and $position -lt ($r.AnalysisPosition-0.25)){Stop-AnalyzerPlayback;return}
    if($r.RevokeAudio){if($r.AnalysisResumeWithoutHold){return};if(-not $State.Paused){Set-AnalysisPlayerPaused $State $true};$r.AnalysisHolding=$true;return}
    if(-not $r.AnalyzerClient.Ready){
        if($r.AnalysisResumeWithoutHold){return}
        Set-AnalysisPlayerPaused $State $true;$r.AnalysisHolding=$true;return
    }
    if($r.AnalysisId -and $r.AnalysisId -ne [guid]::Empty -and [datetime]::UtcNow -ge $r.Session.TokenExpires){Stop-AnalyzerPlayback;return}
    $endpoint='https://'+$c.AnalyzerHost+':'+$c.AnalyzerPort
    if($r.AnalyzerEndpoint -and $r.AnalyzerEndpoint -ne $endpoint){Close-PlaybackAnalyzer;return}
    if(-not $r.AnalysisId -or $r.AnalysisId -eq [guid]::Empty){
        if(-not $c.ServiceApiKey -or [guid]$c.MachineId -eq [guid]::Empty){throw 'Configure a chave de acesso e o GUID da máquina no serviço.'}
        $r.AnalysisFault=''
        # Hold the reader until the first packet is accepted and real audio is ready.
        if(-not $r.AnalysisResumeWithoutHold){Set-AnalysisPlayerPaused $State $true;$r.AnalysisHolding=$true}
        New-PlaybackAudioToken $r.Session
        $r.Session.Capture.SetProcess($r.Player.Id)
        $r.AnalysisId=[guid]::NewGuid();$r.AnalysisSequence=0L;$r.AnalysisPosition=$position;$r.AnalysisEvents=@{};$r.AnalysisLastSent=[datetime]::MinValue
        $r.AnalysisContexts=@(Read-RecordingContexts $State.Split.Folder)
        $r.AnalysisExecution=(Split-Path $State.Split.Folder -Leaf)
    }
    if(([datetime]::UtcNow-$r.AnalysisLastSent).TotalSeconds -lt 0.1){return}
    $events=@($State.Items | Where-Object { [double]$_.timestamp_seconds -ge $r.AnalysisPosition -and [double]$_.timestamp_seconds -le $position -and -not $r.AnalysisEvents.ContainsKey([string]$_.id) } | Sort-Object timestamp_seconds)
    if($events.Count -gt 1000){Stop-AnalyzerPlayback;throw 'Demasiados eventos no intervalo de reprodução.'}
    $context=Get-RecordingContextAt $r.AnalysisContexts $position
    $packet=[ordered]@{machineId=$c.MachineId;sessionId=$r.AnalysisId.ToString();executionId=$r.AnalysisExecution;token=$r.Session.Token;username=$r.Session.TokenUser;expiresAtUtc=$r.Session.TokenExpires.ToString('o');sequence=($r.AnalysisSequence+1);sentAtUtc=[datetime]::UtcNow.ToString('o');positionSeconds=$position;context=$context.context;events=@($events)}
    $r.AnalyzerClient.SendPacket($r.AnalysisId,($packet|ConvertTo-Json -Depth 40 -Compress))
    $r.AnalysisSequence++;$r.AnalysisPosition=$position;$r.AnalysisLastSent=[datetime]::UtcNow
    foreach($event in $events){$r.AnalysisEvents[[string]$event.id]=$true}
    Set-AnalyzerDiagnostic (Get-AnalyzerConnectionStatus)
}
