using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Threading;
using System.Runtime.InteropServices;
public class AudioService : ServiceBase {
 Process worker; EventWaitHandle stop; IntPtr job;
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a,string n);
 [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j,int c,IntPtr p,uint s);
 [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public AudioService(){ServiceName="AudioRTSP";AutoLog=true;}
 protected override void OnStart(string[] args){
  string root=AppDomain.CurrentDomain.BaseDirectory;
  string name="Local\\AudioRTSP-"+Guid.NewGuid().ToString("N");
  stop=new EventWaitHandle(false,EventResetMode.ManualReset,name);
  job=CreateJobObject(IntPtr.Zero,null);
  // JOBOBJECT_EXTENDED_LIMIT_INFORMATION, x64: LimitFlags at offset 16.
  IntPtr info=Marshal.AllocHGlobal(144);
  try {for(int i=0;i<144;i++)Marshal.WriteByte(info,i,0);Marshal.WriteInt32(info,16,0x2000);
   if(job==IntPtr.Zero || !SetInformationJobObject(job,9,info,144))throw new Exception("Cannot create worker job.");
  }finally{Marshal.FreeHGlobal(info);}
  worker=new Process();
  worker.StartInfo=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe"),"-NoProfile -ExecutionPolicy Bypass -File \""+Path.Combine(root,"ServiceWorker.ps1")+"\" -StopEvent \""+name+"\"");
  worker.StartInfo.UseShellExecute=false;worker.StartInfo.CreateNoWindow=true;worker.StartInfo.WorkingDirectory=root;
  try{worker.Start();if(!AssignProcessToJobObject(job,worker.Handle))throw new Exception("Cannot contain worker process.");
   worker.EnableRaisingEvents=true;worker.Exited+=(s,e)=>{if(!stop.WaitOne(0)){ExitCode=1;Stop();}};
  }catch{if(worker!=null){try{worker.Kill();}catch{}}CloseHandle(job);job=IntPtr.Zero;stop.Dispose();throw;}
 }
 protected override void OnStop(){
  if(stop!=null)stop.Set();
  if(worker!=null){RequestAdditionalTime(20000);worker.WaitForExit(15000);}
  if(job!=IntPtr.Zero){CloseHandle(job);job=IntPtr.Zero;}
  if(worker!=null){worker.Dispose();worker=null;}
 }
 public static void Main(){ServiceBase.Run(new AudioService());}
}
