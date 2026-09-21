package com.codex.note8remote;
import java.util.ArrayDeque;
/** Bounds frames in the socket/receiver as well as the local executor queue. */
final class VideoWindow {
 private final ArrayDeque<Long> pending=new ArrayDeque<>();private long last,ack;
 synchronized boolean reserve(long pts){if(pending.size()>=8)return false;pending.add(pts);last=pts;return true;}
 synchronized void acknowledge(long pts){if(pts>last||pts<ack)return;ack=pts;while(!pending.isEmpty()&&pending.peek()<=pts)pending.remove();}
}
