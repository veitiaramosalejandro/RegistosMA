# Track packets from the actual external-audio input, independently of video progress.
if(-not ('MachiningMonitor.LiveSources284' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
namespace MachiningMonitor {
 public sealed class LiveSources284 : IDisposable {
  readonly object gate=new object();
  readonly Stopwatch clock=Stopwatch.StartNew();
  readonly StreamReader reader;
  readonly Thread thread;
  readonly int audioInput;
  readonly double[] lastVideo;
  long packets,videoPackets; double lastAudio; bool completed,outputHeader;int outputWidth,outputHeight;
  static readonly Regex OutputVideo=new Regex(@"Video:.*?\b(\d{2,5})x(\d{2,5})(?:[, \[]|$)",RegexOptions.Compiled);
  public int OutputWidth {get{lock(gate)return outputWidth;}}
  public int OutputHeight {get{lock(gate)return outputHeight;}}
  static readonly Regex Packet=new Regex(@"demuxer -> ist_index:(\d+):\d+ type:(audio|video)(?:\s|$)",RegexOptions.Compiled);
  public long Packets {get{lock(gate)return packets;}}
  public long VideoPackets {get{lock(gate)return videoPackets;}}
  public double MaxVideoIdleSeconds {get{lock(gate){double result=0;foreach(double last in lastVideo)result=Math.Max(result,clock.Elapsed.TotalSeconds-last);return result;}}}
  public double IdleSeconds {get{lock(gate)return Math.Max(0,clock.Elapsed.TotalSeconds-lastAudio);}}
  public bool Completed {get{lock(gate)return completed;}}
  public LiveSources284(StreamReader input,int inputIndex){
   reader=input;audioInput=inputIndex;lastVideo=new double[inputIndex];thread=new Thread(Read);thread.IsBackground=true;thread.Start();
  }
  void Read(){
   try {
    string line;
    while((line=reader.ReadLine())!=null){
     if(line.Contains("Output #0"))outputHeader=true;
     if(outputHeader){Match size=OutputVideo.Match(line);if(size.Success){lock(gate){outputWidth=int.Parse(size.Groups[1].Value);outputHeight=int.Parse(size.Groups[2].Value);}}}
     Match m=Packet.Match(line);
     if(m.Success){
      if(m.Groups[2].Value=="video"){int index=int.Parse(m.Groups[1].Value);if(index<lastVideo.Length){lock(gate){videoPackets++;lastVideo[index]=clock.Elapsed.TotalSeconds;}}}
      else if(int.Parse(m.Groups[1].Value)==audioInput){lock(gate){packets++;lastAudio=clock.Elapsed.TotalSeconds;}}
     }
    }
   }catch(IOException){}catch(ObjectDisposedException){}
   finally{lock(gate)completed=true;}
  }
  public void Dispose(){
   if(!thread.Join(1000)){reader.Dispose();thread.Join(1000);}
   clock.Stop();
  }
 }
}
'@
}
function Set-RecordingLiveAudioTrace {
    param([object[]]$Items)
    $itemsCopy=@($Items)
    $index=[Array]::IndexOf($itemsCopy,'-loglevel')
    if($index -ge 0){$itemsCopy[$index+1]='verbose'}else{$itemsCopy=@('-loglevel','verbose')+$itemsCopy}
    return @('-debug_ts')+$itemsCopy
}
function Test-RecordingLiveAudioStalled {
    param($Source,$Monitor,[bool]$WaitingForImage,[double]$TimeoutSeconds=10)
    return $Source -and $Source.Type -in @('RTSP','Local') -and $Monitor -and -not $WaitingForImage -and $Monitor.IdleSeconds -gt $TimeoutSeconds
}
