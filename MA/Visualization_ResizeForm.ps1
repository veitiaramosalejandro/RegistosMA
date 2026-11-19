Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if(-not ('MachiningMonitor.MediaResizeForm' -as [type])){
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
namespace MachiningMonitor {
 public class MediaResizeForm : System.Windows.Forms.Form {
  public System.Windows.Forms.Control ResizeSurface { get; set; }
  public System.Windows.Forms.Control ResizeOverlay { get; set; }
  public bool InteractiveResize { get; private set; }
  private bool resizeDeferred;
  public event System.EventHandler ResizeStarting;
  private bool covering;
  private bool suppressGeometry;
  private System.Drawing.Size usableSize;
  [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool IsIconic(System.IntPtr window);
  public bool ResizeSuppressed { get { return suppressGeometry || WindowState==System.Windows.Forms.FormWindowState.Minimized || (IsHandleCreated && IsIconic(Handle)); } }
  private readonly System.Collections.Generic.Dictionary<System.IntPtr,uint> hiddenWindows = new System.Collections.Generic.Dictionary<System.IntPtr,uint>();
  [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
  private struct CoverWindowPosition { public System.IntPtr hwnd, after; public int x,y,cx,cy; public uint flags; }
  private delegate bool CoverEnumProc(System.IntPtr window,System.IntPtr data);
  [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumChildWindows(System.IntPtr parent,CoverEnumProc callback,System.IntPtr data);
  [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr GetParent(System.IntPtr window);
  [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(System.IntPtr window,out uint process);
  [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ShowWindowAsync(System.IntPtr window,int command);
  [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ShowWindow(System.IntPtr window,int command);
  protected override void OnResizeBegin(System.EventArgs e) {
   InteractiveResize=true;
   RevealResizeContent();
   if(ResizeOverlay!=null) ResizeOverlay.Visible=false;
   base.OnResizeBegin(e);
  }
  protected override void OnResizeEnd(System.EventArgs e) {
   InteractiveResize=false;
   base.OnResizeEnd(e);
   if(resizeDeferred){resizeDeferred=false;CoverResizeContent();}
  }
  public void CoverResizeContent() {
   if(ResizeSuppressed) return;
   if(InteractiveResize || (System.Windows.Forms.Control.MouseButtons & System.Windows.Forms.MouseButtons.Left)!=0){resizeDeferred=true;return;}
   if(covering || ResizeSurface==null || ResizeOverlay==null || ResizeSurface.IsDisposed || ResizeOverlay.IsDisposed) return;
   covering=true;
   try {
    if(ResizeStarting!=null) ResizeStarting(this,System.EventArgs.Empty);
    if(!ResizeOverlay.Visible)return;
    var parent=ResizeSurface.Handle;
    EnumChildWindows(parent,(window,data)=> {
     if(GetParent(window)==parent && System.Windows.Forms.Control.FromHandle(window)==null) {
      uint process; GetWindowThreadProcessId(window,out process);
      hiddenWindows[window]=process; ShowWindow(window,0);
     } return true;
    },System.IntPtr.Zero);
    ResizeOverlay.BringToFront(); ResizeOverlay.Refresh();
   } finally {covering=false;}
  }
  public void RevealResizeContent() {
   foreach(var item in hiddenWindows) {
    uint process; GetWindowThreadProcessId(item.Key,out process);
    if(process==item.Value) ShowWindowAsync(item.Key,4);
   }
   hiddenWindows.Clear();
  }
  protected override void SetBoundsCore(int x,int y,int width,int height,System.Windows.Forms.BoundsSpecified specified) {
   if(!ResizeSuppressed && (width!=Width || height!=Height)) CoverResizeContent();
   base.SetBoundsCore(x,y,width,height,specified);
  }
  protected override void SetClientSizeCore(int width,int height) {
   if(!ResizeSuppressed && (width!=ClientSize.Width || height!=ClientSize.Height)) CoverResizeContent();
   base.SetClientSizeCore(width,height);
  }
  protected override void WndProc(ref System.Windows.Forms.Message message) {
   long command=message.Msg==0x112 ? message.WParam.ToInt64() & 0xfff0 : 0;
   bool restore=command==0xf120 && (WindowState==System.Windows.Forms.FormWindowState.Minimized || (IsHandleCreated && IsIconic(Handle)));
   bool bypass=command==0xf020 || restore || (message.Msg==5 && message.WParam.ToInt64()==1) || ResizeSuppressed;
   bool previous=suppressGeometry;
   if(bypass)suppressGeometry=true;
   var before=usableSize;
   try {
   bool changing=false;
   if(message.Msg==0x46 && message.LParam!=System.IntPtr.Zero) {
    var position=(CoverWindowPosition)System.Runtime.InteropServices.Marshal.PtrToStructure(message.LParam,typeof(CoverWindowPosition));
    changing=(position.flags & 1)==0 && (position.cx!=Width || position.cy!=Height);
   }
   if(message.Msg==0x112) {
    changing=command==0xf030 || command==0xf120;
   }
   // Cover before base processes the geometry and lays out native video children.
   if(changing) CoverResizeContent();
   base.WndProc(ref message);
   } finally {suppressGeometry=previous;}
   if(restore && ClientSize!=before && before.Width>0 && before.Height>0)CoverResizeContent();
   if(!ResizeSuppressed && ClientSize.Width>0 && ClientSize.Height>0)usableSize=ClientSize;
  }

  public MediaResizeForm() { DoubleBuffered=true; }
  protected override System.Windows.Forms.CreateParams CreateParams {
   get { var p=base.CreateParams; p.Style |= 0x02000000; return p; }
  }
 }
 public sealed class StablePlaybackForm : MediaResizeForm { }
 public sealed class RecordingResizeForm : MediaResizeForm { }
}
'@
}
