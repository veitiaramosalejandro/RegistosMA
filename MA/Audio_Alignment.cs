using System;
using System.IO;
namespace MachiningMonitor {
 public sealed class AlignmentMatch234 {
  public double OffsetMs, Score, Margin;
  public bool Reliable;
 }
 public static class AudioAlignment234 {
  // Three independent energy envelopes at 100 Hz; no listening gains enter analysis.
  public static double[][] Features(string path) {
   byte[] bytes=File.ReadAllBytes(path);
   int count=bytes.Length/4, frames=count/80;
   double[][] f=new double[3][];
   for(int b=0;b<3;b++) f[b]=new double[frames];
   double[] low=new double[4], hz={100,400,1000,3000}, alpha=new double[4];
   for(int b=0;b<4;b++) alpha[b]=1-Math.Exp(-2*Math.PI*hz[b]/8000);
   double[] energy=new double[3];
   for(int i=0;i<frames*80;i++) {
    double x=BitConverter.ToSingle(bytes,i*4);
    if(double.IsNaN(x)||double.IsInfinity(x))x=0;
    for(int b=0;b<4;b++)low[b]+=alpha[b]*(x-low[b]);
    for(int b=0;b<3;b++){double v=low[b+1]-low[b];energy[b]+=v*v;}
    if(i%80==79)for(int b=0;b<3;b++){f[b][i/80]=Math.Log(1e-14+energy[b]/80);energy[b]=0;}
   }
   for(int b=0;b<3;b++) {
    double[] p=new double[frames+1], copy=(double[])f[b].Clone();
    for(int i=0;i<frames;i++)p[i+1]=p[i]+copy[i];
    for(int i=0;i<frames;i++){int a=Math.Max(0,i-50),z=Math.Min(frames,i+51);f[b][i]-=(p[z]-p[a])/(z-a);}
   }
   return f;
  }
  // Positive delay means external samples precede the same camera event.
  public static AlignmentMatch234 Match(double[][] camera,double[][] external,int seedMs,int radiusMs) {
   int lo=(int)Math.Floor((seedMs-radiusMs)/10.0),hi=(int)Math.Ceiling((seedMs+radiusMs)/10.0);
   double[] scores=new double[hi-lo+1];double best=-2;int bestLag=lo;
   // Identical support for every candidate avoids favoring shorter overlaps.
   int start=Math.Max(100,hi+100),end=Math.Min(camera[0].Length-100,external[0].Length+lo-100);
   if(end-start<800)return new AlignmentMatch234();
   for(int lag=lo;lag<=hi;lag++) {
    double total=0;int valid=0;
    for(int b=0;b<3;b++) {
     double sx=0,sy=0,sxx=0,syy=0,sxy=0;int n=end-start;
     for(int i=start;i<end;i++){double x=camera[b][i],y=external[b][i-lag];sx+=x;sy+=y;sxx+=x*x;syy+=y*y;sxy+=x*y;}
     double vx=sxx-sx*sx/n,vy=syy-sy*sy/n;
     if(vx/n<1e-5||vy/n<1e-5)continue;
     total+=(sxy-sx*sy/n)/Math.Sqrt(vx*vy);valid++;
    }
    double score=valid>=2?total/valid:-1;scores[lag-lo]=score;
    if(score>best){best=score;bestLag=lag;}
   }
   double runner=-1;
   for(int lag=lo;lag<=hi;lag++)if(Math.Abs(lag-bestLag)>20)runner=Math.Max(runner,scores[lag-lo]);
   double margin=best-runner;
   return new AlignmentMatch234 {OffsetMs=bestLag*10,Score=best,Margin=margin,
    Reliable=best>=0.28&&margin>=0.08&&bestLag>lo+2&&bestLag<hi-2};
  }
 }
}
