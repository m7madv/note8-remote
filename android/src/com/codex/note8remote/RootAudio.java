package com.codex.note8remote;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.os.SystemClock;
import java.lang.reflect.Field;

/** Android 9 rooted output mix only. Never selects a microphone source. */
final class RootAudio implements Runnable {
    volatile boolean enabled;
    private boolean initialized;

    synchronized void enable(boolean value) throws Exception {
        if(value && !initialized) {
            // Samsung's AudioRecord JNI requires a non-null operation package.
            Class<?> type=Class.forName("android.app.ActivityThread");
            Object thread=type.getMethod("systemMain").invoke(null);
            Context system=(Context)type.getMethod("getSystemContext").invoke(thread);
            Context context=system.createPackageContext("com.codex.note8remote",0);
            Application app=Instrumentation.newApplication(Application.class,context);
            Field initial=type.getDeclaredField("mInitialApplication");initial.setAccessible(true);initial.set(thread,app);
            initialized=true;
            Thread worker=new Thread(this,"SystemOutputAudio");worker.setDaemon(true);worker.start();
        }
        enabled=value;
    }

    public void run() {
        while(RootBridge.alive) {
            if(!enabled) {SystemClock.sleep(50);continue;}
            AudioRecord record=null;
            try {
                int minimum=AudioRecord.getMinBufferSize(48000,AudioFormat.CHANNEL_IN_STEREO,AudioFormat.ENCODING_PCM_16BIT);
                record=new AudioRecord(8,48000,AudioFormat.CHANNEL_IN_STEREO,AudioFormat.ENCODING_PCM_16BIT,Math.max(16384,minimum*4));
                if(record.getState()!=AudioRecord.STATE_INITIALIZED)throw new IllegalStateException("System output unavailable");
                record.startRecording();
                long captureStarted=SystemClock.elapsedRealtime(), frames=0;
                RootBridge.event(RootBridge.json("audioStatus").put("available",true));
                byte[] pcm=new byte[3840];int filled=0;
                while(RootBridge.alive && enabled) {
                    int n=record.read(pcm,filled,pcm.length-filled,AudioRecord.READ_NON_BLOCKING);
                    if(n<0)throw new IllegalStateException("System output read failed: "+n);
                    filled+=n;
                    if(filled==pcm.length) {
                        java.nio.ByteBuffer packet=java.nio.ByteBuffer.allocate(8+filled);
                        frames+=filled/4;
                        packet.putLong(captureStarted+frames*1000/48000).put(pcm,0,filled);
                        RootBridge.packet(3,packet.array());filled=0;
                    }
                    else SystemClock.sleep(4);
                }
            } catch(Exception e) {
                enabled=false;
                try {RootBridge.event(RootBridge.json("audioStatus").put("available",false).put("message","تعذّر بث صوت النظام على النوت."));}catch(Exception ignored){}
            } finally {
                if(record!=null) {try{record.stop();}catch(Exception ignored){}record.release();}
            }
        }
    }
}
