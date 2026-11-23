. (Join-Path $PSScriptRoot 'Visualization_ResizeForm.ps1')
. (Join-Path $PSScriptRoot 'Reference_Selection.ps1')
. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Events.ps1 - version 243.
Event persistence, inheritance, editing and the playback management interface. events.json stores the timeline; metadata.json supplies the initial machining context.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Visualization_View.ps1')
. (Join-Path $PSScriptRoot 'Event_ListView.ps1')
. (Join-Path $PSScriptRoot 'Playback_DataLayout.ps1')
. (Join-Path $PSScriptRoot 'Recording_Contexts.ps1')
# Functions only: importing this file never starts playback.
# Choose the English or Portuguese text using the current UI language.
. (Join-Path $PSScriptRoot 'Deletion_Authorization.ps1')
function Get-QualityText {
    param([string]$English, [string]$Portuguese)
    if ($script:UiLanguage -eq 'pt') { return $Portuguese }; return $English
}
# Validate an event record before accepting it into the annotation timeline.
. (Join-Path $PSScriptRoot 'Event_Occurrences.ps1')
. (Join-Path $PSScriptRoot 'MachiningMonitor_AtomicEvents.ps1')
. (Join-Path $PSScriptRoot 'Machine_Activities.ps1')
function Test-QualityAnnotation {
    param($Item)
    if ($null -eq $Item -or $Item.id -isnot [string] -or [string]::IsNullOrWhiteSpace($Item.id) -or
        $Item.observations -isnot [string] -or $Item.timestamp_seconds -isnot [ValueType] -or
        $Item.quality -isnot [ValueType]) { throw 'Invalid rating annotation / Anotação de classificação inválida.' }
    if ($null -ne $Item.parameters) { Test-AnnotationParameters $Item.parameters }
    Test-EventOccurrences $Item
    $time = [double]$Item.timestamp_seconds; $quality = [double]$Item.quality
    if ([double]::IsNaN($time) -or [double]::IsInfinity($time) -or $time -lt 0 -or
        [double]::IsNaN($quality) -or $quality -lt 0 -or $quality -gt 5 -or $quality -ne [Math]::Floor($quality)) {
        throw 'Invalid time or rating (0-5) / Tempo ou classificação (0-5) inválidos.'
    }
}
# Load events.json and normalize legacy event fields and inherited machining parameters.
function Read-QualityAnnotations {
    param([string]$Path)
    # events.json is authoritative; import the legacy file only when it is absent.
    $eventsPath = $Path
    $importLegacy = $false
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ([IO.Path]::GetFileName($Path) -ine 'events.json') { return @() }
        $legacyPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) 'quality_annotations.json'
        if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { return @() }
        $Path = $legacyPath
        $importLegacy = $true
    }
    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $data -or $data.schema_version -ne 1 -or $null -eq $data.annotations -or $data.annotations -isnot [array]) {
        throw 'Invalid events.json / events.json inválido.'
    }
    $ids = @{}
    foreach ($item in $data.annotations) {
        # Preserve the original occurrence data; legacy records without an occurrence remain unchanged.
        Test-QualityAnnotation $item
        if ($ids.ContainsKey($item.id)) { throw 'Duplicate annotation ID / ID de anotação duplicado.' }
        $ids[$item.id] = $true
    }
    # Validate every event before creating the new file. Keep the legacy original.
    if ($importLegacy) { Save-QualityAnnotations $eventsPath @($data.annotations) }
    $fields=@(Resolve-EventFields @($data.annotations) $eventsPath)
    $resolved=@(Resolve-EventParameters $fields (Get-EventParameterBaseline $eventsPath) @(Read-RecordingContexts (Split-Path $eventsPath -Parent)))
    foreach($item in $resolved){
        if($item.event_changes.quality -and $null -eq $item.PSObject.Properties['occurrence']){
            # A quality change is represented as its own atomic occurrence and carries the resulting rating as value.
            $item|Add-Member NoteProperty occurrence 'QualityClassificationChanged' -Force
            $item|Add-Member NoteProperty value ([int]$item.quality) -Force
        }
        if($null -eq $item.PSObject.Properties['occurrence'] -and $null -ne $item.parameter_changes){
            $spindleChanged=@($item.parameter_changes.SpindleSpeed).Count -gt 0
            $feedChanged=@($item.parameter_changes.FeedRate).Count -gt 0
            # Only infer an adjustment when the legacy record contains one atomic adjustment group.
            if($spindleChanged -and -not $feedChanged){
                $item|Add-Member NoteProperty occurrence 'SpindleAdjusted' -Force
                $item|Add-Member NoteProperty value $item.parameters.SpindleSpeed.AdjustmentPercent -Force
            }elseif($feedChanged -and -not $spindleChanged){
                $item|Add-Member NoteProperty occurrence 'FeedAdjusted' -Force
                $item|Add-Member NoteProperty value $item.parameters.FeedRate.AdjustmentPercent -Force
            }
        }
    }
    Move-AutoParameterObservations $resolved
    return $resolved
}
# Migrate automatically generated parameter observations out of free-text notes.
function Move-AutoParameterObservations {
    param([AllowEmptyCollection()][object[]]$Items)
    $number='(?:não definido|[+-]?\d+(?:[.,]\d+)?)'
    $pattern='^(?:Rotação|Avanço) — (?:ajuste \[%\]|programado \[(?:rpm|mm/min)\]|após ajuste \[(?:rpm|mm/min)\]): (?:'+$number+' (?:→|->) '+$number+'|alterado para '+$number+')$'
    foreach($item in $Items){
        if($item.observations_format -eq 'manual'){continue}
        $lines=@();$changed=$false
        foreach($line in @($item.observations -split '\r\n|\r|\n')){
            $parts=@($line -split ';\s*');$kept=@()
            foreach($part in $parts){if($part.Trim() -match $pattern){$changed=$true}else{$kept+=,$part}}
            if($kept.Count){$lines+=,($kept -join '; ')}
        }
        if($changed){
            if($null -eq $item.PSObject.Properties['observations_before_changes_cleanup']){$item|Add-Member NoteProperty observations_before_changes_cleanup $item.observations}
            $item.observations=($lines -join [Environment]::NewLine).Trim([char[]]"`r`n")
        }
        $item|Add-Member NoteProperty observations_format 'manual' -Force
    }
}
# Create the initial field values used when resolving event inheritance.
function Get-EventFieldBaseline {
    $id='machining';$label='Machining'
    $path=Join-Path $PSScriptRoot 'machine_states.json'
    if(Test-Path -LiteralPath $path){
        $states=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
        $id=[string]$states.default
        $match=@($states.states|Where-Object id -eq $id|Select-PlaybackReference -First)
        if($match.Count){$label=$match[0].label_key;if(-not $label){$label=$match[0].label}}
        if(Get-Command Get-UiText -ErrorAction SilentlyContinue){$label=Get-UiText $label}
    }
    return [pscustomobject]@{quality=0;machine_state=$id;machine_state_label=$label}
}
# Infer explicit changes in older events that do not contain change tracking.
function Get-LegacyEventFieldChanges {
    param([object[]]$Items,$Baseline)
    $result=@{};$quality=$Baseline.quality;$state=$Baseline.machine_state
    foreach($item in @($Items|Sort-Object timestamp_seconds,created_at_utc,id)){
        $stateValue=$state;if($item.machine_state){$stateValue=$item.machine_state}
        $result[$item.id]=[pscustomobject]@{quality=($item.quality -ne $quality);machine_state=($stateValue -ne $state)}
        $quality=$item.quality;$state=$stateValue
    }
    return $result
}
# Rebuild effective event fields from explicit changes and preceding values.
# Missing values can mean inheritance rather than an empty replacement. Explicit-change
# information preserves that distinction when older records are normalized or an event is edited.
function Resolve-EventFields {
    param([AllowEmptyCollection()][object[]]$Items,[string]$Path)
    $ordered=@($Items|Sort-Object timestamp_seconds,created_at_utc,id)
    $baseline=Get-EventFieldBaseline
    $inferred=Get-LegacyEventFieldChanges $ordered $baseline
    $backupItems=@{};$backupChanges=@{}
    # The prior save can disambiguate a retroactive edit in legacy files.
    # Use it only when it contains the very same events at the same positions.
    if(@($ordered|Where-Object {$null -eq $_.PSObject.Properties['event_changes']}).Count -and (Test-Path -LiteralPath ($Path+'.bak'))){
        try{
            $backup=Get-Content -LiteralPath ($Path+'.bak') -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
            $valid=$backup.schema_version -eq 1 -and @($backup.annotations).Count -eq $ordered.Count
            foreach($item in @($backup.annotations)){Test-QualityAnnotation $item;if($backupItems.ContainsKey($item.id)){$valid=$false};$backupItems[$item.id]=$item}
            foreach($item in $ordered){if(-not $backupItems.ContainsKey($item.id) -or $backupItems[$item.id].timestamp_seconds -ne $item.timestamp_seconds){$valid=$false}}
            if($valid){$backupChanges=Get-LegacyEventFieldChanges @($backup.annotations) $baseline}else{$backupItems=@{}}
        }catch{$backupItems=@{}}
    }
    foreach($item in $ordered){
        if($null -eq $item.PSObject.Properties['event_changes']){
            $flags=$inferred[$item.id]
            if($backupItems.ContainsKey($item.id)){
                $prior=$backupItems[$item.id];$oldFlags=$backupChanges[$item.id]
                if($null -ne $prior.event_changes -and $prior.event_changes.quality -is [bool] -and $prior.event_changes.machine_state -is [bool]){$oldFlags=$prior.event_changes}
                if($item.quality -eq $prior.quality){$flags.quality=[bool]$oldFlags.quality}
                if($item.machine_state -eq $prior.machine_state){$flags.machine_state=[bool]$oldFlags.machine_state}
            }
            $item|Add-Member NoteProperty event_changes $flags
        }
        foreach($key in @('quality','machine_state')){
            if($null -eq $item.event_changes -or $item.event_changes.$key -isnot [bool]){throw 'Invalid event_changes.'}
        }
    }
    $quality=$baseline.quality;$state=$baseline.machine_state;$label=$baseline.machine_state_label
    foreach($item in $ordered){
        if($item.event_changes.quality){$quality=$item.quality}
        if($item.event_changes.machine_state){
            if([string]::IsNullOrWhiteSpace([string]$item.machine_state)){throw 'Invalid explicit machine state.'}
            $state=$item.machine_state;$label=$item.machine_state_label
        }
        $item.quality=[int]$quality
        $item|Add-Member NoteProperty machine_state $state -Force
        $item|Add-Member NoteProperty machine_state_label $label -Force
    }
    return $ordered
}
# Copy machining parameters so editing one event does not mutate another event.
function Copy-EventParameterObject {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 20|ConvertFrom-Json)
}
# Read the recording context that supplies initial machining parameter values.
function Get-EventParameterBaseline {
    param([string]$Path)
    $folder=Split-Path $Path -Parent
    if(Test-Path -LiteralPath (Join-Path $folder 'contexts.json')){
        $entries=@(Read-RecordingContexts $folder)
        $parameters=$entries[0].context.Parameters
        Test-AnnotationParameters $parameters
        return Copy-EventParameterObject $parameters
    }
    $metadataPath=Join-Path (Split-Path $Path -Parent) 'metadata.json'
    if(Test-Path -LiteralPath $metadataPath){
        $meta=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
        if($meta.Context.Parameters){Test-AnnotationParameters $meta.Context.Parameters;return Copy-EventParameterObject $meta.Context.Parameters}
    }
    return [pscustomobject]@{
        SpindleSpeed=[pscustomobject]@{ProgrammedRpm=$null;AdjustmentPercent=100;AdjustedRpm=$null}
        FeedRate=[pscustomobject]@{ProgrammedMmPerMin=$null;AdjustmentPercent=100;AdjustedMmPerMin=$null}
    }
}
# Identify which parameter fields are explicitly set rather than inherited.
function Get-EventParameterMask {
    param($Parameters,$Previous,[switch]$Pin)
    $mask=[pscustomobject]@{SpindleSpeed=@();FeedRate=@()}
    foreach($row in @(@('SpindleSpeed','ProgrammedRpm','AdjustedRpm'),@('FeedRate','ProgrammedMmPerMin','AdjustedMmPerMin'))){
        $name=$row[0];$p=$Parameters.$name;$prior=$Previous.$name;$keys=@()
        foreach($key in @($row[1],'AdjustmentPercent')){if($Pin -or $p.$key -ne $prior.$key){$keys+=,$key}}
        if(($Pin -and ($null -eq $p.AdjustmentPercent -or $null -eq $p.($row[1]))) -or (-not $keys.Count -and $p.($row[2]) -ne $prior.($row[2]))){$keys+=,$row[2]}
        $mask.$name=@($keys)
    }
    return $mask
}
# Walk events in sequence and apply parameter changes over the previous baseline.
# Use the recording context as the initial baseline. Copy effective values between events
# so editing a later parameter cannot mutate an object already assigned to an earlier event.
function Resolve-EventParameters {
    param([AllowEmptyCollection()][object[]]$Items,$Baseline,[object[]]$Contexts=@())
    $current=Copy-EventParameterObject $Baseline
    # Infer legacy intentions against the original snapshots before resolving.
    # This prevents an inserted event from turning inherited old values into edits.
    $previous=Copy-EventParameterObject $Baseline
    $ordered=@($Items|Sort-Object timestamp_seconds,created_at_utc,id)
    foreach($item in $ordered){
        if($null -eq $item.parameters){continue}
        Test-AnnotationParameters $item.parameters
        $hadMask=$null -ne $item.PSObject.Properties['parameter_changes']
        if(-not $hadMask){
            $item|Add-Member NoteProperty parameter_changes (Get-EventParameterMask $item.parameters $previous)
        }
        foreach($row in @(@('SpindleSpeed','ProgrammedRpm','AdjustedRpm'),@('FeedRate','ProgrammedMmPerMin','AdjustedMmPerMin'))){
            $name=$row[0]
            if($null -eq $item.parameter_changes -or $null -eq $item.parameter_changes.PSObject.Properties[$name]){throw 'Invalid parameter_changes.'}
            foreach($key in @($item.parameter_changes.$name)){
                if($key -notin @($row[1],'AdjustmentPercent',$row[2])){throw 'Invalid parameter_changes field.'}
            }
            if(-not $hadMask -and $item.parameters.$name.($row[1]) -eq $previous.$name.($row[1]) -and $item.parameters.$name.AdjustmentPercent -eq $previous.$name.AdjustmentPercent -and $item.parameters.$name.($row[2]) -eq $previous.$name.($row[2])){
                $item.parameter_changes.$name=@()
            }
        }
        $previous=Copy-EventParameterObject $item.parameters
    }
    $contextIndex=0;$contextOrder=@($Contexts | Sort-Object timestamp_seconds)
    foreach($item in $ordered){
        # Context applies first when an event has exactly the same timestamp.
        while($contextIndex -lt $contextOrder.Count -and $contextOrder[$contextIndex].timestamp_seconds -le $item.timestamp_seconds){
            $current=Copy-EventParameterObject $contextOrder[$contextIndex].context.Parameters
            $contextIndex++
        }
        if($null -eq $item.parameters){continue}
        foreach($row in @(@('SpindleSpeed','ProgrammedRpm','AdjustedRpm'),@('FeedRate','ProgrammedMmPerMin','AdjustedMmPerMin'))){
            $name=$row[0];$programmed=$row[1];$adjusted=$row[2]
            if($null -eq $item.parameter_changes -or $null -eq $item.parameter_changes.PSObject.Properties[$name]){throw 'Invalid parameter_changes.'}
            $keys=@($item.parameter_changes.$name)
            foreach($key in $keys){
                if($key -notin @($programmed,'AdjustmentPercent',$adjusted)){throw 'Invalid parameter_changes field.'}
                $current.$name.$key=$item.parameters.$name.$key
            }
            $rate=$current.$name
            if($adjusted -in $keys){
                if($null -ne $rate.$programmed -and $rate.$programmed -gt 0 -and $null -ne $rate.$adjusted){$rate.AdjustmentPercent=[Math]::Round(100*[double]$rate.$adjusted/[double]$rate.$programmed,2)}
            }elseif($keys.Count){
                $rate.$adjusted=if($null -ne $rate.$programmed -and $null -ne $rate.AdjustmentPercent){[double]$rate.$programmed*[double]$rate.AdjustmentPercent/100}else{$null}
            }
        }
        Test-AnnotationParameters $current
        $item.parameters=Copy-EventParameterObject $current
    }
    return $ordered
}
# Collect field changes entered in the event editor.
function Get-EditedEventFieldChanges {
    param($Context)
    $qualityChanged=$false
    if([int]$Context.Quality.SelectedIndex -ne [int]$Context.InitialQuality){
        $qualityChanged=[int]$Context.Quality.SelectedIndex -ne [int]$Context.InheritedQuality
    }elseif($null -ne $Context.Old -and $null -ne $Context.Old.event_changes){
        $qualityChanged=[bool]$Context.Old.event_changes.quality -and ([int]$Context.Quality.SelectedIndex -ne [int]$Context.InheritedQuality)
    }
    return [pscustomobject]@{
        quality=$qualityChanged
        machine_state=($Context.MachineState.SelectedItem.id -ne $Context.InheritedMachineState)
    }
}
# Collect the editor's explicit parameter overrides for persistence.
function Get-EditedEventParameterMask {
    param($Context)
    $mask=[pscustomobject]@{SpindleSpeed=@();FeedRate=@()}
    if($null -ne $Context.Old -and $null -ne $Context.Old.parameter_changes){$mask=Copy-EventParameterObject $Context.Old.parameter_changes}
    $index=0
    foreach($row in @(@('SpindleSpeed','ProgrammedRpm','AdjustedRpm'),@('FeedRate','ProgrammedMmPerMin','AdjustedMmPerMin'))){
        $name=$row[0];$rate=$Context.Rates[$index];$index++
        $keys=@($mask.$name)
        $changed=Get-EventParameterMask $Context.AnnotationParameters $Context.InitialParameters
        foreach($key in @($changed.$name)){if($key -notin $keys){$keys+=,$key}}
        $current=$Context.AnnotationParameters.$name;$initial=$Context.InitialParameters.$name
        if($rate.LastRole -eq 'Adjusted' -and ($current.($row[2]) -ne $initial.($row[2]) -or $current.AdjustmentPercent -ne $initial.AdjustmentPercent)){
            $keys=@($keys|Where-Object {$_ -ne 'AdjustmentPercent'});$keys+=,$row[2]
        }elseif($current.AdjustmentPercent -ne $initial.AdjustmentPercent){
            $keys=@($keys|Where-Object {$_ -ne $row[2]});$keys+=,'AdjustmentPercent'
        }
        $inherited=$Context.InheritedParameters
        if($null -eq $inherited){$inherited=$Context.InitialParameters}
        # Touching a field is not a change. Keep only the final differences.
        $mask.$name=@($keys|Select-Object -Unique|Where-Object {
            $current.$_ -ne $inherited.$name.$_ -or ($_ -eq $row[2] -and $current.AdjustmentPercent -ne $inherited.$name.AdjustmentPercent)
        })
    }
    return $mask
}
# Check that machining parameter data has the expected structure and valid values.
function Test-AnnotationParameters {
    param($Parameters)
    foreach ($row in @(@('SpindleSpeed','ProgrammedRpm','AdjustmentPercent','AdjustedRpm'),@('FeedRate','ProgrammedMmPerMin','AdjustmentPercent','AdjustedMmPerMin'))) {
        $group=$Parameters.($row[0])
        if ($null -eq $group) { throw 'Parâmetros de maquinagem inválidos.' }
        foreach ($key in $row[1..3]) {
            if ($null -eq $group.PSObject.Properties[$key]) { throw 'Parâmetros de maquinagem incompletos.' }
            $value=$group.$key
            if ($null -ne $value -and ($value -isnot [ValueType] -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -lt 0)) { throw 'Parâmetros de maquinagem inválidos.' }
        }
    }
}
# Validate and persist event annotations; optionally return the saved records.
function Save-QualityAnnotations {
    param([string]$Path, [AllowEmptyCollection()][object[]]$Annotations,[switch]$PassThru)
    foreach ($item in $Annotations) { Test-QualityAnnotation $item }
    $fields=@(Resolve-EventFields @(Copy-EventParameterObject @($Annotations)) $Path)
    $Annotations=@(Resolve-EventParameters $fields (Get-EventParameterBaseline $Path) @(Read-RecordingContexts (Split-Path $Path -Parent)))
    Move-AutoParameterObservations $Annotations
    $data = [ordered]@{ schema_version = 1; time_reference = 'playback_seconds'; annotations = @($Annotations | Sort-Object timestamp_seconds, created_at_utc, id) }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($data | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            try { [IO.File]::Replace($temporary, $Path, $Path + '.bak') }
            catch [UnauthorizedAccessException] {
                # Some recording locations allow writes but not File.Replace.
                [IO.File]::Copy($Path, $Path + '.bak', $true)
                [IO.File]::Copy($temporary, $Path, $true)
            }
        }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    if($PassThru){return $Annotations}
}
# Compile the shared native-window and playback-clock helper once per PowerShell process.
function Initialize-QualityClock {
    if ('MachiningMonitor.QualityClock' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Globalization;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
 public sealed class QualityClock {
  private readonly object gate = new object();
  private double seconds; private bool ready; private long samples;
  public double Seconds { get { lock(gate) return seconds; } }
  public bool Ready { get { lock(gate) return ready; } }
  public long Samples { get { lock(gate) return samples; } }
  public Task Reader;
  public void Parse(string line) {
   line = Regex.Replace(line, @"\x1B\[[0-?]*[ -/]*[@-~]", "");
   var m = Regex.Match(line, @"^\s*([0-9]+\.[0-9]+)\s+(?:M-A|A-V|M-V):");
   double value;
   if(m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out value))
    lock(gate) { seconds = value; ready = true; samples++; }
  }
  public void Start(StreamReader input) {
   Reader = Task.Run(() => { var line = new StringBuilder(); int ch;
    try { while((ch = input.Read()) >= 0) {
     if(ch == 13 || ch == 10) { Parse(line.ToString()); line.Clear(); }
     else if(line.Length < 16384) line.Append((char)ch);
    } Parse(line.ToString()); } catch(ObjectDisposedException) {} catch(IOException) {}
   });
  }
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr w, uint m, IntPtr a, IntPtr b);
  [DllImport("user32.dll")] public static extern bool EnableWindow(IntPtr w, bool enable);
  [DllImport("user32.dll")] private static extern bool InvalidateRect(IntPtr w, IntPtr rect, bool erase);
  [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint key, uint mode);
  private delegate bool EnumWindowProc(IntPtr w, IntPtr parameter);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr w, out uint process);
  [DllImport("user32.dll")] private static extern IntPtr SetParent(IntPtr child, IntPtr parent);
  [DllImport("user32.dll", EntryPoint="GetWindowLongW")] private static extern int GetWindowLong(IntPtr w, int index);
  [DllImport("user32.dll", EntryPoint="SetWindowLongW")] private static extern int SetWindowLong(IntPtr w, int index, int value);
  [DllImport("user32.dll")] private static extern bool MoveWindow(IntPtr w, int x, int y, int width, int height, bool repaint);
  [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr w, IntPtr after, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr w);
  public static IntPtr FindWindow(int processId) {
   IntPtr found = IntPtr.Zero;
   EnumWindows((w, p) => { uint id; GetWindowThreadProcessId(w, out id);
    if(id == processId && IsWindowVisible(w)) { found = w; return false; } return true;
   }, IntPtr.Zero); return found;
  }
  public static void Embed(IntPtr child, IntPtr parent, int width, int height) {
   SetParent(child, parent);
   int style = GetWindowLong(child, -16);
   style = (style & ~unchecked((int)0x80CF0000)) | 0x40000000;
   SetWindowLong(child, -16, style);
   SetWindowPos(child, IntPtr.Zero, 0, 0, width, height, 0x0020 | 0x0004 | 0x0040);
  }
  public static void Resize(IntPtr child, int width, int height) {
   if(child != IntPtr.Zero) MoveWindow(child, 0, 0, width, height, true);
  }
  public static IntPtr PauseKeyData(bool release) {
   // SDL identifies letters by the physical scan code in bits 16..23.
   // A zero lParam produces SDL_SCANCODE_UNKNOWN, even with VK_P in wParam.
   uint scan = MapVirtualKey(0x50, 0);
   if(scan == 0) throw new InvalidOperationException("Cannot map pause key / Não é possível mapear a tecla de pausa.");
   uint bits = 1U | (scan << 16);
   if(release) bits |= 0xC0000000U;
   return new IntPtr(unchecked((int)bits));
  }
  public static void Pause(IntPtr window) {
   if(window == IntPtr.Zero || !PostMessage(window, 0x100, (IntPtr)0x50, PauseKeyData(false)))
    throw new InvalidOperationException("Cannot control playback / Não é possível controlar a reprodução.");
   if(!PostMessage(window, 0x101, (IntPtr)0x50, PauseKeyData(true)))
    throw new InvalidOperationException("Cannot release pause key / Não é possível libertar a tecla de pausa.");
  }
  public bool WaitForPlaybackState(bool paused, int timeoutMs) {
   return WaitForPlaybackState(paused, timeoutMs, IntPtr.Zero);
  }
  public bool WaitForPlaybackState(bool paused, int timeoutMs, IntPtr window) {
   var watch = System.Diagnostics.Stopwatch.StartNew();
   double reference = Seconds; long lastSample = Samples; long startSample = lastSample;
   long stableSince = 0; long lastRefresh = -100;
   while(watch.ElapsedMilliseconds < timeoutMs) {
    System.Threading.Thread.Sleep(20);
    if(paused && window != IntPtr.Zero && watch.ElapsedMilliseconds - lastRefresh >= 100) {
     // FFplay normally stops reporting status while paused. An expose event
     // redraws the SAME frame and reports its frozen clock without advancing it.
     if(!InvalidateRect(window, IntPtr.Zero, false) || !PostMessage(window, 0xF, IntPtr.Zero, IntPtr.Zero)) return false;
     lastRefresh = watch.ElapsedMilliseconds;
    }
    long currentSample = Samples; double current = Seconds;
    if(currentSample == lastSample) continue; // Silence is not proof of a pause.
    lastSample = currentSample;
    if(!paused && current > reference + 0.02) return true;
    if(paused) {
     if(Math.Abs(current - reference) > 0.01) {
      reference = current; stableSince = watch.ElapsedMilliseconds; startSample = currentSample;
     } else if(currentSample - startSample >= 3 && watch.ElapsedMilliseconds - stableSince >= 300) return true;
    }
   }
   return false;
  }
 }
}
'@
}
# Return the localized name associated with a quality level.
function Get-QualityName {
    param([ValidateRange(0,5)][int]$Quality)
    $pt=@('Sem classificação','Não conforme','Deficiente','Conforme','Boa','Excelente')
    $en=@('Unclassified','Non-conforming','Deficient','Conforming','Good','Excellent')
    return Get-QualityText $en[$Quality] $pt[$Quality]
}
# Return the quality text used in the interface.
function Get-QualityDisplay {
    param([ValidateRange(0,5)][int]$Quality)
    return '{0} - {1}' -f $Quality,(Get-QualityName $Quality)
}
# Explain the meaning of a quality level to the operator.
function Get-QualityMeaning {
    param([ValidateRange(0,5)][int]$Quality)
    $pt=@('Ainda não foi avaliado.','Defeitos graves, fora de tolerância, acabamento inadequado, risco funcional.','Problemas relevantes, dentro da tolerância mas com defeitos visíveis, vibração, marcas, ruído, instabilidade.','Cumpre tolerâncias e requisitos funcionais. Acabamento normal. Sem defeitos críticos.','Acabamento superior, estabilidade, vibração controlada, classificação acima do mínimo requerido.','Acabamento ótimo, estabilidade perfeita, sem marcas, sem desvios, resultado ideal.')
    $en=@('Not yet assessed.','Severe defects, out of tolerance, inadequate finish, functional risk.','Significant problems, within tolerance but with visible defects, vibration, marks, noise or instability.','Meets tolerances and functional requirements. Normal finish. No critical defects.','Superior finish, stability, controlled vibration, rating above the minimum required.','Optimal finish, perfect stability, no marks, no deviations, ideal result.')
    return Get-QualityText $en[$Quality] $pt[$Quality]
}
# Map a quality level to its display color.
function Get-QualityColor {
    param([ValidateRange(0,5)][int]$Quality)
    $colors=@('#BDBDBD','#D73027','#F49B43','#B5C86A','#55A84F','#16803C')
    return [Drawing.ColorTranslator]::FromHtml($colors[$Quality])
}
# Each explicit quality assessment rates the interval ending at its timestamp.
function Get-QualitySegments {
    param($State)
    if ($State.Duration -le 0) { return @() }
    $cursor=0.0
    foreach ($item in @($State.Items | Where-Object {$_.occurrence -eq 'QualityClassificationChanged' -or (-not $_.occurrence -and $_.event_changes.quality)} | Sort-Object timestamp_seconds,created_at_utc,id)) {
        $boundary=[Math]::Min([double]$State.Duration,[Math]::Max(0.0,[double]$item.timestamp_seconds))
        $quality=if($item.occurrence -eq 'QualityClassificationChanged' -and $null -ne $item.value){[int]$item.value}else{[int]$item.quality}
        if ($boundary -gt $cursor) { [pscustomobject]@{Start=$cursor; End=$boundary; Quality=$quality} }
        $cursor=$boundary
    }
    # The portion after the final assessment has not yet been assessed.
    if ($cursor -lt $State.Duration) { [pscustomobject]@{Start=$cursor; End=[double]$State.Duration; Quality=0} }
}
# Resolve the assessment covering a row's starting instant using the timeline's half-open intervals.
function Get-IntervalQuality {
    param([AllowEmptyCollection()][object[]]$Segments,[double]$Seconds)
    foreach($segment in $Segments){
        if($Seconds -ge $segment.Start -and $Seconds -lt $segment.End){return [int]$segment.Quality}
    }
    return 0
}

