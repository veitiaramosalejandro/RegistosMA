. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Recording_Selection.ps1 - version 195.
Recording browser. Read metadata for list rows, preserve layout/sorting, and provide folder selection, rename, Explorer and confirmed deletion actions.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
#>
#Requires -Version 5.1
# Dot-source shared helpers into this scope so their functions and script state are available to the caller.
. (Join-Path $PSScriptRoot 'Recording_Header.ps1')
. (Join-Path $PSScriptRoot 'Recording_Duration.ps1')
. (Join-Path $PSScriptRoot 'Recording_Contexts.ps1')
# Compile the native list-scrolling helper once per process.
. (Join-Path $PSScriptRoot 'Deletion_Authorization.ps1')
function Initialize-RecordingListScroll {
    if('MachiningMonitor.RecordingListScroll' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
 public static class RecordingListScroll {
  [DllImport("user32.dll")] static extern int GetScrollPos(IntPtr window,int bar);
  [DllImport("user32.dll")] static extern bool ShowScrollBar(IntPtr window,int bar,bool show);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int w,int h,uint flags);
  [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr window,IntPtr rect,IntPtr region,uint flags);
  public static void ClearUnusedHorizontalBar(IntPtr window) {
   int position=GetScrollPos(window,0);
   if(position!=0) SendMessage(window,0x1014,new IntPtr(-position),IntPtr.Zero);
   ShowScrollBar(window,0,false);
   SetWindowPos(window,IntPtr.Zero,0,0,0,0,0x0001|0x0002|0x0004|0x0010|0x0020);
   RedrawWindow(window,IntPtr.Zero,IntPtr.Zero,0x0001|0x0004|0x0080|0x0100|0x0400);
  }
 }
}
'@
}
# Read an optional object property safely for display.
function Get-DisplayValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '-' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '-' }
    if($Name -in @('Notes','Machine','Work','Operation','Type')){
        $value=([string]$property.Value -replace '[\x00-\x09\x0B\x0C\x0E-\x1F\x7F|]',' ').Trim()
        $value=[regex]::Replace($value,'\r\n|\r|\n',[Environment]::NewLine)
    }else{
        $value = ([string]$property.Value -replace '[\x00-\x1F\x7F|]', ' ').Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return '-' }
    return $value
}

