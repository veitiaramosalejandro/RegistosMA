<#
Recording_Instance.ps1 - documented version 123.
Single-instance recording protection. A named mutex prevents concurrent capture for this installation; a named event lets a later launch activate the existing window.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Acquire the single-recording-instance guard for the selected application folder.
function Enter-RecordingInstance {
    param([string]$Folder)
    # Preserve the existing name so older versions cannot record concurrently.
    $name='Local\MachiningMonitorRecording_'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Folder)).Replace('\','_')
    $mutex=New-Object Threading.Mutex($false,$name)
    $acquired=$false
    try {
        try { $acquired=$mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired=$true }
        if ($acquired) {
            $activation=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($name+'_Activate'))
            return @{Mutex=$mutex;Activation=$activation;Acquired=$true;Notified=$false}
        }
        $notified=$false
        $activation=$null
        try {
            $activation=[Threading.EventWaitHandle]::OpenExisting($name+'_Activate')
            $notified=$activation.Set()
        } catch [Threading.WaitHandleCannotBeOpenedException] {
            # An older version has the lock and does not support activation.
        } finally { if($activation){$activation.Dispose()} }
        $mutex.Dispose()
        return @{Mutex=$null;Activation=$null;Acquired=$false;Notified=$notified}
    } catch {
        if($acquired){$mutex.ReleaseMutex()}
        $mutex.Dispose()
        throw
    }
}
# Release the recording-instance guard and related resources.
function Exit-RecordingInstance {
    param($Instance)
    if($null -eq $Instance){return}
    if($Instance.Activation){$Instance.Activation.Dispose()}
    if($Instance.Mutex){
        if($Instance.Acquired){$Instance.Mutex.ReleaseMutex()}
        $Instance.Mutex.Dispose()
    }
}
# Respond to another launch by restoring the existing recording window.
function Restore-RecordingInstanceWindow {
    param($Instance,$Form)
    if($null -eq $Instance -or $null -eq $Form -or $Form.IsDisposed){return}
    if($Instance.Activation.WaitOne(0)){
        if($Form.WindowState -eq 'Minimized'){$Form.WindowState='Normal'}
        $Form.Show(); $Form.BringToFront(); [void]$Form.Activate()
    }
}
