# Retain original strings for application comparisons; wrap only displayed text.
if(-not ('MachiningMonitor.WrappingToolTip' -as [type])){
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
 public sealed class WrappingToolTip : ToolTip {
  private readonly Dictionary<Control,string> original = new Dictionary<Control,string>();
  public static string Wrap(string text) {
   if(String.IsNullOrEmpty(text)) return text;
   var result = new List<string>();
   foreach(string source in Regex.Split(text,@"\r\n|\r|\n")) {
    string line=source;
    while(line.Length > 72) {
     int split=line.LastIndexOf(' ',72);
     if(split <= 0) split=72;
     result.Add(line.Substring(0,split).TrimEnd());
     line=line.Substring(split).TrimStart();
    }
    result.Add(line);
   }
   return String.Join(Environment.NewLine,result);
  }
  public new void SetToolTip(Control control,string text) {
   if(text == null) original.Remove(control); else original[control]=text;
   base.SetToolTip(control,Wrap(text));
  }
  public new string GetToolTip(Control control) {
   string text;
   return original.TryGetValue(control,out text) ? text : base.GetToolTip(control);
  }
  public new void Show(string text,IWin32Window window,int x,int y,int duration) {
   base.Show(Wrap(text),window,x,y,duration);
  }
  public new void Show(string text,IWin32Window window) { base.Show(Wrap(text),window); }
  public new void Show(string text,IWin32Window window,int duration) { base.Show(Wrap(text),window,duration); }
  public new void Show(string text,IWin32Window window,System.Drawing.Point point) { base.Show(Wrap(text),window,point); }
  public new void Show(string text,IWin32Window window,System.Drawing.Point point,int duration) { base.Show(Wrap(text),window,point,duration); }
  public new void Show(string text,IWin32Window window,int x,int y) { base.Show(Wrap(text),window,x,y); }
  protected override void Dispose(bool disposing) {
   if(disposing) original.Clear();
   base.Dispose(disposing);
  }
 }
 public static class NativeTooltipLayout {
  [DllImport("user32.dll",EntryPoint="SendMessageW")]
  private static extern IntPtr Send(IntPtr window,int message,IntPtr w,IntPtr l);
  public static void ConfigureList(ListView list) {
   if(list.IsDisposed || !list.IsHandleCreated) return;
   IntPtr tip=Send(list.Handle,0x104e,IntPtr.Zero,IntPtr.Zero);
   if(tip!=IntPtr.Zero) Send(tip,0x418,IntPtr.Zero,new IntPtr(480));
  }
 }
}
'@
}
function Register-ListTooltipLayout {
    param($List)
    if($List.PSObject.Properties['WrappedListTooltip']){return}
    $tip=New-Object MachiningMonitor.WrappingToolTip
    $tip.InitialDelay=200;$tip.ReshowDelay=50;$tip.AutoPopDelay=15000
    $List | Add-Member NoteProperty WrappedListTooltip $tip
    $List | Add-Member NoteProperty WrappedListHoverText ''
    $state=@{Tip=$tip;Text='';Item=$null;SubItem=$null;ShownAt=[datetime]::MinValue}
    # Native ListView infotips can ignore the requested maximum width when
    # expanding truncated subitems. Use the same wrapper as the other controls.
    $List.ShowItemToolTips=$false
    $List.Add_MouseMove({param($sender,$eventArgs)
        if($sender.ShowItemToolTips){$sender.ShowItemToolTips=$false}
        $hit=$sender.HitTest($eventArgs.Location)
        Update-ListTooltipHover $state $sender $hit.Item $hit.SubItem $eventArgs.Location
    }.GetNewClosure())
    $List.Add_MouseLeave({param($sender,$eventArgs)
        $state.Tip.Hide($sender)
        $state.Text='';$state.Item=$null;$state.SubItem=$null;$state.ShownAt=[datetime]::MinValue
    }.GetNewClosure())
    $List.Add_Disposed({$state.Tip.Dispose()}.GetNewClosure())
    if($List.IsHandleCreated){$List.ShowItemToolTips=$false}
}
function Update-ListTooltipHover {
    param($State,$List,$Item,$SubItem,[Drawing.Point]$Point)
    $text=''
    if(Test-ListCellNeedsTooltip $List $Item $SubItem){$text=Get-ListCellTooltipText $Item $SubItem}
    $changed=$State.Text -ne $text -or -not [object]::ReferenceEquals($State.Item,$Item) -or -not [object]::ReferenceEquals($State.SubItem,$SubItem)
    $expired=$text -and ([datetime]::UtcNow-$State.ShownAt).TotalSeconds -ge 15
    if(-not $changed -and -not $expired){return}
    $State.Tip.Hide($List)
    $State.Text=$text;$State.Item=$Item;$State.SubItem=$SubItem
    if($text){
        # Explicit display does not depend on leaving and re-entering the list.
        $State.Tip.Show($text,$List,($Point.X+14),($Point.Y+20),15000)
        $State.ShownAt=[datetime]::UtcNow
    }else{$State.ShownAt=[datetime]::MinValue}
}
function Get-ListCellTooltipText {
    param($Item,$SubItem)
    if(-not $Item){return ''}
    if($Item.ToolTipText){return [string]$Item.ToolTipText}
    if($SubItem){
        if($SubItem.Tag -is [string]){return [string]$SubItem.Tag}
        return [string]$SubItem.Text
    }
    return [string]$Item.Text
}
function Test-ListCellNeedsTooltip {
    param($List,$Item,$SubItem)
    if(-not $Item){return $false}
    $value=if($SubItem){[string]$SubItem.Text}else{[string]$Item.Text}
    if($SubItem -and $SubItem.Tag -is [string] -and $SubItem.Tag -match '[\r\n]'){return $true}
    if($value -match '[\r\n]'){return $true}
    $index=0;if($SubItem){$index=$Item.SubItems.IndexOf($SubItem)}
    if($index -lt 0 -or $index -ge $List.Columns.Count -or -not $value){return $false}
    $width=[Math]::Max(0,$List.Columns[$index].Width-8)
    $size=[Windows.Forms.TextRenderer]::MeasureText($value,$List.Font,[Drawing.Size]::new([int]::MaxValue,[int]::MaxValue),([Windows.Forms.TextFormatFlags]::SingleLine -bor [Windows.Forms.TextFormatFlags]::NoPrefix))
    return $size.Width -gt $width
}
