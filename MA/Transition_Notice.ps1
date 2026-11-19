<#
Transition_Notice.ps1 - documented version 123.
Embedded C# wait window. A dedicated STA thread keeps the progress animation responsive while the main thread loads a recording or rebuilds the recording list.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
Implementation guide for the embedded C# helper:
- The constructor starts an STA thread and waits until the form handle is available.
- Run owns the form, marquee progress bar and ApplicationContext message loop.
- Show/Hide marshal work with Invoke because controls belong to the dedicated UI thread.
- Dispose asks that message loop to exit, then briefly waits for the thread to finish.
#>
#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()
if (-not ('MachiningMonitor.TransitionNotice' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;
namespace MachiningMonitor {
 public sealed class TransitionNotice : IDisposable {
  Thread thread; Form form; Label label; ApplicationContext context;
  ManualResetEvent ready=new ManualResetEvent(false);
  Exception error; bool disposed;
  public TransitionNotice() {
   thread=new Thread(Run); thread.IsBackground=true; thread.SetApartmentState(ApartmentState.STA); thread.Start();
   ready.WaitOne();
   if(error!=null) throw new InvalidOperationException("Unable to create wait window.",error);
  }
  void Run() {
   try {
    form=new Form(); form.Text="Machining Monitor"; form.ClientSize=new Size(460,130);
    form.StartPosition=FormStartPosition.CenterScreen; form.FormBorderStyle=FormBorderStyle.FixedDialog;
    form.ControlBox=false; form.ShowInTaskbar=false; form.UseWaitCursor=true;
    label=new Label(); label.SetBounds(20,20,420,52); label.Font=new Font("Segoe UI",11);
    form.Controls.Add(label);
    var progress=new ProgressBar(); progress.SetBounds(20,88,420,20);
    progress.Style=ProgressBarStyle.Marquee; progress.MarqueeAnimationSpeed=20;
    form.Controls.Add(progress);
    context=new ApplicationContext();
    IntPtr handle=form.Handle;
    ready.Set(); Application.Run(context);
   } catch(Exception ex) { error=ex; ready.Set(); }
   finally { if(form!=null) form.Dispose(); }
  }
  public void Show(string text) {
   if(disposed) return;
   form.Invoke((MethodInvoker)delegate { label.Text=text; if(!form.Visible) form.Show(); form.BringToFront(); form.Update(); });
  }
  public void Hide() { if(!disposed) form.Invoke((MethodInvoker)delegate { form.Hide(); }); }
  public void Dispose() {
   if(disposed) return; disposed=true;
   if(form!=null && !form.IsDisposed) form.Invoke((MethodInvoker)delegate { form.Hide(); context.ExitThread(); });
   if(thread!=null && thread.Join(2000)) ready.Dispose();
  }
 }
}
"@
}