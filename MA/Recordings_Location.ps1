<#
Recordings_Location.ps1 - documented version 123.
Recording and extraction folder preferences. Use an existing folder or show the Windows picker, then optionally save the choice as a default.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Portable_Paths.ps1')
# Show a folder picker initialized to the current recording location.
function Select-RecordingsFolder {
    param([string]$InitialPath,$Owner)
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-RecordingsFolderPicker
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description=if($script:UiLanguage -eq 'pt'){'Selecione uma pasta existente para as gravações.'}else{'Select an existing recordings folder.'}
        $dialog.ShowNewFolderButton=$true
        $candidate=$InitialPath
        while(-not [string]::IsNullOrWhiteSpace($candidate) -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
            $candidate=[IO.Path]::GetDirectoryName($candidate.TrimEnd('\','/'))
        }
        if(-not [string]::IsNullOrWhiteSpace($candidate)){$dialog.SelectedPath=$candidate}
        $result=[MachiningMonitor.VisibleFolderPicker]::Show($dialog,$Owner)
        if ($result -ne [Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.SelectedPath
    } finally { $dialog.Dispose() }
}
# Compile the Windows folder-picker integration once per process.
function Initialize-RecordingsFolderPicker {
    if('MachiningMonitor.VisibleFolderPicker' -as [type]){return}
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace MachiningMonitor {
 public static class VisibleFolderPicker {
  [DllImport("user32.dll")] private static extern IntPtr GetActiveWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder name, int count);
  [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr h, EnumProc callback, IntPtr data);
  private delegate bool EnumProc(IntPtr h, IntPtr data);
  [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
  public static bool RevealSelection() {
   IntPtr dialog=GetActiveWindow(), tree=IntPtr.Zero;
   if(dialog==IntPtr.Zero) return false;
   var name=new StringBuilder(256); GetClassName(dialog,name,name.Capacity);
   if(name.ToString()!="#32770") return false;
   EnumChildWindows(dialog,(h,p)=>{
    var childName=new StringBuilder(256); GetClassName(h,childName,childName.Capacity);
    if(childName.ToString()=="SysTreeView32") { tree=h; return false; }
    return true;
   },IntPtr.Zero);
   if(tree==IntPtr.Zero) return false;
   // The shell selects SelectedPath after initializing the folder tree. Scroll
   // that selected item into view, expanding its ancestors where necessary.
   IntPtr item=SendMessage(tree,0x110A,new IntPtr(9),IntPtr.Zero); // TVGN_CARET
   if(item==IntPtr.Zero) return false;
   SendMessage(tree,0x1114,IntPtr.Zero,item); // TVM_ENSUREVISIBLE
   return true;
  }
  public static DialogResult Show(FolderBrowserDialog dialog,IWin32Window owner) {
   using(var timer=new Timer()) {
    int attempts=0;
    timer.Interval=100;
    timer.Tick+=(s,e)=>{ if(RevealSelection() || ++attempts>=20) timer.Stop(); };
    timer.Start();
    try { return owner==null ? dialog.ShowDialog() : dialog.ShowDialog(owner); }
    finally { timer.Stop(); }
   }
  }
 }
}
'@
}
# Ask whether the chosen folder should become the default recording or extraction location.
function Confirm-DefaultRecordingsFolder {
    param([string]$Path,[switch]$Graphical,$Owner,[switch]$ForExtraction)
    $question=if($script:UiLanguage -eq 'pt'){'Pretende usar esta localização como predefinida?'}else{'Use this location as the default?'}
    if($ForExtraction){
        $question=if($script:UiLanguage -eq 'pt'){'Pretende usar esta localização como predefinida para as gravações extraídas?'}else{'Use this location as the default for extracted recordings?'}
    }
    if($Graphical){
        Add-Type -AssemblyName System.Windows.Forms
        $message=$question+[Environment]::NewLine+[Environment]::NewLine+$Path
        $result=if($null -ne $Owner){
            [Windows.Forms.MessageBox]::Show($Owner,$message,'Machining Monitor','YesNo','Question')
        }else{
            [Windows.Forms.MessageBox]::Show($message,'Machining Monitor','YesNo','Question')
        }
        return $result -eq [Windows.Forms.DialogResult]::Yes
    }
    do{$answer=Read-Host ($question+' (S/Y/N)')}while($answer -notmatch '^(s|sim|y|yes|n|no|não|nao)$')
    return $answer -match '^(s|sim|y|yes)$'
}
# Resolve or request an existing recording/extraction folder and optionally save the preference.
function Get-RecordingsDirectory {
    param([switch]$Graphical, [switch]$Choose, $Owner,[string]$CurrentPath,[switch]$ForExtraction)
    # A temporary selection belongs to this window, not to config.json.
    if(-not $Choose -and -not [string]::IsNullOrWhiteSpace($CurrentPath) -and (Test-Path -LiteralPath $CurrentPath -PathType Container)){
        return [IO.Path]::GetFullPath($CurrentPath)
    }
    $configPath = Join-Path $PSScriptRoot 'config.json'
    $config = [pscustomobject]@{}
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -isnot [pscustomobject]) { throw 'Invalid config.json' }
    }
    $configKey=if($ForExtraction){'ExtractedRecordingsPath'}else{'RecordingsPath'}
    $property = $config.PSObject.Properties[$configKey]
    $needsChoice = $null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)
    $missingLocation=$false
    if(-not $needsChoice){
        $missingLocation=-not (Test-Path -LiteralPath (Resolve-MonitorPath ([string]$property.Value)) -PathType Container)
    }
    if ($needsChoice -or $Choose -or $missingLocation) {
        $defaultPath = '..\Amostras PMM'
        if (-not $needsChoice) { $defaultPath = [string]$property.Value }
        if(-not [string]::IsNullOrWhiteSpace($CurrentPath)){$defaultPath=$CurrentPath}
        if ($Graphical) {
            $value=Select-RecordingsFolder (Resolve-MonitorPath $defaultPath) $Owner
            if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        } else {
            $value = Read-Host ((Get-UiText 'Recording folder [Enter uses default]') + ' (' + $defaultPath + ')')
            if ([string]::IsNullOrWhiteSpace($value)) { $value = $defaultPath }
        }
    } else { $value = [string]$property.Value }
    $storedValue = $value.Trim().Trim('"')
    $value = Resolve-MonitorPath $storedValue
    $value = [IO.Path]::GetFullPath($value)
    if (-not (Test-Path -LiteralPath $value -PathType Container)) {
        $message=if($script:UiLanguage -eq 'pt'){'A pasta das gravações não existe. Selecione uma pasta existente: '}else{'The recordings folder does not exist. Select an existing folder: '}
        throw ($message+$value)
    }
    if ($needsChoice -or $Choose -or $missingLocation) {
      if(Confirm-DefaultRecordingsFolder $value -Graphical:$Graphical -Owner $Owner -ForExtraction:$ForExtraction){
        # Re-read after the dialogs to preserve other settings changed meanwhile.
        if(Test-Path -LiteralPath $configPath){
            $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
            if($null -eq $config -or $config -isnot [pscustomobject]){throw 'Invalid config.json'}
        }
        $config | Add-Member NoteProperty $configKey $storedValue -Force
        $json = Format-UiJson ($config | ConvertTo-Json -Depth 20 -Compress)
        [IO.File]::WriteAllText($configPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
      }
    }
    return $value
}
