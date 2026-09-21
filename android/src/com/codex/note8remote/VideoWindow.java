package com.codex.note8remote;
import java.util.ArrayDeque;
import java.util.function.LongSupplier;
/** Bounded bandwidth-delay window; a fixed eight frames stalls a live stream over WAN RTT. */
final class VideoWindow {
 private static final int MIN=4,MAX=18;
 private static final class Entry {final long pts,at;Entry(long p,long t){pts=p;at=t;}}
 private final ArrayDeque<Entry> pending=new ArrayDeque<>();private final LongSupplier clock;
 private long last,ack;private double rttMs=-1;
 VideoWindow(){this(()->System.nanoTime()/1000000);}
 VideoWindow(LongSupplier clock){this.clock=clock;}
 synchronized int limit(){return rttMs<0?MAX:Math.max(MIN,Math.min(MAX,(int)Math.ceil((rttMs+100)*30/1000)));}
 synchronized int pending(){return pending.size();}
 synchronized long rttMs(){return Math.round(rttMs);}
 synchronized boolean reserve(long pts){if(pending.size()>=limit())return false;pending.add(new Entry(pts,clock.getAsLong()));last=pts;return true;}
 synchronized void acknowledge(long pts){
  if(pts>last||pts<=ack)return;
  Entry matched=null;for(Entry e:pending)if(e.pts==pts){matched=e;break;}
  if(matched==null)return;
  long sample=Math.max(0,clock.getAsLong()-matched.at);
  // Grow promptly on delayed ACKs; shrink slowly after the path recovers.
  rttMs=rttMs<0?sample:sample>rttMs?sample:rttMs*.95+sample*.05;
  ack=pts;while(!pending.isEmpty()&&pending.peek().pts<=pts)pending.remove();
 }
}
