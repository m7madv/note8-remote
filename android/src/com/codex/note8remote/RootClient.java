package com.codex.note8remote;
import android.content.Context;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
final class RootClient {
    interface Listener{void event(JSONObject event);void frame(byte[] jpeg);void audio(byte[] pcm,boolean aac);}
    private Process process;private BufferedWriter input;volatile boolean ready;
    RootClient(Context context,Listener listener)throws Exception{
        String path=context.getApplicationInfo().sourceDir;
        process=new ProcessBuilder("su","-c","CLASSPATH='"+path.replace("'","'\\''")+"' app_process / com.codex.note8remote.RootBridge").start();
        input=new BufferedWriter(new OutputStreamWriter(process.getOutputStream(),StandardCharsets.UTF_8));
        new Thread(()->{try(DataInputStream out=new DataInputStream(new BufferedInputStream(process.getInputStream()))){
            while(true){int type=out.readUnsignedByte(),size=out.readInt();if(size<0||size>4*1024*1024)throw new IOException("Invalid frame");byte[] bytes=new byte[size];out.readFully(bytes);
                if(type==2)listener.frame(bytes);else if(type==3||type==4)listener.audio(bytes,type==4);else{JSONObject event=new JSONObject(new String(bytes,StandardCharsets.UTF_8));if("ready".equals(event.optString("type")))ready=true;listener.event(event);}}
        }catch(Exception e){ready=false;android.util.Log.e("Note8Root","Root helper disconnected",e);try{listener.event(new JSONObject().put("type","error").put("message","خدمة التحكم متوقفة. افتح تطبيق النوت وأعد تشغيلها."));}catch(Exception ignored){}}},"RootReplies").start();
        new Thread(()->{try(BufferedReader errors=new BufferedReader(new InputStreamReader(process.getErrorStream()))){String line;while((line=errors.readLine())!=null){android.util.Log.e("Note8Root",line);}}catch(Exception ignored){}},"RootStderr").start();
    }
    synchronized void send(JSONObject command)throws IOException{input.write(command.toString());input.newLine();input.flush();}
    void close(){ready=false;try{input.close();}catch(Exception ignored){}new Thread(()->{try{Thread.sleep(1500);}catch(Exception ignored){}process.destroy();}).start();}
}
