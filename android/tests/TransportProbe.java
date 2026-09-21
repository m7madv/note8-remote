package com.codex.note8remote;
import fi.iki.elonen.NanoWSD;
import java.io.IOException;
public final class TransportProbe extends NanoWSD {
 TransportProbe(){super("127.0.0.1",18866);}
 protected WebSocket openWebSocket(IHTTPSession s){return new WebSocket(s){
  volatile boolean active=true;
  protected void onOpen(){Thread t=new Thread(()->{while(active){try{send(new byte[]{1});Thread.sleep(100);}catch(Exception e){break;}}});t.setDaemon(true);t.start();}
  protected void onClose(WebSocketFrame.CloseCode c,String reason,boolean remote){active=false;}
  protected void onMessage(WebSocketFrame f){}
  protected void onPong(WebSocketFrame f){}
  protected void onException(IOException e){active=false;}
 };}
 public static void main(String[] args)throws Exception{TransportProbe s=new TransportProbe();s.start(1000,true);System.out.println("READY");System.out.flush();System.in.read();s.stop();}
}
