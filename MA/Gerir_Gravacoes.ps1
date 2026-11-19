<#
Gerir_Gravacoes.ps1 - version 168.
Management entry point. Choose a recording folder, browse recordings and open playback. Returning from playback reloads the list; finally releases the transition notice.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Language.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recordings_Location.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Selection.ps1')
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Transition_Notice.ps1')
. (Join-Path $PSScriptRoot 'Playback_Broadcast.ps1')
$notice=$null
# Run the guarded application workflow. Catch reports failures; finally releases the resources allocated by this workflow.
try {
    Start-ApplicationBroadcast
    $recordingsRoot=Get-RecordingsDirectory -Graphical
    if ([string]::IsNullOrWhiteSpace($recordingsRoot)) { return }
    $notice=New-Object MachiningMonitor.TransitionNotice
    $lastRecording=$null
    while ($true) {
        $recording=Select-RecordingGraphically $recordingsRoot $notice -CurrentRoot ([ref]$recordingsRoot) -SelectedRecording $lastRecording
        if ([string]::IsNullOrWhiteSpace($recording)) { break }
        $lastRecording=$recording
        $notice.Show((Get-SelectionText 'Please wait, opening recording...' 'Aguarde, a abrir a gravação…'))
        & (Join-Path $PSScriptRoot 'Playback_Blocks.ps1') -RecordingPath $recording -ShowPlaybackErrors -TransitionNotice $notice
        $notice.Show((Get-SelectionText 'Please wait, loading recordings...' 'Aguarde, a carregar a lista de gravações…'))
        $recordingsRoot=Get-RecordingsDirectory -Graphical -CurrentPath $recordingsRoot
        if ([string]::IsNullOrWhiteSpace($recordingsRoot)) { break }
    }
} catch {
    if ($null -ne $notice) { $notice.Hide() }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Machining Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
finally { Stop-ApplicationBroadcast; if ($null -ne $notice) { $notice.Dispose() } }