# Read the recording start time used to convert relative positions to wall-clock times.
function Get-AnnotationRecordingStart {
    param([string]$Folder)
    $metadataPath=Join-Path $Folder 'metadata.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $value=[string]$metadata.StartTime
            if ($metadata.StartTime -is [datetime]) { $value=$metadata.StartTime.ToString('o') }
            $parsed=[DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { return $parsed }
        } catch { }
    }
    $folderStart=[datetime]::MinValue
    if ([datetime]::TryParseExact((Split-Path $Folder -Leaf),'yyyyMMdd_HHmmss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$folderStart)) {
        return [DateTimeOffset]$folderStart
    }
    return $null
}
# Build the playback window title for the selected recording.
function Get-QualityPlaybackTitle {
    param([string]$Folder,[double]$Seconds=0,$Entries=$null)
    $context=$null
    try {
        $metadata=Get-Content -LiteralPath (Join-Path $Folder 'metadata.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $context=$metadata.Context
    } catch { }
    if($null -eq $Entries){$Entries=@(Read-RecordingContexts $Folder)}
    $context=(Get-RecordingContextAt $Entries $Seconds).context
    $fields=@($context.Machine,$context.Work,$context.Operation,$context.Tool.Type)
    $values=@(foreach ($field in $fields) {
        $text=([string]$field -replace '[\x00-\x1F\x7F]',' ').Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { '-' } else { $text }
    })
    $prefix=Get-QualityText 'Machining Monitor - Recording' 'Machining Monitor - Gravação'
    return $prefix+': '+([IO.Path]::GetFileName($Folder.TrimEnd('\','/')))+'  |  '+($values -join '  |  ')
}
# Build the playback and event-management window and wire its controls to shared state.
function New-QualityPanel {
    param($Player, [string]$Folder, [double]$DurationSeconds=0, [switch]$DeferShow)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('MachiningMonitor.BufferedTimeline' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
namespace MachiningMonitor {
 public static class TrackbarGeometry {
  [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
  private struct Rect { public int Left, Top, Right, Bottom; }
  [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="SendMessageW")]
  private static extern System.IntPtr Send(System.IntPtr w, uint msg, System.IntPtr a, System.IntPtr b);
  [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="SendMessageW")]
  private static extern System.IntPtr GetRect(System.IntPtr w, uint msg, System.IntPtr a, ref Rect r);
  public static float Center(System.Windows.Forms.TrackBar slider) {
   Rect r = new Rect(); GetRect(slider.Handle, 0x419, System.IntPtr.Zero, ref r);
   return (r.Left + r.Right - 1) / 2f;
  }
  public static System.Drawing.PointF Limits(System.Windows.Forms.TrackBar slider) {
   int original = slider.Value;
   Send(slider.Handle,0xB,System.IntPtr.Zero,System.IntPtr.Zero);
   try {
    // WM_SETREDRAW suppresses painting while TBM_SETPOS updates native geometry.
    // No scroll events are raised and the original position is restored.
    Send(slider.Handle,0x405,(System.IntPtr)1,(System.IntPtr)slider.Minimum);
    float start = Center(slider);
    Send(slider.Handle,0x405,(System.IntPtr)1,(System.IntPtr)slider.Maximum);
    return new System.Drawing.PointF(start, Center(slider));
   } finally {
    Send(slider.Handle,0x405,(System.IntPtr)1,(System.IntPtr)original);
    Send(slider.Handle,0xB,(System.IntPtr)1,System.IntPtr.Zero);
    slider.Invalidate();
   }
  }
 }
 public sealed class BufferedTimeline : System.Windows.Forms.Panel {
  protected override void WndProc(ref System.Windows.Forms.Message m) {
   if(m.Msg==0x204 || m.Msg==0x205 || m.Msg==0x206 || m.Msg==0x7b)return;
   base.WndProc(ref m);
  }
  public BufferedTimeline() {
   SetStyle(System.Windows.Forms.ControlStyles.UserPaint |
            System.Windows.Forms.ControlStyles.AllPaintingInWmPaint |
            System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer |
            System.Windows.Forms.ControlStyles.ResizeRedraw |
            System.Windows.Forms.ControlStyles.Selectable, true);
   UpdateStyles();
  }
  public bool Buffered { get { return DoubleBuffered; } }
 }
 public sealed class TimelineTrackBar : System.Windows.Forms.TrackBar {
  protected override void WndProc(ref System.Windows.Forms.Message m) {
   if(m.Msg==0x204 || m.Msg==0x205 || m.Msg==0x206 || m.Msg==0x7b)return;
   base.WndProc(ref m);
  }
 }
}
'@
    }
    Initialize-QualityClock
    $state = @{ Player = $Player; Clock = (New-Object MachiningMonitor.QualityClock); Paused = $false;
        Path = (Join-Path $Folder 'events.json'); Items = @(); Handle = [IntPtr]::Zero;
        Duration = $DurationSeconds; BaseSeconds = 0.0; PendingSeek = $null; Dragging = $false; RestorePaused=$true; Ended=$false }
    # Read before permitting writes. A corrupt file is never silently replaced.
    $state.ContextEntries=@(Read-RecordingContexts $Folder)
    Test-RecordingContexts $state.ContextEntries $DurationSeconds
    $state.Items = @(Read-QualityAnnotations $state.Path)
    $state.RecordingStart=Get-AnnotationRecordingStart $Folder
    if ($null -ne $Player) { $state.Clock.Start($Player.StandardError) }
    $form = New-Object MachiningMonitor.StablePlaybackForm
    $form.Text = Get-QualityPlaybackTitle $Folder
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $form.ClientSize = New-Object Drawing.Size(([Math]::Min(1170,$area.Width-60)),([Math]::Min(980,$area.Height-80)))
    $state.MinimumWindowSize=New-Object Drawing.Size($form.Width,([Math]::Min(480,$form.Height)))
    $form.MinimumSize = $state.MinimumWindowSize
    $form.StartPosition = 'CenterScreen'
    $form.Tag = $state
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill'; $layout.Margin=New-Object Windows.Forms.Padding(0)
    $layout.Padding=New-Object Windows.Forms.Padding(0); $layout.ColumnCount=1; $layout.RowCount=3
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,28)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,220)))
    $form.Controls.Add($layout)
    $hostPanel = New-Object Windows.Forms.Panel
    $hostPanel.Dock = 'Fill'; $hostPanel.BackColor = [Drawing.Color]::Black
    $hostPanel.Margin=New-Object Windows.Forms.Padding(0)
    $hostPanel.Enabled=$false; $hostPanel.TabStop=$false
    $mediaPanel=New-Object Windows.Forms.Panel; $mediaPanel.Dock='Fill';$mediaPanel.Margin=New-Object Windows.Forms.Padding(0)
    $viewport=New-VisualizationViewport $hostPanel;$mediaPanel.Controls.Add($viewport);$state.Viewport=$viewport
    $choices=New-Object Windows.Forms.Panel;$choices.Dock='Top';$choices.Height=64
    $showVideo=New-Object Windows.Forms.CheckBox;$showVideo.Text=Get-QualityText 'Show video' 'Visualizar vídeo';$showVideo.AutoSize=$true
    $showCharts=New-Object Windows.Forms.CheckBox;$showCharts.Text=Get-QualityText 'Show charts' 'Visualizar gráficos';$showCharts.AutoSize=$true
    $showVideo.Location=New-Object Drawing.Point(12,5);$showCharts.Location=New-Object Drawing.Point(160,5)
    $choices.Controls.AddRange(@($showVideo,$showCharts));Add-VisualizationSizingControls $choices $viewport;$mediaPanel.Controls.Add($choices)
    $state.ShowVideo=$showVideo;$state.ShowCharts=$showCharts
    foreach($choice in @($showVideo,$showCharts)){$choice.Add_CheckedChanged({param($sender,$eventArgs) Update-PlaybackViewChoices $sender.FindForm().Tag})}
    $layout.Controls.Add($mediaPanel,0,0); $state.VideoHost = $hostPanel
    $annotations = New-Object Windows.Forms.Panel
    $annotations.Dock = 'Fill'; $annotations.Margin=New-Object Windows.Forms.Padding(0)
    $layout.Controls.Add($annotations,0,2)
    Add-PlaybackDataLayout $state $layout $mediaPanel
    $timeline = New-Object MachiningMonitor.BufferedTimeline
    $timeline.SetBounds(12,4,($form.ClientSize.Width-24),42); $timeline.Anchor='Top,Left,Right'
    $timeline.Tag=$state; $annotations.Controls.Add($timeline); $state.Timeline=$timeline
    # Focus the strip for wheel input; the slider remains a full-recording overview.
    $timeline.TabStop=$true
    $timeline.Add_MouseEnter({ param($sender,$eventArgs) [void]$sender.Focus() })
    $timeline.Add_MouseWheel({ param($sender,$eventArgs)
        if ($eventArgs -is [Windows.Forms.HandledMouseEventArgs]) { $eventArgs.Handled=$true }
        $zoom=$true
        Move-TimelineWindow $sender.Tag $eventArgs.X $eventArgs.Delta $zoom
    })
    $timeline.Add_Paint({
        param($sender,$eventArgs)
        $s=$sender.Tag; if ($s.Duration -le 0) { return }
        $range=Get-TimelineRange $s
        Draw-TimelineScale $s $eventArgs.Graphics
        foreach ($segment in @(Get-QualitySegments $s)) {
            $left=[single][Math]::Max(0,($range.X+$segment.Start/$s.Duration*($range.Y-$range.X)))
            $right=[single][Math]::Min($sender.ClientSize.Width,($range.X+$segment.End/$s.Duration*($range.Y-$range.X)))
            if ($right -le $left) { continue }
            $brush=New-Object Drawing.SolidBrush((Get-QualityColor $segment.Quality))
            try { $eventArgs.Graphics.FillRectangle($brush,$left,[single]4,[single]($right-$left),[single]8) }
            finally { $brush.Dispose() }
        }
        foreach($entry in $s.ContextEntries){
            $cx=[single]($range.X+$entry.timestamp_seconds/$s.Duration*($range.Y-$range.X))
            if($cx -ge 0 -and $cx -le $sender.ClientSize.Width){$contextPen=New-Object Drawing.Pen([Drawing.Color]::Purple,[single]2);try{$eventArgs.Graphics.DrawLine($contextPen,$cx,0,$cx,22)}finally{$contextPen.Dispose()}}
        }
        foreach ($item in $s.Items) {
            $x=[single]($range.X+[Math]::Min(1.0,$item.timestamp_seconds/$s.Duration)*($range.Y-$range.X))
            if ($x -ge 0 -and $x -le $sender.ClientSize.Width) { $eventArgs.Graphics.DrawLine([Drawing.Pens]::CornflowerBlue,$x,0,$x,22) }
        }
        Draw-TimelinePlayhead $s $eventArgs.Graphics
    })
    $timeline.Add_MouseDown({ param($sender,$eventArgs)
        if($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left){return}
        if(Start-TimelineCursorDrag $sender.Tag $eventArgs.X $eventArgs.Y){$sender.Capture=$true;return}
        $s=$sender.Tag; $range=Get-TimelineRange $s
        Request-QualitySeek $s ($s.Duration*($eventArgs.X-$range.X)/[Math]::Max(1.0,$range.Y-$range.X)) -FromTimeline
    })
    $timeline.Add_MouseUp({param($sender,$eventArgs) if($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left){Move-TimelineCursorDrag $sender.Tag $eventArgs.X;Complete-TimelineCursorDrag $sender.Tag}})
    $timeline.Add_MouseCaptureChanged({if(-not $this.Capture){Complete-TimelineCursorDrag $this.Tag}})
    $slider=New-Object MachiningMonitor.TimelineTrackBar
    $slider.AutoSize=$false; $slider.TickStyle='None'; $slider.Minimum=0; $slider.Maximum=100000
    $slider.SetBounds(4,46,($form.ClientSize.Width-8),20); $slider.Anchor='Top,Left,Right'
    $annotations.Controls.Add($slider); $state.Slider=$slider
    $slider.Add_MouseDown({ param($sender,$eventArgs) if($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left){return};$s=$sender.FindForm().Tag; $s.Dragging=$true; $s.TimelinePauseSnapshot=$s.Paused; Update-QualityActionAvailability $s; if ($s.Split) { Update-SplitExtractionAvailability $s } })
    $slider.Add_MouseUp({ param($sender,$eventArgs)
        if($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left){return}
        $s=$sender.FindForm().Tag; $s.Dragging=$false
        Request-QualitySeek $s ($s.Duration*$sender.Value/$sender.Maximum) -FromTimeline
    })
    $slider.Add_KeyUp({ param($sender,$eventArgs)
        if ($eventArgs.KeyCode -in @('Left','Right','Up','Down','PageUp','PageDown','Home','End')) {
            $s=$sender.FindForm().Tag; Request-QualitySeek $s ($s.Duration*$sender.Value/$sender.Maximum) -FromTimeline
        }
    })
    $hostPanel.Add_Resize({
        param($sender,$eventArgs)
        $s = $sender.FindForm().Tag
        Start-PlaybackResizeNotice $s
        if (-not $s.NativeMpv) { [MachiningMonitor.QualityClock]::Resize($s.Handle,$sender.ClientSize.Width,$sender.ClientSize.Height) }
        elseif ($s.Player) { [MachiningMonitor.AdaptiveMpvController]::ResizeEmbedded($sender.Handle,$s.Player.Id,$sender.ClientSize.Width,$sender.ClientSize.Height) }
    })
    $label = New-Object Windows.Forms.Label
    $label.SetBounds(12,67,300,22); $label.AutoEllipsis=$true; $annotations.Controls.Add($label); $state.Label = $label
    $absoluteLabel=New-Object Windows.Forms.Label
    $absoluteLabel.SetBounds(320,67,270,22); $annotations.Controls.Add($absoluteLabel); $state.AbsoluteTimeLabel=$absoluteLabel
    $totalLabel=New-Object Windows.Forms.Label
    $totalLabel.SetBounds(320,67,145,22); $annotations.Controls.Add($totalLabel); $state.TotalLabel=$totalLabel
    $currentQualityLabel=New-Object Windows.Forms.Label
    $currentQualityLabel.Location=New-Object Drawing.Point(540,69)
    $currentQualityLabel.Padding=New-Object Windows.Forms.Padding(3,0,3,0)
    $currentQualityLabel.AutoSize=$true
    $annotations.Controls.Add($currentQualityLabel); $state.CurrentQualityLabel=$currentQualityLabel
    $spindleLabel=New-Object Windows.Forms.Label; $spindleLabel.AutoSize=$true
    $annotations.Controls.Add($spindleLabel); $state.SpindleLabel=$spindleLabel
    $feedLabel=New-Object Windows.Forms.Label; $feedLabel.AutoSize=$true
    $annotations.Controls.Add($feedLabel); $state.FeedLabel=$feedLabel
    $annotations.Add_ClientSizeChanged({param($sender,$eventArgs) Update-PlaybackStatusLayout $sender.FindForm().Tag })
    $tooltip=New-Object MachiningMonitor.WrappingToolTip
    $state.Tooltip=$tooltip
    $form.Add_Disposed({ param($sender,$eventArgs) $sender.Tag.Tooltip.Dispose() })
    # Show the recording time under the pointer using the same geometry as seeking.
    $timeline.Add_MouseMove({ param($sender,$eventArgs)
        if($sender.Tag.TimelineCursorDrag){Move-TimelineCursorDrag $sender.Tag $eventArgs.X;return}
        $sender.Cursor=if($sender.Tag.Duration -gt 0 -and $eventArgs.Y -le 22 -and [Math]::Abs($eventArgs.X-(Get-TimelineIndicatorX $sender.Tag)) -le 8){[Windows.Forms.Cursors]::SizeWE}else{[Windows.Forms.Cursors]::Default}
        $s=$sender.Tag; $range=Get-TimelineRange $s
        $time=[Math]::Max(0.0,[Math]::Min($s.Duration,($s.Duration*($eventArgs.X-$range.X)/[Math]::Max(1.0,$range.Y-$range.X))))
        $entry=Get-RecordingContextAt $s.ContextEntries $time
        $text=(Format-AnnotationTime $time)+' | '+(Get-QualityText 'Context/program: ' 'Contexto/programa: ')+$entry.context.Work+' | '+$entry.context.Operation+' | '+$entry.context.Tool.Tool
        if ($s.Tooltip.GetToolTip($sender) -ne $text) { $s.Tooltip.SetToolTip($sender,$text) }
    })
    $timeline.Add_MouseLeave({ param($sender,$eventArgs)
        $sender.Cursor=[Windows.Forms.Cursors]::Default
        $s=$sender.Tag; $s.Tooltip.Hide($sender); $s.Tooltip.SetToolTip($sender,$null)
    })
    Initialize-EventListScrollHelper
    $list = New-Object MachiningMonitor.StableEventListView
    $list.Font=New-Object Drawing.Font('Segoe UI',10)
    $list.SetBounds(12,126,($form.ClientSize.Width - 24),86); $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $true
    $list.Anchor = 'Top,Bottom,Left,Right'
    $list.ShowItemToolTips=$false
    $list.Add_MouseMove({param($sender,$eventArgs)
        $s=$sender.FindForm().Tag; $hit=$sender.HitTest($eventArgs.Location); $text=''
        $text=Get-EventListCellTooltip $sender $hit.Item $hit.SubItem
        if ($s.ListHoverText -ne $text) {
            $s.Tooltip.Hide($sender); $s.ListHoverText=$text
            if ($text) { $s.Tooltip.Show($text,$sender,($eventArgs.X+14),($eventArgs.Y+20),15000) }
        }
    })
    $list.Add_MouseLeave({param($sender,$eventArgs) $s=$sender.FindForm().Tag; $s.Tooltip.Hide($sender); $s.ListHoverText='' })
    $list.HideSelection=$false
    [void]$list.Columns.Add((Get-QualityText 'Clock time' 'Hora'),90)
    [void]$list.Columns.Add((Get-QualityText 'Time' 'Tempo'),100)
    [void]$list.Columns.Add((Get-QualityText 'Duration' 'Duração'),110)
    [void]$list.Columns.Add((Get-QualityText 'Rating' 'Classificação'),140)
    [void]$list.Columns.Add((Get-QualityText 'Machine state' 'Estado da máquina'),170)
    [void]$list.Columns.Add((Get-QualityText 'Machine activity' 'Atividade da máquina'),180)
    [void]$list.Columns.Add((Get-QualityText 'Changes' 'Alterações'),300)
    [void]$list.Columns.Add((Get-QualityText 'Notes' 'Notas'),440)
    Initialize-EventColumnLayout $list 'playback'
    $annotations.Controls.Add($list); $state.List = $list
    Initialize-EventListContextMenu $state
    $buttons = @()
    foreach ($pair in @(@('Pause / Resume','Pausar / Retomar'), @('Annotate','Anotar'), @('Edit event','Editar evento'), @('Delete event','Eliminar evento'), @('Position at event','Posicionar no evento'))) {
        $button = New-Object Windows.Forms.Button; Register-ButtonActionTooltip $button
        $button.Text = Get-QualityText $pair[0] $pair[1]
        $width=100; if ($buttons.Count -eq 4) { $width=164 }
        $button.SetBounds((12 + $buttons.Count * 104),90,$width,30); $annotations.Controls.Add($button); $buttons += $button
    }
    $state.Buttons = $buttons
    $buttons[0].SetBounds(12,90,52,30)
    for ($i=1;$i -le 3;$i++) { $buttons[$i].SetBounds((220+($i-1)*76),90,72,30) }
    $buttons[1].Text=Get-QualityText 'Record event' 'Registar evento'; $buttons[1].SetBounds(220,90,104,30)
    $buttons[2].SetBounds(328,90,64,30); $buttons[3].SetBounds(396,90,64,30)
    $buttons[4].SetBounds(464,90,164,30)
    $positionButton=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $positionButton
    $positionButton.Text=Get-QualityText 'Position in time' 'Posicionar no tempo'
    $positionButton.SetBounds(68,90,156,30)
    $positionButton.Enabled=$false
    $annotations.Controls.Add($positionButton); $state.PositionButton=$positionButton
    $positionButton.Add_Click({ param($sender,$eventArgs) Show-QualityPositionDialog $sender.FindForm().Tag })
    $state.DiagnosticPath=Join-Path ([IO.Path]::GetTempPath()) ('ma-controls-'+[guid]::NewGuid().ToString('N')+'.log')
    Write-QualityDiagnostic $state 'panel-created'
    foreach ($control in $buttons) {
        $control.Add_MouseDown({ param($sender,$eventArgs)
            Write-QualityDiagnostic $sender.FindForm().Tag ('mouse-down: '+$sender.Text)
        })
        $control.Add_Click({ param($sender,$eventArgs)
            Write-QualityDiagnostic $sender.FindForm().Tag ('click: '+$sender.Text)
        })
    }
    $buttons[0].Font=New-Object Drawing.Font('Segoe UI Symbol',14,[Drawing.FontStyle]::Regular)
    $buttons[0].Text=[string][char]0x25B6
    $buttons[0].Add_Click({
        param($sender,$eventArgs)
        try { Switch-QualityPause $sender.FindForm().Tag } catch { Show-QualityError $_.Exception.Message }
    })
    $buttons[1].Add_Click({ param($sender,$eventArgs) Show-QualityEditor $sender.FindForm().Tag $false })
    $buttons[2].Add_Click({ param($sender,$eventArgs) Show-QualityEditor $sender.FindForm().Tag $true })
    $list.Add_ItemSelectionChanged({
        param($sender,$eventArgs)
        $s=$sender.FindForm().Tag
        Update-QualityActionAvailability $s
    })
    $buttons[4].Enabled=$false
    $buttons[4].Add_Click({
        param($sender,$eventArgs)
        $s=$sender.FindForm().Tag
        if ($s.List.SelectedItems.Count -gt 0) {
            Request-QualitySeek $s ([double]$s.List.SelectedItems[0].Tag.timestamp_seconds) -CenterTimeline
        }
    })
    $list.Add_DoubleClick({ param($sender,$eventArgs)
        $s=$sender.FindForm().Tag
        if($sender.SelectedItems.Count -eq 1 -and $sender.SelectedItems[0].Tag.RowKind -eq 'Context'){
            try{Edit-EventListContext $s}catch{Show-QualityError $_.Exception.Message}
        }else{Show-QualityEditor $s $true}
    })
    $buttons[3].Add_Click({
        param($sender,$eventArgs)
        try { Remove-SelectedQualityEvents $sender.FindForm().Tag } catch { Show-QualityError $_.Exception.Message }
    })
    Update-QualityList $state
    Set-PlaybackControlFontLayout $state
    $form.ResizeSurface=$state.VideoHost
    Start-PlaybackResizeNotice $state
    $state.ResizeNoticeActive=$false;$state.ResizeNoticeLabel.Visible=$false
    $form.ResizeOverlay=$state.ResizeNoticeLabel
    $form.Add_ResizeStarting({param($sender,$eventArgs) Start-PlaybackResizeNotice $sender.Tag})
    $form.Add_Load({param($sender,$eventArgs) Initialize-PlaybackStartupLayout $sender})
    if($form.GetType().GetEvent('DpiChanged')){
        $form.Add_DpiChanged({param($sender,$eventArgs) $sender.BeginInvoke([Action[object]]{param($window) Set-MonitorWindowHeight $window $window.Tag},[object[]]@($sender)) | Out-Null})
    }
    if(-not $DeferShow){Initialize-PlaybackStartupLayout $form;$form.Show()}
    return $form
}
function Initialize-PlaybackStartupLayout {
    param($Form)
    $s=$Form.Tag
    $Form.PerformAutoScale();$Form.PerformLayout()
    Set-PlaybackControlFontLayout $s
    if($s.Split){Set-SplitClearButtonLayout $s}
    $minimumWidth=[Math]::Max($Form.Width,$Form.MinimumSize.Width)
    $Form.Width=$minimumWidth
    $s.MinimumWindowSize=New-Object Drawing.Size($minimumWidth,$s.MinimumWindowSize.Height)
    $Form.MinimumSize=New-Object Drawing.Size($minimumWidth,$Form.MinimumSize.Height)
    Set-MonitorWindowHeight $Form $s
    $Form.PerformLayout()
    if(-not $Form.Visible){
        $s.ResizeNoticeActive=$false
        if($s.ResizeNoticeLabel){$s.ResizeNoticeLabel.Visible=$false}
        $Form.RevealResizeContent()
        Update-VisualizationGrips $s.Viewport
    }
}
# Ask the operator to confirm removal of the selected event records.
function Confirm-QualityEventRemoval {
    param($Owner,[int]$Count)
    $text=(Get-QualityText 'Delete selected events: ' 'Eliminar os eventos selecionados: ')+$Count+'?'
    if(-not (([Windows.Forms.MessageBox]::Show($Owner,$text,(Get-QualityText 'Delete events' 'Eliminar eventos'),'YesNo','Question','Button2') -eq 'Yes'))){return $false}
    return Confirm-DeletionAuthorization $Owner 'Eliminar eventos'
}
# Remove selected annotations and refresh the saved timeline and list.
function Remove-SelectedQualityEvents {
    param($State)
    $ids=@($State.List.SelectedItems | Where-Object {$_.Tag.RowKind -ne 'Context'} | ForEach-Object { $_.Tag.id })
    if (-not $ids.Count -or -not (Confirm-QualityEventRemoval $State.List.FindForm() $ids.Count)) { return }
    $next=@($State.Items | Where-Object { $_.id -notin $ids })
    $State.Items=@(Save-QualityAnnotations $State.Path $next -PassThru)
    Update-QualityList $State; Update-QualityActionAvailability $State
}
# Display a localized error message in the graphical interface.
function Show-QualityError {
    param([string]$Message)
    [void][Windows.Forms.MessageBox]::Show($Message, (Get-QualityText 'Rating annotation error' 'Erro na anotação de classificação'), 'OK', 'Error')
}
# Toggle playback pause and synchronize the controls with the playback session.
function Switch-QualityPause {
    param($State,[switch]$ExtractionPreview)
    $broadcast=Get-ApplicationBroadcast
    if(-not $ExtractionPreview -and $broadcast){Write-QualityDiagnostic $State ('pause-toggle target='+(-not $State.Paused)+' analyzerUnavailable='+$broadcast.AnalysisUnavailable+' analyzerEnabled='+$broadcast.Config.AnalyzerEnabled)}
    if(-not $ExtractionPreview -and $broadcast -and ($broadcast.AnalysisHolding -or $broadcast.AnalysisArmed)){
        Stop-AnalyzerPlayback;$broadcast.AnalysisArmed=$false;$broadcast.AnalysisHolding=$false;$State.Paused=$true;Update-QualityLabel $State;return
    }
    if(-not $ExtractionPreview -and $State.Split -and $State.Split.Preview){
        if(-not $State.Paused -or $State.Split.Preview.Starting){return}
        # Starting the main player from a paused preview leaves preview mode.
        $State.Split.Preview=$null
    }
    Write-QualityDiagnostic $State 'pause-command'
    if ($State.Ended) {
        Request-QualitySeek $State 0
        $State.SeekPaused=$false
        return
    }
    $targetPaused = -not $State.Paused
    if(-not $targetPaused -and $broadcast -and $broadcast.Config.AnalyzerEnabled -and -not $broadcast.AnalysisUnavailable){
        $broadcast.AnalysisArmed=$true;$broadcast.AnalysisHolding=$true
        Update-QualityLabel $State
        return
    }
    if ($State.NativeMpv) {
        if (-not $State.Clock.SetPaused($targetPaused,2500)) { throw (Get-QualityText 'Player pause command timed out.' 'O leitor não confirmou o comando de pausa.') }
        $State.Paused=$targetPaused; $State.PauseToConfirm=$null; Update-QualityLabel $State
        Update-AnalyzerPlayback $State
        return
    }
    [MachiningMonitor.QualityClock]::Pause($State.Handle)
    if (-not $State.Clock.WaitForPlaybackState($targetPaused, 2500, $State.Handle)) {
        throw (Get-QualityText 'The player did not confirm pause/resume. The annotation was not opened. Close and reopen playback if controls remain unresponsive.' 'O leitor não confirmou a pausa/retoma. A anotação não foi aberta. Feche e reabra a reprodução se os controlos continuarem sem responder.')
    }
    $State.Paused = $targetPaused
    Update-QualityLabel $State
}
# Persist event-column widths and ordering for later sessions.
function Save-EventColumnLayout {
    param($List)
    $layout=$List.EventColumnLayout
    if($null -eq $layout -or $null -eq $layout.Pending){return}
    try{
        $path=Join-Path $PSScriptRoot ('event_columns_'+$layout.Kind+'.json')
        [IO.File]::WriteAllText($path,($layout.Pending|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
        $layout.Pending=$null
    }catch{Write-Warning $_.Exception.Message}
}
# Restore the saved column layout or apply the defaults for this list type.
function Initialize-EventColumnLayout {
    param($List,[ValidateSet('playback','recording')][string]$Kind)
    if($List.Columns.Count -notin @(7,8) -or $null -ne $List.EventColumnLayout){return}
    Initialize-EventListScrollHelper
    $layout=@{FitQueued=$false;Kind=$Kind;Fitting=$false;Restoring=$true;ObservationsMinimum=80;Pending=$null;Timer=$null}
    $List|Add-Member NoteProperty EventColumnLayout $layout
    # Size initial columns for the actual list font, including header padding.
    $List.Columns[3].Width=[Math]::Max(140,([Windows.Forms.TextRenderer]::MeasureText('0 - Sem classificação',$List.Font).Width+14))
    $List.Columns[4].Width=[Math]::Max(150,([Windows.Forms.TextRenderer]::MeasureText('Medição de ferramenta',$List.Font).Width+14))
    $path=Join-Path $PSScriptRoot ('event_columns_'+$Kind+'.json')
    if(Test-Path -LiteralPath $path){
        try{
            $saved=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
            $widths=@($saved.Widths)
            if($Kind -eq 'playback' -and $saved.Version -eq 1){
                if($widths.Count -eq 8){$widths=@($widths[0],$widths[1],$widths[6],$widths[3],$widths[4],$widths[5],$widths[7])}
                elseif($widths.Count -eq 7){$widths[2]=110}
            }
            # Older layouts lack the independent activity column; use the current defaults when upgrading.
            $valid=$saved.Version -eq 3 -and $widths.Count -eq $List.Columns.Count -and $saved.ObservationsMinimum -ge 80 -and $saved.ObservationsMinimum -le 4000
            foreach($width in $widths){if($width -isnot [ValueType] -or $width -lt 20 -or $width -gt 4000){$valid=$false}}
            if($valid){
                for($i=0;$i -lt ($List.Columns.Count-1);$i++){$List.Columns[$i].Width=[int]$widths[$i]}
                $layout.ObservationsMinimum=[int]$saved.ObservationsMinimum
            }
        }catch{Write-Warning $_.Exception.Message}
    }
    $layout.Restoring=$false
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=250;$timer.Tag=$List;$layout.Timer=$timer
    $timer.Add_Tick({$this.Stop();Save-EventColumnLayout $this.Tag})
    $List.Add_ColumnWidthChanging({
        param($sender,$eventArgs)
        $layout=$sender.EventColumnLayout
        if(-not $layout.Fitting -and -not $layout.Restoring -and $eventArgs.ColumnIndex -eq ($sender.Columns.Count-1)){
            $layout.ObservationsMinimum=[Math]::Max(80,$eventArgs.NewWidth)
        }
    })
    $List.Add_ColumnWidthChanged({
        param($sender,$eventArgs)
        $layout=$sender.EventColumnLayout
        if($layout.Fitting -or $layout.Restoring){return}
        Fit-ObservationsColumn $sender
        $layout.Pending=[pscustomobject]@{Version=3;Widths=@($sender.Columns|ForEach-Object {$_.Width});ObservationsMinimum=$layout.ObservationsMinimum}
        $layout.Timer.Stop();$layout.Timer.Start()
    })
    $List.Add_ClientSizeChanged({param($sender,$eventArgs) Fit-ObservationsColumn $sender;Request-EventColumnFit $sender})
    $List.Add_HandleCreated({Request-EventColumnFit $this})
    $List.Add_VisibleChanged({if($this.Visible){Request-EventColumnFit $this}})
    $List.Add_Disposed({
        Save-EventColumnLayout $this
        $this.EventColumnLayout.Timer.Stop();$this.EventColumnLayout.Timer.Dispose()
    })
    Fit-ObservationsColumn $List
    Request-EventColumnFit $List
}
# Fit the observations column into the remaining list width.
function Fit-ObservationsColumn {
    param($List,[switch]$RefreshScroll)
    if ($List.Columns.Count -notin @(6,7,8)) { return }
    $layout=$List.EventColumnLayout
    if($null -ne $layout -and $layout.Fitting){return}
    if($null -ne $layout){$layout.Fitting=$true}
    try{
    $last=$List.Columns.Count-1
    $fixedWidth=0
    for ($i=0; $i -lt $last; $i++) { $fixedWidth += $List.Columns[$i].Width }
    $available=$List.ClientSize.Width-$fixedWidth-2
    $minimum=80;if($null -ne $layout){$minimum=$layout.ObservationsMinimum}
    $width=[Math]::Max($minimum,$available)
    if ($List.Columns[$last].Width -ne $width) { $List.Columns[$last].Width=$width }
    if($RefreshScroll -and $List.IsHandleCreated){[MachiningMonitor.EventListScroll]::Refresh($List,$width)}
    }finally{if($null -ne $layout){$layout.Fitting=$false}}
}
# Format changed numeric values for the event list.
function Format-EventChangeNumber {
    param($Value)
    if($null -eq $Value){return '-'}
    return ([double]$Value).ToString('0.########',[Globalization.CultureInfo]::CurrentCulture)
}
# Describe the machining and context changes relative to the preceding event.
function Get-EventChangesText {
    param($Item,$PreviousParameters,$PreviousEvent,$MachineStates=$null)
    # Atomic events display their occurrence and assigned value without inherited snapshot changes.
    if($Item.occurrence){return Format-EventOccurrenceValue $Item}
    $changes=@()
    foreach($row in @(@('SpindleSpeed','ProgrammedRpm','AdjustedRpm','Spindle','Rotação','rpm'),@('FeedRate','ProgrammedMmPerMin','AdjustedMmPerMin','Feed','Avanço','mm/min'))){
        $name=$row[0]
        foreach($key in @($Item.parameter_changes.$name)){
            if($null -eq $key){continue}
            if($Item.parameters.$name.$key -eq $PreviousParameters.$name.$key){continue}
            $label=Get-QualityText $row[3] $row[4];$unit=$row[5]
            if($key -eq 'AdjustmentPercent'){$label+=' (%)';$unit='%'}
            elseif($key -eq $row[1]){$label+=Get-QualityText ' programmed' ' programado'}
            else{$label+=Get-QualityText ' adjusted' ' ajustado'}
            $changes+=($label+': '+(Format-EventChangeNumber $PreviousParameters.$name.$key)+' → '+(Format-EventChangeNumber $Item.parameters.$name.$key)+' '+$unit)
        }
    }
    $previousQuality=0;if($null -ne $PreviousEvent){$previousQuality=$PreviousEvent.quality}
    if($Item.quality -ne $previousQuality){$changes+=((Get-QualityText 'Rating' 'Classificação')+': '+$previousQuality+' → '+$Item.quality)}
    if($Item.machine_state -and ($null -eq $PreviousEvent -or $Item.machine_state -ne $PreviousEvent.machine_state)){
        if($null -eq $MachineStates){$MachineStates=Get-MachineStates}
        $stateText=[string]$Item.machine_state_label
        $localized=@($MachineStates.states | Where-Object {$_.id -eq $Item.machine_state} | Select-PlaybackReference -First)
        if($localized.Count){$stateText=$localized[0].label}
        elseif(-not $stateText){$stateText=[string]$Item.machine_state}
        $changes+=((Get-QualityText 'State' 'Estado')+': '+$stateText)
    }
    if($Item.machine_activity -and ($null -eq $PreviousEvent -or $Item.machine_activity -ne $PreviousEvent.machine_activity)){
        $activities=Get-MachineActivities;$activityText=[string]$Item.machine_activity_label
        $localized=@($activities.activities|Where-Object {$_.id -eq $Item.machine_activity}|Select-PlaybackReference -First)
        if($localized.Count){$activityText=$localized[0].label}elseif(-not $activityText){$activityText=[string]$Item.machine_activity}
        $changes+=((Get-QualityText 'Activity' 'Atividade')+': '+$activityText)
    }
    $occurrence=@((Get-EventOccurrenceOptions) | Where-Object {$_.id -eq [string]$Item.occurrence} | ForEach-Object {$_.label})
    if($occurrence.Count){$changes+=($occurrence[0])}
    return $changes -join '; '
}
# Prepare multiline observations for compact display in a list row.
function Get-EventListCellTooltip {
    param($List,$Item,$SubItem)
    if(-not $Item){return ''}
    $help=Get-QualityText 'Double-click to edit; right-click for options.' 'Duplo clique para editar; botão direito do rato para opções.'
    if(-not $SubItem){return $help}
    $index=$Item.SubItems.IndexOf($SubItem)
    if($index -lt 0 -or $index -ge $List.Columns.Count){return $help}
    $value=[string]$SubItem.Text
    # Preserve the original line breaks in notes, rather than the list's compact form.
    if($index -eq 7){
        if($Item.Tag.RowKind -eq 'Context'){$value=[string]$Item.Tag.Entry.context.Notes}
        else{$value=[string]$Item.Tag.observations}
    }
    $text=[string]$List.Columns[$index].Text+': '+$value
    $text+=[Environment]::NewLine+[Environment]::NewLine+$help
    return $text
}
function Format-AnnotationObservationsForList {
    param([string]$Text)
    $result=''; $previous=''
    $changePattern='^(?:Rotação|Avanço|Classificação|Qualidade|Tempo|Estado)\s*(?:—[^:]*)?:.*(?:→|->)'
    foreach ($line in @($Text -split '\r\n|\r|\n')) {
        $line=$line.Trim()
        if (-not $line) { continue }
        if ($result.Length) {
            if ($previous -match $changePattern -and $line -match $changePattern -and -not $result.EndsWith(';')) { $result+='; ' }
            else { $result+=' ' }
        }
        $result+=$line; $previous=$line
    }
    return $result
}
# Collapse is a presentation choice for this management window only.
function Set-EventListContextExpansion {
    param($State,[ValidateSet('Expand','Collapse','ExpandAll','CollapseAll')][string]$Action,[string]$ContextId)
    if($null -eq $State.CollapsedEventContexts){$State.CollapsedEventContexts=@{}}
    $entries=@($State.ContextEntries)
    if($Action -in @('Expand','Collapse')){$entries=@($entries | Where-Object {$_.id -eq $ContextId})}
    foreach($entry in $entries){
        if($Action -in @('Collapse','CollapseAll')){$State.CollapsedEventContexts[[string]$entry.id]=$true}
        else{[void]$State.CollapsedEventContexts.Remove([string]$entry.id)}
    }
    Update-QualityList $State
    Update-QualityActionAvailability $State
    foreach($row in $State.List.Items){
        if($row.Tag.RowKind -eq 'Context' -and $row.Tag.Entry.id -eq $ContextId){$row.Selected=$true;$row.Focused=$true;$row.EnsureVisible();break}
    }
}
function Initialize-EventListContextMenu {
    param($State)
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $menu.ShowItemToolTips=$true
    $menu.Tag=@{State=$State;ContextId=$null}
    foreach($spec in @(@('EditContext','Edit','Editar'),@('DeleteContext','Delete','Eliminar'),@('SeekContext','Position at context start','Posicionar no início do contexto'),@('Expand','Expand','Expandir'),@('Collapse','Collapse','Colapsar'),@('ExpandAll','Expand all','Expandir tudo'),@('CollapseAll','Collapse all','Colapsar tudo'))){
        $item=New-Object Windows.Forms.ToolStripMenuItem((Get-QualityText $spec[1] $spec[2]));$item.Name=$spec[0]
        $item.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap((Get-EventMenuActionTooltip $item.Name))
        [void]$menu.Items.Add($item)
        $item.Add_Click({param($sender,$eventArgs)
            $target=$sender.Owner.Tag
            if($sender.Name -in @('EditContext','DeleteContext')){
                try{
                    if($sender.Name -eq 'EditContext'){Edit-EventListContext $target.State}
                    else{Remove-EventListContext $target.State $target.ContextId}
                }catch{Show-QualityError $_.Exception.Message}
                return
            }
            if($sender.Name -eq 'SeekContext'){
                $s=$target.State
                if(-not $s.Clock.Ready -or $s.Seeking -or $s.Dragging -or $null -ne $s.PendingSeek){return}
                $entry=@($s.ContextEntries | Where-Object {$_.id -eq $target.ContextId})
                if($entry.Count -eq 1){Request-QualitySeek $s ([double]$entry[0].timestamp_seconds) -CenterTimeline}
                return
            }
            Set-EventListContextExpansion $target.State $sender.Name $target.ContextId
        })
    }
    $menu.Add_Opening({param($sender,$eventArgs)
        $s=$sender.Tag.State;$id=$sender.Tag.ContextId
        foreach($option in $sender.Items){$option.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap((Get-EventMenuActionTooltip $option.Name))}
        $sender.Items['SeekContext'].Enabled=$s.Clock.Ready -and -not $s.Seeking -and -not $s.Dragging -and $null -eq $s.PendingSeek
        $sender.Items['EditContext'].Enabled=$sender.Items['SeekContext'].Enabled
        $entry=@($s.ContextEntries | Where-Object {$_.id -eq $id})
        $sender.Items['DeleteContext'].Enabled=$sender.Items['SeekContext'].Enabled -and $entry.Count -eq 1 -and $entry[0].timestamp_seconds -gt 0
        $collapsed=$null -ne $s.CollapsedEventContexts -and $s.CollapsedEventContexts.ContainsKey($id)
        $sender.Items['Expand'].Enabled=$collapsed
        $sender.Items['Collapse'].Enabled=-not $collapsed
        $count=@($s.ContextEntries | Where-Object {$null -ne $s.CollapsedEventContexts -and $s.CollapsedEventContexts.ContainsKey([string]$_.id)}).Count
        $sender.Items['ExpandAll'].Enabled=$count -gt 0
        $sender.Items['CollapseAll'].Enabled=$count -lt @($s.ContextEntries).Count
    })
    $State.List | Add-Member NoteProperty ContextRowsMenu $menu
    $eventMenu=New-Object Windows.Forms.ContextMenuStrip;$eventMenu.Tag=$State
    $eventMenu.ShowItemToolTips=$true
    foreach($spec in @(@('EditEvent','Edit','Editar',2),@('DeleteEvent','Delete','Eliminar',3),@('SeekEvent','Position at event','Posicionar no evento',4))){
        $item=New-Object Windows.Forms.ToolStripMenuItem((Get-QualityText $spec[1] $spec[2]));$item.Name=$spec[0];$item.Tag=$spec[3]
        $item.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap((Get-EventMenuActionTooltip $item.Name))
        [void]$eventMenu.Items.Add($item)
        $item.Add_Click({param($sender,$eventArgs) $sender.Owner.Tag.Buttons[[int]$sender.Tag].PerformClick()})
    }
    $eventMenu.Add_Opening({param($sender,$eventArgs)
        Update-QualityActionAvailability $sender.Tag
        foreach($item in $sender.Items){$item.Enabled=$sender.Tag.Buttons[[int]$item.Tag].Enabled;$item.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap((Get-ButtonActionDescription $sender.Tag.Buttons[[int]$item.Tag]))}
    })
    $State.List | Add-Member NoteProperty EventRowsMenu $eventMenu
    $State.List.Add_MouseUp({param($sender,$eventArgs)
        if($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Right){return}
        $row=$sender.GetItemAt($eventArgs.X,$eventArgs.Y)
        if(-not $row){return}
        if($row.Tag.RowKind -ne 'Context'){
            if(-not $row.Selected){foreach($selected in @($sender.SelectedItems)){$selected.Selected=$false}}
            $row.Selected=$true;$row.Focused=$true
            $sender.EventRowsMenu.Show($sender,$eventArgs.Location)
            return
        }
        foreach($selected in @($sender.SelectedItems)){$selected.Selected=$false}
        $row.Selected=$true;$row.Focused=$true
        $sender.ContextRowsMenu.Tag.ContextId=[string]$row.Tag.Entry.id
        $sender.ContextRowsMenu.Show($sender,$eventArgs.Location)
    })
    $State.List.Add_Disposed({param($sender,$eventArgs) $sender.ContextRowsMenu.Dispose();$sender.EventRowsMenu.Dispose()})
}
function Get-EventMenuActionTooltip {
    param([string]$Action)
    $buttonText=switch($Action){
        'EditContext' {'Edit'}
        'DeleteContext' {'Delete'}
        'SeekContext' {'Position at context'}
        'EditEvent' {'Edit event'}
        'DeleteEvent' {'Delete event'}
        'SeekEvent' {'Position at event'}
    }
    if($buttonText){return (Get-ButtonActionDescription ([pscustomobject]@{Text=$buttonText;Name='';AccessibleName='';AccessibleDescription=''}))}
    switch($Action){
        'Expand' {return (Get-QualityText 'Show the events in the selected context/program.' 'Mostra os eventos do contexto/programa selecionado.')}
        'Collapse' {return (Get-QualityText 'Hide the events in the selected context/program.' 'Oculta os eventos do contexto/programa selecionado.')}
        'ExpandAll' {return (Get-QualityText 'Show the events in all contexts/programs.' 'Mostra os eventos de todos os contextos/programas.')}
        'CollapseAll' {return (Get-QualityText 'Hide the events in all contexts/programs.' 'Oculta os eventos de todos os contextos/programas.')}
    }
}
function Remove-EventListContext {
    param($State,[string]$ContextId)
    if(-not $State.Clock.Ready -or $State.Seeking -or $State.Dragging -or $null -ne $State.PendingSeek){return}
    $folder=Split-Path $State.Path -Parent;$hash=Get-RecordingContextsHash $folder
    $entries=@(Read-RecordingContexts $folder)
    $entry=@($entries | Where-Object {$_.id -eq $ContextId})
    if($entry.Count -ne 1 -or $entry[0].timestamp_seconds -le 0){return}
    if(Confirm-PlaybackContextRemoval $State.List.FindForm() 1){
        Save-PlaybackContexts $State @($entries | Where-Object {$_.id -ne $ContextId}) $hash
    }
}
# Context separators are view rows, never event records or persisted annotations.
function Add-EventListContextRow {
    param($State,$Entry,[double]$End,[string[]]$SelectedIds)
    $hour='-'
    if($null -ne $State.RecordingStart){$hour=$State.RecordingStart.AddSeconds([double]$Entry.timestamp_seconds).ToString('HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)}
    $program=([string]$Entry.context.Work -replace '[\r\n\t]+',' ').Trim()
    $operation=([string]$Entry.context.Operation -replace '[\r\n\t]+',' ').Trim()
    $text=$program+' | '+$operation
    $row=New-Object Windows.Forms.ListViewItem($hour)
    foreach($value in @((Format-AnnotationTime $Entry.timestamp_seconds),(Format-AnnotationTime ([Math]::Max(0.0,$End-[double]$Entry.timestamp_seconds))),'',(Get-QualityText 'Context/program' 'Contexto/programa'),'',$text,(Format-AnnotationObservationsForList $Entry.context.Notes))){[void]$row.SubItems.Add([string]$value)}
    $row.Tag=[pscustomobject]@{RowKind='Context';id=('context:'+$Entry.id);timestamp_seconds=[double]$Entry.timestamp_seconds;Entry=$Entry}
    $collapsed=$null -ne $State.CollapsedEventContexts -and $State.CollapsedEventContexts.ContainsKey([string]$Entry.id)
    $symbol=if($collapsed){[string][char]0x25B6}else{[string][char]0x25BC}
    $row.SubItems[4].Text=$symbol+' '+$row.SubItems[4].Text
    $row.BackColor=[Drawing.Color]::Lavender;$row.ForeColor=[Drawing.Color]::Purple;$row.ImageIndex=2
    $row.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap(($text+[Environment]::NewLine+(Get-QualityText 'Double-click to edit context/program.' 'Duplo clique para editar o contexto/programa.')))
    [void]$State.List.Items.Add($row)
    if($row.Tag.id -in $SelectedIds){$row.Selected=$true}
}
function Edit-EventListContext {
    param($State)
    if(-not $State.Clock.Ready -or $State.Seeking -or $State.Dragging -or $null -ne $State.PendingSeek){return}
    if($State.List.SelectedItems.Count -ne 1){return}
    $tag=$State.List.SelectedItems[0].Tag
    if($tag.RowKind -ne 'Context'){return}
    $entry=@(Read-RecordingContexts (Split-Path $State.Path -Parent) | Where-Object {$_.id -eq $tag.Entry.id})
    if($entry.Count -ne 1){throw (Get-QualityText 'Context/program changed. Reopen the contexts/programs list.' 'O contexto/programa foi alterado. Volte a abrir a lista de contextos/programas.')}
    if(-not $State.Paused){Switch-QualityPause $State}
    Show-PlaybackContextEditor $State $entry[0]
    foreach($row in $State.List.Items){if($row.Tag.id -eq $tag.id){$row.Selected=$true;$row.Focused=$true;$row.EnsureVisible();break}}
}
# Reconstruct independent controller state and physical activity at each event instant.
function Get-EventStatusProjection {
    param([AllowEmptyCollection()][object[]]$Items)
    $result=@{};$state='unknown';$activity='unknown'
    $stateIds=@('unknown','idle','running','paused','stopped','alarm')
    $activityIds=@('unknown','idle','warm_up','machining','tool_change','tool_measurement')
    foreach($group in @($Items|Sort-Object timestamp_seconds,created_at_utc,id|Group-Object timestamp_seconds)){
        # Apply all explicit changes at a shared timestamp before displaying events at that instant.
        foreach($item in $group.Group){
            if($item.occurrence -eq 'MachineStateChanged'){
                $raw=([string]$item.value).ToLowerInvariant();$numeric=0
                if([int]::TryParse($raw,[ref]$numeric) -and $numeric -ge 0 -and $numeric -lt $stateIds.Count){$raw=$stateIds[$numeric]}
                if($raw -in $stateIds){$state=$raw}
            }elseif($item.occurrence -eq 'MachineActivityChanged'){
                $raw=([string]$item.value).ToLowerInvariant();$numeric=0
                if([int]::TryParse($raw,[ref]$numeric) -and $numeric -ge 0 -and $numeric -lt $activityIds.Count){$raw=$activityIds[$numeric]}
                $raw=switch($raw){'warmup' {'warm_up'};'toolchange' {'tool_change'};'toolmeasurement' {'tool_measurement'};default {$raw}}
                if($raw -in $activityIds){$activity=$raw}
            }elseif(-not $item.occurrence){
                # Retain known legacy snapshots without treating Running as proof of machining activity.
                if($item.machine_state -in $stateIds){$state=[string]$item.machine_state}
                if($item.machine_activity -in $activityIds){$activity=[string]$item.machine_activity}
            }
        }
        foreach($item in $group.Group){$result[[string]$item.id]=[pscustomobject]@{State=$state;Activity=$activity}}
    }
    return $result
}

# Rebuild event rows, including effective values, colors and change descriptions.
function Update-QualityList {
    param($State)
    $qualitySegments=@(Get-QualitySegments $State)
    $statusAtEvent=Get-EventStatusProjection @($State.Items)
    $activityChoices=@((Get-MachineActivities).activities)
    $selectedIds=@($State.List.SelectedItems | ForEach-Object {$_.Tag.id})
    $machineStates=Get-MachineStates
    $previousParameters=Get-EventParameterBaseline $State.Path
    $contextIndex=0;$contextOrder=@($State.ContextEntries | Sort-Object timestamp_seconds)
    $contextRowIndex=0
    if($null -eq $State.CollapsedEventContexts){$State.CollapsedEventContexts=@{}}
    if($contextOrder.Count){Initialize-CurrentEventMarker $State}
    $previousEvent=[pscustomobject]@{quality=0;machine_state=$machineStates.default}
    $State.RefreshingList=$true
    $State.List.BeginUpdate()
    try {
    $State.List.Items.Clear()
    $orderedEvents=@($State.Items | Sort-Object timestamp_seconds, created_at_utc, id)
    for($eventIndex=0;$eventIndex -lt $orderedEvents.Count;$eventIndex++) {
        $annotation=$orderedEvents[$eventIndex]
        while($contextRowIndex -lt $contextOrder.Count -and $contextOrder[$contextRowIndex].timestamp_seconds -le $annotation.timestamp_seconds){
            $contextEnd=[double]$State.Duration
            if($contextRowIndex+1 -lt $contextOrder.Count){$contextEnd=[Math]::Min($contextEnd,[double]$contextOrder[$contextRowIndex+1].timestamp_seconds)}
            Add-EventListContextRow $State $contextOrder[$contextRowIndex] $contextEnd $selectedIds
            $contextRowIndex++
        }
        $eventEnd=[double]$State.Duration
        if($eventIndex+1 -lt $orderedEvents.Count){$eventEnd=[Math]::Min($eventEnd,[double]$orderedEvents[$eventIndex+1].timestamp_seconds)}
        $eventDuration=[Math]::Max(0.0,$eventEnd-[double]$annotation.timestamp_seconds)
        while($contextIndex -lt $contextOrder.Count -and $contextOrder[$contextIndex].timestamp_seconds -le $annotation.timestamp_seconds){
            $previousParameters=$contextOrder[$contextIndex].context.Parameters;$contextIndex++
        }
        $hour='-'; $fullTime=''
        if ($null -ne $State.RecordingStart) {
            $wallTime=$State.RecordingStart.AddSeconds([double]$annotation.timestamp_seconds)
            $hour=$wallTime.ToString('HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
            $fullTime=$wallTime.ToString('yyyy-MM-dd HH:mm:ss.fff zzz',[Globalization.CultureInfo]::InvariantCulture)
        }
        $row = New-Object Windows.Forms.ListViewItem($hour)
        $intervalQuality=Get-IntervalQuality $qualitySegments ([double]$annotation.timestamp_seconds)
        $meaning=(Get-QualityDisplay $intervalQuality) + ': ' + (Get-QualityMeaning $intervalQuality)
        $row.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap(($meaning))
        if ($fullTime) { $row.ToolTipText=[MachiningMonitor.WrappingToolTip]::Wrap(($fullTime + [Environment]::NewLine + $meaning)) }
        [void]$row.SubItems.Add((Format-AnnotationTime $annotation.timestamp_seconds))
        [void]$row.SubItems.Add((Format-AnnotationTime $eventDuration))
        [void]$row.SubItems.Add((Get-QualityDisplay $intervalQuality))
        $stateLabel='-'
        $status=$statusAtEvent[[string]$annotation.id]
        $match=@($machineStates.states | Where-Object { $_.id -eq $status.State })
        if ($match.Count) { $stateLabel=$match[0].label } else {$stateLabel=Get-QualityText 'Unknown' 'Desconhecido'}
        $activityMatch=@($activityChoices|Where-Object {$_.id -eq $status.Activity})
        $activityLabel=if($activityMatch.Count){$activityMatch[0].label}else{Get-QualityText 'Unknown' 'Desconhecido'}
        $changes=Get-EventChangesText $annotation $previousParameters $previousEvent $machineStates
        [void]$row.SubItems.Add($stateLabel); [void]$row.SubItems.Add($activityLabel); [void]$row.SubItems.Add($changes); [void]$row.SubItems.Add((Format-AnnotationObservationsForList $annotation.observations))
        if($changes){$row.ToolTipText+=[MachiningMonitor.WrappingToolTip]::Wrap(([Environment]::NewLine+$changes))}
        $row.Tag = $annotation
        $collapsed=$contextRowIndex -gt 0 -and $State.CollapsedEventContexts.ContainsKey([string]$contextOrder[$contextRowIndex-1].id)
        if(-not $collapsed){
            [void]$State.List.Items.Add($row)
            if($annotation.id -in $selectedIds){$row.Selected=$true}
        }elseif($annotation.id -in $selectedIds){
            $headerId='context:'+$contextOrder[$contextRowIndex-1].id
            foreach($header in $State.List.Items){if($header.Tag.id -eq $headerId){$header.Selected=$true;break}}
        }
        if($annotation.parameters){$previousParameters=$annotation.parameters}
        $previousEvent=$annotation
    }
    while($contextRowIndex -lt $contextOrder.Count){
        $contextEnd=[double]$State.Duration
        if($contextRowIndex+1 -lt $contextOrder.Count){$contextEnd=[Math]::Min($contextEnd,[double]$contextOrder[$contextRowIndex+1].timestamp_seconds)}
        Add-EventListContextRow $State $contextOrder[$contextRowIndex] $contextEnd $selectedIds
        $contextRowIndex++
    }
    } finally { $State.List.EndUpdate(); $State.RefreshingList=$false }
    if($State.EventListPinnedId -and $State.EventListPinnedId -notin @($State.Items | ForEach-Object {$_.id})){$State.EventListPinnedId=$null}
    if ($null -ne $State.Timeline) { $State.Timeline.Invalidate() }
}
# Read the current playback position from the active clock/session.
function Get-QualityPosition {
    param($State)
    if ($State.Ended) { return [double]$State.Duration }
    return ([double]$State.BaseSeconds + $State.Clock.Seconds)
}
# Highlight the annotation corresponding to the current playback time.
# Native item images keep the marker independent from timestamps and selection colors.
function Initialize-CurrentEventMarker {
    param($State)
    if($State.EventMarkerImages){return}
    $images=New-Object Windows.Forms.ImageList;$images.ImageSize=New-Object Drawing.Size(16,16);$images.ColorDepth='Depth32Bit'
    $marker=New-Object Drawing.Bitmap(16,16);$blank=New-Object Drawing.Bitmap(16,16)
    $contextMarker=New-Object Drawing.Bitmap(16,16)
    $contextGraphics=[Drawing.Graphics]::FromImage($contextMarker)
    try{
        $contextGraphics.Clear([Drawing.Color]::Transparent)
        $contextGraphics.FillRectangle([Drawing.Brushes]::Purple,5,2,5,12)
    }finally{$contextGraphics.Dispose()}
    $graphics=[Drawing.Graphics]::FromImage($marker)
    try{
        $graphics.Clear([Drawing.Color]::Transparent)
        $points=[Drawing.Point[]]@((New-Object Drawing.Point(4,2)),(New-Object Drawing.Point(12,8)),(New-Object Drawing.Point(4,14)))
        $graphics.FillPolygon([Drawing.Brushes]::DarkOrange,$points)
        $graphics.DrawPolygon([Drawing.Pens]::DarkSlateGray,$points)
        [void]$images.Images.Add($marker);[void]$images.Images.Add($blank);[void]$images.Images.Add($contextMarker)
        # Materialize native images before releasing the source bitmaps.
        $null=$images.Handle
    }finally{$graphics.Dispose();$marker.Dispose();$blank.Dispose();$contextMarker.Dispose()}
    $State.EventMarkerImages=$images;$State.List.SmallImageList=$images
    # Reserve room for the icon without clipping a complete clock timestamp.
    $width=[Windows.Forms.TextRenderer]::MeasureText('00:00:00.000',$State.List.Font).Width+24
    if($State.List.Columns.Count -and $State.List.Columns[0].Width -lt $width){$State.List.Columns[0].Width=$width}
    $State.List.Add_Disposed({param($sender,$eventArgs) if($sender.SmallImageList){$sender.SmallImageList.Dispose()}})
}
function Update-CurrentAnnotationHighlight {
    param($State,[double]$Seconds)
    Initialize-CurrentEventMarker $State
    $active=@($State.Items | Where-Object { $_.timestamp_seconds -le $Seconds } | Sort-Object timestamp_seconds,created_at_utc,id | Select-PlaybackReference)
    $context=@($State.ContextEntries | Where-Object { $_.timestamp_seconds -le $Seconds } | Sort-Object timestamp_seconds | Select-PlaybackReference)
    # A new context ends the preceding event's visual interval.
    if($context.Count -and $active.Count -and $active[0].timestamp_seconds -lt $context[0].timestamp_seconds){$active=@()}
    $id=''; if ($active.Count) { $id=[string]$active[0].id }
    $rowId=$id
    if(-not $rowId -and $context.Count){$rowId='context:'+[string]$context[0].id}
    elseif($rowId -and $context.Count -and $State.CollapsedEventContexts -and $State.CollapsedEventContexts.ContainsKey([string]$context[0].id)){
        $rowId='context:'+[string]$context[0].id
    }
    foreach ($row in $State.List.Items) {
        if($row.Tag.RowKind -eq 'Context'){
            $isCurrent=$rowId -ne '' -and $row.Tag.id -eq $rowId
            $imageIndex=if($isCurrent){0}else{2}
            $color=if($isCurrent){[Drawing.Color]::LightGoldenrodYellow}else{[Drawing.Color]::Lavender}
            if($row.ImageIndex -ne $imageIndex){$row.ImageIndex=$imageIndex}
            if($row.BackColor -ne $color){$row.BackColor=$color}
            continue
        }
        $isCurrent=$rowId -ne '' -and $row.Tag.id -eq $rowId
        $imageIndex=if($isCurrent){0}else{1}
        if($row.ImageIndex -ne $imageIndex){$row.ImageIndex=$imageIndex}
        $color=[Drawing.SystemColors]::Window
        if ($isCurrent) { $color=[Drawing.Color]::LightGoldenrodYellow }
        if ($row.BackColor -ne $color) { $row.BackColor=$color }
    }
    if ($State.ActiveAnnotationId -ne $id -or $State.ActiveEventListRowId -ne $rowId -or $State.EnsureCurrentVisible) {
        $State.ActiveAnnotationId=$id
        $State.ActiveEventListRowId=$rowId
        $State.EnsureCurrentVisible=$false
        foreach ($row in $State.List.Items) {
            if ($row.Tag.id -eq $(if($State.EventListPinnedId){$State.EventListPinnedId}else{$rowId})) { $row.EnsureVisible(); break }
        }
    }
}
# Determine the time range represented by the playback timeline.
function Get-TimelineRange {
    param($State)
    $key='{0}:{1}:{2}:{3}' -f $State.Slider.Handle,$State.Slider.Width,$State.Slider.Left,$State.Timeline.Left
    if ($State.TimelineRangeKey -ne $key) {
        $limits=[MachiningMonitor.TrackbarGeometry]::Limits($State.Slider)
        $offset=$State.Slider.Left-$State.Timeline.Left
        $State.TimelineRange=New-Object Drawing.PointF(($limits.X+$offset),($limits.Y+$offset))
        $State.TimelineRangeKey=$key
    }
    # One virtual range keeps drawing, clicking and hover on the same zoomed scale.
    $window=Get-TimelineWindow $State
    if ($State.Duration -le 0) { return $State.TimelineRange }
    $scale=($State.TimelineRange.Y-$State.TimelineRange.X)/$window.Span
    $left=$State.TimelineRange.X-$window.Start*$scale
    return New-Object Drawing.PointF([single]$left,[single]($left+$State.Duration*$scale))
}
# Choose readable tick spacing from the visible duration and the measured label width.
function Get-TimelineScaleTicks {
    param($State,[double]$LabelWidth)
    $window=Get-TimelineWindow $State
    if ($window.Span -le 0) { return }
    $limits=$State.TimelineRange
    $width=[Math]::Max(1.0,($limits.Y-$limits.X))
    $raw=$window.Span*[Math]::Max(1.0,$LabelWidth+18)/$width
    $power=[Math]::Pow(10,[Math]::Floor([Math]::Log10([Math]::Max(0.001,$raw))))
    $step=10*$power
    foreach ($factor in @(1,2,5,10)) { if ($factor*$power -ge $raw) { $step=$factor*$power; break } }
    if($State.TimelinePresetStep -gt 0){$step=[double]$State.TimelinePresetStep}
    $first=[Math]::Ceiling(($window.Start-0.0000001)/$step)*$step
    $count=[int][Math]::Ceiling($window.Span/$step)+1
    for ($i=0;$i -lt $count;$i++) {
        $time=$first+$i*$step
        if ($time -gt $window.Start+$window.Span+0.0000001) { break }
        if ($time -lt 0) { continue }
        $label=Format-AnnotationTime $time
        if ($step -ge 1) { $label=$label.Substring(0,$label.Length-4) }
        $x=$limits.X+($time-$window.Start)/$window.Span*$width
        [pscustomobject]@{Time=$time;X=$x;Label=$label;Step=$step}
    }
}
# Draw the ruler inside the same control so zoom, pan and resize repaint it together.
function Draw-TimelineScale {
    param($State,$Graphics)
    $font=$State.Timeline.Font
    $sample=Format-AnnotationTime $State.Duration
    $labelWidth=$Graphics.MeasureString($sample,$font).Width
    $ticks=@(Get-TimelineScaleTicks $State $labelWidth)
    $limits=$State.TimelineRange
    $Graphics.DrawLine([Drawing.Pens]::DimGray,[single]$limits.X,[single]14,[single]$limits.Y,[single]14)
    $previousRight=-1000.0
    foreach ($tick in $ticks) {
        $x=[single]$tick.X
        $Graphics.DrawLine([Drawing.Pens]::DimGray,$x,[single]12,$x,[single]17)
        $size=$Graphics.MeasureString($tick.Label,$font)
        $left=[Math]::Max(0.0,[Math]::Min(($State.Timeline.ClientSize.Width-$size.Width),($x-$size.Width/2)))
        # Keep endpoint labels inside the control and skip any that would overlap.
        if ($left -lt $previousRight+6) { continue }
        $Graphics.DrawString($tick.Label,$font,[Drawing.SystemBrushes]::ControlText,[single]$left,[single]24)
        $previousRight=$left+$size.Width
    }
}
# Normalize the visible interval against the current recording duration.
function Get-TimelineWindow {
    param($State)
    $duration=[Math]::Max(0.0,[double]$State.Duration)
    $span=$duration
    if ($State.TimelineSpan -gt 0) { $span=[Math]::Min($duration,[double]$State.TimelineSpan) }
    $start=[Math]::Max(0.0,[Math]::Min(($duration-$span),[double]$State.TimelineStart))
    return @{Start=$start;Span=$span}
}
# Map the precise indicator time relative to the visible window, avoiding global-slider rounding
# and cancellation of large single-precision virtual coordinates at one-second zoom.
# Editor-style playhead: a downward red head and a slightly thicker vertical stem.
function Draw-TimelinePlayhead {
    param($State,$Graphics)
    $x=[single](Get-TimelineIndicatorX $State)
    if($x -lt 0 -or $x -gt $State.Timeline.ClientSize.Width){return}
    $pen=New-Object Drawing.Pen([Drawing.Color]::Red,[single]2)
    try{
        $Graphics.DrawLine($pen,$x,[single]6,$x,[single]17)
        $points=[Drawing.PointF[]]@((New-Object Drawing.PointF(($x-5),0)),(New-Object Drawing.PointF(($x+5),0)),(New-Object Drawing.PointF($x,7)))
        $Graphics.FillPolygon([Drawing.Brushes]::Red,$points)
    }finally{$pen.Dispose()}
}
function Get-TimelineIndicatorX {
    param($State)
    [void](Get-TimelineRange $State)
    $window=Get-TimelineWindow $State
    $limits=$State.TimelineRange
    if ($window.Span -le 0) { return [double]$limits.X }
    $position=$State.TimelinePosition
    if ($null -eq $position) { $position=Get-QualityPosition $State }
    if ($null -ne $State.PendingSeek) { $position=[double]$State.PendingSeek }
    if ($State.Dragging) { $position=$State.Duration*$State.Slider.Value/[double]$State.Slider.Maximum }
    if($State.TimelineCursorDrag){$position=$State.TimelineCursorDragPosition}
    return ($limits.X+([double]$position-$window.Start)/$window.Span*($limits.Y-$limits.X))
}
function Start-TimelineCursorDrag {
    param($State,[double]$X,[double]$Y)
    if($State.Duration -le 0 -or -not $State.Context -or $State.Dragging -or $Y -lt 0 -or $Y -gt 22){return $false}
    $cursor=Get-TimelineIndicatorX $State
    if([Math]::Abs($X-$cursor) -gt 8){return $false}
    $window=Get-TimelineWindow $State
    $State.TimelineCursorDrag=@{Start=$window.Start;Span=$window.Span;Left=[double]$State.TimelineRange.X;Right=[double]$State.TimelineRange.Y;Offset=($X-$cursor)}
    $State.TimelinePauseSnapshot=$State.Paused;$State.Dragging=$true
    $State.TimelineCursorDragPosition=if($null -ne $State.PendingSeek){[double]$State.PendingSeek}elseif($null -ne $State.TimelinePosition){[double]$State.TimelinePosition}else{Get-QualityPosition $State}
    Update-QualityActionAvailability $State
    if($State.Split){Update-SplitExtractionAvailability $State}
    return $true
}
function Move-TimelineCursorDrag {
    param($State,[double]$X)
    $drag=$State.TimelineCursorDrag;if(-not $drag){return}
    $fraction=($X-$drag.Offset-$drag.Left)/[Math]::Max(1.0,$drag.Right-$drag.Left)
    $State.TimelineCursorDragPosition=[Math]::Max(0.0,[Math]::Min([double]$State.Duration,$drag.Start+[Math]::Max(0.0,[Math]::Min(1.0,$fraction))*$drag.Span))
    $State.Slider.Value=[int]($State.TimelineCursorDragPosition/$State.Duration*$State.Slider.Maximum)
    $State.Timeline.Invalidate()
}
function Complete-TimelineCursorDrag {
    param($State)
    if(-not $State.TimelineCursorDrag){return}
    $target=$State.TimelineCursorDragPosition
    $State.TimelineCursorDrag=$null;$State.Dragging=$false
    $State.Timeline.Capture=$false
    $owner=$State.Timeline.FindForm()
    if(-not $owner -or $owner.IsDisposed -or $owner.Disposing){return}
    Request-QualitySeek $State $target -FromTimeline
}
# Follow active playback in the zoomed window; preserve manual navigation while paused.
function Update-TimelinePlaybackFollow {
    param($State,[double]$Position)
    if ($State.Paused -or $State.Ended -or $State.Dragging -or $State.Seeking -or
        $null -ne $State.PendingSeek -or -not $State.Clock.Ready -or $State.Duration -le 0) { return }
    Center-TimelinePosition $State $Position
}
# Share centering between active playback and explicit timeline seeks, including while paused.
function Center-TimelinePosition {
    param($State,[double]$Position)
    if ($State.Duration -le 0 -or $null -eq $State.Timeline -or
        [double]::IsNaN($Position) -or [double]::IsInfinity($Position)) { return }
    $window=Get-TimelineWindow $State
    if ($window.Span -ge $State.Duration) { return }
    # Near either end, clamp the interval rather than showing time outside the recording.
    $start=[Math]::Max(0.0,[Math]::Min(([double]$State.Duration-$window.Span),($Position-$window.Span/2)))
    if ($start -eq [double]$State.TimelineStart) { return }
    $State.TimelineStart=$start
    # A stationary playhead can still have moving ticks, colors and event markers behind it.
    $State.Timeline.Invalidate()
    if ($State.Tooltip.GetToolTip($State.Timeline)) {
        $State.Tooltip.Hide($State.Timeline)
        $State.Tooltip.SetToolTip($State.Timeline,$null)
    }
}
# The wheel zooms at the pointer without requiring a keyboard modifier.
function Move-TimelineWindow {
    param($State,[double]$X,[int]$Delta,[bool]$Zoom)
    $duration=[double]$State.Duration
    if ($duration -le 0 -or $Delta -eq 0 -or $State.Dragging) { return }
    $window=Get-TimelineWindow $State
    $range=Get-TimelineRange $State
    $underPointer=[Math]::Max($window.Start,[Math]::Min(($window.Start+$window.Span),($duration*($X-$range.X)/[Math]::Max(1.0,($range.Y-$range.X)))))
    if ($Zoom) {
        $fraction=($underPointer-$window.Start)/$window.Span
        # Allow a one-second window regardless of recording length.
        $minimum=[Math]::Min($duration,0.1)
        $span=[Math]::Max($minimum,[Math]::Min($duration,($window.Span/[Math]::Pow(1.5,($Delta/120.0)))))
        $start=$underPointer-$fraction*$span
    } else {
        $span=$window.Span
        $start=$window.Start-($Delta/120.0)*$span*0.15
    }
    $State.TimelineSpan=$span
    $State.TimelinePresetStep=$null
    $State.TimelineStart=[Math]::Max(0.0,[Math]::Min(($duration-$span),$start))
    $State.Tooltip.Hide($State.Timeline)
    $State.Tooltip.SetToolTip($State.Timeline,$null)
    $State.Timeline.Invalidate()
}
# Find the quality in effect at the requested relative time.
function Set-TimelineScalePreset {
    param($State,[double]$Step)
    if($State.Duration -le 0 -or $Step -le 0 -or $State.Dragging){return}
    $null=Get-TimelineRange $State
    $width=[Math]::Max(1.0,$State.TimelineRange.Y-$State.TimelineRange.X)
    $labelWidth=[Windows.Forms.TextRenderer]::MeasureText('00:00:00.000',$State.Timeline.Font).Width
    $divisions=[Math]::Max(1,[Math]::Floor($width/($labelWidth+18)))
    $State.TimelinePresetStep=$Step
    $State.TimelineSpan=[Math]::Min([double]$State.Duration,$Step*$divisions)
    $position=Get-QualityPosition $State
    if($null -ne $State.PendingSeek){$position=[double]$State.PendingSeek}
    $State.TimelineStart=[Math]::Max(0.0,[Math]::Min(($State.Duration-$State.TimelineSpan),($position-$State.TimelineSpan/2)))
    $State.Tooltip.Hide($State.Timeline);$State.Tooltip.SetToolTip($State.Timeline,$null)
    $State.Timeline.Invalidate()
}
function Get-CurrentQuality {
    param($State, [double]$Seconds)
    # The label, list and timeline share the same retrospective assessment intervals.
    return Get-IntervalQuality @(Get-QualitySegments $State) $Seconds
}
# Convert seconds to the time representation used by annotation controls.
function Format-AnnotationTime {
    param([double]$Seconds)
    $ms=[long][Math]::Round($Seconds*1000,0,[MidpointRounding]::AwayFromZero)
    return ('{0:00}:{1:00}:{2:00}.{3:000}' -f [long][Math]::Floor($ms/3600000.0),[int][Math]::Floor(($ms%3600000)/60000.0),[int][Math]::Floor(($ms%60000)/1000.0),($ms%1000))
}
# Parse a displayed time and validate it against the allowed recording range.
function Convert-AnnotationTime {
    param([string]$Text,[ValidateSet('Clock','Seconds')][string]$Format,[double]$Maximum=0)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw (Get-QualityText 'Set the time.' 'Defina o tempo.') }
    $text=$Text.Trim(); $seconds=0.0
    if ($Format -eq 'Clock') {
        $match=[regex]::Match($text,'^(\d{2,}):([0-5]\d):([0-5]\d)\.(\d{3})$')
        if (-not $match.Success) { throw (Get-QualityText 'Use hh:mm:ss.mmm.' 'Use hh:mm:ss.mmm.') }
        $seconds=[double]::Parse($match.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)*3600 + [int]$match.Groups[2].Value*60 + [int]$match.Groups[3].Value + [int]$match.Groups[4].Value/1000.0
    } else {
        if ($text -notmatch '^\d+(?:[.,]\d{1,3})?$') { throw (Get-QualityText 'Enter non-negative seconds with up to three decimal places.' 'Introduza segundos não negativos com até três casas decimais.') }
        $seconds=[double]::Parse($text.Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture)
    }
    if ([double]::IsInfinity($seconds) -or [double]::IsNaN($seconds) -or $seconds -gt [TimeSpan]::MaxValue.TotalSeconds -or ($Maximum -gt 0 -and $seconds -gt $Maximum+0.0005001)) {
        throw (Get-QualityText 'Time exceeds the recording duration.' 'O tempo excede a duração da gravação.')
    }
    $rounded=[Math]::Round($seconds,3)
    if ($Maximum -gt 0 -and $rounded -gt $Maximum -and $rounded-$Maximum -le 0.0005001) { return $Maximum }
    return $rounded
}
# Refresh the absolute date/time derived from the event's relative position.
function Update-AnnotationWallTime {
    param($Context)
    $display='-'
    if ($Context.TimeValid -and $null -ne $Context.State.RecordingStart) {
        $display=$Context.State.RecordingStart.AddSeconds([double]$Context.Time).ToString('yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
    }
    $caption=Get-QualityText 'Event clock time: ' 'Hora do evento: '
    if ($Context.IsPosition) { $caption=Get-QualityText 'Recording clock time: ' 'Hora da gravação: ' }
    $Context.WallTime.Text=$caption + $display
}
# Attach validation feedback to fields in the annotation dialog.
function Add-AnnotationFieldWarnings {
    param($Dialog)
    $c=$Dialog.Tag
    foreach ($control in $Dialog.Controls) { if ($control.Top -ge 68) { $control.Top+=44 } }
    $Dialog.ClientSize=New-Object Drawing.Size($Dialog.ClientSize.Width,($Dialog.ClientSize.Height+44))
    $c.TimeError.Visible=$false; $c.FieldErrors=@{}
    foreach ($pair in @(@('Clock',$c.ClockInput),@('Seconds',$c.SecondsInput))) {
        $label=New-Object Windows.Forms.Label; $label.ForeColor=[Drawing.Color]::Firebrick; $label.SetBounds($pair[1].Left,($pair[1].Bottom+3),$pair[1].Width,40); $Dialog.Controls.Add($label); $c.FieldErrors[$pair[0]]=$label
    }
}
# Keep the editor's alternative time representations synchronized.
# Compact the atomic editor and reserve validation space only while a time field is invalid.
function Set-CompactAtomicEventLayout {
    param($Dialog)
    $c=$Dialog.Tag
    if(-not $c.CompactFields){return}
    $offset=if($c.TimeValid){0}else{34}
    $c.CompactFields.TimeLabel.SetBounds(12,6,190,18)
    $c.CompactFields.SecondsLabel.SetBounds(218,6,125,18)
    $c.ClockInput.SetBounds(12,25,190,23);$c.SecondsInput.SetBounds(218,25,125,23)
    foreach($errorLabel in $c.FieldErrors.Values){$errorLabel.Top=49;$errorLabel.Height=32;$errorLabel.Visible=-not $c.TimeValid}
    $c.WallTime.SetBounds(12,(52+$offset),468,18)
    $c.OccurrenceLabel.SetBounds(12,(79+$offset),100,20);$c.Occurrence.SetBounds(116,(76+$offset),364,25)
    $c.ValueLabel.SetBounds(12,(109+$offset),100,20)
    $c.Value.SetBounds(116,(106+$offset),364,25);$c.ValueCombo.SetBounds(116,(106+$offset),364,25)
    $c.CompactFields.NotesLabel.SetBounds(12,(136+$offset),468,18);$c.Notes.SetBounds(12,(155+$offset),468,60)
    $c.Save.SetBounds(282,(223+$offset),95,28);$c.CompactFields.Cancel.SetBounds(385,(223+$offset),95,28)
    if($c.CompactFields.StopCapture){$c.CompactFields.StopCapture.SetBounds(12,(223+$offset),180,28)}
    $Dialog.ClientSize=New-Object Drawing.Size(492,(259+$offset))
}

function Sync-AnnotationTime {
    param($Dialog,[ValidateSet('Clock','Seconds')][string]$Source)
    $c=$Dialog.Tag; if ($c.SyncingTime) { return }
    $c.SyncingTime=$true
    try {
        $input=$c.ClockInput; if ($Source -eq 'Seconds') { $input=$c.SecondsInput }
        $maximum=$c.State.Duration
        $value=Convert-AnnotationTime $input.Text $Source $maximum
        $c.Time=$value; $c.TimeValid=$true; $c.TimeError.Text=''; $c.Save.Enabled=$true
        if ($Source -eq 'Clock') { $c.SecondsInput.Text=$value.ToString('0.###',[Globalization.CultureInfo]::CurrentCulture) }
        else { $c.ClockInput.Text=Format-AnnotationTime $value }
        $c.ClockInput.BackColor=[Drawing.SystemColors]::Window; $c.SecondsInput.BackColor=[Drawing.SystemColors]::Window
        if ($c.FieldErrors) { foreach ($label in $c.FieldErrors.Values) { $label.Text='' } }
    } catch {
        $c.TimeValid=$false; $c.TimeError.Text=$_.Exception.Message; $c.Save.Enabled=$false
        $input.BackColor=[Drawing.Color]::MistyRose
        if ($c.FieldErrors) { foreach ($label in $c.FieldErrors.Values) { $label.Text='' }; $c.FieldErrors[$Source].Text=$_.Exception.Message }
    } finally { if ($c.CopyTime) { $c.CopyTime.Enabled=$c.TimeValid; $c.CopyTime.Text=Get-QualityText 'Copy time' 'Copiar tempo' }; $c.SyncingTime=$false; Update-AnnotationWallTime $c; if ($c.AnnotationParameters) { Update-AnnotationParameterValidation $Dialog }; Set-CompactAtomicEventLayout $Dialog }
}
# Let the operator enter a playback position and request a seek.
function Show-QualityPositionDialog {
    param($State)
    if (-not $State.Clock.Ready) { return }
    $wasPaused=[bool]$State.Paused; $dialog=$null; $accepted=$false
    try {
        if (-not $wasPaused) { Switch-QualityPause $State }
        $dialog=New-Object Windows.Forms.Form
        $dialog.Text=Get-QualityText 'Position playback' 'Posicionar reprodução'
        $dialog.ClientSize=New-Object Drawing.Size(480,210)
        $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'
        $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
        $clockLabel=New-Object Windows.Forms.Label
        $clockLabel.Text=Get-QualityText 'Time (hh:mm:ss.mmm)' 'Tempo (hh:mm:ss.mmm)'
        $clockLabel.SetBounds(12,12,248,22); $dialog.Controls.Add($clockLabel)
        $secondsLabel=New-Object Windows.Forms.Label
        $secondsLabel.Text=Get-QualityText 'Total seconds' 'Segundos totais'
        $secondsLabel.SetBounds(280,12,182,22); $dialog.Controls.Add($secondsLabel)
        $time=[Math]::Round((Get-QualityPosition $State),3)
        $clock=New-Object Windows.Forms.TextBox
        $clock.SetBounds(12,38,248,25); $clock.Text=Format-AnnotationTime $time; $dialog.Controls.Add($clock)
        $seconds=New-Object Windows.Forms.TextBox
        $seconds.SetBounds(280,38,182,25); $seconds.Text=$time.ToString('0.000',[Globalization.CultureInfo]::CurrentCulture); $dialog.Controls.Add($seconds)
        $wall=New-Object Windows.Forms.Label
        $wall.SetBounds(12,70,450,22); $dialog.Controls.Add($wall)
        $errorLabel=New-Object Windows.Forms.Label
        $errorLabel.SetBounds(12,96,450,40); $errorLabel.ForeColor=[Drawing.Color]::Firebrick; $dialog.Controls.Add($errorLabel)
        $copy=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $copy
        $copy.Name='CopyPositionTime'
        $copy.Text=Get-QualityText 'Copy time' 'Copiar tempo'
        $copy.SetBounds(12,168,150,30); $dialog.Controls.Add($copy)
        $copy.Add_Click({param($sender,$eventArgs)
            $d=$sender.FindForm()
            if(-not $d.Tag.TimeValid){return}
            try {
                [Windows.Forms.Clipboard]::SetText((Format-AnnotationTime ([double]$d.Tag.Time)))
                $sender.Text=Get-QualityText 'Time copied' 'Tempo copiado'
            } catch { Show-QualityError $_.Exception.Message }
        })
        $go=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $go
        $go.Text=Get-QualityText 'Position' 'Posicionar'; $go.SetBounds(260,168,95,30); $dialog.Controls.Add($go)
        $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel
        $cancel.Text=Get-QualityText 'Cancel' 'Cancelar'; $cancel.SetBounds(365,168,95,30)
        $cancel.DialogResult='Cancel'; $dialog.Controls.Add($cancel); $dialog.CancelButton=$cancel; $dialog.AcceptButton=$go
        $dialog.Tag=@{IsPosition=$true;CopyTime=$copy;State=$State;Time=$time;ClockInput=$clock;SecondsInput=$seconds;TimeError=$errorLabel;Save=$go;SyncingTime=$false;TimeValid=$true;WallTime=$wall}
        Add-AnnotationFieldWarnings $dialog
        Update-AnnotationWallTime $dialog.Tag
        $clock.Add_TextChanged({param($sender,$eventArgs) Sync-AnnotationTime $sender.FindForm() 'Clock'})
        $seconds.Add_TextChanged({param($sender,$eventArgs) Sync-AnnotationTime $sender.FindForm() 'Seconds'})
        $go.Add_Click({param($sender,$eventArgs)
            $d=$sender.FindForm()
            if ($d.Tag.TimeValid) { $d.DialogResult='OK'; $d.Close() }
        })
        if ($dialog.ShowDialog($State.List.FindForm()) -eq 'OK') {
            Request-QualitySeek $State ([double]$dialog.Tag.Time) -FromTimeline
            $State.SeekPaused=$wasPaused
            $accepted=$true
        }
    } catch { Show-QualityError $_.Exception.Message }
    finally {
        if ($null -ne $dialog) { $dialog.Dispose() }
        if (-not $accepted -and -not $wasPaused -and $State.Paused) {
            try { Switch-QualityPause $State } catch { Show-QualityError $_.Exception.Message }
        }
    }
}
# Load available machine states from the state configuration.
function Get-MachineStates {
    $path=Join-Path $PSScriptRoot 'machine_states.json'
    $config=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $ids=@{}
    $localized=@()
    foreach ($state in $config.states) {
        $key=$state.label_key; if (-not $key) { $key=$state.label }
        if ([string]::IsNullOrWhiteSpace($state.id) -or [string]::IsNullOrWhiteSpace($key) -or $ids.ContainsKey($state.id)) { throw 'machine_states.json: estados inválidos ou repetidos.' }
        $ids[$state.id]=$true
        $localized+=[pscustomobject]@{id=$state.id;label=(Get-UiText $key)}
    }
    if (-not $ids.ContainsKey([string]$config.default)) { throw 'machine_states.json: estado predefinido inválido.' }
    return [pscustomobject]@{default=$config.default;states=$localized}
}
# Resolve the machining parameters in effect at the requested time.
function Get-AnnotationParameters {
    param($State,[double]$Seconds)
    $entries=$State.ContextEntries
    if($null -eq $entries){$entries=@(Read-RecordingContexts (Split-Path $State.Path -Parent))}
    $active=Get-RecordingContextAt $entries $Seconds
    $parameters=$active.context.Parameters
    $previous=@($State.Items | Where-Object { $_.timestamp_seconds -ge $active.timestamp_seconds -and $_.timestamp_seconds -le $Seconds -and $null -ne $_.parameters } | Sort-Object timestamp_seconds,created_at_utc,id | Select-PlaybackReference)
    if($previous.Count){$parameters=$previous[0].parameters}
    return Copy-SplitObject $parameters
}
# Enable custom drawing so machine states can use their configured colors.
function Enable-EventStateColorDrawing {
    param($Combo)
    # Native DropDownList painting can ignore ForeColor for the selected value.
    $Combo.DrawMode='OwnerDrawFixed'
    $Combo.Add_DrawItem({
        param($sender,$eventArgs)
        if($eventArgs.Index -lt 0){return}
        $eventArgs.DrawBackground()
        $item=$sender.Items[$eventArgs.Index]
        $text=$sender.GetItemText($item)
        $color=$eventArgs.ForeColor
        if($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected){$color=[Drawing.SystemColors]::HighlightText}
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$text,$eventArgs.Font,$eventArgs.Bounds,$color,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        $eventArgs.DrawFocusRectangle()
    })
}
# Refresh editor field colors to reflect state and override information.
function Update-AnnotationFieldColors {
    param($Dialog)
    $c=$Dialog.Tag
    if($null -eq $c.InheritedParameters -or $null -eq $c.InitialParameters){return}
    foreach($rate in $c.Rates){if($rate.Updating){return}}
    $preview=Copy-EventParameterObject $c.AnnotationParameters
    foreach($field in $c.Fields){
        $name=if([object]::ReferenceEquals($field.Object,$c.AnnotationParameters.SpindleSpeed)){'SpindleSpeed'}else{'FeedRate'}
        try{$preview.$name.($field.Name)=Read-SplitNumber $field.Input.Text}catch{}
    }
    $mask=Get-EditedEventParameterMask @{Old=$c.Old;InitialParameters=$c.InitialParameters;InheritedParameters=$c.InheritedParameters;AnnotationParameters=$preview;Rates=$c.Rates}
    foreach($field in $c.Fields){
        $name=if([object]::ReferenceEquals($field.Object,$c.AnnotationParameters.SpindleSpeed)){'SpindleSpeed'}else{'FeedRate'}
        $changed=$field.Name -in @($mask.$name) -or $preview.$name.($field.Name) -ne $c.InheritedParameters.$name.($field.Name)
        $field.Input.ForeColor=if($changed){[Drawing.Color]::FromArgb(192,96,0)}else{[Drawing.SystemColors]::WindowText}
    }
    $c.Quality.ForeColor=if($c.Quality.SelectedIndex -ne $c.InheritedQuality){[Drawing.Color]::FromArgb(192,96,0)}else{[Drawing.SystemColors]::WindowText}
    $c.MachineState.ForeColor=if($c.MachineState.SelectedItem.id -ne $c.InheritedMachineState){[Drawing.Color]::FromArgb(192,96,0)}else{[Drawing.SystemColors]::WindowText}
    $c.MachineState.Invalidate();$c.Quality.Invalidate()
    $timeColor=if($null -ne $c.Old -and $c.Time -ne $c.BaselineTime){[Drawing.Color]::FromArgb(192,96,0)}else{[Drawing.SystemColors]::WindowText}
    $c.ClockInput.ForeColor=$timeColor; $c.SecondsInput.ForeColor=$timeColor
}
# Validate related machining inputs and refresh warnings in the event editor.
function Update-AnnotationParameterValidation {
    param($Dialog)
    $c=$Dialog.Tag
    if (-not $c.AnnotationParameters -or $c.SyncingTime) { return }
    $valid=$c.TimeValid
    foreach ($rate in $c.Rates) { if ($rate.Updating) { return }; if (-not $rate.Valid) { $valid=$false } }
    foreach ($field in $c.Fields) {
        $label=$c.ParameterWarnings[$field.Input]; $label.Text=''
        try { $null=Read-SplitNumber $field.Input.Text; $field.Input.BackColor=[Drawing.SystemColors]::Window }
        catch { $valid=$false; $field.Input.BackColor=[Drawing.Color]::MistyRose; $label.Text='Número inválido' }
    }
    foreach ($rate in $c.Rates) {
        if (-not $rate.Valid -and $rate.LastRole) { $box=$rate[$rate.LastRole]; $box.BackColor=[Drawing.Color]::MistyRose; $c.ParameterWarnings[$box].Text='Valor inválido' }
    }
    $c.Save.Enabled=$valid
    Update-AnnotationFieldColors $Dialog
}
# Create or edit an event, including time, quality, machine state and machining parameters.
function Show-QualityEditor {
    param($State, [bool]$Edit)
    Write-QualityDiagnostic $State ('annotation-command edit='+$Edit)
    if (-not $State.Clock.Ready -or $State.Handle -eq [IntPtr]::Zero) {
        Write-QualityDiagnostic $State 'annotation-not-ready'
        Show-QualityError (Get-QualityText 'The player is still preparing the recording. Please try again in a moment.' 'O leitor ainda está a preparar a gravação. Tente novamente dentro de instantes.')
        return
    }
    $old = $null
    if ($Edit) {
        if ($State.List.SelectedItems.Count -gt 1) { return }
        if ($State.List.SelectedItems.Count -gt 0) {
            $old=$State.List.SelectedItems[0].Tag
            if($old.RowKind -eq 'Context'){return}
        }
        else {
            $old=@($State.Items | Where-Object { $_.id -eq $State.ActiveAnnotationId } | Select-PlaybackReference -First)
            if (-not $old.Count) { return }
            $old=$old[0]
            foreach ($row in $State.List.Items) {
                if ($row.Tag.id -eq $old.id) {
                    $row.Selected=$true
                    $row.Focused=$true
                    $row.EnsureVisible()
                    break
                }
            }
        }
    }
    $resume = -not $State.Paused; $dialog = $null
    try {
        if ($resume -and -not $State.LiveRecording) { Switch-QualityPause $State }
        $time = [Math]::Round((Get-QualityPosition $State),3)
        if ($Edit) { $time = $old.timestamp_seconds }
        $dialog = New-Object Windows.Forms.Form
        $dialog.Text = Get-QualityText 'Recording event' 'Evento da gravação'
        $dialog.ClientSize = New-Object Drawing.Size(480,418); $dialog.StartPosition = 'CenterParent'
        $dialog.FormBorderStyle = 'FixedDialog'; $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
        $timeLabel = New-Object Windows.Forms.Label
        $timeLabel.Text = Get-QualityText 'Time (hh:mm:ss.mmm)' 'Tempo (hh:mm:ss.mmm)'
        $timeLabel.SetBounds(12,12,248,22); $dialog.Controls.Add($timeLabel)
        $secondsLabel=New-Object Windows.Forms.Label
        $secondsLabel.Text=Get-QualityText 'Total seconds' 'Segundos totais'
        $secondsLabel.SetBounds(280,12,182,22); $dialog.Controls.Add($secondsLabel)
        $clockInput=New-Object Windows.Forms.TextBox
        $clockInput.SetBounds(12,38,248,25); $clockInput.Text=Format-AnnotationTime $time
        $clockInput.ReadOnly=$false; $dialog.Controls.Add($clockInput)
        $secondsInput=New-Object Windows.Forms.TextBox
        $secondsInput.SetBounds(280,38,182,25); $secondsInput.Text=$time.ToString('0.###',[Globalization.CultureInfo]::CurrentCulture)
        $secondsInput.ReadOnly=$false; $dialog.Controls.Add($secondsInput)
        if ($State.LiveRecording) { $clockInput.ReadOnly=$true; $secondsInput.ReadOnly=$true }
        $wallTimeLabel=New-Object Windows.Forms.Label
        $wallTimeLabel.SetBounds(12,68,450,22); $dialog.Controls.Add($wallTimeLabel)
        $timeError=New-Object Windows.Forms.Label
        $timeError.SetBounds(12,92,450,38); $timeError.ForeColor=[Drawing.Color]::Firebrick; $dialog.Controls.Add($timeError)
        $qualityLabel = New-Object Windows.Forms.Label
        $qualityLabel.Text = Get-QualityText 'Rating' 'Classificação'
        $qualityLabel.AutoSize=$true
        $qualityLabel.SetBounds(12,136,160,25); $dialog.Controls.Add($qualityLabel)
        $quality = New-Object Windows.Forms.ComboBox
        $quality.DropDownStyle='DropDownList'; $quality.SetBounds(180,133,282,28)
        foreach ($level in 0..5) { [void]$quality.Items.Add((Get-QualityDisplay $level)) }
        $quality.SelectedIndex=0
        if ($Edit) { $quality.SelectedIndex = [int]$old.quality }
        else {
            $current=Get-CurrentQuality $State $time
            if ($null -ne $current) { $quality.SelectedIndex=[int]$current }
        }
        $dialog.Controls.Add($quality)
        $dialogTooltip=New-Object MachiningMonitor.WrappingToolTip
        $dialogTooltip.AutoPopDelay=15000; $dialogTooltip.ShowAlways=$true
        $quality.Tag=$dialogTooltip
        $dialogTooltip.SetToolTip($quality,(Get-QualityMeaning $quality.SelectedIndex))
        $quality.Add_SelectedIndexChanged({ param($sender,$eventArgs)
            if ($sender.SelectedIndex -ge 0) { $sender.Tag.SetToolTip($sender,(Get-QualityMeaning $sender.SelectedIndex)) }
        })
        $quality.DrawMode='OwnerDrawFixed'
        $quality.Add_DrawItem({param($sender,$eventArgs)
            if ($eventArgs.Index -lt 0) { return }
            $eventArgs.DrawBackground()
            [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,[string]$sender.Items[$eventArgs.Index],$eventArgs.Font,$eventArgs.Bounds,$eventArgs.ForeColor,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
            $eventArgs.DrawFocusRectangle()
            if ($sender.DroppedDown -and ($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected)) {
                $sender.Tag.Hide($sender)
                $sender.Tag.Show((Get-QualityMeaning $eventArgs.Index),$sender,($sender.Width+8),($sender.Height+$eventArgs.Bounds.Top),15000)
            }
        })
        $quality.Add_DropDownClosed({param($sender,$eventArgs) $sender.Tag.Hide($sender) })
        $dialog.Add_Disposed({ param($sender,$eventArgs) $sender.Tag.Quality.Tag.Dispose() })
        $notesLabel = New-Object Windows.Forms.Label
        $notesLabel.Text = Get-QualityText 'Notes' 'Notas'; $notesLabel.SetBounds(12,172,450,25); $dialog.Controls.Add($notesLabel)
        $notes = New-Object Windows.Forms.TextBox
        $notes.Multiline = $true; $notes.AcceptsReturn = $true; $notes.ScrollBars = 'Vertical'; $notes.SetBounds(12,200,450,160)
        if ($Edit) { $notes.Text = $old.observations }; $dialog.Controls.Add($notes)
        $save = New-Object Windows.Forms.Button; Register-ButtonActionTooltip $save; $save.Text = Get-QualityText 'Save' 'Guardar'
        $save.SetBounds(260,376,95,30); $dialog.Controls.Add($save)
        $cancel = New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text = Get-QualityText 'Cancel' 'Cancelar'
        $cancel.SetBounds(365,376,95,30); $cancel.DialogResult = 'Cancel'; $dialog.Controls.Add($cancel); $dialog.CancelButton = $cancel
        $dialog.Tag = @{ State = $State; Old = $old; Time = $time; Quality = $quality; Notes = $notes;
            ClockInput=$clockInput; SecondsInput=$secondsInput; TimeError=$timeError; Save=$save; SyncingTime=$false; TimeValid=$true; WallTime=$wallTimeLabel }
        Add-AnnotationFieldWarnings $dialog
        $dialog.ClientSize=New-Object Drawing.Size(492,395)
        $clockInput.Width=190; $timeLabel.Width=190; $secondsInput.SetBounds(218,38,125,25); $secondsLabel.Left=218
        $dialog.Tag.FieldErrors.Clock.Width=190; $dialog.Tag.FieldErrors.Seconds.SetBounds(218,90,125,40)
        $wallTimeLabel.Top=106; $quality.SetBounds(120,130,360,25); $qualityLabel.SetBounds(12,133,100,20)
        $states=Get-MachineStates
        $stateId=$states.default; $stateLabel=''
        if (-not $Edit) {
            $previous=@($State.Items | Where-Object { $_.timestamp_seconds -le $time } | Sort-Object timestamp_seconds,created_at_utc,id | Select-PlaybackReference)
            if($previous.Count -and $previous[0].machine_state){ $stateId=$previous[0].machine_state; $stateLabel=$previous[0].machine_state_label }
        }
        if ($Edit -and $old.machine_state) { $stateId=$old.machine_state; $stateLabel=$old.machine_state_label }
        $choices=@($states.states)
        if (-not @($choices | Where-Object id -eq $stateId).Count) {
            if (-not $stateLabel) { $stateLabel=$stateId }
            $choices+=[pscustomobject]@{id=$stateId;label=$stateLabel}
        }
        $stateCaption=New-Object Windows.Forms.Label; $stateCaption.Text=Get-UiText 'State'; $stateCaption.SetBounds(12,165,100,20); $dialog.Controls.Add($stateCaption)
        $machineState=New-Object Windows.Forms.ComboBox; $machineState.DropDownStyle='DropDownList'; $machineState.DisplayMember='label'; $machineState.SetBounds(120,162,360,25)
        Enable-EventStateColorDrawing $machineState
        foreach ($choice in $choices) { [void]$machineState.Items.Add($choice) }
        for ($i=0;$i -lt $choices.Count;$i++) { if ($choices[$i].id -eq $stateId) { $machineState.SelectedIndex=$i; break } }
        $dialog.Controls.Add($machineState)
        $activities=Get-MachineActivities;$activityId=$activities.default;$activityLabel=''
        if($Edit -and $old.machine_activity){$activityId=$old.machine_activity;$activityLabel=$old.machine_activity_label}
        elseif(-not $Edit){$previousActivity=@($State.Items|Where-Object {$_.timestamp_seconds -le $time -and $_.machine_activity}|Sort-Object timestamp_seconds,created_at_utc,id|Select-PlaybackReference -First);if($previousActivity.Count){$activityId=$previousActivity[0].machine_activity;$activityLabel=$previousActivity[0].machine_activity_label}}
        $activityChoices=@($activities.activities);if(-not @($activityChoices|Where-Object id -eq $activityId).Count){$activityChoices+=[pscustomobject]@{id=$activityId;label=$activityLabel}}
        $activityCaption=New-Object Windows.Forms.Label;$activityCaption.Text=Get-UiText 'Activity';$activityCaption.SetBounds(12,198,100,20);$dialog.Controls.Add($activityCaption)
        $machineActivity=New-Object Windows.Forms.ComboBox;$machineActivity.DropDownStyle='DropDownList';$machineActivity.DisplayMember='label';$machineActivity.SetBounds(120,195,360,25)
        foreach($choice in $activityChoices){[void]$machineActivity.Items.Add($choice)}
        for($i=0;$i -lt $activityChoices.Count;$i++){if($activityChoices[$i].id -eq $activityId){$machineActivity.SelectedIndex=$i;break}}
        $dialog.Controls.Add($machineActivity)
        # State, activity, and rating are derived from atomic occurrence values and are not edited as separate fields.
        $qualityLabel.Visible=$false;$quality.Visible=$false;$stateCaption.Visible=$false;$machineState.Visible=$false;$activityCaption.Visible=$false;$machineActivity.Visible=$false
        $parameters=Get-AnnotationParameters $State $time
        if ($Edit -and $null -ne $old.parameters) { $parameters=Copy-SplitObject $old.parameters }
        $fields=New-Object 'System.Collections.Generic.List[object]'
        $section=New-SplitEditorSection $dialog (Get-UiText 'Machining parameters') 12 197 468 212
        $rates=@()
        $rates+=Add-SplitRateRow $parameters.SpindleSpeed 'ProgrammedRpm' 'AdjustedRpm' (Get-QualityText 'Spindle speed' 'Velocidade de rotação do fuso') $section $fields 18
        $rates+=Add-SplitRateRow $parameters.FeedRate 'ProgrammedMmPerMin' 'AdjustedMmPerMin' (Get-QualityText 'Feed rate' 'Avanço') $section $fields 112
        $notesLabel.SetBounds(12,245,468,20); $notes.SetBounds(12,267,468,75)
        $save.SetBounds(282,353,95,30); $cancel.SetBounds(385,353,95,30)
        $legend=New-Object Windows.Forms.Label
        $legend.Text=Get-QualityText 'Text in this color indicates fields changed in this event.' 'O texto nesta cor indica os campos alterados neste evento.'
        $legend.ForeColor=[Drawing.Color]::FromArgb(192,96,0); $legend.SetBounds(12,508,468,30); $dialog.Controls.Add($legend)
        # Atomic events carry one occurrence value; the legacy machining-parameter editor is no longer shown.
        $section.Visible=$false; $legend.Visible=$false
        $dialog.Tag.MachineState=$machineState; $dialog.Tag.BaselineMachineState=$machineState.SelectedItem.id; $dialog.Tag.BaselineMachineStateLabel=$machineState.SelectedItem.label
        $dialog.Tag.MachineActivity=$machineActivity; $dialog.Tag.BaselineMachineActivity=$machineActivity.SelectedItem.id; $dialog.Tag.BaselineMachineActivityLabel=$machineActivity.SelectedItem.label
        $dialog.Tag.AnnotationParameters=$parameters; $dialog.Tag.Fields=$fields; $dialog.Tag.Rates=$rates; $dialog.Tag.ParameterWarnings=@{}
        if($null -eq $State.ContextEntries){$State.ContextEntries=@(Read-RecordingContexts (Split-Path $State.Path -Parent))}
        $contextAtEvent=Get-RecordingContextAt $State.ContextEntries $time
        $inherited=$contextAtEvent.context.Parameters
        $priorEvent=$null
        foreach($prior in @($State.Items|Where-Object {$_.timestamp_seconds -le $time}|Sort-Object timestamp_seconds,created_at_utc,id)){
            if($Edit -and $prior.id -eq $old.id){break}
            $priorEvent=$prior
            if($prior.parameters -and $prior.timestamp_seconds -ge $contextAtEvent.timestamp_seconds){$inherited=$prior.parameters}
        }
        $dialog.Tag.InheritedParameters=Copy-EventParameterObject $inherited
        $dialog.Tag.InheritedQuality=if($null -ne $priorEvent){[int]$priorEvent.quality}else{0}
        $dialog.Tag.InheritedMachineState=if($null -ne $priorEvent -and $priorEvent.machine_state){$priorEvent.machine_state}else{$states.default}
        # Untouched quality inherits; opening another event must not pin a snapshot.
        if(-not $Edit -or ($null -ne $old.event_changes -and -not $old.event_changes.quality)){
            $quality.SelectedIndex=$dialog.Tag.InheritedQuality
        }
        $dialog.Tag.InitialQuality=$quality.SelectedIndex
        $dialog.Tag.InitialParameters=Copy-EventParameterObject $parameters
        foreach($rate in $rates){
            $rate.Touched=@{}
            foreach($box in @($rate.Programmed,$rate.Percent,$rate.Adjusted)){
                $box.Add_TextChanged({param($sender,$eventArgs) if(-not $sender.Tag.Group.Updating){$sender.Tag.Group.Touched[$sender.Tag.Role]=$true}})
            }
        }
        $dialog.Tag.BaselineTime=$time
        $quality.Add_SelectedIndexChanged({param($sender,$eventArgs) Update-AnnotationFieldColors $sender.FindForm()})
        $machineState.Add_SelectedIndexChanged({param($sender,$eventArgs) Update-AnnotationFieldColors $sender.FindForm()})
        foreach ($field in $fields) {
            $box=$field.Input; $box.Width=90; $label=New-Object Windows.Forms.Label; $label.ForeColor=[Drawing.Color]::Firebrick; $label.SetBounds($box.Left,($box.Bottom+3),$box.Width,28); $box.Parent.Controls.Add($label); $dialog.Tag.ParameterWarnings[$box]=$label
            $box.Add_TextChanged({param($sender,$eventArgs) Update-AnnotationParameterValidation $sender.FindForm()})
        }
        Update-AnnotationParameterValidation $dialog
        Update-AnnotationWallTime $dialog.Tag
        $clockInput.Add_TextChanged({ param($sender,$eventArgs) Sync-AnnotationTime $sender.FindForm() 'Clock' })
        $secondsInput.Add_TextChanged({ param($sender,$eventArgs) Sync-AnnotationTime $sender.FindForm() 'Seconds' })
        $save.Add_Click({
            param($sender,$eventArgs)
            $d = $sender.FindForm(); $context = $d.Tag
            try {
                foreach ($rate in $context.Rates) { if ($rate.LastRole -eq 'Percent') { Sync-SplitRate $rate.Percent -Normalize } }
                Update-AnnotationParameterValidation $d
                if (-not $context.Save.Enabled) { return }
                foreach ($field in $context.Fields) { $field.Object.($field.Name)=Read-SplitNumber $field.Input.Text }
                foreach ($rate in @($context.AnnotationParameters.SpindleSpeed,$context.AnnotationParameters.FeedRate)) {
                    if ($null -ne $rate.AdjustmentPercent) { $rate.AdjustmentPercent=[Math]::Round($rate.AdjustmentPercent,2,[MidpointRounding]::AwayFromZero) }
                }
                $now = [DateTime]::UtcNow.ToString('o'); $id = [guid]::NewGuid().ToString('N'); $created = $now
                if ($null -ne $context.Old) { $id = $context.Old.id; $created = $context.Old.created_at_utc }
                $item = [pscustomobject]@{ id = $id; timestamp_seconds = [double]$context.Time; quality = [int]$context.Quality.SelectedIndex;
                    observations = $context.Notes.Text; observations_format='manual'; created_at_utc = $created; updated_at_utc = $now; parameters=(Copy-SplitObject $context.AnnotationParameters);
                    machine_state=$context.MachineState.SelectedItem.id; machine_state_label=$context.MachineState.SelectedItem.label;
                    machine_activity=$context.MachineActivity.SelectedItem.id; machine_activity_label=$context.MachineActivity.SelectedItem.label;
                    occurrence=(Get-EditedEventOccurrences $context); value=(Get-EditedEventValue $context) }
                $item|Add-Member NoteProperty parameter_changes (Get-EditedEventParameterMask $context)
                $item|Add-Member NoteProperty event_changes (Get-EditedEventFieldChanges $context)
                if($item.occurrence -eq 'QualityClassificationChanged'){
                    # Keep the compatibility rating synchronized with the atomic assessment value.
                    $item.quality=[int]$item.value;$item.event_changes.quality=$true
                }
                if($null -ne $context.Old -and $null -ne $context.Old.PSObject.Properties['observations_before_changes_cleanup']){
                    $item|Add-Member NoteProperty observations_before_changes_cleanup $context.Old.observations_before_changes_cleanup
                }
                $next = @($context.State.Items | Where-Object { $_.id -ne $id }) + @($item)
                $context.State.Items = @(Save-QualityAnnotations $context.State.Path $next -PassThru)
                Update-QualityList $context.State; Select-EditedPlaybackEvent $context.State $id; $d.DialogResult = 'OK'; $d.Close()
            } catch { Show-QualityError $_.Exception.Message }
        })
        if ($State.LiveRecording) {
            $stopCapture=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $stopCapture
            $stopCapture.Text=Get-QualityText 'Stop recording' 'Parar gravação'
            $stopCapture.SetBounds(12,353,180,30); $dialog.Controls.Add($stopCapture)
            $stopCapture.Add_Click({ if(Request-FormRecordingStop $this.FindForm()){ $this.FindForm().Close() } })
        }
        Add-EventOccurrencesEditor $dialog $old
        $dialog.Tag.CompactFields=@{TimeLabel=$timeLabel;SecondsLabel=$secondsLabel;NotesLabel=$notesLabel;Cancel=$cancel;StopCapture=$stopCapture}
        Set-CompactAtomicEventLayout $dialog
        [void]$dialog.ShowDialog($State.List.FindForm())
        if($dialog.DialogResult -eq 'OK' -and $State.EventListPinnedId){Select-EditedPlaybackEvent $State $State.EventListPinnedId}
    } catch { Show-QualityError $_.Exception.Message }
    finally {
        if ($null -ne $dialog) { $dialog.Dispose() }
        if ($resume -and $State.Paused -and -not $State.Player.HasExited) {
            try { Switch-QualityPause $State } catch { Show-QualityError $_.Exception.Message }
        }
    }
}
# Enable actions only when the current playback and selection state allows them.
function Update-QualityActionAvailability {
    param($s)
    $previewPlaying=$s.Split -and $s.Split.Preview -and (-not $s.Paused -or $s.Split.Preview.Starting)
    $busy=$s.Dragging -or $s.Seeking -or $null -ne $s.PendingSeek -or $previewPlaying
    $ready=$s.Clock.Ready -and $s.Handle -ne [IntPtr]::Zero
    $selectedEvents=@($s.List.SelectedItems | Where-Object {$_.Tag.RowKind -ne 'Context'})
    if($s.Buttons.Count -gt 4){
        $positionText=Get-QualityText 'Position at event' 'Posicionar no evento'
        if($s.List.SelectedItems.Count -eq 1 -and $s.List.SelectedItems[0].Tag.RowKind -eq 'Context'){$positionText=Get-QualityText 'Position at context/program' 'Posicionar no contexto/programa'}
        if($s.Buttons[4].Text -ne $positionText){$s.Buttons[4].Text=$positionText}
    }
    for ($i=0; $i -lt $s.Buttons.Count; $i++) {
        $enabled=$ready
        if ($i -eq 0 -and $s.NativeMpv) { $enabled=$s.Clock.Connected }
        if ($i -eq 3) { $enabled=$ready -and $selectedEvents.Count -gt 0 }
        if ($i -eq 4) { $enabled=$ready -and $s.List.SelectedItems.Count -eq 1 }
        if ($i -eq 2) { $enabled=$ready -and (($s.List.SelectedItems.Count -eq 1 -and $selectedEvents.Count -eq 1) -or ($s.List.SelectedItems.Count -eq 0 -and -not [string]::IsNullOrEmpty($s.ActiveAnnotationId))) }
        $enabled=$enabled -and -not $busy
        if ($s.Buttons[$i].Enabled -ne $enabled) { $s.Buttons[$i].Enabled=$enabled }
    }
    if ($null -ne $s.PositionButton) { $s.PositionButton.Enabled=$ready -and -not $busy -and $s.Duration -gt 0 }
    if ($null -ne $s.PlaybackSettingsButton) { $s.PlaybackSettingsButton.Enabled=$ready -and -not $busy }
    if ($null -ne $s.MetadataButton) { $s.MetadataButton.Enabled=$ready -and -not $busy }
    if ($null -ne $s.FilterButton) { $s.FilterButton.Enabled=$ready -and -not $busy }
}
# Refresh playback controls, timeline, annotations and status during the UI loop.
function Update-QualityPanel {
    param($Panel,[switch]$NoPump)
    if (-not $NoPump) { [Windows.Forms.Application]::DoEvents() }
    $s = $Panel.Tag
    if ($Panel.IsDisposed) { Stop-PlaybackProcess $s.Player; return }
    $s.Player.Refresh()
    if ($s.NativeMpv) {
        if ($s.Clock.Failure) { throw ($s.Clock.Failure + [Environment]::NewLine + $s.Session.LogPath) }
        if ($null -ne $s.PauseToConfirm) {
            # Ignore startup pause notifications until the requested state has
            # been confirmed for the loaded media, including after each seek.
            $s.Paused=[bool]$s.PauseToConfirm
            if ($s.Clock.Ready -and $s.Clock.Connected) {
                if (-not $s.Clock.SetPaused($s.Paused,2500)) { throw (Get-QualityText 'Player pause command timed out.' 'O leitor não confirmou o comando de pausa.') }
                $s.PauseToConfirm=$null
            }
        } else { $s.Paused=$s.Clock.Paused }
        if ($s.Clock.Eof) { $s.Ended=$true; $s.Paused=$true }
    }
    if ($s.Handle -eq [IntPtr]::Zero) {
        $s.Handle = [MachiningMonitor.QualityClock]::FindWindow($s.Player.Id)
    }
    if ($s.Handle -ne [IntPtr]::Zero -and -not $s.Embedded) {
        [MachiningMonitor.QualityClock]::Embed($s.Handle,$s.VideoHost.Handle,$s.VideoHost.ClientSize.Width,$s.VideoHost.ClientSize.Height)
        $s.Embedded = $true
        # All pause controls go through the panel, keeping playback state deterministic.
        [void][MachiningMonitor.QualityClock]::EnableWindow($s.Handle, $false)
    }
    $connectionState='{0}/{1}' -f $s.Clock.Connected,$s.Clock.Ready
    if ($s.LastConnectionState -ne $connectionState) {
        Write-QualityDiagnostic $s ('connection-state: '+$connectionState)
        $s.LastConnectionState=$connectionState
    }
    Update-QualityActionAvailability $s
    $s.Slider.Enabled = $s.Duration -gt 0 -and $null -ne $s.Context -and $s.Clock.Ready
    if ($s.RestorePaused -and $s.Clock.Ready -and $s.Handle -ne [IntPtr]::Zero) {
        $s.RestorePaused=$false; Switch-QualityPause $s
    }
    if (-not $s.NativeMpv -and -not $s.Paused -and -not $s.Ended -and $s.Clock.Ready -and $s.Embedded -and $s.Handle -ne [IntPtr]::Zero -and $s.Duration -gt 0 -and
        (Get-QualityPosition $s) -ge ($s.Duration-0.04) -and $null -eq $s.PendingSeek) {
        Switch-QualityPause $s
        $s.Ended=$true
    }
    Update-AdaptivePlotLayout $s
    Update-QualityLabel $s
}
# Update the displayed quality and its corresponding color.
function Update-QualityLabel {
    param($s)
    Update-QualityActionAvailability $s
    Set-PlaybackControlFontLayout $s
    if ($s.Split) { Update-SplitExtractionAvailability $s }
    $position=Get-QualityPosition $s
    if ($null -ne $s.PendingSeek) { $position=[double]$s.PendingSeek }
    $qualityPosition=$position
    if($s.Dragging -and $s.Duration -gt 0){
        $qualityPosition=$s.Duration*$s.Slider.Value/[double]$s.Slider.Maximum
        if($s.TimelineCursorDrag){$qualityPosition=[double]$s.TimelineCursorDragPosition}
    }
    $current=Get-CurrentQuality $s $qualityPosition
    Update-CurrentAnnotationHighlight $s $position
    $value = '0'; if ($null -ne $current) { $value = [string]$current }
    $status = Get-QualityText 'Playing' 'A reproduzir'; if ($s.Paused) { $status = Get-QualityText 'Paused' 'Em pausa' }
    if (-not $s.Clock.Ready) { $status = Get-QualityText 'Waiting for playback...' 'A aguardar reprodução...' }
    if ($s.NativeMpv -and -not $s.Clock.Ready) {
        $status=Get-QualityText 'Connecting to player...' 'A ligar ao leitor...'
        if ($s.Clock.Connected) { $status=Get-QualityText 'Preparing playback...' 'A preparar reprodução...' }
    }
    if ($null -ne $s.PendingSeek -or $s.Seeking) { $status=Get-QualityText 'Seeking...' 'A posicionar...' }
    $action=Get-QualityText 'Pause' 'Pausar'
    $symbol=[string][char]0x23F8
    if ($s.Paused) { $action=Get-QualityText 'Resume' 'Retomar'; $symbol=[string][char]0x25B6 }
    if ($s.PlaybackAction -ne $action) {
        $s.Buttons[0].Text=$symbol
        $s.Buttons[0].AccessibleName=$action
        $s.Tooltip.SetToolTip($s.Buttons[0],$action)
        $s.PlaybackAction=$action
    }
    Update-PlaybackResizeNotice $s
    $broadcast=Get-ApplicationBroadcast
    if($broadcast -and $broadcast.PlaybackState -eq $s -and -not $s.Paused){
        if(-not $broadcast.Config.AnalyzerEnabled -or $broadcast.AnalysisUnavailable -eq 'disabled'){$status=Get-QualityText 'Playing (AI analysis disabled)' 'A reproduzir (análise por IA desativada)'}
        elseif($broadcast.AnalysisUnavailable -eq 'disconnected'){$status=Get-QualityText 'Playing (no connection to AI analysis)' 'A reproduzir (sem ligação à análise por IA)'}
        elseif($broadcast.AnalysisId -and $broadcast.AnalysisId -ne [guid]::Empty){$status=Get-QualityText 'Playing (AI analysis in progress)' 'A reproduzir (análise por IA em curso)'}
    }
    if($broadcast -and $broadcast.Config.AnalyzerEnabled -and $broadcast.PlaybackState -eq $s -and -not $broadcast.AnalysisUnavailable){
        if($broadcast.AnalysisHolding -or $broadcast.AnalysisArmed){$status=Get-QualityText 'Preparing analysis and audio...' 'A preparar análise e áudio...'}
        elseif($broadcast.AnalysisFault){$status=(Get-QualityText 'Analysis paused: ' 'Análise pausada: ')+$broadcast.AnalysisFault}
    }
    $s.Label.Text = '{0} | {1} ({2} s)' -f $status, [TimeSpan]::FromSeconds($position).ToString('hh\:mm\:ss\.fff'), $position.ToString('0.000',[Globalization.CultureInfo]::CurrentCulture)
    $s.TotalLabel.Text=(Get-QualityText 'Total time: ' 'Tempo total: ') + [TimeSpan]::FromSeconds($s.Duration).ToString('hh\:mm\:ss\.fff')
    $s.CurrentQualityLabel.Text='{0}: {1}' -f (Get-QualityText 'Rating' 'Classificação'),(Get-QualityDisplay ([int]$value))
    $s.CurrentQualityLabel.BackColor=Get-QualityColor ([int]$value)
    $foreground=[Drawing.Color]::White
    if ([int]$value -eq 3) { $foreground=[Drawing.Color]::Black }
    if ($s.CurrentQualityLabel.ForeColor -ne $foreground) { $s.CurrentQualityLabel.ForeColor=$foreground }
    $description=Get-QualityMeaning ([int]$value)
    if ($s.QualityDescription -ne $description) {
        $s.Tooltip.SetToolTip($s.CurrentQualityLabel,$description); $s.QualityDescription=$description
    }
    if (-not $s.Dragging -and $s.Duration -gt 0) {
        $s.Slider.Value=[int]([Math]::Min(1.0,[Math]::Max(0.0,$position/$s.Duration))*$s.Slider.Maximum)
    }
    if ($s.Dragging) {
        $target=$s.Duration*$s.Slider.Value/$s.Slider.Maximum
        if($s.TimelineCursorDrag){$target=$s.TimelineCursorDragPosition}
        $s.Label.Text=(Get-QualityText 'Position: ' 'Posição: ') + [TimeSpan]::FromSeconds($target).ToString('hh\:mm\:ss\.fff') + ' (' + $target.ToString('0.000',[Globalization.CultureInfo]::CurrentCulture) + ' s)'
    }
    $parameterPosition=$position
    if ($s.Dragging) { $parameterPosition=$target }
    Update-PlaybackAbsoluteTime $s $parameterPosition
    Update-CurrentMachiningLabels $s $parameterPosition
    Update-PlaybackStatusLayout $s
    # Use the same precise clock sample for the indicator and the moving window.
    # The global slider has integer steps that can represent nearly a second in long recordings.
    $s.TimelinePosition=[double]$parameterPosition
    Update-TimelinePlaybackFollow $s $position
    # The follow helper also repaints when the scale scrolls behind a centered playhead.
    $pixel=[int](Get-TimelineIndicatorX $s)
    if ($null -eq $s.TimelinePixel -or $pixel -ne $s.TimelinePixel) {
        $s.TimelinePixel=$pixel; $s.Timeline.Invalidate()
    }
}

# Display recording wall-clock time for the current relative playback position.
function Update-PlaybackAbsoluteTime {
    param($State,[double]$Seconds)
    if($null -eq $State.AbsoluteTimeLabel){return}
    $display='-'
    if($null -ne $State.RecordingStart){
        $display=$State.RecordingStart.AddSeconds($Seconds).ToString('yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
    }
    $State.AbsoluteTimeLabel.Text=(Get-QualityText 'Date/time: ' 'Data/hora: ')+$display
}
# Format programmed and adjusted machining values for the information labels.
function Get-CurrentMachiningParameterText {
    param($Rate,[string]$Programmed,[string]$Adjusted)
    if ($null -eq $Rate) { return '-' }
    $value=$Rate.$Adjusted
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        $value=$Rate.$Programmed
        if ($null -ne $value -and $null -ne $Rate.AdjustmentPercent) { $value=[double]$value*[double]$Rate.AdjustmentPercent/100 }
    }
    $number=0.0
    if ($null -eq $value -or -not [double]::TryParse([string]$value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { return '-' }
    return $number.ToString('0.##',[Globalization.CultureInfo]::CurrentCulture)
}
# Show the machining parameters inherited by the current playback position.
function Update-CurrentMachiningLabels {
    param($State,[double]$Seconds)
    if ($null -eq $State.SpindleLabel) { return }
    $parameters=Get-AnnotationParameters $State $Seconds
    $active=Get-RecordingContextAt $State.ContextEntries $Seconds
    if($active -and $State.DisplayContextId -ne $active.id){
        $State.DisplayContextId=$active.id
        $State.VideoHost.FindForm().Text=Get-QualityPlaybackTitle (Split-Path $State.Path -Parent) $Seconds $State.ContextEntries
    }
    $rpm=Get-CurrentMachiningParameterText $parameters.SpindleSpeed 'ProgrammedRpm' 'AdjustedRpm'
    $feed=Get-CurrentMachiningParameterText $parameters.FeedRate 'ProgrammedMmPerMin' 'AdjustedMmPerMin'
    $State.SpindleLabel.Text=(Get-QualityText 'Spindle: ' 'Fuso: ')+$rpm+' rpm'
    $State.FeedLabel.Text=(Get-QualityText 'Feed: ' 'Avanço: ')+$feed+' mm/min'
}
# Position playback status labels within the available window width.
function Update-PlaybackStatusLayout {
    param($State)
    if ($null -eq $State.FeedLabel -or $null -eq $State.Label.Parent) { return }
    $right=@($State.SpindleLabel,$State.FeedLabel,$State.CurrentQualityLabel)
    $widths=@($right | ForEach-Object { $_.GetPreferredSize([Drawing.Size]::Empty).Width })
    $groupWidth=20; foreach ($width in $widths) { $groupWidth+=$width }
    $groupLeft=$State.Label.Parent.ClientSize.Width-12-$groupWidth
    $totalWidth=$State.TotalLabel.GetPreferredSize([Drawing.Size]::Empty).Width
    $absoluteWidth=0
    if($null -ne $State.AbsoluteTimeLabel){$absoluteWidth=$State.AbsoluteTimeLabel.GetPreferredSize([Drawing.Size]::Empty).Width+10}
    $statusWidth=[Math]::Max(80,[Math]::Min($State.Label.GetPreferredSize([Drawing.Size]::Empty).Width,$groupLeft-$totalWidth-$absoluteWidth-46))
    $State.Label.AutoSize=$false; $State.Label.AutoEllipsis=$true
    $State.Label.TextAlign='TopLeft'; $State.Label.SetBounds(12,67,$statusWidth,22)
    $State.TotalLabel.AutoSize=$false; $State.TotalLabel.TextAlign='TopLeft'
    $next=22+$statusWidth
    if($null -ne $State.AbsoluteTimeLabel){
        $State.AbsoluteTimeLabel.AutoSize=$false; $State.AbsoluteTimeLabel.AutoEllipsis=$true; $State.AbsoluteTimeLabel.TextAlign='TopLeft'
        $State.AbsoluteTimeLabel.SetBounds($next,67,($absoluteWidth-10),22)
        $next+=$absoluteWidth
    }
    $State.TotalLabel.SetBounds($next,67,$totalWidth,22)
    $x=$groupLeft
    for ($i=0;$i -lt $right.Count;$i++) {
        $right[$i].AutoSize=$false; $right[$i].AutoEllipsis=$true
        $right[$i].TextAlign='TopLeft'
        $height=22
        if ($right[$i] -eq $State.CurrentQualityLabel) { $height=$right[$i].Font.Height }
        # All labels share the same text origin; only the quality background is shorter.
        $right[$i].SetBounds($x,67,$widths[$i],$height)
        $x+=$widths[$i]+10
    }
}

# Cover the playback surface while new graph dimensions are being applied.
function Start-PlaybackResizeNotice {
    param($State)
    if(-not $State.VideoHost){return}
    $window=$State.VideoHost.FindForm()
    if($window -and ($window.WindowState -eq 'Minimized' -or ($window.PSObject.Properties['ResizeSuppressed'] -and $window.ResizeSuppressed))){return}
    $sizeKey=[string]$State.VideoHost.Width+'/'+$State.VideoHost.Height
    $sameSize=$State.LastResizeSurfaceKey -ceq $sizeKey
    $State.LastResizeSurfaceKey=$sizeKey
    if($State.ResizeNoticeLabel -and $sameSize -and -not $State.Viewport.Tag.NoticePending){
        if(-not $State.Context.AdaptivePlots -or ($State.AppliedPlotLayout -ceq (Get-VisualizationRenderKey $State.VideoHost.ClientSize $State.Context.Visualization))){return}
    }
    if(-not $State.ResizeNoticeLabel){
        Initialize-PlainResizeNotice
        $label=New-Object MachiningMonitor.PlainResizeNotice
        $label.Dock='None';$label.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold)
        $label.TextAlign='MiddleCenter';$label.ForeColor=[Drawing.Color]::White
        $label.BackColor=[Drawing.Color]::Black
        $State.Viewport.Controls.Add($label)
        $State.Viewport.Tag.ResizeLayer=$label
        Update-VisualizationMessageLayers $State.Viewport
        $State.ResizeNoticeLabel=$label
    }
    if(Defer-VisualizationResizeNotice $State.Viewport){return}
    $State.ResizeNoticeActive=$true
    Update-VisualizationGrips $State.Viewport
    $State.ResizeNoticeUntil=[DateTime]::UtcNow.AddMilliseconds(350)
    $State.ResizeNoticeLabel.Text=Get-QualityText 'Resizing - please wait...' 'A redimensionar - aguarde...'
    $State.ResizeNoticeLabel.Visible=$true
    $State.ResizeNoticeLabel.BringToFront()
    $State.ResizeNoticeLabel.Refresh()
}
# Keep the resize notice visible until rendering and pending seeks have settled.
function Update-PlaybackResizeNotice {
    param($State)
    if(-not $State.ResizeNoticeActive -or -not $State.ResizeNoticeLabel){return}
    if(Test-VisualizationInteractionActive $State.Viewport){$State.Viewport.Tag.NoticePending=$true;Suspend-VisualizationResizeNotice $State.Viewport;return}
    if($State.Label.FindForm().WindowState -eq 'Minimized'){$State.ResizeNoticeLabel.Visible=$false;return}
    $pending=$false
    if($State.NativeMpv -and $State.Context.AdaptivePlots -and -not $State.Ended){
        $size=$State.VideoHost.ClientSize
        $key=Get-VisualizationRenderKey $size $State.Context.Visualization
        $pending=$State.AppliedPlotLayout -ne $key -or $State.Seeking -or $null -ne $State.PendingSeek -or -not $State.Clock.Connected -or -not $State.Clock.Ready
    }
    $waiting=[DateTime]::UtcNow -lt $State.ResizeNoticeUntil -or $pending
    $resizeForm=$State.VideoHost.FindForm()
    if(-not $waiting -and $resizeForm -and $resizeForm.PSObject.Methods['RevealResizeContent']){$resizeForm.RevealResizeContent()}
    $State.ResizeNoticeLabel.Visible=[bool]$waiting
    if($waiting){$State.ResizeNoticeLabel.BringToFront()}
    if(-not $waiting){$State.ResizeNoticeActive=$false;Update-VisualizationGrips $State.Viewport}
}

# Measure button text and distribute available width while preserving control spacing.
# Version 123 keeps a 1170-pixel initial client width (subject to screen space). Text buttons
# share surplus width, outer margins remain 12 pixels and gaps remain 4 pixels.
# The play/pause button remains 52 x 30; enlarging the form must not inflate its minimum width.
function Set-PlaybackControlFontLayout {
    param($State)
    if(-not $State.Buttons -or -not $State.PositionButton){return}
    $window=$State.PositionButton.FindForm()
    if($window -and ($window.WindowState -eq 'Minimized' -or ($window.PSObject.Properties['ResizeSuppressed'] -and $window.ResizeSuppressed))){return}
    $controls=@($State.Buttons[0],$State.PositionButton,$State.Buttons[4],$State.MetadataButton,$State.Buttons[1],$State.Buttons[2],$State.Buttons[3],$State.FilterButton,$State.PlaybackSettingsButton)
    $minimums=@(52,156,164,116,104,116,124,96,122)
    $widths=New-Object int[] 9
    $required=24;$count=0
    for($i=0;$i -lt $controls.Count;$i++){
        $control=$controls[$i];if(-not $control){continue}
        $widths[$i]=$minimums[$i]
        if($i -ne 0){$widths[$i]=[Math]::Max($widths[$i],([Windows.Forms.TextRenderer]::MeasureText($control.Text,$control.Font)).Width+12)}
        $required+=$widths[$i];$count++
    }
    $required+=4*[Math]::Max(0,$count-1)
    if($count -eq 9){
        $extra=[Math]::Max(0,$State.PositionButton.Parent.ClientSize.Width-$required)
        $share=[int][Math]::Floor($extra/8.0);$remainder=$extra%8
        for($i=1;$i -lt 9;$i++){$widths[$i]+=$share;if($i -le $remainder){$widths[$i]++}}
    }
    $x=12
    for($i=0;$i -lt $controls.Count;$i++){
        $control=$controls[$i];if(-not $control){continue}
        if($control.Left -ne $x -or $control.Width -ne $widths[$i]){$control.SetBounds($x,90,$widths[$i],30)}
        $x+=$widths[$i]+4
    }
    $form=$State.PositionButton.FindForm()
    if($form -and $form.WindowState -eq 'Normal'){
        $minimum=[Math]::Max($State.MinimumWindowSize.Width,$required+($form.Width-$form.ClientSize.Width))
        if($form.MinimumSize.Width -ne $minimum){$form.MinimumSize=New-Object Drawing.Size($minimum,$State.MinimumWindowSize.Height)}
    }
}
# Calculate window height from the monitor's available area and the content layout.
function Set-MonitorWindowHeight {
    param($Form,$State)
    if(-not $Form -or $Form.IsDisposed -or $Form.WindowState -ne 'Normal'){return}
    if($Form.PSObject.Properties['ResizeSuppressed'] -and $Form.ResizeSuppressed){return}
    if($State.DataResizeLayout){Set-PlaybackDataWindowHeight $Form $State;return}
    $area=[Windows.Forms.Screen]::FromControl($Form).WorkingArea
    $available=[Math]::Max(1,$area.Height-24)
    $layout=$Form.Controls[0]
    $rowHeights=$layout.GetRowHeights()
    $fixed=0
    for($i=0;$i -lt $layout.RowStyles.Count;$i++){
        if($layout.RowStyles[$i].SizeType -eq 'Absolute'){$fixed+=$rowHeights[$i]}
    }
    $border=$Form.Height-$Form.ClientSize.Height
    $viewHeaderHeight=0
    if($State.Viewport){foreach($control in $State.Viewport.Parent.Controls){if($control.Dock -eq 'Top'){$viewHeaderHeight+=$control.Height}}}
    $minimumHeight=[Math]::Min($available,$fixed+$border+$viewHeaderHeight+160)
    $State.MinimumWindowSize=New-Object Drawing.Size($State.MinimumWindowSize.Width,$minimumHeight)
    $Form.MinimumSize=New-Object Drawing.Size($Form.MinimumSize.Width,$minimumHeight)
    if($Form.WindowState -eq 'Normal'){
        if($Form.Height -gt $available){$Form.Height=$available}
        $top=[Math]::Max($area.Top+12,[Math]::Min($Form.Top,$area.Bottom-12-$Form.Height))
        if($Form.Top -ne $top){$Form.Top=$top}
    }
}

# Compile the native resize-overlay helper used to cover video during geometry changes.
function Initialize-PlainResizeNotice {
    if('MachiningMonitor.PlainResizeNotice' -as [type]){return}
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition '
using System.Drawing;
using System.Windows.Forms;
namespace MachiningMonitor {
 public sealed class PlainResizeNotice : Label {
  public PlainResizeNotice() {
   SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
  }
  protected override void OnPaint(PaintEventArgs e) {
   e.Graphics.Clear(BackColor);
   TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,ForeColor,
    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
  }
 }
}'
}
