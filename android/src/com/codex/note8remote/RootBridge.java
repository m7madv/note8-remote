package com.codex.note8remote;

import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.SystemClock;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.io.*;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Local-only helper. No sockets, no shell command endpoint; stdin closes -> release touch and exit. */
public final class RootBridge {
    static final String DIR="/storage/emulated/0/DCIM/Camera1/";
    static final DataOutputStream OUT=new DataOutputStream(new BufferedOutputStream(System.out));
    static volatile boolean alive=true, streaming=false, autoRecording=false;
    static volatile int width=1080,height=2220,rotation=0,previewWidth=480,fps=8,quality=62;
    static volatile String recordId="";
    static long touchStart=0; static float lastX,lastY;
    static Object inputManager,displayManager;
    static Method inject,displayInfo,screenshot;
    static final RootAudio audio=new RootAudio();
    static final RootVideo video=new RootVideo();
    static final Object outputLock=new Object();
    static void packet(int type,byte[] data) throws IOException {
        synchronized(outputLock){
        OUT.writeByte(type);OUT.writeInt(data.length);OUT.write(data);OUT.flush();
        }
    }
    static void event(JSONObject event) { try{packet(1,event.toString().getBytes(StandardCharsets.UTF_8));}catch(Exception e){alive=false;} }
    static JSONObject json(String type) {JSONObject o=new JSONObject();try{o.put("type",type);}catch(Exception ignored){}return o;}
    static void error(String message){try{event(json("error").put("message",message));}catch(Exception ignored){}}
    static void dimensions() throws Exception {
        Object info=displayInfo.invoke(displayManager,0);
        width=info.getClass().getField("logicalWidth").getInt(info);height=info.getClass().getField("logicalHeight").getInt(info);
        rotation=info.getClass().getField("rotation").getInt(info);
    }
    static synchronized void touch(int action,float x,float y) throws Exception {
        if(action==0 && touchStart!=0) touch(1,lastX,lastY);
        if(action!=0 && touchStart==0)return;
        if(action==0)touchStart=SystemClock.uptimeMillis();
        lastX=Math.max(0,Math.min(width-1,x));lastY=Math.max(0,Math.min(height-1,y));
        MotionEvent e=MotionEvent.obtain(touchStart,SystemClock.uptimeMillis(),action,lastX,lastY,action==1?0:1,1,0,1,1,0,0);
        e.setSource(0x1002);
        try { if(!Boolean.TRUE.equals(inject.invoke(inputManager,e,0)))throw new IOException("Touch rejected"); }
        finally{e.recycle();if(action==1||action==3)touchStart=0;}
    }
    static void key(int key) throws Exception {
        long now=SystemClock.uptimeMillis();
        for(int action:new int[]{0,1}) {
            KeyEvent event=new KeyEvent(now,SystemClock.uptimeMillis(),action,key,0,0,-1,0,0,0x101);
            inject.invoke(inputManager,event,0);
        }
    }
    static String read(File f) throws Exception {try(FileInputStream in=new FileInputStream(f)){byte[] b=new byte[4096];int n=in.read(b);return n<0?"":new String(b,0,n,StandardCharsets.UTF_8);}}
    static void write(File f,String value) throws Exception {
        File tmp=new File(f.getPath()+".tmp");try(FileOutputStream out=new FileOutputStream(tmp)){out.write(value.getBytes(StandardCharsets.UTF_8));}
        android.system.Os.rename(tmp.getPath(),f.getPath());android.system.Os.chmod(f.getPath(),0666);
    }
    static synchronized void record(JSONObject command) throws Exception {
        if(autoRecording)throw new IOException("يوجد تسجيل جارٍ.");
        final long duration=command.getLong("durationMs");
        if(duration<500 || duration>60000)throw new IOException("مدة التسجيل المدعومة من 0.5 إلى 60 ثانية.");
        final String id=command.getString("id");if(!id.matches("[a-fA-F0-9-]{16,64}"))throw new IOException("Invalid session");
        dimensions();final float x=(float)command.getDouble("x")*width,y=(float)command.getDouble("y")*height;
        if(touchStart!=0)touch(1,lastX,lastY);
        recordId=id;autoRecording=true;
        write(new File(DIR,"remote-record-request.json"),new JSONObject().put("id",id).put("issuedMs",SystemClock.elapsedRealtime()).toString());
        new Thread(()->{
            long started=0,deadline=SystemClock.elapsedRealtime()+20000;
            try{
                touch(0,x,y);event(json("record").put("state","starting").put("id",id));
                File marker=new File(DIR,"remote-record-start.json");
                while(alive && autoRecording && id.equals(recordId) && SystemClock.elapsedRealtime()<deadline){
                    try{JSONObject m=new JSONObject(read(marker));if(id.equals(m.optString("id"))){started=m.getLong("startedMs");break;}}catch(Exception ignored){}
                    SystemClock.sleep(12);
                }
                if(started==0)throw new IOException("لم يؤكد سناب بدء التسجيل. افتح شاشة الكاميرا وحدد موضع زر التسجيل.");
                long stopAt=started+duration;
                event(json("record").put("state","recording").put("id",id).put("durationMs",duration).put("remainingMs",Math.max(0,stopAt-SystemClock.elapsedRealtime())));
                while(alive && autoRecording && id.equals(recordId) && SystemClock.elapsedRealtime()<stopAt)SystemClock.sleep(Math.min(10,Math.max(1,stopAt-SystemClock.elapsedRealtime())));
                touch(1,x,y);
                event(json("record").put("state","finished").put("id",id).put("heldMs",SystemClock.elapsedRealtime()-started));
            }catch(Exception e){try{touch(1,lastX,lastY);}catch(Exception ignored){}error(e.getMessage());}
            finally{autoRecording=false;new File(DIR,"remote-record-request.json").delete();}
        },"LocalRecordingDeadline").start();
    }
    public static void main(String[] args) throws Exception {
        android.os.Looper.prepareMainLooper();
        Class<?> im=Class.forName("android.hardware.input.InputManager");inputManager=im.getMethod("getInstance").invoke(null);inject=im.getMethod("injectInputEvent",InputEvent.class,int.class);
        Class<?> dm=Class.forName("android.hardware.display.DisplayManagerGlobal");displayManager=dm.getMethod("getInstance").invoke(null);displayInfo=dm.getMethod("getDisplayInfo",int.class);
        screenshot=Class.forName("android.view.SurfaceControl").getDeclaredMethod("screenshot",Rect.class,int.class,int.class,int.class);
        dimensions();event(json("ready").put("width",width).put("height",height));
        Thread capture=new Thread(()->{
            while(alive){
                if(!streaming){SystemClock.sleep(150);continue;}
                long begin=SystemClock.elapsedRealtime();Bitmap bitmap=null;
                try{
                    dimensions();int w=previewWidth,h=Math.max(2,Math.round((float)height*w/width));
                    bitmap=(Bitmap)screenshot.invoke(null,new Rect(),w,h,rotation);
                    if(bitmap!=null){ByteArrayOutputStream bytes=new ByteArrayOutputStream(96*1024);bitmap.compress(Bitmap.CompressFormat.JPEG,quality,bytes);packet(2,bytes.toByteArray());}
                }catch(Exception e){error("تعذّر بث الشاشة.");SystemClock.sleep(1000);}
                finally{if(bitmap!=null)bitmap.recycle();}
                SystemClock.sleep(Math.max(1,1000/Math.max(1,fps)-(SystemClock.elapsedRealtime()-begin)));
            }
        },"ScreenPreview");capture.setDaemon(true);capture.start();
        try(BufferedReader input=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8))){
            String line;while((line=input.readLine())!=null && alive){
                if(line.length()>8192)continue;
                try{
                    JSONObject c=new JSONObject(line);String type=c.getString("type");
                    if(type.equals("stream")){streaming=c.optBoolean("enabled");previewWidth=Math.max(320,Math.min(720,c.optInt("width",480)));fps=Math.max(1,Math.min(24,c.optInt("fps",8)));}
                    else if(type.equals("video")){video.enable(c.optBoolean("enabled"));}
                    else if(type.equals("videoKey")){video.requestKey=true;}
                    else if(type.equals("audio")){try{audio.enable(c.optBoolean("enabled"),c.optBoolean("aac"));}catch(Exception e){event(json("audioStatus").put("available",false).put("message","تعذّر بدء صوت النظام."));}}
                    else if(type.equals("touch")&&!autoRecording)touch(c.getInt("action"),(float)c.getDouble("x")*width,(float)c.getDouble("y")*height);
                    else if(type.equals("cancelTouch")&&!autoRecording)touch(1,lastX,lastY);
                    else if(type.equals("stopRecord")){autoRecording=false;touch(1,lastX,lastY);}
                    else if(type.equals("key")&&!autoRecording){int k=c.getInt("key");if(k==3||k==4||k==187||k==279||k==224)key(k);}
                    else if(type.equals("record"))record(c);
                    else if(type.equals("open")&&!autoRecording){
                        String app=c.getString("app");
                        final String component=app.equals("com.snapchat.android")?"com.snapchat.android/.LandingPageActivity":app.equals("com.codex.note8camera")?"com.codex.note8camera/.MainActivity":null;
                        if(component==null)throw new IOException("Invalid application");
                        key(224);key(3);
                        new Thread(()->{try{SystemClock.sleep(250);Process p=new ProcessBuilder("/system/bin/am","start","-n",component).redirectErrorStream(true).start();try(InputStream in=p.getInputStream()){byte[] b=new byte[1024];while(in.read(b)!=-1){}}if(p.waitFor()!=0)error("تعذّر فتح التطبيق.");}catch(Exception e){error("تعذّر فتح التطبيق.");}},"OpenApplication").start();
                    }
                }catch(Exception e){error(e.getMessage()==null?"تعذّر تنفيذ الأمر.":e.getMessage());}
            }
        }finally{alive=false;autoRecording=false;try{touch(1,lastX,lastY);}catch(Exception ignored){}System.exit(0);}
    }
}
