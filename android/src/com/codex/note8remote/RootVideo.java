package com.codex.note8remote;
import android.graphics.Rect;
import android.media.*;
import android.os.*;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.io.ByteArrayOutputStream;

/** Android 9 hardware surface capture. It never reads or modifies media sources. */
final class RootVideo implements Runnable {
    volatile boolean enabled, requestKey;
    volatile int bitrate=1200000;
    private boolean launched;
    synchronized void enable(boolean value) throws Exception {
        if(value)RootRuntime.ensureContext();
        enabled=value;
        if(value&&!launched){launched=true;Thread t=new Thread(this,"HardwareScreenVideo");t.setDaemon(true);t.start();}
    }
    private static Object call(String name,Class<?>[] signature,Object... args)throws Exception {
        return Class.forName("android.view.SurfaceControl").getDeclaredMethod(name,signature).invoke(null,args);
    }
    public void run(){
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DISPLAY);
        while(RootBridge.alive){
            if(!enabled){SystemClock.sleep(40);continue;}
            MediaCodec codec=null;Surface surface=null;IBinder display=null;
            try{
                RootBridge.dimensions();int sourceW=RootBridge.width,sourceH=RootBridge.height,rotation=RootBridge.rotation;
                int w=sourceW<=sourceH?360:740,h=sourceW<=sourceH?740:360;
                // Keep the source aspect ratio with even dimensions required by AVC.
                if(sourceW<=sourceH)h=Math.max(2,Math.round((float)sourceH*w/sourceW/2)*2);
                else w=Math.max(2,Math.round((float)sourceW*h/sourceH/2)*2);
                MediaFormat format=MediaFormat.createVideoFormat("video/avc",w,h);
                format.setInteger(MediaFormat.KEY_COLOR_FORMAT,MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
                int activeBitrate=bitrate;format.setInteger(MediaFormat.KEY_BIT_RATE,activeBitrate);
                format.setInteger(MediaFormat.KEY_FRAME_RATE,30);
                format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL,1);
                format.setInteger(MediaFormat.KEY_PROFILE,MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
                format.setInteger(MediaFormat.KEY_PRIORITY,0);
                format.setFloat("max-fps-to-encoder",30);
                format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER,33333);
                codec=MediaCodec.createEncoderByType("video/avc");
                String name=codec.getName().toLowerCase(java.util.Locale.ROOT);
                if(name.contains("google")||name.contains("android"))throw new IllegalStateException("Hardware AVC encoder required");
                codec.configure(format,null,null,MediaCodec.CONFIGURE_FLAG_ENCODE);surface=codec.createInputSurface();
                display=(IBinder)call("createDisplay",new Class[]{String.class,boolean.class},"Note8Remote",false);
                Object info=RootBridge.displayInfo.invoke(RootBridge.displayManager,0);
                int stack=info.getClass().getField("layerStack").getInt(info);
                call("openTransaction",new Class[]{});
                try{
                    call("setDisplaySurface",new Class[]{IBinder.class,Surface.class},display,surface);
                    call("setDisplayProjection",new Class[]{IBinder.class,int.class,Rect.class,Rect.class},display,0,new Rect(0,0,sourceW,sourceH),new Rect(0,0,w,h));
                    call("setDisplayLayerStack",new Class[]{IBinder.class,int.class},display,stack);
                }finally{call("closeTransaction",new Class[]{});}
                codec.start();byte[] config=new byte[0];long check=SystemClock.elapsedRealtime();
                RootBridge.event(RootBridge.json("videoStatus").put("available",true).put("width",w).put("height",h).put("targetFps",30).put("codec",codec.getName()));
                MediaCodec.BufferInfo output=new MediaCodec.BufferInfo();
                while(RootBridge.alive&&enabled){
                    if(activeBitrate!=bitrate){activeBitrate=bitrate;Bundle rate=new Bundle();rate.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE,activeBitrate);codec.setParameters(rate);requestKey=true;}
                    if(requestKey){requestKey=false;Bundle p=new Bundle();p.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME,0);codec.setParameters(p);}
                    int index=codec.dequeueOutputBuffer(output,10000);
                    if(index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED){
                        MediaFormat actual=codec.getOutputFormat();ByteArrayOutputStream bytes=new ByteArrayOutputStream();
                        for(String key:new String[]{"csd-0","csd-1"}){ByteBuffer b=actual.getByteBuffer(key);if(b!=null){byte[] part=new byte[b.remaining()];b.get(part);bytes.write(part);}}
                        config=bytes.toByteArray();
                    }
                    if(index>=0){try{
                        ByteBuffer b=codec.getOutputBuffer(index);b.position(output.offset);b.limit(output.offset+output.size);byte[] bytes=new byte[output.size];b.get(bytes);
                        if((output.flags&MediaCodec.BUFFER_FLAG_CODEC_CONFIG)!=0)config=bytes;
                        else if(bytes.length>0){boolean key=(output.flags&MediaCodec.BUFFER_FLAG_KEY_FRAME)!=0;
                            ByteBuffer packet=ByteBuffer.allocate(16+bytes.length+(key?config.length:0));
                            packet.putInt(0x4e385631).putInt(key?1:0).putLong(output.presentationTimeUs);
                            if(key)packet.put(config);packet.put(bytes);RootBridge.packet(5,packet.array());
                        }
                    }finally{codec.releaseOutputBuffer(index,false);}}
                    if(SystemClock.elapsedRealtime()-check>500){RootBridge.dimensions();check=SystemClock.elapsedRealtime();if(RootBridge.rotation!=rotation||RootBridge.width!=sourceW||RootBridge.height!=sourceH)break;}
                }
            }catch(Exception e){enabled=false;try{RootBridge.event(RootBridge.json("videoStatus").put("available",false).put("message","تعذّر تشغيل بث الفيديو العتادي؛ سيُستخدم بث الصور مؤقتًا."));}catch(Exception ignored){}}
            finally{
                if(display!=null)try{call("destroyDisplay",new Class[]{IBinder.class},display);}catch(Exception ignored){}
                if(codec!=null){try{codec.stop();}catch(Exception ignored){}codec.release();}
                if(surface!=null)surface.release();
            }
        }
    }
}
