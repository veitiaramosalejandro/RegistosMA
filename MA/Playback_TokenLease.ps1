# Independent lease guardian: receives only process identities and timestamps, never credentials.
param([int]$ServerId,[long]$ServerTicks,[int]$EncoderId,[long]$EncoderTicks,[int]$ManagerId,[long]$ManagerTicks,[long]$ExpiresTicks)
function Get-LeasedProcess([int]$ProcessId,[long]$Ticks){
    try{$process=[Diagnostics.Process]::GetProcessById($ProcessId);if($process.StartTime.ToUniversalTime().Ticks -eq $Ticks){return $process};$process.Dispose()}catch{}
    return $null
}
while([datetime]::UtcNow.Ticks -lt $ExpiresTicks){
    $manager=Get-LeasedProcess $ManagerId $ManagerTicks
    $server=Get-LeasedProcess $ServerId $ServerTicks
    if(-not $manager -or -not $server){if($manager){$manager.Dispose()};if($server){$server.Dispose()};break}
    $manager.Dispose();$server.Dispose();Start-Sleep -Seconds 1
}
foreach($identity in @(@($EncoderId,$EncoderTicks),@($ServerId,$ServerTicks))){
    $process=Get-LeasedProcess $identity[0] $identity[1]
    if($process){try{$process.Kill()}catch{}finally{$process.Dispose()}}
}