# Format a recording's start time using metadata or its folder information.
function Get-RecordingStartDisplay {
    param($Metadata, [string]$Folder)
    $start = [DateTimeOffset]::MinValue
    if ($null -ne $Metadata -and [DateTimeOffset]::TryParse([string]$Metadata.StartTime,
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$start)) {
        return $start.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    }
    # Recording folder names retain the start time even when context entry was cancelled.
    $folderStart = [datetime]::MinValue
    if ([datetime]::TryParseExact($Folder, 'yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$folderStart)) {
        return $folderStart.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    }
    return '-'
}

# Format the recorded duration for the selection list.
function Get-RecordingDurationDisplay {
    param($Metadata,[string]$Folder)
    if($Folder){
        $actual=Get-RecordedSessionSeconds $Folder
        if($null -ne $actual){$Metadata=[pscustomobject]@{DurationSeconds=$actual.ToString('R',[Globalization.CultureInfo]::InvariantCulture)}}
    }
    if ($null -eq $Metadata) { return '-' }
    $seconds = 0.0
    $valid = [double]::TryParse([string]$Metadata.DurationSeconds, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
    $valid = $valid -and -not [double]::IsNaN($seconds) -and -not [double]::IsInfinity($seconds) -and $seconds -ge 0 -and $seconds -le [TimeSpan]::MaxValue.TotalSeconds
    if (-not $valid) {
        $start = [DateTimeOffset]::MinValue; $end = [DateTimeOffset]::MinValue
        $valid = [DateTimeOffset]::TryParse([string]$Metadata.StartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$start) -and
            [DateTimeOffset]::TryParse([string]$Metadata.EndTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$end) -and $end -ge $start
        if ($valid) { $seconds = ($end - $start).TotalSeconds }
    }
    if (-not $valid) {
        $duration = [TimeSpan]::Zero
        $valid = [TimeSpan]::TryParse([string]$Metadata.Duration, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -and $duration.TotalSeconds -ge 0
        if ($valid) { $seconds = $duration.TotalSeconds }
    }
    if (-not $valid) { return '-' }
    $milliseconds=[long][Math]::Round($seconds*1000,0,[MidpointRounding]::AwayFromZero)
    return ('{0:00}:{1:00}:{2:00}.{3:000}' -f [long][Math]::Floor($milliseconds/3600000.0),[long][Math]::Floor(($milliseconds%3600000)/60000.0),[long][Math]::Floor(($milliseconds%60000)/1000.0),($milliseconds%1000))
}

# Read a recording folder and assemble its display row and associated metadata.
function Get-RecordingRow {
    param([int]$Number, [string]$Folder, [string]$Root)
    $metadata = $null
    $context = $null
    $note = ''
    $recordingFolder = Join-Path $Root $Folder
    $metadataPath = Join-Path $recordingFolder 'metadata.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $metadata -or $metadata -isnot [pscustomobject]) { throw 'Invalid metadata object' }
            $context = $metadata.Context
        } catch { $metadata = $null; $note = ' (invalid metadata)' }
    } else { $note = ' (no metadata)' }
    $mode = 'Unknown'
    if ($script:UiLanguage -eq 'pt') { $mode = 'Desconhecido' }
    if ($null -ne $metadata -and $metadata.Mode -eq 'VIDEO_AUDIO') { $mode = 'Video + audio' }
    elseif ($null -ne $metadata -and $metadata.Mode -eq 'AUDIO') { $mode = 'Audio only' }
    elseif ($null -ne $metadata -and $metadata.Mode -eq 'VIDEO') { $mode = 'Camera only' }
    else {
        $files = @(Get-ChildItem -LiteralPath $recordingFolder -File -ErrorAction Stop)
        if (@($files | Where-Object { $_.Name -match '^video(?:_[0-9]+)?\.mp4$' }).Count) { $mode = 'Video + audio' }
        elseif (@($files | Where-Object { $_.Name -match '^audio(?:_[0-9]+)?\.wav$' }).Count) { $mode = 'Audio only' }
    }
    $contexts=@()
    try{$contexts=@(Read-RecordingContexts $recordingFolder | ForEach-Object {$_.context})}
    catch{$note+=' (contexts.json inválido)'}
    if($contexts.Count){
        $context=Copy-RecordingContextValue $contexts[0]
        foreach($key in @('Machine','Work','Operation','Notes')){
            $separator=[Environment]::NewLine
            $context.$key=(@($contexts | ForEach-Object {$value=Get-DisplayValue $_ $key;if($value -ne '-'){$value}} | Select-Object -Unique) -join $separator)
        }
        $context.Tool.Type=(@($contexts | ForEach-Object {$value=Get-DisplayValue $_.Tool 'Type';if($value -ne '-'){$value}} | Select-Object -Unique) -join [Environment]::NewLine)
    }
    $tool = $null
    if ($null -ne $context) { $tool = $context.Tool }
    $notesDisplay = Get-DisplayValue $context 'Notes'
    $modeDisplay=Get-UiText ($mode+$note)
    $cameraCount=@($metadata.Cameras | Where-Object {$_}).Count
    if($cameraCount -gt 1){$modeDisplay+=' — '+$cameraCount+(Get-SelectionText ' cameras' ' câmaras')}
    return [pscustomobject]@{
        Values = @(
            [string]$Number
            Get-RecordingStartDisplay $metadata $Folder
            Get-RecordingDurationDisplay $metadata $recordingFolder
            Get-DisplayValue $context 'Machine'
            Get-DisplayValue $context 'Work'
            Get-DisplayValue $context 'Operation'
            Get-DisplayValue $tool 'Type'
            $notesDisplay
            $modeDisplay
        )
    }
}

# Choose localized text for the recording-selection interface.
function Get-SelectionText {
    param([string]$English,[string]$Portuguese)
    if ($script:UiLanguage -eq 'pt') { return $Portuguese }
    return $English
}
# Refresh the available recordings and their displayed metadata.
function Update-RecordingSelection {
    param($Form)
    $data=$Form.Tag; $list=$data.List
    $selected=@()
    if ($list.SelectedItems.Count) { $selected=@($list.SelectedItems | ForEach-Object { [string]$_.Tag }) }
    $list.BeginUpdate()
    try {
        $list.Items.Clear(); $data.Open.Enabled=$false; $data.Delete.Enabled=$false; $data.Rename.Enabled=$false; $data.Explore.Enabled=$false
        $folders=@(Get-ChildItem -LiteralPath $data.Root -Directory -ErrorAction Stop | Sort-Object Name)
        $number=0
        foreach ($folder in $folders) {
            $number++
            $row=Get-RecordingRow $number $folder.Name $data.Root
            $item=New-Object Windows.Forms.ListViewItem($folder.Name)
            foreach ($value in $row.Values[@(1,2,3,4,5,6,8,7)]) {
                $cell=$item.SubItems.Add(([string]$value -replace '\r\n|\r|\n',' | '))
                $cell.Tag=[string]$value
            }
            $item.Tag=$folder.FullName
            [void]$list.Items.Add($item)
            if ($folder.FullName -in $selected) { $item.Selected=$true }
        }
        if ($folders.Count) {
            $data.Status.Text=Get-SelectionText 'Select a recording and click Open, or double-click its row.' 'Selecione uma gravação e clique em Abrir, ou faça duplo clique na linha.'
        } else {
            $data.Status.Text=Get-SelectionText 'No recordings found. Click Refresh to check again.' 'Não foram encontradas gravações. Clique em Atualizar para procurar novamente.'
        }
        if ($null -ne $list.ListViewItemSorter) { $list.Sort() }
    } finally { $list.EndUpdate() }
}
# Build the recording browser with selection, sorting, rename and deletion controls.
function New-RecordingSelectionForm {
    param([string]$Root)
    Add-Type -AssemblyName System.Windows.Forms
    $form=New-Object Windows.Forms.Form
    $form.Text=Get-SelectionText 'Machining Monitor - Recording management' 'Machining Monitor - Gestão de gravações'
    $form.ClientSize=New-Object Drawing.Size(1280,620)
    $form.MinimumSize=New-Object Drawing.Size(900,420)
    $form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $header=New-RecordingHeader $form $Root
    $path=$header.PathLabel; $chooseFolder=$header.ChooseFolder
    $language=$header.Language; $applyLanguage=$header.ApplyLanguage
    $list=New-Object Windows.Forms.ListView; Register-ListTooltipLayout $list
    $list.SetBounds(12,44,1256,506); $list.Anchor='Top,Bottom,Left,Right'
    $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$true; $list.AllowColumnReorder=$true
    $list.HideSelection=$false; $list.ShowItemToolTips=$false
    $headers=@('Recording','Start','Duration','Machine','Program','Operation','Tool type','Recording mode','Notes')
    $pt=@('Gravação','Início','Duração','Máquina','Programa','Operação','Tipo de ferramenta','Modo de gravação','Notas')
    $widths=@(140,155,112,100,105,115,120,140,240)
    for ($i=0;$i -lt $headers.Count;$i++) { [void]$list.Columns.Add((Get-SelectionText $headers[$i] $pt[$i]),$widths[$i]) }
    $form.Controls.Add($list)
    $status=New-Object Windows.Forms.Label; $status.SetBounds(12,558,1256,22); $status.Anchor='Bottom,Left,Right'
    $form.Controls.Add($status)
    $open=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $open; $open.Text=Get-SelectionText 'Open recording' 'Abrir gravação'
    $open.SetBounds(532,584,142,28); $open.Anchor='Bottom,Right'; $open.Enabled=$false; $form.Controls.Add($open)
    $refresh=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $refresh; $refresh.Text=Get-SelectionText 'Refresh' 'Atualizar'
    $refresh.SetBounds(682,584,104,28); $refresh.Anchor='Bottom,Right'; $form.Controls.Add($refresh)
    $close=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $close; $close.Text=Get-SelectionText 'Close' 'Fechar'
    $close.SetBounds(1164,584,104,28); $close.Anchor='Bottom,Right'; $close.DialogResult='Cancel'; $form.Controls.Add($close)
    $delete=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $delete
    $delete.SetBounds(1052,584,104,28); $delete.Anchor='Bottom,Right'; $delete.Enabled=$false; $form.Controls.Add($delete)
    $rename=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $rename
    $rename.SetBounds(940,584,104,28); $rename.Anchor='Bottom,Right'; $rename.Enabled=$false; $form.Controls.Add($rename)
    $explore=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $explore
    $explore.SetBounds(794,584,138,28); $explore.Anchor='Bottom,Right'; $explore.Enabled=$false; $form.Controls.Add($explore)
    $open.TabIndex=10; $refresh.TabIndex=11; $explore.TabIndex=12; $rename.TabIndex=13; $delete.TabIndex=14; $close.TabIndex=15
    $form.CancelButton=$close; $form.AcceptButton=$open
    $form.Tag=@{Root=$Root;List=$list;Open=$open;Delete=$delete;Rename=$rename;Explore=$explore;Refresh=$refresh;Close=$close;Language=$language;ApplyLanguage=$applyLanguage;Status=$status;SelectedPath=$null;SortColumn=-1;Descending=$false;NotesMinimum=180;Fitting=$false}
    $form.Tag.PathLabel=$path; $form.Tag.ChooseFolder=$chooseFolder
    if((Get-Command Get-ApplicationBroadcast -ErrorAction SilentlyContinue) -and (Get-ApplicationBroadcast)){Add-ApplicationBroadcastControls $form}
    $chooseFolder.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        try {
            $root=Get-RecordingsDirectory -Graphical -Choose -Owner $d -CurrentPath $d.Tag.Root
            if ([string]::IsNullOrWhiteSpace($root)) { return }
            Set-RecordingSelectionRoot $d $root
        } catch { [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
    })
    $list.Add_SelectedIndexChanged({param($sender,$eventArgs) $data=$sender.FindForm().Tag; $enabled=$sender.SelectedItems.Count -eq 1; $data.Open.Enabled=$enabled; $data.Delete.Enabled=$sender.SelectedItems.Count -gt 0; $data.Rename.Enabled=$enabled; $data.Explore.Enabled=$enabled })
    $open.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        if ($d.Tag.List.SelectedItems.Count -ne 1) { return }
        $path=[string]$d.Tag.List.SelectedItems[0].Tag
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            [void][Windows.Forms.MessageBox]::Show($d,(Get-SelectionText 'Recording folder no longer exists. Refresh the list.' 'A pasta da gravação já não existe. Atualize a lista.'),$d.Text)
            return
        }
        $d.Tag.SelectedPath=$path; $d.DialogResult='OK'
    })
    $list.Add_DoubleClick({param($sender,$eventArgs) if ($sender.SelectedItems.Count -eq 1) { $sender.FindForm().Tag.Open.PerformClick() } })
    $refresh.Add_Click({
        param($sender,$eventArgs)
        try { Update-RecordingSelection $sender.FindForm() }
        catch { [void][Windows.Forms.MessageBox]::Show($sender.FindForm(),$_.Exception.Message) }
    })
    $language.Add_SelectedIndexChanged({
        param($sender,$eventArgs)
        Update-SelectedLanguageButton $sender.FindForm()
    })
    $applyLanguage.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        try {
            $language=@('pt','en')[$d.Tag.Language.SelectedIndex]
            Save-RecordingSelectionLanguage $language
            Update-RecordingSelectionLanguage $d
            Update-RecordingSelection $d
        } catch { [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
    })
    $delete.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        if ($d.Tag.List.SelectedItems.Count -eq 0) { return }
        try {
            $paths=@($d.Tag.List.SelectedItems | ForEach-Object { [string]$_.Tag })
            if (Remove-SelectedRecordings $d $paths) { Update-RecordingSelection $d }
        } catch { Update-RecordingSelection $d; [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
    })
    $explore.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        if ($d.Tag.List.SelectedItems.Count -ne 1) { return }
        try { Open-RecordingFolder ([string]$d.Tag.List.SelectedItems[0].Tag) }
        catch { [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
    })
    $rename.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        if ($d.Tag.List.SelectedItems.Count -ne 1) { return }
        $dialog=$null
        try {
            $dialog=New-RecordingRenameForm $d.Tag.Root ([string]$d.Tag.List.SelectedItems[0].Tag)
            if ($dialog.ShowDialog($d) -eq [Windows.Forms.DialogResult]::OK) {
                $newPath=$dialog.Tag.NewPath
                Update-RecordingSelection $d
                foreach ($item in $d.Tag.List.Items) {
                    if ([string]::Equals([string]$item.Tag,$newPath,[StringComparison]::OrdinalIgnoreCase)) {
                        $item.Selected=$true; $item.Focused=$true; $item.EnsureVisible(); break
                    }
                }
            }
        } catch { [void][Windows.Forms.MessageBox]::Show($d,$_.Exception.Message,$d.Text) }
        finally { if ($null -ne $dialog) { $dialog.Dispose() } }
    })
    Restore-RecordingListLayout $form
    # Keep internal column indices stable for sorting and saved widths.
    # Apply after preferences so existing installations also move mode to the end.
    $list.Columns[7].DisplayIndex=$list.Columns.Count-1
    Initialize-RecordingListScroll
    $fitTimer=New-Object Windows.Forms.Timer; $fitTimer.Interval=80; $fitTimer.Tag=$form
    $form.Tag.FitTimer=$fitTimer
    $fitTimer.Add_Tick({
        $this.Stop(); $d=$this.Tag
        if(-not $d.IsDisposed -and $d.WindowState -ne 'Minimized'){
            Fit-RecordingNotesColumn $d.Tag.List -RefreshScrollbars
        }
    })
    $form.Add_Disposed({if($this.Tag.FitTimer){$this.Tag.FitTimer.Stop();$this.Tag.FitTimer.Dispose()}})
    $form.Add_SizeChanged({Queue-RecordingListFit $this.Tag.List})
    $form.Add_ResizeEnd({Queue-RecordingListFit $this.Tag.List})
    $form.Add_Shown({Queue-RecordingListFit $this.Tag.List})
    $list.Add_ClientSizeChanged({param($sender,$eventArgs) Queue-RecordingListFit $sender })
    $list.Add_ColumnWidthChanging({
        param($sender,$eventArgs)
        $d=$sender.FindForm(); if($null -eq $d -or $null -eq $d.Tag -or $d.Tag.Fitting){return}
        # Only a user drag changes the preferred minimum, never automatic fitting.
        if($eventArgs.ColumnIndex -eq 8){$d.Tag.NotesMinimum=[Math]::Max(180,$eventArgs.NewWidth)}
    })
    $list.Add_ColumnWidthChanged({
        param($sender,$eventArgs)
        $d=$sender.FindForm(); if ($null -eq $d -or $null -eq $d.Tag -or $d.Tag.Fitting) { return }
        Fit-RecordingNotesColumn $sender
        Queue-RecordingListFit $sender
    })
    $list.Add_ColumnClick({param($sender,$eventArgs) Set-RecordingListSort $sender.FindForm() $eventArgs.Column })
    $form.Add_FormClosing({
        param($sender,$eventArgs)
        try { Save-RecordingListLayout $sender }
        catch { [void][Windows.Forms.MessageBox]::Show($sender,$_.Exception.Message,$sender.Text) }
    })
    Fit-RecordingNotesColumn $list
    Update-RecordingSelectionLanguage $form
    Set-RecordingListSort $form 0
    try { Update-RecordingSelection $form } catch { $form.Dispose(); throw }
    return $form
}
# Show the recording browser and return the chosen folder or a cancellation result.
function Restore-OpenedRecordingSelection {
    param($Form,[string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return}
    $list=$Form.Tag.List
    foreach($item in $list.Items){
        if([string]::Equals([string]$item.Tag,$Path,[StringComparison]::OrdinalIgnoreCase)){
            $list.SelectedItems.Clear()
            $item.Selected=$true;$item.Focused=$true
            $item.EnsureVisible();[void]$list.Focus()
            return
        }
    }
}
function Select-RecordingGraphically {
    param([string]$Root,$TransitionNotice,[ref]$CurrentRoot,[string]$SelectedRecording)
    $form=New-RecordingSelectionForm $Root
    $form.Tag.ReturnSelectionPath=$SelectedRecording
    $form.Add_Shown({param($sender,$eventArgs) Restore-OpenedRecordingSelection $sender $sender.Tag.ReturnSelectionPath})
    if ($null -ne $TransitionNotice) {
        $form.Tag.TransitionNotice=$TransitionNotice
        $form.Add_Shown({param($sender,$eventArgs) $sender.Tag.TransitionNotice.Hide() })
    }
    try {
        if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { return $form.Tag.SelectedPath }
        return $null
    } finally {
        if($null -ne $CurrentRoot){$CurrentRoot.Value=$form.Tag.Root}
        $form.Dispose()
    }
}
# Change the browser's root folder and reload its recording list.
function Set-RecordingSelectionRoot {
    param($Form,[string]$Root)
    $Form.Tag.Root=$Root
    $Form.Tag.PathLabel.Text=$Root
    $Form.Tag.SelectedPath=$null
    $Form.Tag.List.SelectedItems.Clear()
    Update-RecordingSelection $Form
    Queue-RecordingListFit $Form.Tag.List
}
# Persist the language chosen in the recording browser.
function Save-RecordingSelectionLanguage {
    param([ValidateSet('pt','en')][string]$Language)
    $config=[pscustomobject]@{}
    if (Test-Path -LiteralPath $script:UiConfigPath) {
        $config=Get-Content -LiteralPath $script:UiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -isnot [pscustomobject]) { throw 'Invalid config.json / config.json inválido.' }
    }
    $config | Add-Member NoteProperty Language $Language -Force
    [IO.File]::WriteAllText($script:UiConfigPath,(Format-UiJson ($config | ConvertTo-Json -Depth 20 -Compress))+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
    $script:UiLanguage=$Language
    Set-UiCulture
}
# Refresh browser labels after changing the selected language.
function Update-RecordingSelectionLanguage {
    param($Form)
    $data=$Form.Tag
    $Form.Text=Get-SelectionText 'Machining Monitor - Recording management' 'Machining Monitor - Gestão de gravações'
    $en=@('Recording','Start','Duration','Machine','Program','Operation','Tool type','Recording mode','Notes')
    $pt=@('Gravação','Início','Duração','Máquina','Programa','Operação','Tipo de ferramenta','Modo de gravação','Notas')
    for ($i=0; $i -lt $en.Count; $i++) { $data.List.Columns[$i].Text=Get-SelectionText $en[$i] $pt[$i] }
    $data.Open.Text=Get-SelectionText 'Open recording' 'Abrir gravação'
    $data.Rename.Text=Get-SelectionText 'Rename' 'Renomear'
    $data.Delete.Text=Get-SelectionText 'Delete' 'Eliminar'
    $data.Refresh.Text=Get-SelectionText 'Refresh' 'Atualizar'
    $data.ChooseFolder.Text=Get-SelectionText 'Choose folder...' 'Escolher pasta…'
    $data.Explore.Text=Get-SelectionText 'Open folder' 'Abrir pasta'
    $data.Close.Text=Get-SelectionText 'Close' 'Fechar'
    if($data.BroadcastSettings){Update-ApplicationBroadcast}
    Update-SelectedLanguageButton $Form
    Update-RecordingSortIndicator $Form
}
# Resolve and validate a recording folder before allowing deletion.
function Get-RecordingDeletionTarget {
    param([string]$Root,[string]$Path)
    $rootItem=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    $target=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $rootFull=[IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\','/')
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($target.FullName).TrimEnd('\','/'))
    if (-not $rootItem.PSIsContainer -or -not $target.PSIsContainer -or -not [string]::Equals($rootFull,$parent,[StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-SelectionText 'Only a recording directly inside the recordings folder can be deleted.' 'Só pode eliminar uma gravação diretamente dentro da pasta de gravações.')
    }
    # Refuse links/junctions before recursively removing anything.
    foreach ($item in @($rootItem,$target)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Get-SelectionText 'Linked folders cannot be deleted here.' 'Não é possível eliminar pastas com ligações nesta janela.') }
    }
    $pending=New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue($target.FullName)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Get-SelectionText 'The recording contains a linked file or folder and cannot be deleted here.' 'A gravação contém um ficheiro ou pasta com ligação e não pode ser eliminada nesta janela.') }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
        }
    }
    return $target.FullName
}
# Ask the operator to confirm deleting one recording folder.
function Confirm-RecordingDeletion {
    param($Form,[string]$Path)
    $text=Get-SelectionText ("Permanently delete this recording and all its files?"+[Environment]::NewLine+[Environment]::NewLine+$Path) ("Eliminar definitivamente esta gravação e todos os seus ficheiros?"+[Environment]::NewLine+[Environment]::NewLine+$Path)
    if(-not ([Windows.Forms.MessageBox]::Show($Form,$text,(Get-SelectionText 'Delete recording' 'Eliminar gravação'),[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2) -eq [Windows.Forms.DialogResult]::Yes)){return $false}
    return Confirm-DeletionAuthorization $Form 'Eliminar gravação'
}
# Delete a validated recording after confirmation and refresh the list.
function Remove-SelectedRecording {
    param($Form,[string]$Path)
    $target=Get-RecordingDeletionTarget $Form.Tag.Root $Path
    if (-not (Confirm-RecordingDeletion $Form $target)) { return $false }
    # Recheck the exact absolute target after the confirmation dialog.
    $target=Get-RecordingDeletionTarget $Form.Tag.Root $target
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    return $true
}

# Defer list-column fitting until pending UI layout work has completed.
function Queue-RecordingListFit {
    param($List)
    $form=$List.FindForm()
    if($null -eq $form -or $null -eq $form.Tag -or $form.Tag.Fitting -or $form.IsDisposed -or -not $form.Tag.FitTimer){return}
    $form.Tag.FitTimer.Stop(); $form.Tag.FitTimer.Start()
}
# Use remaining list width for notes and optionally refresh native scrollbars.
function Fit-RecordingNotesColumn {
    param($List,[switch]$RefreshScrollbars)
    $form=$List.FindForm()
    if ($List.Columns.Count -ne 9 -or $null -eq $form -or $null -eq $form.Tag -or $form.Tag.Fitting) { return }
    $form.Tag.Fitting=$true
    try {
        $used=0; for ($i=0;$i -lt 8;$i++) { $used+=$List.Columns[$i].Width }
        $width=[Math]::Max($form.Tag.NotesMinimum,$List.ClientSize.Width-$used-4)
        if ($List.Columns[8].Width -ne $width) { $List.Columns[8].Width=$width }
        if($RefreshScrollbars -and $List.IsHandleCreated -and ($used+$List.Columns[8].Width) -le $List.ClientSize.Width){
            [MachiningMonitor.RecordingListScroll]::ClearUnusedHorizontalBar($List.Handle)
        }
    } finally { $form.Tag.Fitting=$false }
}
# Validate the proposed name and rename the selected recording folder.
function Rename-SelectedRecording {
    param([string]$Root,[string]$Path,[string]$Name)
    $rootItem=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    $target=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $rootFull=[IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\','/')
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($target.FullName).TrimEnd('\','/'))
    if (-not $rootItem.PSIsContainer -or -not $target.PSIsContainer -or
        -not [string]::Equals($rootFull,$parent,[StringComparison]::OrdinalIgnoreCase) -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($target.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw (Get-SelectionText 'Select a recording directly inside the recordings folder.' 'Selecione uma gravação diretamente dentro da pasta de gravações.')
    }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 255 -or
        $Name -match '[<>:"/\\|?*\x00-\x1F]' -or $Name -match '[ .]$' -or
        $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)' -or $Name -in @('.','..')) {
        throw (Get-SelectionText 'Enter a valid folder name, without path separators, reserved names, or trailing spaces/dots.' 'Introduza um nome de pasta válido, sem separadores de caminho, nomes reservados ou espaços/pontos no fim.')
    }
    $destination=[IO.Path]::GetFullPath((Join-Path $rootFull $Name))
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($destination),$rootFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-SelectionText 'The recording must remain in the same folder.' 'A gravação deve permanecer na mesma pasta.')
    }
    if ([string]::Equals($target.Name,$Name,[StringComparison]::Ordinal)) { return $target.FullName }
    if ((Test-Path -LiteralPath $destination) -and -not [string]::Equals($target.FullName,$destination,[StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-SelectionText 'A recording or file with that name already exists. Choose another name.' 'Já existe uma gravação ou ficheiro com esse nome. Escolha outro nome.')
    }
    Rename-Item -LiteralPath $target.FullName -NewName $Name -ErrorAction Stop
    return $destination
}
# Create the dialog used to enter a new recording-folder name.
function New-RecordingRenameForm {
    param([string]$Root,[string]$Path)
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text=Get-SelectionText 'Rename recording' 'Renomear gravação'
    $dialog.ClientSize=New-Object Drawing.Size(520,156); $dialog.StartPosition='CenterParent'
    $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $dialog.Font=New-Object Drawing.Font('Segoe UI',10)
    $label=New-Object Windows.Forms.Label
    $label.Text=Get-SelectionText 'Recording folder name' 'Nome da pasta da gravação'
    $label.SetBounds(12,12,496,24); $dialog.Controls.Add($label)
    $name=New-Object Windows.Forms.TextBox; $name.MaxLength=255
    $name.Text=[IO.Path]::GetFileName($Path.TrimEnd('\','/')); $name.SetBounds(12,42,496,28); $dialog.Controls.Add($name)
    $errorLabel=New-Object Windows.Forms.Label; $errorLabel.ForeColor=[Drawing.Color]::Firebrick
    $errorLabel.SetBounds(12,76,496,36); $dialog.Controls.Add($errorLabel)
    $save=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $save; $save.Text=Get-SelectionText 'Rename' 'Renomear'
    $save.SetBounds(288,116,104,28); $dialog.Controls.Add($save)
    $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel; $cancel.Text=Get-SelectionText 'Cancel' 'Cancelar'
    $cancel.SetBounds(404,116,104,28); $cancel.DialogResult='Cancel'; $dialog.Controls.Add($cancel)
    $dialog.AcceptButton=$save; $dialog.CancelButton=$cancel
    $dialog.Tag=@{Root=$Root;Path=$Path;Name=$name;ErrorLabel=$errorLabel;NewPath=$null;Save=$save}
    $dialog.Add_Shown({param($sender,$eventArgs) $sender.Tag.Name.SelectAll(); $sender.Tag.Name.Focus() })
    $save.Add_Click({
        param($sender,$eventArgs)
        $d=$sender.FindForm()
        try {
            $d.Tag.NewPath=Rename-SelectedRecording $d.Tag.Root $d.Tag.Path $d.Tag.Name.Text
            $d.DialogResult='OK'
        } catch { $d.Tag.ErrorLabel.Text=$_.Exception.Message }
    })
    return $dialog
}
# Apply sorting for the selected recording-list column.
function Set-RecordingListSort {
    param($Form,[int]$Column)
    if (-not ('MachiningMonitor.RecordingComparerV165' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections;
using System.Globalization;
using System.Windows.Forms;
namespace MachiningMonitor {
 public class RecordingComparerV165 : IComparer {
  public int Column; public bool Descending;
  public RecordingComparerV165(int column, bool descending) { Column=column; Descending=descending; }
  double Number(string text) {
   double n; if(Column==2) {
    string[] p=text.Split(':');
    if(p.Length==3) { double h,m,s; if(double.TryParse(p[0],NumberStyles.Float,CultureInfo.InvariantCulture,out h)&&double.TryParse(p[1],NumberStyles.Float,CultureInfo.InvariantCulture,out m)&&double.TryParse(p[2],NumberStyles.Float,CultureInfo.InvariantCulture,out s)) return h*3600+m*60+s; }
   }
   return double.TryParse(text,NumberStyles.Float,CultureInfo.InvariantCulture,out n)?n:double.NegativeInfinity;
  }
  public int Compare(object x, object y) {
   ListViewItem a=(ListViewItem)x,b=(ListViewItem)y;
   string av=a.SubItems[Column].Text,bv=b.SubItems[Column].Text;
   int r=(Column==2)?Number(av).CompareTo(Number(bv)):StringComparer.CurrentCultureIgnoreCase.Compare(av,bv);
   if(r==0) r=StringComparer.OrdinalIgnoreCase.Compare((string)a.Tag,(string)b.Tag);
   return Descending?-Math.Sign(r):Math.Sign(r);
  }
 }
}
"@
    }
    $data=$Form.Tag
    if ($data.SortColumn -eq $Column) { $data.Descending=-not $data.Descending } else { $data.SortColumn=$Column; $data.Descending=$false }
    $data.List.ListViewItemSorter=New-Object MachiningMonitor.RecordingComparerV165($Column,[bool]$data.Descending)
    $data.List.Sort()
    Update-RecordingSortIndicator $Form
}
# Locate the saved recording-browser layout preferences.
function Get-RecordingListLayoutPath {
    return (Join-Path $PSScriptRoot 'recording_list.json')
}
# Restore saved browser column widths, ordering and sorting preferences.
function Restore-RecordingListLayout {
    param($Form)
    $path=Get-RecordingListLayoutPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $layout=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $w=0; $h=0
        if ([int]::TryParse([string]$layout.WindowWidth,[ref]$w) -and [int]::TryParse([string]$layout.WindowHeight,[ref]$h) -and $w -ge 900 -and $h -ge 420) {
            $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $Form.Size=New-Object Drawing.Size(([Math]::Max(900,[Math]::Min($w,$area.Width))),([Math]::Max(420,[Math]::Min($h,$area.Height))))
            if ($layout.WindowMaximized -eq $true) { $Form.WindowState='Maximized' }
        }
        $storedWidths=@($layout.Widths)
        $order=@($layout.DisplayIndices)
        $legacy=$storedWidths.Count -eq 10
        if ($legacy) { $storedWidths=@($storedWidths[1..9]) }
        if ($storedWidths.Count -ne 9) { return }
        $widths=@()
        foreach ($width in $storedWidths) {
            $n=0
            if (-not [int]::TryParse([string]$width,[ref]$n) -or $n -lt 24 -or $n -gt 5000) { return }
            $widths+=$n
        }
        for ($i=0;$i -lt 9;$i++) { $Form.Tag.List.Columns[$i].Width=$widths[$i] }
        $durationWidth=[Windows.Forms.TextRenderer]::MeasureText('00:00:00.000',$Form.Tag.List.Font).Width+12
        $Form.Tag.List.Columns[2].Width=[Math]::Max($Form.Tag.List.Columns[2].Width,$durationWidth)
        $count=9; if ($legacy) { $count=10 }
        if ($order.Count -eq $count) {
            $indices=@(); $valid=$true
            foreach ($value in $order) {
                $index=0
                if (-not [int]::TryParse([string]$value,[ref]$index) -or $index -lt 0 -or $index -ge $count) { $valid=$false; break }
                $indices+=$index
            }
            if ($valid -and @($indices | Select-Object -Unique).Count -eq $count) {
                if ($legacy) {
                    $removed=$indices[0]
                    $indices=@($indices[1..9] | ForEach-Object { if ($_ -gt $removed) { $_-1 } else { $_ } })
                }
                foreach ($i in (0..8 | Sort-Object { $indices[$_] })) { $Form.Tag.List.Columns[$i].DisplayIndex=$indices[$i] }
            }
        }
        $minimum=180
        if ($layout.NotesMinimumVersion -eq 2 -and [int]::TryParse([string]$layout.NotesMinimum,[ref]$minimum) -and $minimum -ge 180 -and $minimum -le 5000) { $Form.Tag.NotesMinimum=$minimum }
    } catch { } # A missing/invalid layout uses defaults without affecting recordings.
}
# Persist the browser's current column layout and sort state.
function Save-RecordingListLayout {
    param($Form)
    $size=$Form.Size
    if ($Form.WindowState -ne [Windows.Forms.FormWindowState]::Normal) { $size=$Form.RestoreBounds.Size }
    $layout=[pscustomobject]@{WindowWidth=$size.Width;WindowHeight=$size.Height;WindowMaximized=($Form.WindowState -eq [Windows.Forms.FormWindowState]::Maximized);Widths=@($Form.Tag.List.Columns | ForEach-Object { $_.Width });NotesMinimum=$Form.Tag.NotesMinimum;NotesMinimumVersion=2;DisplayIndices=@($Form.Tag.List.Columns | ForEach-Object { $_.DisplayIndex })}
    $path=Get-RecordingListLayoutPath
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($layout | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
# Ask the operator to confirm deletion of multiple recording folders.
function Confirm-RecordingsDeletion {
    param($Form,[string[]]$Paths)
    $text=Get-SelectionText ("Permanently delete the selected recordings and all their files?") ("Eliminar definitivamente as gravações selecionadas e todos os seus ficheiros?")
    $text+=[Environment]::NewLine+[Environment]::NewLine+($Paths -join [Environment]::NewLine)
    if(-not ([Windows.Forms.MessageBox]::Show($Form,$text,(Get-SelectionText 'Delete recordings' 'Eliminar gravações'),[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2) -eq [Windows.Forms.DialogResult]::Yes)){return $false}
    return Confirm-DeletionAuthorization $Form 'Eliminar gravações'
}
# Delete the confirmed, validated selections and refresh the recording browser.
function Remove-SelectedRecordings {
    param($Form,[string[]]$Paths)
    if ($Paths.Count -eq 0) { return $false }
    $targets=@($Paths | Select-Object -Unique | ForEach-Object { Get-RecordingDeletionTarget $Form.Tag.Root $_ })
    if (-not (Confirm-RecordingsDeletion $Form $targets)) { return $false }
    # Validate the entire selection again after confirmation, before any deletion.
    $targets=@($targets | ForEach-Object { Get-RecordingDeletionTarget $Form.Tag.Root $_ })
    foreach ($target in $targets) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
    return $true
}

# Refresh the column-header indicator for the active sort direction.
function Update-RecordingSortIndicator {
    param($Form)
    $data=$Form.Tag
    for ($i=0;$i -lt $data.List.Columns.Count;$i++) {
        $header=$data.List.Columns[$i]
        $text=$header.Text -replace ' [▲▼]$',''
        if ($i -eq $data.SortColumn) {
            if ($data.Descending) { $text+=' ▼' } else { $text+=' ▲' }
        }
        $header.Text=$text
    }
}

# Open the selected recording folder in Windows Explorer.
function Open-RecordingFolder {
    param([string]$Path)
    $folder=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $folder.PSIsContainer) { throw (Get-SelectionText 'Recording folder not found.' 'Pasta da gravação não encontrada.') }
    # Explorer must be visible: this is the interactive window explicitly requested by the user.
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"'+$folder.FullName+'"') -ErrorAction Stop
}

# Refresh the language-application control to match the current selection.
function Update-SelectedLanguageButton {
    param($Form)
    if ($Form.Tag.Language.SelectedIndex -eq 1) { $Form.Tag.ApplyLanguage.Text='Apply' }
    else { $Form.Tag.ApplyLanguage.Text='Aplicar' }
}
