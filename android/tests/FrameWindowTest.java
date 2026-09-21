package com.codex.note8remote;
public final class FrameWindowTest {
 public static void main(String[] args){
  FrameWindow w=new FrameWindow();long a=w.reserve(),b=w.reserve();
  if(a!=1||b!=2||w.reserve()!=0)throw new AssertionError("Window unbounded");
  w.acknowledge(999);if(w.reserve()!=0)throw new AssertionError("Future ack accepted");
  w.acknowledge(1);if(w.reserve()!=3||w.reserve()!=0)throw new AssertionError("Ack accounting");
  w.reset();w.acknowledge(2);long c=w.reserve();if(c!=4||w.reserve()!=5||w.reserve()!=0)throw new AssertionError("Stale ack reopened window");
  long[] now={0};VideoWindow video=new VideoWindow(()->now[0]);
  for(int i=1;i<=18;i++)if(!video.reserve(i*1000))throw new AssertionError("Early initial rejection");
  if(video.reserve(19000))throw new AssertionError("Video backlog unbounded");
  video.acknowledge(999999);if(video.reserve(19000))throw new AssertionError("Future ack accepted");
  now[0]=160;video.acknowledge(18000);
  if(video.limit()<8||video.pending()!=0)throw new AssertionError("WAN window too small");
  // 30fps with 160ms cumulative ACK latency must not shed the prediction chain.
  java.util.ArrayDeque<long[]> flight=new java.util.ArrayDeque<>();int sent=0;
  for(int tick=0;tick<300;tick++){
   now[0]=200+tick*1000/30;
   while(!flight.isEmpty()&&flight.peek()[0]<=now[0])video.acknowledge(flight.remove()[1]);
   long pts=100000+tick*33333L;
   if(!video.reserve(pts))throw new AssertionError("30fps starved at WAN RTT");
   flight.add(new long[]{now[0]+160,pts});sent++;
  }
  if(sent!=300)throw new AssertionError("Incomplete WAN simulation");
  now[0]+=1000;video.acknowledge(flight.peekLast()[1]);
  if(video.limit()!=18)throw new AssertionError("Window cap violated");
  for(int i=0;i<18;i++)if(!video.reserve(20000000L+i))throw new AssertionError("Cap too small");
  if(video.reserve(30000000L))throw new AssertionError("Window unbounded after RTT spike");
  System.out.println("Frame window passed: bounded, ordered, future/stale ack rejected");
 }
}
