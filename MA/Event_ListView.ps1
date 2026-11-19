# Reconcile native event-list scroll ranges after Windows finishes a resize.
function Initialize-EventListScrollHelper {
    if('MachiningMonitor.EventListScroll' -as [type]){return}
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace MachiningMonitor {
 public sealed class StableEventListView : ListView {
  private bool queued;
  private bool repairing;
  private bool revealSelectionAfterResize;
  private bool recreatingForScroll;
  private bool previouslyScrollable;
  [DllImport("user32.dll",EntryPoint="GetWindowLongW")] private static extern int GetStyle(IntPtr h,int index);
  private bool HasVerticalScroll {get{return IsHandleCreated && (GetStyle(Handle,-16)&0x200000)!=0;}}
  private void ResetVanishedVerticalScroll() {
   bool current=HasVerticalScroll;
   if(previouslyScrollable && !current && Items.Count>0) {
    // Native top-index can already be zero while row pixel origins still carry
    // the old bottom scroll offset. Rebuilding this handle resets BOTH caches.
    var selected=new ListViewItem[SelectedItems.Count];SelectedItems.CopyTo(selected,0);
    var focused=FocusedItem;
    recreatingForScroll=true;
    try {
     RecreateHandle();
     foreach(var item in selected) if(item.ListView==this) item.Selected=true;
     if(focused!=null && focused.ListView==this) focused.Focused=true;
     TopItem=Items[0];
    } finally {recreatingForScroll=false;}
    current=HasVerticalScroll;
   }
   previouslyScrollable=current;
  }
  private readonly Timer settleTimer;
  public StableEventListView() {
   DoubleBuffered=true;
   SetStyle(ControlStyles.ResizeRedraw,true);
   settleTimer=new Timer(); settleTimer.Interval=100;
   settleTimer.Tick+=(sender,args)=>{
    settleTimer.Stop();RepairVisibleRows();
    if(revealSelectionAfterResize){
     revealSelectionAfterResize=false;
     var selected=FocusedItem;
     if(selected==null || !selected.Selected) selected=SelectedItems.Count>0?SelectedItems[0]:null;
     if(selected!=null){selected.EnsureVisible();RepairVisibleRows();}
    }
   };
  }
  public void QueueRowRefresh() {
   if(IsDisposed || Disposing || !IsHandleCreated || recreatingForScroll) return;
   if(settleTimer!=null){settleTimer.Stop();settleTimer.Start();}
   if(queued) return;
   queued=true;
   BeginInvoke((MethodInvoker)(()=>{
    queued=false;
    if(!IsDisposed && !Disposing && IsHandleCreated) RepairVisibleRows();
   }));
  }
  public void RepairVisibleRows() {
   if(repairing || IsDisposed || Disposing || !IsHandleCreated || !Visible) return;
   repairing=true;
   try {
    ResetVanishedVerticalScroll();
    // Invalidate native ITEM caches, not only the surrounding window background.
    if(Items.Count>0) RedrawItems(0,Items.Count-1,true);
    Invalidate(true);
    Update();
   } finally {repairing=false;}
  }
  protected override void OnClientSizeChanged(EventArgs e) {revealSelectionAfterResize=true;if(HasVerticalScroll)previouslyScrollable=true;base.OnClientSizeChanged(e);QueueRowRefresh();}
  protected override void OnVisibleChanged(EventArgs e) {base.OnVisibleChanged(e);if(Visible)QueueRowRefresh();}
  protected override void OnHandleCreated(EventArgs e) {base.OnHandleCreated(e);QueueRowRefresh();}
  protected override void Dispose(bool disposing) {
   if(disposing && settleTimer!=null){settleTimer.Stop();settleTimer.Dispose();}
   base.Dispose(disposing);
  }
 }

 public static class EventListScroll {
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h,int m,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] static extern int GetScrollPos(IntPtr h,int bar);
  [DllImport("user32.dll")] static extern bool ShowScrollBar(IntPtr h,int bar,bool show);
  [DllImport("user32.dll",EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr h,int index);
  [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr h,IntPtr rect,IntPtr region,uint flags);
  public static bool HorizontalVisible(ListView list) {return (GetWindowLong(list.Handle,-16)&0x100000)!=0;}
  public static void Refresh(ListView list,int width) {
   if(list.IsDisposed || !list.IsHandleCreated || list.Columns.Count==0) return;
   int last=list.Columns.Count-1;
   if(SendMessage(list.Handle,0x101d,new IntPtr(last),IntPtr.Zero).ToInt32()!=width)
    SendMessage(list.Handle,0x101e,new IntPtr(last),new IntPtr(width));
   int total=0; foreach(ColumnHeader column in list.Columns) total+=column.Width;
   if(total<=list.ClientSize.Width) {
    int position=GetScrollPos(list.Handle,0);
    if(position!=0) SendMessage(list.Handle,0x1014,new IntPtr(-position),IntPtr.Zero);
    if(HorizontalVisible(list)) ShowScrollBar(list.Handle,0,false);
   }
   // Native buffering prevents exposed rows from being left blank while their host moves.
   SendMessage(list.Handle,0x1036,new IntPtr(0x10000),new IntPtr(0x10000));
   // Expanding a list scrolled near its end can leave a stale native top index.
   int count=list.Items.Count;
   int page=Math.Max(1,SendMessage(list.Handle,0x1028,IntPtr.Zero,IntPtr.Zero).ToInt32());
   int top=SendMessage(list.Handle,0x1027,IntPtr.Zero,IntPtr.Zero).ToInt32();
   int maximum=Math.Max(0,count-page);
   if(count>0 && top>maximum) list.TopItem=list.Items[maximum];
   // Invalidate and erase the ENTIRE client and header after native scroll reconciliation.
   RedrawWindow(list.Handle,IntPtr.Zero,IntPtr.Zero,0x585);
   var stable=list as StableEventListView;
   if(stable!=null) stable.QueueRowRefresh();
   list.Invalidate(true);
   list.Update();
  }
 }
}
'@
}
# Version 204. Coalesce redraws until the layout/scroll ranges have settled.
function Request-EventColumnFit {
    param($List)
    if(-not $List -or $List.IsDisposed -or -not $List.IsHandleCreated){return}
    $layout=$List.EventColumnLayout
    if(-not $layout -or $layout.Fitting -or $layout.FitQueued){return}
    $layout.FitQueued=$true
    [void]$List.BeginInvoke([Action[object]]{
        param($control)
        if($control.IsDisposed){return}
        $control.EventColumnLayout.FitQueued=$false
        Fit-ObservationsColumn $control -RefreshScroll
    },[object[]]@($List))
}
