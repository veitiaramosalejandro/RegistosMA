<#
Recording_Log.ps1 - version 168.
Embedded C# capture-log monitor. A background reader parses FFmpeg packets; a timer detects missing streams and emits status records. Locks protect shared state and RTSP credentials are redacted.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the current behavior.
Implementation guide for the embedded C# helper:
- CaptureLog164 starts a background stderr reader and a 250 ms watchdog timer.
- Track keeps packet counts, arrival times and source timestamps for each expected stream.
- ProcessLine reports first packets, resumed streams and missing/jumping timestamps.
- DTS is preferred over PTS because B-frame presentation order can legitimately differ.
- Check emits stall warnings and periodic heartbeats; packet traces are not stored verbatim.
- A shared lock serializes reader/timer access. Write records I/O failure instead of throwing
  from the background thread. Finish writes totals; Complete/Dispose stop monitoring.
#>
#Requires -Version 5.1
if (-not ('MachiningMonitor.CaptureLog164' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Globalization;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Collections.Generic;
namespace MachiningMonitor {
 public sealed class CaptureLog164 : IDisposable {
  sealed class OutputTrack {public double First,Seconds;}
  readonly Dictionary<int,OutputTrack> recordedOutputs=new Dictionary<int,OutputTrack>();
  sealed class Track {
   public string Name; public long Count; public double LastArrival,FirstArrival,FirstClock,LastClock;
   public bool HaveClock,Missing; public double LastAlert=-100000;
  }
  readonly object gate=new object(); readonly Stopwatch clock=Stopwatch.StartNew();
  readonly Dictionary<string,Track> tracks=new Dictionary<string,Track>();
  readonly StreamWriter writer; readonly StreamReader reader; readonly Thread thread; readonly Timer timer;
  readonly double timeout,heartbeat; double lastHeartbeat; bool closed; long warnings; string failure;
  public string Failure { get { lock(gate) return failure; } }
  public double ExternalAudioIdleSeconds { get { lock(gate) {
   Track track; if(!tracks.TryGetValue(cameraCount+":audio",out track))return clock.Elapsed.TotalSeconds;
   return track.Count==0 ? clock.Elapsed.TotalSeconds : Math.Max(0,clock.Elapsed.TotalSeconds-track.LastArrival);
  } } }
  readonly int cameraCount;
  readonly bool externalAudio;
  bool mediaReady; double mediaSeconds,firstMediaPts; DateTime mediaStart;
  double lastMediaArrival,displaySeconds,displayUpdatedAt;
  public bool Ready { get { lock(gate) return mediaReady; } }
  public double Seconds { get { lock(gate) return mediaSeconds; } }
  public double MinimumOutputSeconds { get { lock(gate) {
   double result=double.MaxValue;
   for(int i=0;i<cameraCount+(externalAudio?1:0);i++){OutputTrack output;if(!recordedOutputs.TryGetValue(i,out output))return 0;result=Math.Min(result,output.Seconds);}
   return result==double.MaxValue?0:result;
  } } }
  public double DisplaySeconds { get { lock(gate) {
   if(!mediaReady)return 0;
   if(closed)return mediaSeconds;
   AdvanceDisplay(clock.Elapsed.TotalSeconds);return displaySeconds;
  } } }
  void AdvanceDisplay(double now) {
   // Do not re-anchor to each packet: network/decoder batches would repeatedly
   // stop or reset the display. Freeze only after a real lack of output.
   double until=Math.Min(now,lastMediaArrival+Math.Min(timeout,2.0));
   displaySeconds+=Math.Max(0,until-displayUpdatedAt);displayUpdatedAt=now;
  }
  public DateTime StartTime { get { lock(gate) return mediaStart; } }
  static readonly Regex OutputVideo=new Regex(@"\[vost#0:\d+[^\]]*\].*?muxer <- .*?pts_time:(\S+).*?duration_time:(\S+)",RegexOptions.Compiled);
  static readonly Regex OutputAudio=new Regex(@"\[aost#0:\d+[^\]]*\].*?muxer <- .*?pts_time:(\S+).*?duration_time:(\S+)",RegexOptions.Compiled);
  static readonly Regex Packet=new Regex(@"demuxer -> ist_index:(\d+):(\d+) type:(video|audio).*?pkt_pts_time:(\S+).*?pkt_dts_time:(\S+)",RegexOptions.Compiled);
  static readonly Regex RecordedOutput=new Regex(@"\[(vost|aost)#(\d+):\d+[^\]]*\].*?muxer <- .*?pts_time:(\S+).*?duration_time:(\S+)",RegexOptions.Compiled);
  public CaptureLog164(StreamReader input,string path,int cameras,double stallSeconds,double heartbeatSeconds):this(input,path,cameras,stallSeconds,heartbeatSeconds,true){}
  public CaptureLog164(StreamReader input,string path,int cameras,double stallSeconds,double heartbeatSeconds,bool expectExternalAudio) {
   cameraCount=cameras;
   externalAudio=expectExternalAudio;
   reader=input; timeout=stallSeconds; heartbeat=heartbeatSeconds;
   writer=new StreamWriter(path,false,new UTF8Encoding(false)); writer.AutoFlush=true;
   for(int i=0;i<cameras;i++) tracks[i+":video"]=new Track{Name="camera_"+(i+1)+"_video"};
   if(externalAudio)tracks[cameras+":audio"]=new Track{Name="external_audio"};
   Write("START","version=164; stall_seconds="+timeout+"; heartbeat_seconds="+heartbeat+"; timestamp_jump_seconds=5; raw_packet_trace=off");
   thread=new Thread(Read); thread.IsBackground=true; thread.Start();
   timer=new Timer(Check,null,250,250);
  }
  void Write(string kind,string text) {
   if(failure!=null) return;
   try { writer.WriteLine(DateTimeOffset.Now.ToString("o")+" elapsed="+clock.Elapsed.TotalSeconds.ToString("F3",CultureInfo.InvariantCulture)+" ["+kind+"] "+text); } catch(Exception ex) { failure=ex.Message; }
  }
  static bool Number(string text,out double n) {
   return double.TryParse(text,NumberStyles.Float,CultureInfo.InvariantCulture,out n) && !double.IsNaN(n) && !double.IsInfinity(n);
  }
  public void ProcessLine(string line) {
   lock(gate) {
    if(closed) return;
    Match recorded=RecordedOutput.Match(line);
    if(recorded.Success){
     int index=int.Parse(recorded.Groups[2].Value,CultureInfo.InvariantCulture);
     bool wanted=(recorded.Groups[1].Value=="vost" && index<cameraCount)||(externalAudio && recorded.Groups[1].Value=="aost" && index==cameraCount);
     double pts,duration;
     if(wanted && Number(recorded.Groups[3].Value,out pts)){
      if(!Number(recorded.Groups[4].Value,out duration))duration=0;
      OutputTrack trackOutput;if(!recordedOutputs.TryGetValue(index,out trackOutput)){trackOutput=new OutputTrack{First=pts};recordedOutputs[index]=trackOutput;}
      trackOutput.Seconds=Math.Max(trackOutput.Seconds,Math.Max(0,pts-trackOutput.First+Math.Max(0,duration)));
     }
    }
    Match output=(cameraCount>0?OutputVideo:OutputAudio).Match(line);
    if(output.Success) {
     double pts,duration;
     if(Number(output.Groups[1].Value,out pts)) {
      if(!Number(output.Groups[2].Value,out duration)) duration=0;
      if(mediaReady)AdvanceDisplay(clock.Elapsed.TotalSeconds);
      if(!mediaReady) {firstMediaPts=pts;mediaStart=DateTime.Now;displayUpdatedAt=clock.Elapsed.TotalSeconds;mediaReady=true;Write("CAPTURE_READY","first_output_pts="+pts.ToString("F6",CultureInfo.InvariantCulture));}
      mediaSeconds=Math.Max(mediaSeconds,Math.Max(0,pts-firstMediaPts+Math.Max(0,duration)));
      lastMediaArrival=clock.Elapsed.TotalSeconds;
     }
    }
    Match m=Packet.Match(line);
    if(m.Success) {
     Track t; string key=m.Groups[1].Value+":"+m.Groups[3].Value;
     if(!tracks.TryGetValue(key,out t)) return;
     double now=clock.Elapsed.TotalSeconds;
     if(t.Missing) { Write("STREAM_RESUMED",t.Name+"; silence_seconds="+(now-t.LastArrival).ToString("F3",CultureInfo.InvariantCulture)); t.Missing=false; }
     if(t.Count==0) { t.FirstArrival=now; Write("FIRST_PACKET",t.Name+"; stream="+m.Groups[1].Value+":"+m.Groups[2].Value); }
     t.Count++; t.LastArrival=now;
     double pts,dts; bool havePts=Number(m.Groups[4].Value,out pts), haveDts=Number(m.Groups[5].Value,out dts);
     if(!havePts || !haveDts) {
      if(now-t.LastAlert>=1) { warnings++; Write("TIMESTAMP_MISSING",t.Name+"; pts="+m.Groups[4].Value+"; dts="+m.Groups[5].Value); t.LastAlert=now; }
     }
     // DTS avoids treating the normal presentation reordering of B-frames as a clock reversal.
     double value=haveDts?dts:pts;
     if(haveDts || havePts) {
      if(t.HaveClock) {
       double delta=value-t.LastClock;
       if((delta < -0.001 || delta > 5) && now-t.LastAlert>=1) {
        warnings++; Write(delta<0?"TIMESTAMP_BACKWARD":"TIMESTAMP_JUMP",
         t.Name+"; previous="+t.LastClock.ToString("F6",CultureInfo.InvariantCulture)+"; current="+value.ToString("F6",CultureInfo.InvariantCulture)+"; delta_seconds="+delta.ToString("F6",CultureInfo.InvariantCulture));
        t.LastAlert=now;
       }
      } else { t.FirstClock=value; t.HaveClock=true; }
      t.LastClock=value;
     }
     return;
    }
    // Keep useful FFmpeg messages; do not store the high-volume per-packet debug trace.
    if(line.Contains(" -> ") || line.Contains(" <- ") || line.Contains("demuxer+") || line.Contains("encoder ->") || line.Contains("decoder ->")) return;
    string safe=Regex.Replace(line,@"(rtsps?://)[^/\s'""@]+@", "$1[redacted]@",RegexOptions.IgnoreCase);
    Write("FFMPEG",safe);
   }
  }
  void Check(object unused) {
   lock(gate) {
    if(closed) return;
    double now=clock.Elapsed.TotalSeconds;
    foreach(Track t in tracks.Values) {
     if(now-t.LastArrival>=timeout && !t.Missing) {
      warnings++; t.Missing=true;
      Write(t.Count==0?"NO_FIRST_PACKET":"STREAM_STALLED",t.Name+"; seconds_without_packets="+(now-t.LastArrival).ToString("F3",CultureInfo.InvariantCulture)+"; packet_count="+t.Count);
     }
    }
    if(now-lastHeartbeat>=heartbeat) {
     lastHeartbeat=now;
     foreach(Track t in tracks.Values) {
      string details=t.Name+"; packets="+t.Count+"; last_packet_age_seconds="+(now-t.LastArrival).ToString("F3",CultureInfo.InvariantCulture);
      if(t.HaveClock) details+="; source_elapsed_seconds="+(t.LastClock-t.FirstClock).ToString("F3",CultureInfo.InvariantCulture)+"; arrival_elapsed_seconds="+(t.LastArrival-t.FirstArrival).ToString("F3",CultureInfo.InvariantCulture);
      Write("STATUS",details);
     }
    }
   }
  }
  void Read() {
   try { string line; while((line=reader.ReadLine())!=null) ProcessLine(line); }
   catch(Exception ex) { lock(gate) { if(!closed) Write("LOG_READER_ERROR",ex.Message); } }
   finally { Finish(); }
  }
  void Finish() {
   lock(gate) {
    if(closed) return;
    foreach(Track t in tracks.Values) Write("SUMMARY",t.Name+"; packets="+t.Count+"; last_packet_at_elapsed_seconds="+t.LastArrival.ToString("F3",CultureInfo.InvariantCulture));
    Write("END","warning_events="+warnings); closed=true; try { writer.Dispose(); } catch(Exception ex) { failure=ex.Message; }
   }
  }
  public bool Complete(int milliseconds) { bool done=thread.Join(milliseconds); if(done) timer.Dispose(); return done; }
  public void Dispose() { if(Complete(3000)) return; timer.Dispose(); Finish(); }
 }
}
"@
}
