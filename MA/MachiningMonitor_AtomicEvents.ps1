# Creates and validates schema version 7 events for HTTP/TCP integration with MachiningMonitor.
function New-MachiningMonitorEvent {
    param(
        [Parameter(Mandatory)][guid]$MachineId,
        [Parameter(Mandatory)][guid]$DriverSessionId,
        [Parameter(Mandatory)][long]$Sequence,
        [Parameter(Mandatory)][string]$Occurrence,
        [Parameter(Mandatory)]$Value,
        [guid]$EventId = [guid]::NewGuid(),
        [DateTimeOffset]$OccurredAtUtc = [DateTimeOffset]::UtcNow,
        [string]$ExecutionId,
        [guid]$ContextId,
        [string]$State,
        [string]$Notes
    )
    $option=@(Get-EventOccurrenceOptions | Where-Object id -eq $Occurrence)
    if($option.Count -ne 1){throw "Unknown event occurrence: $Occurrence"}
    if($EventId -eq [guid]::Empty -or $MachineId -eq [guid]::Empty -or $DriverSessionId -eq [guid]::Empty){throw 'Event identities must be non-empty.'}
    if($Sequence -le 0){throw 'Sequence must be positive.'}
    if($OccurredAtUtc.Offset -ne [TimeSpan]::Zero){$OccurredAtUtc=$OccurredAtUtc.ToUniversalTime()}
    if($null -eq $Value){throw 'Atomic event Value cannot be null.'}
    $event=[ordered]@{
        schemaVersion=7;eventId=$EventId;machineId=$MachineId;driverSessionId=$DriverSessionId;sequence=$Sequence
        occurredAtUtc=$OccurredAtUtc;executionId=$ExecutionId;contextId=$ContextId;occurrence=$Occurrence
        state=$State;value=$Value;notes=$Notes
    }
    return [pscustomobject]$event
}

function Test-MachiningMonitorEvent {
    param([Parameter(Mandatory)]$Event)
    if($Event.schemaVersion -ne 7){throw 'Only schema version 7 is supported.'}
    if($Event.eventId -isnot [guid] -or $Event.eventId -eq [guid]::Empty){throw 'Invalid eventId.'}
    if($Event.machineId -isnot [guid] -or $Event.machineId -eq [guid]::Empty){throw 'Invalid machineId.'}
    if($Event.driverSessionId -isnot [guid] -or $Event.driverSessionId -eq [guid]::Empty){throw 'Invalid driverSessionId.'}
    if([long]$Event.sequence -le 0){throw 'Invalid sequence.'}
    if(@(Get-EventOccurrenceOptions | Where-Object id -eq ([string]$Event.occurrence)).Count -ne 1){throw 'Invalid occurrence.'}
    if($null -eq $Event.value){throw 'Atomic event value is required.'}
    return $true
}

function ConvertTo-MachiningMonitorEventJson {
    param([Parameter(Mandatory)]$Event)
    Test-MachiningMonitorEvent $Event | Out-Null
    return ($Event | ConvertTo-Json -Depth 20 -Compress)
}

function Send-MachiningMonitorEventHttp {
    param(
        [Parameter(Mandatory)]$Event,
        [Parameter(Mandatory)][string]$ServiceUrl,
        [Parameter(Mandatory)][string]$ApiKey
    )
    $json=ConvertTo-MachiningMonitorEventJson $Event
    $headers=@{'X-Api-Key'=$ApiKey}
    return Invoke-RestMethod -Method Post -Uri ($ServiceUrl.TrimEnd('/')+'/api/v6/events') -Headers $headers -ContentType 'application/json' -Body $json
}
