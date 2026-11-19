// Capture only audio rendered by the selected player process (Windows build 20348+).
// PCM is relayed on a bounded, real-time clock. No recording is opened here.
using System;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace MachiningMonitor.Broadcast {
 [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IActivateOperation {
  [PreserveSig] int GetActivateResult(out int result, [MarshalAs(UnmanagedType.IUnknown)] out object activated);
 }
 [Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IActivateCompletion { [PreserveSig] int ActivateCompleted(IActivateOperation operation); }
 [Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IAgileObject { }
 [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 interface IAudioClient {
  [PreserveSig] int Initialize(int mode, uint flags, long duration, long periodicity, ref WaveFormat format, IntPtr session);
  [PreserveSig] int GetBufferSize(out uint frames);
  [PreserveSig] int GetStreamLatency(out long latency);
  [PreserveSig] int GetCurrentPadding(out uint frames);
  [PreserveSig] int IsFormatSupported(int mode, IntPtr format, out IntPtr closest);
  [PreserveSig] int GetMixFormat(out IntPtr format);
  [PreserveSig] int GetDevicePeriod(out long normal, out long minimum);
  [PreserveSig] int Start();
  [PreserveSig] int Stop();
  [PreserveSig] int Reset();
  [PreserveSig] int SetEventHandle(IntPtr handle);
  [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
 }
 [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 interface IAudioCaptureClient {
  [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong device, out ulong qpc);
  [PreserveSig] int ReleaseBuffer(uint frames);
  [PreserveSig] int GetNextPacketSize(out uint frames);
 }
 [StructLayout(LayoutKind.Sequential, Pack=2)]
 struct WaveFormat { public ushort tag, channels; public uint rate, bytesPerSecond; public ushort align, bits, extra; }
 [StructLayout(LayoutKind.Sequential)]
 struct Blob { public int size; public IntPtr data; }
 [StructLayout(LayoutKind.Explicit)]
 struct PropVariant { [FieldOffset(0)] public ushort type; [FieldOffset(8)] public Blob blob; }

 [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
 public sealed class Activation : IActivateCompletion, IAgileObject {
  internal readonly ManualResetEvent Done = new ManualResetEvent(false);
  internal object Client; internal int Result;
  public int ActivateCompleted(IActivateOperation operation) {
   try { int hr; object client; int call=operation.GetActivateResult(out hr,out client);
    Result=call<0?call:hr; Client=client;
   } catch(Exception error) { Result=Marshal.GetHRForException(error); }
   finally { Done.Set(); } return 0;
  }
 }

 public sealed class ProcessAudio : IDisposable {
  [DllImport("Mmdevapi.dll", ExactSpelling=true, CharSet=CharSet.Unicode)]
  static extern int ActivateAudioInterfaceAsync(string path, ref Guid iid, ref PropVariant parameters,
   IActivateCompletion completion, out IActivateOperation operation);
  [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved, uint model);
  [DllImport("ole32.dll")] static extern void CoUninitialize();
  readonly object gate=new object(); readonly byte[] ring=new byte[17640]; // 100 ms, stereo PCM16/44100
  readonly ManualResetEvent stop=new ManualResetEvent(false);
  readonly Stream destination; Thread capture, sender; int target, read, count;
  long capturedFrames, sentFrames; volatile string failure; volatile bool disposed; int capturingProcess;
  public string Failure { get { return failure; } }
  public long CapturedFrames { get { return Interlocked.Read(ref capturedFrames); } }
  public long SentFrames { get { return Interlocked.Read(ref sentFrames); } }
  public int TargetProcess { get { return Volatile.Read(ref target); } }
  public bool CaptureReady { get { return TargetProcess!=0 && Volatile.Read(ref capturingProcess)==TargetProcess; } }
  public ProcessAudio(Stream output) {
   destination=output;
   capture=new Thread(Capture); sender=new Thread(Send);
   capture.IsBackground=sender.IsBackground=true;
   capture.SetApartmentState(ApartmentState.MTA);
   capture.Start(); sender.Start();
  }
  public void SetProcess(int process) {
   lock(gate) { if(target==process)return; Volatile.Write(ref target,process); read=0; count=0; }
  }
  void Enqueue(byte[] bytes, int process) {
   lock(gate) {
    if(target!=process)return;
    int start=Math.Max(0,bytes.Length-ring.Length), length=bytes.Length-start;
    // Drop old samples instead of allowing network/CPU stalls to build up delay.
    if(count+length>ring.Length) { int drop=count+length-ring.Length; read=(read+drop)%ring.Length; count-=drop; }
    for(int i=start;i<bytes.Length;i++) { ring[(read+count)%ring.Length]=bytes[i]; count++; }
   }
  }
  void Send() {
   try {
    byte[] packet=new byte[1764]; var clock=Stopwatch.StartNew(); long due=10;
    while(!stop.WaitOne(0)) {
     int wait=(int)(due-clock.ElapsedMilliseconds); if(wait>0 && stop.WaitOne(wait))break;
     Array.Clear(packet,0,packet.Length);
     lock(gate) {
      // If the writer was stalled, discard queued history before resuming.
      if(clock.ElapsedMilliseconds-due>100) { read=0;count=0; }
      int length=Math.Min(packet.Length,count);
      for(int i=0;i<length;i++)packet[i]=ring[(read+i)%ring.Length];
      read=(read+length)%ring.Length;count-=length;
     }
     destination.Write(packet,0,packet.Length); Interlocked.Add(ref sentFrames,441);
     due=Math.Max(due+10,clock.ElapsedMilliseconds);
    }
   } catch(Exception error) { if(!disposed)failure="PCM: "+error.Message; }
  }
  void Capture() {
   int com=CoInitializeEx(IntPtr.Zero,0);
   try {
    while(!stop.WaitOne(0)) {
     int process=TargetProcess;
     if(process==0) { stop.WaitOne(10);continue; }
     IAudioClient client=null; IAudioCaptureClient reader=null; IActivateOperation operation=null;
     Activation activation=null; IntPtr parameters=IntPtr.Zero;
     try {
      parameters=Marshal.AllocHGlobal(12);
      Marshal.WriteInt32(parameters,0,1); // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
      Marshal.WriteInt32(parameters,4,process); Marshal.WriteInt32(parameters,8,0); // include process tree
      var variant=new PropVariant {type=65,blob=new Blob {size=12,data=parameters}};
      Guid iid=typeof(IAudioClient).GUID; activation=new Activation();
      Marshal.ThrowExceptionForHR(ActivateAudioInterfaceAsync("VAD\\Process_Loopback",ref iid,ref variant,activation,out operation));
      // Activation owns the parameters until its callback completes. Do not time out and free them early.
      activation.Done.WaitOne(); Marshal.ThrowExceptionForHR(activation.Result);
      client=(IAudioClient)activation.Client;
      var format=new WaveFormat {tag=1,channels=2,rate=44100,bytesPerSecond=176400,align=4,bits=16,extra=0};
      using(var ready=new AutoResetEvent(false)) {
       Marshal.ThrowExceptionForHR(client.Initialize(0,0x20000|0x40000|0x80000000,0,0,ref format,IntPtr.Zero));
       Guid captureId=typeof(IAudioCaptureClient).GUID; object service;
       Marshal.ThrowExceptionForHR(client.GetService(ref captureId,out service)); reader=(IAudioCaptureClient)service;
       Marshal.ThrowExceptionForHR(client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle()));
       Marshal.ThrowExceptionForHR(client.Start());
       Volatile.Write(ref capturingProcess,process);
       while(!stop.WaitOne(0) && TargetProcess==process) {
        ready.WaitOne(20); uint frames;
        Marshal.ThrowExceptionForHR(reader.GetNextPacketSize(out frames));
        while(frames>0 && !stop.WaitOne(0) && TargetProcess==process) {
         IntPtr data;uint flags;ulong device,qpc;
         Marshal.ThrowExceptionForHR(reader.GetBuffer(out data,out frames,out flags,out device,out qpc));
         try {
          var bytes=new byte[checked((int)frames*4)];
          if((flags&2)==0)Marshal.Copy(data,bytes,0,bytes.Length);
          Enqueue(bytes,process); Interlocked.Add(ref capturedFrames,frames);
         } finally { Marshal.ThrowExceptionForHR(reader.ReleaseBuffer(frames)); }
         Marshal.ThrowExceptionForHR(reader.GetNextPacketSize(out frames));
        }
       }
      }
     } catch(Exception error) { if(!disposed && TargetProcess==process) { failure="WASAPI: "+error.Message; return; } }
     finally {
      Volatile.Write(ref capturingProcess,0);
      if(client!=null)client.Stop();
      if(reader!=null)Marshal.ReleaseComObject(reader);
      if(client!=null)Marshal.ReleaseComObject(client);
      else if(activation!=null && activation.Client!=null)Marshal.ReleaseComObject(activation.Client);
      if(operation!=null)Marshal.ReleaseComObject(operation);
      if(parameters!=IntPtr.Zero)Marshal.FreeHGlobal(parameters);
      if(activation!=null)activation.Done.Dispose();
     }
    }
   } finally { if(com>=0)CoUninitialize(); }
  }
  // Close/kill the encoder first to unblock a potentially blocked pipe write.
  public void Dispose() {
   if(disposed)return;disposed=true;stop.Set();
   sender.Join(1500);capture.Join(1500);
   // The event may still belong to an outstanding Windows activation callback.
   if(!sender.IsAlive && !capture.IsAlive)stop.Dispose();
  }
 }
}
