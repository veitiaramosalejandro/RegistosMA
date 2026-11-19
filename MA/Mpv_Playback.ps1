<#
Mpv_Playback.ps1 - documented version 123.
Native mpv playback integration. An embedded C# controller uses named-pipe JSON IPC to observe playback time, pause and readiness and to control rendering.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Compile the named-pipe mpv controller and native embedding helpers once per process.
# The embedded controller separates IPC writing from state updates using locks.
# Its reader observes mpv properties asynchronously; the UI reads snapshots of time/readiness.
# Request identifiers match synchronous replies to commands. Dispose ends the IPC session.
# ResizeEmbedded only moves child windows owned by the expected player process.
function Initialize-MpvController {
    if ('MachiningMonitor.AdaptiveMpvController' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
 public static class PlaybackMatroskaPipe {
  public static async Task CopyAsync(Stream input, Stream output) {
   byte[] header=new byte[4];int count=0;
   while(count<header.Length) { int read=await input.ReadAsync(header,count,header.Length-count).ConfigureAwait(false);if(read==0)break;count+=read; }
   if(count!=4 || header[0]!=0x1a || header[1]!=0x45 || header[2]!=0xdf || header[3]!=0xa3)
    throw new IOException("O FFmpeg não forneceu o cabeçalho Matroska esperado. Bytes iniciais: "+BitConverter.ToString(header,0,count));
   await output.WriteAsync(header,0,header.Length).ConfigureAwait(false);
   await input.CopyToAsync(output).ConfigureAwait(false);
  }
 }
 public sealed class AdaptiveMpvController : IDisposable {
  private delegate bool EnumWindowProc(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr data);
  [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr window);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] private static extern bool MoveWindow(IntPtr window, int x, int y, int width, int height, bool repaint);
  public static void ResizeEmbedded(IntPtr parent, int process, int width, int height) {
   if(width <= 0 || height <= 0) return;
   EnumChildWindows(parent, (window, data) => { uint id; GetWindowThreadProcessId(window,out id);
    if(id == process && GetParent(window) == parent) MoveWindow(window,0,0,width,height,true);
    return true;
   }, IntPtr.Zero);
  }
  private readonly object gate = new object(); private readonly object output = new object();
  private NamedPipeClientStream pipe; private StreamWriter writer;
  private double seconds, initialSeconds; private bool haveOrigin; private bool loaded, haveTime, paused = true, eof, disposed, connected;
  private string failure; private long samples;
  private int requestId; private readonly Dictionary<int,string> replies = new Dictionary<int,string>();
  public Task Reader;
  public double Seconds { get { lock(gate) return Math.Max(0,seconds-initialSeconds); } }
  public double InitialSeconds { get { lock(gate) return initialSeconds; } }
  public bool Ready { get { lock(gate) return loaded && haveTime && haveOrigin; } }
  public bool Connected { get { lock(gate) return connected && !disposed; } }
  public bool Paused { get { lock(gate) return paused; } }
  public bool Eof { get { lock(gate) return eof; } }
  public long Samples { get { lock(gate) return samples; } }
  public string Failure { get { lock(gate) return failure; } }
  public void Start(string name) {
   Reader = Task.Run(() => {
    try {
     pipe = new NamedPipeClientStream(".",name,PipeDirection.InOut,PipeOptions.Asynchronous);
     pipe.Connect(15000);
     writer = new StreamWriter(pipe,new UTF8Encoding(false),4096,true); writer.AutoFlush = true;
     lock(gate) connected=true;
     Command("observe_property",1,"time-pos"); Command("observe_property",2,"pause");
     Command("observe_property",3,"eof-reached"); Command("observe_property",4,"path");
     var input = new StreamReader(pipe,new UTF8Encoding(false),false,4096,true);
     var json = new JavaScriptSerializer(); string line;
     while((line=input.ReadLine()) != null) {
      var message=json.Deserialize<Dictionary<string,object>>(line);
      object replyId, replyError;
      if(message.TryGetValue("request_id",out replyId) && message.TryGetValue("error",out replyError)) {
       if(Convert.ToInt32(replyId) == -1) {
        object position;
        if(Convert.ToString(replyError) == "success" && message.TryGetValue("data",out position) && position != null) {
         lock(gate) { if(!haveOrigin) { initialSeconds=Convert.ToDouble(position,System.Globalization.CultureInfo.InvariantCulture); haveOrigin=true; } }
        }
       } else { lock(gate) replies[Convert.ToInt32(replyId)] = Convert.ToString(replyError); }
      }
      object kind; if(!message.TryGetValue("event",out kind)) continue;
      if((string)kind == "playback-restart" && !haveOrigin) {
       // time-pos can first report a provisional zero before the first image
       // is presented. Calibrate only after mpv completes startup/preroll.
       lock(output) writer.WriteLine(new JavaScriptSerializer().Serialize(new { command=new object[] {"get_property","time-pos"}, request_id=-1 }));
      }
      if((string)kind == "file-loaded") { lock(gate) loaded=true; }
      if((string)kind == "property-change") {
       object data, property;
       if(!message.TryGetValue("name",out property) || !message.TryGetValue("data",out data) || data == null) continue;
       lock(gate) {
        switch((string)property) {
         case "time-pos": seconds=Convert.ToDouble(data,System.Globalization.CultureInfo.InvariantCulture); haveTime=true; loaded=true; samples++; break;
         case "pause": paused=Convert.ToBoolean(data); break;
         case "eof-reached": eof=Convert.ToBoolean(data); break;
         case "path": loaded=true; break;
        }
       }
      }
     }
    } catch(Exception error) { lock(gate) { if(!disposed) failure=error.Message; } }
   });
  }
  public void Command(params object[] args) {
   lock(output) {
    if(writer == null) throw new InvalidOperationException("Player control is not connected.");
    writer.WriteLine(new JavaScriptSerializer().Serialize(new { command=args }));
   }
  }
  public bool SetPaused(bool value, int timeoutMs) {
   int id=Interlocked.Increment(ref requestId);
   lock(output) {
    if(writer == null) throw new InvalidOperationException("Player control is not connected.");
    writer.WriteLine(new JavaScriptSerializer().Serialize(new { command=new object[] {"set_property","pause",value}, request_id=id }));
   }
   var watch=System.Diagnostics.Stopwatch.StartNew();
   while(watch.ElapsedMilliseconds < timeoutMs) {
    if(Failure != null) throw new IOException(Failure);
    lock(gate) {
     string result;
     if(replies.TryGetValue(id,out result)) {
      replies.Remove(id);
      if(result != "success") throw new IOException("Player pause command: "+result);
      // Acknowledge this command rather than accepting a cached startup value.
      paused=value; return true;
     }
    }
    Thread.Sleep(10);
   } return false;
  }
  public bool SetVideoFilter(string value, int timeoutMs) {
   int id=Interlocked.Increment(ref requestId);
   lock(output) {
    if(writer == null) throw new InvalidOperationException("Player control is not connected.");
    writer.WriteLine(new JavaScriptSerializer().Serialize(new { command=new object[] {"vf","set",value}, request_id=id }));
   }
   var watch=System.Diagnostics.Stopwatch.StartNew();
   while(watch.ElapsedMilliseconds < timeoutMs) {
    if(Failure != null) throw new IOException(Failure);
    lock(gate) { string result; if(replies.TryGetValue(id,out result)) {
     replies.Remove(id); if(result != "success") throw new IOException("Player layout: "+result); return true;
    } }
    Thread.Sleep(10);
   } return false;
  }
  public void Dispose() { lock(gate) disposed=true; if(pipe != null) pipe.Dispose(); }
 }
}
'@
}
# Adjust native mpv graph rendering to the current playback surface dimensions.
function Set-NativePlotRendering {
    param($Context,$Size)
    $parameters=@{}; foreach ($key in $Context.Visualization.Keys) { $parameters[$key]=$Context.Visualization[$key] }
    $parameters.CanvasWidth=$Size.Width; $parameters.CanvasHeight=$Size.Height
    $Context.UnfilteredItems=@(Get-VisualizationArguments @parameters)
    $Context.ProducerItems=@(Set-VibrationArguments $Context.UnfilteredItems $Context.Vibration)
    $Context.NativePlotKey=Get-VisualizationRenderKey $Size $Context.Visualization
}
# Apply graph layout changes when the playback surface has been resized.
function Update-AdaptivePlotLayout {
    param($State)
    $window=$State.VideoHost.FindForm()
    if($window -and ($window.WindowState -eq 'Minimized' -or ($window.PSObject.Properties['ResizeSuppressed'] -and $window.ResizeSuppressed))){return}
    if ((Test-VisualizationInteractionActive $State.Viewport) -or -not $State.NativeMpv -or -not $State.Context.AdaptivePlots -or -not $State.Clock.Ready -or -not $State.Clock.Connected) { return }
    $size=$State.VideoHost.ClientSize
    if ($size.Width -le 0 -or $size.Height -le 0) { return }
    $key=Get-VisualizationRenderKey $size $State.Context.Visualization
    if ($State.AppliedPlotLayout -eq $key) { return }
    if ($State.PendingPlotLayout -ne $key) { $State.PendingPlotLayout=$key; $State.PlotResizeAt=[DateTime]::UtcNow; return }
    if (([DateTime]::UtcNow-$State.PlotResizeAt).TotalMilliseconds -lt 350 -or $State.Seeking -or $null -ne $State.PendingSeek -or $State.Dragging) { return }
    Set-NativePlotRendering $State.Context $size
    $State.AppliedPlotLayout=$key
    Request-QualitySeek $State ([Math]::Min((Get-QualityPosition $State),[Math]::Max(0,$State.Duration-0.101)))
}
# Start mpv with IPC control at the requested playback position and pause state.
function Start-MpvPlayback {
    param($Context,[double]$Seconds,[bool]$Paused)
    Initialize-MpvController
    $session=@{Player=$null; Producer=$null; Copy=$null; InputClosed=$false; BaseSeconds=$Seconds; Controller=$null; Embedded=$true; LogPath=$null;ProducerErrors=$null;ProducerLogPath=$null}
    try {
        $items=@($Context.ProducerItems)
        if ($Context.Direct) {
            $args=@($Context.PlayerItems); $index=[Array]::IndexOf($args,'-i')
            $items=@('-nostdin','-loglevel','error')
            if ($args -contains 'concat') { $items+=@('-f','concat','-safe','0') }
            $items+=@('-i',$args[$index+1],'-map','0:v:0?','-map','0:a:0?',
                '-c:v','libx264','-preset','ultrafast','-c:a','pcm_s16le','-f','matroska','pipe:1')
        }
        $pipeName='ma-player-'+[guid]::NewGuid().ToString('N')
        $session.LogPath=Join-Path ([IO.Path]::GetTempPath()) ($pipeName+'.log')
        $session.ProducerLogPath=Join-Path ([IO.Path]::GetTempPath()) ($pipeName+'-ffmpeg.log')
        $pauseOption='yes'; if (-not $Paused) { $pauseOption='no' }
        $options=@('--no-config','--load-scripts=no','--terminal=no','--osc=no','--osd-level=0',
            '--input-default-bindings=no','--input-vo-keyboard=no','--input-cursor=no',
            '--force-window=yes','--keep-open=always','--keep-open-pause=yes','--loop-file=no','--loop-playlist=no',
            '--audio-display=no','--hwdec=no','--vo=gpu','--gpu-api=d3d11','--demuxer=lavf','--demuxer-lavf-format=matroska',
            ('--log-file='+$session.LogPath),('--pause='+$pauseOption),('--wid='+$Context.WindowHandle.ToInt64()),('--input-ipc-server='+$pipeName),'-')
        if ($Context.AdaptivePlots) { $options=@('--video-unscaled=yes')+$options }
        $session.Player=Start-PlaybackProcess $Context.PlayerExe $options -PipeInput
        $session.Controller=New-Object MachiningMonitor.AdaptiveMpvController
        $session.Controller.Start($pipeName)
        $output=@(Get-SeekProducerArguments $items $Seconds -FastSeek)
        if ($Context.Duration -gt 0) {
            $remaining=[Math]::Max(0.001,[double]$Context.Duration-$Seconds).ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
            $output=@($output[0..($output.Count-2)])+@('-t',$remaining,$output[-1])
        }
        $session.Producer=Start-PlaybackProcess $Context.ProducerExe $output -PipeOutput -QualityClock
        $session.ProducerErrors=$session.Producer.StandardError.ReadToEndAsync()
        [IO.File]::WriteAllText($session.ProducerLogPath,('FFmpeg: '+$Context.ProducerExe+[Environment]::NewLine+'Arguments: '+(Join-PlaybackArguments $output)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($true)))
        $session.Copy=[MachiningMonitor.PlaybackMatroskaPipe]::CopyAsync($session.Producer.StandardOutput.BaseStream,$session.Player.StandardInput.BaseStream)
        return $session
    } catch { Stop-QualityPlayback $session; throw }
}
# Attach the mpv process, controller and initial pause state to the playback UI state.
function Attach-MpvPlayback {
    param($State,$Session,[bool]$Paused)
    Set-ApplicationBroadcastPlayer $State $Session
    $State.Session=$Session; $State.Player=$Session.Player; $State.Clock=$Session.Controller
    $State.BaseSeconds=$Session.BaseSeconds; $State.Handle=$State.VideoHost.Handle
    $State.Embedded=$true; $State.Paused=$Paused; $State.RestorePaused=$false; $State.Ended=$false
    $State.NativeMpv=$true
    $State.AppliedPlotLayout=$State.Context.NativePlotKey; $State.PendingPlotLayout=$null
    $State.PauseToConfirm=$Paused
    foreach ($button in $State.Buttons) { $button.Enabled=$false }
    $State.Slider.Enabled=$false
}
