param([ValidateSet('Install','Uninstall','Start','Stop','Automatic','Manual')][string]$Action)
$ErrorActionPreference='Stop'
function Get-AudioService { Get-Service -Name AudioRTSP -ErrorAction SilentlyContinue }
function Invoke-AudioServiceAction([string]$Operation){
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        & "$PSScriptRoot\Service.ps1" -Action $Operation
    }else{
        $args='-NoProfile -ExecutionPolicy Bypass -File "'+$PSScriptRoot+'\Service.ps1" -Action '+$Operation
        $p=Start-Process "$PSHOME\powershell.exe" -ArgumentList $args -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if($p.ExitCode -ne 0){throw 'A operação do serviço não foi concluída.'}
    }
}
if(-not $Action){return}
try {
    $svc=Get-AudioService
    if($svc){
        $registered=Get-CimInstance Win32_Service -Filter "Name='AudioRTSP'"
        $expected='"'+(Join-Path $PSScriptRoot 'AudioRTSP.Service.exe')+'"'
        if($registered.PathName -ne $expected){throw 'O serviço AudioRTSP pertence a outra pasta. Desinstale-o nessa pasta primeiro.'}
    }
    switch($Action){
        Install {
            if($svc){throw 'O serviço já está instalado.'}
            $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
            & $compiler /nologo /platform:x64 /target:exe /reference:System.ServiceProcess.dll ('/out:'+(Join-Path $PSScriptRoot 'AudioRTSP.Service.exe')) (Join-Path $PSScriptRoot 'ServiceHost.cs')
            if($LASTEXITCODE -ne 0){throw 'Não foi possível compilar o serviço.'}
            $null=New-Service -Name AudioRTSP -DisplayName 'AudioRTSP' -BinaryPathName ('"'+(Join-Path $PSScriptRoot 'AudioRTSP.Service.exe')+'"') -StartupType Manual -Description 'Transmissão de áudio RTSP independente da aplicação.'
        }
        Uninstall {if($svc){Stop-Service AudioRTSP -ErrorAction Stop;& "$env:SystemRoot\System32\sc.exe" delete AudioRTSP | Out-Null;if($LASTEXITCODE -ne 0){throw 'Não foi possível desinstalar o serviço.'}}}
        Start {Start-Service AudioRTSP}
        Stop {Stop-Service AudioRTSP}
        Automatic {Set-Service AudioRTSP -StartupType Automatic}
        Manual {Set-Service AudioRTSP -StartupType Manual}
    }
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    $null=[Windows.Forms.MessageBox]::Show($_.Exception.Message,'AudioRTSP','OK','Error')
    exit 1
}
