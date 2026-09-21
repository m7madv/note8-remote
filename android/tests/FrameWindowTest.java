package com.codex.note8remote;
public final class FrameWindowTest {
 public static void main(String[] args){
  FrameWindow w=new FrameWindow();long a=w.reserve(),b=w.reserve();
  if(a!=1||b!=2||w.reserve()!=0)throw new AssertionError("Window unbounded");
  w.acknowledge(999);if(w.reserve()!=0)throw new AssertionError("Future ack accepted");
  w.acknowledge(1);if(w.reserve()!=3||w.reserve()!=0)throw new AssertionError("Ack accounting");
  w.reset();w.acknowledge(2);long c=w.reserve();if(c!=4||w.reserve()!=5||w.reserve()!=0)throw new AssertionError("Stale ack reopened window");
  System.out.println("Frame window passed: bounded, ordered, future/stale ack rejected");
 }
}
