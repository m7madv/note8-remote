package com.codex.note8remote;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.SystemClock;
import java.lang.reflect.Field;

/** Android 9 rooted output mix only. Never selects a microphone source. */
final class RootAudio implements Runnable {
    volatile boolean enabled;
    volatile boolean compressed;
    private boolean initialized;

    synchronized void enable(boolean value, boolean aac) throws Exception {
        if(value && !initialized) {
            // Samsung's AudioRecord JNI requires a non-null operation package.
            RootRuntime.ensureContext();
            initialized=true;
            Thread worker=new Thread(this,"SystemOutputAudio");worker.setDaemon(true);worker.start();
        }
        compressed=aac;enabled=value;
    }

    public void run() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
        while(RootBridge.alive) {
            if(!enabled) {SystemClock.sleep(50);continue;}
            AudioRecord record=null;
            MediaCodec encoder=null;
            final boolean useAac=compressed;
            try {
                int minimum=AudioRecord.getMinBufferSize(48000,AudioFormat.CHANNEL_IN_STEREO,AudioFormat.ENCODING_PCM_16BIT);
                record=new AudioRecord(8,48000,AudioFormat.CHANNEL_IN_STEREO,AudioFormat.ENCODING_PCM_16BIT,Math.max(7680,minimum*2));
                if(record.getState()!=AudioRecord.STATE_INITIALIZED)throw new IllegalStateException("System output unavailable");
                if(useAac) {
                    MediaFormat format=MediaFormat.createAudioFormat("audio/mp4a-latm",48000,2);
                    format.setInteger(MediaFormat.KEY_AAC_PROFILE,MediaCodecInfo.CodecProfileLevel.AACObjectLC);
                    format.setInteger(MediaFormat.KEY_BIT_RATE,128000);
                    format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE,16384);
                    encoder=MediaCodec.createEncoderByType("audio/mp4a-latm");
                    encoder.configure(format,null,null,MediaCodec.CONFIGURE_FLAG_ENCODE);encoder.start();
                }
                record.startRecording();
                long captureStarted=SystemClock.elapsedRealtime(), frames=0;
                RootBridge.event(RootBridge.json("audioStatus").put("available",true));
                byte[] pcm=new byte[3840];int filled=0;
                while(RootBridge.alive && enabled && useAac==compressed) {
                    int n=record.read(pcm,filled,pcm.length-filled,AudioRecord.READ_NON_BLOCKING);
                    if(n<0)throw new IllegalStateException("System output read failed: "+n);
                    filled+=n;
                    if(filled==pcm.length) {
                        if(useAac) {
                            int index=encoder.dequeueInputBuffer(3000);
                            if(index>=0) {
                                java.nio.ByteBuffer input=encoder.getInputBuffer(index);input.clear();input.put(pcm,0,filled);
                                encoder.queueInputBuffer(index,0,filled,captureStarted*1000+frames*1000000/48000,0);
                            }
                        } else {
                            java.nio.ByteBuffer packet=java.nio.ByteBuffer.allocate(8+filled);
                            packet.putLong(captureStarted+(frames+filled/4)*1000/48000).put(pcm,0,filled);
                            RootBridge.packet(3,packet.array());
                        }
                        frames+=filled/4;
                        filled=0;
                    }
                    else SystemClock.sleep(4);
                    if(useAac) {
                        MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();int index;
                        while((index=encoder.dequeueOutputBuffer(info,0))>=0) {
                            try {
                                if(info.size>0 && (info.flags&MediaCodec.BUFFER_FLAG_CODEC_CONFIG)==0) {
                                    java.nio.ByteBuffer output=encoder.getOutputBuffer(index);output.position(info.offset);output.limit(info.offset+info.size);
                                    java.nio.ByteBuffer packet=java.nio.ByteBuffer.allocate(8+info.size);
                                    packet.putLong(info.presentationTimeUs/1000).put(output);
                                    RootBridge.packet(4,packet.array());
                                }
                            } finally {encoder.releaseOutputBuffer(index,false);}
                        }
                    }
                }
            } catch(Exception e) {
                enabled=false;
                try {RootBridge.event(RootBridge.json("audioStatus").put("available",false).put("message","تعذّر بث صوت النظام على النوت."));}catch(Exception ignored){}
            } finally {
                if(record!=null) {try{record.stop();}catch(Exception ignored){}record.release();}
                if(encoder!=null) {try{encoder.stop();}catch(Exception ignored){}encoder.release();}
            }
        }
    }
}
